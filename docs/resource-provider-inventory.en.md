# Subscription and Resource Provider Inventory

## Purpose

These scripts create the following CSV inventories and can register an
explicitly selected list of resource providers:

1. enabled subscriptions accessible to the current Azure CLI account; and
2. registered Azure resource providers in selected subscriptions.

The scripts use the Azure CLI's **current cloud**. They work with Azure China when the current cloud is `AzureChinaCloud`, and with global Azure when it is `AzureCloud`.

`Export-AccessibleSubscriptions.ps1`, `Export-RegisteredResourceProviders.ps1`,
and `Export-AzureChinaVmSkuQuota.ps1` are read-only.
`Register-ResourceProviders.ps1` is the only script that changes subscriptions,
and it registers only namespaces explicitly supplied through
`ProviderNamespace`; it never unregisters a provider.

## Files

| File | Purpose |
| --- | --- |
| `Export-AccessibleSubscriptions.ps1` | Refreshes and exports enabled subscriptions in the current Azure CLI cloud. |
| `Export-RegisteredResourceProviders.ps1` | Reads a two-column subscription CSV and exports registered providers for each subscription. |
| `Register-ResourceProviders.ps1` | Registers explicitly selected resource providers for subscriptions in a CSV and exports an audit report. |

Each functional unit is a standalone script. No shared PowerShell module from
this repository needs to be copied or imported.

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

### 4. Export VM SKU and quota for multiple subscriptions

The same `subscriptions.csv` can be passed directly to the VM SKU and quota
script. This script uses an Az PowerShell login rather than the Azure CLI login;
ensure that the current Az PowerShell account has `Reader` access to every
subscription retained in the CSV.

```powershell
.\Export-AzureChinaVmSkuQuota.ps1 `
    -InputPath .\subscriptions.csv `
    -Location chinaeast2 `
    -OutputPath .\all-subscriptions-chinaeast2-vm-quota.csv
```

Subscriptions are queried sequentially and successful results are combined in
one CSV. If a subscription fails, the script continues, saves partial results,
and exits with an error summary after processing the remaining subscriptions.
The batch `InputPath` mode and single-subscription `SubscriptionId` mode are
mutually exclusive.
If all CSV subscriptions belong to one tenant, `TenantId` can also be supplied.
For a cross-tenant list, omit it and ensure the required Az PowerShell
subscription contexts are accessible.

### 5. Register selected resource providers

Registration is a write operation. The caller needs
`Microsoft.Resources/subscriptions/providers/register/action` at subscription
scope; roles such as `Contributor` and `Owner` include this permission.

Preview the requested changes first:

```powershell
.\Register-ResourceProviders.ps1 `
    -InputPath .\subscriptions.csv `
    -ProviderNamespace Microsoft.Compute, Microsoft.Network `
    -WhatIf
```

Remove `-WhatIf` to perform registration. The script prompts for each change by
default; add `-Confirm:$false` only for an approved unattended run. It processes
only providers explicitly supplied to `ProviderNamespace`, skips providers that
are already registered, waits for new registrations, and records initial state,
final state, action, status, and error details in an audit CSV.

## Failure behavior

- Existing output files are never overwritten. Choose a new path or remove the old output intentionally.
- Input and output paths must be different.
- If one or more provider queries fail, the script continues with the remaining subscriptions, saves partial results and error details, and then exits with an error.
- If one or more registrations fail, the registration script continues with the remaining items, saves its audit report and error details, and then exits with an error.
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
