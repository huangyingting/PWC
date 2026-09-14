# 最新 Resource Provider 与 VM Quota 脚本使用说明

**主题：最新 Resource Provider 与 VM Quota 脚本使用说明**

各位好，

最新脚本已更新。每个功能块均为独立 PowerShell 7 脚本，无需复制或导入额外的项目模块。

## 1. 导出订阅

请先安装 Azure CLI，切换到 Azure 中国云并登录：

```powershell
az cloud set --name AzureChinaCloud
az login
```

导出当前账号可访问的订阅：

```powershell
.\Export-AccessibleSubscriptions.ps1 `
    -OutputPath .\subscriptions.csv
```

可以打开 `subscriptions.csv` 删除不需要处理的订阅，但请保留 `SubscriptionName` 和 `SubscriptionId` 两列。

## 2. 导出已注册的 Resource Provider

```powershell
.\Export-RegisteredResourceProviders.ps1 `
    -InputPath .\subscriptions.csv `
    -OutputPath .\registered-resource-providers.csv
```

## 3. 注册指定的 Resource Provider

注册属于写操作。账号需要在订阅范围具有 `Microsoft.Resources/subscriptions/providers/register/action` 权限。

请先使用 `-WhatIf` 预览：

```powershell
.\Register-ResourceProviders.ps1 `
    -InputPath .\subscriptions.csv `
    -ProviderNamespace Microsoft.Compute, Microsoft.Network `
    -WhatIf
```

确认无误后移除 `-WhatIf` 执行注册。脚本只注册通过 `-ProviderNamespace` 明确指定的 Provider，跳过已注册项目，等待注册完成，并生成审计 CSV。脚本默认逐项请求确认；已审批的无人值守操作可以添加 `-Confirm:$false`。

## 4. 批量导出 VM SKU 与 Quota

请确保已安装 `Az.Accounts` 和 `Az.Resources` 模块，并且当前 Az PowerShell 账号对 CSV 中的订阅具有 `Reader` 权限：

```powershell
.\Export-AzureChinaVmSkuQuota.ps1 `
    -InputPath .\subscriptions.csv `
    -Location chinaeast2 `
    -OutputPath .\all-subscriptions-chinaeast2-vm-quota.csv
```

脚本会逐个遍历订阅，并将成功结果合并到一个 CSV。报告包含指定区域的 VM SKU 可用性、系列及区域 vCPU Quota，以及 VM、VMSS、AKS 和 Azure Machine Learning 的部署情况。查询其他区域时，请将 `chinaeast2` 替换为对应的 Azure 中国区域名称。

如有问题，请将脚本输出的错误信息一并提供。

谢谢！
