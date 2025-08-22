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
  loki
  monitoring
  istiod
  istio-crds
  kyverno-policies
  kyverno
  prometheus-operator-crds
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

# 3. Finally, delete BigBang
log "Delete the BigBang bigbang/envs/dev/"
kustomize build bigbang/envs/dev/ | kubectl delete -f - || true

until [[ $(kubectl --namespace bigbang get all --no-headers) == "" ]]; do
    log "Waiting for cleanup of bigbang resources..."
    sleep 5
done

until [[ $(kubectl --namespace bigbang get helmreleases.helm.toolkit.fluxcd.io --no-headers) == "" ]]; do
    log "Waiting for cleanup of helmreleases..."
    sleep 5
done

log "Delete the gitrepositories"
until [[ $(kubectl --namespace bigbang get gitrepositories.source.toolkit.fluxcd.io --no-headers) == "" ]]; do
    log "Waiting for cleanup of gitrepositories..."
    sleep 5
done

log "Delete the flux"
kustomize build flux/ | kubectl delete -f - || true

until [[ $(kubectl --namespace flux-system get all --no-headers) == "" ]]; do
    log "Waiting for cleanup of flux components..."
    sleep 5
done

log "Delete the cluster-init/ resources"
kustomize build cluster-init/ | kubectl delete -f -

until [[ $(kubectl get ns bigbang --no-headers) == "" ]]; do
    log "Waiting for cleanup of bigbang namespace..."
    sleep 5
done

until [[ $(kubectl get ns flux-system --no-headers) == "" ]]; do
    log "Waiting for cleanup of flux-system namespace..."
    sleep 5
done
