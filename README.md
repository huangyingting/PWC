# Azure Private Endpoint Private DNS Tools

PowerShell utilities for testing and synchronizing Azure Private Endpoint private DNS records across subscriptions. The scripts support both **Azure Global** (`AzureCloud`) and **Azure China** (`AzureChinaCloud`).

## Files

| File | Purpose |
| --- | --- |
| `Deploy-TestPrivateEndpoint.ps1` | Deploys a small test environment with a storage account, VNet, private endpoint, private DNS zone, and VNet link. Useful for validating private endpoint DNS behavior. |
| `Deploy-ChinaPrivateEndpointTest.ps1` | Deploys three Azure China test private endpoints for Storage Blob, Storage File, and Key Vault, each with its matching private DNS zone. |
| `Sync-PrivateEndpointPrivateDns.ps1` | Synchronizes Azure PaaS Private Link private DNS by linking matching source private endpoints to destination private DNS zones by default, with direct A/TXT record sync as a fallback. |
| `test-private-endpoint-deployment.json` | Generated output from `Deploy-TestPrivateEndpoint.ps1` containing resource names, endpoint details, and cleanup command. |
| `china-private-endpoint-test-deployment.json` | Generated output from `Deploy-ChinaPrivateEndpointTest.ps1` containing the Azure China test resource names, private endpoint IPs, DNS zones, and cleanup command. |

## Prerequisites

- PowerShell 5.1+ or PowerShell 7+
- Azure PowerShell modules:
  - `Az.Accounts`
  - `Az.Resources`
- Azure permissions appropriate to the operation, described below

Install the required modules if needed:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.Resources -Scope CurrentUser
```

## Azure cloud support

Both scripts support:

- `AzureCloud` for Azure Global
- `AzureChinaCloud` for Azure China

For Azure China, pass `-SourceEnvironment AzureChinaCloud` or `-Environment AzureChinaCloud` depending on the script.

## Deploy test private endpoint resources

`Deploy-TestPrivateEndpoint.ps1` creates a test Blob private endpoint environment.

### What it deploys

- Resource group
- Virtual network `vnet-pe-test`
- Subnet `snet-private-endpoints`
- Storage account
- Blob private endpoint `pe-blob-test`
- Private DNS zone
- Private DNS zone VNet link
- Private DNS zone group on the private endpoint

### Azure Global example

```powershell
.\Deploy-TestPrivateEndpoint.ps1 `
    -SubscriptionId "<subscription-id>"
```

Default Azure Global settings:

| Setting | Value |
| --- | --- |
| Environment | `AzureCloud` |
| Default location | `eastus` |
| Blob endpoint suffix | `blob.core.windows.net` |
| Private DNS zone | `privatelink.blob.core.windows.net` |

### Azure China example

```powershell
.\Deploy-TestPrivateEndpoint.ps1 `
    -SubscriptionId "<china-subscription-id>" `
    -Environment AzureChinaCloud
```

Default Azure China settings:

| Setting | Value |
| --- | --- |
| Environment | `AzureChinaCloud` |
| Default location | `chinaeast2` |
| Blob endpoint suffix | `blob.core.chinacloudapi.cn` |
| Private DNS zone | `privatelink.blob.core.chinacloudapi.cn` |

### Azure China multi-endpoint test deployment

Use `Deploy-ChinaPrivateEndpointTest.ps1` when you need several Azure China private endpoint types for sync testing.

```powershell
.\Deploy-ChinaPrivateEndpointTest.ps1 `
    -SubscriptionId "<china-subscription-id>"
```

It deploys:

| Private endpoint | Group ID | Private DNS zone |
| --- | --- | --- |
| `pe-storage-blob-test` | `blob` | `privatelink.blob.core.chinacloudapi.cn` |
| `pe-storage-file-test` | `file` | `privatelink.file.core.chinacloudapi.cn` |
| `pe-keyvault-test` | `vault` | `privatelink.vaultcore.azure.cn` |

The script writes deployment details to:

```text
china-private-endpoint-test-deployment.json
```

### Optional deployment parameters

| Parameter | Description |
| --- | --- |
| `-SubscriptionId` | Target subscription ID. |
| `-Environment` | Azure cloud: `AzureCloud` or `AzureChinaCloud`. Defaults to `AzureCloud`. |
| `-Location` | Azure region. If omitted, the script uses a cloud-specific default. |
| `-TenantId` | Optional tenant ID for authentication/context selection. |
| `-NameSuffix` | Optional suffix for generated resource names. Must contain at least 3 lowercase letters or numbers after normalization. |
| `-ResourceGroupName` | Optional resource group name. Defaults to `rg-pe-test-<suffix>`. |

### Deployment output

The deployment script writes details to:

```text
test-private-endpoint-deployment.json
```

The output includes:

- Subscription ID
- Azure environment
- Resource group name
- Storage account name
- Blob endpoint
- Private endpoint name and IP
- Private DNS zone name
- Cleanup command

### Cleanup

Use the generated cleanup command from `test-private-endpoint-deployment.json`, for example:

```powershell
Remove-AzResourceGroup -Name "<resource-group-name>" -Force
```

## Sync private endpoint private DNS records

`Sync-PrivateEndpointPrivateDns.ps1` syncs private DNS from source private DNS zones to matching destination private DNS zones. By default, it updates source private endpoints' `privateDnsZoneGroups` so Azure manages destination A records. If no matching source private endpoint can be found, or if `-SkipSourcePrivateEndpointLink` is used, it falls back to direct A record sync and writes same-name provenance TXT records by default.

The script is intentionally scoped to **Azure PaaS Private Link private DNS zones** only. Custom zones and non-PaaS zones are ignored or rejected.

### Key behavior

- Reads private DNS zones from the source subscription.
- Filters zones through a built-in Azure PaaS Private Link allow-list.
- Reads A records from selected source zones.
- Finds matching private DNS zones by exact zone name in the destination subscription.
- Creates missing destination private DNS zones by default.
- Updates source private endpoint `privateDnsZoneGroups` by default so Azure manages destination A records.
- Falls back to creating, merging, or replacing destination A record sets only when no matching source private endpoint can be linked, or when `-SkipSourcePrivateEndpointLink` is used.
- Creates or updates a same-name destination TXT record with sync provenance metadata when direct A record sync is used.
- Supports `-WhatIf` for safe previews.
- Optionally removes source A records after copying.
- By default, finds source private endpoints that correspond to DNS records and links them to destination private DNS zones.
- Use `-SkipSourcePrivateEndpointLink` to sync DNS records only.

### Default merge behavior

When direct A record sync is used, if a destination A record set already exists, source IP addresses are merged into the existing set.

Use `-ReplaceExisting` if manually synced destination record sets should exactly match the source record set.

### Provenance TXT records

When the script uses direct A record sync, every synced destination A record also gets a TXT record at the same record name by default. This TXT record records where the A record was synced from.

When a record is handled through private endpoint `privateDnsZoneGroups`, the script does **not** create provenance TXT records by default. That keeps Azure's private endpoint lifecycle management clean: Azure owns the A record and can remove it when the private endpoint or zone group is deleted.

The managed TXT value includes:

- `sync-private-endpoint-private-dns:v1`
- Source subscription ID
- Source private DNS zone resource group name
- Source private DNS zone name
- Source record name
- Source IPv4 addresses
- Script marker: `managedBy=Sync-PrivateEndpointPrivateDns.ps1`

Existing TXT values that do not start with the managed marker are preserved.

Example TXT values for `stpecnxxxx.privatelink.blob.core.chinacloudapi.cn`:

```text
sync-private-endpoint-private-dns:v1
sourceSubscriptionId=4157b2d1-e1d0-4c44-8ef3-2bcda2f98d56
sourceResourceGroups=rg-pe-cn-test-example
sourceZone=privatelink.blob.core.chinacloudapi.cn
sourceRecord=stpecnxxxx
sourceIPv4Addresses=10.83.1.6
managedBy=Sync-PrivateEndpointPrivateDns.ps1
```

Use `-SkipProvenanceTxtRecord` to direct-sync A records without creating or updating provenance TXT records.

### Private endpoint deletion behavior

Azure can automatically remove A records that are created and owned by a private endpoint `privateDnsZoneGroup` when that private endpoint or zone group is deleted.

The default script behavior uses this Azure-managed path whenever it can match a source private endpoint. In that case, the script updates `privateDnsZoneGroups` and does not manually write the destination A/TXT record.

The script only writes destination DNS records directly when it cannot safely link a source private endpoint, or when you run with `-SkipSourcePrivateEndpointLink`:

- Destination A records are created, merged, or replaced by the script.
- Provenance TXT records are created or updated by the script.

Those script-managed records are not guaranteed to be automatically deleted when the source private endpoint is deleted. Treat them as synchronized records that need a future sync cleanup flow or manual cleanup if the source private endpoint is removed.

In short:

| Record source | Deleted automatically with private endpoint? |
| --- | --- |
| A record created solely by Azure private DNS zone group | Yes, Azure normally removes it with the private endpoint or zone group. |
| A record manually written by this script | No reliable automatic deletion. |
| TXT provenance record written by this script | No. |

### Destination zone creation behavior

The script scans the destination subscription for matching private DNS zones by exact zone name.

If a matching destination zone already exists:

- The script uses the existing zone and its resource group.
- If multiple destination zones with the same name exist in different resource groups, the script stops because the target is ambiguous.

If a matching destination zone does not exist:

- The script creates it by default.
- Private DNS Zone location is always `global`.
- The destination resource group name defaults to the source private DNS zone resource group name.
- If that resource group does not exist in the destination subscription, the script creates it.
- The destination resource group location defaults to the source private DNS zone resource group's location.
- If the source resource group location cannot be read, the fallback is `eastus` for `AzureCloud` and `chinaeast2` for `AzureChinaCloud`.

You can override the resource group used for newly created destination zones:

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -DestinationPrivateDnsZoneResourceGroupName "rg-central-private-dns" `
    -DestinationResourceGroupLocation "chinaeast2" `
    -WhatIf
```

You can require destination zones to already exist:

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -SkipCreateMissingDestinationZones `
    -WhatIf
```

## Basic sync examples

### Preview Azure Global sync

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -WhatIf
```

### Apply Azure Global sync

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>"
```

### Preview Azure China sync

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-china-subscription-id>" `
    -DestinationSubscriptionId "<destination-china-subscription-id>" `
    -SourceEnvironment AzureChinaCloud `
    -WhatIf
```

If `-DestinationEnvironment` is omitted, it defaults to `-SourceEnvironment`.

### Sync selected zones only

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -ZoneName "privatelink.blob.core.windows.net", "privatelink.database.windows.net" `
    -WhatIf
```

For Azure China, use Azure China zone names, for example:

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-china-subscription-id>" `
    -DestinationSubscriptionId "<destination-china-subscription-id>" `
    -SourceEnvironment AzureChinaCloud `
    -ZoneName "privatelink.blob.core.chinacloudapi.cn" `
    -WhatIf
```

## Link source private endpoints to destination private DNS zones

This is now the default behavior. The script finds the source private endpoint that corresponds to each DNS A record and adds the matching destination private DNS zone to that source private endpoint's `privateDnsZoneGroups`. Azure then manages the A record in the destination private DNS zone.

This is useful when records were copied to a central/private DNS subscription and you want the source private endpoint to reference that destination private DNS zone through a private DNS zone group.

The older `-LinkSourcePrivateEndpointsToDestinationZones` switch is still accepted for compatibility, but it is no longer required.

Use `-SkipSourcePrivateEndpointLink` when you want to sync DNS records only without updating private endpoint zone groups.

### Preview linking

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -WhatIf
```

### Apply linking

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>"
```

### Sync DNS records only

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -SkipSourcePrivateEndpointLink `
    -WhatIf
```

### Custom private DNS zone group name

The default private DNS zone group name is `default`.

```powershell
.\Sync-PrivateEndpointPrivateDns.ps1 `
    -SourceSubscriptionId "<source-subscription-id>" `
    -DestinationSubscriptionId "<destination-subscription-id>" `
    -PrivateDnsZoneGroupName "default" `
    -WhatIf
```

### How private endpoints are matched

The script attempts to match each source DNS A record to source private endpoints by using private endpoint DNS metadata.

Match order:

1. **FQDN + IP match** using DNS record FQDN and A record IP.
2. **FQDN-only match** if FQDN matches but IP metadata differs or is unavailable.
3. **Unique IP fallback** if exactly one private endpoint has that IP.
4. **Ambiguous IP matches are skipped** when multiple private endpoints share the same IP match candidate.

The result output includes the matched source private endpoint names, IDs, match types, and private DNS zone group operations.

## Sync script parameters

| Parameter | Description |
| --- | --- |
| `-SourceSubscriptionId` | Source subscription containing private DNS zones and records. Required. |
| `-DestinationSubscriptionId` | Destination subscription containing matching private DNS zones. Required. |
| `-SourceEnvironment` | Source Azure cloud: `AzureCloud` or `AzureChinaCloud`. Defaults to `AzureCloud`. |
| `-DestinationEnvironment` | Destination Azure cloud. Defaults to `-SourceEnvironment`. |
| `-SourceTenantId` | Optional source tenant ID. |
| `-DestinationTenantId` | Optional destination tenant ID. |
| `-DestinationPrivateDnsZoneResourceGroupName` | Optional override resource group for newly created destination private DNS zones. If omitted, the source zone resource group name is used. |
| `-DestinationResourceGroupLocation` | Optional location for newly created destination resource groups. If omitted, the source private DNS zone resource group's location is used when available; otherwise the fallback is `eastus` for Azure Global and `chinaeast2` for Azure China. |
| `-ZoneName` | Optional list of zone names to sync. Names must be in the built-in Azure PaaS allow-list for the selected cloud. |
| `-IncludeAllPrivateDnsZones` | Backward-compatible switch. It is ignored; the script only syncs supported Azure PaaS Private Link zones. |
| `-SkipCreateMissingDestinationZones` | Do not create missing destination private DNS zones. Missing zones are skipped. |
| `-SkipProvenanceTxtRecord` | Do not create or update same-name provenance TXT records in destination private DNS zones. |
| `-IncludeApex` | Include apex `@` A records. By default, apex records are skipped. |
| `-ReplaceExisting` | Replace destination A record sets instead of merging source IPs into existing records when direct A record sync is used. |
| `-RemoveSourceAfterCopy` | Delete source A record sets after successful copy. Use carefully. |
| `-LinkSourcePrivateEndpointsToDestinationZones` | Backward-compatible switch. Linking is enabled by default, so this switch is no longer required. |
| `-SkipSourcePrivateEndpointLink` | Always use direct DNS record sync and do not update source private endpoint private DNS zone groups. |
| `-PrivateDnsZoneGroupName` | Private DNS zone group name used for default private endpoint linking. Defaults to `default`. |
| `-Ttl` | Optional TTL override for destination record sets. |
| `-WhatIf` | Preview operations without writing changes. |

## Supported private DNS zones

The sync script uses built-in allow-lists for Azure PaaS Private Link private DNS zones.

### Azure Global

The `AzureCloud` allow-list includes common Azure PaaS Private Link zones such as Storage, SQL, Cosmos DB, Key Vault, Service Bus, Event Grid, Redis, App Service, Container Registry, App Configuration, API Management, Search, AI services, Data Factory, Synapse, Azure Monitor, Automation, SignalR, IoT, Purview, HDInsight, Container Apps, AKS, Batch, and Backup-related zones.

### Azure China

The `AzureChinaCloud` allow-list is aligned with the official Azure China Private Endpoint DNS zone table and is intentionally smaller than Azure Global.

Examples include:

- `privatelink.blob.core.chinacloudapi.cn`
- `privatelink.file.core.chinacloudapi.cn`
- `privatelink.queue.core.chinacloudapi.cn`
- `privatelink.table.core.chinacloudapi.cn`
- `privatelink.dfs.core.chinacloudapi.cn`
- `privatelink.database.chinacloudapi.cn`
- `privatelink.postgres.database.chinacloudapi.cn`
- `privatelink.mysql.database.chinacloudapi.cn`
- `privatelink.mariadb.database.chinacloudapi.cn`
- `privatelink.documents.azure.cn`
- `privatelink.mongo.cosmos.azure.cn`
- `privatelink.cassandra.cosmos.azure.cn`
- `privatelink.gremlin.cosmos.azure.cn`
- `privatelink.table.cosmos.azure.cn`
- `privatelink.servicebus.chinacloudapi.cn`
- `privatelink.redis.cache.chinacloudapi.cn`
- `privatelink.vaultcore.azure.cn`
- `privatelink.chinacloudsites.cn`
- `privatelink.signalr.azure.cn`
- `privatelink.datafactory.azure.cn`
- `privatelink.adf.azure.cn`
- `privatelink.azure-automation.cn`
- `privatelink.azure-devices.cn`
- `privatelink.azure-devices-provisioning.cn`
- `privatelink.azurehdinsight.cn`
- `privatelink.<region>.kusto.windows.cn`
- `privatelink.batch.chinacloudapi.cn`
- `privatelink-global.wvd.azure.cn`
- `privatelink.wvd.azure.cn`

If a zone is not in the allow-list, the script ignores it during discovery. If you explicitly pass an unsupported zone with `-ZoneName`, the script throws an error.

## Required permissions

### Default sync

Source subscription:

- Reader on private DNS zones
- Network Contributor on source private endpoints, because private endpoint linking is enabled by default

Destination subscription:

- Private DNS Zone Contributor on destination private DNS zones
- Permission to create destination resource groups when missing destination zones are auto-created in source-named resource groups
- Read access to destination private DNS zones so their resource IDs can be linked

### DNS record sync only

When using `-SkipSourcePrivateEndpointLink`, source private endpoint write permissions are not required.

Source subscription:

- Reader on private DNS zones

Destination subscription:

- Private DNS Zone Contributor on destination private DNS zones
- Permission to create destination private DNS zones unless `-SkipCreateMissingDestinationZones` is used

### Remove source records

When using `-RemoveSourceAfterCopy`, source subscription also requires:

- Private DNS Zone Contributor on source private DNS zones

## Safety notes

- Always run with `-WhatIf` first.
- Destination zones are created by default when missing. Use `-SkipCreateMissingDestinationZones` to require pre-created zones.
- The sync script updates private endpoint zone groups by default so Azure owns destination A records.
- Direct A record sync and provenance TXT records are used as fallback when no source private endpoint can be linked, or when `-SkipSourcePrivateEndpointLink` is used.
- Use `-SkipProvenanceTxtRecord` if you do not want provenance TXT records during direct record sync.
- By default, apex `@` records are skipped unless `-IncludeApex` is specified.
- `-RemoveSourceAfterCopy` deletes source records after copying. Use with caution.
- Private endpoint linking is enabled by default and updates source private endpoint resources.
- Use `-SkipSourcePrivateEndpointLink` if you only want to sync DNS A records.
- Cross-cloud linking is not supported. Source and destination environments must match when linking private endpoints to destination zones.
- If both source and destination tenant IDs are provided for linking, they must be the same.

## Troubleshooting

### No source private DNS zones matched

The source subscription may not contain supported Azure PaaS Private Link private DNS zones, or the selected `-ZoneName` values may not match existing zones.

### No records were synced

Check that matching destination private DNS zones already exist and that the source zones contain A records.

### Explicit ZoneName is rejected

The specified zone is not in the built-in Azure PaaS allow-list for the selected cloud environment.

### No source private endpoint matched a DNS record

The DNS record may be stale, manually created, or its private endpoint DNS metadata may not include matching FQDN/IP information. The record can still be synced, but no private endpoint DNS zone group link is added for that record.

### Ambiguous private endpoint match

Multiple source private endpoints matched by IP only. The script skips linking for that record to avoid attaching the wrong private DNS zone.

### Provenance TXT record overwrote custom TXT metadata

The script preserves TXT values that do not start with `sync-private-endpoint-private-dns:v1`. If you do not want any provenance TXT updates, run with `-SkipProvenanceTxtRecord`.

## Validation commands

You can validate PowerShell syntax without running Azure operations:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\Sync-PrivateEndpointPrivateDns.ps1', [ref]$null, [ref]$errors) | Out-Null
if ($errors) { $errors | Format-List * } else { 'PowerShell parse OK' }
```

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\Deploy-TestPrivateEndpoint.ps1', [ref]$null, [ref]$errors) | Out-Null
if ($errors) { $errors | Format-List * } else { 'PowerShell parse OK' }
```