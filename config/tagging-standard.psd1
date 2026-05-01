# config/tagging-standard.psd1
@{
    # Tags every resource MUST have. If missing, it's a violation.
    RequiredTags = @{

        Environment = @{
            AllowedValues = @('dev', 'test', 'staging', 'prod')
            DefaultValue  = $null      # no default — must be set explicitly
            CaseSensitive = $false
        }

        Owner = @{
            # No AllowedValues = any non-empty string is OK
            AllowedValues = $null
            DefaultValue  = $null
            CaseSensitive = $true      # 'alice@x.com' != 'Alice@X.com'
        }

        CostCenter = @{
            # Pattern-based validation, e.g. 'CC-1234'
            Pattern       = '^CC-\d{4}$'
            DefaultValue  = $null
            CaseSensitive = $true
        }

        ManagedBy = @{
            AllowedValues = @('terraform', 'bicep', 'manual', 'pipeline')
            DefaultValue  = 'manual'   # safe to auto-apply when missing
            CaseSensitive = $false
        }
    }

    # Resource types the standard does NOT apply to.
    # Default Microsoft-created resources, classic resources, hidden types.
    ExcludedResourceTypes = @(
        'microsoft.resources/deployments',
        'microsoft.resources/deploymentscripts',
        'microsoft.classiccompute/*',
        'microsoft.classicstorage/*',
        'microsoft.classicnetwork/*'
    )

    # Resource group name patterns to skip (regex).
    ExcludedResourceGroupPatterns = @(
        '^NetworkWatcherRG$',
        '^DefaultResourceGroup-.+$',
        '^MC_.+$',                # AKS-managed RGs
        '^databricks-rg-.+$'      # Databricks-managed RGs
    )
}