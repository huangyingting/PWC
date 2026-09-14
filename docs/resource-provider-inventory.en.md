# Subscription and Resource Provider Inventory

## Purpose

These scripts create a read-only CSV inventory of:

1. enabled subscriptions accessible to the current Azure CLI account; and
2. registered Azure resource providers in selected subscriptions.

The scripts use the Azure CLI's **current cloud**. They work with Azure China when the current cloud is `AzureChinaCloud`, and with global Azure when it is `AzureCloud`.

No script registers or unregisters a resource provider and no Azure resource is changed.

## Files

| File | Purpose |
| --- | --- |
| `Export-AccessibleSubscriptions.ps1` | Refreshes and exports enabled subscriptions in the current Azure CLI cloud. |
| `Export-RegisteredResourceProviders.ps1` | Reads a two-column subscription CSV and exports registered providers for each subscription. |
| `ResourceProviderInventory.Common.psm1` | Shared validation, Azure CLI, path, and CSV helpers. Do not run this module directly. |

## Prerequisites

- PowerShell 7 or later.
- Azure CLI available as `az` on `PATH`.
- An authenticated Azure CLI session.
- Read access to the subscriptions being queried.

For Azure China, select the China cloud before signing in:

```powershell
az cloud set --name AzureChinaCloud
az login
az cloud show --query name --output tsv
```

The last command must return `AzureChinaCloud`. Changing the Azure CLI cloud usually requires signing in again.

## Recommended workflow

Run commands from the repository root.

### 1. Export accessible subscriptions

```powershell
.\Export-AccessibleSubscriptions.ps1 `
    -OutputPath .\subscriptions.csv
```

The output has exactly two columns:

| Column | Description |
| --- | --- |
| `SubscriptionName` | Azure subscription display name. |
| `SubscriptionId` | Subscription GUID. |

Only subscriptions in the current Azure CLI cloud with state `Enabled` are included. Duplicate subscription IDs are removed.

The script refreshes the Azure CLI account cache. On accounts with access to many tenants or subscriptions, this can take some time.

### 2. Review the subscription list

Open `subscriptions.csv` and remove subscriptions that should not be queried. Keep both columns, their order, and the header names unchanged.

Each subscription ID must appear exactly once. Blank names, malformed or empty GUIDs, additional columns, and duplicate IDs are rejected.

### 3. Export registered resource providers

```powershell
.\Export-RegisteredResourceProviders.ps1 `
    -InputPath .\subscriptions.csv `
    -OutputPath .\registered-resource-providers.csv
```

The script queries subscriptions sequentially and creates these columns:

| Column | Description |
| --- | --- |
| `SubscriptionName` | Name copied from the input CSV. |
| `SubscriptionId` | ID copied from the input CSV. |
| `ProviderNamespace` | Registered provider namespace, such as `Microsoft.Compute`. |
| `RegistrationState` | `Registered` for successful provider rows. |
| `QueryStatus` | `Success`, `NoRegisteredProviders`, or `Failed`. |
| `ErrorMessage` | Azure CLI error for a failed subscription; otherwise blank. |

## Failure behavior

- Existing output files are never overwritten. Choose a new path or remove the old output intentionally.
- Input and output paths must be different.
- If one or more provider queries fail, the script continues with the remaining subscriptions, saves partial results and error details, and then exits with an error.
- A subscription with no registered providers receives one row with `QueryStatus=NoRegisteredProviders` and blank provider fields.
- No output is created when the subscription export finds no enabled accessible subscriptions.

## Troubleshooting

### Azure CLI is not found

Install Azure CLI and confirm that `az` is available in the same PowerShell session.

### Results come from the wrong cloud

Check the current cloud:

```powershell
az cloud show --query name --output tsv
```

For Azure China, switch to `AzureChinaCloud` and sign in again before running the scripts.

### A subscription query fails

Confirm that the current account can read the subscription and that it belongs to the current Azure CLI cloud. Review `QueryStatus` and `ErrorMessage` in the partial output CSV.

### Output already exists

Use a different `-OutputPath`. The scripts deliberately avoid overwriting inventory evidence.

## Security and data handling

The CSV files contain subscription names and IDs. Treat them as internal inventory data and store or share them according to your organization's data-handling policy. Azure CLI authentication tokens are not written to the CSV.
