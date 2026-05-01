#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph, Az.Resources

<#
.SYNOPSIS
    Audits (and optionally remediates) Azure resources against a tagging standard.

.DESCRIPTION
    Reads a tagging standard from a .psd1 config file and checks every resource
    across all accessible subscriptions for compliance. Returns one object per
    violation with the resource ID, the failing rule, and the suggested fix.

    Default mode is audit-only. Pass -Remediate to apply *safe* fixes:
      - A required tag is missing AND the standard defines a DefaultValue.
    The script will NEVER overwrite an existing tag value, even if it violates
    the standard — that's a policy decision you must make explicitly.

.PARAMETER ConfigPath
    Path to the tagging standard .psd1 file.
    Defaults to ../../config/tagging-standard.psd1 relative to the script.

.PARAMETER Remediate
    If specified, applies safe fixes. Honors -WhatIf and -Confirm.

.EXAMPLE
    ./Test-AzTaggingStandard.ps1
    Audit mode. Returns all violations.

.EXAMPLE
    ./Test-AzTaggingStandard.ps1 | Group-Object Rule | Sort-Object Count -Descending
    Top violation types across the tenant.

.EXAMPLE
    ./Test-AzTaggingStandard.ps1 -Remediate -WhatIf
    Show what would be auto-fixed, without changing anything.

.EXAMPLE
    ./Test-AzTaggingStandard.ps1 -Remediate -Confirm:$false
    Apply safe fixes silently (use with care, ideally only in CI on a sandbox sub).
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' '..' 'config' 'tagging-standard.psd1'),
    [switch] $Remediate
)

# --- 1. Pre-flight ---------------------------------------------------------
if (-not (Get-AzContext)) {
    throw "Not connected to Azure. Run 'Connect-AzAccount' first."
}

if (-not (Test-Path $ConfigPath)) {
    throw "Tagging standard not found at: $ConfigPath"
}

# Import-PowerShellDataFile parses .psd1 safely (no script execution).
# This is the right way to load config — never use Invoke-Expression on .ps1 files.
$standard = Import-PowerShellDataFile -Path $ConfigPath
Write-Verbose "Loaded standard with $($standard.RequiredTags.Count) required tag(s)."

$subscriptionIds = (Get-AzSubscription | Where-Object State -eq 'Enabled').Id
if (-not $subscriptionIds) { Write-Warning "No enabled subscriptions."; return }

# --- 2. Pull all in-scope resources via ARG --------------------------------
# We grab everything once, filter in PowerShell. Faster than per-type queries
# and lets us reuse the same dataset for every rule.
$query = @'
Resources
| project id, name, type, resourceGroup, subscriptionId, location, tags
'@

Write-Verbose "Querying resources across $($subscriptionIds.Count) subscription(s)..."
$resources = Search-AzGraph -Query $query -Subscription $subscriptionIds -First 5000

# --- 3. Apply exclusions ---------------------------------------------------
# Build regex matchers once, outside the loop. Tiny perf win, big readability win.
$typeExclusions = $standard.ExcludedResourceTypes |
    ForEach-Object { '^' + [regex]::Escape($_).Replace('\*', '.*') + '$' }

$rgExclusions = $standard.ExcludedResourceGroupPatterns

function Test-IsExcluded {
    param($Resource)

    foreach ($pattern in $typeExclusions) {
        if ($Resource.type -match $pattern) { return $true }
    }
    foreach ($pattern in $rgExclusions) {
        if ($Resource.resourceGroup -match $pattern) { return $true }
    }
    return $false
}

$inScope = $resources | Where-Object { -not (Test-IsExcluded $_) }
Write-Verbose "$($inScope.Count) of $($resources.Count) resources are in scope."

# --- 4. Validation rules ---------------------------------------------------
# Each rule returns $null if OK, or a violation object if not.
# Keeping rules as small functions makes them testable in isolation.

function Test-TagPresent {
    param($Resource, [string] $TagName)

    $value = if ($Resource.tags) { [string]$Resource.tags.$TagName } else { $null }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return [PSCustomObject]@{
            Rule        = 'MissingRequiredTag'
            TagName     = $TagName
            CurrentValue = $null
            Message     = "Required tag '$TagName' is missing."
        }
    }
    return $null
}

function Test-TagValueAllowed {
    param($Resource, [string] $TagName, $Rule)

    if (-not $Resource.tags) { return $null }   # Test-TagPresent already flagged it
    $value = [string]$Resource.tags.$TagName
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    # Allowed-values check
    if ($Rule.AllowedValues) {
        $comparer = if ($Rule.CaseSensitive) {
            { param($a, $b) $a -ceq $b }
        } else {
            { param($a, $b) $a -eq $b }
        }

        $isAllowed = $false
        foreach ($allowed in $Rule.AllowedValues) {
            if (& $comparer $value $allowed) { $isAllowed = $true; break }
        }

        if (-not $isAllowed) {
            return [PSCustomObject]@{
                Rule         = 'InvalidTagValue'
                TagName      = $TagName
                CurrentValue = $value
                Message      = "Value '$value' is not in allowed list: $($Rule.AllowedValues -join ', ')"
            }
        }
    }

    # Pattern check
    if ($Rule.Pattern -and $value -notmatch $Rule.Pattern) {
        return [PSCustomObject]@{
            Rule         = 'TagValuePatternMismatch'
            TagName      = $TagName
            CurrentValue = $value
            Message      = "Value '$value' does not match pattern '$($Rule.Pattern)'."
        }
    }

    return $null
}

# --- 5. Run all rules against all resources -------------------------------
$violations = [System.Collections.Generic.List[object]]::new()

foreach ($r in $inScope) {
    foreach ($tagName in $standard.RequiredTags.Keys) {
        $rule = $standard.RequiredTags[$tagName]

        $checks = @(
            (Test-TagPresent       -Resource $r -TagName $tagName),
            (Test-TagValueAllowed  -Resource $r -TagName $tagName -Rule $rule)
        )

        foreach ($v in ($checks | Where-Object { $_ })) {
            $violations.Add([PSCustomObject]@{
                SubscriptionId = $r.subscriptionId
                ResourceGroup  = $r.resourceGroup
                ResourceName   = $r.name
                ResourceType   = $r.type
                ResourceId     = $r.id
                Rule           = $v.Rule
                TagName        = $v.TagName
                CurrentValue   = $v.CurrentValue
                Message        = $v.Message
                # Auto-fixable only when the tag is missing AND the standard provides a default
                AutoFixable    = ($v.Rule -eq 'MissingRequiredTag' -and $rule.DefaultValue)
                ProposedValue  = if ($v.Rule -eq 'MissingRequiredTag') { $rule.DefaultValue } else { $null }
            })
        }
    }
}

# --- 6. Audit mode: just emit and return ----------------------------------
if (-not $Remediate) {
    return $violations
}

# --- 7. Remediation mode --------------------------------------------------
# Only acts on AutoFixable violations. Anything ambiguous is left for human review.
$fixable = $violations | Where-Object AutoFixable
Write-Verbose "$($fixable.Count) of $($violations.Count) violations are auto-fixable."

# Group by resource so we batch tag updates per-resource (fewer API calls,
# avoids racing against ourselves on the same resource).
$byResource = $fixable | Group-Object ResourceId

foreach ($group in $byResource) {
    $resourceId = $group.Name
    $tagsToAdd  = @{}
    foreach ($v in $group.Group) { $tagsToAdd[$v.TagName] = $v.ProposedValue }

    $target = "$resourceId  ($((($tagsToAdd.GetEnumerator() |
                ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')))"

    if ($PSCmdlet.ShouldProcess($target, "Apply missing required tags")) {
        try {
            # -Operation Merge preserves existing tags; we only add what's missing.
            Update-AzTag -ResourceId $resourceId -Tag $tagsToAdd -Operation Merge -ErrorAction Stop | Out-Null
            Write-Verbose "Tagged: $resourceId"
        }
        catch {
            Write-Warning "Failed to tag $resourceId : $_"
        }
    }
}