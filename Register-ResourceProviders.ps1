<#
.SYNOPSIS
Registers selected Azure resource providers across subscriptions listed in a CSV.

.DESCRIPTION
Reads the two-column CSV created by Export-AccessibleSubscriptions.ps1 and
processes each subscription and explicitly supplied provider namespace. Already
registered providers are left unchanged. Providers that are not registered are
registered and polled until registration completes or the timeout expires.

The script uses the Azure CLI current cloud and login. It does not depend on a
PowerShell module from this repository. Use WhatIf to preview registration
without changing subscriptions.

Required permission: Microsoft.Resources/subscriptions/providers/register/action
at subscription scope, included in roles such as Contributor and Owner.

.PARAMETER InputPath
Path to a CSV with exactly two columns in this order: SubscriptionName,
SubscriptionId.

.PARAMETER ProviderNamespace
One or more provider namespaces to register, for example Microsoft.Compute and
Microsoft.Network. Only explicitly supplied namespaces are processed.

.PARAMETER OutputPath
Audit CSV output path. Defaults to a timestamped file beside this script.
Existing files are not overwritten.

.PARAMETER TimeoutSeconds
Maximum time to wait for each provider registration. Defaults to 600 seconds.

.PARAMETER PollIntervalSeconds
Delay between registration-state checks. Defaults to 10 seconds.

.EXAMPLE
    .\Register-ResourceProviders.ps1 `
        -InputPath .\subscriptions.csv `
        -ProviderNamespace Microsoft.Compute, Microsoft.Network `
        -WhatIf

.EXAMPLE
    .\Register-ResourceProviders.ps1 `
        -InputPath .\subscriptions.csv `
        -ProviderNamespace Microsoft.Compute, Microsoft.Network `
        -OutputPath .\resource-provider-registration.csv
#>

#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $InputPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if ($_ -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$') {
            throw "Invalid resource provider namespace: '$_'. Example: Microsoft.Compute."
        }
        $true
    })]
    [string[]] $ProviderNamespace,

    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path $PSScriptRoot ("resource-provider-registration-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))),

    [ValidateRange(30, 7200)]
    [int] $TimeoutSeconds = 600,

    [ValidateRange(1, 300)]
    [int] $PollIntervalSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-AzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) was not found on PATH. Install Azure CLI and log in to the correct cloud first.'
    }
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

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
    if ([string]::IsNullOrWhiteSpace($responseText)) {
        throw 'Azure CLI returned an empty response.'
    }

    ConvertFrom-Json -InputObject $responseText
}

function Resolve-OutputPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ResolvedInputPath
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($resolvedPath -eq $ResolvedInputPath) {
        throw 'InputPath and OutputPath must be different files.'
    }
    if (Test-Path -LiteralPath $resolvedPath) {
        throw "Output already exists. Choose a different OutputPath: $resolvedPath"
    }

    $resolvedPath
}

function Get-ProviderRegistrationState {
    param(
        [Parameter(Mandatory = $true)][string] $SubscriptionId,
        [Parameter(Mandatory = $true)][string] $Namespace
    )

    $provider = Invoke-AzCliJson -Arguments @(
        'provider', 'show',
        '--subscription', $SubscriptionId,
        '--namespace', $Namespace,
        '--query', '{namespace:namespace,registrationState:registrationState}'
    )
    [string] $provider.registrationState
}

$resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).ProviderPath
if (-not (Test-Path -LiteralPath $resolvedInputPath -PathType Leaf)) {
    throw 'InputPath must be a CSV file.'
}
$resolvedOutputPath = Resolve-OutputPath -Path $OutputPath -ResolvedInputPath $resolvedInputPath

$inputRows = @(Import-Csv -LiteralPath $resolvedInputPath -Encoding utf8)
if ($inputRows.Count -eq 0) {
    throw 'Input CSV must contain a header and at least one subscription row.'
}
$columns = @($inputRows[0].PSObject.Properties.Name)
if ($columns.Count -ne 2 -or $columns[0] -cne 'SubscriptionName' -or $columns[1] -cne 'SubscriptionId') {
    throw 'Input CSV must have exactly two columns, in order: SubscriptionName, SubscriptionId.'
}

$subscriptions = @(for ($index = 0; $index -lt $inputRows.Count; $index++) {
    $subscriptionName = ([string] $inputRows[$index].SubscriptionName).Trim()
    $subscriptionId = ([string] $inputRows[$index].SubscriptionId).Trim()
    $parsedId = [guid]::Empty
    if (-not $subscriptionName -or
        -not [guid]::TryParseExact($subscriptionId, 'D', [ref] $parsedId) -or
        $parsedId -eq [guid]::Empty) {
        throw "Invalid CSV data row $($index + 1): supply a subscription name and a non-empty GUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
    }

    [PSCustomObject][ordered]@{
        SubscriptionName = $subscriptionName
        SubscriptionId = $parsedId.ToString()
    }
})

$duplicateSubscriptionIds = @($subscriptions | Group-Object SubscriptionId | Where-Object Count -gt 1)
if ($duplicateSubscriptionIds.Count -gt 0) {
    throw "Input CSV contains duplicate subscription IDs. Each subscription must appear exactly once. Duplicate IDs: $($duplicateSubscriptionIds.Name -join ', ')"
}

$providerNamespaces = @($ProviderNamespace | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
Confirm-AzureCli
$cloud = Invoke-AzCliJson -Arguments @('cloud', 'show', '--query', '{name:name}')
if ([string]::IsNullOrWhiteSpace([string] $cloud.name)) {
    throw 'Azure CLI did not return the current cloud name.'
}
Write-Host "Using Azure CLI cloud '$($cloud.name)' for $($subscriptions.Count) subscription(s)."

$results = [System.Collections.Generic.List[object]]::new()
$failedRegistrations = 0
foreach ($subscription in $subscriptions) {
    foreach ($namespace in $providerNamespaces) {
        Write-Host "Checking '$namespace' in $($subscription.SubscriptionName) ($($subscription.SubscriptionId))..."
        $initialState = ''
        $finalState = ''
        $action = ''
        $status = 'Success'
        $errorMessage = ''

        try {
            $initialState = Get-ProviderRegistrationState `
                -SubscriptionId $subscription.SubscriptionId `
                -Namespace $namespace
            $finalState = $initialState

            if ($initialState -eq 'Registered') {
                $action = 'AlreadyRegistered'
            }
            elseif (-not $PSCmdlet.ShouldProcess(
                "$($subscription.SubscriptionName) ($($subscription.SubscriptionId))",
                "Register resource provider '$namespace'")) {
                $action = 'WouldRegister'
                $status = 'Preview'
            }
            else {
                $action = 'Register'
                Write-Host "Registering '$namespace'..."
                Invoke-AzCliJson -Arguments @(
                    'provider', 'register',
                    '--subscription', $subscription.SubscriptionId,
                    '--namespace', $namespace,
                    '--query', '{namespace:namespace,registrationState:registrationState}'
                ) | Out-Null

                $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                do {
                    $finalState = Get-ProviderRegistrationState `
                        -SubscriptionId $subscription.SubscriptionId `
                        -Namespace $namespace
                    if ($finalState -eq 'Registered') {
                        break
                    }
                    if ([DateTime]::UtcNow -ge $deadline) {
                        throw "Timed out after $TimeoutSeconds seconds waiting for registration. Last state: '$finalState'."
                    }
                    Start-Sleep -Seconds $PollIntervalSeconds
                } while ($true)
            }
        }
        catch {
            $status = 'Failed'
            $errorMessage = $_.Exception.Message
            $failedRegistrations++
            Write-Warning "$($subscription.SubscriptionId) / ${namespace}: $errorMessage"
        }

        $results.Add([PSCustomObject][ordered]@{
            SubscriptionName        = $subscription.SubscriptionName
            SubscriptionId          = $subscription.SubscriptionId
            AzureEnvironment        = [string] $cloud.name
            ProviderNamespace       = $namespace
            InitialRegistrationState = $initialState
            FinalRegistrationState  = $finalState
            Action                   = $action
            QueryStatus              = $status
            ErrorMessage             = $errorMessage
            ProcessedAtUtc           = [DateTime]::UtcNow.ToString('o')
        })
    }
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$results.ToArray() | Export-Csv -LiteralPath $resolvedOutputPath -NoTypeInformation -Encoding utf8BOM -NoClobber -WhatIf:$false
Write-Host "Exported $($results.Count) registration result(s) to $resolvedOutputPath"

if ($failedRegistrations -gt 0) {
    throw "$failedRegistrations provider registration query/operation(s) failed. Results and errors were saved to $resolvedOutputPath"
}
