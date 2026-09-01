<#
.SYNOPSIS
Runs local, no-Azure tests for Link-PrivateEndpointPrivateDns.ps1.

.DESCRIPTION
Parses the standalone runbook, loads only its mapping variables and pure helper
functions, and verifies representative Azure China zone inference and
zone-config comparison behavior. No Azure login or resources are required.
#>

[CmdletBinding()]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RunbookPath = (Join-Path $PSScriptRoot 'Link-PrivateEndpointPrivateDns.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RunbookPath = (Resolve-Path -LiteralPath $RunbookPath).ProviderPath
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RunbookPath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw "Runbook parser errors: $(@($parseErrors | ForEach-Object { $_.Message }) -join ' | ')"
}

$requiredVariableNames = @(
    'AzureChinaPaaSPrivateDnsZonePatterns'
    'AzureChinaPublicDnsSuffixToPrivateDnsZones'
    'AzureChinaResourceGroupToPrivateDnsZones'
)
$assignmentAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $requiredVariableNames -contains $node.Left.VariablePath.UserPath
}, $true))

foreach ($variableName in $requiredVariableNames) {
    $assignmentAst = @($assignmentAsts | Where-Object { $_.Left.VariablePath.UserPath -eq $variableName })[0]
    if ($null -eq $assignmentAst) {
        throw "Could not find mapping variable '$variableName' in '$RunbookPath'."
    }

    Invoke-Expression $assignmentAst.Extent.Text
}

$requiredFunctionNames = @(
    'Get-AutomationVariableString'
    'Get-FirstAutomationVariableString'
    'Get-ObjectPropertyValue'
    'Import-RequiredAzModules'
    'Select-AzureChinaSubscription'
    'ConvertTo-NormalizedFqdn'
    'Test-AzureChinaPaaSPrivateDnsZoneName'
    'Get-PrivateDnsZoneGroupZoneIds'
    'Add-ZoneInference'
    'Get-InferredPrivateDnsZones'
    'Resolve-DestinationPrivateDnsZones'
    'Confirm-ResourceGroupExists'
    'Wait-PrivateDnsZoneReady'
    'ConvertTo-ArmPathSegment'
    'Get-PrivateDnsZoneGroupName'
    'New-PrivateDnsZoneGroupPath'
    'Wait-PrivateDnsZoneGroupDeleted'
    'Get-ZoneNameFromPrivateDnsZoneId'
    'Select-PrivateDnsZoneGroup'
    'ConvertTo-ComparableZoneConfigs'
    'Test-ZoneConfigSetsEqual'
    'New-ShortHash'
    'New-PrivateDnsZoneConfigName'
    'Set-PrivateEndpointPrivateDnsZoneGroup'
)
$functionAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))

foreach ($functionName in $requiredFunctionNames) {
    $functionAst = @($functionAsts | Where-Object { $_.Name -eq $functionName })[0]
    if ($null -eq $functionAst) {
        throw "Could not find function '$functionName' in '$RunbookPath'."
    }

    Invoke-Expression $functionAst.Extent.Text
}

$assertions = New-Object System.Collections.Generic.List[object]

function Add-Assertion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [bool]$Passed,

        [Parameter(Mandatory = $true)]
        [string]$Details
    )

    $assertions.Add([pscustomobject]@{
        Name    = $Name
        Passed  = $Passed
        Details = $Details
    })

    if (-not $Passed) {
        throw "Assertion failed: $Name. $Details"
    }

    Write-Host "PASS: $Name - $Details" -ForegroundColor Green
}

function Test-StringSetEqual {
    param(
        [string[]]$Actual,
        [string[]]$Expected
    )

    $actualValues = @($Actual | Sort-Object -Unique)
    $expectedValues = @($Expected | Sort-Object -Unique)
    if ($actualValues.Count -ne $expectedValues.Count) {
        return $false
    }

    foreach ($expectedValue in $expectedValues) {
        if ($actualValues -notcontains $expectedValue) {
            return $false
        }
    }

    return $true
}

$script:MockAutomationVariables = @{
    SyncPrivateEndpointPrivateDnsDestinationSubscriptionId = '22222222-2222-2222-2222-222222222222'
}

function Get-AutomationVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($script:MockAutomationVariables.ContainsKey($Name)) {
        return $script:MockAutomationVariables[$Name]
    }

    throw "Automation variable '$Name' was not found."
}

$sharedDestinationSubscriptionId = Get-FirstAutomationVariableString -Names @(
    'LinkPrivateEndpointPrivateDnsDestinationSubscriptionId'
    'SyncPrivateEndpointPrivateDnsDestinationSubscriptionId'
)
Add-Assertion `
    -Name 'SharedAutomationVariableIsUsedWhenDedicatedVariableIsMissing' `
    -Passed ($sharedDestinationSubscriptionId -eq '22222222-2222-2222-2222-222222222222') `
    -Details "ResolvedDestinationSubscriptionId='$sharedDestinationSubscriptionId'."

$script:MockAutomationVariables['LinkPrivateEndpointPrivateDnsDestinationSubscriptionId'] = '33333333-3333-3333-3333-333333333333'
$dedicatedDestinationSubscriptionId = Get-FirstAutomationVariableString -Names @(
    'LinkPrivateEndpointPrivateDnsDestinationSubscriptionId'
    'SyncPrivateEndpointPrivateDnsDestinationSubscriptionId'
)
Add-Assertion `
    -Name 'DedicatedAutomationVariableOverridesSharedFallback' `
    -Passed ($dedicatedDestinationSubscriptionId -eq '33333333-3333-3333-3333-333333333333') `
    -Details "ResolvedDestinationSubscriptionId='$dedicatedDestinationSubscriptionId'."

function Invoke-InferenceCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string[]]$Fqdns = @(),

        [object[]]$Connections = @(),

        [object[]]$ExistingZoneGroups = @(),

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedZones
    )

    $dnsDetails = [pscustomobject]@{ Fqdns = @($Fqdns) }
    $actual = @(Get-InferredPrivateDnsZones `
        -DnsDetails $dnsDetails `
        -Connections $Connections `
        -ExistingZoneGroups $ExistingZoneGroups)
    $actualZoneNames = @($actual | ForEach-Object { [string]$_.ZoneName })
    Add-Assertion `
        -Name $Name `
        -Passed (Test-StringSetEqual -Actual $actualZoneNames -Expected $ExpectedZones) `
        -Details "Expected='$($ExpectedZones -join ',')'; actual='$($actualZoneNames -join ',')'."
}

Invoke-InferenceCase `
    -Name 'StorageBlobFromFqdnAndGroupId' `
    -Fqdns @('account.blob.core.chinacloudapi.cn') `
    -Connections @([pscustomobject]@{
        ResourceType         = 'microsoft.storage/storageaccounts'
        GroupId              = 'blob'
        PrivateLinkServiceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/account'
    }) `
    -ExpectedZones @('privatelink.blob.core.chinacloudapi.cn')

Invoke-InferenceCase `
    -Name 'MySqlUsesMostSpecificFqdnSuffix' `
    -Fqdns @('server.mysql.database.chinacloudapi.cn') `
    -Connections @([pscustomobject]@{
        ResourceType         = 'microsoft.dbformysql/flexibleservers'
        GroupId              = 'mysqlServer'
        PrivateLinkServiceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.DBforMySQL/flexibleServers/server'
    }) `
    -ExpectedZones @('privatelink.mysql.database.chinacloudapi.cn')

Invoke-InferenceCase `
    -Name 'CosmosSqlUsesDocumentDbResourceProvider' `
    -Connections @([pscustomobject]@{
        ResourceType         = 'microsoft.documentdb/databaseaccounts'
        GroupId              = 'Sql'
        PrivateLinkServiceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/account'
    }) `
    -ExpectedZones @('privatelink.documents.azure.cn')

Invoke-InferenceCase `
    -Name 'AzureAiSearchFromResourceTypeAndGroupId' `
    -Connections @([pscustomobject]@{
        ResourceType         = 'microsoft.search/searchservices'
        GroupId              = 'searchService'
        PrivateLinkServiceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Search/searchServices/search'
    }) `
    -ExpectedZones @('privatelink.search.azure.cn')

Invoke-InferenceCase `
    -Name 'AzureAiSearchFromPublicFqdn' `
    -Fqdns @('search.search.azure.cn') `
    -ExpectedZones @('privatelink.search.azure.cn')

Invoke-InferenceCase `
    -Name 'CognitiveServicesFromResourceTypeAndGroupId' `
    -Connections @([pscustomobject]@{
        ResourceType         = 'microsoft.cognitiveservices/accounts'
        GroupId              = 'account'
        PrivateLinkServiceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/cognitive'
    }) `
    -ExpectedZones @('privatelink.cognitiveservices.azure.cn')

Invoke-InferenceCase `
    -Name 'CognitiveServicesFromPublicFqdn' `
    -Fqdns @('cognitive.cognitiveservices.azure.cn') `
    -ExpectedZones @('privatelink.cognitiveservices.azure.cn')

Invoke-InferenceCase `
    -Name 'AmlInfersBothZonesWithoutFqdn' `
    -Connections @([pscustomobject]@{
        ResourceType         = 'microsoft.machinelearningservices/workspaces'
        GroupId              = 'amlworkspace'
        PrivateLinkServiceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.MachineLearningServices/workspaces/ws'
    }) `
    -ExpectedZones @(
        'privatelink.api.ml.azure.cn'
        'privatelink.notebooks.chinacloudapi.cn'
    )

Invoke-InferenceCase `
    -Name 'IoTHubInfersDeviceAndBuiltInEventHubZones' `
    -Connections @([pscustomobject]@{
        ResourceType         = 'microsoft.devices/iothubs'
        GroupId              = 'iotHub'
        PrivateLinkServiceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Devices/IotHubs/hub'
    }) `
    -ExpectedZones @(
        'privatelink.azure-devices.cn'
        'privatelink.servicebus.chinacloudapi.cn'
    )

$script:ConnectedWithManagedIdentity = $false
$script:AzContextAutosaveDisabled = $false
$script:MockContextAutosaveDisableCount = 0
$script:MockConnectCount = 0
$script:MockSetContextCount = 0
$script:MockSelectedSubscriptionId = $null
$script:MockConnectSubscriptionId = $null
$script:MockConnectTenantId = $null
$script:MockConnectAccountId = $null
$script:MockConnectScope = $null
$script:MockSkippedContextPopulation = $false

function Import-RequiredAzModules {
}

function Disable-AzContextAutosave {
    [CmdletBinding()]
    param(
        [string]$Scope
    )

    $script:MockContextAutosaveDisableCount++
}

function Connect-AzAccount {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Environment,
        [switch]$Identity,
        [string]$AccountId,
        [string]$Tenant,
        [string]$Subscription,
        [switch]$SkipContextPopulation,
        [string]$Scope
    )

    $script:MockConnectCount++
    $script:MockConnectSubscriptionId = $Subscription
    $script:MockConnectTenantId = $Tenant
    $script:MockConnectAccountId = $AccountId
    $script:MockConnectScope = $Scope
    $script:MockSkippedContextPopulation = [bool]$SkipContextPopulation
}

function Set-AzContext {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SubscriptionId,
        [string]$Tenant,
        [string]$Scope
    )

    $script:MockSetContextCount++
    $script:MockSelectedSubscriptionId = $SubscriptionId
}

function Get-AzContext {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Environment  = [pscustomobject]@{ Name = 'AzureChinaCloud' }
        Subscription = [pscustomobject]@{ Id = $script:MockSelectedSubscriptionId }
        Tenant       = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' }
    }
}

$managedIdentitySubscriptionId = '11111111-1111-1111-1111-111111111111'
$managedIdentityTenantId = '00000000-0000-0000-0000-000000000000'
$managedIdentityClientId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
Select-AzureChinaSubscription `
    -SubscriptionId $managedIdentitySubscriptionId `
    -TenantId $managedIdentityTenantId `
    -UseManagedIdentityLogin $true `
    -IdentityAccountId $managedIdentityClientId | Out-Null
Select-AzureChinaSubscription `
    -SubscriptionId $managedIdentitySubscriptionId `
    -TenantId $managedIdentityTenantId `
    -UseManagedIdentityLogin $true `
    -IdentityAccountId $managedIdentityClientId | Out-Null
Add-Assertion `
    -Name 'ManagedIdentityLoginIsProcessScopedAndDeterministic' `
    -Passed ($script:MockContextAutosaveDisableCount -eq 1 -and
        $script:MockConnectCount -eq 1 -and
        $script:MockSetContextCount -eq 2 -and
        $script:MockSelectedSubscriptionId -eq $managedIdentitySubscriptionId -and
        $script:MockConnectSubscriptionId -eq $managedIdentitySubscriptionId -and
        $script:MockConnectTenantId -eq $managedIdentityTenantId -and
        $script:MockConnectAccountId -eq $managedIdentityClientId -and
        $script:MockConnectScope -eq 'Process' -and
        $script:MockSkippedContextPopulation) `
    -Details "DisableCount='$($script:MockContextAutosaveDisableCount)'; ConnectCount='$($script:MockConnectCount)'; SetContextCount='$($script:MockSetContextCount)'; Subscription='$($script:MockConnectSubscriptionId)'; Tenant='$($script:MockConnectTenantId)'; AccountId='$($script:MockConnectAccountId)'; Scope='$($script:MockConnectScope)'; SkipContextPopulation='$($script:MockSkippedContextPopulation)'."

$existingZoneGroup = [pscustomobject]@{
    properties = [pscustomobject]@{
        privateDnsZoneConfigs = @(
            [pscustomobject]@{
                name       = 'vault'
                properties = [pscustomobject]@{
                    privateDnsZoneId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.cn'
                }
            }
        )
    }
}
Invoke-InferenceCase `
    -Name 'ExistingZoneGroupProvidesInferenceEvidence' `
    -ExistingZoneGroups @($existingZoneGroup) `
    -ExpectedZones @('privatelink.vaultcore.azure.cn')

$existingConfig = [pscustomobject]@{
    name       = 'blob'
    properties = [pscustomobject]@{
        privateDnsZoneId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.chinacloudapi.cn'
    }
}
$desiredConfig = @{
    name       = 'blob'
    properties = @{
        privateDnsZoneId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.chinacloudapi.cn'
    }
}
Add-Assertion `
    -Name 'ZoneConfigComparisonAcceptsArmObjectsAndRequestHashtables' `
    -Passed (Test-ZoneConfigSetsEqual -Left @($existingConfig) -Right @($desiredConfig)) `
    -Details 'Equivalent ARM response objects and PUT request hashtables compare equal.'

$generatedConfigName = New-PrivateDnsZoneConfigName `
    -ZoneName 'privatelink.blob.core.chinacloudapi.cn' `
    -ZoneId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.chinacloudapi.cn' `
    -ExistingNames @()
Add-Assertion `
    -Name 'ZoneConfigNameIsDeterministicAndValid' `
    -Passed ($generatedConfigName -eq 'privatelink-blob-core-chinacloudapi-cn') `
    -Details "GeneratedName='$generatedConfigName'."

$inferredBlobZone = [pscustomobject]@{ ZoneName = 'privatelink.blob.core.chinacloudapi.cn' }
$uniqueDestinationZone = [pscustomobject]@{
    Name              = 'privatelink.blob.core.chinacloudapi.cn'
    ResourceGroupName = 'dns-one'
    Id                = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-one/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.chinacloudapi.cn'
}
$resolvedZones = @(Resolve-DestinationPrivateDnsZones `
    -SubscriptionId '22222222-2222-2222-2222-222222222222' `
    -InferredZones @($inferredBlobZone) `
    -ExistingZones @($uniqueDestinationZone) `
    -ResourceGroupLocation 'chinaeast2')
Add-Assertion `
    -Name 'SubscriptionScanSelectsUniqueExactZoneName' `
    -Passed ($resolvedZones.Count -eq 1 -and $resolvedZones[0].Id -eq $uniqueDestinationZone.Id) `
    -Details "ResolvedId='$([string]$resolvedZones[0].Id)'."

$duplicateZone = [pscustomobject]@{
    Name              = 'privatelink.blob.core.chinacloudapi.cn'
    ResourceGroupName = 'dns-two'
    Id                = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-two/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.chinacloudapi.cn'
}
$duplicateFailedSafely = $false
try {
    Resolve-DestinationPrivateDnsZones `
        -SubscriptionId '22222222-2222-2222-2222-222222222222' `
        -InferredZones @($inferredBlobZone) `
        -ExistingZones @($uniqueDestinationZone, $duplicateZone) `
        -ResourceGroupLocation 'chinaeast2' | Out-Null
}
catch {
    $duplicateFailedSafely = $_.Exception.Message -match 'multiple private DNS zones'
}
Add-Assertion `
    -Name 'SubscriptionScanRejectsDuplicateZoneNames' `
    -Passed $duplicateFailedSafely `
    -Details 'Duplicate exact-name matches require an explicit resource-group filter.'

$missingFailedSafely = $false
try {
    Resolve-DestinationPrivateDnsZones `
        -SubscriptionId '22222222-2222-2222-2222-222222222222' `
        -InferredZones @($inferredBlobZone) `
        -ExistingZones @() `
        -ResourceGroupLocation 'chinaeast2' | Out-Null
}
catch {
    $missingFailedSafely = $_.Exception.Message -match 'Supply DestinationPrivateDnsZoneResourceGroupName'
}
Add-Assertion `
    -Name 'SubscriptionScanDoesNotCreateWithoutResourceGroup' `
    -Passed $missingFailedSafely `
    -Details 'A missing zone fails safely when no creation resource group is configured.'

$NetworkApiVersion = '2023-09-01'
$PrivateDnsApiVersion = '2018-09-01'
$ResourceGroupApiVersion = '2021-04-01'
$ScriptCommand = $PSCmdlet
$script:MockZoneGroups = @()
$script:MockPutCalls = New-Object System.Collections.Generic.List[object]
$script:MockPrivateDnsZoneProvisioningState = $null

function Get-ArmPagedValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return @($script:MockZoneGroups)
}

function Invoke-ArmJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [string]$Path,

        [object]$Body,

        [int[]]$ExpectedStatusCode,

        [switch]$AllowNotFound
    )

    $script:MockPutCalls.Add([pscustomobject]@{
        Method = $Method
        Path   = $Path
        Body   = $Body
    })

    if ($Method -eq 'GET' -and $Path -match '/resourceGroups/[^/?]+\?api-version=2021-04-01$') {
        return [pscustomobject]@{ id = ($Path -replace '\?api-version=.+$') }
    }

    if ($Method -eq 'GET' -and
        $Path -match '/providers/Microsoft\.Network/privateDnsZones/[^/?]+\?api-version=' -and
        -not [string]::IsNullOrWhiteSpace($script:MockPrivateDnsZoneProvisioningState)) {
        return [pscustomobject]@{
            properties = [pscustomobject]@{
                provisioningState = $script:MockPrivateDnsZoneProvisioningState
            }
        }
    }
}

$script:MockPrivateDnsZoneProvisioningState = 'Succeeded'
$createdZone = @(Resolve-DestinationPrivateDnsZones `
    -SubscriptionId '22222222-2222-2222-2222-222222222222' `
    -InferredZones @($inferredBlobZone) `
    -ExistingZones @() `
    -ResourceGroupName 'target-dns' `
    -ResourceGroupLocation 'chinaeast2')
$zoneCreateCalls = @($script:MockPutCalls.ToArray() | Where-Object {
    $_.Method -eq 'PUT' -and $_.Path -match '/privateDnsZones/'
})
$zoneReadyCalls = @($script:MockPutCalls.ToArray() | Where-Object {
    $_.Method -eq 'GET' -and $_.Path -match '/privateDnsZones/'
})
Add-Assertion `
    -Name 'CreatedPrivateDnsZoneIsReadyBeforeUse' `
    -Passed ($createdZone.Count -eq 1 -and
        $zoneCreateCalls.Count -eq 1 -and
        $zoneReadyCalls.Count -eq 1 -and
        $createdZone[0].Id -eq '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/target-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.chinacloudapi.cn') `
    -Details "CreateCalls='$($zoneCreateCalls.Count)'; ReadyCalls='$($zoneReadyCalls.Count)'; ResolvedId='$([string]$createdZone[0].Id)'."
$script:MockPrivateDnsZoneProvisioningState = $null
$script:MockPutCalls.Clear()

$privateEndpoint = [pscustomobject]@{
    id   = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/app/providers/Microsoft.Network/privateEndpoints/pe-blob'
    name = 'pe-blob'
}
$sourceBlobZoneId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/source-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.chinacloudapi.cn'
$destinationBlobZone = [pscustomobject]@{
    Name              = 'privatelink.blob.core.chinacloudapi.cn'
    ResourceGroupName = 'target-dns'
    Id                = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/target-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.chinacloudapi.cn'
}
$unrelatedVaultZoneId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/source-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.cn'
$script:MockZoneGroups = @(
    [pscustomobject]@{
        id         = "$($privateEndpoint.id)/privateDnsZoneGroups/custom"
        name       = 'pe-blob/custom'
        properties = [pscustomobject]@{
            privateDnsZoneConfigs = @(
                [pscustomobject]@{
                    name       = 'blob'
                    properties = [pscustomobject]@{ privateDnsZoneId = $sourceBlobZoneId }
                }
                [pscustomobject]@{
                    name       = 'vault'
                    properties = [pscustomobject]@{ privateDnsZoneId = $unrelatedVaultZoneId }
                }
            )
        }
    }
)

$moveResult = Set-PrivateEndpointPrivateDnsZoneGroup `
    -PrivateEndpoint $privateEndpoint `
    -DestinationZones @($destinationBlobZone) `
    -RequestedGroupName 'default'
$putCalls = @($script:MockPutCalls.ToArray() | Where-Object { $_.Method -eq 'PUT' })
$removeZoneIds = @($putCalls[0].Body.properties.privateDnsZoneConfigs | ForEach-Object { [string]$_.properties.privateDnsZoneId })
$writtenConfigs = @($putCalls[1].Body.properties.privateDnsZoneConfigs)
$writtenZoneIds = @($writtenConfigs | ForEach-Object { [string]$_.properties.privateDnsZoneId })
Add-Assertion `
    -Name 'ZoneGroupMoveUsesExistingGroupAndPreservesUnrelatedConfig' `
    -Passed ($moveResult.Operation -eq 'ZoneGroupTwoPutMoveToDestination' -and
        $moveResult.GroupName -eq 'custom' -and
        $putCalls.Count -eq 2 -and
        $removeZoneIds.Count -eq 1 -and
        $removeZoneIds -contains $unrelatedVaultZoneId -and
        $writtenZoneIds -contains $destinationBlobZone.Id -and
        $writtenZoneIds -contains $unrelatedVaultZoneId -and
        $writtenZoneIds -notcontains $sourceBlobZoneId) `
    -Details "Operation='$($moveResult.Operation)'; Group='$($moveResult.GroupName)'; WrittenZoneIds='$($writtenZoneIds -join ',')'."

$script:MockPutCalls.Clear()
$script:MockZoneGroups = @(
    [pscustomobject]@{
        id         = "$($privateEndpoint.id)/privateDnsZoneGroups/custom"
        name       = 'pe-blob/custom'
        properties = [pscustomobject]@{
            privateDnsZoneConfigs = @(
                [pscustomobject]@{
                    name       = 'blob'
                    properties = [pscustomobject]@{ privateDnsZoneId = $sourceBlobZoneId }
                }
            )
        }
    }
)
$soleMoveResult = Set-PrivateEndpointPrivateDnsZoneGroup `
    -PrivateEndpoint $privateEndpoint `
    -DestinationZones @($destinationBlobZone) `
    -RequestedGroupName 'default'
$soleMoveCalls = @($script:MockPutCalls.ToArray())
Add-Assertion `
    -Name 'SoleConfigMoveDeletesWaitsAndRecreatesGroup' `
    -Passed ($soleMoveResult.Operation -eq 'ZoneGroupDeleteCreateMoveToDestination' -and
        $soleMoveCalls.Count -eq 3 -and
        $soleMoveCalls[0].Method -eq 'DELETE' -and
        $soleMoveCalls[1].Method -eq 'GET' -and
        $soleMoveCalls[2].Method -eq 'PUT' -and
        @($soleMoveCalls[2].Body.properties.privateDnsZoneConfigs).Count -eq 1 -and
        [string]$soleMoveCalls[2].Body.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId -eq $destinationBlobZone.Id) `
    -Details "Operation='$($soleMoveResult.Operation)'; Methods='$(@($soleMoveCalls.Method) -join ',')'."

$script:MockPutCalls.Clear()
$script:MockZoneGroups = @(
    [pscustomobject]@{
        id         = "$($privateEndpoint.id)/privateDnsZoneGroups/custom"
        name       = 'pe-blob/custom'
        properties = [pscustomobject]@{
            privateDnsZoneConfigs = @(
                [pscustomobject]@{
                    name       = 'blob'
                    properties = [pscustomobject]@{ privateDnsZoneId = $destinationBlobZone.Id }
                }
            )
        }
    }
)
$noChangeResult = Set-PrivateEndpointPrivateDnsZoneGroup `
    -PrivateEndpoint $privateEndpoint `
    -DestinationZones @($destinationBlobZone) `
    -RequestedGroupName 'default'
Add-Assertion `
    -Name 'ZoneGroupUpdateIsIdempotent' `
    -Passed ($noChangeResult.Operation -eq 'ZoneGroupNoChange' -and
        -not $noChangeResult.Changed -and
        $script:MockPutCalls.Count -eq 0) `
    -Details "Operation='$($noChangeResult.Operation)'; Changed='$($noChangeResult.Changed)'; PutCalls='$($script:MockPutCalls.Count)'."

[pscustomobject]@{
    RunbookPath   = $RunbookPath
    AssertionCount = $assertions.Count
    Passed        = @($assertions | Where-Object { $_.Passed }).Count
    Failed        = @($assertions | Where-Object { -not $_.Passed }).Count
    Assertions    = @($assertions.ToArray())
}
