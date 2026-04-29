#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Lists all virtual machines across every subscription the current account can access.

.DESCRIPTION
    Iterates through all subscriptions in the active tenant, collects VM details
    (name, resource group, location, size, OS, power state, tags), and returns
    them as objects suitable for piping or formatting.

.EXAMPLE
    ./Get-AzVmInventory.ps1
    Lists all VMs across all accessible subscriptions in a console table.

.EXAMPLE
    ./Get-AzVmInventory.ps1 | Where-Object PowerState -eq 'VM running'
    Filters to running VMs only.

.EXAMPLE
    ./Get-AzVmInventory.ps1 | Export-Csv -Path vms.csv -NoTypeInformation
    Exports to CSV (we'll add this as a built-in option later).

.NOTES
    Author : <your name>
    Repo   : https://github.com/<you>/az-toolkit
#>

[CmdletBinding()]
param()

# --- 1. Make sure we're authenticated ---------------------------------------
# Get-AzContext returns $null if no one has run Connect-AzAccount in this session.
# We fail early with a clear message rather than hitting cryptic errors later.
if (-not (Get-AzContext)) {
    throw "Not connected to Azure. Run 'Connect-AzAccount' first."
}

# --- 2. Discover all subscriptions ------------------------------------------
# Get-AzSubscription returns every subscription the signed-in identity can see.
# We filter to 'Enabled' to skip disabled/deleted subs that would just throw.
Write-Verbose "Discovering subscriptions..."
$subscriptions = Get-AzSubscription | Where-Object State -eq 'Enabled'

if (-not $subscriptions) {
    Write-Warning "No enabled subscriptions found for the current account."
    return
}

Write-Verbose "Found $($subscriptions.Count) enabled subscription(s)."

# --- 3. Loop through each subscription and collect VMs ----------------------
# Using a generic List<T> instead of += on an array — much faster as the list grows
# (arrays in PowerShell are immutable; += rebuilds the whole array each time).
$inventory = [System.Collections.Generic.List[object]]::new()

foreach ($sub in $subscriptions) {
    Write-Verbose "Scanning subscription: $($sub.Name) ($($sub.Id))"

    # Set context so subsequent Az cmdlets target this subscription.
    # -WarningAction SilentlyContinue suppresses the noisy tenant-warning banner.
    try {
        Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Warning "Could not switch to subscription '$($sub.Name)': $_"
        continue   # skip to the next sub instead of dying
    }

    # -Status enriches the result with PowerState ('VM running', 'VM deallocated', etc.)
    # but it's slower because it makes an extra API call per VM. Worth it for inventory.
    try {
        $vms = Get-AzVM -Status -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to list VMs in '$($sub.Name)': $_"
        continue
    }

    foreach ($vm in $vms) {
        # Build a flat object with the columns we actually want to see.
        # [PSCustomObject] gives us a clean, typed-feeling row in the output table.
        $inventory.Add([PSCustomObject]@{
            Subscription   = $sub.Name
            ResourceGroup  = $vm.ResourceGroupName
            Name           = $vm.Name
            Location       = $vm.Location
            Size           = $vm.HardwareProfile.VmSize
            OS             = $vm.StorageProfile.OsDisk.OsType
            PowerState     = ($vm.PowerState -replace '^VM ', '')   # 'running' instead of 'VM running'
            # Tags is a hashtable; flatten to "key=value; key=value" for table display
            Tags           = if ($vm.Tags) {
                                ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
                             } else { '' }
        })
    }
}

# --- 4. Output --------------------------------------------------------------
# Emit objects to the pipeline. The caller decides what to do with them
# (Format-Table, Export-Csv, Where-Object, etc.). This is the PowerShell way —
# don't format inside the script, output objects.
$inventory | Sort-Object Subscription, ResourceGroup, Name
