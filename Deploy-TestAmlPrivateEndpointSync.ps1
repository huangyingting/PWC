<#
.SYNOPSIS
Deploys Azure Machine Learning with a private endpoint and tests private DNS synchronization.

.DESCRIPTION
Creates an isolated Azure China test environment in a source subscription with
an Azure Machine Learning workspace, its required dependent resources, a virtual
network, a private endpoint, and both Azure Machine Learning private DNS zones.
It then runs Sync-PrivateEndpointPrivateDns.ps1 against an isolated destination
resource group and verifies that:
- the workspace and private endpoint provision successfully;
- Azure creates source A records in both Machine Learning private DNS zones;
- the sync script matches the private endpoint for both zones;
- both private DNS zone group configs move to the destination subscription;
- Azure creates matching destination A records for both zones; and
- zone-group-managed records do not receive direct-sync provenance TXT records.

When synchronization is enabled, the source and destination subscriptions must
be in the same Microsoft Entra tenant. Test resource groups are removed by
default, including when the test fails. Use -KeepResources to retain them for
investigation.

Use -SkipSync to deploy and validate only the source Azure Machine Learning
workspace, private endpoint, and private DNS resources. This mode does not
access the destination subscription or invoke the sync script, and it retains
the successfully deployed source resource group.

.EXAMPLE
    .\Deploy-TestAmlPrivateEndpointSync.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222"

Deploy, test, write the JSON report, and remove both test resource groups.

.EXAMPLE
    .\Deploy-TestAmlPrivateEndpointSync.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -KeepResources

Retain both resource groups after the test for troubleshooting.

.EXAMPLE
    .\Deploy-TestAmlPrivateEndpointSync.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -SkipSync

Deploy Azure Machine Learning with a private endpoint, validate the source
resources, retain them, and do not run private DNS synchronization.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceSubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationSubscriptionId = '65a9c0da-4f85-47ba-ac0f-7401cbe43205',

    [Parameter()]
    [ValidateSet('chinaeast2', 'chinanorth3')]
    [string]$Location = 'chinaeast2',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourceTenantId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationTenantId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$NameSuffix,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourceResourceGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationResourceGroupName,

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SyncScriptPath = (Join-Path $PSScriptRoot 'Sync-PrivateEndpointPrivateDns.ps1'),

    [Parameter()]
    [ValidateRange(60, 1800)]
    [int]$DnsRecordTimeoutSeconds = 600,

    [Parameter()]
    [ValidateRange(60, 1800)]
    [int]$ProviderRegistrationTimeoutSeconds = 600,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PSScriptRoot 'aml-private-endpoint-sync-test.json'),

    [switch]$SkipSync,

    [switch]$KeepResources
)

#requires -Modules Az.Accounts, Az.Resources

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceApiVersion = '2024-10-01'
$PrivateDnsApiVersion = '2018-09-01'
$NetworkApiVersion = '2023-09-01'
$PrivateDnsZoneGroupName = 'default'
$PrivateLinkGroupId = 'amlworkspace'
$ProvenanceTxtRecordMarker = 'sync-private-endpoint-private-dns:v1'
$AmlPrivateDnsZoneNames = @(
    'privatelink.api.ml.azure.cn'
    'privatelink.notebooks.chinacloudapi.cn'
)
$script:AmlSyncTestAssertions = New-Object System.Collections.Generic.List[object]

function Import-RequiredAzModules {
    foreach ($moduleName in @('Az.Accounts', 'Az.Resources')) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            throw "$moduleName is required. Install it with: Install-Module $moduleName -Scope CurrentUser"
        }

        Import-Module $moduleName -ErrorAction Stop
    }
}

function Select-AzureChinaSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [string]$TenantId
    )

    $connectParameters = @{
        Environment = 'AzureChinaCloud'
        ErrorAction = 'Stop'
    }
    $contextParameters = @{
        SubscriptionId = $SubscriptionId
        ErrorAction    = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectParameters['Tenant'] = $TenantId
        $contextParameters['Tenant'] = $TenantId
    }

    try {
        $currentContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $currentContext -or $currentContext.Environment.Name -ne 'AzureChinaCloud') {
            Connect-AzAccount @connectParameters | Out-Null
        }

        Set-AzContext @contextParameters | Out-Null
    }
    catch {
        Connect-AzAccount @connectParameters | Out-Null
        Set-AzContext @contextParameters | Out-Null
    }

    $selectedContext = Get-AzContext -ErrorAction Stop
    if ($selectedContext.Environment.Name -ne 'AzureChinaCloud') {
        throw "Selected Azure context is '$($selectedContext.Environment.Name)', expected 'AzureChinaCloud'."
    }

    if ($selectedContext.Subscription.Id -ne $SubscriptionId) {
        throw "Selected subscription is '$($selectedContext.Subscription.Id)', expected '$SubscriptionId'."
    }

    return $selectedContext
}

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function ConvertTo-ArmPathSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [System.Uri]::EscapeDataString($Value)
}

function Invoke-ArmGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$AllowNotFound
    )

    try {
        $response = Invoke-AzRestMethod -Method GET -Path $Path -ErrorAction Stop
    }
    catch {
        if ($AllowNotFound -and $_.Exception.Message -match '\b404\b') {
            return $null
        }

        throw
    }

    $statusCode = [int]$response.StatusCode
    if ($AllowNotFound -and $statusCode -eq 404) {
        return $null
    }

    if ($statusCode -ne 200) {
        throw "ARM GET failed for '$Path'. Status: $statusCode. Response: $($response.Content)"
    }

    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

function Confirm-ResourceProviderRegistered {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ProviderNamespace,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $providerSegment = ConvertTo-ArmPathSegment -Value $ProviderNamespace
    $providerPath = "/subscriptions/$SubscriptionId/providers/${providerSegment}?api-version=2021-04-01"
    $providerResponse = Invoke-AzRestMethod -Method GET -Path $providerPath -ErrorAction Stop
    if ([int]$providerResponse.StatusCode -ne 200) {
        throw "Could not query resource provider '$ProviderNamespace': HTTP $($providerResponse.StatusCode) $($providerResponse.Content)"
    }

    $provider = $providerResponse.Content | ConvertFrom-Json
    if ([string]$provider.registrationState -eq 'Registered') {
        return [string]$provider.registrationState
    }

    Write-Host "Registering resource provider '$ProviderNamespace'..."
    $registrationPath = "/subscriptions/$SubscriptionId/providers/${providerSegment}/register?api-version=2021-04-01"
    $registrationResponse = Invoke-AzRestMethod -Method POST -Path $registrationPath -Payload '{}' -ErrorAction Stop
    if ([int]$registrationResponse.StatusCode -notin @(200, 201, 202)) {
        throw "Resource provider registration failed for '$ProviderNamespace': HTTP $($registrationResponse.StatusCode) $($registrationResponse.Content)"
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $providerResponse = Invoke-AzRestMethod -Method GET -Path $providerPath -ErrorAction Stop
        $provider = $providerResponse.Content | ConvertFrom-Json
        $registrationState = [string]$provider.registrationState
        if ($registrationState -eq 'Registered') {
            return $registrationState
        }

        if ((Get-Date) -ge $deadline) {
            break
        }

        Start-Sleep -Seconds 10
    } while ($true)

    throw "Timed out after $TimeoutSeconds seconds waiting for resource provider '$ProviderNamespace' to register. Last state: '$registrationState'."
}

function New-PrivateDnsRecordPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [ValidateSet('A', 'TXT')]
        [string]$RecordType = 'A',

        [string]$RecordName
    )

    $zoneSegment = ConvertTo-ArmPathSegment -Value $ZoneName
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/privateDnsZones/$zoneSegment/$RecordType"

    if (-not [string]::IsNullOrWhiteSpace($RecordName)) {
        $recordSegment = ConvertTo-ArmPathSegment -Value $RecordName
        $path = "$path/$recordSegment"
    }

    return "${path}?api-version=$PrivateDnsApiVersion"
}

function Get-PrivateDnsARecordRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName
    )

    $path = New-PrivateDnsRecordPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ZoneName $ZoneName
    $response = Invoke-ArmGet -Path $path
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($recordSet in @(Get-ObjectPropertyValue -InputObject $response -Name 'value')) {
        if ($null -eq $recordSet) {
            continue
        }

        $properties = Get-ObjectPropertyValue -InputObject $recordSet -Name 'properties'
        $ipAddresses = @((Get-ObjectPropertyValue -InputObject $properties -Name 'aRecords') | ForEach-Object { [string]$_.ipv4Address } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($ipAddresses.Count -eq 0) {
            continue
        }

        $rows.Add([pscustomobject]@{
            ZoneName      = $ZoneName
            RecordName    = [string]$recordSet.name
            IPv4Addresses = @($ipAddresses)
            TTL           = [int](Get-ObjectPropertyValue -InputObject $properties -Name 'ttl')
        })
    }

    return $rows
}

function Wait-PrivateDnsARecordsByAnyIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [Parameter(Mandatory = $true)]
        [string[]]$CandidateIpAddresses,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $rows = @(Get-PrivateDnsARecordRows `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -ZoneName $ZoneName)
        $matchingRows = @($rows | Where-Object {
            $rowIpAddresses = @($_.IPv4Addresses)
            @($CandidateIpAddresses | Where-Object { $rowIpAddresses -contains $_ }).Count -gt 0
        })

        if ($matchingRows.Count -gt 0) {
            return $matchingRows
        }

        if ((Get-Date) -ge $deadline) {
            break
        }

        Start-Sleep -Seconds 10
    } while ($true)

    throw "Timed out after $TimeoutSeconds seconds waiting for a private DNS A record in '$ResourceGroupName/$ZoneName' with one of these IP addresses: $($CandidateIpAddresses -join ', ')."
}

function Wait-PrivateDnsARecordsByIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedIpAddresses,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $rows = @(Get-PrivateDnsARecordRows `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -ZoneName $ZoneName)
        $actualIpAddresses = @($rows | ForEach-Object { $_.IPv4Addresses } | Sort-Object -Unique)
        $missingIpAddresses = @($ExpectedIpAddresses | Where-Object { $actualIpAddresses -notcontains $_ })

        if ($missingIpAddresses.Count -eq 0) {
            return @($rows | Where-Object {
                $rowIpAddresses = @($_.IPv4Addresses)
                @($ExpectedIpAddresses | Where-Object { $rowIpAddresses -contains $_ }).Count -gt 0
            })
        }

        if ((Get-Date) -ge $deadline) {
            break
        }

        Start-Sleep -Seconds 10
    } while ($true)

    throw "Timed out after $TimeoutSeconds seconds waiting for private DNS A records in '$ResourceGroupName/$ZoneName' with IP addresses: $($ExpectedIpAddresses -join ', ')."
}

function Get-PrivateEndpointIpAddresses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$PrivateEndpointName
    )

    $privateEndpoint = Get-AzResource `
        -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.Network/privateEndpoints' `
        -ResourceName $PrivateEndpointName `
        -ExpandProperties `
        -ErrorAction Stop
    $privateEndpointProperties = Get-ObjectPropertyValue -InputObject $privateEndpoint -Name 'Properties'
    $ipAddresses = New-Object System.Collections.Generic.List[string]

    foreach ($networkInterfaceReference in @(Get-ObjectPropertyValue -InputObject $privateEndpointProperties -Name 'networkInterfaces')) {
        if ($null -eq $networkInterfaceReference) {
            continue
        }

        $networkInterfaceId = [string](Get-ObjectPropertyValue -InputObject $networkInterfaceReference -Name 'id')
        if ([string]::IsNullOrWhiteSpace($networkInterfaceId)) {
            continue
        }

        $networkInterface = Get-AzResource -ResourceId $networkInterfaceId -ExpandProperties -ErrorAction Stop
        $networkInterfaceProperties = Get-ObjectPropertyValue -InputObject $networkInterface -Name 'Properties'
        foreach ($ipConfiguration in @(Get-ObjectPropertyValue -InputObject $networkInterfaceProperties -Name 'ipConfigurations')) {
            $ipConfigurationProperties = Get-ObjectPropertyValue -InputObject $ipConfiguration -Name 'properties'
            $privateIpAddress = [string](Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateIPAddress')
            if (-not [string]::IsNullOrWhiteSpace($privateIpAddress) -and -not $ipAddresses.Contains($privateIpAddress)) {
                $ipAddresses.Add($privateIpAddress)
            }
        }
    }

    if ($ipAddresses.Count -eq 0) {
        throw "Private endpoint '$PrivateEndpointName' has no private IP addresses."
    }

    return @($ipAddresses.ToArray())
}

function Get-PrivateEndpointZoneGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrivateEndpointResourceId,

        [Parameter(Mandatory = $true)]
        [string]$ZoneGroupName
    )

    $zoneGroupSegment = ConvertTo-ArmPathSegment -Value $ZoneGroupName
    $path = "$PrivateEndpointResourceId/privateDnsZoneGroups/${zoneGroupSegment}?api-version=$NetworkApiVersion"
    return Invoke-ArmGet -Path $path
}

function Get-PrivateEndpointZoneIds {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ZoneGroup
    )

    $zoneGroupProperties = Get-ObjectPropertyValue -InputObject $ZoneGroup -Name 'properties'
    return @((Get-ObjectPropertyValue -InputObject $zoneGroupProperties -Name 'privateDnsZoneConfigs') | ForEach-Object {
        $configProperties = Get-ObjectPropertyValue -InputObject $_ -Name 'properties'
        [string](Get-ObjectPropertyValue -InputObject $configProperties -Name 'privateDnsZoneId')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-PrivateDnsTxtRecordSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName
    )

    $path = New-PrivateDnsRecordPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ZoneName $ZoneName `
        -RecordType 'TXT' `
        -RecordName $RecordName
    return Invoke-ArmGet -Path $path -AllowNotFound
}

function Test-ContainsSyncProvenanceTxtRecord {
    param(
        [object]$TxtRecordSet
    )

    if ($null -eq $TxtRecordSet) {
        return $false
    }

    $properties = Get-ObjectPropertyValue -InputObject $TxtRecordSet -Name 'properties'
    foreach ($txtRecord in @(Get-ObjectPropertyValue -InputObject $properties -Name 'txtRecords')) {
        $values = @((Get-ObjectPropertyValue -InputObject $txtRecord -Name 'value') | ForEach-Object { [string]$_ })
        if ($values -contains $ProvenanceTxtRecordMarker) {
            return $true
        }
    }

    return $false
}

function Wait-ResourceGroupRemoved {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [ValidateRange(60, 1800)]
        [int]$TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
            return
        }

        if ((Get-Date) -ge $deadline) {
            break
        }

        Start-Sleep -Seconds 10
    } while ($true)

    throw "Timed out after $TimeoutSeconds seconds waiting for resource group '$ResourceGroupName' to be removed."
}

function Add-TestAssertion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [bool]$Passed,

        [Parameter(Mandatory = $true)]
        [string]$Details
    )

    $script:AmlSyncTestAssertions.Add([pscustomobject]@{
        Name    = $Name
        Passed  = $Passed
        Details = $Details
    })

    if (-not $Passed) {
        throw "Assertion failed: $Name. $Details"
    }

    Write-Host "PASS: $Name - $Details" -ForegroundColor Green
}

function Test-StringCollectionContainsAll {
    param(
        [string[]]$Actual,
        [string[]]$Expected
    )

    foreach ($expectedValue in @($Expected)) {
        if (@($Actual) -notcontains $expectedValue) {
            return $false
        }
    }

    return $true
}

Import-RequiredAzModules

if (-not $SkipSync) {
    $SyncScriptPath = (Resolve-Path -LiteralPath $SyncScriptPath -ErrorAction Stop).ProviderPath
}
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

if ([string]::IsNullOrWhiteSpace($NameSuffix)) {
    $characters = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    $NameSuffix = -join (1..10 | ForEach-Object { $characters | Get-Random })
}

$NameSuffix = $NameSuffix.ToLowerInvariant() -replace '[^a-z0-9]', ''
if ($NameSuffix.Length -lt 3 -or $NameSuffix.Length -gt 20) {
    throw 'NameSuffix must contain between 3 and 20 lowercase letters or numbers after normalization.'
}

if ([string]::IsNullOrWhiteSpace($SourceResourceGroupName)) {
    $SourceResourceGroupName = "rg-aml-pe-src-$NameSuffix"
}

if ([string]::IsNullOrWhiteSpace($DestinationResourceGroupName)) {
    $DestinationResourceGroupName = "rg-aml-pe-dst-$NameSuffix"
}

if ($SourceResourceGroupName -ieq $DestinationResourceGroupName -and $SourceSubscriptionId -eq $DestinationSubscriptionId) {
    throw 'SourceResourceGroupName and DestinationResourceGroupName must be different when both subscriptions are the same.'
}

$workspaceName = "amlcnpe$NameSuffix"
$storageAccountName = "stml$NameSuffix"
$keyVaultName = "kvml$NameSuffix"
$appInsightsName = "appi-aml-$NameSuffix"
$virtualNetworkName = 'vnet-aml-pe-test'
$subnetName = 'snet-private-endpoints'
$privateEndpointName = 'pe-aml-sync-test'
$privateEndpointResourceId = "/subscriptions/$SourceSubscriptionId/resourceGroups/$SourceResourceGroupName/providers/Microsoft.Network/privateEndpoints/$privateEndpointName"
$sourcePrivateDnsZoneIds = @($AmlPrivateDnsZoneNames | ForEach-Object {
    "/subscriptions/$SourceSubscriptionId/resourceGroups/$SourceResourceGroupName/providers/Microsoft.Network/privateDnsZones/$_"
})
$destinationPrivateDnsZoneIds = @($AmlPrivateDnsZoneNames | ForEach-Object {
    "/subscriptions/$DestinationSubscriptionId/resourceGroups/$DestinationResourceGroupName/providers/Microsoft.Network/privateDnsZones/$_"
})

$sourceContext = $null
$destinationContext = $null
$sourceResourceGroupOwned = $false
$destinationResourceGroupOwned = $false
$providerRegistrationStates = @{}
$testError = $null
$cleanupErrors = New-Object System.Collections.Generic.List[string]
$cleanupActions = New-Object System.Collections.Generic.List[string]
$syncResultRows = @()
$sourceDnsRecords = @()
$destinationDnsRecords = @()
$privateIpAddresses = @()
$testStatus = 'NotStarted'
$testStartedAt = Get-Date
$testCompletedAt = $null
$report = $null

try {
    Write-Host 'Validating Azure China contexts, providers, and isolated resource-group names...'
    $sourceContext = Select-AzureChinaSubscription -SubscriptionId $SourceSubscriptionId -TenantId $SourceTenantId
    $SourceTenantId = [string]$sourceContext.Tenant.Id
    if (Get-AzResourceGroup -Name $SourceResourceGroupName -ErrorAction SilentlyContinue) {
        throw "Source test resource group '$SourceResourceGroupName' already exists. Choose another NameSuffix or SourceResourceGroupName."
    }

    if (-not $SkipSync) {
        $destinationContext = Select-AzureChinaSubscription -SubscriptionId $DestinationSubscriptionId -TenantId $DestinationTenantId
        $DestinationTenantId = [string]$destinationContext.Tenant.Id
        if (Get-AzResourceGroup -Name $DestinationResourceGroupName -ErrorAction SilentlyContinue) {
            throw "Destination test resource group '$DestinationResourceGroupName' already exists. Choose another NameSuffix or DestinationResourceGroupName."
        }

        if ($SourceTenantId -ne $DestinationTenantId) {
            throw "Source tenant '$SourceTenantId' and destination tenant '$DestinationTenantId' differ. This test validates private endpoint DNS zone-group linking, which requires both subscriptions to be in the same tenant."
        }
    }

    Select-AzureChinaSubscription -SubscriptionId $SourceSubscriptionId -TenantId $SourceTenantId | Out-Null
    foreach ($providerNamespace in @('Microsoft.MachineLearningServices', 'Microsoft.Storage', 'Microsoft.KeyVault', 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.Network')) {
        $providerRegistrationStates[$providerNamespace] = Confirm-ResourceProviderRegistered `
            -SubscriptionId $SourceSubscriptionId `
            -ProviderNamespace $providerNamespace `
            -TimeoutSeconds $ProviderRegistrationTimeoutSeconds
    }

    $workspaceCollectionPath = "/subscriptions/$SourceSubscriptionId/providers/Microsoft.MachineLearningServices/workspaces?api-version=$WorkspaceApiVersion"
    $workspaceCollectionResponse = Invoke-AzRestMethod -Method GET -Path $workspaceCollectionPath -ErrorAction Stop
    if ([int]$workspaceCollectionResponse.StatusCode -ne 200) {
        throw "Azure Machine Learning workspaces API '$WorkspaceApiVersion' is unavailable in source subscription '$SourceSubscriptionId'. ARM returned HTTP $($workspaceCollectionResponse.StatusCode): $($workspaceCollectionResponse.Content)"
    }

    $testStatus = 'Deploying'
    Write-Host "Creating source resource group '$SourceResourceGroupName' in '$Location'..."
    New-AzResourceGroup -Name $SourceResourceGroupName -Location $Location -Force | Out-Null
    $sourceResourceGroupOwned = $true

    $template = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            location           = @{ type = 'string' }
            workspaceName      = @{ type = 'string' }
            storageAccountName = @{ type = 'string' }
            keyVaultName       = @{ type = 'string' }
            appInsightsName    = @{ type = 'string' }
        }
        variables      = @{
            virtualNetworkName      = $virtualNetworkName
            subnetName              = $subnetName
            privateEndpointName     = $privateEndpointName
            privateDnsZoneGroupName = $PrivateDnsZoneGroupName
            apiPrivateDnsZoneName   = $AmlPrivateDnsZoneNames[0]
            notebookPrivateDnsZoneName = $AmlPrivateDnsZoneNames[1]
            apiVirtualNetworkLinkName = 'aml-api-pe-test-link'
            notebookVirtualNetworkLinkName = 'aml-notebooks-pe-test-link'
            subnetId                = "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('virtualNetworkName'), variables('subnetName'))]"
            workspaceId             = "[resourceId('Microsoft.MachineLearningServices/workspaces', parameters('workspaceName'))]"
            apiPrivateDnsZoneId     = "[resourceId('Microsoft.Network/privateDnsZones', variables('apiPrivateDnsZoneName'))]"
            notebookPrivateDnsZoneId = "[resourceId('Microsoft.Network/privateDnsZones', variables('notebookPrivateDnsZoneName'))]"
        }
        resources      = @(
            @{
                type       = 'Microsoft.Network/virtualNetworks'
                apiVersion = '2023-09-01'
                name       = "[variables('virtualNetworkName')]"
                location   = "[parameters('location')]"
                properties = @{
                    addressSpace = @{ addressPrefixes = @('10.85.0.0/16') }
                    subnets      = @(
                        @{
                            name       = "[variables('subnetName')]"
                            properties = @{
                                addressPrefix                     = '10.85.1.0/24'
                                privateEndpointNetworkPolicies    = 'Disabled'
                                privateLinkServiceNetworkPolicies = 'Enabled'
                            }
                        }
                    )
                }
            }
            @{
                type       = 'Microsoft.Storage/storageAccounts'
                apiVersion = '2023-05-01'
                name       = "[parameters('storageAccountName')]"
                location   = "[parameters('location')]"
                sku        = @{ name = 'Standard_LRS' }
                kind       = 'StorageV2'
                properties = @{
                    allowBlobPublicAccess = $false
                    minimumTlsVersion     = 'TLS1_2'
                    supportsHttpsTrafficOnly = $true
                }
            }
            @{
                type       = 'Microsoft.KeyVault/vaults'
                apiVersion = '2023-07-01'
                name       = "[parameters('keyVaultName')]"
                location   = "[parameters('location')]"
                properties = @{
                    tenantId = "[subscription().tenantId]"
                    sku      = @{ family = 'A'; name = 'standard' }
                    accessPolicies = @()
                    enableRbacAuthorization = $true
                    enableSoftDelete = $true
                    softDeleteRetentionInDays = 7
                }
            }
            @{
                type       = 'Microsoft.Insights/components'
                apiVersion = '2020-02-02'
                name       = "[parameters('appInsightsName')]"
                location   = "[parameters('location')]"
                kind       = 'web'
                properties = @{
                    Application_Type = 'web'
                    Flow_Type        = 'Bluefield'
                    Request_Source   = 'rest'
                }
            }
            @{
                type       = 'Microsoft.MachineLearningServices/workspaces'
                apiVersion = $WorkspaceApiVersion
                name       = "[parameters('workspaceName')]"
                location   = "[parameters('location')]"
                identity   = @{ type = 'SystemAssigned' }
                dependsOn  = @(
                    "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
                    "[resourceId('Microsoft.KeyVault/vaults', parameters('keyVaultName'))]"
                    "[resourceId('Microsoft.Insights/components', parameters('appInsightsName'))]"
                )
                properties = @{
                    friendlyName        = "[parameters('workspaceName')]"
                    description         = 'Isolated private endpoint DNS sync integration test.'
                    storageAccount      = "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
                    keyVault            = "[resourceId('Microsoft.KeyVault/vaults', parameters('keyVaultName'))]"
                    applicationInsights = "[resourceId('Microsoft.Insights/components', parameters('appInsightsName'))]"
                    publicNetworkAccess = 'Disabled'
                    v1LegacyMode        = $false
                }
            }
            @{
                type       = 'Microsoft.Network/privateDnsZones'
                apiVersion = '2020-06-01'
                name       = "[variables('apiPrivateDnsZoneName')]"
                location   = 'global'
            }
            @{
                type       = 'Microsoft.Network/privateDnsZones'
                apiVersion = '2020-06-01'
                name       = "[variables('notebookPrivateDnsZoneName')]"
                location   = 'global'
            }
            @{
                type       = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
                apiVersion = '2020-06-01'
                name       = "[format('{0}/{1}', variables('apiPrivateDnsZoneName'), variables('apiVirtualNetworkLinkName'))]"
                location   = 'global'
                dependsOn  = @(
                    "[resourceId('Microsoft.Network/privateDnsZones', variables('apiPrivateDnsZoneName'))]"
                    "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]"
                )
                properties = @{
                    registrationEnabled = $false
                    virtualNetwork      = @{ id = "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]" }
                }
            }
            @{
                type       = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
                apiVersion = '2020-06-01'
                name       = "[format('{0}/{1}', variables('notebookPrivateDnsZoneName'), variables('notebookVirtualNetworkLinkName'))]"
                location   = 'global'
                dependsOn  = @(
                    "[resourceId('Microsoft.Network/privateDnsZones', variables('notebookPrivateDnsZoneName'))]"
                    "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]"
                )
                properties = @{
                    registrationEnabled = $false
                    virtualNetwork      = @{ id = "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]" }
                }
            }
            @{
                type       = 'Microsoft.Network/privateEndpoints'
                apiVersion = '2023-09-01'
                name       = "[variables('privateEndpointName')]"
                location   = "[parameters('location')]"
                dependsOn  = @(
                    "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]"
                    "[resourceId('Microsoft.MachineLearningServices/workspaces', parameters('workspaceName'))]"
                )
                properties = @{
                    subnet = @{ id = "[variables('subnetId')]" }
                    privateLinkServiceConnections = @(
                        @{
                            name       = $PrivateLinkGroupId
                            properties = @{
                                privateLinkServiceId = "[variables('workspaceId')]"
                                groupIds              = @($PrivateLinkGroupId)
                                requestMessage        = 'Azure Machine Learning private DNS sync integration test.'
                            }
                        }
                    )
                }
            }
            @{
                type       = 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
                apiVersion = '2023-09-01'
                name       = "[format('{0}/{1}', variables('privateEndpointName'), variables('privateDnsZoneGroupName'))]"
                dependsOn  = @(
                    "[resourceId('Microsoft.Network/privateEndpoints', variables('privateEndpointName'))]"
                    "[resourceId('Microsoft.Network/privateDnsZones', variables('apiPrivateDnsZoneName'))]"
                    "[resourceId('Microsoft.Network/privateDnsZones', variables('notebookPrivateDnsZoneName'))]"
                )
                properties = @{
                    privateDnsZoneConfigs = @(
                        @{
                            name       = 'aml-api'
                            properties = @{ privateDnsZoneId = "[variables('apiPrivateDnsZoneId')]" }
                        }
                        @{
                            name       = 'aml-notebooks'
                            properties = @{ privateDnsZoneId = "[variables('notebookPrivateDnsZoneId')]" }
                        }
                    )
                }
            }
        )
    }

    Write-Host "Deploying Azure Machine Learning workspace '$workspaceName' and its private endpoint. Provisioning can take several minutes..."
    New-AzResourceGroupDeployment `
        -Name "aml-pe-sync-test-$NameSuffix" `
        -ResourceGroupName $SourceResourceGroupName `
        -TemplateObject $template `
        -location $Location `
        -workspaceName $workspaceName `
        -storageAccountName $storageAccountName `
        -keyVaultName $keyVaultName `
        -appInsightsName $appInsightsName `
        -ErrorAction Stop `
        -Verbose | Out-Null

    $testStatus = 'ValidatingSource'
    $workspaceResourceId = "/subscriptions/$SourceSubscriptionId/resourceGroups/$SourceResourceGroupName/providers/Microsoft.MachineLearningServices/workspaces/$workspaceName"
    $workspace = Invoke-ArmGet -Path "${workspaceResourceId}?api-version=$WorkspaceApiVersion"
    $workspaceProperties = Get-ObjectPropertyValue -InputObject $workspace -Name 'properties'
    $workspaceProvisioningState = [string](Get-ObjectPropertyValue -InputObject $workspaceProperties -Name 'provisioningState')
    $workspacePublicNetworkAccess = [string](Get-ObjectPropertyValue -InputObject $workspaceProperties -Name 'publicNetworkAccess')
    Add-TestAssertion `
        -Name 'AmlWorkspaceProvisioningSucceeded' `
        -Passed ($workspaceProvisioningState -eq 'Succeeded') `
        -Details "ProvisioningState='$workspaceProvisioningState'."
    Add-TestAssertion `
        -Name 'AmlWorkspacePublicNetworkDisabled' `
        -Passed ($workspacePublicNetworkAccess -eq 'Disabled') `
        -Details "PublicNetworkAccess='$workspacePublicNetworkAccess'."

    $privateEndpoint = Get-AzResource `
        -ResourceGroupName $SourceResourceGroupName `
        -ResourceType 'Microsoft.Network/privateEndpoints' `
        -ResourceName $privateEndpointName `
        -ExpandProperties `
        -ErrorAction Stop
    $privateEndpointProperties = Get-ObjectPropertyValue -InputObject $privateEndpoint -Name 'Properties'
    $connectionStatuses = @((Get-ObjectPropertyValue -InputObject $privateEndpointProperties -Name 'privateLinkServiceConnections') | ForEach-Object {
        $connectionProperties = Get-ObjectPropertyValue -InputObject $_ -Name 'properties'
        $connectionState = Get-ObjectPropertyValue -InputObject $connectionProperties -Name 'privateLinkServiceConnectionState'
        [string](Get-ObjectPropertyValue -InputObject $connectionState -Name 'status')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Add-TestAssertion `
        -Name 'AmlPrivateEndpointApproved' `
        -Passed ($connectionStatuses.Count -gt 0 -and @($connectionStatuses | Where-Object { $_ -ne 'Approved' }).Count -eq 0) `
        -Details "ConnectionStatus='$($connectionStatuses -join ',')'."

    $privateIpAddresses = @(Get-PrivateEndpointIpAddresses `
        -ResourceGroupName $SourceResourceGroupName `
        -PrivateEndpointName $privateEndpointName)
    Add-TestAssertion `
        -Name 'AmlPrivateEndpointHasPrivateIp' `
        -Passed ($privateIpAddresses.Count -gt 0) `
        -Details "PrivateIpAddresses='$($privateIpAddresses -join ',')'."

    $initialZoneGroup = Get-PrivateEndpointZoneGroup `
        -PrivateEndpointResourceId $privateEndpointResourceId `
        -ZoneGroupName $PrivateDnsZoneGroupName
    $initialZoneIds = @(Get-PrivateEndpointZoneIds -ZoneGroup $initialZoneGroup)
    Add-TestAssertion `
        -Name 'InitialZoneGroupUsesBothSourceAmlZones' `
        -Passed ((Test-StringCollectionContainsAll -Actual $initialZoneIds -Expected $sourcePrivateDnsZoneIds) -and $initialZoneIds.Count -eq $sourcePrivateDnsZoneIds.Count) `
        -Details "ZoneIds='$($initialZoneIds -join ',')'."

    foreach ($zoneName in $AmlPrivateDnsZoneNames) {
        Write-Host "Waiting for Azure to create source Machine Learning A records in '$zoneName'..."
        $zoneRecords = @(Wait-PrivateDnsARecordsByAnyIp `
            -SubscriptionId $SourceSubscriptionId `
            -ResourceGroupName $SourceResourceGroupName `
            -ZoneName $zoneName `
            -CandidateIpAddresses $privateIpAddresses `
            -TimeoutSeconds $DnsRecordTimeoutSeconds)
        $sourceDnsRecords += $zoneRecords
        $zoneIpAddresses = @($zoneRecords | ForEach-Object { $_.IPv4Addresses } | Sort-Object -Unique)
        Add-TestAssertion `
            -Name "SourceAmlDnsRecordsCreated:$zoneName" `
            -Passed (@($zoneIpAddresses | Where-Object { $privateIpAddresses -contains $_ }).Count -gt 0) `
            -Details "RecordNames='$(@($zoneRecords.RecordName) -join ',')'; IPs='$($zoneIpAddresses -join ',')'."
    }

    if ($SkipSync) {
        $testStatus = 'Deployed'
        Write-Host "Azure Machine Learning workspace '$workspaceName' and private endpoint '$privateEndpointName' were deployed and source-validated. Synchronization was skipped."
    }
    else {
    $testStatus = 'RunningSync'
    Write-Host "Running '$SyncScriptPath' for the isolated Machine Learning source zones..."
    $syncParameters = @{
        SourceSubscriptionId                       = $SourceSubscriptionId
        DestinationSubscriptionId                  = $DestinationSubscriptionId
        SourceTenantId                             = $SourceTenantId
        DestinationTenantId                        = $DestinationTenantId
        SourcePrivateDnsZoneResourceGroupName      = $SourceResourceGroupName
        DestinationPrivateDnsZoneResourceGroupName = $DestinationResourceGroupName
        DestinationResourceGroupLocation           = $Location
        PrivateDnsZoneGroupName                    = $PrivateDnsZoneGroupName
        IncludeNoChangeResults                     = $true
        ErrorAction                                = 'Stop'
    }
    $rawSyncResults = @(& $SyncScriptPath @syncParameters)
    $syncResultRows = @($rawSyncResults | Where-Object {
        $zoneNameProperty = $_.PSObject.Properties['ZoneName']
        $zoneNameProperty -and $AmlPrivateDnsZoneNames -contains [string]$zoneNameProperty.Value
    })

    foreach ($zoneName in $AmlPrivateDnsZoneNames) {
        $matchingEndpointResults = @($syncResultRows | Where-Object {
            $_.ZoneName -ieq $zoneName -and
            @(([string]$_.SourcePrivateEndpointNames -split ',') | ForEach-Object { $_.Trim() }) -contains $privateEndpointName
        })
        Add-TestAssertion `
            -Name "SyncMatchedAmlPrivateEndpoint:$zoneName" `
            -Passed ($matchingEndpointResults.Count -gt 0) `
            -Details "MatchingResultCount='$($matchingEndpointResults.Count)'; Operations='$(@($matchingEndpointResults.Operation) -join ',')'."
    }

    $destinationResourceGroupOwned = $true
    $testStatus = 'ValidatingDestination'
    Select-AzureChinaSubscription -SubscriptionId $SourceSubscriptionId -TenantId $SourceTenantId | Out-Null
    $updatedZoneGroup = Get-PrivateEndpointZoneGroup `
        -PrivateEndpointResourceId $privateEndpointResourceId `
        -ZoneGroupName $PrivateDnsZoneGroupName
    $updatedZoneIds = @(Get-PrivateEndpointZoneIds -ZoneGroup $updatedZoneGroup)
    Add-TestAssertion `
        -Name 'ZoneGroupUsesBothDestinationAmlZones' `
        -Passed ((Test-StringCollectionContainsAll -Actual $updatedZoneIds -Expected $destinationPrivateDnsZoneIds) -and $updatedZoneIds.Count -eq $destinationPrivateDnsZoneIds.Count) `
        -Details "ZoneIds='$($updatedZoneIds -join ',')'."
    Add-TestAssertion `
        -Name 'ZoneGroupNoLongerUsesSourceAmlZones' `
        -Passed (@($updatedZoneIds | Where-Object { $sourcePrivateDnsZoneIds -contains $_ }).Count -eq 0) `
        -Details "SourceZoneIds='$($sourcePrivateDnsZoneIds -join ',')'."

    Select-AzureChinaSubscription -SubscriptionId $DestinationSubscriptionId -TenantId $DestinationTenantId | Out-Null
    if (-not (Get-AzResourceGroup -Name $DestinationResourceGroupName -ErrorAction SilentlyContinue)) {
        throw "The sync script did not create destination resource group '$DestinationResourceGroupName'."
    }

    foreach ($zoneName in $AmlPrivateDnsZoneNames) {
        $destinationZoneId = "/subscriptions/$DestinationSubscriptionId/resourceGroups/$DestinationResourceGroupName/providers/Microsoft.Network/privateDnsZones/$zoneName"
        $destinationZone = Get-AzResource `
            -ResourceGroupName $DestinationResourceGroupName `
            -ResourceType 'Microsoft.Network/privateDnsZones' `
            -ResourceName $zoneName `
            -ErrorAction Stop
        Add-TestAssertion `
            -Name "DestinationAmlPrivateDnsZoneCreated:$zoneName" `
            -Passed ($destinationZone.ResourceId -ieq $destinationZoneId) `
            -Details "ResourceId='$($destinationZone.ResourceId)'."

        $expectedZoneIpAddresses = @($sourceDnsRecords | Where-Object { $_.ZoneName -ieq $zoneName } | ForEach-Object { $_.IPv4Addresses } | Sort-Object -Unique)
        Write-Host "Waiting for Azure to create destination Machine Learning A records in '$zoneName'..."
        $zoneRecords = @(Wait-PrivateDnsARecordsByIp `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $DestinationResourceGroupName `
            -ZoneName $zoneName `
            -ExpectedIpAddresses $expectedZoneIpAddresses `
            -TimeoutSeconds $DnsRecordTimeoutSeconds)
        $destinationDnsRecords += $zoneRecords
        $destinationZoneIpAddresses = @($zoneRecords | ForEach-Object { $_.IPv4Addresses } | Sort-Object -Unique)
        Add-TestAssertion `
            -Name "DestinationAmlDnsRecordsCreated:$zoneName" `
            -Passed (Test-StringCollectionContainsAll -Actual $destinationZoneIpAddresses -Expected $expectedZoneIpAddresses) `
            -Details "RecordNames='$(@($zoneRecords.RecordName) -join ',')'; IPs='$($destinationZoneIpAddresses -join ',')'."

        foreach ($destinationDnsRecord in $zoneRecords) {
            $txtRecordSet = Get-PrivateDnsTxtRecordSet `
                -SubscriptionId $DestinationSubscriptionId `
                -ResourceGroupName $DestinationResourceGroupName `
                -ZoneName $zoneName `
                -RecordName $destinationDnsRecord.RecordName
            Add-TestAssertion `
                -Name "NoDirectSyncProvenanceTxt:$zoneName/$($destinationDnsRecord.RecordName)" `
                -Passed (-not (Test-ContainsSyncProvenanceTxtRecord -TxtRecordSet $txtRecordSet)) `
                -Details 'Zone-group-managed Machine Learning records must not have a direct-sync provenance TXT record.'
        }
    }

        $testStatus = 'Passed'
    }
}
catch {
    $testError = $_
    $testStatus = 'Failed'
    Write-Warning "Azure Machine Learning private endpoint sync test failed: $($_.Exception.Message)"
}
finally {
    $testCompletedAt = Get-Date

    $retainResources = [bool]($KeepResources -or ($SkipSync -and $testStatus -eq 'Deployed'))
    if (-not $retainResources) {
        if ($sourceContext -and $sourceResourceGroupOwned) {
            try {
                Select-AzureChinaSubscription -SubscriptionId $SourceSubscriptionId -TenantId $SourceTenantId | Out-Null
                if (Get-AzResourceGroup -Name $SourceResourceGroupName -ErrorAction SilentlyContinue) {
                    Write-Host "Removing source test resource group '$SourceResourceGroupName'..."
                    Remove-AzResourceGroup -Name $SourceResourceGroupName -Force -ErrorAction Stop | Out-Null
                    Wait-ResourceGroupRemoved -ResourceGroupName $SourceResourceGroupName
                    $cleanupActions.Add("Removed source resource group '$SourceResourceGroupName'.")
                }
            }
            catch {
                $cleanupErrors.Add("Source cleanup failed: $($_.Exception.Message)")
            }
        }

        if ($destinationContext) {
            try {
                Select-AzureChinaSubscription -SubscriptionId $DestinationSubscriptionId -TenantId $DestinationTenantId | Out-Null
                if (Get-AzResourceGroup -Name $DestinationResourceGroupName -ErrorAction SilentlyContinue) {
                    Write-Host "Removing destination test resource group '$DestinationResourceGroupName'..."
                    Remove-AzResourceGroup -Name $DestinationResourceGroupName -Force -ErrorAction Stop | Out-Null
                    Wait-ResourceGroupRemoved -ResourceGroupName $DestinationResourceGroupName
                    $cleanupActions.Add("Removed destination resource group '$DestinationResourceGroupName'.")
                    $destinationResourceGroupOwned = $true
                }
            }
            catch {
                $cleanupErrors.Add("Destination cleanup failed: $($_.Exception.Message)")
            }
        }
    }
    else {
        $retainReason = if ($SkipSync -and $testStatus -eq 'Deployed') { 'SkipSync deployment completed successfully.' } else { 'KeepResources was specified.' }
        $cleanupActions.Add("Resources retained because $retainReason")
    }

    if ($testStatus -eq 'Passed' -and $cleanupErrors.Count -gt 0) {
        $testStatus = 'PassedWithCleanupErrors'
    }

    $report = [ordered]@{
        Status                         = $testStatus
        StartedAt                     = $testStartedAt.ToString('o')
        CompletedAt                   = $testCompletedAt.ToString('o')
        Duration                      = ('{0:hh\:mm\:ss}' -f ($testCompletedAt - $testStartedAt))
        Environment                   = 'AzureChinaCloud'
        SourceSubscriptionId          = $SourceSubscriptionId
        DestinationSubscriptionId     = $DestinationSubscriptionId
        TenantId                      = $SourceTenantId
        Location                      = $Location
        WorkspaceApiVersion           = $WorkspaceApiVersion
        WorkspaceName                 = $workspaceName
        StorageAccountName            = $storageAccountName
        KeyVaultName                  = $keyVaultName
        ApplicationInsightsName       = $appInsightsName
        NameSuffix                    = $NameSuffix
        SourceResourceGroupName       = $SourceResourceGroupName
        DestinationResourceGroupName  = $DestinationResourceGroupName
        PrivateEndpointName           = $privateEndpointName
        PrivateLinkGroupId            = $PrivateLinkGroupId
        PrivateDnsZoneNames            = @($AmlPrivateDnsZoneNames)
        PrivateIpAddresses            = @($privateIpAddresses)
        ProviderRegistrationStates    = $providerRegistrationStates
        SourceDnsRecords              = @($sourceDnsRecords)
        DestinationDnsRecords         = @($destinationDnsRecords)
        SyncResults                   = @($syncResultRows)
        Assertions                    = @($script:AmlSyncTestAssertions.ToArray())
        SyncSkipped                   = [bool]$SkipSync
        KeepResources                 = [bool]$KeepResources
        ResourcesRetained             = $retainResources
        SourceResourceGroupCreated    = $sourceResourceGroupOwned
        DestinationResourceGroupUsed = $destinationResourceGroupOwned
        CleanupActions                = @($cleanupActions.ToArray())
        CleanupErrors                 = @($cleanupErrors.ToArray())
        CleanupCommands               = @(
            "Set-AzContext -SubscriptionId '$SourceSubscriptionId'; Remove-AzResourceGroup -Name '$SourceResourceGroupName' -Force"
            if (-not $SkipSync) {
                "Set-AzContext -SubscriptionId '$DestinationSubscriptionId'; Remove-AzResourceGroup -Name '$DestinationResourceGroupName' -Force"
            }
        )
        Error                          = if ($testError) { [string]$testError.Exception.Message } else { $null }
    }

    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "Test report written to '$OutputPath'."
}

if ($testError) {
    throw $testError
}

if ($cleanupErrors.Count -gt 0) {
    throw "Azure Machine Learning private endpoint sync passed, but cleanup failed: $($cleanupErrors -join ' | ')"
}

if ($SkipSync) {
    Write-Host "Azure Machine Learning private endpoint deployment completed without synchronization. Source resource group '$SourceResourceGroupName' was retained." -ForegroundColor Green
}
else {
    Write-Host "Azure Machine Learning private endpoint sync test passed with '$($script:AmlSyncTestAssertions.Count)' assertion(s)." -ForegroundColor Green
}
[pscustomobject]$report
