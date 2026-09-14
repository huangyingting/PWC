<#
.SYNOPSIS
Exports Azure China regional VM SKU availability, Compute quota, and deployed capacity to CSV.

.DESCRIPTION
Connects only to AzureChinaCloud and writes one CSV row for every virtualMachines
SKU returned for a specified region. A single subscription can be supplied with
SubscriptionId, or subscriptions can be read from the two-column CSV created by
Export-AccessibleSubscriptions.ps1. Each row includes SKU capabilities and
restrictions, the matching VM-family vCPU quota, total regional vCPU quota, and
an inventory summary for standalone VMs, VM scale sets, AKS, and Azure Machine
Learning compute.

VMs, VMSS, AKS nodes, and Azure Machine Learning AmlCompute nodes consume the
same Microsoft.Compute regional and VM-family vCPU quotas when the compute is
created in the customer's subscription. Azure Batch, Container Instances,
Dedicated Hosts, and some other services have additional or separate quota
models and are not reported by this Compute-quota export.

The quota values returned by Microsoft.Compute are authoritative. Inventory
counts are informational: deallocated resources, autoscale targets, hidden
managed resources, and recently changed resources can make inventory-derived
vCPU totals differ from CurrentValue.

Required permissions: Reader on the subscription.
Required modules: Az.Accounts and Az.Resources.

.PARAMETER SubscriptionId
Customer Azure China subscription ID.

.PARAMETER InputPath
Path to a CSV created by Export-AccessibleSubscriptions.ps1. The file must have
exactly two columns in this order: SubscriptionName, SubscriptionId. The script
queries each subscription sequentially and combines all successful results in
one output CSV.

.PARAMETER Location
Azure China region name, for example chinaeast2 or chinanorth3.

.PARAMETER TenantId
Optional Microsoft Entra tenant ID. In batch mode, specify it only when all
subscriptions in the input CSV belong to the same tenant.

.PARAMETER OutputPath
CSV output path. Defaults to a timestamped file beside this script.

.PARAMETER PassThru
Also writes every report row to the PowerShell success output stream. By
default, rows are written only to the CSV to avoid flooding interactive and
automation logs.

.EXAMPLE
    .\Export-AzureChinaVmSkuQuota.ps1 `
        -SubscriptionId '11111111-1111-1111-1111-111111111111' `
        -Location 'chinaeast2'

.EXAMPLE
    .\Export-AzureChinaVmSkuQuota.ps1 `
        -SubscriptionId '11111111-1111-1111-1111-111111111111' `
        -Location 'chinanorth3' `
        -OutputPath '.\customer-chinanorth3-vm-quota.csv'

.EXAMPLE
    .\Export-AzureChinaVmSkuQuota.ps1 `
        -InputPath '.\subscriptions.csv' `
        -Location 'chinaeast2' `
        -OutputPath '.\all-subscriptions-chinaeast2-vm-quota.csv'
#>

[CmdletBinding(DefaultParameterSetName = 'SingleSubscription')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'SingleSubscription')]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionFile')]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

#requires -Modules Az.Accounts, Az.Resources

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ComputeApiVersion = '2021-07-01'
$ComputeSkuApiVersion = '2021-07-01'
$RunStartedAt = Get-Date

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

    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }

    return $null
}

function Get-NestedPropertyValue {
    param(
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Path
    )

    $value = $InputObject
    foreach ($segment in $Path) {
        $value = Get-ObjectPropertyValue -InputObject $value -Name $segment
        if ($null -eq $value) {
            return $null
        }
    }

    return $value
}

function Select-AzureChinaSubscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [string]$TenantId
    )

    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop

    $connectParameters = @{
        Environment = 'AzureChinaCloud'
        ErrorAction = 'Stop'
    }
    $contextParameters = @{
        SubscriptionId = $SubscriptionId
        ErrorAction    = 'Stop'
    }

    if ($TenantId) {
        $connectParameters['Tenant'] = $TenantId
        $contextParameters['Tenant'] = $TenantId
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
        throw "Selected Azure environment is '$($selectedContext.Environment.Name)', expected 'AzureChinaCloud'."
    }

    return $selectedContext
}

function Invoke-ArmGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $response = Invoke-AzRestMethod -Method GET -Path $Path -ErrorAction Stop
    if ([int]$response.StatusCode -ne 200) {
        throw "ARM GET failed for '$Path'. Status: $($response.StatusCode). Response: $($response.Content)"
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
            $response = Invoke-AzRestMethod -Method GET -Uri $nextLink -ErrorAction Stop
            if ([int]$response.StatusCode -ne 200) {
                throw "ARM GET failed for '$nextLink'. Status: $($response.StatusCode). Response: $($response.Content)"
            }
            $page = $response.Content | ConvertFrom-Json
        }
        else {
            $page = Invoke-ArmGet -Path $nextLink
        }

        foreach ($item in @(Get-ObjectPropertyValue -InputObject $page -Name 'value')) {
            if ($null -ne $item) {
                $items.Add($item)
            }
        }

        $nextLink = [string](Get-ObjectPropertyValue -InputObject $page -Name 'nextLink')
    }

    return @($items.ToArray())
}

function Get-ResourceGroupNameFromId {
    param([string]$ResourceId)

    if ($ResourceId -match '/resourceGroups/([^/]+)/') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }

    return $null
}

function Get-TagValue {
    param(
        [object]$Tags,
        [string[]]$Names
    )

    if ($null -eq $Tags) {
        return $null
    }

    foreach ($tagProperty in $Tags.PSObject.Properties) {
        foreach ($name in $Names) {
            if ($tagProperty.Name -ieq $name) {
                return [string]$tagProperty.Value
            }
        }
    }

    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($key in $Tags.Keys) {
            foreach ($name in $Names) {
                if ([string]$key -ieq $name) {
                    return [string]$Tags[$key]
                }
            }
        }
    }

    return $null
}

function Get-CapabilityValue {
    param(
        [object]$Sku,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    foreach ($capability in @(Get-ObjectPropertyValue -InputObject $Sku -Name 'capabilities')) {
        if ([string](Get-ObjectPropertyValue -InputObject $capability -Name 'name') -ieq $Name) {
            return Get-ObjectPropertyValue -InputObject $capability -Name 'value'
        }
    }

    return $null
}

function Get-RegionalSkuRestriction {
    param(
        [object]$Sku,
        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $messages = New-Object System.Collections.Generic.List[string]
    $isLocationRestricted = $false

    foreach ($restriction in @(Get-ObjectPropertyValue -InputObject $Sku -Name 'restrictions')) {
        if ($null -eq $restriction) {
            continue
        }

        $type = [string](Get-ObjectPropertyValue -InputObject $restriction -Name 'type')
        $reasonCode = [string](Get-ObjectPropertyValue -InputObject $restriction -Name 'reasonCode')
        $restrictionInfo = Get-ObjectPropertyValue -InputObject $restriction -Name 'restrictionInfo'
        $restrictedLocations = @((Get-ObjectPropertyValue -InputObject $restrictionInfo -Name 'locations') |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $restrictedZones = @((Get-ObjectPropertyValue -InputObject $restrictionInfo -Name 'zones') |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        if ($type -ieq 'Location' -and ($restrictedLocations.Count -eq 0 -or $restrictedLocations -icontains $Location)) {
            $isLocationRestricted = $true
        }

        $details = @($type, $reasonCode) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($restrictedZones.Count -gt 0) {
            $details += "zones=$($restrictedZones -join '|')"
        }
        if ($restrictedLocations.Count -gt 0) {
            $details += "locations=$($restrictedLocations -join '|')"
        }
        if ($details.Count -gt 0) {
            $messages.Add($details -join ':')
        }
    }

    return [pscustomobject]@{
        IsLocationRestricted = $isLocationRestricted
        Message              = $messages -join '; '
    }
}

function New-InventoryEntry {
    return [ordered]@{
        VirtualMachineCount              = 0
        VirtualMachineScaleSetCount      = 0
        VirtualMachineScaleSetInstances  = 0
        AksScaleSetCount                  = 0
        AksNodeCount                      = 0
        AzureMachineLearningComputeCount = 0
        AzureMachineLearningNodeCount    = 0
        OtherManagedScaleSetCount        = 0
        OtherManagedInstances            = 0
    }
}

function Add-InventoryValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Inventory,
        [Parameter(Mandatory = $true)]
        [string]$VmSize,
        [Parameter(Mandatory = $true)]
        [string]$Property,
        [int]$Value = 1
    )

    if ([string]::IsNullOrWhiteSpace($VmSize)) {
        return
    }

    $key = $VmSize.ToLowerInvariant()
    if (-not $Inventory.ContainsKey($key)) {
        $Inventory[$key] = New-InventoryEntry
    }

    $Inventory[$key][$Property] = [int]$Inventory[$key][$Property] + $Value
}

function Get-RegionalComputeInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $inventory = @{}
    $normalizedLocation = $Location.ToLowerInvariant()
    $virtualMachines = @(Get-AzResource `
        -ResourceType 'Microsoft.Compute/virtualMachines' `
        -ExpandProperties `
        -ErrorAction Stop | Where-Object {
        ([string]$_.Location).ToLowerInvariant() -eq $normalizedLocation
    })
    $scaleSets = @(Get-AzResource `
        -ResourceType 'Microsoft.Compute/virtualMachineScaleSets' `
        -ExpandProperties `
        -ErrorAction Stop | Where-Object {
        ([string]$_.Location).ToLowerInvariant() -eq $normalizedLocation
    })
    $managedClusters = @(Get-AzResource `
        -ResourceType 'Microsoft.ContainerService/managedClusters' `
        -ExpandProperties `
        -ErrorAction Stop | Where-Object {
        ([string]$_.Location).ToLowerInvariant() -eq $normalizedLocation
    })
    $amlComputes = @(Get-AzResource `
        -ResourceType 'Microsoft.MachineLearningServices/workspaces/computes' `
        -ExpandProperties `
        -ErrorAction Stop | Where-Object {
        ([string]$_.Location).ToLowerInvariant() -eq $normalizedLocation
    })

    $aksNodeResourceGroups = @{}
    foreach ($cluster in $managedClusters) {
        $nodeResourceGroup = [string](Get-ObjectPropertyValue -InputObject $cluster.Properties -Name 'nodeResourceGroup')
        if (-not [string]::IsNullOrWhiteSpace($nodeResourceGroup)) {
            $aksNodeResourceGroups[$nodeResourceGroup.ToLowerInvariant()] = $true
        }
    }

    $amlVmssIds = @{}
    foreach ($compute in $amlComputes) {
        $computeType = [string](Get-ObjectPropertyValue -InputObject $compute.Properties -Name 'computeType')
        if ($computeType -ine 'AmlCompute') {
            continue
        }

        $details = Get-ObjectPropertyValue -InputObject $compute.Properties -Name 'properties'
        $vmSize = [string](Get-ObjectPropertyValue -InputObject $details -Name 'vmSize')
        $resourceId = [string](Get-ObjectPropertyValue -InputObject $compute.Properties -Name 'resourceId')
        if ([string]::IsNullOrWhiteSpace($resourceId)) {
            $resourceId = [string](Get-ObjectPropertyValue -InputObject $details -Name 'resourceId')
        }
        if (-not [string]::IsNullOrWhiteSpace($resourceId)) {
            $amlVmssIds[$resourceId.TrimEnd('/').ToLowerInvariant()] = $true
        }

        Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'AzureMachineLearningComputeCount'
    }

    $matchedAmlVmssIds = @{}
    foreach ($scaleSet in $scaleSets) {
        $vmSize = [string](Get-NestedPropertyValue -InputObject $scaleSet -Path @('Sku', 'Name'))
        if ([string]::IsNullOrWhiteSpace($vmSize)) {
            $vmSize = [string](Get-NestedPropertyValue -InputObject $scaleSet.Properties -Path @('virtualMachineProfile', 'hardwareProfile', 'vmSize'))
        }
        $capacityValue = Get-NestedPropertyValue -InputObject $scaleSet -Path @('Sku', 'Capacity')
        $capacity = if ($null -eq $capacityValue) { 0 } else { [int]$capacityValue }
        $resourceIdKey = ([string]$scaleSet.ResourceId).TrimEnd('/').ToLowerInvariant()
        $resourceGroupName = [string]$scaleSet.ResourceGroupName
        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            $resourceGroupName = Get-ResourceGroupNameFromId -ResourceId ([string]$scaleSet.ResourceId)
        }

        $aksTag = Get-TagValue -Tags $scaleSet.Tags -Names @('aks-managed-cluster-name', 'aks-managed-cluster-rg')
        $amlTag = Get-TagValue -Tags $scaleSet.Tags -Names @('azureml', 'amlcompute', 'AzureMachineLearning')

        if ($amlVmssIds.ContainsKey($resourceIdKey) -or -not [string]::IsNullOrWhiteSpace($amlTag)) {
            Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'AzureMachineLearningNodeCount' -Value $capacity
            $matchedAmlVmssIds[$resourceIdKey] = $true
        }
        elseif ((-not [string]::IsNullOrWhiteSpace($resourceGroupName) -and $aksNodeResourceGroups.ContainsKey($resourceGroupName.ToLowerInvariant())) -or
            -not [string]::IsNullOrWhiteSpace($aksTag)) {
            Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'AksScaleSetCount'
            Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'AksNodeCount' -Value $capacity
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$scaleSet.ManagedBy)) {
            Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'OtherManagedScaleSetCount'
            Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'OtherManagedInstances' -Value $capacity
        }
        else {
            Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'VirtualMachineScaleSetCount'
            Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'VirtualMachineScaleSetInstances' -Value $capacity
        }
    }

    foreach ($compute in $amlComputes) {
        $computeType = [string](Get-ObjectPropertyValue -InputObject $compute.Properties -Name 'computeType')
        if ($computeType -ine 'AmlCompute') {
            continue
        }

        $details = Get-ObjectPropertyValue -InputObject $compute.Properties -Name 'properties'
        $vmSize = [string](Get-ObjectPropertyValue -InputObject $details -Name 'vmSize')
        $resourceId = [string](Get-ObjectPropertyValue -InputObject $compute.Properties -Name 'resourceId')
        if ([string]::IsNullOrWhiteSpace($resourceId)) {
            $resourceId = [string](Get-ObjectPropertyValue -InputObject $details -Name 'resourceId')
        }
        $resourceIdKey = $resourceId.TrimEnd('/').ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($resourceIdKey) -and $matchedAmlVmssIds.ContainsKey($resourceIdKey)) {
            continue
        }

        $currentNodeCount = Get-ObjectPropertyValue -InputObject $details -Name 'currentNodeCount'
        if ($null -ne $currentNodeCount) {
            Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'AzureMachineLearningNodeCount' -Value ([int]$currentNodeCount)
        }
    }

    foreach ($virtualMachine in $virtualMachines) {
        $parentScaleSet = Get-NestedPropertyValue -InputObject $virtualMachine.Properties -Path @('virtualMachineScaleSet', 'id')
        if (-not [string]::IsNullOrWhiteSpace([string]$parentScaleSet)) {
            continue
        }

        $vmSize = [string](Get-NestedPropertyValue -InputObject $virtualMachine.Properties -Path @('hardwareProfile', 'vmSize'))
        Add-InventoryValue -Inventory $inventory -VmSize $vmSize -Property 'VirtualMachineCount'
    }

    return $inventory
}

function Get-SubscriptionVmSkuQuotaReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [string]$TenantId
    )

    Write-Host "Selecting Azure China subscription '$SubscriptionId'..."
    $context = Select-AzureChinaSubscription -SubscriptionId $SubscriptionId -TenantId $TenantId
    $subscriptionName = [string]$context.Subscription.Name

    Write-Host "Reading Microsoft.Compute quota for '$Location'..."
    $usagePath = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/usages?api-version=$ComputeApiVersion"
    $usages = @(Get-ArmPagedValues -Path $usagePath)
    $usageByName = @{}
    foreach ($usage in $usages) {
        $usageName = [string](Get-NestedPropertyValue -InputObject $usage -Path @('name', 'value'))
        if (-not [string]::IsNullOrWhiteSpace($usageName)) {
            $usageByName[$usageName.ToLowerInvariant()] = $usage
        }
    }

    $regionalUsage = $null
    foreach ($regionalUsageName in @('cores', 'totalRegionalCores')) {
        if ($usageByName.ContainsKey($regionalUsageName.ToLowerInvariant())) {
            $regionalUsage = $usageByName[$regionalUsageName.ToLowerInvariant()]
            break
        }
    }
    $regionalCurrent = if ($null -eq $regionalUsage) { $null } else { [int](Get-ObjectPropertyValue -InputObject $regionalUsage -Name 'currentValue') }
    $regionalLimit = if ($null -eq $regionalUsage) { $null } else { [int](Get-ObjectPropertyValue -InputObject $regionalUsage -Name 'limit') }
    $regionalRemaining = if ($null -eq $regionalUsage) { $null } else { [Math]::Max(0, $regionalLimit - $regionalCurrent) }

    Write-Host "Reading VM SKU availability for '$Location'..."
    $skuPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus?api-version=$ComputeSkuApiVersion"
    $skus = @(Get-ArmPagedValues -Path $skuPath | Where-Object {
        [string](Get-ObjectPropertyValue -InputObject $_ -Name 'resourceType') -ieq 'virtualMachines' -and
        @((Get-ObjectPropertyValue -InputObject $_ -Name 'locations') | ForEach-Object { [string]$_ }) -icontains $Location
    })
    if ($skus.Count -eq 0) {
        throw "No virtual machine SKUs were returned for region '$Location'. Verify that the Azure China region name and subscription are correct."
    }

    Write-Host 'Reading VM, VMSS, AKS, and Azure Machine Learning inventory...'
    $inventory = Get-RegionalComputeInventory -Location $Location

    foreach ($sku in $skus | Sort-Object { [string](Get-ObjectPropertyValue -InputObject $_ -Name 'name') }) {
    $vmSize = [string](Get-ObjectPropertyValue -InputObject $sku -Name 'name')
    $family = [string](Get-ObjectPropertyValue -InputObject $sku -Name 'family')
    $familyUsage = $null
    if (-not [string]::IsNullOrWhiteSpace($family) -and $usageByName.ContainsKey($family.ToLowerInvariant())) {
        $familyUsage = $usageByName[$family.ToLowerInvariant()]
    }

    $restriction = Get-RegionalSkuRestriction -Sku $sku -Location $Location
    $vmSizeKey = $vmSize.ToLowerInvariant()
    $deployed = if ($inventory.ContainsKey($vmSizeKey)) { $inventory[$vmSizeKey] } else { New-InventoryEntry }
    $vCpusValue = Get-CapabilityValue -Sku $sku -Name 'vCPUs'
    $vCpus = if ($null -eq $vCpusValue -or [string]::IsNullOrWhiteSpace([string]$vCpusValue)) { $null } else { [int]$vCpusValue }
    $familyCurrent = if ($null -eq $familyUsage) { $null } else { [int](Get-ObjectPropertyValue -InputObject $familyUsage -Name 'currentValue') }
    $familyLimit = if ($null -eq $familyUsage) { $null } else { [int](Get-ObjectPropertyValue -InputObject $familyUsage -Name 'limit') }
    $familyRemaining = if ($null -eq $familyUsage) { $null } else { [Math]::Max(0, $familyLimit - $familyCurrent) }
    $isAvailableToSubscription = -not $restriction.IsLocationRestricted
    $maxAdditionalInstances = if ($isAvailableToSubscription -and $null -ne $vCpus -and $vCpus -gt 0 -and $null -ne $familyRemaining) {
        [Math]::Floor($familyRemaining / $vCpus)
    }
    elseif (-not $isAvailableToSubscription -and $null -ne $familyRemaining) {
        0
    }
    else {
        $null
    }
    $effectiveRemaining = if ($null -ne $familyRemaining -and $null -ne $regionalRemaining) {
        [Math]::Min($familyRemaining, $regionalRemaining)
    }
    elseif ($null -ne $familyRemaining) {
        $familyRemaining
    }
    else {
        $regionalRemaining
    }
    $maxAdditionalInstancesByEffectiveQuota = if ($isAvailableToSubscription -and $null -ne $vCpus -and $vCpus -gt 0 -and $null -ne $effectiveRemaining) {
        [Math]::Floor($effectiveRemaining / $vCpus)
    }
    elseif (-not $isAvailableToSubscription -and $null -ne $effectiveRemaining) {
        0
    }
    else {
        $null
    }

        [pscustomobject][ordered]@{
        SubscriptionName                      = $subscriptionName
        SubscriptionId                        = $SubscriptionId
        AzureEnvironment                      = 'AzureChinaCloud'
        Location                              = $Location
        VmSize                                = $vmSize
        VmFamily                              = $family
        vCPUs                                 = $vCpus
        MemoryGB                              = Get-CapabilityValue -Sku $sku -Name 'MemoryGB'
        PremiumIO                             = Get-CapabilityValue -Sku $sku -Name 'PremiumIO'
        AcceleratedNetworkingEnabled          = Get-CapabilityValue -Sku $sku -Name 'AcceleratedNetworkingEnabled'
        AvailableToSubscription               = $isAvailableToSubscription
        Restrictions                          = $restriction.Message
        FamilyQuotaName                       = if ($null -eq $familyUsage) { $null } else { Get-NestedPropertyValue -InputObject $familyUsage -Path @('name', 'localizedValue') }
        FamilyQuotaCurrentvCPUs                = $familyCurrent
        FamilyQuotaLimitvCPUs                  = $familyLimit
        FamilyQuotaRemainingvCPUs              = $familyRemaining
        MaxAdditionalInstancesByFamilyQuota    = $maxAdditionalInstances
        RegionalQuotaCurrentvCPUs              = $regionalCurrent
        RegionalQuotaLimitvCPUs                = $regionalLimit
        RegionalQuotaRemainingvCPUs            = $regionalRemaining
        MaxAdditionalInstancesByEffectiveQuota = $maxAdditionalInstancesByEffectiveQuota
        VirtualMachineCount                    = $deployed.VirtualMachineCount
        VirtualMachineScaleSetCount            = $deployed.VirtualMachineScaleSetCount
        VirtualMachineScaleSetInstances        = $deployed.VirtualMachineScaleSetInstances
        AksScaleSetCount                       = $deployed.AksScaleSetCount
        AksNodeCount                           = $deployed.AksNodeCount
        AzureMachineLearningComputeCount       = $deployed.AzureMachineLearningComputeCount
        AzureMachineLearningNodeCount          = $deployed.AzureMachineLearningNodeCount
        OtherManagedScaleSetCount              = $deployed.OtherManagedScaleSetCount
        OtherManagedInstances                  = $deployed.OtherManagedInstances
        ExportedAtUtc                          = [DateTime]::UtcNow.ToString('o')
        }
    }
}

$Location = $Location.Trim().ToLowerInvariant()
$subscriptions = if ($PSCmdlet.ParameterSetName -eq 'SubscriptionFile') {
    $resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).ProviderPath
    if (-not (Test-Path -LiteralPath $resolvedInputPath -PathType Leaf)) {
        throw 'InputPath must be a CSV file.'
    }

    $inputRows = @(Import-Csv -LiteralPath $resolvedInputPath -Encoding utf8)
    if ($inputRows.Count -eq 0) {
        throw 'Input CSV must contain a header and at least one subscription row.'
    }
    $columns = @($inputRows[0].PSObject.Properties.Name)
    if ($columns.Count -ne 2 -or $columns[0] -cne 'SubscriptionName' -or $columns[1] -cne 'SubscriptionId') {
        throw 'Input CSV must have exactly two columns, in order: SubscriptionName, SubscriptionId.'
    }

    @(for ($index = 0; $index -lt $inputRows.Count; $index++) {
        $name = ([string]$inputRows[$index].SubscriptionName).Trim()
        $id = ([string]$inputRows[$index].SubscriptionId).Trim()
        $parsedId = [guid]::Empty
        if ([string]::IsNullOrWhiteSpace($name) -or
            -not [guid]::TryParseExact($id, 'D', [ref]$parsedId) -or
            $parsedId -eq [guid]::Empty) {
            throw "Invalid CSV data row $($index + 1): supply a subscription name and a non-empty GUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
        }
        [pscustomobject]@{
            SubscriptionName = $name
            SubscriptionId   = $parsedId.ToString()
        }
    })
}
else {
    @([pscustomobject]@{
        SubscriptionName = ''
        SubscriptionId   = $SubscriptionId.Trim()
    })
}

$duplicateSubscriptionIds = @($subscriptions | Group-Object SubscriptionId | Where-Object Count -gt 1)
if ($duplicateSubscriptionIds.Count -gt 0) {
    throw "Input CSV contains duplicate subscription IDs. Each subscription must appear exactly once. Duplicate IDs: $($duplicateSubscriptionIds.Name -join ', ')"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputScope = if ($PSCmdlet.ParameterSetName -eq 'SubscriptionFile') {
        'all-subscriptions'
    }
    else {
        $SubscriptionId -replace '[^a-zA-Z0-9-]', ''
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $PSScriptRoot "azure-china-vm-sku-quota-$outputScope-$Location-$timestamp.csv"
}

$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ($PSCmdlet.ParameterSetName -eq 'SubscriptionFile' -and $resolvedInputPath -eq $resolvedOutputPath) {
    throw 'InputPath and OutputPath must be different files.'
}
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$report = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($subscription in $subscriptions) {
    try {
        $subscriptionRows = @(Get-SubscriptionVmSkuQuotaReport `
            -SubscriptionId $subscription.SubscriptionId `
            -Location $Location `
            -TenantId $TenantId)
        foreach ($row in $subscriptionRows) {
            $report.Add($row)
        }
    }
    catch {
        $message = "$($subscription.SubscriptionName) ($($subscription.SubscriptionId)): $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
    }
}

if ($report.Count -eq 0) {
    throw "No VM SKU quota rows were collected. Failed subscriptions: $($failures -join ' | ')"
}

$report.ToArray() | Export-Csv -LiteralPath $resolvedOutputPath -NoTypeInformation -Encoding UTF8
$resolvedOutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
$duration = (Get-Date) - $RunStartedAt
Write-Host "Exported '$($report.Count)' VM SKU rows for '$($subscriptions.Count)' subscription(s) to '$resolvedOutputPath' in $('{0:hh\:mm\:ss}' -f $duration)."

if ($PassThru) {
    $report.ToArray()
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) subscription query/queries failed. Partial results were saved to '$resolvedOutputPath'. Failures: $($failures -join ' | ')"
}
