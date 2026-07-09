# Azure China Private DNS Automation

Automates Private DNS operations for Azure China:

- `Sync-PrivateEndpointPrivateDns` syncs supported Private Endpoint DNS zones from a source subscription to the default destination subscription.
- `Repair-AksPrivateDnsLinks` links AKS private DNS zones to the default FCS VNet.

Both runbooks are deployed by `Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1`.

## Defaults

| Setting | Default |
| --- | --- |
| Destination subscription | `65a9c0da-4f85-47ba-ac0f-7401cbe43205` |
| AKS target VNet | `/subscriptions/65a9c0da-4f85-47ba-ac0f-7401cbe43205/resourceGroups/RGP-P0001-CN-AZ-FCS-0005/providers/Microsoft.Network/virtualNetworks/vNet-P0001-CN-AZ-FCS-0005` |
| AKS private DNS suffix | `.cx.prod.service.azk8s.cn` |

Override these only when needed.

## 1. Install local modules

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.Resources -Scope CurrentUser
Install-Module Az.Automation -Scope CurrentUser
```

If `Az.Automation` requires a newer `Az.Accounts`, update the modules and start a new PowerShell session.

## 2. Deploy both Automation runbooks

```powershell
.\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
    -SubscriptionId "<automation-account-subscription-id>" `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Location "chinaeast2" `
    -SourceSubscriptionId "<default-source-subscription-id>" `
    -UserAssignedManagedIdentityResourceId "/subscriptions/<identity-subscription-id>/resourceGroups/<identity-resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity-name>"
```

This publishes:

- `Sync-PrivateEndpointPrivateDns`
- `Repair-AksPrivateDnsLinks`

The deploy script also saves Automation variables for the default source subscription, destination subscription, managed identity client ID, and AKS target VNet.

### Optional deployment overrides

```powershell
-DestinationSubscriptionId "<destination-subscription-id>"
-AksTargetVirtualNetworkResourceId "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/virtualNetworks/<vnet-name>"
```

## 3. Optional: assign recommended RBAC

Run this only if the managed identity does not already have the required permissions.

```powershell
.\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
    -SubscriptionId "<automation-account-subscription-id>" `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Location "chinaeast2" `
    -SourceSubscriptionId "<default-source-subscription-id>" `
    -UserAssignedManagedIdentityResourceId "/subscriptions/<identity-subscription-id>/resourceGroups/<identity-resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity-name>" `
    -AssignRecommendedRoles `
    -GrantSourceNetworkContributor `
    -GrantDestinationContributor
```

Recommended roles:

- Source subscription: `Reader`; optional `Network Contributor` for private endpoint zone-group linking.
- Destination subscription: `Private DNS Zone Contributor`; optional `Contributor` if the runbook may create missing resource groups.

## 4. Run from Azure Portal

1. Open the Automation Account in Azure China portal.
2. Go to **Runbooks**.
3. Start one of:
   - `Sync-PrivateEndpointPrivateDns`
   - `Repair-AksPrivateDnsLinks`
4. Leave parameters blank to use deployment defaults.
5. For another source subscription, enter `SourceSubscriptionId` before selecting **OK**.

For multiple source subscriptions, start the relevant runbook once per source subscription.

## 5. Schedule the sync runbook

```powershell
New-AzAutomationSchedule `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Name "daily-private-endpoint-dns-sync" `
    -StartTime (Get-Date).AddHours(1) `
    -DayInterval 1

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -RunbookName "Sync-PrivateEndpointPrivateDns" `
    -ScheduleName "daily-private-endpoint-dns-sync"
```

For multiple source subscriptions, register one scheduled run per source:

```powershell
Register-AzAutomationScheduledRunbook `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -RunbookName "Sync-PrivateEndpointPrivateDns" `
    -ScheduleName "daily-private-endpoint-dns-sync" `
    -Parameters @{ SourceSubscriptionId = "<source-subscription-id>" }
```

## What the sync runbook does

`Sync-PrivateEndpointPrivateDns` processes all supported Azure China private DNS zones.

For each source DNS A record:

1. If a matching source private endpoint exists, the runbook links that private endpoint to the destination private DNS zone.
2. If no matching private endpoint exists, the runbook directly syncs the destination A record.
3. For directly synced records, it writes a provenance TXT record.
4. If the source record or source zone later disappears, stale destination records/IPs previously managed by this script are removed.

Cleanup is safe by design: it only touches destination records with this script's provenance TXT marker and matching `SourceSubscriptionId`, source zone, and source record metadata. Unmanaged IPs are preserved.

If source and destination tenants differ, the runbook automatically uses direct DNS record sync because private endpoint zone-group linking requires a single tenant.

## What the AKS repair runbook does

`Repair-AksPrivateDnsLinks` scans AKS private DNS zones ending with `.cx.prod.service.azk8s.cn` in the source subscription and ensures each matching zone is linked to the target VNet.

Local preview:

```powershell
.\Repair-AksPrivateDnsLinks.ps1 -WhatIf
```

Override source subscription locally:

```powershell
.\Repair-AksPrivateDnsLinks.ps1 `
    -SourceSubscriptionId "<source-subscription-id>"
```

## Local sync preview

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -WhatIf
```

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
