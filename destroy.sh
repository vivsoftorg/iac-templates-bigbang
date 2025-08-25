#!/usr/bin/env bash
set -euo pipefail

# List of prioritized HelmReleases
HELMRELEASES=(
  kyverno-reporter
  neuvector
  metrics-server
  kiali
  public-ingressgateway
  passthrough-ingressgateway
  grafana
  bbctl
  alloy
  tempo
  twistlock
  loki
  monitoring
  istiod
  istio-crds
  kyverno-policies
  kyverno
  prometheus-operator-crds
  kiali
  bigbang
)

log() { echo -e "\033[1;34m==> $*\033[0m"; }
success() { echo -e "\033[1;32m✔ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }


delete_hr_and_dependents() {
  local hr=$1
  local ns=${2:-bigbang}

  log "Processing HelmRelease: $ns/$hr"

  # Try deleting HR
  log "  Deleting HelmRelease $ns/$hr"
  kubectl delete helmrelease "$hr" -n "$ns" --ignore-not-found --wait=false || true
  sleep 1

  # Check if still exists
  if kubectl get helmrelease "$hr" -n "$ns" >/dev/null 2>&1; then
    warn "  $ns/$hr still exists, cleaning CRDs and CRs..."

    # Find CRDs possibly tied to this HR
    for crd in $(kubectl get crds -o json | jq -r ".items[].metadata.name"); do
      if [[ "$crd" == *"$hr"* ]]; then
        log "    Found CRD: $crd"
        kind=$(kubectl get crd "$crd" -o jsonpath='{.spec.names.plural}' 2>/dev/null || true)
        group=$(kubectl get crd "$crd" -o jsonpath='{.spec.group}' 2>/dev/null || true)
        [[ -z "$kind" || -z "$group" ]] && continue
        fqdn="$kind.$group"

        # Clean CRs
        log "    Patching CRs of $fqdn to remove finalizers"
        kubectl patch "$fqdn" --all --all-namespaces \
          --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

        log "    Deleting all CRs of $fqdn"
        kubectl delete "$fqdn" --all --all-namespaces --ignore-not-found --wait=false 2>/dev/null || true

        # Delete CRD itself
        log "    Deleting CRD $crd"
        kubectl delete crd "$crd" --ignore-not-found --wait=false || true
      fi
    done

    # Retry HR delete
    log "  Retrying deletion of HelmRelease $ns/$hr"
    kubectl patch helmrelease "$hr" -n "$ns" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    kubectl delete helmrelease "$hr" -n "$ns" --ignore-not-found --wait=false || true
  fi

  success "HelmRelease $ns/$hr cleaned."
}


# --- MAIN ---

# Get all existing HelmReleases in bigbang namespace once
EXISTING_HRS=$(kubectl get helmrelease -n bigbang -o jsonpath='{.items[*].metadata.name}')

# 1. Process the curated HELMRELEASES list
for hr in "${HELMRELEASES[@]}"; do
  if [[ " $EXISTING_HRS " =~ " $hr " ]]; then
    delete_hr_and_dependents "$hr" "bigbang"
  else
    warn "HelmRelease bigbang/$hr not found, skipping."
  fi
done

# 2. Delete our BigBang kustomization
log "Delete the BigBang bigbang/envs/dev/"
kustomize build bigbang/envs/dev/ | kubectl delete -f - || true

# 3. Handle orphan HRs (not in list)

log "Scanning for leftover HelmReleases in bigbang namespace..."
for hr in $(kubectl -n bigbang get helmreleases -o name | cut -d/ -f2); do
  if [[ ! " ${HELMRELEASES[*]} " =~ " $hr " ]]; then
    warn "Found orphan HelmRelease: $hr"
    delete_hr_and_dependents "$hr" "bigbang"
  fi
done

log "Waiting for all HelmReleases in bigbang namespace to be deleted..."
until [[ $(kubectl --namespace bigbang get helmreleases.helm.toolkit.fluxcd.io --no-headers) == "" ]]; do
    log "Waiting for cleanup of helmreleases..."
    sleep 5
done

log "Waiting for all resources in bigbang namespace to be deleted..."
until [[ $(kubectl --namespace bigbang get all --no-headers) == "" ]]; do
    log "Waiting for cleanup of bigbang resources..."
    sleep 5
done


# 4. Delete gitrepositories, flux, cluster-init
log "Delete the gitrepositories"
until [[ $(kubectl --namespace bigbang get gitrepositories.source.toolkit.fluxcd.io --no-headers) == "" ]]; do
    log "Waiting for cleanup of gitrepositories..."
    sleep 5
done

log "Delete the helmrepository"
until [[ $(kubectl --namespace bigbang get helmrepository.source.toolkit.fluxcd.io --no-headers) == "" ]]; do
    log "Waiting for cleanup of helmrepository ..."
    sleep 5
done

log "Delete the flux"
kustomize build flux/ | kubectl delete -f - || true

until [[ $(kubectl --namespace flux-system get all --no-headers) == "" ]]; do
    log "Waiting for cleanup of flux components..."
    sleep 5
done

log "Delete the cluster-init/ resources"
kustomize build cluster-init/ | kubectl delete -f - || true

success "BigBang and all associated resources have been destroyed successfully 🎉"

# 4. Clean up CRDs and CRs left behind
log "Cleaning up leftover istio CRDs "
istio_crds=$(kubectl get crds -o name | grep 'istio.io' || true)
for crd in $istio_crds; do
  log "  Deleting CRD $crd ..."
  kubectl delete "$crd" --ignore-not-found || true
done

grafana_crds=$(kubectl get crds -o name | grep 'grafana.com' || true)
for crd in $grafana_crds; do
  log "  Deleting CRD $crd ..."
  kubectl delete "$crd" --ignore-not-found || true
done

kiali_crds=$(kubectl get crds -o name | grep 'kiali.io' || true)
for crd in $kiali_crds; do
  log "  Deleting CRD $crd ..."
  kubectl delete "$crd" --ignore-not-found || true
done

wgpolicyk8s_crds=$(kubectl get crds -o name | grep 'wgpolicyk8s.io' || true)
for crd in $wgpolicyk8s_crds; do
  log "  Deleting CRD $crd ..."
  kubectl delete "$crd" --ignore-not-found || true
done

# 5. Patch and delete Terminating namespaces
log "Checking for Terminating namespaces..."
for ns in $(kubectl get ns --no-headers | awk '$2=="Terminating"{print $1}'); do
  warn "Namespace $ns is stuck in Terminating. Patching finalizers..."
  kubectl get ns "$ns" -o json \
    | jq '.spec.finalizers = []' \
    | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - || true
  success "Namespace $ns finalized."
done

success "Cluster cleanup completed!"
log "Remaining namespaces:"
kubectl get ns
