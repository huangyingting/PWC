<#
.SYNOPSIS
Links AKS Azure China private DNS zones to a target virtual network.

.DESCRIPTION
Finds private DNS zones in an Azure China subscription whose names end with the
AKS private DNS suffix .cx.prod.service.azk8s.cn.

For every matching private DNS zone, the script checks existing virtual network
links and creates a missing link to the target virtual network. Existing links
to the same virtual network are left unchanged.

.EXAMPLE
    .\Repair-AksPrivateDnsLinks.ps1 -WhatIf

Preview links from matching AKS private DNS zones to the default target virtual
network.

.EXAMPLE
    .\Repair-AksPrivateDnsLinks.ps1 `
        -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
        -TargetVirtualNetworkResourceId "/subscriptions/65a9c0da-4f85-47ba-ac0f-7401cbe43205/resourceGroups/RGP-P0001-CN-AZ-FCS-0005/providers/Microsoft.Network/virtualNetworks/vNet-P0001-CN-AZ-FCS-0005"

Link matching zones in a specific private DNS zone subscription to the FCS VNet.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourceSubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [switch]$UseManagedIdentity,

    [Alias('UserAssignedManagedIdentityClientId')]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedIdentityAccountId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TargetVirtualNetworkResourceId = '/subscriptions/65a9c0da-4f85-47ba-ac0f-7401cbe43205/resourceGroups/RGP-P0001-CN-AZ-FCS-0005/providers/Microsoft.Network/virtualNetworks/vNet-P0001-CN-AZ-FCS-0005',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AksPrivateDnsZoneSuffix = '.cx.prod.service.azk8s.cn',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LinkName
)

#requires -Modules Az.Accounts

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PrivateDnsApiVersion = '2020-06-01'
$DefaultSourceSubscriptionIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsSourceSubscriptionId'
$DefaultManagedIdentityAccountIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsManagedIdentityAccountId'
$DefaultAksTargetVirtualNetworkResourceIdAutomationVariableName = 'RepairAksPrivateDnsLinksTargetVirtualNetworkResourceId'
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
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
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

function Import-AzAccountsModule {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw 'Az.Accounts is required. Install it with: Install-Module Az.Accounts -Scope CurrentUser'
    }

    Import-Module Az.Accounts -ErrorAction Stop
}

function Select-AzureChinaSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [string]$TargetTenantId,

        [bool]$UseManagedIdentityLogin,

        [string]$TargetManagedIdentityAccountId
    )

    Import-AzAccountsModule


    $connectParameters = @{
        Environment = 'AzureChinaCloud'
        ErrorAction  = 'Stop'
    }
    $contextParameters = @{
        SubscriptionId = $TargetSubscriptionId
        ErrorAction    = 'Stop'
        WhatIf         = $false
    }

    if ($UseManagedIdentityLogin) {
        $connectParameters['Identity'] = $true
        if (-not [string]::IsNullOrWhiteSpace($TargetManagedIdentityAccountId)) {
            $connectParameters['AccountId'] = $TargetManagedIdentityAccountId
        }
    }

    if ($TargetTenantId) {
        $connectParameters['Tenant'] = $TargetTenantId
        $contextParameters['Tenant'] = $TargetTenantId
    }

    if ($UseManagedIdentityLogin) {
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
        if ($UseManagedIdentityLogin) {
            $script:ConnectedWithManagedIdentity = $true
        }

        Set-AzContext @contextParameters | Out-Null
    }
}

function ConvertTo-ArmPathSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [System.Uri]::EscapeDataString($Value)
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

function Normalize-ResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    return $ResourceId.Trim().TrimEnd('/').ToLowerInvariant()
}

function Get-SubscriptionIdFromResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    if ($ResourceId -notmatch '^/subscriptions/([^/]+)(/|$)') {
        throw "Could not read subscription ID from resource ID: $ResourceId"
    }

    return [System.Uri]::UnescapeDataString($Matches[1])
}

function Get-ResourceGroupNameFromResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    if ($ResourceId -notmatch '/resourceGroups/([^/]+)(/|$)') {
        throw "Could not read resource group name from resource ID: $ResourceId"
    }

    return [System.Uri]::UnescapeDataString($Matches[1])
}

function Get-VirtualNetworkNameFromResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    if ($ResourceId -notmatch '/providers/Microsoft\.Network/virtualNetworks/([^/]+)$') {
        throw "Could not read virtual network name from resource ID: $ResourceId"
    }

    return [System.Uri]::UnescapeDataString($Matches[1])
}

function Invoke-ArmJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT')]
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
        [string]$TargetSubscriptionId
    )

    $path = "/subscriptions/$TargetSubscriptionId/providers/Microsoft.Network/privateDnsZones?api-version=$PrivateDnsApiVersion"
    $zones = Get-ArmPagedValues -Path $path
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($currentZone in $zones) {
        $zoneId = [string](Get-ObjectPropertyValue -InputObject $currentZone -Name 'id')
        $zoneName = [string](Get-ObjectPropertyValue -InputObject $currentZone -Name 'name')

        $results.Add([pscustomobject]@{
            Name              = $zoneName
            ResourceGroupName = Get-ResourceGroupNameFromResourceId -ResourceId $zoneId
            Id                = $zoneId
        })
    }

    return $results
}

function Test-AksPrivateDnsZoneName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    return $Name.EndsWith($Suffix, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-PrivateDnsVirtualNetworkLinkPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [string]$CurrentLinkName
    )

    $zoneSegment = ConvertTo-ArmPathSegment -Value $ZoneName
    $path = "/subscriptions/$TargetSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/privateDnsZones/$zoneSegment/virtualNetworkLinks"

    if ($CurrentLinkName) {
        $linkSegment = ConvertTo-ArmPathSegment -Value $CurrentLinkName
        $path = "$path/$linkSegment"
    }

    return "${path}?api-version=$PrivateDnsApiVersion"
}

function Get-PrivateDnsVirtualNetworkLinkName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Link
    )

    $linkId = [string](Get-ObjectPropertyValue -InputObject $Link -Name 'id')
    if ($linkId -match '/virtualNetworkLinks/([^/?]+)') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }

    $name = [string](Get-ObjectPropertyValue -InputObject $Link -Name 'name')
    if ($name -match '/') {
        return ($name -split '/')[-1]
    }

    return $name
}

function Get-PrivateDnsVirtualNetworkLinks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName
    )

    $path = New-PrivateDnsVirtualNetworkLinkPath `
        -TargetSubscriptionId $TargetSubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ZoneName $ZoneName

    return Get-ArmPagedValues -Path $path
}

function New-DefaultLinkName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VirtualNetworkResourceId
    )

    $virtualNetworkName = Get-VirtualNetworkNameFromResourceId -ResourceId $VirtualNetworkResourceId
    $generatedName = "$($virtualNetworkName.ToLowerInvariant())-link" -replace '[^a-z0-9-]', '-'
    $generatedName = $generatedName.Trim('-')

    if ([string]::IsNullOrWhiteSpace($generatedName)) {
        throw "Could not generate a virtual network link name from resource ID: $VirtualNetworkResourceId"
    }

    if ($generatedName.Length -gt 80) {
        $generatedName = $generatedName.Substring(0, 80).Trim('-')
    }

    return $generatedName
}

function Ensure-PrivateDnsZoneVirtualNetworkLink {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Zone,

        [Parameter(Mandatory = $true)]
        [string]$ZoneSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$TargetVirtualNetworkId,

        [Parameter(Mandatory = $true)]
        [string]$TargetLinkName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneType
    )

    $zoneName = [string]$Zone.Name
    $resourceGroupName = [string]$Zone.ResourceGroupName
    $normalizedTargetVirtualNetworkId = Normalize-ResourceId -ResourceId $TargetVirtualNetworkId
    $links = @(Get-PrivateDnsVirtualNetworkLinks `
        -TargetSubscriptionId $ZoneSubscriptionId `
        -ResourceGroupName $resourceGroupName `
        -ZoneName $zoneName)

    foreach ($existingLink in $links) {
        $properties = Get-ObjectPropertyValue -InputObject $existingLink -Name 'properties'
        $virtualNetwork = Get-ObjectPropertyValue -InputObject $properties -Name 'virtualNetwork'
        $existingVirtualNetworkId = [string](Get-ObjectPropertyValue -InputObject $virtualNetwork -Name 'id')
        $existingLinkName = Get-PrivateDnsVirtualNetworkLinkName -Link $existingLink

        if (-not [string]::IsNullOrWhiteSpace($existingVirtualNetworkId) -and (Normalize-ResourceId -ResourceId $existingVirtualNetworkId) -eq $normalizedTargetVirtualNetworkId) {
            return [pscustomobject]@{
                ZoneType                       = $ZoneType
                ZoneName                       = $zoneName
                ZoneResourceGroupName          = $resourceGroupName
                LinkName                       = $existingLinkName
                TargetVirtualNetworkResourceId = $TargetVirtualNetworkId
                Action                         = 'AlreadyLinked'
            }
        }

        if ($existingLinkName -ieq $TargetLinkName) {
            throw "Private DNS zone '$zoneName' already has virtual network link '$TargetLinkName' to '$existingVirtualNetworkId'. Choose a different -LinkName or remove the conflicting link."
        }
    }

    $path = New-PrivateDnsVirtualNetworkLinkPath `
        -TargetSubscriptionId $ZoneSubscriptionId `
        -ResourceGroupName $resourceGroupName `
        -ZoneName $zoneName `
        -CurrentLinkName $TargetLinkName
    $body = @{
        location   = 'global'
        properties = @{
            registrationEnabled = $false
            virtualNetwork      = @{ id = $TargetVirtualNetworkId }
        }
    }
    $targetDescription = "$zoneName/$TargetLinkName -> $TargetVirtualNetworkId"

    if ($ScriptCommand.ShouldProcess($targetDescription, 'Create private DNS virtual network link')) {
        Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201, 202) | Out-Null
        $action = 'Created'
    }
    else {
        $action = if ($WhatIfPreference) { 'WouldCreate' } else { 'Skipped' }
    }

    return [pscustomobject]@{
        ZoneType                       = $ZoneType
        ZoneName                       = $zoneName
        ZoneResourceGroupName          = $resourceGroupName
        LinkName                       = $TargetLinkName
        TargetVirtualNetworkResourceId = $TargetVirtualNetworkId
        Action                         = $action
    }
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

if ($IsAzureAutomationRunbook -and [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId)) {
    $ManagedIdentityAccountId = Get-AutomationVariableString -Name $DefaultManagedIdentityAccountIdAutomationVariableName
}

if ($IsAzureAutomationRunbook -and -not $PSBoundParameters.ContainsKey('TargetVirtualNetworkResourceId')) {
    $automationTargetVirtualNetworkResourceId = Get-AutomationVariableString -Name $DefaultAksTargetVirtualNetworkResourceIdAutomationVariableName
    if (-not [string]::IsNullOrWhiteSpace($automationTargetVirtualNetworkResourceId)) {
        $TargetVirtualNetworkResourceId = $automationTargetVirtualNetworkResourceId
    }
}

if ($IsAzureAutomationRunbook -and [string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
    $SourceSubscriptionId = Get-AutomationVariableString -Name $DefaultSourceSubscriptionIdAutomationVariableName
}

if ([string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
    $SourceSubscriptionId = Get-SubscriptionIdFromResourceId -ResourceId $TargetVirtualNetworkResourceId
}

if ([string]::IsNullOrWhiteSpace($LinkName)) {
    $LinkName = New-DefaultLinkName -VirtualNetworkResourceId $TargetVirtualNetworkResourceId
}

$UseManagedIdentityLogin = [bool]($UseManagedIdentity -or -not [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId) -or $IsAzureAutomationRunbook)
if ($UseManagedIdentityLogin -and $IsAzureAutomationRunbook -and -not $UseManagedIdentity -and [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId)) {
    Write-TraceLog -Message 'Azure Automation runbook environment detected. Using the Automation Account system-assigned managed identity for Azure login.'
}

Write-TraceLog -Message "Starting Repair-AksPrivateDnsLinks.ps1. SourceSubscriptionId='$SourceSubscriptionId'; TargetVirtualNetworkResourceId='$TargetVirtualNetworkResourceId'; LinkName='$LinkName'; WhatIf='$WhatIfPreference'; UseManagedIdentity='$UseManagedIdentityLogin'."
Write-TraceLog -Message "AKS private DNS suffix filter='$AksPrivateDnsZoneSuffix'."

Write-TraceLog -Message "Selecting Azure China source subscription '$SourceSubscriptionId'."
Select-AzureChinaSubscription `
    -TargetSubscriptionId $SourceSubscriptionId `
    -TargetTenantId $TenantId `
    -UseManagedIdentityLogin $UseManagedIdentityLogin `
    -TargetManagedIdentityAccountId $ManagedIdentityAccountId

Write-TraceLog -Message "Scanning private DNS zones in source subscription '$SourceSubscriptionId'."
$allZones = @(Get-PrivateDnsZonesInSubscription -TargetSubscriptionId $SourceSubscriptionId)
Write-TraceLog -Message "Private DNS zones discovered='$($allZones.Count)'."
$matchingZones = @(
    foreach ($zone in $allZones) {
        if (Test-AksPrivateDnsZoneName -Name $zone.Name -Suffix $AksPrivateDnsZoneSuffix) {
            [pscustomobject]@{
                Zone     = $zone
                ZoneType = 'AKS'
            }
        }
    }
)

if ($matchingZones.Count -eq 0) {
    Write-TraceLog -Level WARN -Message "No AKS private DNS zones ending with '$AksPrivateDnsZoneSuffix' were found in source subscription '$SourceSubscriptionId'."
    Write-TraceLog -Message "Completed Repair-AksPrivateDnsLinks.ps1 in $(Format-TraceDuration -StartTime $RunStartedAt)."
    return
}

Write-TraceLog -Message "Found '$($matchingZones.Count)' matching private DNS zone(s). Ensuring virtual network link '$LinkName'."
$results = foreach ($match in $matchingZones) {
    Ensure-PrivateDnsZoneVirtualNetworkLink `
        -Zone $match.Zone `
        -ZoneSubscriptionId $SourceSubscriptionId `
        -TargetVirtualNetworkId $TargetVirtualNetworkResourceId `
        -TargetLinkName $LinkName `
        -ZoneType $match.ZoneType
}

Write-TraceLog -Message "Operation summary for '$(@($results).Count)' result row(s):"
foreach ($actionGroup in @($results | Group-Object Action | Sort-Object Name)) {
    Write-TraceLog -Message "  $($actionGroup.Name): $($actionGroup.Count)"
}

Write-TraceLog -Message "Completed Repair-AksPrivateDnsLinks.ps1 in $(Format-TraceDuration -StartTime $RunStartedAt)."

$results | Sort-Object ZoneType, ZoneName | Format-Table -AutoSize