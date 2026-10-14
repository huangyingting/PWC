#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./find-unused-pvcs.sh [options]

Description:
  Conservatively lists Kubernetes PersistentVolumeClaims (PVCs) that are not
  referenced by any Pod or workload controller template (Deployment,
  StatefulSet, DaemonSet, ReplicaSet, ReplicationController, Job, CronJob),
  including StatefulSet volumeClaimTemplates when scaled to zero.

  Also enriches each candidate with its PersistentVolume (PV), StorageClass,
  reclaim policy, Kubernetes VolumeAttachment state, and Azure Disk resource ID.

Options:
  -n, --namespace <ns>   Inspect a single namespace instead of all namespaces
  -c, --context <ctx>    Use a specific kubeconfig context
  -o, --output <format>  Output format: table (default), tsv, or csv
  -f, --file <path>      Write output to a file instead of stdout
  -h, --help             Show this help message
EOF
}

NAMESPACE=""
KUBE_CONTEXT=""
OUTPUT_FORMAT="table"
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      [[ $# -ge 2 ]] || { echo "Error: $1 requires a namespace argument." >&2; exit 1; }
      NAMESPACE="$2"
      shift 2
      ;;
    -c|--context)
      [[ $# -ge 2 ]] || { echo "Error: $1 requires a context argument." >&2; exit 1; }
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    -o|--output)
      [[ $# -ge 2 ]] || { echo "Error: $1 requires a format argument (table|tsv|csv)." >&2; exit 1; }
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    -f|--file)
      [[ $# -ge 2 ]] || { echo "Error: $1 requires a file path argument." >&2; exit 1; }
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$OUTPUT_FORMAT" in
  table|tsv|csv) ;;
  *)
    echo "Error: Invalid --output format '$OUTPUT_FORMAT'. Choose table, tsv, or csv." >&2
    exit 1
    ;;
esac

if [[ -n "$OUTPUT_FILE" && -e "$OUTPUT_FILE" ]]; then
  echo "Error: Output file already exists: $OUTPUT_FILE" >&2
  exit 1
fi

for cmd in kubectl jq sort awk grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Required command '$cmd' was not found on PATH." >&2
    exit 1
  fi
done

kubectl_cmd=(kubectl)
if [[ -n "$KUBE_CONTEXT" ]]; then
  kubectl_cmd+=(--context "$KUBE_CONTEXT")
fi

ns_args=(--all-namespaces)
if [[ -n "$NAMESPACE" ]]; then
  ns_args=(-n "$NAMESPACE")
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pvc_json="$tmp_dir/pvcs.json"
pv_json="$tmp_dir/pvs.json"
va_json="$tmp_dir/volumeattachments.json"
workloads_json="$tmp_dir/workloads.json"
statefulsets_json="$tmp_dir/statefulsets.json"

all_pvcs="$tmp_dir/all-pvcs.tsv"
referenced_pvcs="$tmp_dir/referenced-pvcs.tsv"
statefulset_pvcs="$tmp_dir/statefulset-pvcs.tsv"
candidates_tsv="$tmp_dir/candidates.tsv"

"${kubectl_cmd[@]}" get pvc "${ns_args[@]}" -o json > "$pvc_json"

if "${kubectl_cmd[@]}" get pv -o json > "$pv_json" 2>/dev/null; then
  :
else
  echo '{"items":[]}' > "$pv_json"
fi

if "${kubectl_cmd[@]}" get volumeattachments -o json > "$va_json" 2>/dev/null; then
  :
else
  echo '{"items":[]}' > "$va_json"
fi

"${kubectl_cmd[@]}" get \
  pods,deployments,statefulsets,daemonsets,replicasets,replicationcontrollers,jobs,cronjobs \
  "${ns_args[@]}" -o json > "$workloads_json"

"${kubectl_cmd[@]}" get statefulsets "${ns_args[@]}" -o json > "$statefulsets_json"

# Extract every PVC and enrich with PV metadata and VolumeAttachment state.
jq -r \
  --slurpfile pvs "$pv_json" \
  --slurpfile vas "$va_json" '
  ($pvs[0].items // [] | map({
    key: .metadata.name,
    value: {
      reclaimPolicy: (.spec.persistentVolumeReclaimPolicy // "-"),
      volumeHandle: (.spec.csi.volumeHandle // .spec.azureDisk.diskURI // "-")
    }
  }) | from_entries) as $pv_map
  |
  ($vas[0].items // [] | reduce .[] as $va ({};
    ($va.spec.source.persistentVolumeName // "") as $pv_name
    | if $pv_name != "" and ($va.status.attached // false) then
        .[$pv_name] = (($va.spec.nodeName // "attached"))
      elif $pv_name != "" and (.[$pv_name] == null) then
        .[$pv_name] = "attaching/detaching"
      else
        .
      end
  )) as $va_map
  |
  .items[]
  | (.spec.volumeName // "-") as $pv
  | [
      .metadata.namespace,
      .metadata.name,
      (.status.phase // "-"),
      (.spec.storageClassName // "-"),
      (.status.capacity.storage // .spec.resources.requests.storage // "-"),
      $pv,
      (if $pv != "-" and ($pv_map[$pv] != null) then $pv_map[$pv].reclaimPolicy else "-" end),
      (if $pv != "-" and ($va_map[$pv] != null) then $va_map[$pv] else "false" end),
      (if $pv != "-" and ($pv_map[$pv] != null) then $pv_map[$pv].volumeHandle else "-" end)
    ]
  | @tsv
' "$pvc_json" | sort -u > "$all_pvcs"

# Find explicit PVC references in Pods and workload templates.
# Including workload templates is important because a Deployment, Job, or
# CronJob may currently have zero Pods but can use the PVC again later.
jq -r '
  .items[] as $item
  | ($item.metadata.namespace // "default") as $namespace
  | [
      $item
      | ..
      | objects
      | .persistentVolumeClaim?
      | select(. != null)
      | .claimName?
      | select(. != null)
    ][]
  | [$namespace, .]
  | @tsv
' "$workloads_json" | sort -u > "$referenced_pvcs"

# Protect StatefulSet volumeClaimTemplates.
# StatefulSet PVCs follow the naming pattern:
#   <volumeClaimTemplate>-<statefulSetName>-<ordinal>
# Matching this pattern protects them even if the StatefulSet is scaled to zero.
jq -r \
  --slurpfile pvcs "$pvc_json" '
  [
    .items[]
    | .metadata.namespace as $namespace
    | .metadata.name as $statefulset
    | .spec.volumeClaimTemplates[]?
    | {
        namespace: $namespace,
        prefix: (.metadata.name + "-" + $statefulset + "-")
      }
  ] as $prefixes
  |
  ($pvcs[0].items // [])[]
  | .metadata.namespace as $ns
  | .metadata.name as $pvc_name
  | select(
      any(
        $prefixes[];
        .namespace == $ns
        and ($pvc_name | startswith(.prefix))
        and (($pvc_name | ltrimstr(.prefix)) | test("^[0-9]+$"))
      )
    )
  | [$ns, $pvc_name]
  | @tsv
' "$statefulsets_json" | sort -u > "$statefulset_pvcs"

: > "$candidates_tsv"
while IFS=$'\t' read -r namespace pvc phase storage_class size pv reclaim_policy attached volume_handle; do
  [[ -z "$namespace" ]] && continue

  if grep -Fqx "${namespace}"$'\t'"${pvc}" "$referenced_pvcs"; then
    continue
  fi

  if grep -Fqx "${namespace}"$'\t'"${pvc}" "$statefulset_pvcs"; then
    continue
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$namespace" "$pvc" "$phase" "$storage_class" "$size" "$pv" "$reclaim_policy" "$attached" "$volume_handle" \
    >> "$candidates_tsv"
done < "$all_pvcs"

render_output() {
  case "$OUTPUT_FORMAT" in
    table)
      echo "PVC deletion candidates (not referenced by active Pods or workload templates):"
      echo
      printf "%-24s %-36s %-8s %-22s %-10s %-42s %-10s %-18s %s\n" \
        "NAMESPACE" "PVC" "PHASE" "STORAGECLASS" "SIZE" "PV" "RECLAIM" "ATTACHED" "AZURE_DISK_OR_VOLUME_HANDLE"
      while IFS=$'\t' read -r namespace pvc phase storage_class size pv reclaim_policy attached volume_handle; do
        [[ -z "$namespace" ]] && continue
        printf "%-24s %-36s %-8s %-22s %-10s %-42s %-10s %-18s %s\n" \
          "$namespace" "$pvc" "$phase" "$storage_class" "$size" "$pv" "$reclaim_policy" "$attached" "$volume_handle"
      done < "$candidates_tsv"
      ;;
    tsv)
      printf "NAMESPACE\tPVC\tPHASE\tSTORAGECLASS\tSIZE\tPV\tRECLAIM_POLICY\tATTACHED\tVOLUME_HANDLE\n"
      cat "$candidates_tsv"
      ;;
    csv)
      jq -Rn --rawfile data "$candidates_tsv" '
        (["NAMESPACE","PVC","PHASE","STORAGECLASS","SIZE","PV","RECLAIM_POLICY","ATTACHED","VOLUME_HANDLE"] | @csv),
        (
          $data
          | split("\n")[:-1][]
          | select(length > 0)
          | split("\t")
          | @csv
        )
      '
      ;;
  esac
}

if [[ -n "$OUTPUT_FILE" ]]; then
  render_output > "$OUTPUT_FILE"
  echo "Wrote PVC deletion candidates to $OUTPUT_FILE" >&2
else
  render_output
fi
