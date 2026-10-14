# Finding and Safely Deleting Unused AKS PVCs and Azure Disks

## Purpose

[`find-unused-pvcs.sh`](../find-unused-pvcs.sh) is a read-only discovery script that lists Kubernetes `PersistentVolumeClaim` (PVC) objects not referenced by any running Pod or workload template in an Azure Kubernetes Service (AKS) cluster.

A PVC with no **currently running Pod** is not automatically safe to delete:

- A `Deployment` or `StatefulSet` may be temporarily scaled to `0` replicas.
- A `CronJob` or `Job` only creates Pods while scheduled or running.
- A `StatefulSet` uses `volumeClaimTemplates`, which are not listed as static `persistentVolumeClaim.claimName` entries when Pods are scaled down.

To avoid false positives, `find-unused-pvcs.sh` inspects:

1. All `Pod`, `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `ReplicationController`, `Job`, and `CronJob` objects for explicit `persistentVolumeClaim.claimName` references.
2. All `StatefulSet` `volumeClaimTemplates` and protects matching `<template>-<statefulset>-<ordinal>` PVCs even when `replicas: 0`.
3. `PersistentVolume` (PV) metadata, including `persistentVolumeReclaimPolicy` and the underlying Azure Managed Disk resource ID (`spec.csi.volumeHandle`).
4. Kubernetes `VolumeAttachment` status to reveal whether the disk is still attached to a cluster node.

## Prerequisites

- Bash shell (Linux, macOS, WSL, Azure Cloud Shell, or Git Bash on Windows).
- `kubectl` configured to access the target AKS cluster.
- `jq` installed on `PATH`.
- Cluster RBAC permissions to `list`/`get`:
  - Namespaced resources: `persistentvolumeclaims`, `pods`, `deployments`, `statefulsets`, `daemonsets`, `replicasets`, `replicationcontrollers`, `jobs`, `cronjobs`.
  - Cluster-scoped resources (recommended for PV and attachment enrichment): `persistentvolumes`, `volumeattachments`.

## Usage

Make the script executable once:

```bash
chmod +x find-unused-pvcs.sh
```

### 1. Scan all namespaces (default table output)

```bash
./find-unused-pvcs.sh
```

### 2. Scan a single namespace or specific kubeconfig context

```bash
./find-unused-pvcs.sh --namespace production --context my-aks-cluster
```

### 3. Export candidates to CSV or TSV for review

```bash
./find-unused-pvcs.sh --output csv --file ./unused-pvcs.csv
./find-unused-pvcs.sh --output tsv --file ./unused-pvcs.tsv
```

Existing output files are never overwritten; specify a new file path or remove the previous file first.

## Output columns

| Column | Description |
| --- | --- |
| `NAMESPACE` | Kubernetes namespace of the PVC. |
| `PVC` | Name of the `PersistentVolumeClaim`. |
| `PHASE` | Current PVC phase (`Bound`, `Pending`, `Lost`). |
| `STORAGECLASS` | StorageClass name (for example `managed-csi` or `managed-csi-premium`). |
| `SIZE` | Provisioned or requested storage capacity. |
| `PV` | Bound `PersistentVolume` name (`-` if unbound). |
| `RECLAIM` / `RECLAIM_POLICY` | PV reclaim policy (`Delete` or `Retain`). |
| `ATTACHED` | Node name if an active `VolumeAttachment` exists, `attaching/detaching` if in transition, or `false` if unattached. |
| `AZURE_DISK_OR_VOLUME_HANDLE` / `VOLUME_HANDLE` | Underlying CSI volume handle (for Azure Disk CSI, the full Azure Managed Disk ARM resource ID). |

## Verification checklist before deleting a PVC

Treat the script output as **deletion candidates**, not an automatic deletion list. Before deleting any PVC, verify the following:

### 1. Confirm the volume is not attached to any node

The `ATTACHED` column should be `false`. You can also verify directly:

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

If this returns a row with `true`, the disk is still attached to a node—**do not delete it**.

### 2. Inspect PVC and PV events, labels, and annotations

```bash
kubectl describe pvc -n "<namespace>" "<pvc-name>"
kubectl describe pv "<pv-name>"
```

Check whether the PVC is:

- Managed by Helm, Flux, Argo CD, or Terraform that is temporarily scaled down or undeployed.
- Referenced by custom CRDs (for example, database operators, Spark jobs, Argo Workflows, or backup tools like Velero) that create Pods dynamically outside standard Kubernetes workload controllers.
- Retained intentionally for disaster recovery, migration, or manual troubleshooting.

### 3. Check the PV reclaim policy and Azure Disk impact

```bash
kubectl get pv "<pv-name>" \
  -o jsonpath='Reclaim policy: {.spec.persistentVolumeReclaimPolicy}{"\n"}Volume handle: {.spec.csi.volumeHandle}{"\n"}'
```

- **`Delete` reclaim policy**: Deleting the PVC automatically deletes both the Kubernetes `PersistentVolume` and the underlying Azure Managed Disk in the node resource group (`MC_*`). Consider taking an Azure Disk snapshot first if the data might be needed.
- **`Retain` reclaim policy**: Deleting the PVC removes only the PVC object. The `PersistentVolume` moves to `Released` and the Azure Managed Disk remains in Azure (and continues to incur cost) until you delete the PV and the Azure Disk manually.

## Safe deletion workflow

1. **(Optional) Create an Azure Disk snapshot before deletion**

   Using the Azure Disk resource ID from `VOLUME_HANDLE`:

   ```bash
   DISK_ID="<volume-handle>"
   SNAPSHOT_NAME="snap-$(basename "$DISK_ID")-$(date +%Y%m%d%H%M%S)"
   RESOURCE_GROUP="$(echo "$DISK_ID" | awk -F'/' '{for (i=1;i<=NF;i++) if (tolower($i)=="resourcegroups") print $(i+1)}')"

   az snapshot create \
     --resource-group "$RESOURCE_GROUP" \
     --name "$SNAPSHOT_NAME" \
     --source "$DISK_ID"
   ```

2. **Delete the PVC in Kubernetes**

   ```bash
   kubectl delete pvc -n "<namespace>" "<pvc-name>"
   ```

3. **If the PV reclaim policy was `Retain`, clean up the PV and Azure Disk**

   ```bash
   kubectl delete pv "<pv-name>"
   az disk delete --ids "<volume-handle>" --yes
   ```
