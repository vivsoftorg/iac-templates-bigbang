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

# Function to clean up CRs for a CRD
cleanup_crd() {
  local crd=$1

  # Skip if in keep list
  if [[ ${KEEP_CRDS[$crd]+_} ]]; then
    echo "  Skipping (kept): $crd"
    return
  fi

  echo "  Processing CRD: $crd"
  CR_NAMES=$(kubectl get "$crd" --all-namespaces --ignore-not-found -o name || true)

  if [[ -n "$CR_NAMES" ]]; then
    echo "    Found resources:"
    echo "$CR_NAMES" | sed 's/^/      - /'
    for obj in $CR_NAMES; do
      echo "      Deleting $obj ..."
      if ! kubectl delete "$obj" --timeout=30s --ignore-not-found; then
        echo "      ⚠️ $obj stuck, removing finalizers..."
        kubectl patch "$obj" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' || true
        kubectl delete "$obj" --ignore-not-found || true
      fi
    done
  fi

  echo "    Deleting CRD $crd ..."
  kubectl delete crd "$crd" --ignore-not-found || true
}

# Always clean all CRDs except those in the KEEP list
ALL_CRDS=$(kubectl get crds -o name | sed 's#customresourcedefinition.apiextensions.k8s.io/##')
for crd in $ALL_CRDS; do
  cleanup_crd "$crd"
done

echo "✅ Completed cleanup!"
