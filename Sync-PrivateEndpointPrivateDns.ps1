<#
.SYNOPSIS
Syncs Azure Private Link private DNS A records from one subscription to another.

.DESCRIPTION
Scans a source subscription for private DNS zones, reads the A records from
Private Link zones, and writes those records to matching private DNS zones in a
destination subscription.

The script is scoped to Azure China. Private DNS zone names are discovered from
the source subscription and matched by exact zone name in the destination
subscription. Only Azure China PaaS Private Link private DNS zones from the
built-in allow-list are scanned; custom private DNS zones and non-PaaS zones are
ignored even if their names start with "privatelink.".

By default, the script scans supported Azure PaaS Private Link zones and links
matching source private endpoints to destination private DNS zones by updating
privateDnsZoneGroups. Azure then manages the destination A records. If no source
private endpoint can be matched, the script falls back to writing the destination
A record directly. Use -SkipSourcePrivateEndpointLink to always sync DNS records
directly, and use -ReplaceExisting when manually synced destination record sets
should exactly match the source.

By default, the script also finds the source private endpoints that correspond
to the synced A records and adds the destination private DNS zones to those
private endpoints' privateDnsZoneGroups. This is an Azure resource update on the
source private endpoints. Use -SkipSourcePrivateEndpointLink to sync DNS records
only.

If a matching destination private DNS zone doesn't exist, the script creates it
by default. Private DNS zones are global resources, so the zone location is
always "global". The destination resource group name defaults to the source
private DNS zone resource group name, and a missing destination resource group is
created in the source resource group's location unless
-DestinationResourceGroupLocation is specified. Use
-DestinationPrivateDnsZoneResourceGroupName to override the destination resource
group for newly created zones, or -SkipCreateMissingDestinationZones to require
destination zones to already exist.

When the script falls back to direct A record sync, it also writes a same-name
provenance TXT record by default. The managed TXT value records the source
subscription, source private DNS zone resource group, source zone, source record
name, source IP addresses, and script marker. Existing non-managed TXT values on
that record set are preserved. Zone-group-managed records do not get provenance
TXT records by default so that Azure can manage their lifecycle cleanly. Use
-SkipProvenanceTxtRecord to disable this metadata record for direct record sync.

Required permissions:
- Source subscription: Reader on private DNS zones.
- Destination subscription: Private DNS Zone Contributor on private DNS zones.
- Optional -RemoveSourceAfterCopy: Private DNS Zone Contributor on source zones.
- Default private endpoint linking: Network Contributor on source private
    endpoints, plus read access to destination private DNS zones.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -WhatIf

Preview all changes for supported source Azure PaaS Private Link zones.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -ReplaceExisting

Sync all supported source Azure PaaS Private Link A records and replace matching
destination record sets.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -ZoneName "privatelink.blob.core.chinacloudapi.cn", "privatelink.vaultcore.azure.cn"

Sync only selected Azure PaaS Private Link private DNS zones. The selected zone
names must be present in the built-in Azure China PaaS allow-list.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -WhatIf

Preview DNS record sync and source private endpoint DNS zone group links to the
matching destination private DNS zones.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -SkipSourcePrivateEndpointLink `
        -WhatIf

Preview DNS record sync only, without updating source private endpoint private
DNS zone groups.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -DestinationPrivateDnsZoneResourceGroupName "rg-central-private-dns" `
        -DestinationResourceGroupLocation "chinaeast2" `
        -WhatIf

Preview sync and create any missing destination private DNS zones in a specific
destination resource group instead of using the source zone resource group name.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -SkipProvenanceTxtRecord `
        -WhatIf

Preview DNS record sync without creating or updating provenance TXT records.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [Alias('AppSubscriptionId')]
    [ValidateNotNullOrEmpty()]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory = $true)]
    [Alias('CentralSubscriptionId')]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationSubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$SourceTenantId,

    [ValidateNotNullOrEmpty()]
    [string]$DestinationTenantId,

    [ValidateNotNullOrEmpty()]
    [string]$DestinationPrivateDnsZoneResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$DestinationResourceGroupLocation,

    [ValidateNotNullOrEmpty()]
    [string[]]$ZoneName,

    [switch]$IncludeAllPrivateDnsZones,

    [switch]$SkipCreateMissingDestinationZones,

    [switch]$SkipProvenanceTxtRecord,

    [switch]$IncludeApex,

    [switch]$ReplaceExisting,

    [switch]$RemoveSourceAfterCopy,

    [switch]$LinkSourcePrivateEndpointsToDestinationZones,

    [switch]$SkipSourcePrivateEndpointLink,

    [ValidateNotNullOrEmpty()]
    [string]$PrivateDnsZoneGroupName = 'default',

    [ValidateRange(1, 2147483647)]
    [int]$Ttl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PrivateDnsApiVersion = '2018-09-01'
$NetworkApiVersion = '2023-09-01'
$AzureChinaEnvironmentName = 'AzureChinaCloud'
$ProvenanceTxtRecordMarker = 'sync-private-endpoint-private-dns:v1'
$UseTtlOverride = $PSBoundParameters.ContainsKey('Ttl')
$ScriptCommand = $PSCmdlet

$UseDestinationResourceGroupLocationOverride = $PSBoundParameters.ContainsKey('DestinationResourceGroupLocation')
$DefaultDestinationResourceGroupLocation = 'chinaeast2'
if ([string]::IsNullOrWhiteSpace($DestinationResourceGroupLocation)) {
    $DestinationResourceGroupLocation = $DefaultDestinationResourceGroupLocation
}

if ($LinkSourcePrivateEndpointsToDestinationZones -and $SkipSourcePrivateEndpointLink) {
    throw 'Use either -LinkSourcePrivateEndpointsToDestinationZones or -SkipSourcePrivateEndpointLink, not both.'
}

$ShouldLinkSourcePrivateEndpointsToDestinationZones = -not $SkipSourcePrivateEndpointLink

if ($ShouldLinkSourcePrivateEndpointsToDestinationZones -and $SourceTenantId -and $DestinationTenantId -and $SourceTenantId -ne $DestinationTenantId) {
    throw 'Private endpoint linking is enabled by default and requires source and destination private DNS zones/private endpoints to be in the same tenant. Use -SkipSourcePrivateEndpointLink to sync DNS records only.'
}

if ($IncludeAllPrivateDnsZones) {
    Write-Warning '-IncludeAllPrivateDnsZones is kept for backward compatibility but is ignored. This script only syncs supported Azure PaaS Private Link private DNS zones.'
}

$AzurePaaSPrivateDnsZonePatterns = @{
    AzureChinaCloud = @(
        # Keep this list aligned with the official China table:
        # https://docs.azure.cn/en-us/private-link/private-endpoint-dns
        '^privatelink\.api\.ml\.azure\.cn$',
        '^privatelink\.notebooks\.chinacloudapi\.cn$',
        '^privatelink\.(blob|dfs|file|queue|table|web)\.core\.chinacloudapi\.cn$',
        '^privatelink\.afs\.azure\.cn$',
        '^privatelink\.database\.chinacloudapi\.cn$',
        '^privatelink\.(mysql|postgres|mariadb)\.database\.chinacloudapi\.cn$',
        '^privatelink\.documents\.azure\.cn$',
        '^privatelink\.(mongo|cassandra|gremlin|table)\.cosmos\.azure\.cn$',
        '^privatelink\.vaultcore\.azure\.cn$',
        '^privatelink\.servicebus\.chinacloudapi\.cn$',
        '^privatelink\.redis\.cache\.chinacloudapi\.cn$',
        '^privatelink\.chinacloudsites\.cn$',
        '^privatelink\.datafactory\.azure\.cn$',
        '^privatelink\.adf\.azure\.cn$',
        '^privatelink\.azure-automation\.cn$',
        '^privatelink\.signalr\.azure\.cn$',
        '^privatelink\.azure-devices\.cn$',
        '^privatelink\.azure-devices-provisioning\.cn$',
        '^privatelink\.azurehdinsight\.cn$',
        '^privatelink\.[a-z0-9-]+\.kusto\.windows\.cn$',
        '^privatelink\.batch\.chinacloudapi\.cn$',
        '^privatelink-global\.wvd\.azure\.cn$',
        '^privatelink\.wvd\.azure\.cn$'
    )
}

function Import-AzAccountsModule {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw 'Az.Accounts is required. Install it with: Install-Module Az.Accounts -Scope CurrentUser'
    }

    Import-Module Az.Accounts -ErrorAction Stop
}

function Select-AzureSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [string]$TenantId
    )

    Import-AzAccountsModule


    $connectParameters = @{}
    $contextParameters = @{
        SubscriptionId = $SubscriptionId
        ErrorAction    = 'Stop'
        WhatIf         = $false
    }

    if ($EnvironmentName) {
        $connectParameters['Environment'] = $EnvironmentName
    }

    if ($TenantId) {
        $connectParameters['Tenant'] = $TenantId
        $contextParameters['Tenant'] = $TenantId
    }

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Connect-AzAccount @connectParameters -ErrorAction Stop | Out-Null
    }

    try {
        Set-AzContext @contextParameters | Out-Null
    }
    catch {
        Connect-AzAccount @connectParameters -ErrorAction Stop | Out-Null
        Set-AzContext @contextParameters | Out-Null
    }
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

function Get-ResourceGroupNameFromResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    if ($ResourceId -notmatch '/resourceGroups/([^/]+)/') {
        throw "Could not read resource group name from resource ID: $ResourceId"
    }

    return [System.Uri]::UnescapeDataString($Matches[1])
}

function New-PrivateDnsRecordSetPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [ValidateSet('A', 'TXT')]
        [string]$RecordType = 'A',

        [string]$RecordName
    )

    $zoneSegment = ConvertTo-ArmPathSegment -Value $CurrentZoneName
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/privateDnsZones/$zoneSegment/$RecordType"

    if ($RecordName) {
        $recordSegment = ConvertTo-ArmPathSegment -Value $RecordName
        $path = "$path/$recordSegment"
    }

    return "${path}?api-version=$PrivateDnsApiVersion"
}

function New-PrivateDnsZonePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName
    )

    $zoneSegment = ConvertTo-ArmPathSegment -Value $CurrentZoneName
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/privateDnsZones/$zoneSegment"
    return "${path}?api-version=$PrivateDnsApiVersion"
}

function New-PrivateDnsZoneResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName
    )

    return "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/privateDnsZones/$CurrentZoneName"
}

function Invoke-ArmJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT', 'DELETE')]
        [string]$Method,

        [string]$Path,

        [string]$Uri,

        [object]$Body,

        [int[]]$ExpectedStatusCode = @(200),

        [switch]$AllowNotFound
    )

    $parameters = @{
        Method      = $Method
        ErrorAction = 'Stop'
    }

    if ($Uri) {
        $parameters['Uri'] = $Uri
    }
    elseif ($Path) {
        $parameters['Path'] = $Path
    }
    else {
        throw 'Either Path or Uri is required.'
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters['Payload'] = ($Body | ConvertTo-Json -Depth 20)
    }

    try {
        $response = Invoke-AzRestMethod @parameters
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

    if ($ExpectedStatusCode -notcontains $statusCode) {
        $target = if ($Uri) { $Uri } else { $Path }
        throw "ARM $Method failed for $target. Status: $statusCode. Response: $($response.Content)"
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

function Get-ArmPagedValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $items = New-Object System.Collections.Generic.List[object]
    $nextLink = $Path

    while ($nextLink) {
        if ($nextLink -match '^https?://') {
            $page = Invoke-ArmJson -Method GET -Uri $nextLink -ExpectedStatusCode @(200)
        }
        else {
            $page = Invoke-ArmJson -Method GET -Path $nextLink -ExpectedStatusCode @(200)
        }

        foreach ($item in @(Get-ObjectPropertyValue -InputObject $page -Name 'value')) {
            if ($null -ne $item) {
                $items.Add($item)
            }
        }

        $nextLink = Get-ObjectPropertyValue -InputObject $page -Name 'nextLink'
    }

    return $items
}

function Get-PrivateDnsZonesInSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    $path = "/subscriptions/$SubscriptionId/providers/Microsoft.Network/privateDnsZones?api-version=$PrivateDnsApiVersion"
    $zones = Get-ArmPagedValues -Path $path
    $results = New-Object System.Collections.Generic.List[object]
    $resourceGroupLocationLookup = @{}

    foreach ($currentZone in $zones) {
        $resourceGroupName = Get-ResourceGroupNameFromResourceId -ResourceId ([string]$currentZone.id)
        if (-not $resourceGroupLocationLookup.ContainsKey($resourceGroupName.ToLowerInvariant())) {
            $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
            $resourceGroupLocationLookup[$resourceGroupName.ToLowerInvariant()] = if ($resourceGroup) { [string]$resourceGroup.Location } else { $null }
        }

        $results.Add([pscustomobject]@{
            Name              = [string]$currentZone.name
            ResourceGroupName = $resourceGroupName
            ResourceGroupLocation = $resourceGroupLocationLookup[$resourceGroupName.ToLowerInvariant()]
            Id                = [string]$currentZone.id
        })
    }

    return $results
}

function Test-AzurePaaSPrivateDnsZoneName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('AzureChinaCloud')]
        [string]$EnvironmentName
    )

    $normalizedName = $Name.Trim().ToLowerInvariant()
    $patterns = @($AzurePaaSPrivateDnsZonePatterns[$EnvironmentName])

    foreach ($pattern in $patterns) {
        if ($normalizedName -match $pattern) {
            return $true
        }
    }

    return $false
}

function Select-ZonesForSync {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Zones,

        [string[]]$RequestedZoneNames,

        [Parameter(Mandatory = $true)]
        [ValidateSet('AzureChinaCloud')]
        [string]$EnvironmentName
    )

    $requestedZoneLookup = @{}
    foreach ($requestedZoneName in @($RequestedZoneNames)) {
        if ([string]::IsNullOrWhiteSpace($requestedZoneName)) {
            continue
        }

        $normalizedRequestedZoneName = $requestedZoneName.Trim().ToLowerInvariant()
        if (-not (Test-AzurePaaSPrivateDnsZoneName -Name $normalizedRequestedZoneName -EnvironmentName $EnvironmentName)) {
            throw "ZoneName '$requestedZoneName' is not a supported Azure PaaS Private Link private DNS zone for '$EnvironmentName'."
        }

        $requestedZoneLookup[$normalizedRequestedZoneName] = $true
    }

    $selectedZones = New-Object System.Collections.Generic.List[object]
    foreach ($currentZone in @($Zones)) {
        $currentZoneName = ([string]$currentZone.Name).Trim()

        if (-not (Test-AzurePaaSPrivateDnsZoneName -Name $currentZoneName -EnvironmentName $EnvironmentName)) {
            continue
        }

        if ($requestedZoneLookup.Count -gt 0) {
            if ($requestedZoneLookup.ContainsKey($currentZoneName.ToLowerInvariant())) {
                $selectedZones.Add($currentZone)
            }

            continue
        }

        $selectedZones.Add($currentZone)
    }

    return $selectedZones
}

function Confirm-ResourceGroupExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $existingResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if ($existingResourceGroup) {
        return
    }

    if ($ScriptCommand.ShouldProcess($ResourceGroupName, 'Create destination resource group')) {
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null
    }
}

function Confirm-DestinationPrivateDnsZones {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationSubscriptionId,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SourceZones,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$DestinationZones,

        [string]$ResourceGroupNameOverride,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupLocation,

        [bool]$UseResourceGroupLocationOverride,

        [switch]$SkipCreate
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($destinationZone in @($DestinationZones)) {
        $results.Add($destinationZone)
    }

    if ($SkipCreate) {
        return $results
    }

    $destinationZoneLookup = New-ZoneLookup -Zones @($results.ToArray())
    $sourceZoneGroups = @($SourceZones | Group-Object { ([string]$_.Name).ToLowerInvariant() })

    foreach ($sourceZoneGroup in $sourceZoneGroups) {
        $sourceZone = $sourceZoneGroup.Group[0]
        $zoneName = [string]$sourceZone.Name
        $zoneKey = $zoneName.ToLowerInvariant()

        if ($destinationZoneLookup.ContainsKey($zoneKey)) {
            continue
        }

        if ($ResourceGroupNameOverride) {
            $destinationResourceGroupName = $ResourceGroupNameOverride
        }
        else {
            $sourceResourceGroupNames = @($sourceZoneGroup.Group | ForEach-Object { [string]$_.ResourceGroupName } | Sort-Object -Unique)
            if ($sourceResourceGroupNames.Count -gt 1) {
                throw "Multiple source private DNS zones named '$zoneName' exist in resource groups: $($sourceResourceGroupNames -join ', '). Specify -DestinationPrivateDnsZoneResourceGroupName to choose where to create the destination zone."
            }

            $destinationResourceGroupName = $sourceResourceGroupNames[0]
        }

        if ($UseResourceGroupLocationOverride) {
            $effectiveResourceGroupLocation = $ResourceGroupLocation
        }
        else {
            $sourceResourceGroupLocations = @($sourceZoneGroup.Group | ForEach-Object { [string]$_.ResourceGroupLocation } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            if ($sourceResourceGroupLocations.Count -eq 1) {
                $effectiveResourceGroupLocation = $sourceResourceGroupLocations[0]
            }
            else {
                $effectiveResourceGroupLocation = $ResourceGroupLocation
            }
        }

        Confirm-ResourceGroupExists `
            -ResourceGroupName $destinationResourceGroupName `
            -Location $effectiveResourceGroupLocation

        $zonePath = New-PrivateDnsZonePath `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $destinationResourceGroupName `
            -CurrentZoneName $zoneName
        $zoneId = New-PrivateDnsZoneResourceId `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $destinationResourceGroupName `
            -CurrentZoneName $zoneName
        $body = @{
            location   = 'global'
            properties = @{}
        }
        $target = "$DestinationSubscriptionId/$destinationResourceGroupName/$zoneName"

        if ($ScriptCommand.ShouldProcess($target, 'Create destination private DNS zone')) {
            Invoke-ArmJson -Method PUT -Path $zonePath -Body $body -ExpectedStatusCode @(200, 201, 202) | Out-Null
        }

        $createdZone = [pscustomobject]@{
            Name              = $zoneName
            ResourceGroupName = $destinationResourceGroupName
            Id                = $zoneId
        }
        $results.Add($createdZone)
        $destinationZoneLookup[$zoneKey] = New-Object System.Collections.Generic.List[object]
        $destinationZoneLookup[$zoneKey].Add($createdZone)
    }

    return $results
}

function Get-PrivateDnsARecordRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [object[]]$Zones,

        [switch]$AllowApex
    )

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($currentZone in @($Zones)) {
        $path = New-PrivateDnsRecordSetPath `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $currentZone.ResourceGroupName `
            -CurrentZoneName $currentZone.Name
        $recordSets = Get-ArmPagedValues -Path $path

        foreach ($recordSet in @($recordSets)) {
            $recordName = [string]$recordSet.name

            if (-not $AllowApex -and $recordName -eq '@') {
                continue
            }

            $recordSetProperties = Get-ObjectPropertyValue -InputObject $recordSet -Name 'properties'
            $aRecords = Get-ObjectPropertyValue -InputObject $recordSetProperties -Name 'aRecords'
            $recordSetTtl = Get-ObjectPropertyValue -InputObject $recordSetProperties -Name 'ttl'

            foreach ($aRecord in @($aRecords)) {
                if ($null -eq $aRecord) {
                    continue
                }

                $rows.Add([pscustomobject]@{
                    ZoneName                    = [string]$currentZone.Name
                    SourceZoneResourceGroupName = [string]$currentZone.ResourceGroupName
                    RecordName                  = $recordName
                    IPv4Address                 = [string]$aRecord.ipv4Address
                    TTL                         = [int]$recordSetTtl
                })
            }
        }
    }

    return $rows
}

function Assert-IPv4Address {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsedAddress)) {
        throw "'$Value' is not a valid IP address."
    }

    if ($parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "'$Value' is not an IPv4 address. Private DNS A records require IPv4 values."
    }
}

function ConvertTo-ValidatedRecordRows {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [bool]$UseOverrideTtl,

        [int]$OverrideTtl
    )

    $validatedRows = New-Object System.Collections.Generic.List[object]

    foreach ($row in @($Rows)) {
        $currentZoneName = ([string]$row.ZoneName).Trim()
        $sourceZoneResourceGroupName = ([string]$row.SourceZoneResourceGroupName).Trim()
        $recordName = ([string]$row.RecordName).Trim()
        $ipAddress = ([string]$row.IPv4Address).Trim()

        if (-not $currentZoneName -or -not $sourceZoneResourceGroupName -or -not $recordName -or -not $ipAddress) {
            throw 'Every record row must include ZoneName, SourceZoneResourceGroupName, RecordName, and IPv4Address.'
        }

        Assert-IPv4Address -Value $ipAddress

        if ($UseOverrideTtl) {
            $effectiveTtl = $OverrideTtl
        }
        elseif ($row.PSObject.Properties.Name -contains 'TTL' -and $row.TTL) {
            $effectiveTtl = [int]$row.TTL
        }
        else {
            $effectiveTtl = 300
        }

        $validatedRows.Add([pscustomobject]@{
            ZoneName                    = $currentZoneName
            SourceZoneResourceGroupName = $sourceZoneResourceGroupName
            RecordName                  = $recordName
            IPv4Address                 = $ipAddress
            TTL                         = $effectiveTtl
        })
    }

    return $validatedRows
}

function Get-PrivateDnsARecordSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName
    )

    $path = New-PrivateDnsRecordSetPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordName $RecordName

    return Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200) -AllowNotFound
}

function Get-PrivateDnsTxtRecordSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName
    )

    $path = New-PrivateDnsRecordSetPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordType 'TXT' `
        -RecordName $RecordName

    return Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200) -AllowNotFound
}

function ConvertTo-DnsTxtStrings {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Values
    )

    $strings = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        $remainingValue = [string]$value
        if ($remainingValue.Length -eq 0) {
            $strings.Add('')
            continue
        }

        while ($remainingValue.Length -gt 255) {
            $strings.Add($remainingValue.Substring(0, 255))
            $remainingValue = $remainingValue.Substring(255)
        }

        $strings.Add($remainingValue)
    }

    return @($strings.ToArray())
}

function New-ProvenanceTxtValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string[]]$SourceResourceGroupNames,

        [Parameter(Mandatory = $true)]
        [string]$SourceZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName,

        [Parameter(Mandatory = $true)]
        [string[]]$IPv4Addresses
    )

    $values = @(
        $ProvenanceTxtRecordMarker
        "sourceSubscriptionId=$SourceSubscriptionId"
        "sourceResourceGroups=$(@($SourceResourceGroupNames | Sort-Object -Unique) -join ',')"
        "sourceZone=$SourceZoneName"
        "sourceRecord=$RecordName"
        "sourceIPv4Addresses=$(@($IPv4Addresses | Sort-Object -Unique) -join ',')"
        'managedBy=Sync-PrivateEndpointPrivateDns.ps1'
    )

    return ConvertTo-DnsTxtStrings -Values $values
}

function Get-TxtRecordValues {
    param(
        [object]$TxtRecord
    )

    return @((Get-ObjectPropertyValue -InputObject $TxtRecord -Name 'value') | ForEach-Object { [string]$_ })
}

function ConvertTo-NormalizedFqdn {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Trim().TrimEnd('.').ToLowerInvariant()
}

function New-PrivateDnsRecordFqdn {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName
    )

    $normalizedZoneName = ConvertTo-NormalizedFqdn -Value $CurrentZoneName
    $normalizedRecordName = $RecordName.Trim().TrimEnd('.').ToLowerInvariant()

    if ($normalizedRecordName -eq '@') {
        return $normalizedZoneName
    }

    return "$normalizedRecordName.$normalizedZoneName"
}

function Get-PrivateEndpointDnsDetails {
    param(
        [Parameter(Mandatory = $true)]
        [object]$PrivateEndpoint
    )

    $properties = Get-ObjectPropertyValue -InputObject $PrivateEndpoint -Name 'properties'
    $privateIpAddresses = New-Object System.Collections.Generic.List[string]
    $fqdns = New-Object System.Collections.Generic.List[string]

    foreach ($customDnsConfig in @(Get-ObjectPropertyValue -InputObject $properties -Name 'customDnsConfigs')) {
        if ($null -eq $customDnsConfig) {
            continue
        }

        $fqdn = Get-ObjectPropertyValue -InputObject $customDnsConfig -Name 'fqdn'
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
            $normalizedFqdn = ConvertTo-NormalizedFqdn -Value ([string]$fqdn)
            if (-not $fqdns.Contains($normalizedFqdn)) {
                $fqdns.Add($normalizedFqdn)
            }
        }

        foreach ($ipAddress in @(Get-ObjectPropertyValue -InputObject $customDnsConfig -Name 'ipAddresses')) {
            if ([string]::IsNullOrWhiteSpace($ipAddress)) {
                continue
            }

            $normalizedIpAddress = ([string]$ipAddress).Trim()
            if (-not $privateIpAddresses.Contains($normalizedIpAddress)) {
                $privateIpAddresses.Add($normalizedIpAddress)
            }
        }
    }

    foreach ($networkInterfaceReference in @(Get-ObjectPropertyValue -InputObject $properties -Name 'networkInterfaces')) {
        if ($null -eq $networkInterfaceReference) {
            continue
        }

        $networkInterfaceId = Get-ObjectPropertyValue -InputObject $networkInterfaceReference -Name 'id'
        if ([string]::IsNullOrWhiteSpace($networkInterfaceId)) {
            continue
        }

        $networkInterface = Invoke-ArmJson `
            -Method GET `
            -Path "${networkInterfaceId}?api-version=$NetworkApiVersion" `
            -ExpectedStatusCode @(200) `
            -AllowNotFound
        if ($null -eq $networkInterface) {
            continue
        }

        $networkInterfaceProperties = Get-ObjectPropertyValue -InputObject $networkInterface -Name 'properties'
        foreach ($ipConfiguration in @(Get-ObjectPropertyValue -InputObject $networkInterfaceProperties -Name 'ipConfigurations')) {
            if ($null -eq $ipConfiguration) {
                continue
            }

            $ipConfigurationProperties = Get-ObjectPropertyValue -InputObject $ipConfiguration -Name 'properties'
            $privateIpAddress = Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateIPAddress'
            if (-not [string]::IsNullOrWhiteSpace($privateIpAddress)) {
                $normalizedIpAddress = ([string]$privateIpAddress).Trim()
                if (-not $privateIpAddresses.Contains($normalizedIpAddress)) {
                    $privateIpAddresses.Add($normalizedIpAddress)
                }
            }

            $privateLinkConnectionProperties = Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateLinkConnectionProperties'
            foreach ($fqdn in @(Get-ObjectPropertyValue -InputObject $privateLinkConnectionProperties -Name 'fqdns')) {
                if ([string]::IsNullOrWhiteSpace($fqdn)) {
                    continue
                }

                $normalizedFqdn = ConvertTo-NormalizedFqdn -Value ([string]$fqdn)
                if (-not $fqdns.Contains($normalizedFqdn)) {
                    $fqdns.Add($normalizedFqdn)
                }
            }
        }
    }

    foreach ($ipConfiguration in @(Get-ObjectPropertyValue -InputObject $properties -Name 'ipConfigurations')) {
        if ($null -eq $ipConfiguration) {
            continue
        }

        $ipConfigurationProperties = Get-ObjectPropertyValue -InputObject $ipConfiguration -Name 'properties'
        $privateIpAddress = Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateIPAddress'
        if (-not [string]::IsNullOrWhiteSpace($privateIpAddress)) {
            $normalizedIpAddress = ([string]$privateIpAddress).Trim()
            if (-not $privateIpAddresses.Contains($normalizedIpAddress)) {
                $privateIpAddresses.Add($normalizedIpAddress)
            }
        }

        $privateLinkConnectionProperties = Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateLinkConnectionProperties'
        foreach ($fqdn in @(Get-ObjectPropertyValue -InputObject $privateLinkConnectionProperties -Name 'fqdns')) {
            if ([string]::IsNullOrWhiteSpace($fqdn)) {
                continue
            }

            $normalizedFqdn = ConvertTo-NormalizedFqdn -Value ([string]$fqdn)
            if (-not $fqdns.Contains($normalizedFqdn)) {
                $fqdns.Add($normalizedFqdn)
            }
        }
    }

    return [pscustomobject]@{
        Name               = [string]$PrivateEndpoint.name
        ResourceGroupName  = Get-ResourceGroupNameFromResourceId -ResourceId ([string]$PrivateEndpoint.id)
        Id                 = [string]$PrivateEndpoint.id
        Fqdns              = @($fqdns.ToArray())
        PrivateIpAddresses = @($privateIpAddresses.ToArray())
    }
}

function Get-PrivateEndpointDnsDetailsInSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    $path = "/subscriptions/$SubscriptionId/providers/Microsoft.Network/privateEndpoints?api-version=$NetworkApiVersion"
    $privateEndpoints = Get-ArmPagedValues -Path $path
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($privateEndpoint in @($privateEndpoints)) {
        $results.Add((Get-PrivateEndpointDnsDetails -PrivateEndpoint $privateEndpoint))
    }

    return $results
}

function Find-SourcePrivateEndpointsForDnsRecord {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$PrivateEndpoints,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName,

        [Parameter(Mandatory = $true)]
        [string]$IPv4Address
    )

    $recordFqdn = New-PrivateDnsRecordFqdn -CurrentZoneName $CurrentZoneName -RecordName $RecordName
    $normalizedIpAddress = $IPv4Address.Trim()
    $strongMatches = New-Object System.Collections.Generic.List[object]
    $fqdnOnlyMatches = New-Object System.Collections.Generic.List[object]
    $ipOnlyMatches = New-Object System.Collections.Generic.List[object]

    foreach ($privateEndpoint in @($PrivateEndpoints)) {
        $matchesFqdn = @($privateEndpoint.Fqdns) -contains $recordFqdn
        $matchesIpAddress = @($privateEndpoint.PrivateIpAddresses) -contains $normalizedIpAddress

        if ($matchesFqdn -and $matchesIpAddress) {
            $strongMatches.Add([pscustomobject]@{ PrivateEndpoint = $privateEndpoint; MatchType = 'FqdnAndIp'; IsAmbiguous = $false })
        }
        elseif ($matchesFqdn) {
            $fqdnOnlyMatches.Add([pscustomobject]@{ PrivateEndpoint = $privateEndpoint; MatchType = 'Fqdn'; IsAmbiguous = $false })
        }
        elseif ($matchesIpAddress) {
            $ipOnlyMatches.Add([pscustomobject]@{ PrivateEndpoint = $privateEndpoint; MatchType = 'Ip'; IsAmbiguous = $false })
        }
    }

    if ($strongMatches.Count -gt 0) {
        return $strongMatches
    }

    if ($fqdnOnlyMatches.Count -gt 0) {
        return $fqdnOnlyMatches
    }

    if ($ipOnlyMatches.Count -eq 1) {
        return $ipOnlyMatches
    }

    if ($ipOnlyMatches.Count -gt 1) {
        foreach ($ipOnlyMatch in $ipOnlyMatches) {
            $ipOnlyMatch.IsAmbiguous = $true
            $ipOnlyMatch.MatchType = 'AmbiguousIp'
        }

        return $ipOnlyMatches
    }

    return @()
}

function New-PrivateDnsZoneGroupPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrivateEndpointId,

        [Parameter(Mandatory = $true)]
        [string]$ZoneGroupName
    )

    $zoneGroupSegment = ConvertTo-ArmPathSegment -Value $ZoneGroupName
    return "${PrivateEndpointId}/privateDnsZoneGroups/${zoneGroupSegment}?api-version=$NetworkApiVersion"
}

function New-ShortHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant()))
        return -join ($hashBytes[0..3] | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha1.Dispose()
    }
}

function New-PrivateDnsZoneConfigName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$PrivateDnsZoneId,

        [string[]]$ExistingConfigNames
    )

    $baseName = $CurrentZoneName.ToLowerInvariant() -replace '[^a-z0-9]', '-'
    $baseName = $baseName.Trim('-')
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = 'private-dns-zone'
    }

    if ($baseName.Length -gt 80) {
        $baseName = $baseName.Substring(0, 80).Trim('-')
    }

    if (@($ExistingConfigNames) -notcontains $baseName) {
        return $baseName
    }

    $suffix = New-ShortHash -Value $PrivateDnsZoneId
    $maxBaseLength = 80 - $suffix.Length - 1
    if ($baseName.Length -gt $maxBaseLength) {
        $baseName = $baseName.Substring(0, $maxBaseLength).Trim('-')
    }

    return "$baseName-$suffix"
}

function Set-PrivateEndpointPrivateDnsZoneGroup {
    param(
        [Parameter(Mandatory = $true)]
        [object]$PrivateEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPrivateDnsZoneId,

        [Parameter(Mandatory = $true)]
        [string]$ZoneGroupName
    )

    $path = New-PrivateDnsZoneGroupPath -PrivateEndpointId $PrivateEndpoint.Id -ZoneGroupName $ZoneGroupName
    $existingGroup = Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200) -AllowNotFound
    $existingConfigs = New-Object System.Collections.Generic.List[object]
    $existingConfigNames = New-Object System.Collections.Generic.List[string]
    $destinationPrivateDnsZoneIdKey = $DestinationPrivateDnsZoneId.ToLowerInvariant()
    $currentZoneNameKey = $CurrentZoneName.ToLowerInvariant()
    $replacementConfigName = $null
    $replacedSameZoneConfig = $false
    $destinationConfigFound = $false
    $destinationConfigName = $null

    if ($existingGroup) {
        $existingGroupProperties = Get-ObjectPropertyValue -InputObject $existingGroup -Name 'properties'
        foreach ($existingConfig in @(Get-ObjectPropertyValue -InputObject $existingGroupProperties -Name 'privateDnsZoneConfigs')) {
            if ($null -eq $existingConfig) {
                continue
            }

            $existingConfigName = [string]$existingConfig.name
            $existingConfigProperties = Get-ObjectPropertyValue -InputObject $existingConfig -Name 'properties'
            $existingPrivateDnsZoneId = [string](Get-ObjectPropertyValue -InputObject $existingConfigProperties -Name 'privateDnsZoneId')

            if (-not [string]::IsNullOrWhiteSpace($existingConfigName) -and -not $existingConfigNames.Contains($existingConfigName)) {
                $existingConfigNames.Add($existingConfigName)
            }

            if (-not [string]::IsNullOrWhiteSpace($existingPrivateDnsZoneId)) {
                if ($existingPrivateDnsZoneId.ToLowerInvariant() -eq $destinationPrivateDnsZoneIdKey) {
                    $destinationConfigFound = $true
                    $destinationConfigName = $existingConfigName
                    $existingConfigs.Add(@{
                        name       = $existingConfigName
                        properties = @{
                            privateDnsZoneId = $existingPrivateDnsZoneId
                        }
                    })
                    continue
                }

                if ($existingPrivateDnsZoneId -match '/privateDnsZones/([^/]+)$') {
                    $existingZoneName = [System.Uri]::UnescapeDataString($Matches[1])
                    if ($existingZoneName.ToLowerInvariant() -eq $currentZoneNameKey) {
                        $replacementConfigName = $existingConfigName
                        $replacedSameZoneConfig = $true
                        continue
                    }
                }

                $existingConfigs.Add(@{
                    name       = $existingConfigName
                    properties = @{
                        privateDnsZoneId = $existingPrivateDnsZoneId
                    }
                })
            }
        }
    }

    if ($destinationConfigFound -and -not $replacedSameZoneConfig) {
        return [pscustomobject]@{
            PrivateEndpointName        = $PrivateEndpoint.Name
            PrivateEndpointId          = $PrivateEndpoint.Id
            ZoneName                   = $CurrentZoneName
            DestinationPrivateDnsZoneId = $DestinationPrivateDnsZoneId
            PrivateDnsZoneGroupName    = $ZoneGroupName
            PrivateDnsZoneConfigName   = $destinationConfigName
            Operation                  = 'ZoneGroupNoChange'
            Changed                    = $false
        }
    }

    if ($destinationConfigFound) {
        $newConfigName = $destinationConfigName
    }
    elseif ($replacementConfigName) {
        $newConfigName = $replacementConfigName
    }
    else {
        $newConfigName = New-PrivateDnsZoneConfigName `
            -CurrentZoneName $CurrentZoneName `
            -PrivateDnsZoneId $DestinationPrivateDnsZoneId `
            -ExistingConfigNames @($existingConfigNames.ToArray())
    }

    if (-not $destinationConfigFound) {
        $existingConfigs.Add(@{
            name       = $newConfigName
            properties = @{
                privateDnsZoneId = $DestinationPrivateDnsZoneId
            }
        })
    }

    $operation = if ($existingGroup) {
        if ($destinationConfigFound -and $replacedSameZoneConfig) { 'ZoneGroupRemoveDuplicateConfig' }
        elseif ($replacedSameZoneConfig) { 'ZoneGroupReplaceConfig' }
        else { 'ZoneGroupAddConfig' }
    }
    else {
        'ZoneGroupCreate'
    }
    $body = @{
        properties = @{
            privateDnsZoneConfigs = @($existingConfigs.ToArray())
        }
    }
    $target = "$($PrivateEndpoint.Id)/privateDnsZoneGroups/$ZoneGroupName -> $DestinationPrivateDnsZoneId"

    if ($ScriptCommand.ShouldProcess($target, 'Link source private endpoint to destination private DNS zone')) {
        Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201) | Out-Null
    }

    return [pscustomobject]@{
        PrivateEndpointName        = $PrivateEndpoint.Name
        PrivateEndpointId          = $PrivateEndpoint.Id
        ZoneName                   = $CurrentZoneName
        DestinationPrivateDnsZoneId = $DestinationPrivateDnsZoneId
        PrivateDnsZoneGroupName    = $ZoneGroupName
        PrivateDnsZoneConfigName   = $newConfigName
        Operation                  = $operation
        Changed                    = $true
    }
}

function Test-StringSetEqual {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    $leftSet = @($Left | Sort-Object -Unique)
    $rightSet = @($Right | Sort-Object -Unique)

    if ($leftSet.Count -ne $rightSet.Count) {
        return $false
    }

    for ($index = 0; $index -lt $leftSet.Count; $index++) {
        if ($leftSet[$index] -ne $rightSet[$index]) {
            return $false
        }
    }

    return $true
}

function ConvertTo-ComparableJson {
    param(
        [object]$InputObject
    )

    return ($InputObject | ConvertTo-Json -Depth 20 -Compress)
}

function Set-PrivateDnsTxtRecordSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName,

        [Parameter(Mandatory = $true)]
        [string[]]$TxtValues,

        [Parameter(Mandatory = $true)]
        [int]$RecordTtl
    )

    $existingRecordSet = Get-PrivateDnsTxtRecordSet `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordName $RecordName
    $preservedTxtRecords = New-Object System.Collections.Generic.List[object]
    $existingManagedTxtValues = @()
    $existingTtl = $null

    if ($existingRecordSet) {
        $existingProperties = Get-ObjectPropertyValue -InputObject $existingRecordSet -Name 'properties'
        $existingTtl = [int](Get-ObjectPropertyValue -InputObject $existingProperties -Name 'ttl')

        foreach ($existingTxtRecord in @(Get-ObjectPropertyValue -InputObject $existingProperties -Name 'txtRecords')) {
            if ($null -eq $existingTxtRecord) {
                continue
            }

            $existingValues = @(Get-TxtRecordValues -TxtRecord $existingTxtRecord)
            if ($existingValues.Count -gt 0 -and $existingValues[0] -eq $ProvenanceTxtRecordMarker) {
                $existingManagedTxtValues = $existingValues
                continue
            }

            $preservedTxtRecords.Add(@{ value = @($existingValues) })
        }
    }

    $desiredTtl = if ($existingRecordSet) { $existingTtl } else { $RecordTtl }
    $desiredTxtRecords = New-Object System.Collections.Generic.List[object]
    foreach ($preservedTxtRecord in @($preservedTxtRecords.ToArray())) {
        $desiredTxtRecords.Add($preservedTxtRecord)
    }

    $desiredTxtRecords.Add(@{ value = @($TxtValues) })
    $existingComparable = ConvertTo-ComparableJson -InputObject @{
        ttl        = $existingTtl
        txtRecords = @($preservedTxtRecords.ToArray()) + @(@{ value = @($existingManagedTxtValues) })
    }
    $desiredComparable = ConvertTo-ComparableJson -InputObject @{
        ttl        = $desiredTtl
        txtRecords = @($desiredTxtRecords.ToArray())
    }

    if ($existingRecordSet -and $existingComparable -eq $desiredComparable) {
        return [pscustomobject]@{
            ZoneName      = $CurrentZoneName
            RecordName    = $RecordName
            Operation     = 'TxtNoChange'
            TxtValues     = ($TxtValues -join ';')
            TTL           = $desiredTtl
            Changed       = $false
        }
    }

    $body = @{
        properties = @{
            ttl        = $desiredTtl
            txtRecords = @($desiredTxtRecords.ToArray())
        }
    }
    $path = New-PrivateDnsRecordSetPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordType 'TXT' `
        -RecordName $RecordName
    $operation = if ($existingRecordSet) { 'TxtUpdate' } else { 'TxtCreate' }
    $target = "$SubscriptionId/$ResourceGroupName/$CurrentZoneName/TXT/$RecordName"

    if ($ScriptCommand.ShouldProcess($target, "$operation provenance TXT record set")) {
        Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201) | Out-Null
    }

    return [pscustomobject]@{
        ZoneName      = $CurrentZoneName
        RecordName    = $RecordName
        Operation     = $operation
        TxtValues     = ($TxtValues -join ';')
        TTL           = $desiredTtl
        Changed       = $true
    }
}

function Set-PrivateDnsARecordSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName,

        [Parameter(Mandatory = $true)]
        [string[]]$IPv4Addresses,

        [Parameter(Mandatory = $true)]
        [int]$RecordTtl,

        [switch]$Replace
    )

    $existingRecordSet = Get-PrivateDnsARecordSet `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordName $RecordName
    $existingIpAddresses = @()
    $existingTtl = $null

    if ($existingRecordSet) {
        $existingProperties = Get-ObjectPropertyValue -InputObject $existingRecordSet -Name 'properties'
        $existingARecords = Get-ObjectPropertyValue -InputObject $existingProperties -Name 'aRecords'
        $existingIpAddresses = @($existingARecords | ForEach-Object { [string]$_.ipv4Address })
        $existingTtl = [int](Get-ObjectPropertyValue -InputObject $existingProperties -Name 'ttl')
    }

    if ($existingRecordSet -and -not $Replace) {
        $desiredIpAddresses = @($existingIpAddresses + $IPv4Addresses | Sort-Object -Unique)
        $desiredTtl = $existingTtl
        $operation = 'Merge'
    }
    else {
        $desiredIpAddresses = @($IPv4Addresses | Sort-Object -Unique)
        $desiredTtl = $RecordTtl
        $operation = if ($existingRecordSet) { 'Replace' } else { 'Create' }
    }

    if ($existingRecordSet -and (Test-StringSetEqual -Left $existingIpAddresses -Right $desiredIpAddresses) -and $existingTtl -eq $desiredTtl) {
        return [pscustomobject]@{
            ZoneName      = $CurrentZoneName
            RecordName    = $RecordName
            Operation     = 'NoChange'
            IPv4Addresses = ($desiredIpAddresses -join ',')
            TTL           = $desiredTtl
            Changed       = $false
        }
    }

    $body = @{
        properties = @{
            ttl      = $desiredTtl
            aRecords = @($desiredIpAddresses | ForEach-Object { @{ ipv4Address = $_ } })
        }
    }
    $path = New-PrivateDnsRecordSetPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordName $RecordName
    $target = "$SubscriptionId/$ResourceGroupName/$CurrentZoneName/A/$RecordName"

    if ($ScriptCommand.ShouldProcess($target, "$operation private DNS A record set")) {
        Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201) | Out-Null
    }

    return [pscustomobject]@{
        ZoneName      = $CurrentZoneName
        RecordName    = $RecordName
        Operation     = $operation
        IPv4Addresses = ($desiredIpAddresses -join ',')
        TTL           = $desiredTtl
        Changed       = $true
    }
}

function Remove-PrivateDnsARecordSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName
    )

    $path = New-PrivateDnsRecordSetPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordName $RecordName
    $target = "$SubscriptionId/$ResourceGroupName/$CurrentZoneName/A/$RecordName"

    if ($ScriptCommand.ShouldProcess($target, 'Delete source private DNS A record set')) {
        Invoke-ArmJson -Method DELETE -Path $path -ExpectedStatusCode @(200, 202, 204) | Out-Null
    }
}

function New-ZoneLookup {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Zones
    )

    $lookup = @{}
    foreach ($currentZone in @($Zones)) {
        $key = ([string]$currentZone.Name).ToLowerInvariant()
        if (-not $lookup.ContainsKey($key)) {
            $lookup[$key] = New-Object System.Collections.Generic.List[object]
        }

        $lookup[$key].Add($currentZone)
    }

    return $lookup
}

Select-AzureSubscription `
    -SubscriptionId $SourceSubscriptionId `
    -EnvironmentName $AzureChinaEnvironmentName `
    -TenantId $SourceTenantId
$sourceZones = @(Get-PrivateDnsZonesInSubscription -SubscriptionId $SourceSubscriptionId)
$sourceZonesToSync = @(Select-ZonesForSync `
    -Zones $sourceZones `
    -RequestedZoneNames $ZoneName `
    -EnvironmentName $AzureChinaEnvironmentName)

if ($sourceZonesToSync.Count -eq 0) {
    throw 'No supported source Azure PaaS Private Link private DNS zones matched the scan criteria.'
}

$sourceRows = @(Get-PrivateDnsARecordRows `
    -SubscriptionId $SourceSubscriptionId `
    -Zones $sourceZonesToSync `
    -AllowApex:$IncludeApex)
$validatedRows = @(ConvertTo-ValidatedRecordRows `
    -Rows $sourceRows `
    -UseOverrideTtl $UseTtlOverride `
    -OverrideTtl $Ttl)

if ($validatedRows.Count -eq 0) {
    throw 'No source Azure PaaS Private Link private DNS A records matched the scan criteria.'
}

$sourcePrivateEndpoints = @()
if ($ShouldLinkSourcePrivateEndpointsToDestinationZones) {
    Write-Host 'Reading source private endpoints to match DNS records...'
    $sourcePrivateEndpoints = @(Get-PrivateEndpointDnsDetailsInSubscription -SubscriptionId $SourceSubscriptionId)
    if ($sourcePrivateEndpoints.Count -eq 0) {
        Write-Warning 'No source private endpoints were found. DNS records can still be synced, but no private endpoint DNS zone group links can be added.'
    }
}

Select-AzureSubscription `
    -SubscriptionId $DestinationSubscriptionId `
    -EnvironmentName $AzureChinaEnvironmentName `
    -TenantId $DestinationTenantId
$destinationZones = @(Get-PrivateDnsZonesInSubscription -SubscriptionId $DestinationSubscriptionId)
$destinationZonesToSync = @(Select-ZonesForSync `
    -Zones $destinationZones `
    -RequestedZoneNames $ZoneName `
    -EnvironmentName $AzureChinaEnvironmentName)
$destinationZonesToSync = @(Confirm-DestinationPrivateDnsZones `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -SourceZones $sourceZonesToSync `
    -DestinationZones $destinationZonesToSync `
    -ResourceGroupNameOverride $DestinationPrivateDnsZoneResourceGroupName `
    -ResourceGroupLocation $DestinationResourceGroupLocation `
    -UseResourceGroupLocationOverride $UseDestinationResourceGroupLocationOverride `
    -SkipCreate:$SkipCreateMissingDestinationZones)
$destinationZoneLookup = New-ZoneLookup -Zones $destinationZonesToSync

$results = New-Object System.Collections.Generic.List[object]
$skippedZones = New-Object System.Collections.Generic.List[string]
$recordGroups = $validatedRows | Group-Object ZoneName, RecordName

foreach ($recordGroup in $recordGroups) {
    $firstRow = $recordGroup.Group[0]
    $zoneKey = ([string]$firstRow.ZoneName).ToLowerInvariant()

    if (-not $destinationZoneLookup.ContainsKey($zoneKey)) {
        if (-not $skippedZones.Contains($firstRow.ZoneName)) {
            $skippedZones.Add($firstRow.ZoneName)
        }

        continue
    }

    $matchingDestinationZones = @($destinationZoneLookup[$zoneKey].ToArray())
    if ($matchingDestinationZones.Count -gt 1) {
        $resourceGroups = @($matchingDestinationZones | ForEach-Object { $_.ResourceGroupName }) -join ', '
        throw "Destination subscription has multiple private DNS zones named '$($firstRow.ZoneName)' in resource groups: $resourceGroups. Subscription IDs alone are ambiguous."
    }

    $destinationZone = $matchingDestinationZones[0]
    $groupTtls = @($recordGroup.Group | ForEach-Object { [int]$_.TTL } | Sort-Object -Unique)
    if ($groupTtls.Count -gt 1 -and -not $UseTtlOverride) {
        Write-Warning "Multiple TTL values found for $($firstRow.ZoneName)/$($firstRow.RecordName). Using $($groupTtls[0])."
    }

    $ipAddresses = @($recordGroup.Group | ForEach-Object { [string]$_.IPv4Address } | Sort-Object -Unique)
    $syncResult = [pscustomobject]@{
        ZoneName      = $firstRow.ZoneName
        RecordName    = $firstRow.RecordName
        Operation     = 'ZoneGroupManaged'
        IPv4Addresses = ($ipAddresses -join ',')
        TTL           = $groupTtls[0]
        Changed       = $false
    }
    $provenanceTxtRecordOperation = 'TxtSkipped'
    $provenanceTxtRecordChanged = $false
    $provenanceTxtRecordValues = @()
    $sourcePrivateEndpointMatches = @()
    $privateDnsZoneGroupOperations = @()
    $privateDnsZoneGroupChanged = $false
    $linkableMatches = @()

    if ($ShouldLinkSourcePrivateEndpointsToDestinationZones) {
        $sourcePrivateEndpointMatchLookup = @{}

        foreach ($row in @($recordGroup.Group)) {
            $rowMatches = @(Find-SourcePrivateEndpointsForDnsRecord `
                    -PrivateEndpoints $sourcePrivateEndpoints `
                    -CurrentZoneName $row.ZoneName `
                    -RecordName $row.RecordName `
                    -IPv4Address $row.IPv4Address)

            foreach ($rowMatch in $rowMatches) {
                $privateEndpointId = [string]$rowMatch.PrivateEndpoint.Id
                $existingMatch = $sourcePrivateEndpointMatchLookup[$privateEndpointId]

                if (-not $existingMatch -or ($existingMatch.MatchType -ne 'FqdnAndIp' -and $rowMatch.MatchType -eq 'FqdnAndIp')) {
                    $sourcePrivateEndpointMatchLookup[$privateEndpointId] = $rowMatch
                }
            }
        }

        $sourcePrivateEndpointMatches = @($sourcePrivateEndpointMatchLookup.Values)
        if ($sourcePrivateEndpointMatches.Count -eq 0) {
            Write-Warning "No source private endpoint matched DNS record '$($firstRow.RecordName).$($firstRow.ZoneName)' with IP(s) '$($ipAddresses -join ',')'."
        }
        else {
            $ambiguousMatches = @($sourcePrivateEndpointMatches | Where-Object { $_.IsAmbiguous })
            foreach ($ambiguousMatch in $ambiguousMatches) {
                Write-Warning "Skipped ambiguous source private endpoint match '$($ambiguousMatch.PrivateEndpoint.Name)' for '$($firstRow.RecordName).$($firstRow.ZoneName)'. Match type: $($ambiguousMatch.MatchType)."
            }

            $linkableMatches = @($sourcePrivateEndpointMatches | Where-Object { -not $_.IsAmbiguous })
            if ($linkableMatches.Count -gt 0) {
                Select-AzureSubscription `
                    -SubscriptionId $SourceSubscriptionId `
                    -EnvironmentName $AzureChinaEnvironmentName `
                    -TenantId $SourceTenantId

                foreach ($linkableMatch in $linkableMatches) {
                    $zoneGroupResult = Set-PrivateEndpointPrivateDnsZoneGroup `
                        -PrivateEndpoint $linkableMatch.PrivateEndpoint `
                        -CurrentZoneName $firstRow.ZoneName `
                        -DestinationPrivateDnsZoneId $destinationZone.Id `
                        -ZoneGroupName $PrivateDnsZoneGroupName

                    $privateDnsZoneGroupOperations += "$($zoneGroupResult.PrivateEndpointName):$($zoneGroupResult.Operation)"
                    if ($zoneGroupResult.Changed) {
                        $privateDnsZoneGroupChanged = $true
                    }
                }

                Select-AzureSubscription `
                    -SubscriptionId $DestinationSubscriptionId `
                    -EnvironmentName $AzureChinaEnvironmentName `
                    -TenantId $DestinationTenantId
            }
        }
    }

    $shouldSyncRecordDirectly = (-not $ShouldLinkSourcePrivateEndpointsToDestinationZones) -or $linkableMatches.Count -eq 0
    if ($shouldSyncRecordDirectly) {
        $syncResult = Set-PrivateDnsARecordSet `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $destinationZone.ResourceGroupName `
            -CurrentZoneName $firstRow.ZoneName `
            -RecordName $firstRow.RecordName `
            -IPv4Addresses $ipAddresses `
            -RecordTtl $groupTtls[0] `
            -Replace:$ReplaceExisting

        if (-not $SkipProvenanceTxtRecord) {
            $sourceResourceGroupNames = @($recordGroup.Group | ForEach-Object { [string]$_.SourceZoneResourceGroupName } | Sort-Object -Unique)
            $provenanceTxtRecordValues = @(New-ProvenanceTxtValues `
                    -SourceSubscriptionId $SourceSubscriptionId `
                    -SourceResourceGroupNames $sourceResourceGroupNames `
                    -SourceZoneName $firstRow.ZoneName `
                    -RecordName $firstRow.RecordName `
                    -IPv4Addresses $ipAddresses)
            $provenanceTxtRecordResult = Set-PrivateDnsTxtRecordSet `
                -SubscriptionId $DestinationSubscriptionId `
                -ResourceGroupName $destinationZone.ResourceGroupName `
                -CurrentZoneName $firstRow.ZoneName `
                -RecordName $firstRow.RecordName `
                -TxtValues $provenanceTxtRecordValues `
                -RecordTtl $groupTtls[0]

            $provenanceTxtRecordOperation = $provenanceTxtRecordResult.Operation
            $provenanceTxtRecordChanged = $provenanceTxtRecordResult.Changed
        }
    }
    elseif (-not $SkipProvenanceTxtRecord) {
        $provenanceTxtRecordOperation = 'TxtSkippedZoneGroupManaged'
    }

    $results.Add([pscustomobject]@{
        ZoneName                         = $syncResult.ZoneName
        RecordName                       = $syncResult.RecordName
        DestinationZoneResourceGroupName = $destinationZone.ResourceGroupName
        Operation                        = $syncResult.Operation
        IPv4Addresses                    = $syncResult.IPv4Addresses
        TTL                              = $syncResult.TTL
        Changed                          = $syncResult.Changed
        SourcePrivateEndpointNames       = (@($sourcePrivateEndpointMatches | Where-Object { -not $_.IsAmbiguous } | ForEach-Object { $_.PrivateEndpoint.Name } | Sort-Object -Unique) -join ',')
        SourcePrivateEndpointIds         = (@($sourcePrivateEndpointMatches | Where-Object { -not $_.IsAmbiguous } | ForEach-Object { $_.PrivateEndpoint.Id } | Sort-Object -Unique) -join ',')
        SourcePrivateEndpointMatchTypes  = (@($sourcePrivateEndpointMatches | Where-Object { -not $_.IsAmbiguous } | ForEach-Object { "$($_.PrivateEndpoint.Name):$($_.MatchType)" } | Sort-Object -Unique) -join ',')
        PrivateDnsZoneGroupOperations    = ($privateDnsZoneGroupOperations -join ',')
        PrivateDnsZoneGroupChanged       = $privateDnsZoneGroupChanged
        ProvenanceTxtRecordOperation     = $provenanceTxtRecordOperation
        ProvenanceTxtRecordChanged       = $provenanceTxtRecordChanged
        ProvenanceTxtRecordValues        = ($provenanceTxtRecordValues -join ';')
    })

    if ($RemoveSourceAfterCopy) {
        Select-AzureSubscription `
            -SubscriptionId $SourceSubscriptionId `
            -EnvironmentName $AzureChinaEnvironmentName `
            -TenantId $SourceTenantId
        $sourceRecordSets = @($recordGroup.Group | Select-Object ZoneName, SourceZoneResourceGroupName, RecordName -Unique)

        foreach ($sourceRecordSet in $sourceRecordSets) {
            Remove-PrivateDnsARecordSet `
                -SubscriptionId $SourceSubscriptionId `
                -ResourceGroupName $sourceRecordSet.SourceZoneResourceGroupName `
                -CurrentZoneName $sourceRecordSet.ZoneName `
                -RecordName $sourceRecordSet.RecordName
        }

        Select-AzureSubscription `
            -SubscriptionId $DestinationSubscriptionId `
            -EnvironmentName $AzureChinaEnvironmentName `
            -TenantId $DestinationTenantId
    }
}

foreach ($skippedZone in @($skippedZones | Sort-Object -Unique)) {
    Write-Warning "Skipped source zone '$skippedZone' because no matching destination private DNS zone was found."
}

if ($results.Count -eq 0) {
    throw 'No records were synced. Check that matching destination private DNS zones exist.'
}

$results | Sort-Object ZoneName, RecordName