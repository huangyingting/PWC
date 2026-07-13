<#
.SYNOPSIS
Syncs Azure Private Link private DNS A records from one subscription to another.

.DESCRIPTION
Scans a source subscription for private DNS zones, reads the A records from
Private Link zones, and writes those records to matching private DNS zones in a
destination subscription. When running in Azure Automation, SourceSubscriptionId,
DestinationSubscriptionId, and ManagedIdentityAccountId can be read from
Automation variables created by Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1.
DestinationSubscriptionId defaults to 65a9c0da-4f85-47ba-ac0f-7401cbe43205,
the same subscription used by Repair-AksPrivateDnsLinks.ps1's default target
virtual network.

The script is scoped to Azure China. Private DNS zone names are discovered from
the source subscription and matched by exact zone name in the destination
subscription. Only supported Azure China private DNS zones from the built-in
allow-list are scanned; custom private DNS zones are ignored even if their names
start with "privatelink.".

By default, the script scans supported Azure China private DNS zones and links
matching source private endpoints to destination private DNS zones by updating
privateDnsZoneGroups. Azure then manages the destination A records. If no source
private endpoint can be matched, the script falls back to writing the destination
A record directly. Use -ReplaceExisting when manually synced destination record
sets should exactly match the source.

By default, the script also finds the source private endpoints that correspond
to the synced A records and adds the destination private DNS zones to those
private endpoints' privateDnsZoneGroups. This is an Azure resource update on the
source private endpoints. If source and destination tenants are explicitly set
and differ, the script automatically uses direct DNS record sync because private
endpoint DNS zone group linking requires a single tenant.

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

By default, the script removes stale destination A record values previously
synced directly by this script when the corresponding source record no longer
exists, or when the source zone no longer exists. Cleanup only acts on records
with this script's provenance TXT marker and matching source subscription, zone,
and record metadata. If a destination A record has extra unmanaged IP addresses,
only the previously synced IP addresses recorded in provenance are removed. By
default, all supported zones are in scope.

Required permissions:
- Source subscription: Reader on private DNS zones.
- Destination subscription: Private DNS Zone Contributor on private DNS zones.
- Optional -RemoveSourceAfterCopy: Private DNS Zone Contributor on source zones.
- Default private endpoint linking: Network Contributor on source private
    endpoints, plus read access to destination private DNS zones.
- Azure Automation: enable the Automation Account managed identity, assign the
    required RBAC permissions to that identity, and run this script with
    -UseManagedIdentity. For a user-assigned managed identity, also pass
    -ManagedIdentityAccountId with the identity client ID.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -WhatIf

Preview all changes for supported source Azure China private DNS zones.
By default, the script links matching source private endpoints to destination
private DNS zones and falls back to direct DNS A record sync when no source
private endpoint can be matched.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -ReplaceExisting

Sync all supported source Azure China private DNS A records and replace matching
destination record sets.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -WhatIf

Preview DNS record sync and source private endpoint DNS zone group links to the
matching destination private DNS zones.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -DestinationPrivateDnsZoneResourceGroupName "rg-central-private-dns" `
        -DestinationResourceGroupLocation "chinaeast2" `
        -WhatIf

Preview sync and create any missing destination private DNS zones in a specific
destination resource group instead of using the source zone resource group name.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -SkipProvenanceTxtRecord `
        -WhatIf

Preview DNS record sync without creating or updating provenance TXT records.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -UseManagedIdentity

Run inside Azure Automation using the Automation Account system-assigned
managed identity.

.EXAMPLE
    .\Sync-PrivateEndpointPrivateDns.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -UseManagedIdentity `
        -ManagedIdentityAccountId "33333333-3333-3333-3333-333333333333"

Run using a user-assigned managed identity. The ManagedIdentityAccountId value
is typically the user-assigned managed identity client ID.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [Alias('AppSubscriptionId')]
    [string]$SourceSubscriptionId,

    [Parameter()]
    [Alias('CentralSubscriptionId')]
    [string]$DestinationSubscriptionId = '65a9c0da-4f85-47ba-ac0f-7401cbe43205',

    [string]$SourceTenantId,

    [string]$DestinationTenantId,

    [switch]$UseManagedIdentity,

    [Alias('UserAssignedManagedIdentityClientId')]
    [string]$ManagedIdentityAccountId,

    [string]$DestinationPrivateDnsZoneResourceGroupName,

    [string]$DestinationResourceGroupLocation,

    [switch]$IncludeAllPrivateDnsZones,

    [switch]$SkipCreateMissingDestinationZones,

    [switch]$SkipProvenanceTxtRecord,

    [switch]$IncludeApex,

    [switch]$ReplaceExisting,

    [switch]$RemoveSourceAfterCopy,

    [ValidateNotNullOrEmpty()]
    [string]$PrivateDnsZoneGroupName = 'default',

    [ValidateRange(1, 2147483647)]
    [int]$Ttl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PrivateDnsApiVersion = '2018-09-01'
$NetworkApiVersion = '2023-09-01'
$ProvenanceTxtRecordMarker = 'sync-private-endpoint-private-dns:v1'
$ProvenanceTxtManagedBy = 'Sync-PrivateEndpointPrivateDns.ps1'
$DefaultSourceSubscriptionIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsSourceSubscriptionId'
$DefaultDestinationSubscriptionIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsDestinationSubscriptionId'
$DefaultManagedIdentityAccountIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsManagedIdentityAccountId'
$DefaultDestinationSubscriptionId = '65a9c0da-4f85-47ba-ac0f-7401cbe43205'
$UseTtlOverride = $PSBoundParameters.ContainsKey('Ttl')
$ScriptCommand = $PSCmdlet
$script:ConnectedWithManagedIdentity = $false
$RunStartedAt = Get-Date

function Write-TraceLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
    $line = "[$timestamp][$Level] $Message"

    switch ($Level) {
        'WARN' { Write-Warning $line }
        'ERROR' { Write-Error -Message $line -ErrorAction Continue }
        default { Write-Verbose -Message $line -Verbose }
    }
}

function Format-TraceDuration {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$StartTime
    )

    $elapsed = (Get-Date) - $StartTime
    return ('{0:hh\:mm\:ss\.fff}' -f $elapsed)
}

function Write-TraceError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-TraceLog -Level ERROR -Message "Unhandled error: $($ErrorRecord.Exception.Message)"

    if ($ErrorRecord.InvocationInfo) {
        $location = $ErrorRecord.InvocationInfo.PositionMessage
        if (-not [string]::IsNullOrWhiteSpace($location)) {
            Write-TraceLog -Level ERROR -Message "Error location: $location"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
        Write-TraceLog -Level ERROR -Message "Script stack trace: $($ErrorRecord.ScriptStackTrace)"
    }

    $exception = $ErrorRecord.Exception
    while ($exception) {
        Write-TraceLog -Level ERROR -Message "Exception type: $($exception.GetType().FullName)"
        $exception = $exception.InnerException
    }
}

trap {
    Write-TraceError -ErrorRecord $_
    break
}

function Get-AutomationVariableString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command -Name Get-AutomationVariable -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $value = Get-AutomationVariable -Name $Name -ErrorAction Stop
    }
    catch {
        return $null
    }

    if ($null -eq $value) {
        return $null
    }

    return [string]$value
}

$IsAzureAutomationRunbook = $false
if ($env:AZUREPS_HOST_ENVIRONMENT -match 'AzureAutomation') {
    $IsAzureAutomationRunbook = $true
}

$psPrivateMetadataVariable = Get-Variable -Name PSPrivateMetadata -Scope Global -ErrorAction SilentlyContinue
if ($psPrivateMetadataVariable -and $psPrivateMetadataVariable.Value) {
    $jobIdProperty = $psPrivateMetadataVariable.Value.PSObject.Properties['JobId']
    if ($jobIdProperty -and $jobIdProperty.Value) {
        $IsAzureAutomationRunbook = $true
    }
}

if ($IsAzureAutomationRunbook -and [string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
    $SourceSubscriptionId = Get-AutomationVariableString -Name $DefaultSourceSubscriptionIdAutomationVariableName
}

if ($IsAzureAutomationRunbook -and -not $PSBoundParameters.ContainsKey('DestinationSubscriptionId')) {
    $automationDestinationSubscriptionId = Get-AutomationVariableString -Name $DefaultDestinationSubscriptionIdAutomationVariableName
    if (-not [string]::IsNullOrWhiteSpace($automationDestinationSubscriptionId)) {
        $DestinationSubscriptionId = $automationDestinationSubscriptionId
    }
}

if ($IsAzureAutomationRunbook -and [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId)) {
    $ManagedIdentityAccountId = Get-AutomationVariableString -Name $DefaultManagedIdentityAccountIdAutomationVariableName
}

if ([string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
    throw "SourceSubscriptionId is required. In Azure Automation, pass SourceSubscriptionId or set the '$DefaultSourceSubscriptionIdAutomationVariableName' Automation variable."
}

if ([string]::IsNullOrWhiteSpace($DestinationSubscriptionId)) {
    $DestinationSubscriptionId = $DefaultDestinationSubscriptionId
}

$UseManagedIdentityLogin = [bool]($UseManagedIdentity -or -not [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId) -or $IsAzureAutomationRunbook)
if ($UseManagedIdentityLogin -and $IsAzureAutomationRunbook -and -not $UseManagedIdentity -and [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId)) {
    Write-TraceLog -Message 'Azure Automation runbook environment detected. Using the Automation Account system-assigned managed identity for Azure login.'
}

$UseDestinationResourceGroupLocationOverride = $PSBoundParameters.ContainsKey('DestinationResourceGroupLocation')
$DefaultDestinationResourceGroupLocation = 'chinaeast2'
if ([string]::IsNullOrWhiteSpace($DestinationResourceGroupLocation)) {
    $DestinationResourceGroupLocation = $DefaultDestinationResourceGroupLocation
}

$CanUpdatePrivateEndpointZoneGroups = -not ($SourceTenantId -and $DestinationTenantId -and $SourceTenantId -ne $DestinationTenantId)
if (-not $CanUpdatePrivateEndpointZoneGroups) {
    Write-TraceLog -Level WARN -Message 'SourceTenantId and DestinationTenantId differ. Private endpoint DNS zone group linking requires a single tenant, so this run will use direct DNS record sync only.'
}

if ($IncludeAllPrivateDnsZones) {
    Write-TraceLog -Level WARN -Message '-IncludeAllPrivateDnsZones is kept for backward compatibility but is ignored. This script only syncs supported Azure China private DNS zones.'
}

Write-TraceLog -Message "Starting Sync-PrivateEndpointPrivateDns.ps1. SourceSubscriptionId='$SourceSubscriptionId'; DestinationSubscriptionId='$DestinationSubscriptionId'; WhatIf='$WhatIfPreference'; UseManagedIdentity='$UseManagedIdentityLogin'."
Write-TraceLog -Message "Mode: combined private endpoint zone-group linking with direct DNS A record fallback. CanUpdatePrivateEndpointZoneGroups='$CanUpdatePrivateEndpointZoneGroups'."

$AzureChinaPaaSPrivateDnsZonePatterns = @(
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

function Import-AzAccountsModule {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw 'Az.Accounts is required. Install it with: Install-Module Az.Accounts -Scope CurrentUser'
    }

    Import-Module Az.Accounts -ErrorAction Stop
}

function Select-AzureChinaSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [string]$TenantId,

        [bool]$UseManagedIdentity,

        [string]$ManagedIdentityAccountId
    )

    Import-AzAccountsModule

    $connectParameters = @{
        Environment = 'AzureChinaCloud'
        ErrorAction = 'Stop'
    }
    $contextParameters = @{
        SubscriptionId = $SubscriptionId
        ErrorAction    = 'Stop'
        WhatIf         = $false
    }

    if ($UseManagedIdentity) {
        $connectParameters['Identity'] = $true
        if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId)) {
            $connectParameters['AccountId'] = $ManagedIdentityAccountId
        }
    }

    if ($TenantId) {
        $connectParameters['Tenant'] = $TenantId
        $contextParameters['Tenant'] = $TenantId
    }

    if ($UseManagedIdentity) {
        if (-not $script:ConnectedWithManagedIdentity) {
            Connect-AzAccount @connectParameters | Out-Null
            $script:ConnectedWithManagedIdentity = $true
        }
    }
    else {
        $currentContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $currentContext -or $currentContext.Environment.Name -ne 'AzureChinaCloud') {
            Connect-AzAccount @connectParameters | Out-Null
        }
    }

    try {
        Set-AzContext @contextParameters | Out-Null
    }
    catch {
        Connect-AzAccount @connectParameters | Out-Null
        if ($UseManagedIdentity) {
            $script:ConnectedWithManagedIdentity = $true
        }

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
        [string]$Name
    )

    $normalizedName = $Name.Trim().ToLowerInvariant()

    foreach ($pattern in $AzureChinaPaaSPrivateDnsZonePatterns) {
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
        [object[]]$Zones
    )

    $selectedZones = New-Object System.Collections.Generic.List[object]
    foreach ($currentZone in @($Zones)) {
        $currentZoneName = ([string]$currentZone.Name).Trim()

        if (-not (Test-AzurePaaSPrivateDnsZoneName -Name $currentZoneName)) {
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
    $destinationZoneLookup = New-ZoneLookup -Zones @($DestinationZones)
    $sourceZoneGroups = @($SourceZones | Group-Object { ([string]$_.Name).ToLowerInvariant() })

    foreach ($sourceZoneGroup in $sourceZoneGroups) {
        $sourceZone = $sourceZoneGroup.Group[0]
        $zoneName = [string]$sourceZone.Name
        $zoneKey = $zoneName.ToLowerInvariant()
        $matchingDestinationZones = @()

        if ($destinationZoneLookup.ContainsKey($zoneKey)) {
            $matchingDestinationZones = @($destinationZoneLookup[$zoneKey].ToArray())
        }

        if ($ResourceGroupNameOverride -and $matchingDestinationZones.Count -gt 0) {
            $matchingDestinationZones = @($matchingDestinationZones | Where-Object { $_.ResourceGroupName -ieq $ResourceGroupNameOverride })
        }

        if ($matchingDestinationZones.Count -gt 0) {
            $selectedDestinationZone = @($matchingDestinationZones | Sort-Object ResourceGroupName, Id)[0]
            $results.Add($selectedDestinationZone)
            continue
        }

        if ($SkipCreate) {
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
    }

    return $results
}

function Get-PrivateDnsARecordRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
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
        [AllowEmptyCollection()]
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

function Get-PrivateDnsRecordSets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [ValidateSet('A', 'TXT')]
        [string]$RecordType = 'A'
    )

    $path = New-PrivateDnsRecordSetPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordType $RecordType

    return Get-ArmPagedValues -Path $path
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
        "managedBy=$ProvenanceTxtManagedBy"
    )

    return ConvertTo-DnsTxtStrings -Values $values
}

function Get-TxtRecordValues {
    param(
        [object]$TxtRecord
    )

    return @((Get-ObjectPropertyValue -InputObject $TxtRecord -Name 'value') | ForEach-Object { [string]$_ })
}

function ConvertFrom-ProvenanceTxtValues {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Values
    )

    $metadata = @{}
    foreach ($value in @($Values)) {
        if ($value -eq $ProvenanceTxtRecordMarker) {
            continue
        }

        $separatorIndex = $value.IndexOf('=')
        if ($separatorIndex -gt 0) {
            $metadata[$value.Substring(0, $separatorIndex)] = $value.Substring($separatorIndex + 1)
        }
    }

    $sourceIPv4Addresses = @()
    if ($metadata.ContainsKey('sourceIPv4Addresses')) {
        $sourceIPv4Addresses = @(([string]$metadata['sourceIPv4Addresses'] -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }))
    }

    return [pscustomobject]@{
        SourceSubscriptionId = [string]$metadata['sourceSubscriptionId']
        SourceZone           = [string]$metadata['sourceZone']
        SourceRecord         = [string]$metadata['sourceRecord']
        SourceIPv4Addresses  = @($sourceIPv4Addresses)
        ManagedBy            = [string]$metadata['managedBy']
    }
}

function Test-ProvenanceMatchesScope {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Provenance,

        [Parameter(Mandatory = $true)]
        [string]$SourceSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName
    )

    $isManagedByThisScript = [string]::IsNullOrWhiteSpace([string]$Provenance.ManagedBy) -or $Provenance.ManagedBy -eq $ProvenanceTxtManagedBy

    return $isManagedByThisScript `
        -and $Provenance.SourceSubscriptionId -ieq $SourceSubscriptionId `
        -and $Provenance.SourceZone -ieq $ZoneName `
        -and $Provenance.SourceRecord -ieq $RecordName
}

function Get-MatchingManagedProvenanceTxtValues {
    param(
        [object]$TxtRecordSet,

        [Parameter(Mandatory = $true)]
        [string]$SourceSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName
    )

    if ($null -eq $TxtRecordSet) {
        return @()
    }

    $properties = Get-ObjectPropertyValue -InputObject $TxtRecordSet -Name 'properties'
    foreach ($txtRecord in @(Get-ObjectPropertyValue -InputObject $properties -Name 'txtRecords')) {
        if ($null -eq $txtRecord) {
            continue
        }

        $values = @(Get-TxtRecordValues -TxtRecord $txtRecord)
        if ($values.Count -eq 0 -or $values[0] -ne $ProvenanceTxtRecordMarker) {
            continue
        }

        $provenance = ConvertFrom-ProvenanceTxtValues -Values $values
        if (Test-ProvenanceMatchesScope `
            -Provenance $provenance `
            -SourceSubscriptionId $SourceSubscriptionId `
            -ZoneName $ZoneName `
            -RecordName $RecordName) {
            return @($values)
        }
    }

    return @()
}

function New-PrivateDnsRecordKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName
    )

    return "$($ZoneName.Trim().ToLowerInvariant())|$($RecordName.Trim().ToLowerInvariant())"
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
        $privateEndpointDnsDetails = Get-PrivateEndpointDnsDetails -PrivateEndpoint $privateEndpoint
        if (@($privateEndpointDnsDetails.PrivateIpAddresses).Count -eq 0) {
            Write-Warning "Skipped source private endpoint '$($privateEndpointDnsDetails.Name)' because it has no private IP address. Private endpoint ID: $($privateEndpointDnsDetails.Id)"
            continue
        }

        $results.Add($privateEndpointDnsDetails)
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
    $replacedSameZoneConfig = $false
    $sameZoneConfigName = $null
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
                        $replacedSameZoneConfig = $true
                        $sameZoneConfigName = $existingConfigName
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

    if ($replacedSameZoneConfig -and -not [string]::IsNullOrWhiteSpace($sameZoneConfigName)) {
        $newConfigName = $sameZoneConfigName
    }
    elseif ($destinationConfigFound) {
        $newConfigName = $destinationConfigName
    }
    else {
        $newConfigName = New-PrivateDnsZoneConfigName `
            -CurrentZoneName $CurrentZoneName `
            -PrivateDnsZoneId $DestinationPrivateDnsZoneId `
            -ExistingConfigNames @($existingConfigNames.ToArray())
    }

    $target = "$($PrivateEndpoint.Id)/privateDnsZoneGroups/$ZoneGroupName -> $DestinationPrivateDnsZoneId"

    if ($replacedSameZoneConfig) {
        $configsAfterRemove = New-Object System.Collections.Generic.List[object]
        $destinationConfigAlreadyKept = $false

        foreach ($existingConfig in @($existingConfigs.ToArray())) {
            $existingConfigName = [string]$existingConfig['name']
            $existingConfigProperties = $existingConfig['properties']
            $existingPrivateDnsZoneId = [string]$existingConfigProperties['privateDnsZoneId']

            if ($existingPrivateDnsZoneId.ToLowerInvariant() -eq $destinationPrivateDnsZoneIdKey -and $existingConfigName -ne $newConfigName) {
                continue
            }

            if ($existingPrivateDnsZoneId.ToLowerInvariant() -eq $destinationPrivateDnsZoneIdKey -and $existingConfigName -eq $newConfigName) {
                $destinationConfigAlreadyKept = $true
            }

            $configsAfterRemove.Add($existingConfig)
        }

        $removeBody = @{
            properties = @{
                privateDnsZoneConfigs = @($configsAfterRemove.ToArray())
            }
        }

        if ($ScriptCommand.ShouldProcess($target, 'Remove source private DNS zone config from private endpoint zone group')) {
            Invoke-ArmJson -Method PUT -Path $path -Body $removeBody -ExpectedStatusCode @(200, 201) | Out-Null
        }

        if (-not $destinationConfigAlreadyKept) {
            $configsAfterRemove.Add(@{
                name       = $newConfigName
                properties = @{
                    privateDnsZoneId = $DestinationPrivateDnsZoneId
                }
            })
        }

        $body = @{
            properties = @{
                privateDnsZoneConfigs = @($configsAfterRemove.ToArray())
            }
        }
        $operation = if ($destinationConfigFound) { 'ZoneGroupTwoPutRemoveDuplicateConfig' } else { 'ZoneGroupTwoPutMoveToDestinationConfig' }

        if ($ScriptCommand.ShouldProcess($target, 'Add destination private DNS zone config to private endpoint zone group')) {
            Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201) | Out-Null
        }
    }
    else {
        if (-not $destinationConfigFound) {
            $existingConfigs.Add(@{
                name       = $newConfigName
                properties = @{
                    privateDnsZoneId = $DestinationPrivateDnsZoneId
                }
            })
        }

        $operation = if ($existingGroup) { 'ZoneGroupAddConfig' } else { 'ZoneGroupCreate' }
        $body = @{
            properties = @{
                privateDnsZoneConfigs = @($existingConfigs.ToArray())
            }
        }

        if ($ScriptCommand.ShouldProcess($target, 'Link source private endpoint to destination private DNS zone')) {
            Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201) | Out-Null
        }
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
    $desiredProvenance = ConvertFrom-ProvenanceTxtValues -Values $TxtValues

    if ($existingRecordSet) {
        $existingProperties = Get-ObjectPropertyValue -InputObject $existingRecordSet -Name 'properties'
        $existingTtl = [int](Get-ObjectPropertyValue -InputObject $existingProperties -Name 'ttl')

        foreach ($existingTxtRecord in @(Get-ObjectPropertyValue -InputObject $existingProperties -Name 'txtRecords')) {
            if ($null -eq $existingTxtRecord) {
                continue
            }

            $existingValues = @(Get-TxtRecordValues -TxtRecord $existingTxtRecord)
            if ($existingValues.Count -gt 0 -and $existingValues[0] -eq $ProvenanceTxtRecordMarker) {
                $existingProvenance = ConvertFrom-ProvenanceTxtValues -Values $existingValues
                if (Test-ProvenanceMatchesScope `
                    -Provenance $existingProvenance `
                    -SourceSubscriptionId $desiredProvenance.SourceSubscriptionId `
                    -ZoneName $desiredProvenance.SourceZone `
                    -RecordName $desiredProvenance.SourceRecord) {
                    $existingManagedTxtValues = $existingValues
                    continue
                }

                $preservedTxtRecords.Add(@{ value = @($existingValues) })
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

function Remove-ManagedProvenanceTxtRecordSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$CurrentZoneName,

        [Parameter(Mandatory = $true)]
        [string]$RecordName,

        [string]$ExpectedSourceSubscriptionId,

        [string]$ExpectedSourceZone,

        [string]$ExpectedSourceRecord
    )

    $existingRecordSet = Get-PrivateDnsTxtRecordSet `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordName $RecordName

    if ($null -eq $existingRecordSet) {
        return [pscustomobject]@{
            Operation = 'TxtMissing'
            Changed   = $false
        }
    }

    $existingProperties = Get-ObjectPropertyValue -InputObject $existingRecordSet -Name 'properties'
    $existingTtl = [int](Get-ObjectPropertyValue -InputObject $existingProperties -Name 'ttl')
    $preservedTxtRecords = New-Object System.Collections.Generic.List[object]
    $managedTxtFound = $false

    foreach ($existingTxtRecord in @(Get-ObjectPropertyValue -InputObject $existingProperties -Name 'txtRecords')) {
        if ($null -eq $existingTxtRecord) {
            continue
        }

        $existingValues = @(Get-TxtRecordValues -TxtRecord $existingTxtRecord)
        if ($existingValues.Count -gt 0 -and $existingValues[0] -eq $ProvenanceTxtRecordMarker) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceSubscriptionId) -or -not [string]::IsNullOrWhiteSpace($ExpectedSourceZone) -or -not [string]::IsNullOrWhiteSpace($ExpectedSourceRecord)) {
                $provenance = ConvertFrom-ProvenanceTxtValues -Values $existingValues
                if (-not (Test-ProvenanceMatchesScope `
                    -Provenance $provenance `
                    -SourceSubscriptionId $ExpectedSourceSubscriptionId `
                    -ZoneName $ExpectedSourceZone `
                    -RecordName $ExpectedSourceRecord)) {
                    $preservedTxtRecords.Add(@{ value = @($existingValues) })
                    continue
                }
            }

            $managedTxtFound = $true
            continue
        }

        $preservedTxtRecords.Add(@{ value = @($existingValues) })
    }

    if (-not $managedTxtFound) {
        return [pscustomobject]@{
            Operation = 'TxtNoManagedProvenance'
            Changed   = $false
        }
    }

    $path = New-PrivateDnsRecordSetPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordType 'TXT' `
        -RecordName $RecordName
    $target = "$SubscriptionId/$ResourceGroupName/$CurrentZoneName/TXT/$RecordName"

    if ($preservedTxtRecords.Count -eq 0) {
        if ($ScriptCommand.ShouldProcess($target, 'Delete managed provenance TXT record set')) {
            Invoke-ArmJson -Method DELETE -Path $path -ExpectedStatusCode @(200, 202, 204) | Out-Null
        }

        return [pscustomobject]@{
            Operation = 'TxtDeleteManagedProvenance'
            Changed   = $true
        }
    }

    $body = @{
        properties = @{
            ttl        = $existingTtl
            txtRecords = @($preservedTxtRecords.ToArray())
        }
    }

    if ($ScriptCommand.ShouldProcess($target, 'Remove managed provenance TXT value from record set')) {
        Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201) | Out-Null
    }

    return [pscustomobject]@{
        Operation = 'TxtRemoveManagedProvenance'
        Changed   = $true
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

        [switch]$Replace,

        [string[]]$PreviouslyManagedIPv4Addresses
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
        $previouslyManagedIpLookup = @{}
        foreach ($previouslyManagedIpAddress in @($PreviouslyManagedIPv4Addresses)) {
            if ([string]::IsNullOrWhiteSpace($previouslyManagedIpAddress)) {
                continue
            }

            $previouslyManagedIpLookup[$previouslyManagedIpAddress.Trim()] = $true
        }

        if ($previouslyManagedIpLookup.Count -gt 0) {
            $unmanagedExistingIpAddresses = @($existingIpAddresses | Where-Object { -not $previouslyManagedIpLookup.ContainsKey($_) })
            $desiredIpAddresses = @($unmanagedExistingIpAddresses + $IPv4Addresses | Sort-Object -Unique)
            $operation = 'SyncManaged'
        }
        else {
            $desiredIpAddresses = @($existingIpAddresses + $IPv4Addresses | Sort-Object -Unique)
            $operation = 'Merge'
        }

        $desiredTtl = $existingTtl
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
        [string]$RecordName,

        [string]$ActionDescription = 'Delete private DNS A record set'
    )

    $path = New-PrivateDnsRecordSetPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -CurrentZoneName $CurrentZoneName `
        -RecordName $RecordName
    $target = "$SubscriptionId/$ResourceGroupName/$CurrentZoneName/A/$RecordName"

    if ($ScriptCommand.ShouldProcess($target, $ActionDescription)) {
        Invoke-ArmJson -Method DELETE -Path $path -ExpectedStatusCode @(200, 202, 204) | Out-Null
    }
}

function Remove-MissingDestinationPrivateDnsRecords {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationSubscriptionId,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$DestinationZones,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SourceRows,

        [Parameter(Mandatory = $true)]
        [string]$SourceSubscriptionId,

        [switch]$AllowApex
    )

    $results = New-Object System.Collections.Generic.List[object]
    $sourceRecordLookup = @{}
    foreach ($sourceRow in @($SourceRows)) {
        $sourceKey = New-PrivateDnsRecordKey `
            -ZoneName ([string]$sourceRow.ZoneName) `
            -RecordName ([string]$sourceRow.RecordName)
        $sourceRecordLookup[$sourceKey] = $true
    }

    foreach ($destinationZone in @($DestinationZones)) {
        $zoneName = [string]$destinationZone.Name
        $resourceGroupName = [string]$destinationZone.ResourceGroupName
        $destinationARecordSets = @(Get-PrivateDnsRecordSets `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $resourceGroupName `
            -CurrentZoneName $zoneName `
            -RecordType 'A')

        foreach ($destinationARecordSet in $destinationARecordSets) {
            $recordName = [string]$destinationARecordSet.name
            if ([string]::IsNullOrWhiteSpace($recordName)) {
                continue
            }

            if (-not $AllowApex -and $recordName -eq '@') {
                continue
            }

            $destinationRecordKey = New-PrivateDnsRecordKey -ZoneName $zoneName -RecordName $recordName
            if ($sourceRecordLookup.ContainsKey($destinationRecordKey)) {
                continue
            }

            $txtRecordSet = Get-PrivateDnsTxtRecordSet `
                -SubscriptionId $DestinationSubscriptionId `
                -ResourceGroupName $resourceGroupName `
                -CurrentZoneName $zoneName `
                -RecordName $recordName
            $managedTxtValues = @(Get-MatchingManagedProvenanceTxtValues `
                -TxtRecordSet $txtRecordSet `
                -SourceSubscriptionId $SourceSubscriptionId `
                -ZoneName $zoneName `
                -RecordName $recordName)
            if ($managedTxtValues.Count -eq 0) {
                continue
            }

            $provenance = ConvertFrom-ProvenanceTxtValues -Values $managedTxtValues
            if (-not (Test-ProvenanceMatchesScope `
                -Provenance $provenance `
                -SourceSubscriptionId $SourceSubscriptionId `
                -ZoneName $zoneName `
                -RecordName $recordName)) {
                continue
            }

            $managedIpLookup = @{}
            foreach ($managedIpAddress in @($provenance.SourceIPv4Addresses)) {
                if ([string]::IsNullOrWhiteSpace($managedIpAddress)) {
                    continue
                }

                $managedIpLookup[$managedIpAddress.Trim()] = $true
            }

            if ($managedIpLookup.Count -eq 0) {
                Write-Warning "Skipped stale destination record '$recordName.$zoneName' because its provenance TXT record does not contain source IPv4 addresses."
                continue
            }

            $recordProperties = Get-ObjectPropertyValue -InputObject $destinationARecordSet -Name 'properties'
            $recordTtl = [int](Get-ObjectPropertyValue -InputObject $recordProperties -Name 'ttl')
            $currentIpAddresses = @((Get-ObjectPropertyValue -InputObject $recordProperties -Name 'aRecords') | ForEach-Object { [string]$_.ipv4Address } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            $remainingIpAddresses = @($currentIpAddresses | Where-Object { -not $managedIpLookup.ContainsKey($_) } | Sort-Object -Unique)
            $removedIpAddresses = @($currentIpAddresses | Where-Object { $managedIpLookup.ContainsKey($_) } | Sort-Object -Unique)

            if ($removedIpAddresses.Count -eq 0) {
                Write-Warning "Skipped stale destination record '$recordName.$zoneName' because none of the provenance-managed IP addresses are present in the destination A record set."
                continue
            }

            if ($remainingIpAddresses.Count -eq 0) {
                Write-TraceLog -Message "Deleting stale destination A record '$recordName.$zoneName' in resource group '$resourceGroupName'. Removed IP(s)='$($removedIpAddresses -join ',')'."
                Remove-PrivateDnsARecordSet `
                    -SubscriptionId $DestinationSubscriptionId `
                    -ResourceGroupName $resourceGroupName `
                    -CurrentZoneName $zoneName `
                    -RecordName $recordName `
                    -ActionDescription 'Delete stale destination private DNS A record set'
                $operation = 'DeleteMissingDestinationRecord'
                $resultIpAddresses = ''
            }
            else {
                Write-TraceLog -Message "Pruning stale destination A record '$recordName.$zoneName' in resource group '$resourceGroupName'. Removed IP(s)='$($removedIpAddresses -join ',')'; remaining IP(s)='$($remainingIpAddresses -join ',')'."
                Set-PrivateDnsARecordSet `
                    -SubscriptionId $DestinationSubscriptionId `
                    -ResourceGroupName $resourceGroupName `
                    -CurrentZoneName $zoneName `
                    -RecordName $recordName `
                    -IPv4Addresses $remainingIpAddresses `
                    -RecordTtl $recordTtl `
                    -Replace | Out-Null
                $operation = 'PruneMissingDestinationRecord'
                $resultIpAddresses = ($remainingIpAddresses -join ',')
            }

            $txtCleanupResult = Remove-ManagedProvenanceTxtRecordSet `
                -SubscriptionId $DestinationSubscriptionId `
                -ResourceGroupName $resourceGroupName `
                -CurrentZoneName $zoneName `
                -RecordName $recordName `
                -ExpectedSourceSubscriptionId $SourceSubscriptionId `
                -ExpectedSourceZone $zoneName `
                -ExpectedSourceRecord $recordName

            $results.Add([pscustomobject]@{
                ZoneName                         = $zoneName
                RecordName                       = $recordName
                DestinationZoneResourceGroupName = $resourceGroupName
                Operation                        = $operation
                IPv4Addresses                    = $resultIpAddresses
                RemovedIPv4Addresses             = ($removedIpAddresses -join ',')
                TTL                              = $recordTtl
                Changed                          = $true
                SourcePrivateEndpointNames       = ''
                SourcePrivateEndpointIds         = ''
                SourcePrivateEndpointMatchTypes  = ''
                PrivateDnsZoneGroupOperations    = ''
                PrivateDnsZoneGroupChanged       = $false
                ProvenanceTxtRecordOperation     = $txtCleanupResult.Operation
                ProvenanceTxtRecordChanged       = $txtCleanupResult.Changed
                ProvenanceTxtRecordValues        = ($managedTxtValues -join ';')
            })
        }
    }

    return $results
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

Write-TraceLog -Message "Selecting source subscription '$SourceSubscriptionId'."
Select-AzureChinaSubscription `
    -SubscriptionId $SourceSubscriptionId `
    -TenantId $SourceTenantId `
    -UseManagedIdentity $UseManagedIdentityLogin `
    -ManagedIdentityAccountId $ManagedIdentityAccountId
Write-TraceLog -Message 'Reading source private DNS zones.'
$sourceZones = @(Get-PrivateDnsZonesInSubscription -SubscriptionId $SourceSubscriptionId)
$sourceZonesToSync = @(Select-ZonesForSync -Zones $sourceZones)
Write-TraceLog -Message "Source zones discovered='$($sourceZones.Count)'; selected for sync='$($sourceZonesToSync.Count)'."

if ($sourceZonesToSync.Count -eq 0) {
    Write-TraceLog -Level WARN -Message 'No supported source Azure China private DNS zones matched the scan criteria. Continuing destination cleanup based on destination zones and provenance TXT metadata.'
}

Write-TraceLog -Message 'Reading source private DNS A records.'
$sourceRows = @(Get-PrivateDnsARecordRows `
    -SubscriptionId $SourceSubscriptionId `
    -Zones $sourceZonesToSync `
    -AllowApex:$IncludeApex)
Write-TraceLog -Message "Source A record rows discovered='$($sourceRows.Count)'."

if ($sourceRows.Count -eq 0) {
    if ($sourceZonesToSync.Count -gt 0) {
        $zoneNames = @($sourceZonesToSync | ForEach-Object { [string]$_.Name } | Sort-Object -Unique) -join ', '
        Write-TraceLog -Level WARN -Message "No source Azure China private DNS A records were found in supported source zones: $zoneNames. This can be expected after source private endpoints are already associated to destination private DNS zones. Nothing to sync."
    }

}

$validatedRows = @(ConvertTo-ValidatedRecordRows `
    -Rows $sourceRows `
    -UseOverrideTtl $UseTtlOverride `
    -OverrideTtl $Ttl)
Write-TraceLog -Message "Validated source A record rows='$($validatedRows.Count)'."

$sourcePrivateEndpoints = @()
if ($CanUpdatePrivateEndpointZoneGroups -and $validatedRows.Count -gt 0) {
    Write-TraceLog -Message 'Reading source private endpoints to match DNS records.'
    $sourcePrivateEndpoints = @(Get-PrivateEndpointDnsDetailsInSubscription -SubscriptionId $SourceSubscriptionId)
    Write-TraceLog -Message "Source private endpoints with DNS details='$($sourcePrivateEndpoints.Count)'."
    if ($sourcePrivateEndpoints.Count -eq 0) {
        Write-TraceLog -Level WARN -Message 'No source private endpoints were found. DNS records can still be synced, but no private endpoint DNS zone group links can be added.'
    }
}

Write-TraceLog -Message "Selecting destination subscription '$DestinationSubscriptionId'."
Select-AzureChinaSubscription `
    -SubscriptionId $DestinationSubscriptionId `
    -TenantId $DestinationTenantId `
    -UseManagedIdentity $UseManagedIdentityLogin `
    -ManagedIdentityAccountId $ManagedIdentityAccountId
Write-TraceLog -Message 'Reading destination private DNS zones.'
$destinationZones = @(Get-PrivateDnsZonesInSubscription -SubscriptionId $DestinationSubscriptionId)
$destinationZonesInScope = @(Select-ZonesForSync -Zones $destinationZones)
Write-TraceLog -Message "Destination zones discovered='$($destinationZones.Count)'; selected in scope='$($destinationZonesInScope.Count)'."
$destinationZonesForCleanup = $destinationZonesInScope
if (-not [string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) {
    $destinationZonesForCleanup = @($destinationZonesForCleanup | Where-Object { $_.ResourceGroupName -ieq $DestinationPrivateDnsZoneResourceGroupName })
    Write-TraceLog -Message "Destination cleanup zones after resource group filter '$DestinationPrivateDnsZoneResourceGroupName'='$($destinationZonesForCleanup.Count)'."
}

$destinationZonesToSync = @()
if ($sourceZonesToSync.Count -gt 0) {
    Write-TraceLog -Message 'Confirming destination private DNS zones exist.'
    $skipCreateDestinationZones = [bool]($SkipCreateMissingDestinationZones -or $validatedRows.Count -eq 0)
    $destinationZonesToSync = @(Confirm-DestinationPrivateDnsZones `
        -DestinationSubscriptionId $DestinationSubscriptionId `
        -SourceZones $sourceZonesToSync `
        -DestinationZones $destinationZonesInScope `
        -ResourceGroupNameOverride $DestinationPrivateDnsZoneResourceGroupName `
        -ResourceGroupLocation $DestinationResourceGroupLocation `
        -UseResourceGroupLocationOverride $UseDestinationResourceGroupLocationOverride `
        -SkipCreate:$skipCreateDestinationZones)
}
Write-TraceLog -Message "Destination zones available for sync='$($destinationZonesToSync.Count)'; cleanup scope='$($destinationZonesForCleanup.Count)'."
$destinationZoneLookup = New-ZoneLookup -Zones $destinationZonesToSync

$results = New-Object System.Collections.Generic.List[object]
$skippedZones = New-Object System.Collections.Generic.List[string]
$recordGroups = $validatedRows | Group-Object ZoneName, RecordName
Write-TraceLog -Message "Processing DNS record sets='$(@($recordGroups).Count)'."

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
        Write-Warning "Destination subscription has multiple private DNS zones named '$($firstRow.ZoneName)' in resource groups: $resourceGroups. Using the first match by resource group name."
    }

    $destinationZone = @($matchingDestinationZones | Sort-Object ResourceGroupName, Id)[0]
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

    if ($CanUpdatePrivateEndpointZoneGroups) {
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
                Select-AzureChinaSubscription `
                    -SubscriptionId $SourceSubscriptionId `
                    -TenantId $SourceTenantId `
                    -UseManagedIdentity $UseManagedIdentityLogin `
                    -ManagedIdentityAccountId $ManagedIdentityAccountId

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

                Select-AzureChinaSubscription `
                    -SubscriptionId $DestinationSubscriptionId `
                    -TenantId $DestinationTenantId `
                    -UseManagedIdentity $UseManagedIdentityLogin `
                    -ManagedIdentityAccountId $ManagedIdentityAccountId
            }
        }
    }

    $shouldSyncRecordDirectly = (-not $CanUpdatePrivateEndpointZoneGroups) -or $linkableMatches.Count -eq 0
    if ($shouldSyncRecordDirectly) {
        $previouslyManagedIpAddresses = @()
        $existingTxtRecordSet = Get-PrivateDnsTxtRecordSet `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $destinationZone.ResourceGroupName `
            -CurrentZoneName $firstRow.ZoneName `
            -RecordName $firstRow.RecordName
        $existingManagedTxtValues = @(Get-MatchingManagedProvenanceTxtValues `
            -TxtRecordSet $existingTxtRecordSet `
            -SourceSubscriptionId $SourceSubscriptionId `
            -ZoneName $firstRow.ZoneName `
            -RecordName $firstRow.RecordName)
        if ($existingManagedTxtValues.Count -gt 0) {
            $existingProvenance = ConvertFrom-ProvenanceTxtValues -Values $existingManagedTxtValues
            if (Test-ProvenanceMatchesScope `
                -Provenance $existingProvenance `
                -SourceSubscriptionId $SourceSubscriptionId `
                -ZoneName $firstRow.ZoneName `
                -RecordName $firstRow.RecordName) {
                $previouslyManagedIpAddresses = @($existingProvenance.SourceIPv4Addresses)
            }
        }

        $syncResult = Set-PrivateDnsARecordSet `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $destinationZone.ResourceGroupName `
            -CurrentZoneName $firstRow.ZoneName `
            -RecordName $firstRow.RecordName `
            -IPv4Addresses $ipAddresses `
            -RecordTtl $groupTtls[0] `
            -Replace:$ReplaceExisting `
            -PreviouslyManagedIPv4Addresses $previouslyManagedIpAddresses

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
    else {
        $txtCleanupResult = Remove-ManagedProvenanceTxtRecordSet `
            -SubscriptionId $DestinationSubscriptionId `
            -ResourceGroupName $destinationZone.ResourceGroupName `
            -CurrentZoneName $firstRow.ZoneName `
            -RecordName $firstRow.RecordName `
            -ExpectedSourceSubscriptionId $SourceSubscriptionId `
            -ExpectedSourceZone $firstRow.ZoneName `
            -ExpectedSourceRecord $firstRow.RecordName

        if ($txtCleanupResult.Changed) {
            $provenanceTxtRecordOperation = $txtCleanupResult.Operation
            $provenanceTxtRecordChanged = $txtCleanupResult.Changed
        }
        elseif (-not $SkipProvenanceTxtRecord) {
            $provenanceTxtRecordOperation = 'TxtSkippedZoneGroupManaged'
        }
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
        Select-AzureChinaSubscription `
            -SubscriptionId $SourceSubscriptionId `
            -TenantId $SourceTenantId `
            -UseManagedIdentity $UseManagedIdentityLogin `
            -ManagedIdentityAccountId $ManagedIdentityAccountId
        $sourceRecordSets = @($recordGroup.Group | Select-Object ZoneName, SourceZoneResourceGroupName, RecordName -Unique)

        foreach ($sourceRecordSet in $sourceRecordSets) {
            Remove-PrivateDnsARecordSet `
                -SubscriptionId $SourceSubscriptionId `
                -ResourceGroupName $sourceRecordSet.SourceZoneResourceGroupName `
                -CurrentZoneName $sourceRecordSet.ZoneName `
                -RecordName $sourceRecordSet.RecordName `
                -ActionDescription 'Delete source private DNS A record set'
        }

        Select-AzureChinaSubscription `
            -SubscriptionId $DestinationSubscriptionId `
            -TenantId $DestinationTenantId `
            -UseManagedIdentity $UseManagedIdentityLogin `
            -ManagedIdentityAccountId $ManagedIdentityAccountId
    }
}

Write-TraceLog -Message 'Checking for stale destination DNS records managed by this script.'
$cleanupResults = @(Remove-MissingDestinationPrivateDnsRecords `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationZones $destinationZonesForCleanup `
    -SourceRows $validatedRows `
    -SourceSubscriptionId $SourceSubscriptionId `
    -AllowApex:$IncludeApex)
Write-TraceLog -Message "Stale destination cleanup results='$($cleanupResults.Count)'."

foreach ($cleanupResult in $cleanupResults) {
    $results.Add($cleanupResult)
}

foreach ($skippedZone in @($skippedZones | Sort-Object -Unique)) {
    Write-TraceLog -Level WARN -Message "Skipped source zone '$skippedZone' because no matching destination private DNS zone was found."
}

if ($results.Count -eq 0) {
    if ($validatedRows.Count -eq 0) {
        Write-TraceLog -Level WARN -Message 'No records were synced or removed. Check that matching destination private DNS zones exist and that stale destination records have provenance TXT metadata from this script.'
        Write-TraceLog -Message "Completed Sync-PrivateEndpointPrivateDns.ps1 in $(Format-TraceDuration -StartTime $RunStartedAt)."
        return
    }

    throw 'No records were synced or removed. Check that matching destination private DNS zones exist.'
}

Write-TraceLog -Message "Operation summary for '$($results.Count)' result row(s):"
foreach ($operationGroup in @($results | Group-Object Operation | Sort-Object Name)) {
    Write-TraceLog -Message "  $($operationGroup.Name): $($operationGroup.Count)"
}

if ($CanUpdatePrivateEndpointZoneGroups -and $sourcePrivateEndpoints.Count -gt 0) {
    $summaryRows = @($results.ToArray())
    $matchedSourcePrivateEndpointIdLookup = @{}
    foreach ($summaryRow in $summaryRows) {
        $sourcePrivateEndpointIdsValue = Get-ObjectPropertyValue -InputObject $summaryRow -Name 'SourcePrivateEndpointIds'
        foreach ($sourcePrivateEndpointId in @(([string]$sourcePrivateEndpointIdsValue -split ','))) {
            $normalizedSourcePrivateEndpointId = $sourcePrivateEndpointId.Trim()
            if (-not [string]::IsNullOrWhiteSpace($normalizedSourcePrivateEndpointId)) {
                $matchedSourcePrivateEndpointIdLookup[$normalizedSourcePrivateEndpointId.ToLowerInvariant()] = $true
            }
        }
    }

    $matchedSourcePrivateEndpoints = @($sourcePrivateEndpoints | Where-Object { $matchedSourcePrivateEndpointIdLookup.ContainsKey(([string]$_.Id).ToLowerInvariant()) } | Sort-Object Name)
    $unmatchedSourcePrivateEndpoints = @($sourcePrivateEndpoints | Where-Object { -not $matchedSourcePrivateEndpointIdLookup.ContainsKey(([string]$_.Id).ToLowerInvariant()) } | Sort-Object Name)
    Write-TraceLog -Message "Source private endpoints matched to processed DNS records='$($matchedSourcePrivateEndpoints.Count)' out of '$($sourcePrivateEndpoints.Count)' endpoint(s) with DNS details."

    if ($matchedSourcePrivateEndpoints.Count -gt 0) {
        Write-TraceLog -Message "Matched source private endpoints: $(@($matchedSourcePrivateEndpoints | ForEach-Object { $_.Name }) -join ', ')."
    }

    if ($unmatchedSourcePrivateEndpoints.Count -gt 0) {
        Write-TraceLog -Level WARN -Message "Source private endpoints not matched to processed DNS records='$($unmatchedSourcePrivateEndpoints.Count)': $(@($unmatchedSourcePrivateEndpoints | ForEach-Object { $_.Name }) -join ', '). Check that each endpoint has a supported source private DNS zone A record and that a matching destination private DNS zone is available."
    }

    $privateDnsZoneGroupOperationNames = New-Object System.Collections.Generic.List[string]
    foreach ($summaryRow in $summaryRows) {
        $privateDnsZoneGroupOperationsValue = Get-ObjectPropertyValue -InputObject $summaryRow -Name 'PrivateDnsZoneGroupOperations'
        foreach ($operationEntry in @(([string]$privateDnsZoneGroupOperationsValue -split ','))) {
            $normalizedOperationEntry = $operationEntry.Trim()
            if ([string]::IsNullOrWhiteSpace($normalizedOperationEntry)) {
                continue
            }

            $separatorIndex = $normalizedOperationEntry.LastIndexOf(':')
            if ($separatorIndex -ge 0 -and $separatorIndex -lt ($normalizedOperationEntry.Length - 1)) {
                $privateDnsZoneGroupOperationNames.Add($normalizedOperationEntry.Substring($separatorIndex + 1))
            }
        }
    }

    foreach ($privateDnsZoneGroupOperationGroup in @($privateDnsZoneGroupOperationNames | Group-Object | Sort-Object Name)) {
        Write-TraceLog -Message "  PrivateEndpointZoneGroup $($privateDnsZoneGroupOperationGroup.Name): $($privateDnsZoneGroupOperationGroup.Count)"
    }
}

$staleCleanupRows = @($results | Where-Object { $_.Operation -in @('DeleteMissingDestinationRecord', 'PruneMissingDestinationRecord') } | Sort-Object ZoneName, RecordName)
if ($staleCleanupRows.Count -gt 0) {
    Write-TraceLog -Message "Stale destination record cleanup details:"
    foreach ($cleanupRow in $staleCleanupRows) {
        Write-TraceLog -Message "  $($cleanupRow.Operation): $($cleanupRow.RecordName).$($cleanupRow.ZoneName) in resource group '$($cleanupRow.DestinationZoneResourceGroupName)'; removed IP(s)='$($cleanupRow.RemovedIPv4Addresses)'; remaining IP(s)='$($cleanupRow.IPv4Addresses)'."
    }
}

Write-TraceLog -Message "Completed Sync-PrivateEndpointPrivateDns.ps1 in $(Format-TraceDuration -StartTime $RunStartedAt)."

$results | Sort-Object ZoneName, RecordName