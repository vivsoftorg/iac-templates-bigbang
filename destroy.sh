#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${CYAN}==> $1${NC}"; }
success(){ echo -e "${GREEN}✔ $1${NC}"; }
error()  { echo -e "${RED}✖ $1${NC}"; }

# Namespace (default unless overridden)
NAMESPACE="${1:-default}"

# HelmReleases to delete (reverse dependency order)
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

# CRDs grouped by component
declare -A CRD_GROUPS=(
  [istio]="authorizationpolicies.security.istio.io destinationrules.networking.istio.io envoyfilters.networking.istio.io gateways.networking.istio.io istiooperators.install.istio.io peerauthentications.security.istio.io proxyconfigs.networking.istio.io requestauthentications.security.istio.io serviceentries.networking.istio.io sidecars.networking.istio.io telemetries.telemetry.istio.io virtualservices.networking.istio.io wasmplugins.extensions.istio.io workloadentries.networking.istio.io workloadgroups.networking.istio.io"
  [gatekeeper]="assign.mutations.gatekeeper.sh assignmetadata.mutations.gatekeeper.sh configs.config.gatekeeper.sh constraintpodstatuses.status.gatekeeper.sh constrainttemplatepodstatuses.status.gatekeeper.sh constrainttemplates.templates.gatekeeper.sh expansiontemplate.expansion.gatekeeper.sh modifyset.mutations.gatekeeper.sh mutatorpodstatuses.status.gatekeeper.sh providers.externaldata.gatekeeper.sh"
  [kyverno]="admissionreports.kyverno.io backgroundscanreports.kyverno.io cleanuppolicies.kyverno.io clusteradmissionreports.kyverno.io clusterbackgroundscanreports.kyverno.io clustercleanuppolicies.kyverno.io clusterpolicies.kyverno.io policies.kyverno.io policyexceptions.kyverno.io updaterequests.kyverno.io"
  [grafana]="grafanaagents.monitoring.grafana.com integrations.monitoring.grafana.com logsinstances.monitoring.grafana.com metricsinstances.monitoring.grafana.com podlogs.monitoring.grafana.com"
  [policyreports]="clusterpolicyreports.wgpolicyk8s.io policyreports.wgpolicyk8s.io"
  [tracing]="jaegers.jaegertracing.io kialis.kiali.io"
)

# Delete CRs safely (with finalizer removal if needed)
delete_crs_and_crd() {
  local crd="$1"
  if ! kubectl get crd "$crd" >/dev/null 2>&1; then
    log "CRD $crd not found, skipping"
    return
  fi

  log "Processing CRD: $crd"
  local crs
  crs=$(kubectl get "$crd" -A --no-headers 2>/dev/null || true)

  if [[ -n "$crs" ]]; then
    log "Found CRs for $crd:"
    echo "$crs"

    read -rp "Delete these CRs? (y/n) " ans
    if [[ "$ans" == "y" ]]; then
      while read -r ns name _; do
        log "Deleting CR $name in ns $ns (from $crd)"
        if ! kubectl delete "$crd" "$name" -n "$ns" --timeout=60s; then
          error "Force removing finalizers for $name in $ns"
          kubectl patch "$crd" "$name" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge || true
          kubectl delete "$crd" "$name" -n "$ns" || true
        fi
      done <<< "$(kubectl get "$crd" -A --no-headers | awk '{print $1,$2}')"
    else
      log "Skipping CR deletion for $crd"
    fi
  fi

  kubectl delete crd "$crd" || true
  success "CRD $crd deleted"
}

### MAIN FLOW ###

log "Deleting HelmReleases from namespace: ${NAMESPACE}"

for hr in "${HELMRELEASES[@]}"; do
  log "Deleting HelmRelease: $hr"
  if kubectl get helmrelease "$hr" -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl delete helmrelease "$hr" -n "$NAMESPACE" --wait=true || {
      error "Failed to delete $hr"
      continue
    }
    success "$hr deleted"
  else
    log "$hr not found, skipping"
  fi
done

# Process CRDs in groups
for group in "${!CRD_GROUPS[@]}"; do
  log "Cleaning CRDs for $group"
  for crd in ${CRD_GROUPS[$group]}; do
    delete_crs_and_crd "$crd"
  done
done

success "All HelmReleases and CRDs processed!"
