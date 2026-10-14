# PWC Azure China Private DNS Automation

Automates Private DNS operations for PWC on Azure China:

- `Sync-PrivateEndpointPrivateDns` syncs supported Private Endpoint DNS zones from a source subscription to the default destination subscription.
- `Link-PrivateEndpointPrivateDns` infers and links the required destination Private DNS zone for one Private Endpoint.
- `Repair-AksPrivateDnsLinks` links AKS private DNS zones to the default FCS VNet.
- `Export-AzureChinaVmSkuQuota` exports regional VM SKU availability, Compute quota, and deployed compute inventory to CSV.
- `Register-ResourceProviders` registers an explicit provider list across subscriptions from a CSV and writes an audit report.

## Documentation

- [English documentation](docs/resource-provider-inventory.en.md) — subscription and registered resource provider inventory.
- [中文文档](docs/resource-provider-inventory.zh-CN.md) — 订阅与已注册资源提供程序清单。
- [AKS unused PVC guide (English)](docs/aks-unused-pvc.en.md) — finding and safely deleting unused AKS PVCs and Azure Disks.
- [AKS 未使用 PVC 清理指南（中文）](docs/aks-unused-pvc.zh-CN.md) — 查找并安全清理 AKS 未使用 PVC 与 Azure 磁盘。
- [Documentation index / 文档索引](docs/README.md)

## Azure China VM SKU and quota report

Run the report with `Reader` access to the customer subscription. For one
subscription, use `SubscriptionId`:

```powershell
.\Export-AzureChinaVmSkuQuota.ps1 `
	-SubscriptionId "<customer-subscription-id>" `
	-Location "chinaeast2" `
	-OutputPath ".\customer-chinaeast2-vm-quota.csv"
```

To query multiple subscriptions, first create and optionally filter the
two-column subscription file, then pass it directly to the quota script:

```powershell
.\Export-AccessibleSubscriptions.ps1 `
	-OutputPath ".\subscriptions.csv"

.\Export-AzureChinaVmSkuQuota.ps1 `
	-InputPath ".\subscriptions.csv" `
	-Location "chinaeast2" `
	-OutputPath ".\all-subscriptions-chinaeast2-vm-quota.csv"
```

The subscriptions are queried sequentially and successful rows are combined in
one CSV. If a subscription fails, the script continues with the remaining
subscriptions, saves partial results, and exits with an error summary. Azure CLI
and Az PowerShell authentication are separate; the Az PowerShell account used by
the quota script must be able to access every subscription retained in the CSV.

## Resource Provider registration

Each inventory function is delivered as a standalone script; no repository
PowerShell module needs to be copied or imported. Preview an explicit provider
list before registration:

```powershell
.\Register-ResourceProviders.ps1 `
	-InputPath ".\subscriptions.csv" `
	-ProviderNamespace Microsoft.Compute, Microsoft.Network `
	-WhatIf
```

Remove `-WhatIf` to register the providers. Registration is a write operation
and prompts for confirmation by default. For an approved unattended run, add
`-Confirm:$false`. The caller needs
`Microsoft.Resources/subscriptions/providers/register/action` at subscription
scope, which is included in roles such as `Contributor` and `Owner`.

Only namespaces explicitly passed to `ProviderNamespace` are processed. The
script skips providers already registered, waits for each new registration, and
writes an audit CSV containing initial state, final state, action, status, and
error details.

The CSV contains one row per VM size available or restricted for that
subscription and region. It includes:

- VM family, vCPUs, memory, Premium SSD, accelerated networking, and SKU restrictions.
- VM-family and total-regional vCPU usage/limit/remaining quota.
- Estimates of additional deployable instances allowed by family quota and by the effective minimum of family and regional quota. Both estimates are zero when a location restriction makes that SKU unavailable to the subscription.
- Deployed counts for standalone VMs, ordinary VMSS, AKS VMSS/nodes, Azure Machine Learning `AmlCompute`, and other managed VMSS.

Rows are written only to the CSV by default. Add `-PassThru` when the same rows
should also be emitted to the PowerShell pipeline.

VM, VMSS, AKS nodes, and Azure Machine Learning compute created in the customer
subscription normally consume the same `Microsoft.Compute` total-regional and
VM-family vCPU quotas. The quota API values in the report are authoritative;
inventory is included to explain likely consumers and can differ because of
deallocation, autoscale, hidden managed resources, or recent changes.

Other services were intentionally not mixed into this report: Azure Batch,
Container Instances, Dedicated Hosts, and service-specific platforms can have
additional or separate quota models. Azure Databricks and similar managed
services can still consume customer-subscription Compute quota when they deploy
VMs/VMSS there; visible managed scale sets are shown under
`OtherManagedScaleSetCount` and `OtherManagedInstances`.

## Defaults

| Setting | Default |
| --- | --- |
| Destination subscription | `65a9c0da-4f85-47ba-ac0f-7401cbe43205` |
| AKS target VNet | `/subscriptions/65a9c0da-4f85-47ba-ac0f-7401cbe43205/resourceGroups/RGP-P0001-CN-AZ-FCS-0005/providers/Microsoft.Network/virtualNetworks/vNet-P0001-CN-AZ-FCS-0005` |
| AKS private DNS suffix | `.cx.prod.service.azk8s.cn` |

Override these only when needed.

## Permissions

- Source subscription: `Reader`; `Network Contributor` when updating private endpoint DNS zone groups.
- Destination subscription: `Private DNS Zone Contributor`; `Contributor` only when creating a missing resource group.

## Deploy

`Deploy-AzureChinaPrivateDnsAutomation.ps1` is the single deployment
entry point. It creates or updates one Automation Account and publishes all
three runbooks with the same managed identity and shared settings.

```powershell
.\Deploy-AzureChinaPrivateDnsAutomation.ps1 `
	-SubscriptionId "<automation-subscription-id>" `
	-ResourceGroupName "<automation-resource-group>" `
	-AutomationAccountName "<automation-account-name>" `
	-SourceSubscriptionId "<private-endpoint-subscription-id>" `
	-UserAssignedManagedIdentityResourceId "<existing-managed-identity-resource-id>" `
	-AssignRecommendedRoles `
	-GrantSourceNetworkContributor
```

The default identity type is `UserAssigned`. When updating an existing account,
pass its current user-assigned identity resource ID so the deployer reuses that
identity. Use `-ManagedIdentityType SystemAssigned` only when the account is
intentionally configured for a system-assigned identity.

The consolidated deployment uses these Automation variables:

| Setting | Automation variable |
| --- | --- |
| Tenant | `SyncPrivateEndpointPrivateDnsTenantId` |
| Source subscription | `SyncPrivateEndpointPrivateDnsSourceSubscriptionId` |
| Destination subscription | `SyncPrivateEndpointPrivateDnsDestinationSubscriptionId` |
| User-assigned identity client ID | `SyncPrivateEndpointPrivateDnsManagedIdentityAccountId` |
| Link destination DNS resource group (optional) | `LinkPrivateEndpointPrivateDnsDestinationZoneResourceGroupName` |
| AKS target VNet | `RepairAksPrivateDnsLinksTargetVirtualNetworkResourceId` |

The Link runbook still recognizes the old dedicated tenant, destination, and
identity variables for manually maintained accounts. The consolidated deployer
removes those legacy overrides so Link always uses the shared Sync values.

## Run

In the Azure China portal, open the Automation Account, select **Runbooks**, and start the required runbook:

| Runbook | Use it for |
| --- | --- |
| `Repair-AksPrivateDnsLinks` | Repairing AKS private DNS virtual network links. |
| `Sync-PrivateEndpointPrivateDns` | Handling other supported Azure China PaaS private endpoint DNS zones. |
| `Link-PrivateEndpointPrivateDns` | Linking one specified Private Endpoint when its source DNS record is absent or the bulk sync cannot infer it from records. |

Set `SourceSubscriptionId` to the subscription containing the source private endpoints or DNS zones. Run once per source subscription. By default, the sync runbook outputs changed rows only; set `IncludeNoChangeResults = True` for the full audit output.

## Local preview

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 -SourceSubscriptionId "<source-subscription-id>" -WhatIf
.\Link-PrivateEndpointPrivateDns.ps1 -PrivateEndpointResourceId "<private-endpoint-resource-id>" -WhatIf
.\Repair-AksPrivateDnsLinks.ps1 -SourceSubscriptionId "<source-subscription-id>" -WhatIf
```

## Sync behavior

- Processes supported Azure China private DNS zones; PostgreSQL is excluded.
- Links matching private endpoints to the destination zone, otherwise syncs A records directly.
- Removes only stale records previously managed by this script and preserves unmanaged IPs.
- Uses direct record sync across different Microsoft Entra tenants.

Azure Event Grid custom topics and domains use `privatelink.eventgrid.azure.cn` with the `topic` or `domain` group ID. System topics do not support private endpoints.

Azure AI Search and Cognitive Services Private Endpoints are supported using
the Azure China settings verified from live ARM `privateLinkResources`
metadata:

| Service | Resource type | Group ID | Private DNS zone |
| --- | --- | --- | --- |
| Azure AI Search | `Microsoft.Search/searchServices` | `searchService` | `privatelink.search.azure.cn` |
| Cognitive Services | `Microsoft.CognitiveServices/accounts` | `account` | `privatelink.cognitiveservices.azure.cn` |
| Azure Databricks | `Microsoft.Databricks/workspaces` | `databricks_ui_api`, `browser_authentication` | `privatelink.databricks.azure.cn` |

Azure China Databricks Private Link requires a Premium, custom VNet-injected
workspace. Standard non-VNet-injected workspaces reject Private Link with
`NonVNetInjectedWorkspaceNotSupported`. Both Databricks subresources use the
same private DNS zone. Databricks Private Endpoint NIC metadata can omit FQDNs,
so the targeted Link runbook infers the zone from resource type and group ID.

## Targeted Private Endpoint link

`Link-PrivateEndpointPrivateDns` derives the source subscription from
`PrivateEndpointResourceId`, infers the required Azure China Private DNS zone,
and updates the endpoint's private DNS zone group.

- It finds one exact inferred zone-name match in the destination scope.
- Without a destination resource group, a missing or duplicate zone fails safely.
- With a destination resource group, a missing zone can be created there.
- It updates the Private Endpoint DNS zone group; it does not create VNet links.
- `ZoneGroupNoChange` means the endpoint was already linked correctly.

When manually importing the runbook into an already configured Automation
Account, publish `Link-PrivateEndpointPrivateDns.ps1` as
`Link-PrivateEndpointPrivateDns`. Usually only `PrivateEndpointResourceId` is
needed at job start because the runbook falls back to the shared variables above.

## AKS repair

`Repair-AksPrivateDnsLinks` links source AKS private DNS zones ending with `.cx.prod.service.azk8s.cn` to the target VNet.

## Offline tests

The targeted Link tests require no Azure sign-in:

```powershell
.\Test-Link-PrivateEndpointPrivateDns.ps1
```

## Files

Production Automation runbooks keep their published names:

- `Sync-PrivateEndpointPrivateDns.ps1` — subscription-wide synchronization runbook.
- `Link-PrivateEndpointPrivateDns.ps1` — targeted Private Endpoint DNS link runbook.
- `Repair-AksPrivateDnsLinks.ps1` — AKS Private DNS VNet-link repair runbook.

Deployment and test helpers use role-based prefixes:

- `Deploy-AzureChinaPrivateDnsAutomation.ps1` — consolidated Automation Account deployer.
- `Deploy-ChinaPrivateEndpointTest.ps1` — deploys reusable Azure China Private Endpoint test resources.
- `Export-AzureChinaVmSkuQuota.ps1` — exports Azure China regional VM SKU availability, Compute quota, and deployed-capacity attribution to CSV.
- `Export-AccessibleSubscriptions.ps1` — exports enabled subscriptions from the current Azure CLI cloud to CSV.
- `Export-RegisteredResourceProviders.ps1` — exports registered resource providers for subscriptions listed in a CSV.
- `Register-ResourceProviders.ps1` — registers explicitly selected resource providers for subscriptions listed in a CSV and exports an audit report.
- `find-unused-pvcs.sh` — conservatively lists AKS PersistentVolumeClaims not referenced by active Pods or workload templates.
- `Test-Link-PrivateEndpointPrivateDns.ps1` — offline targeted-link tests.
- `Test-AmlPrivateEndpointSync.ps1` — Azure Machine Learning end-to-end synchronization test.
- `Test-RedisPrivateEndpointSync.ps1` — Redis end-to-end synchronization test.

## Troubleshooting

The runbooks emit timestamped tracing logs for:

- subscription selection
- zone and record counts
- private endpoint matching
- stale cleanup checks
- deleted/pruned destination record names and IPs
- operation summaries
- duration
- unhandled error details

Import or verify `Az.Accounts` and `Az.Resources` in the Automation Account before running the runbooks.
