#Requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path $PSScriptRoot ("subscriptions-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-InventoryAzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) was not found on PATH. Install Azure CLI and log in to the correct cloud first.'
    }
}

function Invoke-InventoryAzJson {
    param([string[]] $Arguments)

    $previousNativeCommandPreference = $PSNativeCommandUseErrorActionPreference
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $ErrorActionPreference = 'Continue'
        $response = & az @Arguments --output json --only-show-errors 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativeCommandPreference
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $responseText = ($response | Out-String).Trim()
    if ($exitCode -ne 0) {
        throw "Azure CLI exited with code ${exitCode}: $responseText"
    }
    if (-not $responseText) {
        throw 'Azure CLI returned an empty response.'
    }

    ConvertFrom-Json -InputObject $responseText
}

function Resolve-InventoryOutputPath {
    param([string] $OutputPath)

    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (Test-Path -LiteralPath $resolvedOutputPath) {
        throw "Output already exists. Choose a different OutputPath: $resolvedOutputPath"
    }
    $resolvedOutputPath
}

function ConvertTo-InventorySubscription {
    param(
        [string] $SubscriptionName,
        [string] $SubscriptionId
    )

    $subscriptionName = $SubscriptionName.Trim()
    $subscriptionId = $SubscriptionId.Trim()
    $parsedId = [guid]::Empty
    if (-not $subscriptionName -or -not [guid]::TryParseExact($subscriptionId, 'D', [ref] $parsedId) -or $parsedId -eq [guid]::Empty) {
        throw 'Azure CLI returned a subscription with an empty name or invalid ID.'
    }
    [PSCustomObject][ordered]@{
        SubscriptionName = $subscriptionName
        SubscriptionId = $parsedId.ToString()
    }
}

function Export-InventoryCsv {
    param(
        [object[]] $Rows,
        [string] $OutputPath
    )

    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $Rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8BOM -NoClobber
}

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