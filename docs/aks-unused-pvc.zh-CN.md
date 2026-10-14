# 查找并安全清理 AKS 未使用 PVC 与 Azure 磁盘

## 用途

[`find-unused-pvcs.sh`](../find-unused-pvcs.sh) 是一个只读排查脚本，用于列出 Azure Kubernetes Service (AKS) 集群中未被任何运行中 Pod 或工作负载模板引用的 `PersistentVolumeClaim` (PVC)。

**当前没有运行中 Pod 挂载的 PVC 并不一定可以安全删除**：

- `Deployment` 或 `StatefulSet` 可能暂时缩容为 `0` 副本。
- `CronJob` 或 `Job` 仅在定时触发或任务执行期间才会创建 Pod。
- `StatefulSet` 使用 `volumeClaimTemplates` 动态生成 PVC，当副本缩容为 `0` 时，这些 PVC 不会以静态 `persistentVolumeClaim.claimName` 的形式出现在控制器中。

为避免误删，`find-unused-pvcs.sh` 会自动检查：

1. 所有 `Pod`、`Deployment`、`StatefulSet`、`DaemonSet`、`ReplicaSet`、`ReplicationController`、`Job` 和 `CronJob` 中的显式 `persistentVolumeClaim.claimName` 引用。
2. 所有 `StatefulSet` 的 `volumeClaimTemplates`，即使 `replicas: 0` 也会保护符合 `<template>-<statefulset>-<ordinal>` 命名规则的 PVC。
3. `PersistentVolume` (PV) 元数据，包括回收策略 (`persistentVolumeReclaimPolicy`) 以及底层 Azure 托管磁盘资源 ID (`spec.csi.volumeHandle`)。
4. Kubernetes `VolumeAttachment` 状态，用于确认底层磁盘是否仍挂载在集群节点上。

## 前提条件

- Bash 环境（Linux、macOS、WSL、Azure Cloud Shell 或 Windows Git Bash）。
- 已配置好目标 AKS 集群访问权限的 `kubectl`。
- `PATH` 中已安装 `jq`。
- 具备读取以下资源的 Kubernetes RBAC 权限（`get`/`list`）：
  - 命名空间级资源：`persistentvolumeclaims`、`pods`、`deployments`、`statefulsets`、`daemonsets`、`replicasets`、`replicationcontrollers`、`jobs`、`cronjobs`。
  - 集群级资源（用于补充 PV 与挂载状态信息）：`persistentvolumes`、`volumeattachments`。

## 使用方法

首次使用前赋予脚本可执行权限：

```bash
chmod +x find-unused-pvcs.sh
```

### 1. 扫描所有命名空间（默认表格输出）

```bash
./find-unused-pvcs.sh
```

### 2. 指定单个命名空间或 kubeconfig 上下文

```bash
./find-unused-pvcs.sh --namespace production --context my-aks-cluster
```

### 3. 导出为 CSV 或 TSV 文件以便人工审核

```bash
./find-unused-pvcs.sh --output csv --file ./unused-pvcs.csv
./find-unused-pvcs.sh --output tsv --file ./unused-pvcs.tsv
```

脚本不会覆盖已存在的输出文件；如需重新导出，请指定新的文件路径或先删除旧文件。

## 输出字段说明

| 字段 | 说明 |
| --- | --- |
| `NAMESPACE` | PVC 所在的 Kubernetes 命名空间。 |
| `PVC` | `PersistentVolumeClaim` 名称。 |
| `PHASE` | PVC 当前状态（`Bound`、`Pending`、`Lost`）。 |
| `STORAGECLASS` | 存储类名称（例如 `managed-csi` 或 `managed-csi-premium`）。 |
| `SIZE` | 已分配或请求的存储容量。 |
| `PV` | 绑定的 `PersistentVolume` 名称（未绑定时为 `-`）。 |
| `RECLAIM` / `RECLAIM_POLICY` | PV 回收策略（`Delete` 或 `Retain`）。 |
| `ATTACHED` | 若存在已挂载的 `VolumeAttachment` 则显示节点名，挂载/卸载过渡中显示 `attaching/detaching`，未挂载显示 `false`。 |
| `AZURE_DISK_OR_VOLUME_HANDLE` / `VOLUME_HANDLE` | 底层 CSI 卷句柄（对于 Azure Disk CSI 驱动，即完整的 Azure 托管磁盘 ARM 资源 ID）。 |

## 删除前的核查清单

请将脚本输出视为**待删除候选列表**，切勿未经核查直接批量删除。删除任何 PVC 前请逐项确认：

### 1. 确认磁盘未挂载到任何节点

输出中的 `ATTACHED` 列应当为 `false`。也可以单独执行以下命令核实：

```bash
PV_NAME="<pv-name>"

kubectl get volumeattachments -o json |
jq -r --arg pv "$PV_NAME" '
  .items[]
  | select(.spec.source.persistentVolumeName == $pv)
  | [.metadata.name, .spec.nodeName, (.status.attached // false)]
  | @tsv
'
```

如果返回结果中 `attached` 为 `true`，说明磁盘仍挂载在节点上，**请勿删除**。

### 2. 检查 PVC 与 PV 的详情、标签和注解

```bash
kubectl describe pvc -n "<namespace>" "<pvc-name>"
kubectl describe pv "<pv-name>"
```

请重点确认该 PVC 是否属于以下情况：

- 由 Helm、Flux、Argo CD 或 Terraform 管理，仅因应用临时下线而未运行。
- 被自定义 CRD（例如数据库 Operator、Spark 任务、Argo Workflows 或 Velero 备份任务）动态引用，而非标准 Kubernetes 控制器直接引用。
- 用于灾备恢复、数据迁移或人工维护而特意保留的数据卷。

### 3. 检查 PV 回收策略及对 Azure 磁盘的影响

```bash
kubectl get pv "<pv-name>" \
  -o jsonpath='Reclaim policy: {.spec.persistentVolumeReclaimPolicy}{"\n"}Volume handle: {.spec.csi.volumeHandle}{"\n"}'
```

- **`Delete`（删除）策略**：删除 PVC 会自动删除对应的 Kubernetes `PersistentVolume` 以及节点资源组（`MC_*`）中的底层 Azure 托管磁盘。如果数据可能还有保留价值，建议在删除前先创建 Azure 磁盘快照。
- **`Retain`（保留）策略**：删除 PVC 只会删除 Kubernetes 中的 PVC 对象。PV 状态会变为 `Released`，底层 Azure 托管磁盘仍会保留在 Azure 中（并继续产生费用），需要后续手动删除 PV 和 Azure 磁盘。

## 安全删除流程

1. **（可选）删除前创建 Azure 磁盘快照**

   使用 `VOLUME_HANDLE` 列输出的 Azure 磁盘资源 ID：

   ```bash
   DISK_ID="<volume-handle>"
   SNAPSHOT_NAME="snap-$(basename "$DISK_ID")-$(date +%Y%m%d%H%M%S)"
   RESOURCE_GROUP="$(echo "$DISK_ID" | awk -F'/' '{for (i=1;i<=NF;i++) if (tolower($i)=="resourcegroups") print $(i+1)}')"

   az snapshot create \
     --resource-group "$RESOURCE_GROUP" \
     --name "$SNAPSHOT_NAME" \
     --source "$DISK_ID"
   ```

2. **在 Kubernetes 中删除 PVC**

   ```bash
   kubectl delete pvc -n "<namespace>" "<pvc-name>"
   ```

3. **如果 PV 回收策略为 `Retain`，按需清理 PV 与 Azure 托管磁盘**

   ```bash
   kubectl delete pv "<pv-name>"
   az disk delete --ids "<volume-handle>" --yes
   ```
