<#
.SYNOPSIS
Replays a synthetic Public IP state through the real AzAPI provider offline.
.DESCRIPTION
The seed state comes from a mocked Terraform test apply. The script adds the
AzAPI v2.13.0 private ignore_body_changes value and plans with refresh disabled
against loopback endpoints. It verifies that the non-default forwarded path
does not create an output-only update, while retry and timeout settings remain
the same in the control case. This exercises AzAPI ModifyPlan without Azure,
but does not exercise ARM refresh, API behavior, or live convergence.
#>
[CmdletBinding()]
param(
    [string] $EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) "public-ip-output-plan-$([guid]::NewGuid())")
)

$ErrorActionPreference = 'Stop'
$modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "public-ip-output-plan-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $EvidencePath, $sandbox
$EvidencePath = (Resolve-Path $EvidencePath).Path

function Invoke-Terraform {
    param([string[]] $Arguments, [string] $LogName)
    $result = & terraform @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $result | Set-Content (Join-Path $EvidencePath $LogName)
    if ($exitCode -ne 0) {
        throw "terraform $($Arguments -join ' ') exited $exitCode. See $(Join-Path $EvidencePath $LogName)."
    }
    return $result
}

function Get-DynamicType {
    param($Value)
    if ($null -eq $Value) { return 'dynamic' }
    if ($Value -is [bool]) { return 'bool' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [System.Collections.IDictionary]) {
        $fields = @{}
        foreach ($key in $Value.Keys) { $fields[$key] = Get-DynamicType $Value[$key] }
        return ,@('object', $fields)
    }
    if ($Value -is [array]) {
        $elements = @()
        foreach ($element in $Value) { $elements += ,(Get-DynamicType $element) }
        return ,@('tuple', $elements)
    }
    return 'number'
}

function Get-UnknownPaths {
    param($Value, [string] $Path = '')
    if ($Value -is [bool]) {
        if ($Value -and $Path) { return $Path }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $childPath = if ($Path) { "$Path.$key" } else { [string]$key }
            Get-UnknownPaths $Value[$key] $childPath
        }
        return
    }
    if ($Value -is [array]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            Get-UnknownPaths $Value[$index] "$Path[$index]"
        }
    }
}

function New-SyntheticState {
    param($Seed, [bool] $StoreIgnoreBodyChanges)

    $paths = @('properties.idleTimeoutInMinutes')
    $privateMap = @{}
    if ($StoreIgnoreBodyChanges) {
        $pathsJson = ConvertTo-Json -InputObject $paths -Compress
        $privateMap.ignore_body_changes = [Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes($pathsJson)
        )
    }
    $private = [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes(($privateMap | ConvertTo-Json -Compress))
    )

    $resources = foreach ($resource in ($Seed.root_module.resources | Where-Object mode -eq managed)) {
        $schema = $Seed.provider_schemas[$resource.provider_name]
        $block = $schema.resource_schemas[$resource.type].block
        $attributes = $resource.values

        if ($resource.type -eq 'azapi_resource' -and $resource.name -eq 'this') {
            $attributes.id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-output-plan-regression'
            $attributes.output = @{}
            $attributes.response_export_values = @()
            $attributes.retry = @{
                error_message_regex   = @('RepairTestRetryable')
                interval_seconds      = 3
                max_interval_seconds  = 15
                multiplier            = 1.5
                randomization_factor  = 0.5
            }
            $attributes.tags = @{ test = 'real-provider-output-plan' }
            $attributes.timeouts = @{
                create = '45m'
                delete = '46m'
                read   = '2m'
                update = '44m'
            }
        }

        foreach ($key in @($attributes.Keys)) {
            if ($block.attributes[$key].type -eq 'dynamic' -and $null -ne $attributes[$key]) {
                $attributes[$key] = @{
                    value = $attributes[$key]
                    type  = Get-DynamicType $attributes[$key]
                }
            }
        }

        $instance = @{
            schema_version      = $resource.schema_version
            attributes          = $attributes
            sensitive_attributes = @()
        }
        if ($resource.type -eq 'azapi_resource' -and $resource.name -eq 'this' -and $StoreIgnoreBodyChanges) {
            $instance.private = $private
        }
        if ($resource.Contains('index')) { $instance.index_key = $resource.index }

        @{
            mode      = $resource.mode
            type      = $resource.type
            name      = $resource.name
            provider  = "provider[`"$($resource.provider_name)`"]"
            instances = @($instance)
        }
    }

    return @{
        version           = 4
        terraform_version = (& terraform version -json | ConvertFrom-Json).terraform_version
        serial            = 1
        lineage           = [guid]::NewGuid().ToString()
        outputs           = @{}
        resources         = @($resources)
    }
}

$originalLocation = Get-Location
try {
    Set-Location $modulePath
    $events = Invoke-Terraform -Arguments @(
        'test', '-test-directory=tests\unit',
        '-filter=tests\unit\bodies_and_writers.tftest.hcl', '-verbose', '-json'
    ) -LogName 'mocked-seed.jsonl'
    $seed = $null
    foreach ($line in $events) {
        $event = $line | ConvertFrom-Json -AsHashtable -Depth 100
        if ($event.type -eq 'test_state' -and $event.'@testrun' -eq 'seed_public_ip_for_real_provider_output_plan') {
            $seed = $event.test_state
        }
    }
    if ($null -eq $seed) { throw 'The mocked test did not produce the required Public IP seed state.' }

    Copy-Item (Join-Path $modulePath '*.tf') $sandbox
    @'
provider "azapi" {
  subscription_id            = "00000000-0000-0000-0000-000000000001"
  tenant_id                  = "00000000-0000-0000-0000-000000000002"
  client_id                  = "00000000-0000-0000-0000-000000000003"
  client_secret              = "offline-test-placeholder"
  use_cli                    = false
  use_msi                    = false
  use_oidc                   = false
  use_aks_workload_identity  = false
  skip_provider_registration = true
  enable_preflight           = false
  ignore_no_op_changes       = false
  disable_instance_discovery = true
  endpoint = [{
    active_directory_authority_host = "https://127.0.0.1:1"
    resource_manager_endpoint       = "https://127.0.0.1:1"
    resource_manager_audience       = "https://127.0.0.1:1"
  }]
}
'@ | Set-Content (Join-Path $sandbox 'offline-provider.tf')
    @'
data "azapi_resource" "this" {
  count = 0
}

output "public_ip_address" {
  value = null
}
'@ | Set-Content (Join-Path $sandbox 'offline_override.tf')
    if (Test-Path (Join-Path $modulePath '.terraform.lock.hcl')) {
        Copy-Item (Join-Path $modulePath '.terraform.lock.hcl') $sandbox
    }

    Set-Location $sandbox
    $null = Invoke-Terraform -Arguments @('init', '-backend=false', '-input=false', '-no-color') -LogName 'init.log'

    $cases = @(
        @{ Name = 'forwarded_ignore_body_changes'; StoreIgnoreBodyChanges = $true; IgnoreBodyChanges = @{ network_public_ip_addresses = @('properties.idleTimeoutInMinutes') } },
        @{ Name = 'default_ignore_body_changes'; StoreIgnoreBodyChanges = $false; IgnoreBodyChanges = @{ network_public_ip_addresses = @() } }
    )
    $results = foreach ($case in $cases) {
        $caseSeed = $seed | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
        New-SyntheticState $caseSeed $case.StoreIgnoreBodyChanges |
            ConvertTo-Json -Depth 100 |
            Set-Content 'terraform.tfstate'

        @{
            enable_telemetry    = $false
            location            = 'centralindia'
            name                = 'pip-output-plan-regression'
            parent_id           = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test'
            zones               = @()
            tags                = @{ test = 'real-provider-output-plan' }
            ignore_body_changes = $case.IgnoreBodyChanges
            retry               = @{
                error_message_regex   = @('RepairTestRetryable')
                interval_seconds      = 3
                max_interval_seconds  = 15
            }
            timeouts = @{
                create = '45m'
                delete = '46m'
                read   = '2m'
                update = '44m'
            }
        } | ConvertTo-Json -Depth 100 | Set-Content 'case.tfvars.json'

        $null = Invoke-Terraform -Arguments @(
            'plan', '-refresh=false', '-input=false', '-no-color',
            '-var-file=case.tfvars.json', '-out=case.tfplan'
        ) -LogName "$($case.Name).log"
        $json = Invoke-Terraform -Arguments @('show', '-json', 'case.tfplan') -LogName "$($case.Name).json"
        $plan = $json | ConvertFrom-Json -AsHashtable -Depth 100
        $change = $plan.resource_changes | Where-Object address -eq 'azapi_resource.this'

        $changedFields = @()
        if ($null -ne $change) {
            $changedFields += @(Get-UnknownPaths $change.change.after_unknown)
            foreach ($key in $change.change.before.Keys) {
                if ($key -notin $changedFields -and
                    (ConvertTo-Json $change.change.before[$key] -Depth 100 -Compress) -ne
                    (ConvertTo-Json $change.change.after[$key] -Depth 100 -Compress)) {
                    $changedFields += $key
                }
            }
        }
        $actions = if ($null -eq $change) { 'no-op' } else { $change.change.actions -join ',' }
        [pscustomobject]@{
            Case          = $case.Name
            Actions       = $actions
            ChangedFields = ($changedFields | Sort-Object -Unique) -join ','
            Passed        = ($actions -eq 'no-op')
        }
    }

    $results | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $EvidencePath 'results.json')
    $results | Format-Table -AutoSize
    Write-Host "Evidence: $EvidencePath"
    if ($results.Passed -contains $false) {
        throw 'The real-provider Public IP output plan regression failed.'
    }
} finally {
    Set-Location $originalLocation
    [Environment]::CurrentDirectory = $originalLocation.Path
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}
