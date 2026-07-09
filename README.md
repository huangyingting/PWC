# Private Endpoint DNS Sync

Sync Azure China Private Endpoint private DNS from a source subscription to a destination subscription using Azure Automation runbooks and an existing user-assigned managed identity.

## Step 1. Install Modules

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.Resources -Scope CurrentUser
Install-Module Az.Automation -Scope CurrentUser
```

If `Az.Automation` requires a newer `Az.Accounts` version, update the modules and open a new PowerShell session before running the deployment script.

## Step 2a. Deploy The Runbooks

Provide a default source subscription and existing user-assigned managed identity once during deployment. `DestinationSubscriptionId` defaults to `65a9c0da-4f85-47ba-ac0f-7401cbe43205`, the same subscription used by the AKS private DNS repair script. Pass `-DestinationSubscriptionId` only when you need to override that default. The deploy script saves provided defaults as Automation variables, so users do not need to enter them when starting the runbooks for the default source subscription.

```powershell
.\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
    -SubscriptionId "<automation-account-subscription-id>" `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Location "chinaeast2" `
    -SourceSubscriptionId "<source-subscription-id>" `
    -UserAssignedManagedIdentityResourceId "/subscriptions/<identity-subscription-id>/resourceGroups/<identity-resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity-name>"
```

`UserAssignedManagedIdentityResourceId` is the full Azure resource ID of the existing user-assigned managed identity. The runbooks use that identity's client ID for Azure login.

The deploy script publishes both Automation runbooks:

- `Sync-PrivateEndpointPrivateDns`
- `Repair-AksPrivateDnsLinks`

## Step 2b. Optional: Assign RBAC

Skip this step if the managed identity already has the required permissions. Run it only when you want the deploy script to grant the recommended roles to the same managed identity.

```powershell
.\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
    -SubscriptionId "<automation-account-subscription-id>" `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Location "chinaeast2" `
    -SourceSubscriptionId "<source-subscription-id>" `
    -UserAssignedManagedIdentityResourceId "/subscriptions/<identity-subscription-id>/resourceGroups/<identity-resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity-name>" `
    -AssignRecommendedRoles `
    -GrantSourceNetworkContributor `
    -GrantDestinationContributor
```

This grants `Reader` and optional `Network Contributor` on the source subscription, plus `Private DNS Zone Contributor` and optional `Contributor` on the destination subscription.

## Sync And Stale Destination DNS Cleanup

By default, `Sync-PrivateEndpointPrivateDns.ps1` does both modes in one run for all supported Azure China private DNS zones: when a source private endpoint can be matched, it links that private endpoint to the destination private DNS zone; when no source private endpoint can be matched, it directly syncs the DNS A record. It also cleans up destination A records previously synced directly by the script after the matching source record or source zone disappears.

Preview the sync and cleanup first:

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -WhatIf
```

Cleanup only affects destination records with the script's provenance TXT marker and matching `SourceSubscriptionId`, source zone, and source record metadata. If a destination A record also has unmanaged IP addresses, only the previously synced IP addresses recorded in provenance are removed. If source and destination tenants differ, the script automatically uses direct DNS record sync because private endpoint DNS zone group linking requires a single tenant.

Both sync and AKS repair scripts emit timestamped tracing logs for subscription selection, zone/record counts, cleanup checks, operation summaries, duration, and unhandled error details to simplify troubleshooting in local PowerShell and Azure Automation output.

## One-Time AKS DNS Link Repair

Use `Repair-AksPrivateDnsLinks.ps1` when AKS private DNS zones ending in `.cx.prod.service.azk8s.cn` need a virtual network link to the FCS VNet.

Preview the change first:

```powershell
.\Repair-AksPrivateDnsLinks.ps1 -WhatIf
```

Apply the link repair:

```powershell
.\Repair-AksPrivateDnsLinks.ps1
```

The script defaults to linking matching zones to:

```text
/subscriptions/65a9c0da-4f85-47ba-ac0f-7401cbe43205/resourceGroups/RGP-P0001-CN-AZ-FCS-0005/providers/Microsoft.Network/virtualNetworks/vNet-P0001-CN-AZ-FCS-0005
```

If private DNS zones live in a different source subscription from that VNet or from the saved default source subscription, pass the source subscription explicitly:

```powershell
.\Repair-AksPrivateDnsLinks.ps1 `
    -SourceSubscriptionId "<source-subscription-id>"
```

## Step 3a. Option: Start The Runbook In Azure Portal

1. Open the Automation Account in the Azure China portal.
2. Go to **Runbooks**.
3. Open `Sync-PrivateEndpointPrivateDns` for private endpoint DNS sync, or `Repair-AksPrivateDnsLinks` for AKS private DNS link repair.
4. Select **Start**.
5. Leave parameters blank to use the default source subscription saved during deployment.
6. If you need to run either `Sync-PrivateEndpointPrivateDns` or `Repair-AksPrivateDnsLinks` for a different source subscription, enter that subscription ID in `SourceSubscriptionId` before selecting **OK**.
7. For `Repair-AksPrivateDnsLinks`, only enter target VNet parameters when you need to override the default target VNet.

For multiple source subscriptions, start each relevant runbook once per source subscription. Each run can use a different `SourceSubscriptionId`; the destination subscription still defaults to `65a9c0da-4f85-47ba-ac0f-7401cbe43205` unless overridden.

## Step 3b. Option: Schedule The Sync Runbook

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

For multiple source subscriptions, register the sync runbook once per source subscription with a parameters hashtable:

```powershell
Register-AzAutomationScheduledRunbook `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -RunbookName "Sync-PrivateEndpointPrivateDns" `
    -ScheduleName "daily-private-endpoint-dns-sync" `
    -Parameters @{ SourceSubscriptionId = "<source-subscription-id>" }
```

## Notes

- The runbooks can start without parameters because deployment saves default `SourceSubscriptionId`, `DestinationSubscriptionId`, and `ManagedIdentityAccountId` as Automation variables, and the AKS repair runbook has built-in defaults for the target VNet. For multiple source subscriptions, override `SourceSubscriptionId` when starting or scheduling the relevant runbook.
- `GrantDestinationContributor` is only needed if the runbook may create missing destination resource groups.
- Import or verify `Az.Accounts` and `Az.Resources` in the Automation Account before running the runbook.
