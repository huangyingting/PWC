#Requires -Version 7.0

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
        [string] $ErrorMessage = 'Azure CLI returned a subscription with an empty name or invalid ID.'
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

Export-ModuleMember -Function Confirm-InventoryAzureCli, Invoke-InventoryAzJson, Resolve-InventoryOutputPath, ConvertTo-InventorySubscription, Export-InventoryCsv