# 订阅与资源提供程序清单

## 用途

这组脚本以只读方式生成以下 CSV 清单：

1. 当前 Azure CLI 账号可访问且状态为启用的订阅；
2. 所选订阅中已注册的 Azure 资源提供程序。

脚本使用 Azure CLI 的**当前云环境**。当前云为 `AzureChinaCloud` 时查询世纪互联运营的 Azure 中国；当前云为 `AzureCloud` 时查询全球 Azure。

脚本不会注册或取消注册资源提供程序，也不会修改任何 Azure 资源。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `Export-AccessibleSubscriptions.ps1` | 刷新并导出当前 Azure CLI 云环境中状态为启用的可访问订阅。 |
| `Export-RegisteredResourceProviders.ps1` | 读取两列订阅 CSV，并导出每个订阅中已注册的资源提供程序。 |
| `ResourceProviderInventory.Common.psm1` | 提供验证、Azure CLI 调用、路径和 CSV 导出等公共函数，请勿直接运行。 |

## 前提条件

- PowerShell 7 或更高版本。
- 已安装 Azure CLI，并且可通过 `PATH` 中的 `az` 命令访问。
- Azure CLI 已完成身份验证。
- 当前账号对待查询订阅具有读取权限。

使用 Azure 中国前，请先切换到中国云并登录：

```powershell
az cloud set --name AzureChinaCloud
az login
az cloud show --query name --output tsv
```

最后一条命令必须返回 `AzureChinaCloud`。切换 Azure CLI 云环境后，通常需要重新登录。

## 推荐操作流程

请在项目根目录运行以下命令。

### 1. 导出可访问订阅

```powershell
.\Export-AccessibleSubscriptions.ps1 `
    -OutputPath .\subscriptions.csv
```

输出文件仅包含两列：

| 列名 | 说明 |
| --- | --- |
| `SubscriptionName` | Azure 订阅显示名称。 |
| `SubscriptionId` | 订阅 GUID。 |

脚本只导出属于当前 Azure CLI 云环境且状态为 `Enabled` 的订阅，并自动去除重复的订阅 ID。

脚本会刷新 Azure CLI 账号缓存。如果当前账号可以访问多个租户或大量订阅，此步骤可能需要一些时间。

### 2. 检查订阅清单

打开 `subscriptions.csv`，删除不需要查询的订阅。请保留两列、列顺序以及原始表头名称。

每个订阅 ID 只能出现一次。脚本会拒绝空订阅名称、无效或全零 GUID、额外列以及重复订阅 ID。

### 3. 导出已注册资源提供程序

```powershell
.\Export-RegisteredResourceProviders.ps1 `
    -InputPath .\subscriptions.csv `
    -OutputPath .\registered-resource-providers.csv
```

脚本会按顺序逐个查询订阅，并生成以下列：

| 列名 | 说明 |
| --- | --- |
| `SubscriptionName` | 从输入 CSV 复制的订阅名称。 |
| `SubscriptionId` | 从输入 CSV 复制的订阅 ID。 |
| `ProviderNamespace` | 已注册资源提供程序命名空间，例如 `Microsoft.Compute`。 |
| `RegistrationState` | 成功查询的资源提供程序行固定为 `Registered`。 |
| `QueryStatus` | `Success`、`NoRegisteredProviders` 或 `Failed`。 |
| `ErrorMessage` | 订阅查询失败时的 Azure CLI 错误，否则为空。 |

## 失败处理

- 脚本不会覆盖现有输出文件。请指定新路径，或在确认后手动删除旧文件。
- 输入路径和输出路径不能指向同一个文件。
- 如果部分订阅查询失败，脚本会继续查询其余订阅，保存部分结果和错误详情，最后以错误状态退出。
- 如果订阅没有已注册的资源提供程序，输出中会保留一行，`QueryStatus=NoRegisteredProviders`，资源提供程序字段为空。
- 如果没有找到状态为启用的可访问订阅，订阅导出脚本不会创建空 CSV。

## 常见问题

### 找不到 Azure CLI

请安装 Azure CLI，并确认当前 PowerShell 会话可以执行 `az`。

### 查询结果来自错误的云环境

检查当前云环境：

```powershell
az cloud show --query name --output tsv
```

查询 Azure 中国时，请切换到 `AzureChinaCloud` 并重新登录，然后再运行脚本。

### 某个订阅查询失败

请确认当前账号对该订阅具有读取权限，并确认该订阅属于当前 Azure CLI 云环境。可以在部分输出 CSV 中查看 `QueryStatus` 和 `ErrorMessage`。

### 输出文件已存在

请使用不同的 `-OutputPath`。脚本有意避免覆盖已有的清单证据。

## 安全与数据处理

CSV 文件包含订阅名称和订阅 ID，应将其视为内部资产清单，并按照组织的数据处理策略进行存储和共享。Azure CLI 身份验证令牌不会写入 CSV。
