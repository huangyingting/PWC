# Private Endpoint DNS Tools

PowerShell utilities for testing and syncing Azure China Private Endpoint private DNS records.

## Scripts

- `Sync-PrivateEndpointPrivateDns.ps1` syncs supported Azure China private DNS from a source subscription to a destination subscription. By default it links matching source private endpoints to destination private DNS zones; it can fall back to direct A/TXT record sync.
- `Deploy-ChinaPrivateEndpointTest.ps1` deploys an Azure China test environment with Storage Blob, Storage File, and Key Vault private endpoints.
- `Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1` deploys the sync script as an Azure Automation runbook with a managed identity.

## Requirements

- PowerShell 5.1+ or PowerShell 7+
- `Az.Accounts` and `Az.Resources`
- Optional deployment helper: `Az.Automation`

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.Resources -Scope CurrentUser
Install-Module Az.Automation -Scope CurrentUser
```

## Usage

Preview an Azure China DNS sync:

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -WhatIf
```

Deploy Azure China test private endpoints:

```powershell
.\Deploy-ChinaPrivateEndpointTest.ps1 `
    -SubscriptionId "<subscription-id>"
```

## Azure Automation deployment

`Sync-PrivateEndpointPrivateDns.ps1` can run as an Azure Automation PowerShell
runbook by using the Automation Account managed identity instead of interactive
login.

Deploy or update the Automation Account and publish the runbook:

```powershell
.\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
    -SubscriptionId "<automation-account-subscription-id>" `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Location "chinaeast2"
```

Optionally let the deployment helper assign recommended RBAC permissions to the
Automation Account system-assigned managed identity for default zone-group
linking:

```powershell
.\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
    -SubscriptionId "<automation-account-subscription-id>" `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Location "chinaeast2" `
    -AssignRecommendedRoles `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -GrantSourceNetworkContributor `
    -GrantDestinationContributor
```

`-GrantDestinationContributor` is only needed if the runbook may create missing
destination resource groups. If all destination resource groups already exist,
you can omit it; the helper still assigns `Private DNS Zone Contributor` on the
destination subscription.

For the default private endpoint zone-group linking mode, the runbook only needs
the source and destination subscription IDs. Do not pass
`-SkipSourcePrivateEndpointLink`; the script will use the Automation Account
managed identity automatically when it runs inside Azure Automation.

```powershell
-SourceSubscriptionId "<source-subscription-id>"
-DestinationSubscriptionId "<destination-subscription-id>"
```

In this default mode, the script reads source Private DNS A records, matches
them to source Private Endpoints, and links the matching source Private
Endpoints to the destination Private DNS Zones by updating their
`privateDnsZoneGroups`. If a matching destination Private DNS Zone is missing,
the script creates it by default using the source Private DNS zone resource
group name.

For a user-assigned managed identity, also pass
`-ManagedIdentityAccountId "<user-assigned-managed-identity-client-id>"`.

### Trigger the runbook

To trigger the runbook from the Azure China portal:

1. Open the Automation Account.
2. Go to **Runbooks**.
3. Open `Sync-PrivateEndpointPrivateDns`.
4. Select **Start**.
5. Enter only these parameters:

```powershell
SourceSubscriptionId      <source-subscription-id>
DestinationSubscriptionId <destination-subscription-id>
```

To trigger the runbook from PowerShell:

```powershell
$parameters = @{
    SourceSubscriptionId      = "<source-subscription-id>"
    DestinationSubscriptionId = "<destination-subscription-id>"
}

$job = Start-AzAutomationRunbook `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Name "Sync-PrivateEndpointPrivateDns" `
    -Parameters $parameters

Get-AzAutomationJob `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Id $job.JobId
```

To run it on a schedule, create a schedule and link the runbook with the same
two parameters:

```powershell
$parameters = @{
    SourceSubscriptionId      = "<source-subscription-id>"
    DestinationSubscriptionId = "<destination-subscription-id>"
}

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
    -ScheduleName "daily-private-endpoint-dns-sync" `
    -Parameters $parameters
```

## Notes

- By default, the sync runbook uses private endpoint zone-group linking. The only required runbook parameters are `SourceSubscriptionId` and `DestinationSubscriptionId`.
- Use `-SkipSourcePrivateEndpointLink` only when you want to sync DNS records directly instead of updating private endpoint DNS zone groups.
- Existing same-name destination private DNS zones are reused. Missing zones are created by default using the source zone resource group name; use `-SkipCreateMissingDestinationZones` to require them to already exist.
- AKS private DNS zones ending in `cx.prod.service.azk8s.cn` are included and synced directly.
- In Azure Automation, import or verify `Az.Accounts` and `Az.Resources` in the Automation Account before scheduling the runbook. Module import can take a few minutes.
- For default private endpoint zone-group linking, the managed identity needs source `Reader`, `Network Contributor` on source private endpoints, and destination `Private DNS Zone Contributor`. If destination resource groups might be created automatically, it also needs destination `Contributor` at subscription scope.
- Test deployment details, including cleanup command, are written to `china-private-endpoint-test-deployment.json`.