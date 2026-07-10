<#
.SYNOPSIS
Deploys the private endpoint private DNS sync and AKS DNS repair scripts as Azure Automation runbooks.

.DESCRIPTION
Creates or updates an Azure China Automation Account with a user-assigned
managed identity by default, imports Sync-PrivateEndpointPrivateDns.ps1 and
Repair-AksPrivateDnsLinks.ps1 as PowerShell runbooks, publishes them, and can
optionally assign recommended RBAC permissions to the Automation Account managed
identity.

The deployment saves source subscription, destination subscription, and managed
identity client ID defaults as Automation variables so the runbook can start
without parameters. DestinationSubscriptionId defaults to
65a9c0da-4f85-47ba-ac0f-7401cbe43205, the same destination subscription used by
the sync runbook and AKS private DNS repair script. The AKS repair target VNet
can be overridden with AksTargetVirtualNetworkResourceId. If the Automation
Account modules are not already present, this script can start imports for
Az.Accounts and Az.Resources from PowerShell Gallery.

.EXAMPLE
    .\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
        -SubscriptionId "11111111-1111-1111-1111-111111111111" `
        -ResourceGroupName "rg-dns-sync-automation" `
        -AutomationAccountName "aa-dns-sync-cn-prod" `
        -Location "chinaeast2" `
        -SourceSubscriptionId "22222222-2222-2222-2222-222222222222"

    Create or update the Automation Account, publish the runbook, and save the
    runbook default source subscription and default destination subscription.

.EXAMPLE
    .\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
        -SubscriptionId "11111111-1111-1111-1111-111111111111" `
        -ResourceGroupName "rg-dns-sync-automation" `
        -AutomationAccountName "aa-dns-sync-cn-prod" `
        -Location "chinaeast2" `
        -AssignRecommendedRoles `
        -SourceSubscriptionId "22222222-2222-2222-2222-222222222222" `
        -GrantSourceNetworkContributor `
        -GrantDestinationContributor

Deploy the runbook and assign Reader plus Network Contributor on the source
    subscription, Private DNS Zone Contributor on the destination subscription, and
    Contributor on the destination subscription so the runbook can create missing
    destination resource groups when needed.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [string]$ResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$Location = 'chinaeast2',

    [string]$AutomationAccountName,

    [ValidateSet('UserAssigned', 'SystemAssigned')]
    [string]$ManagedIdentityType = 'UserAssigned',

    [ValidateNotNullOrEmpty()]
    [string]$UserAssignedManagedIdentityName,

    [ValidateNotNullOrEmpty()]
    [string]$UserAssignedManagedIdentityResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$UserAssignedManagedIdentityResourceId,

    [ValidateNotNullOrEmpty()]
    [string]$RunbookName = 'Sync-PrivateEndpointPrivateDns',

    [ValidateNotNullOrEmpty()]
    [string]$RunbookPath = (Join-Path $PSScriptRoot 'Sync-PrivateEndpointPrivateDns.ps1'),

    [ValidateNotNullOrEmpty()]
    [string]$AksRepairRunbookName = 'Repair-AksPrivateDnsLinks',

    [ValidateNotNullOrEmpty()]
    [string]$AksRepairRunbookPath = (Join-Path $PSScriptRoot 'Repair-AksPrivateDnsLinks.ps1'),

    [ValidateNotNullOrEmpty()]
    [string]$AksTargetVirtualNetworkResourceId = '/subscriptions/65a9c0da-4f85-47ba-ac0f-7401cbe43205/resourceGroups/RGP-P0001-CN-AZ-FCS-0005/providers/Microsoft.Network/virtualNetworks/vNet-P0001-CN-AZ-FCS-0005',

    [ValidateSet('PowerShell', 'PowerShell72')]
    [string]$RunbookType = 'PowerShell',

    [switch]$SkipModuleImport,

    [switch]$SkipRunbookPublish,

    [switch]$AssignRecommendedRoles,

    [ValidateNotNullOrEmpty()]
    [string]$SourceSubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$DestinationSubscriptionId = '65a9c0da-4f85-47ba-ac0f-7401cbe43205',

    [ValidateNotNullOrEmpty()]
    [string]$DestinationPrivateDnsZoneResourceGroupName,

    [switch]$GrantSourceNetworkContributor,

    [switch]$GrantDestinationContributor
)

#requires -Modules Az.Accounts, Az.Resources, Az.Automation

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AutomationApiVersion = '2023-11-01'
$ManagedIdentityApiVersion = '2023-01-31'
$DefaultSourceSubscriptionIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsSourceSubscriptionId'
$DefaultDestinationSubscriptionIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsDestinationSubscriptionId'
$DefaultManagedIdentityAccountIdAutomationVariableName = 'SyncPrivateEndpointPrivateDnsManagedIdentityAccountId'
$DefaultAksTargetVirtualNetworkResourceIdAutomationVariableName = 'RepairAksPrivateDnsLinksTargetVirtualNetworkResourceId'
$DefaultDestinationSubscriptionId = '65a9c0da-4f85-47ba-ac0f-7401cbe43205'
$RequiredAutomationModules = @('Az.Accounts', 'Az.Resources')

function Import-RequiredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "$Name is required. Install it with: Install-Module $Name -Scope CurrentUser"
    }

    Import-Module $Name -ErrorAction Stop
}

function Select-AzureChinaSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [string]$TargetTenantId
    )

    $connectParameters = @{
        Environment = 'AzureChinaCloud'
        ErrorAction = 'Stop'
    }
    $contextParameters = @{
        SubscriptionId = $TargetSubscriptionId
        ErrorAction    = 'Stop'
    }

    if ($TargetTenantId) {
        $connectParameters['Tenant'] = $TargetTenantId
        $contextParameters['Tenant'] = $TargetTenantId
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
}

function ConvertTo-ArmPathSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [System.Uri]::EscapeDataString($Value)
}

function New-LowercaseAlphanumericString {
    param(
        [ValidateRange(1, 128)]
        [int]$Length = 8
    )

    $characters = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    return -join (1..$Length | ForEach-Object { $characters | Get-Random })
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
        throw "ARM $Method failed for $Path. Status: $statusCode. Response: $($response.Content)"
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

function New-AutomationAccountPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$TargetAutomationAccountName
    )

    $accountSegment = ConvertTo-ArmPathSegment -Value $TargetAutomationAccountName
    return "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName/providers/Microsoft.Automation/automationAccounts/${accountSegment}?api-version=$AutomationApiVersion"
}

function New-UserAssignedManagedIdentityPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$TargetIdentityName
    )

    $identitySegment = ConvertTo-ArmPathSegment -Value $TargetIdentityName
    return "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${identitySegment}?api-version=$ManagedIdentityApiVersion"
}

function Get-UserAssignedManagedIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    $path = "${ResourceId}?api-version=$ManagedIdentityApiVersion"
    return Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200)
}

function New-UserAssignedManagedIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$TargetIdentityName,

        [Parameter(Mandatory = $true)]
        [string]$TargetLocation
    )

    $path = New-UserAssignedManagedIdentityPath `
        -TargetSubscriptionId $TargetSubscriptionId `
        -TargetResourceGroupName $TargetResourceGroupName `
        -TargetIdentityName $TargetIdentityName
    $body = @{
        location = $TargetLocation
    }
    $target = "$TargetSubscriptionId/$TargetResourceGroupName/$TargetIdentityName"

    $existingIdentity = Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200) -AllowNotFound
    if ($existingIdentity) {
        throw "User-assigned managed identity '$TargetIdentityName' already exists in resource group '$TargetResourceGroupName'. Pass -UserAssignedManagedIdentityResourceId '$($existingIdentity.id)' to reuse it, or choose a different -UserAssignedManagedIdentityName."
    }

    if ($PSCmdlet.ShouldProcess($target, 'Create user-assigned managed identity')) {
        return Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201)
    }

    throw 'User-assigned managed identity was not created. Run without -WhatIf to create it.'
}

function Get-UserAssignedManagedIdentityWithPrincipal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $identity = Get-UserAssignedManagedIdentity -ResourceId $ResourceId
        $principalId = [string]$identity.properties.principalId
        $clientId = [string]$identity.properties.clientId
        if (-not [string]::IsNullOrWhiteSpace($principalId) -and -not [string]::IsNullOrWhiteSpace($clientId)) {
            return $identity
        }

        Start-Sleep -Seconds 5
    }

    throw "The user-assigned managed identity principal ID or client ID was not available yet for '$ResourceId'. Wait a minute and rerun the role-assignment step."
}

function Confirm-ResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$TargetLocation
    )

    $resourceGroup = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if ($resourceGroup) {
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Create resource group')) {
        New-AzResourceGroup -Name $Name -Location $TargetLocation -Force | Out-Null
    }
}

function Set-AutomationAccountWithIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$TargetAutomationAccountName,

        [Parameter(Mandatory = $true)]
        [string]$TargetLocation,

        [Parameter(Mandatory = $true)]
        [ValidateSet('UserAssigned', 'SystemAssigned')]
        [string]$TargetManagedIdentityType,

        [string]$TargetUserAssignedManagedIdentityResourceId
    )

    if ($TargetManagedIdentityType -eq 'UserAssigned' -and [string]::IsNullOrWhiteSpace($TargetUserAssignedManagedIdentityResourceId)) {
        throw 'TargetUserAssignedManagedIdentityResourceId is required when TargetManagedIdentityType is UserAssigned.'
    }

    if ($TargetManagedIdentityType -eq 'UserAssigned') {
        $userAssignedIdentities = @{}
        $userAssignedIdentities[$TargetUserAssignedManagedIdentityResourceId] = @{}
        $identity = @{
            type                   = 'UserAssigned'
            userAssignedIdentities = $userAssignedIdentities
        }
        $identityDescription = 'user-assigned managed identity'
    }
    else {
        $identity = @{
            type = 'SystemAssigned'
        }
        $identityDescription = 'system-assigned managed identity'
    }

    $path = New-AutomationAccountPath `
        -TargetSubscriptionId $TargetSubscriptionId `
        -TargetResourceGroupName $TargetResourceGroupName `
        -TargetAutomationAccountName $TargetAutomationAccountName
    $body = @{
        location   = $TargetLocation
        identity   = $identity
        properties = @{
            sku = @{
                name = 'Basic'
            }
        }
    }
    $target = "$TargetSubscriptionId/$TargetResourceGroupName/$TargetAutomationAccountName"

    if ($PSCmdlet.ShouldProcess($target, "Create or update Automation Account with $identityDescription")) {
        return Invoke-ArmJson -Method PUT -Path $path -Body $body -ExpectedStatusCode @(200, 201)
    }

    $existingAccount = Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200) -AllowNotFound
    if (-not $existingAccount) {
        throw 'Automation Account does not exist. Run without -WhatIf to create it.'
    }

    return $existingAccount
}

function Get-AutomationAccountPrincipalId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$TargetAutomationAccountName
    )

    $path = New-AutomationAccountPath `
        -TargetSubscriptionId $TargetSubscriptionId `
        -TargetResourceGroupName $TargetResourceGroupName `
        -TargetAutomationAccountName $TargetAutomationAccountName

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $account = Invoke-ArmJson -Method GET -Path $path -ExpectedStatusCode @(200)
        $principalId = [string]$account.identity.principalId
        if (-not [string]::IsNullOrWhiteSpace($principalId)) {
            return $principalId
        }

        Start-Sleep -Seconds 5
    }

    throw "The Automation Account managed identity principal ID was not available yet for '$TargetAutomationAccountName'. Wait a minute and rerun the role-assignment step."
}

function Confirm-AutomationModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $existingModule = Get-AzAutomationModule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -ErrorAction SilentlyContinue
    if ($existingModule) {
        Write-Host "Automation module '$Name' already exists."
        return
    }

    $contentLinkUri = "https://www.powershellgallery.com/api/v2/package/$Name"
    if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Import Automation module from PowerShell Gallery')) {
        New-AzAutomationModule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -ContentLinkUri $contentLinkUri | Out-Null
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
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -ErrorAction SilentlyContinue

    if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Create or update Automation variable')) {
        if ($existingVariable) {
            Set-AzAutomationVariable `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $Name `
                -Encrypted $false `
                -Value $Value | Out-Null
        }
        else {
            New-AzAutomationVariable `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $Name `
                -Encrypted $false `
                -Value $Value | Out-Null
        }
    }
}

function Remove-AutomationPlainVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $existingVariable = Get-AzAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -ErrorAction SilentlyContinue

    if ($existingVariable -and $PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Remove Automation variable')) {
        Remove-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -Force | Out-Null
    }
}

function Import-AutomationRunbookFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Runbook path '$Path' was not found."
    }

    if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Import Automation runbook')) {
        Import-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -Path $Path `
            -Type $RunbookType `
            -Force | Out-Null
    }

    if (-not $SkipRunbookPublish) {
        if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Publish Automation runbook')) {
            Publish-AzAutomationRunbook `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $Name | Out-Null
        }
    }

    if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$Name", 'Enable verbose runbook logging')) {
        Set-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -LogVerbose $true | Out-Null
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
            -ErrorAction SilentlyContinue | Where-Object { $_.RoleDefinitionName -eq $RoleDefinitionName })
    if ($existingAssignments.Count -gt 0) {
        Write-Host "Role '$RoleDefinitionName' already assigned at scope '$Scope'."
        return
    }

    if ($PSCmdlet.ShouldProcess("$ObjectId -> $Scope", "Assign role '$RoleDefinitionName'")) {
        New-AzRoleAssignment `
            -ObjectId $ObjectId `
            -RoleDefinitionName $RoleDefinitionName `
            -Scope $Scope | Out-Null
    }
}

function Confirm-RecommendRoleAssignments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId
    )

    if ([string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
        throw '-AssignRecommendedRoles requires -SourceSubscriptionId.'
    }

    $sourceScope = "/subscriptions/$SourceSubscriptionId"
    Select-AzureChinaSubscription -TargetSubscriptionId $SourceSubscriptionId -TargetTenantId $TenantId
    Confirm-RoleAssignment -ObjectId $PrincipalId -Scope $sourceScope -RoleDefinitionName 'Reader'
    if ($GrantSourceNetworkContributor) {
        Confirm-RoleAssignment -ObjectId $PrincipalId -Scope $sourceScope -RoleDefinitionName 'Network Contributor'
    }

    if ([string]::IsNullOrWhiteSpace($DestinationPrivateDnsZoneResourceGroupName)) {
        $destinationScope = "/subscriptions/$DestinationSubscriptionId"
    }
    else {
        $destinationScope = "/subscriptions/$DestinationSubscriptionId/resourceGroups/$DestinationPrivateDnsZoneResourceGroupName"
    }

    Select-AzureChinaSubscription -TargetSubscriptionId $DestinationSubscriptionId -TargetTenantId $TenantId
    Confirm-RoleAssignment -ObjectId $PrincipalId -Scope $destinationScope -RoleDefinitionName 'Private DNS Zone Contributor'
    if ($GrantDestinationContributor) {
        Confirm-RoleAssignment -ObjectId $PrincipalId -Scope $destinationScope -RoleDefinitionName 'Contributor'
    }
}

foreach ($moduleName in @('Az.Accounts', 'Az.Resources', 'Az.Automation')) {
    Import-RequiredModule -Name $moduleName
}

if ([string]::IsNullOrWhiteSpace($AutomationAccountName)) {
    $suffix = New-LowercaseAlphanumericString -Length 8
    $AutomationAccountName = "aa-dns-sync-cn-$suffix"
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = "rg-$AutomationAccountName"
}

if ($ManagedIdentityType -eq 'UserAssigned') {
    if (-not [string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityResourceId) -and
        (-not [string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityName) -or -not [string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityResourceGroupName))) {
        throw 'Use either -UserAssignedManagedIdentityResourceId or -UserAssignedManagedIdentityName/-UserAssignedManagedIdentityResourceGroupName, not both.'
    }

    if ([string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityResourceId)) {
        if ([string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityName)) {
            $identitySuffix = New-LowercaseAlphanumericString -Length 8
            $UserAssignedManagedIdentityName = "id-$AutomationAccountName-$identitySuffix"
        }

        if ([string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityResourceGroupName)) {
            $UserAssignedManagedIdentityResourceGroupName = $ResourceGroupName
        }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityResourceId) -or
    -not [string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityName) -or
    -not [string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityResourceGroupName)) {
    throw 'User-assigned managed identity parameters require -ManagedIdentityType UserAssigned.'
}

Select-AzureChinaSubscription -TargetSubscriptionId $SubscriptionId -TargetTenantId $TenantId
Confirm-ResourceGroup -Name $ResourceGroupName -TargetLocation $Location

$managedIdentity = $null
$managedIdentityClientId = $null
$managedIdentityResourceId = $null
if ($ManagedIdentityType -eq 'UserAssigned') {
    if ([string]::IsNullOrWhiteSpace($UserAssignedManagedIdentityResourceId)) {
        if ($UserAssignedManagedIdentityResourceGroupName -ine $ResourceGroupName) {
            Confirm-ResourceGroup -Name $UserAssignedManagedIdentityResourceGroupName -TargetLocation $Location
        }

        $managedIdentity = New-UserAssignedManagedIdentity `
            -TargetSubscriptionId $SubscriptionId `
            -TargetResourceGroupName $UserAssignedManagedIdentityResourceGroupName `
            -TargetIdentityName $UserAssignedManagedIdentityName `
            -TargetLocation $Location
        $UserAssignedManagedIdentityResourceId = [string]$managedIdentity.id
    }

    $managedIdentity = Get-UserAssignedManagedIdentityWithPrincipal -ResourceId $UserAssignedManagedIdentityResourceId
    $managedIdentityResourceId = [string]$managedIdentity.id
    $managedIdentityClientId = [string]$managedIdentity.properties.clientId
}

$account = Set-AutomationAccountWithIdentity `
    -TargetSubscriptionId $SubscriptionId `
    -TargetResourceGroupName $ResourceGroupName `
    -TargetAutomationAccountName $AutomationAccountName `
    -TargetLocation $Location `
    -TargetManagedIdentityType $ManagedIdentityType `
    -TargetUserAssignedManagedIdentityResourceId $managedIdentityResourceId

if ($ManagedIdentityType -eq 'UserAssigned') {
    $principalId = [string]$managedIdentity.properties.principalId
}
else {
    $principalId = [string]$account.identity.principalId
}

if ($ManagedIdentityType -eq 'SystemAssigned' -and [string]::IsNullOrWhiteSpace($principalId)) {
    $principalId = Get-AutomationAccountPrincipalId `
        -TargetSubscriptionId $SubscriptionId `
        -TargetResourceGroupName $ResourceGroupName `
        -TargetAutomationAccountName $AutomationAccountName
}

if (-not $SkipModuleImport) {
    foreach ($moduleName in $RequiredAutomationModules) {
        Confirm-AutomationModule -Name $moduleName
    }
}

Import-AutomationRunbookFile -Name $RunbookName -Path $RunbookPath
Import-AutomationRunbookFile -Name $AksRepairRunbookName -Path $AksRepairRunbookPath

if (-not [string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
    Set-AutomationPlainVariable -Name $DefaultSourceSubscriptionIdAutomationVariableName -Value $SourceSubscriptionId
}

Set-AutomationPlainVariable -Name $DefaultDestinationSubscriptionIdAutomationVariableName -Value $DestinationSubscriptionId
Set-AutomationPlainVariable -Name $DefaultAksTargetVirtualNetworkResourceIdAutomationVariableName -Value $AksTargetVirtualNetworkResourceId

if ($ManagedIdentityType -eq 'UserAssigned') {
    Set-AutomationPlainVariable -Name $DefaultManagedIdentityAccountIdAutomationVariableName -Value $managedIdentityClientId
}
else {
    Remove-AutomationPlainVariable -Name $DefaultManagedIdentityAccountIdAutomationVariableName
}

if ($AssignRecommendedRoles) {
    Confirm-RecommendRoleAssignments -PrincipalId $principalId
}

[pscustomobject]@{
    SubscriptionId         = $SubscriptionId
    ResourceGroupName      = $ResourceGroupName
    Location               = $Location
    AutomationAccountName  = $AutomationAccountName
    ManagedIdentityType    = $ManagedIdentityType
    ManagedIdentityObjectId = $principalId
    ManagedIdentityClientId = $managedIdentityClientId
    ManagedIdentityResourceId = $managedIdentityResourceId
    DefaultSourceSubscriptionIdVariable = $DefaultSourceSubscriptionIdAutomationVariableName
    DefaultDestinationSubscriptionIdVariable = $DefaultDestinationSubscriptionIdAutomationVariableName
    DefaultAksTargetVirtualNetworkResourceIdVariable = $DefaultAksTargetVirtualNetworkResourceIdAutomationVariableName
    DefaultManagedIdentityAccountIdVariable = $DefaultManagedIdentityAccountIdAutomationVariableName
    SyncRunbookName        = $RunbookName
    SyncRunbookPath        = (Resolve-Path -Path $RunbookPath).Path
    AksRepairRunbookName   = $AksRepairRunbookName
    AksRepairRunbookPath   = (Resolve-Path -Path $AksRepairRunbookPath).Path
    RunbookType            = $RunbookType
    ModuleImportStarted    = -not $SkipModuleImport
    RunbooksPublished      = -not $SkipRunbookPublish
}