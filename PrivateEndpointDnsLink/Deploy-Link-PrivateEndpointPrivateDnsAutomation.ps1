<#
.SYNOPSIS
Deploys only Link-PrivateEndpointPrivateDns.ps1 to Azure Automation in Azure China.

.DESCRIPTION
Creates or updates an Azure Automation Account with a system-assigned managed
identity, optionally starts Az.Accounts and Az.Resources module imports, imports
and publishes only the Link-PrivateEndpointPrivateDns runbook, enables verbose
logging, and saves its dedicated destination settings as Automation variables.

The source, destination, and Automation subscriptions must belong to the same
Microsoft Entra tenant. DestinationPrivateDnsZoneResourceGroupName is optional.
When omitted, the runbook scans the destination subscription for one exact zone
name match. Unless SkipRoleAssignments is supplied, the Automation Account
identity receives Reader and Network Contributor on the source subscription and
Private DNS Zone Contributor on the destination resource group when specified,
or on the destination subscription when scanning all resource groups.

.EXAMPLE
    .\Deploy-Link-PrivateEndpointPrivateDnsAutomation.ps1 `
        -AutomationSubscriptionId '11111111-1111-1111-1111-111111111111' `
        -AutomationResourceGroupName 'rg-private-endpoint-dns-link' `
        -AutomationAccountName 'aa-private-endpoint-dns-link' `
        -SourceSubscriptionId '22222222-2222-2222-2222-222222222222' `
        -DestinationSubscriptionId '33333333-3333-3333-3333-333333333333'

    Deploy the dedicated runbook, enable subscription-wide destination zone lookup,
    and assign its recommended roles.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AutomationSubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AutomationResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationSubscriptionId,

    [string]$DestinationPrivateDnsZoneResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [ValidateNotNullOrEmpty()]
    [string]$Location = 'chinaeast2',

    [ValidateNotNullOrEmpty()]
    [string]$RunbookName = 'Link-PrivateEndpointPrivateDns',

    [ValidateNotNullOrEmpty()]
    [string]$RunbookPath = (Join-Path $PSScriptRoot 'Link-PrivateEndpointPrivateDns.ps1'),

    [ValidateSet('PowerShell', 'PowerShell72')]
    [string]$RunbookType = 'PowerShell',

    [switch]$SkipModuleImport,

    [switch]$SkipRunbookPublish,

    [switch]$SkipRoleAssignments
)

#requires -Modules Az.Accounts, Az.Resources, Az.Automation

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AutomationApiVersion = '2023-11-01'
$DestinationSubscriptionVariableName = 'LinkPrivateEndpointPrivateDnsDestinationSubscriptionId'
$DestinationZoneResourceGroupVariableName = 'LinkPrivateEndpointPrivateDnsDestinationZoneResourceGroupName'
$RequiredAutomationModules = @('Az.Accounts', 'Az.Resources')

function Import-RequiredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required local module '$Name' is not installed. Install it for the current user before running this deployment."
    }

    Import-Module -Name $Name -ErrorAction Stop
}

function Select-AzureChinaSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [string]$ExpectedTenantId
    )

    $connectParameters = @{
        Environment = 'AzureChinaCloud'
        ErrorAction = 'Stop'
    }
    $contextParameters = @{
        SubscriptionId = $SubscriptionId
        ErrorAction    = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedTenantId)) {
        $connectParameters['Tenant'] = $ExpectedTenantId
        $contextParameters['Tenant'] = $ExpectedTenantId
    }

    $currentContext = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $currentContext -or $currentContext.Environment.Name -ne 'AzureChinaCloud') {
        Connect-AzAccount @connectParameters | Out-Null
    }

    try {
        Set-AzContext @contextParameters | Out-Null
    }
    catch {
        Connect-AzAccount @connectParameters | Out-Null
        Set-AzContext @contextParameters | Out-Null
    }

    $selectedContext = Get-AzContext -ErrorAction Stop
    if ($selectedContext.Environment.Name -ne 'AzureChinaCloud') {
        throw "Subscription '$SubscriptionId' was not selected in AzureChinaCloud."
    }

    return $selectedContext
}

function Assert-SubscriptionTenant {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName,

        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedTenantId
    )

    $actualTenantId = [string]$Context.Tenant.Id
    if ($actualTenantId -ine $ExpectedTenantId) {
        throw "$SubscriptionName subscription tenant '$actualTenantId' does not match required tenant '$ExpectedTenantId'. All three subscriptions must be in the same Microsoft Entra tenant for the Automation Account system-assigned identity to be authorized."
    }
}

function ConvertTo-ArmPathSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [System.Uri]::EscapeDataString($Value)
}

function Invoke-ArmJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [object]$Body,

        [int[]]$ExpectedStatusCode = @(200),

        [switch]$AllowNotFound
    )

    $parameters = @{
        Method      = $Method
        Path        = $Path
        ErrorAction = 'Stop'
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
        throw "ARM $Method failed for '$Path'. Status='$statusCode'. Response='$($response.Content)'."
    }

    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

function New-AutomationAccountPath {
    $resourceGroupSegment = ConvertTo-ArmPathSegment -Value $AutomationResourceGroupName
    $accountSegment = ConvertTo-ArmPathSegment -Value $AutomationAccountName
    return "/subscriptions/$AutomationSubscriptionId/resourceGroups/$resourceGroupSegment/providers/Microsoft.Automation/automationAccounts/${accountSegment}?api-version=$AutomationApiVersion"
}

function Confirm-AutomationResourceGroup {
    $existingResourceGroup = Get-AzResourceGroup `
        -Name $AutomationResourceGroupName `
        -ErrorAction SilentlyContinue
    if ($existingResourceGroup) {
        return $true
    }

    if ($PSCmdlet.ShouldProcess("$AutomationSubscriptionId/$AutomationResourceGroupName", 'Create Automation resource group')) {
        New-AzResourceGroup `
            -Name $AutomationResourceGroupName `
            -Location $Location `
            -Force | Out-Null
        return $true
    }

    return $false
}

function Assert-DestinationResourceGroupExists {
    if ([string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) {
        return
    }

    $resourceGroup = Get-AzResourceGroup `
        -Name $DestinationPrivateDnsZoneResourceGroupName `
        -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        throw "Destination private DNS resource group '$DestinationPrivateDnsZoneResourceGroupName' does not exist in subscription '$DestinationSubscriptionId'. Create it before running this deployment."
    }
}

function Set-AutomationAccountSystemIdentity {
    $path = New-AutomationAccountPath
    $existingAccount = Invoke-ArmJson `
        -Method GET `
        -Path $path `
        -ExpectedStatusCode @(200) `
        -AllowNotFound

    $accountLocation = $Location
    if ($existingAccount) {
        $accountLocation = [string]$existingAccount.location
        if ([string]::IsNullOrWhiteSpace($accountLocation)) {
            $accountLocation = $Location
        }
    }

    $identity = @{ type = 'SystemAssigned' }
    if ($existingAccount -and $existingAccount.identity -and $existingAccount.identity.userAssignedIdentities) {
        $userAssignedIdentities = @{}
        foreach ($property in $existingAccount.identity.userAssignedIdentities.PSObject.Properties) {
            $userAssignedIdentities[$property.Name] = @{}
        }

        if ($userAssignedIdentities.Count -gt 0) {
            $identity = @{
                type                   = 'SystemAssigned, UserAssigned'
                userAssignedIdentities = $userAssignedIdentities
            }
        }
    }

    $body = @{
        location   = $accountLocation
        identity   = $identity
        properties = @{
            sku = @{ name = 'Basic' }
        }
    }
    if ($existingAccount -and $existingAccount.tags) {
        $tags = @{}
        foreach ($property in $existingAccount.tags.PSObject.Properties) {
            $tags[$property.Name] = [string]$property.Value
        }
        $body['tags'] = $tags
    }

    $target = "$AutomationSubscriptionId/$AutomationResourceGroupName/$AutomationAccountName"
    if ($PSCmdlet.ShouldProcess($target, 'Create or update Automation Account with system-assigned managed identity')) {
        return Invoke-ArmJson `
            -Method PUT `
            -Path $path `
            -Body $body `
            -ExpectedStatusCode @(200, 201)
    }

    return $existingAccount
}

function Get-AutomationAccountWithPrincipal {
    $path = New-AutomationAccountPath
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $account = Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200)
        $principalId = [string]$account.identity.principalId
        if (-not [string]::IsNullOrWhiteSpace($principalId)) {
            return $account
        }

        Start-Sleep -Seconds 5
    }

    throw "The system-assigned principal ID for Automation Account '$AutomationAccountName' was not available after 90 seconds. Wait for identity provisioning to finish and rerun the deployment."
}

function Confirm-AutomationModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $existingModule = Get-AzAutomationModule `
        -ResourceGroupName $AutomationResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -ErrorAction SilentlyContinue
    if ($existingModule -and [string]$existingModule.ProvisioningState -ieq 'Succeeded') {
        Write-Host "Automation module '$Name' is already available."
        return
    }

    if ($existingModule) {
        Write-Host "Automation module '$Name' already has provisioning state '$($existingModule.ProvisioningState)'."
        return
    }

    $contentLinkUri = "https://www.powershellgallery.com/api/v2/package/$Name"
    if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Start Automation module import from PowerShell Gallery')) {
        New-AzAutomationModule `
            -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -ContentLinkUri $contentLinkUri | Out-Null
    }
}

function Import-DedicatedRunbook {
    if (-not (Test-Path -LiteralPath $RunbookPath -PathType Leaf)) {
        throw "Dedicated runbook file '$RunbookPath' was not found. Keep the deployer and runbook together or supply -RunbookPath."
    }

    if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$RunbookName", 'Import dedicated Automation runbook')) {
        Import-AzAutomationRunbook `
            -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $RunbookName `
            -Path $RunbookPath `
            -Type $RunbookType `
            -Force | Out-Null
    }

    if (-not $SkipRunbookPublish -and
        $PSCmdlet.ShouldProcess("$AutomationAccountName/$RunbookName", 'Publish dedicated Automation runbook')) {
        Publish-AzAutomationRunbook `
            -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $RunbookName | Out-Null
    }

    if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$RunbookName", 'Enable verbose runbook logging')) {
        Set-AzAutomationRunbook `
            -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $RunbookName `
            -LogVerbose $true | Out-Null
    }
}

function Set-AutomationPlainVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $existingVariable = Get-AzAutomationVariable `
        -ResourceGroupName $AutomationResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -ErrorAction SilentlyContinue

    if (-not $PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Create or update dedicated Automation variable')) {
        return
    }

    if ($existingVariable) {
        Set-AzAutomationVariable `
            -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -Encrypted $false `
            -Value $Value | Out-Null
    }
    else {
        New-AzAutomationVariable `
            -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -Encrypted $false `
            -Value $Value | Out-Null
    }
}

function Remove-AutomationPlainVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $existingVariable = Get-AzAutomationVariable `
        -ResourceGroupName $AutomationResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -ErrorAction SilentlyContinue
    if ($existingVariable -and
        $PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Remove unused Automation variable')) {
        Remove-AzAutomationVariable `
            -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -Force | Out-Null
    }
}

function Confirm-RoleAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectId,

        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$RoleDefinitionName
    )

    $existingAssignments = @(Get-AzRoleAssignment `
            -ObjectId $ObjectId `
            -Scope $Scope `
            -ErrorAction SilentlyContinue | Where-Object {
                $_.RoleDefinitionName -eq $RoleDefinitionName -and $_.Scope -ieq $Scope
            })
    if ($existingAssignments.Count -gt 0) {
        Write-Host "Role '$RoleDefinitionName' is already assigned at '$Scope'."
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$ObjectId -> $Scope", "Assign role '$RoleDefinitionName'")) {
        return
    }

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            New-AzRoleAssignment `
                -ObjectId $ObjectId `
                -RoleDefinitionName $RoleDefinitionName `
                -Scope $Scope `
                -ErrorAction Stop | Out-Null
            return
        }
        catch {
            if ($attempt -eq 12 -or $_.Exception.Message -notmatch 'PrincipalNotFound|does not exist in the directory') {
                throw
            }

            Start-Sleep -Seconds 5
        }
    }
}

foreach ($moduleName in @('Az.Accounts', 'Az.Resources', 'Az.Automation')) {
    Import-RequiredModule -Name $moduleName
}

$resolvedRunbookPath = $RunbookPath
if (Test-Path -LiteralPath $RunbookPath -PathType Leaf) {
    $resolvedRunbookPath = (Resolve-Path -LiteralPath $RunbookPath).ProviderPath
}

$destinationContext = Select-AzureChinaSubscription `
    -SubscriptionId $DestinationSubscriptionId `
    -ExpectedTenantId $TenantId
Assert-DestinationResourceGroupExists

$sourceContext = Select-AzureChinaSubscription `
    -SubscriptionId $SourceSubscriptionId `
    -ExpectedTenantId $TenantId
$effectiveTenantId = [string]$sourceContext.Tenant.Id
Assert-SubscriptionTenant `
    -SubscriptionName 'Destination' `
    -Context $destinationContext `
    -ExpectedTenantId $effectiveTenantId

$automationContext = Select-AzureChinaSubscription `
    -SubscriptionId $AutomationSubscriptionId `
    -ExpectedTenantId $TenantId
Assert-SubscriptionTenant `
    -SubscriptionName 'Automation' `
    -Context $automationContext `
    -ExpectedTenantId $effectiveTenantId

$automationResourceGroupReady = Confirm-AutomationResourceGroup
$account = Set-AutomationAccountSystemIdentity
if (-not $account) {
    Write-Warning 'WhatIf did not create the missing Automation Account. Dependent imports, variables, and role assignments were not evaluated.'
    [pscustomobject]@{
        AutomationSubscriptionId                         = $AutomationSubscriptionId
        AutomationResourceGroupName                      = $AutomationResourceGroupName
        AutomationAccountName                            = $AutomationAccountName
        TenantId                                         = $effectiveTenantId
        ManagedIdentityType                              = 'SystemAssigned'
        ManagedIdentityObjectId                          = $null
        RunbookName                                      = $RunbookName
        RunbookPath                                      = $resolvedRunbookPath
        DestinationSubscriptionVariableName             = $DestinationSubscriptionVariableName
        DestinationZoneResourceGroupVariableName        = $DestinationZoneResourceGroupVariableName
        DestinationZoneSearchScope                      = if ([string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) { 'Subscription' } else { 'ResourceGroup' }
        AutomationResourceGroupReady                     = $automationResourceGroupReady
        ModuleImportStarted                              = $false
        RunbookPublished                                 = $false
        RoleAssignmentsConfigured                        = $false
        WhatIf                                           = [bool]$WhatIfPreference
    }
    return
}

$account = Get-AutomationAccountWithPrincipal
$principalId = [string]$account.identity.principalId

if (-not $SkipModuleImport) {
    foreach ($moduleName in $RequiredAutomationModules) {
        Confirm-AutomationModule -Name $moduleName
    }
}

Import-DedicatedRunbook
Set-AutomationPlainVariable `
    -Name $DestinationSubscriptionVariableName `
    -Value $DestinationSubscriptionId
if ([string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) {
    Remove-AutomationPlainVariable -Name $DestinationZoneResourceGroupVariableName
}
else {
    Set-AutomationPlainVariable `
        -Name $DestinationZoneResourceGroupVariableName `
        -Value $DestinationPrivateDnsZoneResourceGroupName
}

if (-not $SkipRoleAssignments) {
    $sourceScope = "/subscriptions/$SourceSubscriptionId"
    Select-AzureChinaSubscription `
        -SubscriptionId $SourceSubscriptionId `
        -ExpectedTenantId $effectiveTenantId | Out-Null
    Confirm-RoleAssignment `
        -ObjectId $principalId `
        -Scope $sourceScope `
        -RoleDefinitionName 'Reader'
    Confirm-RoleAssignment `
        -ObjectId $principalId `
        -Scope $sourceScope `
        -RoleDefinitionName 'Network Contributor'

    $destinationScope = if ([string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) {
        "/subscriptions/$DestinationSubscriptionId"
    }
    else {
        "/subscriptions/$DestinationSubscriptionId/resourceGroups/$DestinationPrivateDnsZoneResourceGroupName"
    }
    Select-AzureChinaSubscription `
        -SubscriptionId $DestinationSubscriptionId `
        -ExpectedTenantId $effectiveTenantId | Out-Null
    Confirm-RoleAssignment `
        -ObjectId $principalId `
        -Scope $destinationScope `
        -RoleDefinitionName 'Private DNS Zone Contributor'
}

[pscustomobject]@{
    AutomationSubscriptionId                         = $AutomationSubscriptionId
    AutomationResourceGroupName                      = $AutomationResourceGroupName
    AutomationAccountName                            = $AutomationAccountName
    TenantId                                         = $effectiveTenantId
    ManagedIdentityType                              = 'SystemAssigned'
    ManagedIdentityObjectId                          = $principalId
    RunbookName                                      = $RunbookName
    RunbookPath                                      = $resolvedRunbookPath
    DestinationSubscriptionVariableName             = $DestinationSubscriptionVariableName
    DestinationZoneResourceGroupVariableName        = $DestinationZoneResourceGroupVariableName
    DestinationZoneSearchScope                      = if ([string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) { 'Subscription' } else { 'ResourceGroup' }
    AutomationResourceGroupReady                     = $automationResourceGroupReady
    ModuleImportStarted                              = -not $SkipModuleImport
    RunbookPublished                                 = -not $SkipRunbookPublish
    RoleAssignmentsConfigured                        = -not $SkipRoleAssignments
    WhatIf                                           = [bool]$WhatIfPreference
}
