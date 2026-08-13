# Targeted Private Endpoint DNS Link

Deploys one Azure Automation runbook for linking a supplied Azure China Private Endpoint to its inferred Private DNS zone or zones.

## Files

- `Link-PrivateEndpointPrivateDns.ps1` — targeted Automation runbook.
- `Deploy-Link-PrivateEndpointPrivateDnsAutomation.ps1` — dedicated Azure China deployment script.
- `Test-Link-PrivateEndpointPrivateDns.ps1` — offline inference and zone-group test harness.

## Prerequisites

- PowerShell modules `Az.Accounts`, `Az.Resources`, and `Az.Automation` installed locally.
- Access to all three subscriptions in the same Microsoft Entra tenant.
- Permission to create the Automation resource group/account and, unless skipped, assign roles.

## Deploy

Run from this folder:

```powershell
.\Deploy-Link-PrivateEndpointPrivateDnsAutomation.ps1 `
    -AutomationSubscriptionId "<automation-subscription-id>" `
    -AutomationResourceGroupName "<automation-resource-group>" `
    -AutomationAccountName "<automation-account-name>" `
    -SourceSubscriptionId "<private-endpoint-subscription-id>" `
    -DestinationSubscriptionId "<private-dns-subscription-id>"
```

The deployer uses a system-assigned managed identity, publishes only `Link-PrivateEndpointPrivateDns`, saves the destination subscription, and assigns the recommended roles.

The runbook scans all Private DNS zones in the destination subscription and selects one exact zone-name match. The deployer therefore assigns `Private DNS Zone Contributor` at destination-subscription scope. If the same zone name exists in multiple resource groups, rerun the deployment with `-DestinationPrivateDnsZoneResourceGroupName "<private-dns-resource-group>"` to restrict both the search and role assignment to that resource group. When this optional filter is used, that resource group must already exist.

If no matching zone exists, the runbook stops safely. To allow it to create a missing zone, configure `DestinationPrivateDnsZoneResourceGroupName`. Use `-SkipModuleImport`, `-SkipRunbookPublish`, or `-SkipRoleAssignments` only when those steps are managed separately.

## Run in the Azure portal

1. In the Azure China portal, open the Automation Account.
2. Open **Runbooks** > **Link-PrivateEndpointPrivateDns** > **Start**.
3. Enter only the full Private Endpoint resource ID in `PrivateEndpointResourceId`.
4. Leave the remaining inputs empty and start the job.

Example resource ID:

```text
/subscriptions/<source-subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/privateEndpoints/<private-endpoint-name>
```

## Output and verification

The job outputs one row per inferred zone, including `ZoneName`, `DestinationPrivateDnsZoneId`, `Operation`, and `Changed`. `ZoneGroupNoChange` means the endpoint was already linked correctly.

Verify the completed job output, then open the Private Endpoint's **DNS configuration** and confirm its DNS zone group references the destination zone. Azure should manage the endpoint A record in that zone.

## Local test

No Azure sign-in is required:

```powershell
.\Test-Link-PrivateEndpointPrivateDns.ps1
```
