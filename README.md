# PWC Azure China Private DNS Automation

Automates Private DNS operations for PWC on Azure China:

- `Sync-PrivateEndpointPrivateDns` syncs supported Private Endpoint DNS zones from a source subscription to the default destination subscription.
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

## Run

In the Azure China portal, open the Automation Account, select **Runbooks**, and start the required runbook:

| Runbook | Use it for |
| --- | --- |
| `Repair-AksPrivateDnsLinks` | Repairing AKS private DNS virtual network links. |
| `Sync-PrivateEndpointPrivateDns` | Handling other supported Azure China PaaS private endpoint DNS zones. |

Set `SourceSubscriptionId` to the subscription containing the source private endpoints or DNS zones. Run once per source subscription. By default, the sync runbook outputs changed rows only; set `IncludeNoChangeResults = True` for the full audit output.

## Local preview

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 -SourceSubscriptionId "<source-subscription-id>" -WhatIf
.\Repair-AksPrivateDnsLinks.ps1 -SourceSubscriptionId "<source-subscription-id>" -WhatIf
```

## Sync behavior

- Processes supported Azure China private DNS zones; PostgreSQL is excluded.
- Links matching private endpoints to the destination zone, otherwise syncs A records directly.
- Removes only stale records previously managed by this script and preserves unmanaged IPs.
- Uses direct record sync across different Microsoft Entra tenants.

Azure Event Grid custom topics and domains use `privatelink.eventgrid.azure.cn` with the `topic` or `domain` group ID. System topics do not support private endpoints.

## AKS repair

`Repair-AksPrivateDnsLinks` links source AKS private DNS zones ending with `.cx.prod.service.azk8s.cn` to the target VNet.

## Troubleshooting

Both runbooks emit timestamped tracing logs for:

- subscription selection
- zone and record counts
- private endpoint matching
- stale cleanup checks
- deleted/pruned destination record names and IPs
- operation summaries
- duration
- unhandled error details

Import or verify `Az.Accounts` and `Az.Resources` in the Automation Account before running the runbooks.
