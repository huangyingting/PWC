<#
.SYNOPSIS
Deploys multiple Azure China private endpoints for testing.

.DESCRIPTION
Creates a small Azure China test environment with three different private
endpoint group IDs and private DNS zones:
- Storage blob: privatelink.blob.core.chinacloudapi.cn
- Storage file: privatelink.file.core.chinacloudapi.cn
- Key Vault vault: privatelink.vaultcore.azure.cn

Use PrivateDnsZoneGroupName to deploy a non-default group name and validate
that synchronization adopts the endpoint's existing group.
#>

[CmdletBinding()]
param(
	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$SubscriptionId = '4157b2d1-e1d0-4c44-8ef3-2bcda2f98d56',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$Location = 'chinaeast2',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$PrivateDnsZoneGroupName = 'default',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$TenantId,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$NameSuffix,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$ResourceGroupName,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$OutputPath = (Join-Path $PSScriptRoot 'china-private-endpoint-test-deployment.json')
)

#requires -Modules Az.Accounts, Az.Resources

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

		[string]$TenantId
	)

	Import-AzAccountsModule

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

	return $selectedContext
}

function Get-PrivateEndpointIpAddress {
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
		-ExpandProperties

	$networkInterfaceId = $privateEndpoint.Properties.networkInterfaces[0].id
	$networkInterface = Get-AzResource -ResourceId $networkInterfaceId -ExpandProperties
	return [string]$networkInterface.Properties.ipConfigurations[0].properties.privateIPAddress
}

if ([string]::IsNullOrWhiteSpace($NameSuffix)) {
	$characters = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
	$NameSuffix = -join (1..8 | ForEach-Object { $characters | Get-Random })
}

$NameSuffix = $NameSuffix.ToLowerInvariant() -replace '[^a-z0-9]', ''
if ($NameSuffix.Length -lt 3) {
	throw 'NameSuffix must contain at least 3 lowercase letters or numbers.'
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
	$ResourceGroupName = "rg-pe-cn-test-$NameSuffix"
}

$storageAccountName = "stpecn$NameSuffix"
if ($storageAccountName.Length -gt 24) {
	$storageAccountName = $storageAccountName.Substring(0, 24)
}

$keyVaultName = "kvpecn$NameSuffix"
if ($keyVaultName.Length -gt 24) {
	$keyVaultName = $keyVaultName.Substring(0, 24)
}

$context = Select-AzureChinaSubscription -SubscriptionId $SubscriptionId -TenantId $TenantId
if ([string]::IsNullOrWhiteSpace($TenantId)) {
	$TenantId = $context.Tenant.Id
}

$template = @{
	'$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
	contentVersion = '1.0.0.0'
	parameters     = @{
		location           = @{ type = 'string' }
		storageAccountName = @{ type = 'string' }
		keyVaultName       = @{ type = 'string' }
		tenantId           = @{ type = 'string' }
	}
	variables      = @{
		vnetName                 = 'vnet-pe-cn-test'
		subnetName               = 'snet-private-endpoints'
		blobPrivateEndpointName  = 'pe-storage-blob-test'
		filePrivateEndpointName  = 'pe-storage-file-test'
		vaultPrivateEndpointName = 'pe-keyvault-test'
		privateDnsZoneGroupName  = $PrivateDnsZoneGroupName
		blobDnsZoneName          = 'privatelink.blob.core.chinacloudapi.cn'
		fileDnsZoneName          = 'privatelink.file.core.chinacloudapi.cn'
		vaultDnsZoneName         = 'privatelink.vaultcore.azure.cn'
		subnetId                 = "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('vnetName'), variables('subnetName'))]"
		storageAccountId         = "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
		keyVaultId               = "[resourceId('Microsoft.KeyVault/vaults', parameters('keyVaultName'))]"
		blobDnsZoneId            = "[resourceId('Microsoft.Network/privateDnsZones', variables('blobDnsZoneName'))]"
		fileDnsZoneId            = "[resourceId('Microsoft.Network/privateDnsZones', variables('fileDnsZoneName'))]"
		vaultDnsZoneId           = "[resourceId('Microsoft.Network/privateDnsZones', variables('vaultDnsZoneName'))]"
	}
	resources      = @(
		@{
			type       = 'Microsoft.Network/virtualNetworks'
			apiVersion = '2023-09-01'
			name       = "[variables('vnetName')]"
			location   = "[parameters('location')]"
			properties = @{
				addressSpace = @{ addressPrefixes = @('10.83.0.0/16') }
				subnets      = @(
					@{
						name       = "[variables('subnetName')]"
						properties = @{
							addressPrefix                     = '10.83.1.0/24'
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
				accessTier                   = 'Hot'
				allowBlobPublicAccess        = $false
				allowSharedKeyAccess         = $true
				defaultToOAuthAuthentication = $true
				minimumTlsVersion            = 'TLS1_2'
				publicNetworkAccess          = 'Disabled'
				supportsHttpsTrafficOnly     = $true
			}
		}
		@{
			type       = 'Microsoft.KeyVault/vaults'
			apiVersion = '2023-07-01'
			name       = "[parameters('keyVaultName')]"
			location   = "[parameters('location')]"
			properties = @{
				tenantId                     = "[parameters('tenantId')]"
				sku                          = @{ family = 'A'; name = 'standard' }
				accessPolicies               = @()
				enableRbacAuthorization      = $true
				enabledForDeployment         = $false
				enabledForDiskEncryption     = $false
				enabledForTemplateDeployment = $false
				publicNetworkAccess          = 'Disabled'
				softDeleteRetentionInDays    = 7
			}
		}
		@{
			type       = 'Microsoft.Network/privateDnsZones'
			apiVersion = '2020-06-01'
			name       = "[variables('blobDnsZoneName')]"
			location   = 'global'
		}
		@{
			type       = 'Microsoft.Network/privateDnsZones'
			apiVersion = '2020-06-01'
			name       = "[variables('fileDnsZoneName')]"
			location   = 'global'
		}
		@{
			type       = 'Microsoft.Network/privateDnsZones'
			apiVersion = '2020-06-01'
			name       = "[variables('vaultDnsZoneName')]"
			location   = 'global'
		}
		@{
			type       = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
			apiVersion = '2020-06-01'
			name       = "[format('{0}/{1}', variables('blobDnsZoneName'), 'vnet-pe-cn-test-link')]"
			location   = 'global'
			dependsOn  = @(
				"[resourceId('Microsoft.Network/privateDnsZones', variables('blobDnsZoneName'))]"
				"[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]"
			)
			properties = @{
				registrationEnabled = $false
				virtualNetwork      = @{ id = "[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]" }
			}
		}
		@{
			type       = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
			apiVersion = '2020-06-01'
			name       = "[format('{0}/{1}', variables('fileDnsZoneName'), 'vnet-pe-cn-test-link')]"
			location   = 'global'
			dependsOn  = @(
				"[resourceId('Microsoft.Network/privateDnsZones', variables('fileDnsZoneName'))]"
				"[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]"
			)
			properties = @{
				registrationEnabled = $false
				virtualNetwork      = @{ id = "[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]" }
			}
		}
		@{
			type       = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
			apiVersion = '2020-06-01'
			name       = "[format('{0}/{1}', variables('vaultDnsZoneName'), 'vnet-pe-cn-test-link')]"
			location   = 'global'
			dependsOn  = @(
				"[resourceId('Microsoft.Network/privateDnsZones', variables('vaultDnsZoneName'))]"
				"[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]"
			)
			properties = @{
				registrationEnabled = $false
				virtualNetwork      = @{ id = "[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]" }
			}
		}
		@{
			type       = 'Microsoft.Network/privateEndpoints'
			apiVersion = '2023-09-01'
			name       = "[variables('blobPrivateEndpointName')]"
			location   = "[parameters('location')]"
			dependsOn  = @(
				"[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]"
				"[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
			)
			properties = @{
				subnet = @{ id = "[variables('subnetId')]" }
				privateLinkServiceConnections = @(
					@{ name = 'blob'; properties = @{ privateLinkServiceId = "[variables('storageAccountId')]"; groupIds = @('blob') } }
				)
			}
		}
		@{
			type       = 'Microsoft.Network/privateEndpoints'
			apiVersion = '2023-09-01'
			name       = "[variables('filePrivateEndpointName')]"
			location   = "[parameters('location')]"
			dependsOn  = @(
				"[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]"
				"[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
			)
			properties = @{
				subnet = @{ id = "[variables('subnetId')]" }
				privateLinkServiceConnections = @(
					@{ name = 'file'; properties = @{ privateLinkServiceId = "[variables('storageAccountId')]"; groupIds = @('file') } }
				)
			}
		}
		@{
			type       = 'Microsoft.Network/privateEndpoints'
			apiVersion = '2023-09-01'
			name       = "[variables('vaultPrivateEndpointName')]"
			location   = "[parameters('location')]"
			dependsOn  = @(
				"[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]"
				"[resourceId('Microsoft.KeyVault/vaults', parameters('keyVaultName'))]"
			)
			properties = @{
				subnet = @{ id = "[variables('subnetId')]" }
				privateLinkServiceConnections = @(
					@{ name = 'vault'; properties = @{ privateLinkServiceId = "[variables('keyVaultId')]"; groupIds = @('vault') } }
				)
			}
		}
		@{
			type       = 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
			apiVersion = '2023-09-01'
			name       = "[format('{0}/{1}', variables('blobPrivateEndpointName'), variables('privateDnsZoneGroupName'))]"
			dependsOn  = @(
				"[resourceId('Microsoft.Network/privateEndpoints', variables('blobPrivateEndpointName'))]"
				"[resourceId('Microsoft.Network/privateDnsZones', variables('blobDnsZoneName'))]"
			)
			properties = @{ privateDnsZoneConfigs = @(@{ name = 'blob'; properties = @{ privateDnsZoneId = "[variables('blobDnsZoneId')]" } }) }
		}
		@{
			type       = 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
			apiVersion = '2023-09-01'
			name       = "[format('{0}/{1}', variables('filePrivateEndpointName'), variables('privateDnsZoneGroupName'))]"
			dependsOn  = @(
				"[resourceId('Microsoft.Network/privateEndpoints', variables('filePrivateEndpointName'))]"
				"[resourceId('Microsoft.Network/privateDnsZones', variables('fileDnsZoneName'))]"
			)
			properties = @{ privateDnsZoneConfigs = @(@{ name = 'file'; properties = @{ privateDnsZoneId = "[variables('fileDnsZoneId')]" } }) }
		}
		@{
			type       = 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
			apiVersion = '2023-09-01'
			name       = "[format('{0}/{1}', variables('vaultPrivateEndpointName'), variables('privateDnsZoneGroupName'))]"
			dependsOn  = @(
				"[resourceId('Microsoft.Network/privateEndpoints', variables('vaultPrivateEndpointName'))]"
				"[resourceId('Microsoft.Network/privateDnsZones', variables('vaultDnsZoneName'))]"
			)
			properties = @{ privateDnsZoneConfigs = @(@{ name = 'vault'; properties = @{ privateDnsZoneId = "[variables('vaultDnsZoneId')]" } }) }
		}
	)
}

Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..."
New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null

Write-Host 'Deploying Azure China private endpoint test resources...'
New-AzResourceGroupDeployment `
	-Name "pe-cn-test-$NameSuffix" `
	-ResourceGroupName $ResourceGroupName `
	-TemplateObject $template `
	-location $Location `
	-storageAccountName $storageAccountName `
	-keyVaultName $keyVaultName `
	-tenantId $TenantId `
	-Verbose | Out-Null

$privateEndpointDefinitions = @(
	@{ Name = 'pe-storage-blob-test'; GroupId = 'blob'; PrivateDnsZone = 'privatelink.blob.core.chinacloudapi.cn' }
	@{ Name = 'pe-storage-file-test'; GroupId = 'file'; PrivateDnsZone = 'privatelink.file.core.chinacloudapi.cn' }
	@{ Name = 'pe-keyvault-test'; GroupId = 'vault'; PrivateDnsZone = 'privatelink.vaultcore.azure.cn' }
)

$privateEndpoints = foreach ($definition in $privateEndpointDefinitions) {
	[pscustomobject]@{
		Name           = $definition.Name
		GroupId        = $definition.GroupId
		PrivateIp      = Get-PrivateEndpointIpAddress -ResourceGroupName $ResourceGroupName -PrivateEndpointName $definition.Name
		PrivateDnsZone = $definition.PrivateDnsZone
	}
}

$result = [ordered]@{
	SubscriptionId     = $SubscriptionId
	Environment        = 'AzureChinaCloud'
	TenantId           = $TenantId
	ResourceGroupName  = $ResourceGroupName
	Location           = $Location
	StorageAccountName = $storageAccountName
	KeyVaultName       = $keyVaultName
	VNetName           = 'vnet-pe-cn-test'
	SubnetName         = 'snet-private-endpoints'
	PrivateDnsZoneGroupName = $PrivateDnsZoneGroupName
	PrivateEndpoints   = @($privateEndpoints)
	CleanupCommand     = "Remove-AzResourceGroup -Name '$ResourceGroupName' -Force"
}

$result | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
$result | Format-List
$privateEndpoints | Format-Table -AutoSize
Write-Host "Deployment details written to '$OutputPath'."
