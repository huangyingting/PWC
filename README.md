# PWC Azure China Private DNS Automation

Automates Private DNS operations for PWC on Azure China:

- `Sync-PrivateEndpointPrivateDns` syncs supported Private Endpoint DNS zones from a source subscription to the default destination subscription.
- `Link-PrivateEndpointPrivateDns` infers and links the required destination Private DNS zone for one Private Endpoint.
- `Repair-AksPrivateDnsLinks` links AKS private DNS zones to the default FCS VNet.

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
