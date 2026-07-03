# Private Endpoint DNS Sync

Sync Azure China Private Endpoint private DNS from a source subscription to a destination subscription using an Azure Automation runbook and an existing user-assigned managed identity.

## Step 1. Install Modules

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.Resources -Scope CurrentUser
Install-Module Az.Automation -Scope CurrentUser
```

## Step 2a. Deploy The Runbook

Provide the source subscription, destination subscription, and existing user-assigned managed identity once during deployment. The deploy script saves them as Automation variables, so users do not need to enter them when starting the runbook.

```powershell
.\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
    -SubscriptionId "<automation-account-subscription-id>" `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Location "chinaeast2" `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -UserAssignedManagedIdentityResourceId "/subscriptions/<identity-subscription-id>/resourceGroups/<identity-resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity-name>"
```

`UserAssignedManagedIdentityResourceId` is the full Azure resource ID of the existing user-assigned managed identity. The runbook uses that identity's client ID for Azure login.

## Step 2b. Optional: Assign RBAC

Skip this step if the managed identity already has the required permissions. Run it only when you want the deploy script to grant the recommended roles to the same managed identity.

```powershell
.\Deploy-SyncPrivateEndpointPrivateDnsAutomation.ps1 `
    -SubscriptionId "<automation-account-subscription-id>" `
    -ResourceGroupName "rg-dns-sync-automation" `
    -AutomationAccountName "aa-dns-sync-cn-prod" `
    -Location "chinaeast2" `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -UserAssignedManagedIdentityResourceId "/subscriptions/<identity-subscription-id>/resourceGroups/<identity-resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity-name>" `
    -AssignRecommendedRoles `
    -GrantSourceNetworkContributor `
    -GrantDestinationContributor
```

This grants `Reader` and optional `Network Contributor` on the source subscription, plus `Private DNS Zone Contributor` and optional `Contributor` on the destination subscription.

## Step 3a. Option: Start The Runbook In Azure Portal

1. Open the Automation Account in the Azure China portal.
2. Go to **Runbooks**.
3. Open `Sync-PrivateEndpointPrivateDns`.
4. Select **Start**.
5. Leave parameters blank and select **OK**.

## Step 3b. Option: Schedule The Runbook

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

## Notes

- The runbook starts without parameters because deployment saves `SourceSubscriptionId`, `DestinationSubscriptionId`, and `ManagedIdentityAccountId` as Automation variables.
- `GrantDestinationContributor` is only needed if the runbook may create missing destination resource groups.
- Import or verify `Az.Accounts` and `Az.Resources` in the Automation Account before running the runbook.
