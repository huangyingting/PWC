#Requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path $PSScriptRoot ("subscriptions-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ResourceProviderInventory.Common.psm1') -Scope Local

$resolvedOutputPath = Resolve-InventoryOutputPath -OutputPath $OutputPath
Confirm-InventoryAzureCli

$cloud = Invoke-InventoryAzJson -Arguments @('cloud', 'show')
if ([string]::IsNullOrWhiteSpace($cloud.name)) {
    throw 'Azure CLI did not return the current cloud name.'
}
Write-Host "Refreshing accessible subscriptions in $($cloud.name)..."
$accounts = @(Invoke-InventoryAzJson -Arguments @('account', 'list', '--all', '--refresh'))

$subscriptions = @($accounts | Where-Object {
        $cloudNameProperty = $_.PSObject.Properties['cloudName']
        $environmentNameProperty = $_.PSObject.Properties['environmentName']
        $stateProperty = $_.PSObject.Properties['state']
        $accountCloudName = if ($cloudNameProperty) {
            [string] $cloudNameProperty.Value
        }
        elseif ($environmentNameProperty) {
            [string] $environmentNameProperty.Value
        }
        else {
            ''
        }
        $accountState = if ($stateProperty) { [string] $stateProperty.Value } else { '' }

        $accountCloudName -eq $cloud.name -and $accountState -eq 'Enabled'
    } |
    Sort-Object id -Unique | ForEach-Object {
        ConvertTo-InventorySubscription -SubscriptionName ([string] $_.name) -SubscriptionId ([string] $_.id)
    } | Sort-Object SubscriptionName, SubscriptionId)

if ($subscriptions.Count -eq 0) {
    throw "No enabled accessible subscriptions were returned for $($cloud.name). Check your Azure CLI login and permissions. No CSV was created."
}

Export-InventoryCsv -Rows $subscriptions -OutputPath $resolvedOutputPath
Write-Host "Exported $($subscriptions.Count) subscriptions to $resolvedOutputPath"