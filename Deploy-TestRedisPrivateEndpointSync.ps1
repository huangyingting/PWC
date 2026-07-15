<#
.SYNOPSIS
Deploys Azure Cache for Redis with a private endpoint and tests private DNS synchronization.

.DESCRIPTION
Creates an isolated Azure China test environment in a source subscription with
Azure Cache for Redis, a virtual network, a private endpoint, and the Redis
private DNS zone. It then runs Sync-PrivateEndpointPrivateDns.ps1 against an
isolated destination resource group and verifies that:
- the Redis private endpoint is approved and has private IP addresses;
- the source Redis private DNS A record is created;
- the sync script matches the Redis private endpoint;
- the private endpoint DNS zone group is moved to the destination zone;
- Azure creates matching A records in the destination zone; and
- no direct-sync provenance TXT record is created for the zone-group path.

The source and destination subscriptions must be in the same Microsoft Entra
tenant because private endpoint DNS zone groups cannot reference a private DNS
zone in another tenant. Test resource groups are removed by default, including
when the test fails. Use -KeepResources to retain them for investigation.

.EXAMPLE
    .\Deploy-TestRedisPrivateEndpointSync.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222"

Deploy, test, write the JSON report, and remove the test resource groups.

.EXAMPLE
    .\Deploy-TestRedisPrivateEndpointSync.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -KeepResources

Retain both resource groups after the test for troubleshooting.
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
    [ValidateNotNullOrEmpty()]
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
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PSScriptRoot 'redis-private-endpoint-sync-test.json'),

    [switch]$KeepResources
)

#requires -Modules Az.Accounts, Az.Resources

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PrivateDnsApiVersion = '2018-09-01'
$NetworkApiVersion = '2023-09-01'
$RedisPrivateDnsZoneName = 'privatelink.redis.cache.chinacloudapi.cn'
$PrivateDnsZoneGroupName = 'default'
$ProvenanceTxtRecordMarker = 'sync-private-endpoint-private-dns:v1'
$script:RedisSyncTestAssertions = New-Object System.Collections.Generic.List[object]

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
            RecordName    = [string]$recordSet.name
            IPv4Addresses = @($ipAddresses)
            TTL           = [int](Get-ObjectPropertyValue -InputObject $properties -Name 'ttl')
        })
    }

    return $rows
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

    throw "Timed out after $TimeoutSeconds seconds waiting for private DNS A record(s) in '$ResourceGroupName/$ZoneName' with IP address(es): $($ExpectedIpAddresses -join ', ')."
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

    $script:RedisSyncTestAssertions.Add([pscustomobject]@{
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

$SyncScriptPath = (Resolve-Path -LiteralPath $SyncScriptPath -ErrorAction Stop).ProviderPath
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
    $SourceResourceGroupName = "rg-redis-pe-src-$NameSuffix"
}

if ([string]::IsNullOrWhiteSpace($DestinationResourceGroupName)) {
    $DestinationResourceGroupName = "rg-redis-pe-dst-$NameSuffix"
}

if ($SourceResourceGroupName -ieq $DestinationResourceGroupName -and $SourceSubscriptionId -eq $DestinationSubscriptionId) {
    throw 'SourceResourceGroupName and DestinationResourceGroupName must be different when both subscriptions are the same.'
}

$redisCacheName = "rediscnpe$NameSuffix"
$virtualNetworkName = 'vnet-redis-pe-test'
$subnetName = 'snet-private-endpoints'
$privateEndpointName = 'pe-redis-sync-test'
$sourcePrivateDnsZoneId = "/subscriptions/$SourceSubscriptionId/resourceGroups/$SourceResourceGroupName/providers/Microsoft.Network/privateDnsZones/$RedisPrivateDnsZoneName"
$destinationPrivateDnsZoneId = "/subscriptions/$DestinationSubscriptionId/resourceGroups/$DestinationResourceGroupName/providers/Microsoft.Network/privateDnsZones/$RedisPrivateDnsZoneName"
$privateEndpointResourceId = "/subscriptions/$SourceSubscriptionId/resourceGroups/$SourceResourceGroupName/providers/Microsoft.Network/privateEndpoints/$privateEndpointName"

$sourceContext = $null
$destinationContext = $null
$sourceResourceGroupOwned = $false
$destinationResourceGroupOwned = $false
$preflightComplete = $false
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
    Write-Host 'Validating Azure China contexts and isolated resource-group names...'
    $sourceContext = Select-AzureChinaSubscription -SubscriptionId $SourceSubscriptionId -TenantId $SourceTenantId
    $SourceTenantId = [string]$sourceContext.Tenant.Id
    if (Get-AzResourceGroup -Name $SourceResourceGroupName -ErrorAction SilentlyContinue) {
        throw "Source test resource group '$SourceResourceGroupName' already exists. Choose another NameSuffix or SourceResourceGroupName."
    }

    $destinationContext = Select-AzureChinaSubscription -SubscriptionId $DestinationSubscriptionId -TenantId $DestinationTenantId
    $DestinationTenantId = [string]$destinationContext.Tenant.Id
    if (Get-AzResourceGroup -Name $DestinationResourceGroupName -ErrorAction SilentlyContinue) {
        throw "Destination test resource group '$DestinationResourceGroupName' already exists. Choose another NameSuffix or DestinationResourceGroupName."
    }

    if ($SourceTenantId -ne $DestinationTenantId) {
        throw "Source tenant '$SourceTenantId' and destination tenant '$DestinationTenantId' differ. This test validates private endpoint DNS zone-group linking, which requires both subscriptions to be in the same tenant."
    }

    $preflightComplete = $true
    $testStatus = 'Deploying'

    Select-AzureChinaSubscription -SubscriptionId $SourceSubscriptionId -TenantId $SourceTenantId | Out-Null
    Write-Host "Creating source resource group '$SourceResourceGroupName' in '$Location'..."
    New-AzResourceGroup -Name $SourceResourceGroupName -Location $Location -Force | Out-Null
    $sourceResourceGroupOwned = $true

    $template = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            location       = @{ type = 'string' }
            redisCacheName = @{ type = 'string' }
        }
        variables      = @{
            virtualNetworkName        = $virtualNetworkName
            subnetName                = $subnetName
            privateEndpointName       = $privateEndpointName
            privateDnsZoneName        = $RedisPrivateDnsZoneName
            privateDnsZoneGroupName   = $PrivateDnsZoneGroupName
            virtualNetworkLinkName    = 'redis-pe-test-link'
            subnetId                  = "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('virtualNetworkName'), variables('subnetName'))]"
            redisCacheId              = "[resourceId('Microsoft.Cache/Redis', parameters('redisCacheName'))]"
            privateDnsZoneId          = "[resourceId('Microsoft.Network/privateDnsZones', variables('privateDnsZoneName'))]"
        }
        resources      = @(
            @{
                type       = 'Microsoft.Network/virtualNetworks'
                apiVersion = '2023-09-01'
                name       = "[variables('virtualNetworkName')]"
                location   = "[parameters('location')]"
                properties = @{
                    addressSpace = @{ addressPrefixes = @('10.84.0.0/16') }
                    subnets      = @(
                        @{
                            name       = "[variables('subnetName')]"
                            properties = @{
                                addressPrefix                     = '10.84.1.0/24'
                                privateEndpointNetworkPolicies    = 'Disabled'
                                privateLinkServiceNetworkPolicies = 'Enabled'
                            }
                        }
                    )
                }
            }
            @{
                type       = 'Microsoft.Cache/Redis'
                apiVersion = '2023-08-01'
                name       = "[parameters('redisCacheName')]"
                location   = "[parameters('location')]"
                properties = @{
                    sku = @{
                        name     = 'Basic'
                        family   = 'C'
                        capacity = 0
                    }
                    enableNonSslPort    = $false
                    minimumTlsVersion   = '1.2'
                    publicNetworkAccess = 'Disabled'
                    redisVersion        = '6'
                }
            }
            @{
                type       = 'Microsoft.Network/privateDnsZones'
                apiVersion = '2020-06-01'
                name       = "[variables('privateDnsZoneName')]"
                location   = 'global'
            }
            @{
                type       = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
                apiVersion = '2020-06-01'
                name       = "[format('{0}/{1}', variables('privateDnsZoneName'), variables('virtualNetworkLinkName'))]"
                location   = 'global'
                dependsOn  = @(
                    "[resourceId('Microsoft.Network/privateDnsZones', variables('privateDnsZoneName'))]"
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
                    "[resourceId('Microsoft.Cache/Redis', parameters('redisCacheName'))]"
                )
                properties = @{
                    subnet = @{ id = "[variables('subnetId')]" }
                    privateLinkServiceConnections = @(
                        @{
                            name       = 'redisCache'
                            properties = @{
                                privateLinkServiceId = "[variables('redisCacheId')]"
                                groupIds              = @('redisCache')
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
                    "[resourceId('Microsoft.Network/privateDnsZones', variables('privateDnsZoneName'))]"
                )
                properties = @{
                    privateDnsZoneConfigs = @(
                        @{
                            name       = 'redis'
                            properties = @{ privateDnsZoneId = "[variables('privateDnsZoneId')]" }
                        }
                    )
                }
            }
        )
    }

    Write-Host "Deploying Azure Cache for Redis '$redisCacheName' and its private endpoint. Redis provisioning can take several minutes..."
    New-AzResourceGroupDeployment `
        -Name "redis-pe-sync-test-$NameSuffix" `
        -ResourceGroupName $SourceResourceGroupName `
        -TemplateObject $template `
        -location $Location `
        -redisCacheName $redisCacheName `
        -ErrorAction Stop `
        -Verbose | Out-Null

    $testStatus = 'ValidatingSource'
    $redisCache = Get-AzResource `
        -ResourceGroupName $SourceResourceGroupName `
        -ResourceType 'Microsoft.Cache/Redis' `
        -ResourceName $redisCacheName `
        -ExpandProperties `
        -ErrorAction Stop
    $redisProperties = Get-ObjectPropertyValue -InputObject $redisCache -Name 'Properties'
    $redisProvisioningState = [string](Get-ObjectPropertyValue -InputObject $redisProperties -Name 'provisioningState')
    $redisPublicNetworkAccess = [string](Get-ObjectPropertyValue -InputObject $redisProperties -Name 'publicNetworkAccess')
    Add-TestAssertion `
        -Name 'RedisProvisioningSucceeded' `
        -Passed ($redisProvisioningState -eq 'Succeeded') `
        -Details "ProvisioningState='$redisProvisioningState'."
    Add-TestAssertion `
        -Name 'RedisPublicNetworkDisabled' `
        -Passed ($redisPublicNetworkAccess -eq 'Disabled') `
        -Details "PublicNetworkAccess='$redisPublicNetworkAccess'."

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
        -Name 'RedisPrivateEndpointApproved' `
        -Passed ($connectionStatuses.Count -gt 0 -and @($connectionStatuses | Where-Object { $_ -ne 'Approved' }).Count -eq 0) `
        -Details "ConnectionStatus='$($connectionStatuses -join ',')'."

    $privateIpAddresses = @(Get-PrivateEndpointIpAddresses `
        -ResourceGroupName $SourceResourceGroupName `
        -PrivateEndpointName $privateEndpointName)
    Add-TestAssertion `
        -Name 'RedisPrivateEndpointHasPrivateIp' `
        -Passed ($privateIpAddresses.Count -gt 0) `
        -Details "PrivateIpAddresses='$($privateIpAddresses -join ',')'."

    $initialZoneGroup = Get-PrivateEndpointZoneGroup `
        -PrivateEndpointResourceId $privateEndpointResourceId `
        -ZoneGroupName $PrivateDnsZoneGroupName
    $initialZoneIds = @(Get-PrivateEndpointZoneIds -ZoneGroup $initialZoneGroup)
    Add-TestAssertion `
        -Name 'InitialZoneGroupUsesSourceRedisZone' `
        -Passed (@($initialZoneIds | Where-Object { $_ -ieq $sourcePrivateDnsZoneId }).Count -eq 1) `
        -Details "ZoneIds='$($initialZoneIds -join ',')'."

    Write-Host 'Waiting for Azure to create the source Redis private DNS A record...'
    $sourceDnsRecords = @(Wait-PrivateDnsARecordsByIp `
        -SubscriptionId $SourceSubscriptionId `
        -ResourceGroupName $SourceResourceGroupName `
        -ZoneName $RedisPrivateDnsZoneName `
        -ExpectedIpAddresses $privateIpAddresses `
        -TimeoutSeconds $DnsRecordTimeoutSeconds)
    $sourceDnsIpAddresses = @($sourceDnsRecords | ForEach-Object { $_.IPv4Addresses } | Sort-Object -Unique)
    Add-TestAssertion `
        -Name 'SourceRedisDnsRecordsCreated' `
        -Passed (Test-StringCollectionContainsAll -Actual $sourceDnsIpAddresses -Expected $privateIpAddresses) `
        -Details "RecordNames='$(@($sourceDnsRecords.RecordName) -join ',')'; IPs='$($sourceDnsIpAddresses -join ',')'."

    $testStatus = 'RunningSync'
    Write-Host "Running '$SyncScriptPath' for the isolated Redis source zone..."
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
        $zoneNameProperty -and [string]$zoneNameProperty.Value -ieq $RedisPrivateDnsZoneName
    })
    $matchingEndpointResults = @($syncResultRows | Where-Object {
        $endpointNames = @(([string]$_.SourcePrivateEndpointNames -split ',') | ForEach-Object { $_.Trim() })
        $endpointNames -contains $privateEndpointName
    })
    Add-TestAssertion `
        -Name 'SyncMatchedRedisPrivateEndpoint' `
        -Passed ($matchingEndpointResults.Count -gt 0) `
        -Details "MatchingResultCount='$($matchingEndpointResults.Count)'; Operations='$(@($matchingEndpointResults.Operation) -join ',')'."

    $destinationResourceGroupOwned = $true
    $testStatus = 'ValidatingDestination'
    Select-AzureChinaSubscription -SubscriptionId $SourceSubscriptionId -TenantId $SourceTenantId | Out-Null
    $updatedZoneGroup = Get-PrivateEndpointZoneGroup `
        -PrivateEndpointResourceId $privateEndpointResourceId `
        -ZoneGroupName $PrivateDnsZoneGroupName
    $updatedZoneIds = @(Get-PrivateEndpointZoneIds -ZoneGroup $updatedZoneGroup)
    Add-TestAssertion `
        -Name 'ZoneGroupUsesDestinationRedisZone' `
        -Passed (@($updatedZoneIds | Where-Object { $_ -ieq $destinationPrivateDnsZoneId }).Count -eq 1) `
        -Details "ZoneIds='$($updatedZoneIds -join ',')'."
    Add-TestAssertion `
        -Name 'ZoneGroupNoLongerUsesSourceRedisZone' `
        -Passed (@($updatedZoneIds | Where-Object { $_ -ieq $sourcePrivateDnsZoneId }).Count -eq 0) `
        -Details "SourceZoneId='$sourcePrivateDnsZoneId'."

    Select-AzureChinaSubscription -SubscriptionId $DestinationSubscriptionId -TenantId $DestinationTenantId | Out-Null
    if (-not (Get-AzResourceGroup -Name $DestinationResourceGroupName -ErrorAction SilentlyContinue)) {
        throw "The sync script did not create destination resource group '$DestinationResourceGroupName'."
    }

    $destinationZone = Get-AzResource `
        -ResourceGroupName $DestinationResourceGroupName `
        -ResourceType 'Microsoft.Network/privateDnsZones' `
        -ResourceName $RedisPrivateDnsZoneName `
        -ErrorAction Stop
    Add-TestAssertion `
        -Name 'DestinationRedisPrivateDnsZoneCreated' `
        -Passed ($destinationZone.ResourceId -ieq $destinationPrivateDnsZoneId) `
        -Details "ResourceId='$($destinationZone.ResourceId)'."

    Write-Host 'Waiting for Azure to create the destination Redis private DNS A record...'
    $destinationDnsRecords = @(Wait-PrivateDnsARecordsByIp `
        -SubscriptionId $DestinationSubscriptionId `
        -ResourceGroupName $DestinationResourceGroupName `
        -ZoneName $RedisPrivateDnsZoneName `
        -ExpectedIpAddresses $privateIpAddresses `
        -TimeoutSeconds $DnsRecordTimeoutSeconds)
    $destinationDnsIpAddresses = @($destinationDnsRecords | ForEach-Object { $_.IPv4Addresses } | Sort-Object -Unique)
    Add-TestAssertion `
        -Name 'DestinationRedisDnsRecordsCreated' `
        -Passed (Test-StringCollectionContainsAll -Actual $destinationDnsIpAddresses -Expected $privateIpAddresses) `
        -Details "RecordNames='$(@($destinationDnsRecords.RecordName) -join ',')'; IPs='$($destinationDnsIpAddresses -join ',')'."

    foreach ($destinationDnsRecord in $destinationDnsRecords) {
        $txtRecordSet = Get-PrivateDnsTxtRecordSet `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $DestinationResourceGroupName `
            -ZoneName $RedisPrivateDnsZoneName `
            -RecordName $destinationDnsRecord.RecordName
        Add-TestAssertion `
            -Name "NoDirectSyncProvenanceTxt:$($destinationDnsRecord.RecordName)" `
            -Passed (-not (Test-ContainsSyncProvenanceTxtRecord -TxtRecordSet $txtRecordSet)) `
            -Details 'Zone-group-managed Redis records must not have a direct-sync provenance TXT record.'
    }

    $testStatus = 'Passed'
}
catch {
    $testError = $_
    $testStatus = 'Failed'
    Write-Warning "Redis private endpoint sync test failed: $($_.Exception.Message)"
}
finally {
    $testCompletedAt = Get-Date

    if ($preflightComplete -and -not $KeepResources) {
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

        try {
            Select-AzureChinaSubscription -SubscriptionId $DestinationSubscriptionId -TenantId $DestinationTenantId | Out-Null
            if (Get-AzResourceGroup -Name $DestinationResourceGroupName -ErrorAction SilentlyContinue) {
                Write-Host "Removing destination test resource group '$DestinationResourceGroupName'..."
                Remove-AzResourceGroup -Name $DestinationResourceGroupName -Force -ErrorAction Stop | Out-Null
                Wait-ResourceGroupRemoved -ResourceGroupName $DestinationResourceGroupName
                $cleanupActions.Add("Removed destination resource group '$DestinationResourceGroupName'.")
            }
        }
        catch {
            $cleanupErrors.Add("Destination cleanup failed: $($_.Exception.Message)")
        }
    }
    elseif ($KeepResources) {
        $cleanupActions.Add('Resources retained because KeepResources was specified.')
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
        NameSuffix                    = $NameSuffix
        SourceResourceGroupName       = $SourceResourceGroupName
        DestinationResourceGroupName  = $DestinationResourceGroupName
        RedisCacheName                = $redisCacheName
        RedisSku                      = 'Basic C0'
        RedisPrivateDnsZoneName       = $RedisPrivateDnsZoneName
        PrivateEndpointName           = $privateEndpointName
        PrivateIpAddresses            = @($privateIpAddresses)
        SourceDnsRecords              = @($sourceDnsRecords)
        DestinationDnsRecords         = @($destinationDnsRecords)
        SyncResults                   = @($syncResultRows)
        Assertions                    = @($script:RedisSyncTestAssertions.ToArray())
        KeepResources                 = [bool]$KeepResources
        SourceResourceGroupCreated    = $sourceResourceGroupOwned
        DestinationResourceGroupUsed = $destinationResourceGroupOwned
        CleanupActions                = @($cleanupActions.ToArray())
        CleanupErrors                 = @($cleanupErrors.ToArray())
        CleanupCommands               = @(
            "Set-AzContext -SubscriptionId '$SourceSubscriptionId'; Remove-AzResourceGroup -Name '$SourceResourceGroupName' -Force"
            "Set-AzContext -SubscriptionId '$DestinationSubscriptionId'; Remove-AzResourceGroup -Name '$DestinationResourceGroupName' -Force"
        )
        Error                          = if ($testError) { [string]$testError.Exception.Message } else { $null }
    }

    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "Test report written to '$OutputPath'."
}

if ($testError) {
    throw $testError
}

if ($cleanupErrors.Count -gt 0) {
    throw "Redis private endpoint sync passed, but cleanup failed: $($cleanupErrors -join ' | ')"
}

Write-Host "Redis private endpoint sync test passed with '$($script:RedisSyncTestAssertions.Count)' assertion(s)." -ForegroundColor Green
[pscustomobject]$report
