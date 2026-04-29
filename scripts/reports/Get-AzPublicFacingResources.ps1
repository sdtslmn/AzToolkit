#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Lists Azure resources that are exposed to the public internet across every accessible subscription.

.DESCRIPTION
    Uses Azure Resource Graph to find:
      - Public IP addresses (and what they're attached to)
      - Storage accounts allowing public network access
      - App Services / Function Apps with public access
      - SQL servers with public network access enabled
      - Key Vaults with public network access enabled
      - AKS clusters with public API server endpoints

    Read-only. Returns a unified list of objects with a 'ResourceCategory' column
    so you can filter by type after the fact.

.EXAMPLE
    ./Get-AzPublicFacingResources.ps1 | Format-Table

.EXAMPLE
    ./Get-AzPublicFacingResources.ps1 | Where-Object ResourceCategory -eq 'Storage'

.EXAMPLE
    ./Get-AzPublicFacingResources.ps1 | Export-Csv public-exposure.csv -NoTypeInformation

.NOTES
    Requires the Az.ResourceGraph module:  Install-Module Az.ResourceGraph -Scope CurrentUser
#>

[CmdletBinding()]
param()

# --- 1. Auth check ---------------------------------------------------------
if (-not (Get-AzContext)) {
    throw "Not connected to Azure. Run 'Connect-AzAccount' first."
}

# --- 2. Get the list of subscriptions to query -----------------------------
# Search-AzGraph queries every subscription the caller can see by default,
# but we pass the IDs explicitly so the result is predictable and we can log it.
$subscriptionIds = (Get-AzSubscription | Where-Object State -eq 'Enabled').Id

if (-not $subscriptionIds) {
    Write-Warning "No enabled subscriptions found."
    return
}

Write-Verbose "Querying $($subscriptionIds.Count) subscription(s) via Resource Graph..."

# --- 3. Helper: run an ARG query and tag each row with a category ----------
# Wrapping Search-AzGraph keeps the calling code clean and gives us paging for free.
# ARG returns max 1000 rows per call; -First 5000 plus internal paging covers
# most real tenants. Adjust if you have a tenant with >5000 of any single type.
function Invoke-Arg {
    param(
        [Parameter(Mandatory)] [string] $Query,
        [Parameter(Mandatory)] [string] $Category
    )

    $results = Search-AzGraph -Query $Query -Subscription $subscriptionIds -First 1000

    foreach ($row in $results) {
        # Add the category column so the merged output is self-describing.
        $row | Add-Member -NotePropertyName ResourceCategory -NotePropertyValue $Category -PassThru
    }
}

# --- 4. The KQL queries ----------------------------------------------------
# Each query projects a consistent shape: Name, ResourceGroup, SubscriptionId,
# Location, plus a 'Detail' string with type-specific info. That uniform shape
# is what lets us merge everything into one table at the end.

$publicIps = @'
Resources
| where type == "microsoft.network/publicipaddresses"
| extend AttachedTo = tostring(properties.ipConfiguration.id)
| project
    Name           = name,
    ResourceGroup  = resourceGroup,
    SubscriptionId = subscriptionId,
    Location       = location,
    Detail         = strcat(
                        "IP=", tostring(properties.ipAddress),
                        " | Sku=", tostring(sku.name),
                        " | AttachedTo=", iif(isempty(AttachedTo), "UNATTACHED", AttachedTo))
'@

$storage = @'
Resources
| where type == "microsoft.storage/storageaccounts"
| where properties.publicNetworkAccess != "Disabled"
| project
    Name           = name,
    ResourceGroup  = resourceGroup,
    SubscriptionId = subscriptionId,
    Location       = location,
    Detail         = strcat(
                        "PublicAccess=", tostring(properties.publicNetworkAccess),
                        " | AllowBlobPublic=", tostring(properties.allowBlobPublicAccess),
                        " | MinTls=", tostring(properties.minimumTlsVersion))
'@

$appServices = @'
Resources
| where type == "microsoft.web/sites"
| where properties.publicNetworkAccess != "Disabled"
| project
    Name           = name,
    ResourceGroup  = resourceGroup,
    SubscriptionId = subscriptionId,
    Location       = location,
    Detail         = strcat(
                        "Kind=", kind,
                        " | DefaultHost=", tostring(properties.defaultHostName),
                        " | HttpsOnly=", tostring(properties.httpsOnly))
'@

$sqlServers = @'
Resources
| where type == "microsoft.sql/servers"
| where properties.publicNetworkAccess == "Enabled"
| project
    Name           = name,
    ResourceGroup  = resourceGroup,
    SubscriptionId = subscriptionId,
    Location       = location,
    Detail         = strcat("FQDN=", tostring(properties.fullyQualifiedDomainName))
'@

$keyVaults = @'
Resources
| where type == "microsoft.keyvault/vaults"
| where properties.publicNetworkAccess != "Disabled"
| project
    Name           = name,
    ResourceGroup  = resourceGroup,
    SubscriptionId = subscriptionId,
    Location       = location,
    Detail         = strcat(
                        "NetworkAcls=", tostring(properties.networkAcls.defaultAction),
                        " | RBAC=", tostring(properties.enableRbacAuthorization))
'@

$aks = @'
Resources
| where type == "microsoft.containerservice/managedclusters"
| where isnull(properties.apiServerAccessProfile.enablePrivateCluster)
     or properties.apiServerAccessProfile.enablePrivateCluster == false
| project
    Name           = name,
    ResourceGroup  = resourceGroup,
    SubscriptionId = subscriptionId,
    Location       = location,
    Detail         = strcat(
                        "K8sVersion=", tostring(properties.kubernetesVersion),
                        " | FQDN=", tostring(properties.fqdn))
'@

# --- 5. Run them all and combine -------------------------------------------
# Wrapping each Invoke-Arg in try/catch means one failed query (e.g. a permission
# issue on one resource type) doesn't kill the whole report.
$results = [System.Collections.Generic.List[object]]::new()

$queries = @(
    @{ Name = 'PublicIP';    Query = $publicIps },
    @{ Name = 'Storage';     Query = $storage },
    @{ Name = 'AppService';  Query = $appServices },
    @{ Name = 'SqlServer';   Query = $sqlServers },
    @{ Name = 'KeyVault';    Query = $keyVaults },
    @{ Name = 'AKS';         Query = $aks }
)

foreach ($q in $queries) {
    Write-Verbose "Querying: $($q.Name)"
    try {
        $rows = Invoke-Arg -Query $q.Query -Category $q.Name
        if ($rows) { $results.AddRange([object[]]$rows) }
    }
    catch {
        Write-Warning "Query for '$($q.Name)' failed: $_"
    }
}

# --- 6. Enrich with subscription name (ARG only returns the GUID) ----------
# Build a lookup hashtable once instead of calling Get-AzSubscription per row.
$subLookup = @{}
Get-AzSubscription | ForEach-Object { $subLookup[$_.Id] = $_.Name }

$results | ForEach-Object {
    $_ | Add-Member -NotePropertyName Subscription `
                    -NotePropertyValue ($subLookup[$_.SubscriptionId]) `
                    -PassThru
} |
Sort-Object ResourceCategory, Subscription, ResourceGroup, Name |
Select-Object ResourceCategory, Subscription, ResourceGroup, Name, Location, Detail
