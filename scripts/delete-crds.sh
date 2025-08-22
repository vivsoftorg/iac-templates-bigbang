#!/bin/bash
set -euo pipefail

# --- CRDs to KEEP ---
KEEP_CRDS=(
  # RKE2 defaults
  addons.k3s.cattle.io
  etcdsnapshotfiles.k3s.cattle.io
  helmchartconfigs.helm.cattle.io
  helmcharts.helm.cattle.io

  # Calico
  bgpconfigurations.crd.projectcalico.org
  bgppeers.crd.projectcalico.org
  blockaffinities.crd.projectcalico.org
  caliconodestatuses.crd.projectcalico.org
  clusterinformations.crd.projectcalico.org
  felixconfigurations.crd.projectcalico.org
  globalnetworkpolicies.crd.projectcalico.org
  globalnetworksets.crd.projectcalico.org
  hostendpoints.crd.projectcalico.org
  ipamblocks.crd.projectcalico.org
  ipamconfigs.crd.projectcalico.org
  ipamhandles.crd.projectcalico.org
  ippools.crd.projectcalico.org
  ipreservations.crd.projectcalico.org
  kubecontrollersconfigurations.crd.projectcalico.org
  networkpolicies.crd.projectcalico.org
  networksets.crd.projectcalico.org
  stagedglobalnetworkpolicies.crd.projectcalico.org
  stagedkubernetesnetworkpolicies.crd.projectcalico.org
  stagednetworkpolicies.crd.projectcalico.org
  tiers.crd.projectcalico.org

  # CSI Volume Snapshots
  volumegroupsnapshotclasses.groupsnapshot.storage.k8s.io
  volumegroupsnapshotcontents.groupsnapshot.storage.k8s.io
  volumegroupsnapshots.groupsnapshot.storage.k8s.io
  volumesnapshotclasses.snapshot.storage.k8s.io
  volumesnapshotcontents.snapshot.storage.k8s.io
  volumesnapshots.snapshot.storage.k8s.io
)

# --- CRD groups by component ---
declare -A CRD_GROUPS

CRD_GROUPS["istio"]="authorizationpolicies.security.istio.io destinationrules.networking.istio.io envoyfilters.networking.istio.io gateways.networking.istio.io peerauthentications.security.istio.io proxyconfigs.networking.istio.io requestauthentications.security.istio.io serviceentries.networking.istio.io sidecars.networking.istio.io telemetries.telemetry.istio.io virtualservices.networking.istio.io wasmplugins.extensions.istio.io workloadentries.networking.istio.io"

CRD_GROUPS["kyverno"]="cleanuppolicies.kyverno.io clustercleanuppolicies.kyverno.io clusterephemeralreports.reports.kyverno.io clusterpolicies.kyverno.io ephemeralreports.reports.kyverno.io globalcontextentries.kyverno.io imagevalidatingpolicies.policies.kyverno.io policies.kyverno.io policyexceptions.kyverno.io policyexceptions.policies.kyverno.io updaterequests.kyverno.io validatingpolicies.policies.kyverno.io"

CRD_GROUPS["wgpolicy"]="clusterpolicyreports.wgpolicyk8s.io policyreports.wgpolicyk8s.io"

CRD_GROUPS["neuvector"]="nvadmissioncontrolsecurityrules.neuvector.com nvclustersecurityrules.neuvector.com nvcomplianceprofiles.neuvector.com nvdlpsecurityrules.neuvector.com nvgroupdefinitions.neuvector.com nvsecurityrules.neuvector.com nvvulnerabilityprofiles.neuvector.com nvwafsecurityrules.neuvector.com"

CRD_GROUPS["kiali"]="kialis.kiali.io"

CRD_GROUPS["grafana-alloy"]="alloys.collectors.grafana.com"

# Function to clean up CRs for a CRD
cleanup_crd() {
  local crd=$1

  # Skip if keep list
  if [[ " ${KEEP_CRDS[@]} " =~ " ${crd} " ]]; then
    echo "  Skipping (kept): $crd"
    return
  fi

  echo "  Processing CRD: $crd"
  CR_NAMES=$(kubectl get "$crd" --all-namespaces --ignore-not-found -o name || true)

  if [[ -n "$CR_NAMES" ]]; then
    echo "    Found resources:"
    echo "$CR_NAMES" | sed 's/^/      - /'
    read -p "    Delete these resources? (y/N): " delete_crs
    if [[ "$delete_crs" =~ ^[Yy]$ ]]; then
      for obj in $CR_NAMES; do
        echo "      Deleting $obj ..."
        if ! kubectl delete "$obj" --timeout=30s --ignore-not-found; then
          echo "      ⚠️ $obj stuck, removing finalizers..."
          kubectl patch "$obj" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' || true
          kubectl delete "$obj" --ignore-not-found || true
        fi
      done
    else
      echo "    Skipping CR deletion for $crd"
      return
    fi
  fi

  echo "    Deleting CRD $crd ..."
  kubectl delete crd "$crd" --ignore-not-found || true
}

# Main Menu
echo "Available CRD groups to clean:"
for group in "${!CRD_GROUPS[@]}"; do
  echo " - $group"
done
echo " - all (clean everything except KEEP list)"
echo

read -p "Which group do you want to clean? " choice

if [[ "$choice" == "all" ]]; then
  ALL_CRDS=$(kubectl get crds -o name | sed 's#customresourcedefinition.apiextensions.k8s.io/##')
  for crd in $ALL_CRDS; do
    cleanup_crd "$crd"
  done
elif [[ -n "${CRD_GROUPS[$choice]+_}" ]]; then
  for crd in ${CRD_GROUPS[$choice]}; do
    cleanup_crd "$crd"
  done
else
  echo "Unknown choice: $choice"
  exit 1
fi

echo "✅ Cleanup completed."
