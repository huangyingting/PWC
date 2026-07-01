# Private Endpoint DNS Tools

PowerShell utilities for testing and syncing Azure China Private Endpoint private DNS records.

## Scripts

- `Sync-PrivateEndpointPrivateDns.ps1` syncs supported Azure China private DNS from a source subscription to a destination subscription. By default it links matching source private endpoints to destination private DNS zones; it can fall back to direct A/TXT record sync.
- `Deploy-ChinaPrivateEndpointTest.ps1` deploys an Azure China test environment with Storage Blob, Storage File, and Key Vault private endpoints.

## Requirements

- PowerShell 5.1+ or PowerShell 7+
- `Az.Accounts` and `Az.Resources`

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.Resources -Scope CurrentUser
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

## Notes

- Use `-SkipSourcePrivateEndpointLink` to sync DNS records directly instead of updating private endpoint DNS zone groups.
- Missing destination private DNS zones are created by default; use `-SkipCreateMissingDestinationZones` to require them to already exist.
- AKS private DNS zones ending in `cx.prod.service.azk8s.cn` are included and synced directly.
- Test deployment details, including cleanup command, are written to `china-private-endpoint-test-deployment.json`.