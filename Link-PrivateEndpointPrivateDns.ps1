<#
.SYNOPSIS
Links one Azure China private endpoint to its inferred target private DNS zones.

.DESCRIPTION
Accepts a Microsoft.Network/privateEndpoints resource ID, reads the endpoint's
private IP addresses, FQDN metadata, connected resource ID, resource type, and
private-link group IDs, and infers the recommended Azure China private DNS zone
name or names. It then finds those zones in the destination subscription and
updates the private endpoint's privateDnsZoneGroup so Azure manages its A
records automatically.

Zone inference combines three sources:
- private DNS zones already present in the endpoint's zone group;
- public or private-link FQDNs exposed by the endpoint and its network interface;
- the connected Azure resource type and private-link group ID.

Multi-zone services such as Azure Machine Learning and IoT Hub are supported.
The runbook fails rather than guessing when no supported zone can be inferred,
when duplicate destination zones are ambiguous, or when source and destination
subscriptions are in different Microsoft Entra tenants.

This runbook creates or updates a private DNS zone group on the private
endpoint. It does not create private DNS virtual network links. VNet links are
a separate DNS-resolution concern.

By default, the runbook scans all Private DNS zones in the destination
subscription and requires exactly one exact zone-name match. Optionally supply
DestinationPrivateDnsZoneResourceGroupName to restrict the search. If a
required zone is missing, it can be created only when that resource group is
supplied. Duplicate subscription-wide matches fail safely rather than guessing.
Use SkipCreateMissingDestinationZones to require all zones to exist already.

In Azure Automation, tenant, destination subscription, destination DNS resource
group, and an optional user-assigned managed identity client ID can be read from
dedicated Automation variables. When this runbook shares the Automation Account
deployed by Deploy-AzureChinaPrivateDnsAutomation.ps1, it falls back to
that deployment's shared tenant, destination, and managed identity variables.

Required permissions:
- Reader and Network Contributor on the private endpoint and its network
  interface (or equivalent least-privilege permissions).
- Reader on existing destination private DNS zones.
- Private DNS Zone Contributor when a missing destination zone may be created.
- Contributor on the destination resource group only when the runbook must
  create that resource group.

.EXAMPLE
    .\Link-PrivateEndpointPrivateDns.ps1 `
        -PrivateEndpointResourceId "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-app/providers/Microsoft.Network/privateEndpoints/pe-storage-blob" `
        -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -DestinationPrivateDnsZoneResourceGroupName "rg-central-private-dns" `
        -WhatIf

Preview the inferred zone and private DNS zone-group update.

.EXAMPLE
    .\Link-PrivateEndpointPrivateDns.ps1 `
        -PrivateEndpointResourceId "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-app/providers/Microsoft.Network/privateEndpoints/pe-aml" `
        -UseManagedIdentity

Run in Azure Automation. The runbook derives the source subscription from the
private endpoint resource ID and uses its dedicated Automation variables for
destination defaults when they are available.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PrivateEndpointResourceId,

    [ValidateNotNullOrEmpty()]
    [string]$DestinationSubscriptionId,

    [string]$SourceTenantId,

    [string]$DestinationTenantId,

    [switch]$UseManagedIdentity,

    [string]$ManagedIdentityAccountId,

    [string]$DestinationPrivateDnsZoneResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$DestinationResourceGroupLocation = 'chinaeast2',

    [switch]$SkipCreateMissingDestinationZones,

    [ValidateNotNullOrEmpty()]
    [string]$PrivateDnsZoneGroupName = 'default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NetworkApiVersion = '2023-09-01'
$PrivateDnsApiVersion = '2018-09-01'
$ResourceGroupApiVersion = '2021-04-01'
$TenantIdAutomationVariableName = 'LinkPrivateEndpointPrivateDnsTenantId'
$DestinationSubscriptionIdAutomationVariableName = 'LinkPrivateEndpointPrivateDnsDestinationSubscriptionId'
$DestinationZoneResourceGroupAutomationVariableName = 'LinkPrivateEndpointPrivateDnsDestinationZoneResourceGroupName'
$ManagedIdentityAccountIdAutomationVariableName = 'LinkPrivateEndpointPrivateDnsManagedIdentityAccountId'
$SharedTenantIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsTenantId'
$SharedDestinationSubscriptionIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsDestinationSubscriptionId'
$SharedManagedIdentityAccountIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsManagedIdentityAccountId'
$ScriptCommand = $PSCmdlet
$script:ConnectedWithManagedIdentity = $false
$script:AzContextAutosaveDisabled = $false
$RunStartedAt = Get-Date

$AzureChinaPaaSPrivateDnsZonePatterns = @(
    '^privatelink\.api\.ml\.azure\.cn$',
    '^privatelink\.notebooks\.chinacloudapi\.cn$',
    '^privatelink\.search\.azure\.cn$',
    '^privatelink\.cognitiveservices\.azure\.cn$',
    '^privatelink\.databricks\.azure\.cn$',
    '^privatelink\.(blob|dfs|file|queue|table|web)\.core\.chinacloudapi\.cn$',
    '^privatelink\.afs\.azure\.cn$',
    '^privatelink\.database\.chinacloudapi\.cn$',
    '^privatelink\.(mysql|mariadb)\.database\.chinacloudapi\.cn$',
    '^privatelink\.documents\.azure\.cn$',
    '^privatelink\.(mongo|cassandra|gremlin|table)\.cosmos\.azure\.cn$',
    '^privatelink\.vaultcore\.azure\.cn$',
    '^privatelink\.servicebus\.chinacloudapi\.cn$',
    '^privatelink\.redis\.cache\.chinacloudapi\.cn$',
    '^privatelink\.redis\.chinacloudapi\.cn$',
    '^privatelink\.chinacloudsites\.cn$',
    '^privatelink\.datafactory\.azure\.cn$',
    '^privatelink\.adf\.azure\.cn$',
    '^privatelink\.azure-automation\.cn$',
    '^privatelink\.signalr\.azure\.cn$',
    '^privatelink\.eventgrid\.azure\.cn$',
    '^privatelink\.azure-devices\.cn$',
    '^privatelink\.azure-devices-provisioning\.cn$',
    '^privatelink\.azurehdinsight\.cn$',
    '^privatelink\.[a-z0-9-]+\.kusto\.windows\.cn$',
    '^privatelink\.batch\.chinacloudapi\.cn$',
    '^privatelink-global\.wvd\.azure\.cn$',
    '^privatelink\.wvd\.azure\.cn$'
)

$AzureChinaPublicDnsSuffixToPrivateDnsZones = @{
    'api.ml.azure.cn'                         = @('privatelink.api.ml.azure.cn')
    'notebooks.chinacloudapi.cn'              = @('privatelink.notebooks.chinacloudapi.cn')
    'search.azure.cn'                         = @('privatelink.search.azure.cn')
    'cognitiveservices.azure.cn'              = @('privatelink.cognitiveservices.azure.cn')
    'blob.core.chinacloudapi.cn'              = @('privatelink.blob.core.chinacloudapi.cn')
    'dfs.core.chinacloudapi.cn'               = @('privatelink.dfs.core.chinacloudapi.cn')
    'file.core.chinacloudapi.cn'              = @('privatelink.file.core.chinacloudapi.cn')
    'queue.core.chinacloudapi.cn'             = @('privatelink.queue.core.chinacloudapi.cn')
    'table.core.chinacloudapi.cn'             = @('privatelink.table.core.chinacloudapi.cn')
    'web.core.chinacloudapi.cn'               = @('privatelink.web.core.chinacloudapi.cn')
    'afs.azure.cn'                            = @('privatelink.afs.azure.cn')
    'database.chinacloudapi.cn'               = @('privatelink.database.chinacloudapi.cn')
    'mysql.database.chinacloudapi.cn'         = @('privatelink.mysql.database.chinacloudapi.cn')
    'mariadb.database.chinacloudapi.cn'       = @('privatelink.mariadb.database.chinacloudapi.cn')
    'documents.azure.cn'                      = @('privatelink.documents.azure.cn')
    'mongo.cosmos.azure.cn'                   = @('privatelink.mongo.cosmos.azure.cn')
    'cassandra.cosmos.azure.cn'               = @('privatelink.cassandra.cosmos.azure.cn')
    'gremlin.cosmos.azure.cn'                 = @('privatelink.gremlin.cosmos.azure.cn')
    'table.cosmos.azure.cn'                   = @('privatelink.table.cosmos.azure.cn')
    'vaultcore.azure.cn'                      = @('privatelink.vaultcore.azure.cn')
    'servicebus.chinacloudapi.cn'             = @('privatelink.servicebus.chinacloudapi.cn')
    'redis.cache.chinacloudapi.cn'            = @('privatelink.redis.cache.chinacloudapi.cn')
    'redis.chinacloudapi.cn'                  = @('privatelink.redis.chinacloudapi.cn')
    'chinacloudsites.cn'                      = @('privatelink.chinacloudsites.cn')
    'datafactory.azure.cn'                    = @('privatelink.datafactory.azure.cn')
    'adf.azure.cn'                            = @('privatelink.adf.azure.cn')
    'azure-automation.cn'                     = @('privatelink.azure-automation.cn')
    'service.signalr.azure.cn'                = @('privatelink.signalr.azure.cn')
    'eventgrid.azure.cn'                      = @('privatelink.eventgrid.azure.cn')
    'azure-devices.cn'                        = @('privatelink.azure-devices.cn')
    'azure-devices-provisioning.cn'           = @('privatelink.azure-devices-provisioning.cn')
    'azurehdinsight.cn'                       = @('privatelink.azurehdinsight.cn')
    'batch.chinacloudapi.cn'                  = @('privatelink.batch.chinacloudapi.cn')
    'service.batch.chinacloudapi.cn'          = @('privatelink.batch.chinacloudapi.cn')
}

$AzureChinaResourceGroupToPrivateDnsZones = @{
    'microsoft.machinelearningservices/workspaces|amlworkspace' = @('privatelink.api.ml.azure.cn', 'privatelink.notebooks.chinacloudapi.cn')
    'microsoft.search/searchservices|searchservice'             = @('privatelink.search.azure.cn')
    'microsoft.cognitiveservices/accounts|account'              = @('privatelink.cognitiveservices.azure.cn')
    'microsoft.databricks/workspaces|databricks_ui_api'         = @('privatelink.databricks.azure.cn')
    'microsoft.databricks/workspaces|browser_authentication'    = @('privatelink.databricks.azure.cn')
    'microsoft.datafactory/factories|datafactory'                = @('privatelink.datafactory.azure.cn')
    'microsoft.datafactory/factories|portal'                     = @('privatelink.adf.azure.cn')
    'microsoft.hdinsight/clusters|gateway'                       = @('privatelink.azurehdinsight.cn')
    'microsoft.hdinsight/clusters|headnode'                      = @('privatelink.azurehdinsight.cn')
    'microsoft.batch/batchaccounts|batchaccount'                 = @('privatelink.batch.chinacloudapi.cn')
    'microsoft.batch/batchaccounts|nodemanagement'               = @('privatelink.batch.chinacloudapi.cn')
    'microsoft.desktopvirtualization/workspaces|global'          = @('privatelink-global.wvd.azure.cn')
    'microsoft.desktopvirtualization/workspaces|feed'            = @('privatelink.wvd.azure.cn')
    'microsoft.desktopvirtualization/workspaces|connection'      = @('privatelink.wvd.azure.cn')
    'microsoft.desktopvirtualization/hostpools|connection'       = @('privatelink.wvd.azure.cn')
    'microsoft.sql/servers|sqlserver'                            = @('privatelink.database.chinacloudapi.cn')
    'microsoft.documentdb/databaseaccounts|sql'                  = @('privatelink.documents.azure.cn')
    'microsoft.documentdb/databaseaccounts|mongodb'              = @('privatelink.mongo.cosmos.azure.cn')
    'microsoft.documentdb/databaseaccounts|cassandra'            = @('privatelink.cassandra.cosmos.azure.cn')
    'microsoft.documentdb/databaseaccounts|gremlin'              = @('privatelink.gremlin.cosmos.azure.cn')
    'microsoft.documentdb/databaseaccounts|table'                = @('privatelink.table.cosmos.azure.cn')
    'microsoft.dbformysql/servers|mysqlserver'                   = @('privatelink.mysql.database.chinacloudapi.cn')
    'microsoft.dbformysql/flexibleservers|mysqlserver'           = @('privatelink.mysql.database.chinacloudapi.cn')
    'microsoft.dbformariadb/servers|mariadbserver'               = @('privatelink.mariadb.database.chinacloudapi.cn')
    'microsoft.cache/redis|rediscache'                           = @('privatelink.redis.cache.chinacloudapi.cn')
    'microsoft.cache/redisenterprise|redisenterprise'            = @('privatelink.redis.chinacloudapi.cn')
    'microsoft.servicebus/namespaces|namespace'                  = @('privatelink.servicebus.chinacloudapi.cn')
    'microsoft.eventhub/namespaces|namespace'                    = @('privatelink.servicebus.chinacloudapi.cn')
    'microsoft.relay/namespaces|namespace'                       = @('privatelink.servicebus.chinacloudapi.cn')
    'microsoft.devices/iothubs|iothub'                           = @('privatelink.azure-devices.cn', 'privatelink.servicebus.chinacloudapi.cn')
    'microsoft.devices/provisioningservices|iotdps'              = @('privatelink.azure-devices-provisioning.cn')
    'microsoft.automation/automationaccounts|webhook'            = @('privatelink.azure-automation.cn')
    'microsoft.automation/automationaccounts|dscandhybridworker' = @('privatelink.azure-automation.cn')
    'microsoft.keyvault/vaults|vault'                            = @('privatelink.vaultcore.azure.cn')
    'microsoft.storage/storageaccounts|blob'                     = @('privatelink.blob.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|blob_secondary'           = @('privatelink.blob.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|dfs'                      = @('privatelink.dfs.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|dfs_secondary'            = @('privatelink.dfs.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|file'                     = @('privatelink.file.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|file_secondary'           = @('privatelink.file.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|queue'                    = @('privatelink.queue.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|queue_secondary'          = @('privatelink.queue.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|table'                    = @('privatelink.table.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|table_secondary'          = @('privatelink.table.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|web'                      = @('privatelink.web.core.chinacloudapi.cn')
    'microsoft.storage/storageaccounts|web_secondary'            = @('privatelink.web.core.chinacloudapi.cn')
    'microsoft.storagesync/storagesyncservices|afs'              = @('privatelink.afs.azure.cn')
    'microsoft.web/sites|sites'                                  = @('privatelink.chinacloudsites.cn')
    'microsoft.signalrservice/signalr|signalr'                   = @('privatelink.signalr.azure.cn')
    'microsoft.eventgrid/topics|topic'                           = @('privatelink.eventgrid.azure.cn')
    'microsoft.eventgrid/domains|domain'                         = @('privatelink.eventgrid.azure.cn')
}

function Write-TraceLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK'))][$Level] $Message"
    switch ($Level) {
        'WARN' { Write-Warning $line }
        'ERROR' { Write-Error -Message $line -ErrorAction Continue }
        default { Write-Verbose -Message $line -Verbose }
    }
}

function Write-TraceError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-TraceLog -Level ERROR -Message "Unhandled error: $($ErrorRecord.Exception.Message)"
    if ($ErrorRecord.InvocationInfo -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.InvocationInfo.PositionMessage)) {
        Write-TraceLog -Level ERROR -Message "Error location: $($ErrorRecord.InvocationInfo.PositionMessage)"
    }

    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
        Write-TraceLog -Level ERROR -Message "Script stack trace: $($ErrorRecord.ScriptStackTrace)"
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
        if ($null -ne $value) {
            return [string]$value
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-FirstAutomationVariableString {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $value = Get-AutomationVariableString -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
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

    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Import-RequiredAzModules {
    foreach ($moduleName in @('Az.Accounts', 'Az.Resources')) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            throw "$moduleName is required. Import it into the Automation Account or install it locally."
        }

        Import-Module $moduleName -ErrorAction Stop
    }
}

function Select-AzureChinaSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [string]$TenantId,

        [bool]$UseManagedIdentityLogin,

        [string]$IdentityAccountId
    )

    Import-RequiredAzModules
    if ($UseManagedIdentityLogin -and -not $script:AzContextAutosaveDisabled) {
        Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null
        $script:AzContextAutosaveDisabled = $true
    }

    $connectParameters = @{
        Environment           = 'AzureChinaCloud'
        Subscription          = $SubscriptionId
        SkipContextPopulation = $true
        Scope                 = 'Process'
        ErrorAction           = 'Stop'
        WhatIf                = $false
    }
    $contextParameters = @{
        SubscriptionId = $SubscriptionId
        Scope          = 'Process'
        ErrorAction    = 'Stop'
        WhatIf         = $false
    }

    if ($UseManagedIdentityLogin) {
        $connectParameters['Identity'] = $true
        if (-not [string]::IsNullOrWhiteSpace($IdentityAccountId)) {
            $connectParameters['AccountId'] = $IdentityAccountId
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectParameters['Tenant'] = $TenantId
        $contextParameters['Tenant'] = $TenantId
    }

    $connectAccount = {
        try {
            Connect-AzAccount @connectParameters | Out-Null
        }
        catch {
            if (-not $UseManagedIdentityLogin) {
                throw
            }

            $identityDescription = if ([string]::IsNullOrWhiteSpace($IdentityAccountId)) {
                'the Automation Account system-assigned managed identity'
            }
            else {
                "user-assigned managed identity client ID '$IdentityAccountId'"
            }
            $tenantDescription = if ([string]::IsNullOrWhiteSpace($TenantId)) {
                'without an explicit tenant ID'
            }
            else {
                "in tenant '$TenantId'"
            }

            throw "Azure China sign-in failed using $identityDescription for subscription '$SubscriptionId' $tenantDescription. Confirm that the identity is enabled on the Automation Account. For a user-assigned identity, use its client ID (not its object/principal ID) and confirm that it is attached to the Automation Account. Original error: $($_.Exception.Message)"
        }
    }

    if ($UseManagedIdentityLogin) {
        if (-not $script:ConnectedWithManagedIdentity) {
            & $connectAccount
            $script:ConnectedWithManagedIdentity = $true
        }
    }
    else {
        $currentContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $currentContext -or $currentContext.Environment.Name -ne 'AzureChinaCloud') {
            & $connectAccount
        }
    }

    try {
        Set-AzContext @contextParameters | Out-Null
    }
    catch {
        & $connectAccount
        if ($UseManagedIdentityLogin) {
            $script:ConnectedWithManagedIdentity = $true
        }

        Set-AzContext @contextParameters | Out-Null
    }

    $selectedContext = Get-AzContext -ErrorAction Stop
    if ($selectedContext.Environment.Name -ne 'AzureChinaCloud' -or
        [string]$selectedContext.Subscription.Id -ine $SubscriptionId) {
        throw "Azure context validation failed. Expected AzureChinaCloud subscription '$SubscriptionId'; selected environment='$($selectedContext.Environment.Name)', subscription='$([string]$selectedContext.Subscription.Id)'."
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantId) -and
        [string]$selectedContext.Tenant.Id -ine $TenantId) {
        throw "Azure context validation failed. Subscription '$SubscriptionId' selected tenant '$([string]$selectedContext.Tenant.Id)' instead of required tenant '$TenantId'."
    }

    return $selectedContext
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
    if (-not [string]::IsNullOrWhiteSpace($Uri)) {
        $parameters['Uri'] = $Uri
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Path)) {
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
        throw "ARM $Method failed for '$target'. Status='$statusCode'. Response='$($response.Content)'."
    }

    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
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
        $page = if ($nextLink -match '^https?://') {
            Invoke-ArmJson -Method GET -Uri $nextLink -ExpectedStatusCode @(200)
        }
        else {
            Invoke-ArmJson -Method GET -Path $nextLink -ExpectedStatusCode @(200)
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
        throw "Could not read a resource group name from resource ID '$ResourceId'."
    }

    return [System.Uri]::UnescapeDataString($Matches[1])
}

function Get-ProviderResourceTypeFromResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    $match = [regex]::Match($ResourceId, '/providers/([^/]+)/([^/]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }

    return "$($match.Groups[1].Value)/$($match.Groups[2].Value)".ToLowerInvariant()
}

function ConvertTo-NormalizedFqdn {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Trim().TrimEnd('.').ToLowerInvariant()
}

function Assert-IPv4Address {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsedAddress) -or
        $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Private endpoint IP '$Value' is not a valid IPv4 address."
    }
}

function Test-AzureChinaPaaSPrivateDnsZoneName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $normalizedName = $Name.Trim().TrimEnd('.').ToLowerInvariant()
    foreach ($pattern in $AzureChinaPaaSPrivateDnsZonePatterns) {
        if ($normalizedName -match $pattern) {
            return $true
        }
    }

    return $false
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

        $fqdn = [string](Get-ObjectPropertyValue -InputObject $customDnsConfig -Name 'fqdn')
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
            $normalizedFqdn = ConvertTo-NormalizedFqdn -Value $fqdn
            if (-not $fqdns.Contains($normalizedFqdn)) {
                $fqdns.Add($normalizedFqdn)
            }
        }

        foreach ($ipAddress in @(Get-ObjectPropertyValue -InputObject $customDnsConfig -Name 'ipAddresses')) {
            $normalizedIpAddress = ([string]$ipAddress).Trim()
            if (-not [string]::IsNullOrWhiteSpace($normalizedIpAddress) -and -not $privateIpAddresses.Contains($normalizedIpAddress)) {
                $privateIpAddresses.Add($normalizedIpAddress)
            }
        }
    }

    foreach ($networkInterfaceReference in @(Get-ObjectPropertyValue -InputObject $properties -Name 'networkInterfaces')) {
        $networkInterfaceId = [string](Get-ObjectPropertyValue -InputObject $networkInterfaceReference -Name 'id')
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
            $ipConfigurationProperties = Get-ObjectPropertyValue -InputObject $ipConfiguration -Name 'properties'
            $privateIpAddress = ([string](Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateIPAddress')).Trim()
            if (-not [string]::IsNullOrWhiteSpace($privateIpAddress) -and -not $privateIpAddresses.Contains($privateIpAddress)) {
                $privateIpAddresses.Add($privateIpAddress)
            }

            $privateLinkConnectionProperties = Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateLinkConnectionProperties'
            foreach ($fqdnValue in @(Get-ObjectPropertyValue -InputObject $privateLinkConnectionProperties -Name 'fqdns')) {
                $fqdn = ([string]$fqdnValue).Trim()
                if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
                    $normalizedFqdn = ConvertTo-NormalizedFqdn -Value $fqdn
                    if (-not $fqdns.Contains($normalizedFqdn)) {
                        $fqdns.Add($normalizedFqdn)
                    }
                }
            }
        }
    }

    foreach ($ipConfiguration in @(Get-ObjectPropertyValue -InputObject $properties -Name 'ipConfigurations')) {
        $ipConfigurationProperties = Get-ObjectPropertyValue -InputObject $ipConfiguration -Name 'properties'
        $privateIpAddress = ([string](Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateIPAddress')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($privateIpAddress) -and -not $privateIpAddresses.Contains($privateIpAddress)) {
            $privateIpAddresses.Add($privateIpAddress)
        }

        $privateLinkConnectionProperties = Get-ObjectPropertyValue -InputObject $ipConfigurationProperties -Name 'privateLinkConnectionProperties'
        foreach ($fqdnValue in @(Get-ObjectPropertyValue -InputObject $privateLinkConnectionProperties -Name 'fqdns')) {
            $fqdn = ([string]$fqdnValue).Trim()
            if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
                $normalizedFqdn = ConvertTo-NormalizedFqdn -Value $fqdn
                if (-not $fqdns.Contains($normalizedFqdn)) {
                    $fqdns.Add($normalizedFqdn)
                }
            }
        }
    }

    return [pscustomobject]@{
        Name               = [string]$PrivateEndpoint.name
        Id                 = [string]$PrivateEndpoint.id
        ResourceGroupName  = Get-ResourceGroupNameFromResourceId -ResourceId ([string]$PrivateEndpoint.id)
        PrivateIpAddresses = @($privateIpAddresses.ToArray())
        Fqdns              = @($fqdns.ToArray())
    }
}

function Get-PrivateEndpointConnectionDetails {
    param(
        [Parameter(Mandatory = $true)]
        [object]$PrivateEndpoint
    )

    $results = New-Object System.Collections.Generic.List[object]
    $properties = Get-ObjectPropertyValue -InputObject $PrivateEndpoint -Name 'properties'
    foreach ($connectionCollectionName in @('privateLinkServiceConnections', 'manualPrivateLinkServiceConnections')) {
        foreach ($connection in @(Get-ObjectPropertyValue -InputObject $properties -Name $connectionCollectionName)) {
            if ($null -eq $connection) {
                continue
            }

            $connectionProperties = Get-ObjectPropertyValue -InputObject $connection -Name 'properties'
            $privateLinkServiceId = [string](Get-ObjectPropertyValue -InputObject $connectionProperties -Name 'privateLinkServiceId')
            $resourceType = if ([string]::IsNullOrWhiteSpace($privateLinkServiceId)) {
                $null
            }
            else {
                Get-ProviderResourceTypeFromResourceId -ResourceId $privateLinkServiceId
            }
            $connectionState = Get-ObjectPropertyValue -InputObject $connectionProperties -Name 'privateLinkServiceConnectionState'
            $connectionStatus = [string](Get-ObjectPropertyValue -InputObject $connectionState -Name 'status')
            $groupIds = @((Get-ObjectPropertyValue -InputObject $connectionProperties -Name 'groupIds') | ForEach-Object {
                [string]$_
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            if ($groupIds.Count -eq 0) {
                $results.Add([pscustomobject]@{
                    ConnectionName       = [string]$connection.name
                    ConnectionCollection = $connectionCollectionName
                    ConnectionStatus     = $connectionStatus
                    PrivateLinkServiceId = $privateLinkServiceId
                    ResourceType         = $resourceType
                    GroupId              = $null
                })
                continue
            }

            foreach ($groupId in $groupIds) {
                $results.Add([pscustomobject]@{
                    ConnectionName       = [string]$connection.name
                    ConnectionCollection = $connectionCollectionName
                    ConnectionStatus     = $connectionStatus
                    PrivateLinkServiceId = $privateLinkServiceId
                    ResourceType         = $resourceType
                    GroupId              = $groupId
                })
            }
        }
    }

    return $results
}

function Test-PrivateEndpointIsPostgreSql {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Connections
    )

    foreach ($connection in @($Connections)) {
        if ([string]$connection.ResourceType -imatch '^microsoft\.dbforpostgresql/' -or
            [string]$connection.GroupId -ieq 'postgresqlServer') {
            return $true
        }
    }

    return $false
}

function Get-PrivateDnsZoneGroupName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$PrivateDnsZoneGroup
    )

    $resourceId = [string](Get-ObjectPropertyValue -InputObject $PrivateDnsZoneGroup -Name 'id')
    if ($resourceId -match '/privateDnsZoneGroups/([^/?]+)(?:\?|$)') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }

    $resourceName = [string](Get-ObjectPropertyValue -InputObject $PrivateDnsZoneGroup -Name 'name')
    if (-not [string]::IsNullOrWhiteSpace($resourceName)) {
        return [System.Uri]::UnescapeDataString((@($resourceName -split '/')[-1]))
    }

    return $null
}

function New-PrivateDnsZoneGroupPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrivateEndpointId,

        [Parameter(Mandatory = $true)]
        [string]$ZoneGroupName
    )

    $groupSegment = ConvertTo-ArmPathSegment -Value $ZoneGroupName
    return "${PrivateEndpointId}/privateDnsZoneGroups/${groupSegment}?api-version=$NetworkApiVersion"
}

function Wait-PrivateDnsZoneGroupDeleted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$PrivateEndpointName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneGroupName,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 180,

        [ValidateRange(1, 60)]
        [int]$PollIntervalSeconds = 2
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $remainingGroup = Invoke-ArmJson `
            -Method GET `
            -Path $Path `
            -ExpectedStatusCode @(200) `
            -AllowNotFound
        if ($null -eq $remainingGroup) {
            return
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out after '$TimeoutSeconds' seconds waiting for private DNS zone group '$ZoneGroupName' on endpoint '$PrivateEndpointName' to finish deleting. Rerun the runbook after Azure completes the deletion."
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Get-PrivateDnsZoneGroupZoneIds {
    param(
        [Parameter(Mandatory = $true)]
        [object]$PrivateDnsZoneGroup
    )

    $properties = Get-ObjectPropertyValue -InputObject $PrivateDnsZoneGroup -Name 'properties'
    return @((Get-ObjectPropertyValue -InputObject $properties -Name 'privateDnsZoneConfigs') | ForEach-Object {
        $configProperties = Get-ObjectPropertyValue -InputObject $_ -Name 'properties'
        [string](Get-ObjectPropertyValue -InputObject $configProperties -Name 'privateDnsZoneId')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Add-ZoneInference {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Lookup,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $normalizedZoneName = $ZoneName.Trim().TrimEnd('.').ToLowerInvariant()
    if (-not (Test-AzureChinaPaaSPrivateDnsZoneName -Name $normalizedZoneName)) {
        return
    }

    if (-not $Lookup.Contains($normalizedZoneName)) {
        $Lookup[$normalizedZoneName] = [pscustomobject]@{
            ZoneName = $normalizedZoneName
            Sources  = New-Object System.Collections.Generic.List[string]
        }
    }

    if (-not $Lookup[$normalizedZoneName].Sources.Contains($Source)) {
        $Lookup[$normalizedZoneName].Sources.Add($Source)
    }
}

function Get-InferredPrivateDnsZones {
    param(
        [Parameter(Mandatory = $true)]
        [object]$DnsDetails,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Connections,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$ExistingZoneGroups
    )

    $lookup = @{}
    foreach ($zoneGroup in @($ExistingZoneGroups)) {
        foreach ($zoneId in @(Get-PrivateDnsZoneGroupZoneIds -PrivateDnsZoneGroup $zoneGroup)) {
            if ($zoneId -match '/privateDnsZones/([^/]+)$') {
                $zoneName = [System.Uri]::UnescapeDataString($Matches[1])
                Add-ZoneInference -Lookup $lookup -ZoneName $zoneName -Source "ExistingZoneGroup:$zoneId"
            }
        }
    }

    $publicDnsSuffixes = @($AzureChinaPublicDnsSuffixToPrivateDnsZones.Keys | Sort-Object Length -Descending)
    foreach ($fqdnValue in @($DnsDetails.Fqdns)) {
        $fqdn = ConvertTo-NormalizedFqdn -Value ([string]$fqdnValue)
        if ($fqdn -match '(?:^|\.)(privatelink(?:-global)?\..+)$') {
            Add-ZoneInference -Lookup $lookup -ZoneName $Matches[1] -Source "EndpointFqdn:$fqdn"
        }

        foreach ($publicDnsSuffix in $publicDnsSuffixes) {
            if ($fqdn -ieq $publicDnsSuffix -or $fqdn.EndsWith(".$publicDnsSuffix", [System.StringComparison]::OrdinalIgnoreCase)) {
                foreach ($zoneName in @($AzureChinaPublicDnsSuffixToPrivateDnsZones[$publicDnsSuffix])) {
                    Add-ZoneInference -Lookup $lookup -ZoneName $zoneName -Source "EndpointFqdn:$fqdn"
                }

                break
            }
        }

        if ($fqdn -match '(?:^|\.)([a-z0-9-]+)\.kusto\.windows\.cn$') {
            Add-ZoneInference `
                -Lookup $lookup `
                -ZoneName "privatelink.$($Matches[1]).kusto.windows.cn" `
                -Source "EndpointFqdn:$fqdn"
        }
    }

    foreach ($connection in @($Connections)) {
        $resourceType = ([string]$connection.ResourceType).Trim().ToLowerInvariant()
        $groupId = ([string]$connection.GroupId).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($resourceType) -or [string]::IsNullOrWhiteSpace($groupId)) {
            continue
        }

        $mappingKey = "$resourceType|$groupId"
        if ($AzureChinaResourceGroupToPrivateDnsZones.ContainsKey($mappingKey)) {
            foreach ($zoneName in @($AzureChinaResourceGroupToPrivateDnsZones[$mappingKey])) {
                Add-ZoneInference -Lookup $lookup -ZoneName $zoneName -Source "ResourceTypeAndGroupId:$mappingKey"
            }

            continue
        }

        if ($resourceType -eq 'microsoft.web/sites' -and $groupId.StartsWith('sites-', [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-ZoneInference `
                -Lookup $lookup `
                -ZoneName 'privatelink.chinacloudsites.cn' `
                -Source "ResourceTypeAndGroupId:$mappingKey"
            continue
        }

        if ($mappingKey -eq 'microsoft.kusto/clusters|cluster') {
            try {
                $connectedResource = Get-AzResource `
                    -ResourceId ([string]$connection.PrivateLinkServiceId) `
                    -ExpandProperties `
                    -ErrorAction Stop
                $regionName = ([string]$connectedResource.Location).Trim().ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($regionName)) {
                    Add-ZoneInference `
                        -Lookup $lookup `
                        -ZoneName "privatelink.$regionName.kusto.windows.cn" `
                        -Source "ResourceTypeGroupAndLocation:$mappingKey/$regionName"
                }
            }
            catch {
                Write-TraceLog -Level WARN -Message "Could not read Azure Data Explorer resource '$($connection.PrivateLinkServiceId)' to infer its regional zone: $($_.Exception.Message)"
            }
        }
    }

    return @($lookup.Values | ForEach-Object {
        [pscustomobject]@{
            ZoneName = [string]$_.ZoneName
            Sources  = @($_.Sources.ToArray() | Sort-Object -Unique)
        }
    } | Sort-Object ZoneName)
}

function Get-PrivateDnsZonesInScope {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [string]$ResourceGroupName
    )

    $path = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        "/subscriptions/$SubscriptionId/providers/Microsoft.Network/privateDnsZones?api-version=$PrivateDnsApiVersion"
    }
    else {
        $resourceGroupSegment = ConvertTo-ArmPathSegment -Value $ResourceGroupName
        "/subscriptions/$SubscriptionId/resourceGroups/$resourceGroupSegment/providers/Microsoft.Network/privateDnsZones?api-version=$PrivateDnsApiVersion"
    }

    return @(Get-ArmPagedValues -Path $path | ForEach-Object {
        [pscustomobject]@{
            Name              = [string]$_.name
            ResourceGroupName = Get-ResourceGroupNameFromResourceId -ResourceId ([string]$_.id)
            Id                = [string]$_.id
        }
    })
}

function Confirm-ResourceGroupExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $resourceGroupSegment = ConvertTo-ArmPathSegment -Value $ResourceGroupName
    $path = "/subscriptions/$SubscriptionId/resourceGroups/${resourceGroupSegment}?api-version=$ResourceGroupApiVersion"
    $existingResourceGroup = Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200) -AllowNotFound
    if ($existingResourceGroup) {
        return
    }

    if ($ScriptCommand.ShouldProcess("$SubscriptionId/$ResourceGroupName", 'Create destination resource group')) {
        Invoke-ArmJson `
            -Method PUT `
            -Path $path `
            -Body @{ location = $Location } `
            -ExpectedStatusCode @(200, 201) | Out-Null
    }
}

function Wait-PrivateDnsZoneReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ZoneName,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 300,

        [ValidateRange(1, 60)]
        [int]$PollIntervalSeconds = 2
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $zone = Invoke-ArmJson `
            -Method GET `
            -Path $Path `
            -ExpectedStatusCode @(200) `
            -AllowNotFound
        if ($null -ne $zone) {
            $properties = Get-ObjectPropertyValue -InputObject $zone -Name 'properties'
            $provisioningState = [string](Get-ObjectPropertyValue -InputObject $properties -Name 'provisioningState')
            if ($provisioningState -ieq 'Succeeded') {
                return
            }

            if ($provisioningState -iin @('Failed', 'Canceled')) {
                throw "Private DNS zone '$ZoneName' finished provisioning with state '$provisioningState'."
            }
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out after '$TimeoutSeconds' seconds waiting for Private DNS zone '$ZoneName' to finish provisioning."
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Resolve-DestinationPrivateDnsZones {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$InferredZones,

        [AllowEmptyCollection()]
        [object[]]$ExistingZones,

        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupLocation,

        [switch]$SkipCreate
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($inferredZone in @($InferredZones)) {
        $zoneName = [string]$inferredZone.ZoneName
        $matches = @($ExistingZones | Where-Object {
            $_.Name -ieq $zoneName -and
            ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or $_.ResourceGroupName -ieq $ResourceGroupName)
        })

        if ($matches.Count -gt 1) {
            $matchingResourceGroups = @($matches | ForEach-Object { [string]$_.ResourceGroupName } | Sort-Object -Unique) -join ', '
            throw "Destination subscription has multiple private DNS zones named '$zoneName' in resource groups '$matchingResourceGroups'. Specify DestinationPrivateDnsZoneResourceGroupName."
        }

        if ($matches.Count -eq 1) {
            $results.Add($matches[0])
            continue
        }

        if ($SkipCreate) {
            throw "Destination private DNS zone '$zoneName' was not found in subscription '$SubscriptionId'."
        }

        if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
            throw "Destination private DNS zone '$zoneName' does not exist. Supply DestinationPrivateDnsZoneResourceGroupName to allow the runbook to create it."
        }

        Confirm-ResourceGroupExists `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -Location $ResourceGroupLocation
        $zoneSegment = ConvertTo-ArmPathSegment -Value $zoneName
        $resourceGroupSegment = ConvertTo-ArmPathSegment -Value $ResourceGroupName
        $zoneId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/privateDnsZones/$zoneName"
        $zonePath = "/subscriptions/$SubscriptionId/resourceGroups/$resourceGroupSegment/providers/Microsoft.Network/privateDnsZones/${zoneSegment}?api-version=$PrivateDnsApiVersion"
        if ($ScriptCommand.ShouldProcess($zoneId, 'Create destination private DNS zone')) {
            Invoke-ArmJson `
                -Method PUT `
                -Path $zonePath `
                -Body @{ location = 'global'; properties = @{} } `
                -ExpectedStatusCode @(200, 201, 202) | Out-Null
            Wait-PrivateDnsZoneReady -Path $zonePath -ZoneName $zoneName
        }

        $results.Add([pscustomobject]@{
            Name              = $zoneName
            ResourceGroupName = $ResourceGroupName
            Id                = $zoneId
        })
    }

    return $results
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
        [string]$ZoneName,

        [Parameter(Mandatory = $true)]
        [string]$ZoneId,

        [string[]]$ExistingNames
    )

    $baseName = ($ZoneName.ToLowerInvariant() -replace '[^a-z0-9]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = 'private-dns-zone'
    }

    if ($baseName.Length -gt 80) {
        $baseName = $baseName.Substring(0, 80).Trim('-')
    }

    if (@($ExistingNames) -notcontains $baseName) {
        return $baseName
    }

    $suffix = New-ShortHash -Value $ZoneId
    $maximumBaseLength = 80 - $suffix.Length - 1
    if ($baseName.Length -gt $maximumBaseLength) {
        $baseName = $baseName.Substring(0, $maximumBaseLength).Trim('-')
    }

    return "$baseName-$suffix"
}

function Get-ZoneNameFromPrivateDnsZoneId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZoneId
    )

    if ($ZoneId -match '/privateDnsZones/([^/]+)$') {
        return [System.Uri]::UnescapeDataString($Matches[1]).ToLowerInvariant()
    }

    return $null
}

function Select-PrivateDnsZoneGroup {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Groups,

        [Parameter(Mandatory = $true)]
        [string]$RequestedName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$DestinationZones,

        [Parameter(Mandatory = $true)]
        [string]$PrivateEndpointName
    )

    $groups = @($Groups | Where-Object { $null -ne $_ })
    if ($groups.Count -eq 0) {
        return [pscustomobject]@{ Group = $null; Name = $RequestedName; SelectionReason = 'NoExistingGroup' }
    }

    $details = @($groups | ForEach-Object {
        [pscustomobject]@{
            Group   = $_
            Name    = [string](Get-PrivateDnsZoneGroupName -PrivateDnsZoneGroup $_)
            ZoneIds = @(Get-PrivateDnsZoneGroupZoneIds -PrivateDnsZoneGroup $_)
        }
    })
    if (@($details | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) }).Count -gt 0) {
        throw "Private endpoint '$PrivateEndpointName' returned a private DNS zone group without a usable name."
    }

    $requestedMatches = @($details | Where-Object { $_.Name -ieq $RequestedName })
    if ($requestedMatches.Count -eq 1) {
        return [pscustomobject]@{ Group = $requestedMatches[0].Group; Name = $requestedMatches[0].Name; SelectionReason = 'RequestedName' }
    }

    if ($groups.Count -eq 1) {
        return [pscustomobject]@{ Group = $details[0].Group; Name = $details[0].Name; SelectionReason = 'OnlyExistingGroup' }
    }

    $destinationZoneIds = @($DestinationZones | ForEach-Object { ([string]$_.Id).ToLowerInvariant() })
    $destinationZoneNames = @($DestinationZones | ForEach-Object { ([string]$_.Name).ToLowerInvariant() })
    $matchingGroups = @($details | Where-Object {
        $detailZoneIds = @($_.ZoneIds | ForEach-Object { $_.ToLowerInvariant() })
        $detailZoneNames = @($_.ZoneIds | ForEach-Object { Get-ZoneNameFromPrivateDnsZoneId -ZoneId $_ })
        @($detailZoneIds | Where-Object { $destinationZoneIds -contains $_ }).Count -gt 0 -or
        @($detailZoneNames | Where-Object { $destinationZoneNames -contains $_ }).Count -gt 0
    })
    if ($matchingGroups.Count -eq 1) {
        return [pscustomobject]@{ Group = $matchingGroups[0].Group; Name = $matchingGroups[0].Name; SelectionReason = 'UniqueZoneMatch' }
    }

    $descriptions = @($details | ForEach-Object { "$($_.Name) [$(@($_.ZoneIds) -join ', ')]" }) -join '; '
    throw "Private endpoint '$PrivateEndpointName' has '$($groups.Count)' private DNS zone groups and no unique safe selection. Existing groups: $descriptions."
}

function ConvertTo-ComparableZoneConfigs {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Configs
    )

    return @($Configs | ForEach-Object {
        $properties = Get-ObjectPropertyValue -InputObject $_ -Name 'properties'
        [pscustomobject]@{
            Name = ([string]$_.name).ToLowerInvariant()
            Id   = ([string](Get-ObjectPropertyValue -InputObject $properties -Name 'privateDnsZoneId')).ToLowerInvariant()
        }
    } | Sort-Object Name, Id)
}

function Test-ZoneConfigSetsEqual {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Left,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Right
    )

    $leftJson = ConvertTo-ComparableZoneConfigs -Configs $Left | ConvertTo-Json -Depth 5 -Compress
    $rightJson = ConvertTo-ComparableZoneConfigs -Configs $Right | ConvertTo-Json -Depth 5 -Compress
    return $leftJson -eq $rightJson
}

function Set-PrivateEndpointPrivateDnsZoneGroup {
    param(
        [Parameter(Mandatory = $true)]
        [object]$PrivateEndpoint,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$DestinationZones,

        [Parameter(Mandatory = $true)]
        [string]$RequestedGroupName,

        [switch]$RetriedAfterGroupConflict
    )

    $groupsPath = "$($PrivateEndpoint.id)/privateDnsZoneGroups?api-version=$NetworkApiVersion"
    $groups = @(Get-ArmPagedValues -Path $groupsPath)
    $selection = Select-PrivateDnsZoneGroup `
        -Groups $groups `
        -RequestedName $RequestedGroupName `
        -DestinationZones $DestinationZones `
        -PrivateEndpointName ([string]$PrivateEndpoint.name)
    $groupName = [string]$selection.Name
    $existingGroup = $selection.Group
    $existingConfigs = @()
    if ($existingGroup) {
        $existingGroupProperties = Get-ObjectPropertyValue -InputObject $existingGroup -Name 'properties'
        $existingConfigs = @((Get-ObjectPropertyValue -InputObject $existingGroupProperties -Name 'privateDnsZoneConfigs') | Where-Object { $null -ne $_ })
    }

    $destinationZoneLookup = @{}
    foreach ($destinationZone in @($DestinationZones)) {
        $destinationZoneLookup[([string]$destinationZone.Name).ToLowerInvariant()] = $destinationZone
    }

    $desiredConfigs = New-Object System.Collections.Generic.List[object]
    $usedConfigNames = New-Object System.Collections.Generic.List[string]
    $sameZoneConfigNames = @{}
    $movedZoneNames = New-Object System.Collections.Generic.List[string]
    foreach ($existingConfig in $existingConfigs) {
        $existingConfigName = [string]$existingConfig.name
        $existingConfigProperties = Get-ObjectPropertyValue -InputObject $existingConfig -Name 'properties'
        $existingZoneId = [string](Get-ObjectPropertyValue -InputObject $existingConfigProperties -Name 'privateDnsZoneId')
        $existingZoneName = Get-ZoneNameFromPrivateDnsZoneId -ZoneId $existingZoneId
        if (-not [string]::IsNullOrWhiteSpace($existingConfigName) -and -not $usedConfigNames.Contains($existingConfigName)) {
            $usedConfigNames.Add($existingConfigName)
        }

        if (-not [string]::IsNullOrWhiteSpace($existingZoneName) -and $destinationZoneLookup.ContainsKey($existingZoneName)) {
            $sameZoneConfigNames[$existingZoneName] = $existingConfigName
            $destinationZoneId = [string]$destinationZoneLookup[$existingZoneName].Id
            if ($existingZoneId -ine $destinationZoneId -and -not $movedZoneNames.Contains($existingZoneName)) {
                $movedZoneNames.Add($existingZoneName)
            }

            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($existingZoneId)) {
            $desiredConfigs.Add(@{
                name       = $existingConfigName
                properties = @{ privateDnsZoneId = $existingZoneId }
            })
        }
    }

    $configsAfterRemove = @($desiredConfigs.ToArray())

    foreach ($destinationZone in @($DestinationZones | Sort-Object Name)) {
        $zoneName = ([string]$destinationZone.Name).ToLowerInvariant()
        $zoneId = [string]$destinationZone.Id
        if ($sameZoneConfigNames.ContainsKey($zoneName) -and -not [string]::IsNullOrWhiteSpace([string]$sameZoneConfigNames[$zoneName])) {
            $configName = [string]$sameZoneConfigNames[$zoneName]
        }
        else {
            $configName = New-PrivateDnsZoneConfigName `
                -ZoneName $zoneName `
                -ZoneId $zoneId `
                -ExistingNames @($usedConfigNames.ToArray())
            if (-not $usedConfigNames.Contains($configName)) {
                $usedConfigNames.Add($configName)
            }
        }

        $desiredConfigs.Add(@{
            name       = $configName
            properties = @{ privateDnsZoneId = $zoneId }
        })
    }

    if ($desiredConfigs.Count -gt 5) {
        throw "The resulting private DNS zone group would contain '$($desiredConfigs.Count)' zones, but Azure supports at most five zones per group."
    }

    if ($existingGroup -and (Test-ZoneConfigSetsEqual -Left $existingConfigs -Right @($desiredConfigs.ToArray()))) {
        return [pscustomobject]@{
            GroupName       = $groupName
            SelectionReason = $selection.SelectionReason
            Operation       = 'ZoneGroupNoChange'
            Changed         = $false
            ZoneConfigCount = $desiredConfigs.Count
            MovedZoneNames  = ''
        }
    }

    $path = New-PrivateDnsZoneGroupPath -PrivateEndpointId ([string]$PrivateEndpoint.id) -ZoneGroupName $groupName
    $body = @{ properties = @{ privateDnsZoneConfigs = @($desiredConfigs.ToArray()) } }
    $target = "$($PrivateEndpoint.id)/privateDnsZoneGroups/$groupName"

    if ($movedZoneNames.Count -gt 0) {
        $zoneGroupMustBeRecreated = $configsAfterRemove.Count -eq 0
        $useSinglePutReplacement = $zoneGroupMustBeRecreated -and $groups.Count -gt 1

        if ($useSinglePutReplacement) {
            Write-TraceLog -Level WARN -Message "Private endpoint '$($PrivateEndpoint.name)' has multiple private DNS zone groups. Replacing the source zone configs in group '$groupName' with one non-empty PUT because deleting and recreating that group could be rejected as an additional group."
        }
        elseif ($zoneGroupMustBeRecreated) {
            if ($ScriptCommand.ShouldProcess($target, 'Delete private DNS zone group before replacing all same-name source zone configs')) {
                Invoke-ArmJson -Method DELETE -Path $path -ExpectedStatusCode @(200, 202, 204) | Out-Null
                Wait-PrivateDnsZoneGroupDeleted `
                    -Path $path `
                    -PrivateEndpointName ([string]$PrivateEndpoint.name) `
                    -ZoneGroupName $groupName
            }
        }
        elseif ($ScriptCommand.ShouldProcess($target, 'Remove same-name source private DNS zone configs before adding destination configs')) {
            $removeBody = @{ properties = @{ privateDnsZoneConfigs = $configsAfterRemove } }
            Invoke-ArmJson -Method PUT -Path $path -Body $removeBody -ExpectedStatusCode @(200, 201) | Out-Null
        }

        $operation = if ($useSinglePutReplacement) {
            'ZoneGroupSinglePutMoveToDestination'
        }
        elseif ($zoneGroupMustBeRecreated) {
            'ZoneGroupDeleteCreateMoveToDestination'
        }
        else {
            'ZoneGroupTwoPutMoveToDestination'
        }
    }
    elseif ($existingGroup) {
        $operation = 'ZoneGroupAddConfig'
    }
    else {
        $operation = 'ZoneGroupCreate'
    }

    if ($ScriptCommand.ShouldProcess($target, "${operation}: link inferred destination private DNS zones")) {
        try {
            Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201) | Out-Null
        }
        catch {
            if (-not $RetriedAfterGroupConflict -and $_.Exception.Message -match 'MoreThanOnePrivateDnsZoneGroupPerPrivateEndpointNotAllowed') {
                Write-TraceLog -Level WARN -Message "Private DNS zone group PUT for endpoint '$($PrivateEndpoint.name)' encountered a concurrent group conflict. Refreshing existing groups and retrying once."
                return Set-PrivateEndpointPrivateDnsZoneGroup `
                    -PrivateEndpoint $PrivateEndpoint `
                    -DestinationZones $DestinationZones `
                    -RequestedGroupName $RequestedGroupName `
                    -RetriedAfterGroupConflict
            }

            throw
        }
    }

    return [pscustomobject]@{
        GroupName       = $groupName
        SelectionReason = $selection.SelectionReason
        Operation       = $operation
        Changed         = $true
        ZoneConfigCount = $desiredConfigs.Count
        MovedZoneNames  = (@($movedZoneNames.ToArray()) -join ',')
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

if ($IsAzureAutomationRunbook -and [string]::IsNullOrWhiteSpace($DestinationSubscriptionId)) {
    $DestinationSubscriptionId = Get-FirstAutomationVariableString -Names @(
        $DestinationSubscriptionIdAutomationVariableName
        $SharedDestinationSubscriptionIdAutomationVariableName
    )
}

if ([string]::IsNullOrWhiteSpace($DestinationSubscriptionId)) {
    throw "DestinationSubscriptionId is required. Supply -DestinationSubscriptionId or create Automation variable '$DestinationSubscriptionIdAutomationVariableName' or '$SharedDestinationSubscriptionIdAutomationVariableName'."
}

if ($IsAzureAutomationRunbook -and [string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) {
    $DestinationPrivateDnsZoneResourceGroupName = Get-AutomationVariableString -Name $DestinationZoneResourceGroupAutomationVariableName
}

if ($IsAzureAutomationRunbook -and [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId)) {
    $ManagedIdentityAccountId = Get-FirstAutomationVariableString -Names @(
        $ManagedIdentityAccountIdAutomationVariableName
        $SharedManagedIdentityAccountIdAutomationVariableName
    )
}

$automationTenantId = $null
if ($IsAzureAutomationRunbook -and
    ([string]::IsNullOrWhiteSpace($SourceTenantId) -or [string]::IsNullOrWhiteSpace($DestinationTenantId))) {
    $automationTenantId = Get-FirstAutomationVariableString -Names @(
        $TenantIdAutomationVariableName
        $SharedTenantIdAutomationVariableName
    )
}

if ([string]::IsNullOrWhiteSpace($SourceTenantId)) {
    $SourceTenantId = if (-not [string]::IsNullOrWhiteSpace($DestinationTenantId)) {
        $DestinationTenantId
    }
    else {
        $automationTenantId
    }
}

if ([string]::IsNullOrWhiteSpace($DestinationTenantId)) {
    $DestinationTenantId = if (-not [string]::IsNullOrWhiteSpace($SourceTenantId)) {
        $SourceTenantId
    }
    else {
        $automationTenantId
    }
}

$PrivateEndpointResourceId = $PrivateEndpointResourceId.Trim().TrimEnd('/')
$privateEndpointResourceIdPattern = '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/([^/]+)/providers/Microsoft\.Network/privateEndpoints/([^/]+)$'
if ($PrivateEndpointResourceId -notmatch $privateEndpointResourceIdPattern) {
    throw "PrivateEndpointResourceId must be a full Microsoft.Network/privateEndpoints resource ID. Value='$PrivateEndpointResourceId'."
}

$SourceSubscriptionId = [string]$Matches[1]
$parsedSourceSubscriptionId = [guid]::Empty
$parsedDestinationSubscriptionId = [guid]::Empty
if (-not [guid]::TryParse($SourceSubscriptionId, [ref]$parsedSourceSubscriptionId)) {
    throw "PrivateEndpointResourceId contains an invalid subscription ID '$SourceSubscriptionId'."
}

if (-not [guid]::TryParse($DestinationSubscriptionId, [ref]$parsedDestinationSubscriptionId)) {
    throw "DestinationSubscriptionId '$DestinationSubscriptionId' is not a valid GUID."
}

$UseManagedIdentityLogin = [bool]($UseManagedIdentity -or $IsAzureAutomationRunbook -or -not [string]::IsNullOrWhiteSpace($ManagedIdentityAccountId))
$authenticationMode = if (-not $UseManagedIdentityLogin) {
    'CurrentUser'
}
elseif ([string]::IsNullOrWhiteSpace($ManagedIdentityAccountId)) {
    'SystemAssignedManagedIdentity'
}
else {
    "UserAssignedManagedIdentity:$ManagedIdentityAccountId"
}
Write-TraceLog -Message "Starting Link-PrivateEndpointPrivateDns.ps1. PrivateEndpointResourceId='$PrivateEndpointResourceId'; DestinationSubscriptionId='$DestinationSubscriptionId'; DestinationPrivateDnsZoneResourceGroupName='$DestinationPrivateDnsZoneResourceGroupName'; SourceTenantId='$SourceTenantId'; DestinationTenantId='$DestinationTenantId'; WhatIf='$WhatIfPreference'; AuthenticationMode='$authenticationMode'."

Write-TraceLog -Message "Selecting private endpoint subscription '$SourceSubscriptionId'."
$sourceContext = Select-AzureChinaSubscription `
    -SubscriptionId $SourceSubscriptionId `
    -TenantId $SourceTenantId `
    -UseManagedIdentityLogin $UseManagedIdentityLogin `
    -IdentityAccountId $ManagedIdentityAccountId
$effectiveSourceTenantId = [string]$sourceContext.Tenant.Id

$privateEndpoint = Invoke-ArmJson `
    -Method GET `
    -Path "${PrivateEndpointResourceId}?api-version=$NetworkApiVersion" `
    -ExpectedStatusCode @(200) `
    -AllowNotFound
if ($null -eq $privateEndpoint) {
    throw "Private endpoint '$PrivateEndpointResourceId' was not found or is not visible to the current identity."
}

$dnsDetails = Get-PrivateEndpointDnsDetails -PrivateEndpoint $privateEndpoint
if (@($dnsDetails.PrivateIpAddresses).Count -eq 0) {
    throw "Private endpoint '$PrivateEndpointResourceId' has no private IP address. Confirm that provisioning and connection approval completed."
}

foreach ($privateIpAddress in @($dnsDetails.PrivateIpAddresses)) {
    Assert-IPv4Address -Value $privateIpAddress
}

$connections = @(Get-PrivateEndpointConnectionDetails -PrivateEndpoint $privateEndpoint)
if (Test-PrivateEndpointIsPostgreSql -Connections $connections) {
    throw "Private endpoint '$PrivateEndpointResourceId' targets PostgreSQL, which is intentionally excluded from this automation."
}

$connectionDescriptions = @($connections | ForEach-Object {
    "$($_.ResourceType)|$($_.GroupId)|$($_.PrivateLinkServiceId)|$($_.ConnectionStatus)"
} | Sort-Object -Unique)
Write-TraceLog -Message "Endpoint discovered. Name='$($dnsDetails.Name)'; private IP(s)='$(@($dnsDetails.PrivateIpAddresses) -join ',')'; FQDN(s)='$(@($dnsDetails.Fqdns) -join ',')'; connection(s)='$($connectionDescriptions -join '; ')'."

$existingZoneGroups = @(Get-ArmPagedValues -Path "$PrivateEndpointResourceId/privateDnsZoneGroups?api-version=$NetworkApiVersion")
$inferredZones = @(Get-InferredPrivateDnsZones `
    -DnsDetails $dnsDetails `
    -Connections $connections `
    -ExistingZoneGroups $existingZoneGroups)
if ($inferredZones.Count -eq 0) {
    $resourceTypes = @($connections.ResourceType | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ', '
    $groupIds = @($connections.GroupId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ', '
    throw "Could not infer a supported Azure China private DNS zone. Resource type(s)='$resourceTypes'; group ID(s)='$groupIds'; FQDN(s)='$(@($dnsDetails.Fqdns) -join ', ')'."
}

foreach ($inferredZone in $inferredZones) {
    Write-TraceLog -Message "Inferred private DNS zone '$($inferredZone.ZoneName)' from '$(@($inferredZone.Sources) -join '; ')'."
}

Write-TraceLog -Message "Selecting destination subscription '$DestinationSubscriptionId'."
$destinationContext = Select-AzureChinaSubscription `
    -SubscriptionId $DestinationSubscriptionId `
    -TenantId $DestinationTenantId `
    -UseManagedIdentityLogin $UseManagedIdentityLogin `
    -IdentityAccountId $ManagedIdentityAccountId
$effectiveDestinationTenantId = [string]$destinationContext.Tenant.Id
if ($effectiveSourceTenantId -ine $effectiveDestinationTenantId) {
    throw "Private DNS zone groups cannot reference zones across Microsoft Entra tenants. Source tenant='$effectiveSourceTenantId'; destination tenant='$effectiveDestinationTenantId'."
}

$existingDestinationZones = @(Get-PrivateDnsZonesInScope `
    -SubscriptionId $DestinationSubscriptionId `
    -ResourceGroupName $DestinationPrivateDnsZoneResourceGroupName)
$destinationSearchScope = if ([string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) {
    "subscription '$DestinationSubscriptionId'"
}
else {
    "resource group '$DestinationPrivateDnsZoneResourceGroupName' in subscription '$DestinationSubscriptionId'"
}
Write-TraceLog -Message "Searching '$($existingDestinationZones.Count)' destination Private DNS zone(s) in $destinationSearchScope for exact inferred zone-name matches."
$destinationZones = @(Resolve-DestinationPrivateDnsZones `
    -SubscriptionId $DestinationSubscriptionId `
    -InferredZones $inferredZones `
    -ExistingZones $existingDestinationZones `
    -ResourceGroupName $DestinationPrivateDnsZoneResourceGroupName `
    -ResourceGroupLocation $DestinationResourceGroupLocation `
    -SkipCreate:$SkipCreateMissingDestinationZones)

Select-AzureChinaSubscription `
    -SubscriptionId $SourceSubscriptionId `
    -TenantId $SourceTenantId `
    -UseManagedIdentityLogin $UseManagedIdentityLogin `
    -IdentityAccountId $ManagedIdentityAccountId | Out-Null
$zoneGroupResult = Set-PrivateEndpointPrivateDnsZoneGroup `
    -PrivateEndpoint $privateEndpoint `
    -DestinationZones $destinationZones `
    -RequestedGroupName $PrivateDnsZoneGroupName

$associatedResourceIds = @($connections.PrivateLinkServiceId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
$associatedResourceTypes = @($connections.ResourceType | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
$groupIds = @($connections.GroupId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
$connectionStatuses = @($connections.ConnectionStatus | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
$results = foreach ($inferredZone in $inferredZones) {
    $destinationZone = @($destinationZones | Where-Object { $_.Name -ieq $inferredZone.ZoneName })[0]
    [pscustomobject]@{
        PrivateEndpointName                = $dnsDetails.Name
        PrivateEndpointId                  = $dnsDetails.Id
        PrivateIpAddresses                 = (@($dnsDetails.PrivateIpAddresses) -join ',')
        Fqdns                              = (@($dnsDetails.Fqdns) -join ',')
        AssociatedResourceIds              = ($associatedResourceIds -join ',')
        AssociatedResourceTypes            = ($associatedResourceTypes -join ',')
        GroupIds                           = ($groupIds -join ',')
        ConnectionStatuses                 = ($connectionStatuses -join ',')
        ZoneName                           = $inferredZone.ZoneName
        ZoneInferenceSources               = (@($inferredZone.Sources) -join ';')
        DestinationZoneResourceGroupName   = $destinationZone.ResourceGroupName
        DestinationPrivateDnsZoneId        = $destinationZone.Id
        PrivateDnsZoneGroupName            = $zoneGroupResult.GroupName
        PrivateDnsZoneGroupSelectionReason = $zoneGroupResult.SelectionReason
        Operation                          = $zoneGroupResult.Operation
        Changed                            = [bool]$zoneGroupResult.Changed
        WhatIf                             = [bool]$WhatIfPreference
    }
}

$duration = (Get-Date) - $RunStartedAt
Write-TraceLog -Message "Completed Link-PrivateEndpointPrivateDns.ps1. InferredZones='$($inferredZones.Count)'; Operation='$($zoneGroupResult.Operation)'; Changed='$($zoneGroupResult.Changed)'; Duration='$('{0:hh\:mm\:ss\.fff}' -f $duration)'."
$results | Sort-Object ZoneName
