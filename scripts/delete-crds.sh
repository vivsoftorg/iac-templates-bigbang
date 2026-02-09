#!/bin/bash
set -euo pipefail

# --- CRDs to KEEP ---
declare -A KEEP_CRDS=(
  # RKE2 defaults
  [addons.k3s.cattle.io]=1
  [etcdsnapshotfiles.k3s.cattle.io]=1
  [helmchartconfigs.helm.cattle.io]=1
  [helmcharts.helm.cattle.io]=1

  # Calico
  [bgpconfigurations.crd.projectcalico.org]=1
  [bgppeers.crd.projectcalico.org]=1
  [blockaffinities.crd.projectcalico.org]=1
  [caliconodestatuses.crd.projectcalico.org]=1
  [clusterinformations.crd.projectcalico.org]=1
  [felixconfigurations.crd.projectcalico.org]=1
  [globalnetworkpolicies.crd.projectcalico.org]=1
  [globalnetworksets.crd.projectcalico.org]=1
  [hostendpoints.crd.projectcalico.org]=1
  [ipamblocks.crd.projectcalico.org]=1
  [ipamconfigs.crd.projectcalico.org]=1
  [ipamhandles.crd.projectcalico.org]=1
  [ippools.crd.projectcalico.org]=1
  [ipreservations.crd.projectcalico.org]=1
  [kubecontrollersconfigurations.crd.projectcalico.org]=1
  [networkpolicies.crd.projectcalico.org]=1
  [networksets.crd.projectcalico.org]=1
  [stagedglobalnetworkpolicies.crd.projectcalico.org]=1
  [stagedkubernetesnetworkpolicies.crd.projectcalico.org]=1
  [stagednetworkpolicies.crd.projectcalico.org]=1
  [tiers.crd.projectcalico.org]=1

  # CSI Volume Snapshots
  [volumegroupsnapshotclasses.groupsnapshot.storage.k8s.io]=1
  [volumegroupsnapshotcontents.groupsnapshot.storage.k8s.io]=1
  [volumegroupsnapshots.groupsnapshot.storage.k8s.io]=1
  [volumesnapshotclasses.snapshot.storage.k8s.io]=1
  [volumesnapshotcontents.snapshot.storage.k8s.io]=1
  [volumesnapshots.snapshot.storage.k8s.io]=1
)

# Parallel CRD cleanup: up to 5 at a time
task_limit=5
cr_del_limit=10

cleanup_crd() {
  local crd=$1

  if [[ ${KEEP_CRDS[$crd]+_} ]]; then
    echo "  Skipping (kept): $crd"
    return 0
  fi

  echo "  Processing CRD: $crd"
  CR_NAMES=$(kubectl get "$crd" --all-namespaces --ignore-not-found -o name || true)

  # Clean up resources in parallel (up to $cr_del_limit background tasks)
  if [[ -n "$CR_NAMES" ]]; then
    echo "    Found resources:"
    echo "$CR_NAMES" | sed 's/^/      - /'
    # Parallel delete, but throttle
    running=0
    pids=()
    for obj in $CR_NAMES; do
      (
        echo "      Deleting $obj ..."
        if ! kubectl delete "$obj" --timeout=10s --ignore-not-found; then
          echo "      ⚠️ $obj stuck, removing finalizers..."
          kubectl patch "$obj" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' || true
          kubectl delete "$obj" --ignore-not-found || true
        fi
      ) &
      pids+=("$!")
      (( ++running >= cr_del_limit )) && { wait -n; ((running--)); }
    done
    # Wait for remaining jobs
    wait
  fi

  echo "    Deleting CRD $crd ..."
  kubectl delete crd "$crd" --ignore-not-found || true
}

# Always clean all CRDs except those in the KEEP list
ALL_CRDS=$(kubectl get crds -o name | sed 's#customresourcedefinition.apiextensions.k8s.io/##')

# Parallel CRD deletion (max $task_limit at once)
running=0
crd_pids=()
for crd in $ALL_CRDS; do
  (cleanup_crd "$crd") &
  crd_pids+=("$!")
  (( ++running >= task_limit )) && { wait -n; ((running--)); }
done
wait

echo "✅ Completed cleanup!"