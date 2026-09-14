#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $InputPath,

    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path $PSScriptRoot ("registered-resource-providers-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
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
    param(
        [string] $OutputPath,
        [string] $InputPath
    )

    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if ($InputPath -and $InputPath -eq $resolvedOutputPath) {
        throw 'InputPath and OutputPath must be different files.'
    }
    if (Test-Path -LiteralPath $resolvedOutputPath) {
        throw "Output already exists. Choose a different OutputPath: $resolvedOutputPath"
    }
    $resolvedOutputPath
}

function ConvertTo-InventorySubscription {
    param(
        [string] $SubscriptionName,
        [string] $SubscriptionId,
        [string] $ErrorMessage
    )

    $subscriptionName = $SubscriptionName.Trim()
    $subscriptionId = $SubscriptionId.Trim()
    $parsedId = [guid]::Empty
    if (-not $subscriptionName -or -not [guid]::TryParseExact($subscriptionId, 'D', [ref] $parsedId) -or $parsedId -eq [guid]::Empty) {
        throw $ErrorMessage
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

$resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).ProviderPath
if (-not (Test-Path -LiteralPath $resolvedInputPath -PathType Leaf)) {
    throw 'InputPath must be a CSV file.'
}
$resolvedOutputPath = Resolve-InventoryOutputPath -OutputPath $OutputPath -InputPath $resolvedInputPath

$inputRows = @(Import-Csv -LiteralPath $resolvedInputPath -Encoding utf8)
if ($inputRows.Count -eq 0) {
    throw 'Input CSV must contain a header and at least one subscription row.'
}
$columns = @($inputRows[0].PSObject.Properties.Name)
if ($columns.Count -ne 2 -or $columns[0] -cne 'SubscriptionName' -or $columns[1] -cne 'SubscriptionId') {
    throw 'Input CSV must have exactly two columns, in order: SubscriptionName, SubscriptionId.'
}

$subscriptions = @(for ($index = 0; $index -lt $inputRows.Count; $index++) {
    ConvertTo-InventorySubscription -SubscriptionName ([string] $inputRows[$index].($columns[0])) `
        -SubscriptionId ([string] $inputRows[$index].($columns[1])) `
        -ErrorMessage "Invalid CSV data row $($index + 1): supply a subscription name and a non-empty GUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
})
$duplicateSubscriptionIds = @($subscriptions | Group-Object SubscriptionId | Where-Object Count -gt 1)
if ($duplicateSubscriptionIds.Count -gt 0) {
    throw "Input CSV contains duplicate subscription IDs. Each subscription must appear exactly once. Duplicate IDs: $($duplicateSubscriptionIds.Name -join ', ')"
}

Confirm-InventoryAzureCli

$results = [System.Collections.Generic.List[object]]::new()
$failedSubscriptions = 0
foreach ($subscription in $subscriptions) {
    Write-Host "Querying $($subscription.SubscriptionName) ($($subscription.SubscriptionId))..."
    $status = 'Success'
    $errorMessage = ''
    $registeredProviders = @()
    try {
        $providers = @(Invoke-InventoryAzJson -Arguments @('provider', 'list', '--subscription', $subscription.SubscriptionId,
            '--query', '[].{namespace:namespace,registrationState:registrationState}'))
        $registeredProviders = @($providers |
            Where-Object { $_.registrationState -eq 'Registered' } |
            Sort-Object namespace -Unique)
        if ($registeredProviders.Count -eq 0) {
            $status = 'NoRegisteredProviders'
        }
    }
    catch {
        $status = 'Failed'
        $errorMessage = $_.Exception.Message
        $failedSubscriptions++
        Write-Warning "Subscription $($subscription.SubscriptionId): $errorMessage"
    }

    if ($status -ne 'Success') {
        $registeredProviders = @([PSCustomObject]@{ namespace = ''; registrationState = '' })
    }
    foreach ($provider in $registeredProviders) {
        $results.Add([PSCustomObject][ordered]@{
            SubscriptionName = $subscription.SubscriptionName
            SubscriptionId = $subscription.SubscriptionId
            ProviderNamespace = $provider.namespace
            RegistrationState = $provider.registrationState
            QueryStatus = $status
            ErrorMessage = $errorMessage
        })
    }
}

Export-InventoryCsv -Rows $results.ToArray() -OutputPath $resolvedOutputPath
Write-Host "Exported $($results.Count) rows for $($subscriptions.Count) subscriptions to $resolvedOutputPath"
if ($failedSubscriptions -gt 0) {
    throw "$failedSubscriptions subscription query/queries failed. Partial results and error details were saved to $resolvedOutputPath"
}