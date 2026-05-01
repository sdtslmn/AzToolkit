#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Summarises every resource group across all accessible subscriptions:
    resource counts, top resource types, and a best-effort owner attribution.

.DESCRIPTION
    Uses Azure Resource Graph to:
      1. List all resource groups (including empty ones).
      2. Count resources per RG and identify the top 3 resource types.
      3. Read the RG's 'Owner' tag, falling back to the most common owner tag
         among resources inside the RG when the RG itself isn't tagged.

    Returns one row per resource group, sorted by resource count descending.

.PARAMETER OwnerTagName
    Name of the tag used to identify owners. Defaults to 'Owner'.
    Common alternatives: 'owner', 'CostCenter', 'TechnicalContact'.

.EXAMPLE
    ./Get-AzResourceGroupSummary.ps1 | Format-Table -Wrap

.EXAMPLE
    ./Get-AzResourceGroupSummary.ps1 | Where-Object ResourceCount -eq 0
    Find empty resource groups (cleanup candidates).

.EXAMPLE
    ./Get-AzResourceGroupSummary.ps1 -OwnerTagName 'CostCenter' |
        Group-Object Owner |
        Sort-Object Count -Descending |
        Select-Object Name, Count
    Group RGs by owner to see who owns the most.
#>

[CmdletBinding()]
param(
    [string] $OwnerTagName = 'Owner'
)

# --- 1. Auth check ---------------------------------------------------------
if (-not (Get-AzContext)) {
    throw "Not connected to Azure. Run 'Connect-AzAccount' first."
}

$subscriptionIds = (Get-AzSubscription | Where-Object State -eq 'Enabled').Id
if (-not $subscriptionIds) {
    Write-Warning "No enabled subscriptions found."
    return
}

Write-Verbose "Querying $($subscriptionIds.Count) subscription(s) via Resource Graph..."

# --- 2. Pull all resource groups (including empty ones) --------------------
# ResourceContainers is a separate ARG table that holds RGs and subscriptions.
# Without this, an RG with zero resources wouldn't appear when we query Resources.
$rgQuery = @"
ResourceContainers
| where type == 'microsoft.resources/subscriptions/resourcegroups'
| project
    RgId           = tolower(id),
    Name           = name,
    Location       = location,
    SubscriptionId = subscriptionId,
    RgTags         = tags
"@

$resourceGroups = Search-AzGraph -Query $rgQuery -Subscription $subscriptionIds -First 5000

# --- 3. Pull resource counts and top types per RG --------------------------
# 'make_list' collects all resource types per RG into an array.
# We slice to the top 3 in PowerShell after the query (KQL can do it but the
# syntax is uglier than just doing it client-side for a few thousand RGs).
$resourceQuery = @"
Resources
| extend RgId = tolower(strcat('/subscriptions/', subscriptionId, '/resourcegroups/', resourceGroup))
| summarize
    ResourceCount = count(),
    Types         = make_list(type),
    OwnerTags     = make_list(tostring(tags['$OwnerTagName']))
  by RgId
"@

$resourceData = Search-AzGraph -Query $resourceQuery -Subscription $subscriptionIds -First 5000

# Index by RgId for fast joining (same hashtable-lookup pattern as before)
$resourceLookup = @{}
foreach ($row in $resourceData) {
    $resourceLookup[$row.RgId] = $row
}

# --- 4. Subscription name lookup -------------------------------------------
$subLookup = @{}
Get-AzSubscription | ForEach-Object { $subLookup[$_.Id] = $_.Name }

# --- 5. Helper: pick the most common non-empty value from an array ---------
# Used to derive "what's the most common Owner tag among resources in this RG?"
# Returns $null if the input is empty or all values are empty/null.
function Get-MostCommonValue {
    param([string[]] $Values)

    $cleaned = $Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $cleaned) { return $null }

    ($cleaned | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
}

# --- 6. Combine into the final report --------------------------------------
$report = foreach ($rg in $resourceGroups) {

    $match = $resourceLookup[$rg.RgId]
    $count = if ($match) { $match.ResourceCount } else { 0 }

    # Top 3 resource types by frequency within this RG
    $topTypes =
        if ($match -and $match.Types) {
            ($match.Types |
                Group-Object |
                Sort-Object Count -Descending |
                Select-Object -First 3 |
                ForEach-Object {
                    # Strip the 'microsoft.x/' prefix for readability
                    $short = $_.Name -replace '^microsoft\.', ''
                    "$short ($($_.Count))"
                }) -join ', '
        }
        else { '' }

    # Owner: prefer the RG's own tag, otherwise fall back to the modal value
    # from resources inside the RG.
    $rgOwner = if ($rg.RgTags) { [string]$rg.RgTags.$OwnerTagName } else { $null }
    $owner =
        if (-not [string]::IsNullOrWhiteSpace($rgOwner)) {
            $rgOwner
        }
        elseif ($match) {
            Get-MostCommonValue -Values $match.OwnerTags
        }
        else { $null }

    [PSCustomObject]@{
        Subscription  = $subLookup[$rg.SubscriptionId]
        ResourceGroup = $rg.Name
        Location      = $rg.Location
        ResourceCount = $count
        Owner         = if ($owner) { $owner } else { '<unset>' }
        OwnerSource   = if (-not [string]::IsNullOrWhiteSpace($rgOwner)) { 'RG-tag' }
                        elseif ($owner)                                  { 'inferred' }
                        else                                             { 'none' }
        TopTypes      = $topTypes
    }
}

# --- 7. Output -------------------------------------------------------------
$report | Sort-Object ResourceCount -Descending, Subscription, ResourceGroup