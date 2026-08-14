# Targeted Private Endpoint DNS Link

Azure China Automation runbook that infers the required Private DNS zone and links it to one Private Endpoint.

## Quick start: existing configured account

You do **not** need a new Automation Account or the deployment script when the existing account already has:

- a system-assigned managed identity;
- `Az.Accounts` and `Az.Resources` in the runbook runtime;
- **Reader** and **Network Contributor** on the Private Endpoint subscription; and
- **Private DNS Zone Contributor** on the destination subscription or Private DNS resource group.

To install or update the runbook:

1. In the Azure China portal, open the existing Automation Account.
2. Create or open a PowerShell runbook named `Link-PrivateEndpointPrivateDns`.
3. Paste the complete contents of `Link-PrivateEndpointPrivateDns.ps1`.
4. Select **Save**, then **Publish**.
5. Select **Start** and enter `PrivateEndpointResourceId`.

Example:

```text
/subscriptions/<source-subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/privateEndpoints/<private-endpoint-name>
```

For the destination, use either runbook inputs or these unencrypted String Automation variables:

| Runbook input | Automation variable | Required |
|---|---|---|
| `DestinationSubscriptionId` | `LinkPrivateEndpointPrivateDnsDestinationSubscriptionId` | Yes |
| `DestinationPrivateDnsZoneResourceGroupName` | `LinkPrivateEndpointPrivateDnsDestinationZoneResourceGroupName` | No |

If the variables already exist, enter only `PrivateEndpointResourceId` and leave the other inputs empty.

> The Automation Account must be in Azure China, and all involved subscriptions must be in the same Microsoft Entra tenant.

## Automated setup or repair

Use the deployer only if the account is new, is missing configuration, or should be configured automatically.

Local requirements: `Az.Accounts`, `Az.Resources`, and `Az.Automation`, plus permission to update the account and assign roles.

```powershell
.\Deploy-Link-PrivateEndpointPrivateDnsAutomation.ps1 `
    -AutomationSubscriptionId "<automation-subscription-id>" `
    -AutomationResourceGroupName "<automation-resource-group>" `
    -AutomationAccountName "<automation-account-name>" `
    -SourceSubscriptionId "<private-endpoint-subscription-id>" `
    -DestinationSubscriptionId "<private-dns-subscription-id>"
```

The deployer reuses an account with that exact subscription, resource group, and name; otherwise, it creates one. It configures the identity, modules, runbook, variables, and missing role assignments.

It does not remove unrelated account resources, but it overwrites the `Link-PrivateEndpointPrivateDns` runbook and its dedicated variables. Add `-DestinationPrivateDnsZoneResourceGroupName "<private-dns-resource-group>"` to limit zone lookup and destination RBAC to one existing resource group.

## Behavior and verification

- The runbook derives the source subscription from `PrivateEndpointResourceId`.
- It finds one exact inferred zone-name match in the destination scope.
- Without a destination resource group, a missing or duplicate zone causes a safe failure.
- With a destination resource group, a missing zone can be created there.
- It updates the Private Endpoint DNS zone group; it does not create VNet links.

After the job completes, check its output and the Private Endpoint's **DNS configuration**. `ZoneGroupNoChange` means it was already linked correctly.

## Files

- `Link-PrivateEndpointPrivateDns.ps1` — Automation runbook.
- `Deploy-Link-PrivateEndpointPrivateDnsAutomation.ps1` — optional setup deployer.
- `Test-Link-PrivateEndpointPrivateDns.ps1` — offline tests.

Run the tests without Azure sign-in:

```powershell
.\Test-Link-PrivateEndpointPrivateDns.ps1
```
