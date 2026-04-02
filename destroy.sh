#!/usr/bin/env bash
set -Eeuo pipefail

# Check for HelmRelease CRD
test_helmrelease_crd() {
  kubectl get crd helmreleases.helm.toolkit.fluxcd.io > /dev/null 2>&1
}

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
  bigbang
)

log() { echo -e "\033[1;34m==> $*\033[0m"; }
success() { echo -e "\033[1;32m✔ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }

GATEWAY_SERVICES=(
  "istio-gateway/public-ingressgateway"
  "istio-gateway/passthrough-ingressgateway"
)
GATEWAY_ELB_NAMES=()
GATEWAY_ELB_SECURITY_GROUPS=()
GATEWAY_VPC_ID=""

normalize_kubeconfig() {
  if [[ -z "${KUBECONFIG:-}" ]]; then
    warn "KUBECONFIG is not set; destroy will rely on the current kubectl context"
    return 0
  fi

  if [[ -f "${KUBECONFIG}" ]]; then
    return 0
  fi

  local kubeconfig_file
  kubeconfig_file="$(mktemp /tmp/enbuild-kubeconfig.XXXXXX.yaml)"
  printf '%s\n' "${KUBECONFIG}" > "${kubeconfig_file}"
  chmod 600 "${kubeconfig_file}"
  export KUBECONFIG="${kubeconfig_file}"
  success "Materialized KUBECONFIG content to ${kubeconfig_file}"
}

array_contains() {
  local needle=$1
  shift
  local item
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

append_unique() {
  local array_name=$1
  local value=$2
  local -n array_ref="${array_name}"

  array_contains "${value}" "${array_ref[@]}" && return 0
  array_ref+=("${value}")
}

kube_api_available() {
  kubectl version --request-timeout=5s >/dev/null 2>&1
}

aws_cleanup_available() {
  if ! command -v aws >/dev/null 2>&1; then
    warn "aws CLI not found; skipping gateway ELB cleanup"
    return 1
  fi

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    warn "AWS identity unavailable; skipping gateway ELB cleanup"
    return 1
  fi

  return 0
}

load_balancer_exists() {
  local lb_name=$1
  aws elb describe-load-balancers --load-balancer-names "${lb_name}" >/dev/null 2>&1
}

security_group_exists() {
  local sg_id=$1
  aws ec2 describe-security-groups --group-ids "${sg_id}" >/dev/null 2>&1
}

capture_gateway_elb_targets() {
  local all_elbs svc_ref namespace service_name svc_json hostname match lb_name vpc_id sg_id

  aws_cleanup_available || return 0
  kube_api_available || {
    warn "Kubernetes API unavailable; skipping gateway ELB capture"
    return 0
  }

  all_elbs="$(aws elb describe-load-balancers --query 'LoadBalancerDescriptions[]' --output json 2>/dev/null || true)"
  if [[ -z "${all_elbs}" || "${all_elbs}" == "[]" ]]; then
    warn "No classic ELBs found while capturing gateway cleanup targets"
    return 0
  fi

  for svc_ref in "${GATEWAY_SERVICES[@]}"; do
    namespace="${svc_ref%/*}"
    service_name="${svc_ref#*/}"

    if ! svc_json="$(kubectl get svc "${service_name}" -n "${namespace}" -o json 2>/dev/null)"; then
      warn "Service ${svc_ref} not found while capturing gateway cleanup targets"
      continue
    fi

    hostname="$(printf '%s' "${svc_json}" | jq -r '.status.loadBalancer.ingress[]?.hostname // empty' | head -n1)"
    if [[ -z "${hostname}" ]]; then
      warn "Service ${svc_ref} does not have a load balancer hostname yet"
      continue
    fi

    if [[ "${hostname}" != *.elb.amazonaws.com ]]; then
      warn "Service ${svc_ref} is not backed by an AWS ELB hostname (${hostname}); skipping AWS cleanup"
      continue
    fi

    while IFS= read -r match; do
      [[ -z "${match}" ]] && continue

      lb_name="$(printf '%s' "${match}" | jq -r '.LoadBalancerName')"
      vpc_id="$(printf '%s' "${match}" | jq -r '.VPCId // empty')"

      append_unique GATEWAY_ELB_NAMES "${lb_name}"
      [[ -n "${vpc_id}" && -z "${GATEWAY_VPC_ID}" ]] && GATEWAY_VPC_ID="${vpc_id}"

      while IFS= read -r sg_id; do
        [[ -n "${sg_id}" ]] && append_unique GATEWAY_ELB_SECURITY_GROUPS "${sg_id}"
      done < <(printf '%s' "${match}" | jq -r '.SecurityGroups[]?')

      log "Captured gateway ELB ${lb_name} for ${svc_ref} (${hostname})"
    done < <(printf '%s' "${all_elbs}" | jq -c --arg hostname "${hostname}" '.[] | select(.DNSName == $hostname)')
  done
}

wait_for_gateway_services_deleted() {
  local svc_ref namespace service_name attempt

  kube_api_available || {
    warn "Kubernetes API unavailable; skipping gateway Service deletion wait"
    return 0
  }

  for svc_ref in "${GATEWAY_SERVICES[@]}"; do
    namespace="${svc_ref%/*}"
    service_name="${svc_ref#*/}"

    kubectl get svc "${service_name}" -n "${namespace}" >/dev/null 2>&1 || continue

    log "Waiting for Service ${svc_ref} to be deleted"
    for attempt in $(seq 1 60); do
      if ! kubectl get svc "${service_name}" -n "${namespace}" >/dev/null 2>&1; then
        success "Service ${svc_ref} deleted"
        break
      fi
      sleep 5
    done

    if kubectl get svc "${service_name}" -n "${namespace}" >/dev/null 2>&1; then
      warn "Service ${svc_ref} still exists after waiting; continuing with AWS ELB cleanup"
    fi
  done
}

cleanup_gateway_elbs() {
  local lb_name attempt

  [[ ${#GATEWAY_ELB_NAMES[@]} -gt 0 ]] || return 0

  aws_cleanup_available || return 0
  wait_for_gateway_services_deleted

  for lb_name in "${GATEWAY_ELB_NAMES[@]}"; do
    if load_balancer_exists "${lb_name}"; then
      log "Deleting AWS ELB ${lb_name}"
      aws elb delete-load-balancer --load-balancer-name "${lb_name}"
    fi

    for attempt in $(seq 1 60); do
      if ! load_balancer_exists "${lb_name}"; then
        success "AWS ELB ${lb_name} deleted"
        break
      fi
      sleep 5
    done

    if load_balancer_exists "${lb_name}"; then
      echo "Gateway ELB ${lb_name} still exists after cleanup wait"
      exit 1
    fi
  done
}

cleanup_gateway_elb_security_groups() {
  local sg_id sg_json group_name description vpc_id attempt

  [[ ${#GATEWAY_ELB_SECURITY_GROUPS[@]} -gt 0 ]] || return 0
  [[ -n "${GATEWAY_VPC_ID}" ]] || {
    warn "Gateway VPC ID not captured; skipping ELB security group cleanup"
    return 0
  }

  aws_cleanup_available || return 0

  for sg_id in "${GATEWAY_ELB_SECURITY_GROUPS[@]}"; do
    if ! sg_json="$(aws ec2 describe-security-groups --group-ids "${sg_id}" --output json 2>/dev/null)"; then
      continue
    fi

    group_name="$(printf '%s' "${sg_json}" | jq -r '.SecurityGroups[0].GroupName // empty')"
    description="$(printf '%s' "${sg_json}" | jq -r '.SecurityGroups[0].Description // empty')"
    vpc_id="$(printf '%s' "${sg_json}" | jq -r '.SecurityGroups[0].VpcId // empty')"

    if [[ "${vpc_id}" != "${GATEWAY_VPC_ID}" ]]; then
      warn "Skipping security group ${sg_id}; it is not in the captured gateway VPC"
      continue
    fi

    if [[ "${group_name}" != k8s-elb-* ]] && \
       [[ "${description}" != *"istio-gateway/public-ingressgateway"* ]] && \
       [[ "${description}" != *"istio-gateway/passthrough-ingressgateway"* ]]; then
      warn "Skipping security group ${sg_id}; it does not match the gateway ELB cleanup scope"
      continue
    fi

    log "Deleting leaked gateway ELB security group ${sg_id} (${group_name})"
    for attempt in $(seq 1 24); do
      aws ec2 delete-security-group --group-id "${sg_id}" >/dev/null 2>&1 || true
      if ! security_group_exists "${sg_id}"; then
        success "Gateway ELB security group ${sg_id} deleted"
        break
      fi
      sleep 5
    done

    if security_group_exists "${sg_id}"; then
      echo "Gateway ELB security group ${sg_id} still exists after cleanup wait"
      exit 1
    fi
  done
}


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
    for crd in $(kubectl get crds -o json 2>/dev/null | jq -r ".items[].metadata.name"); do
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

for cmd in kubectl kustomize jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Required command not found: $cmd"
    exit 1
  }
done

normalize_kubeconfig
capture_gateway_elb_targets

# Get all existing HelmReleases in bigbang namespace once
EXISTING_HRS=""
if test_helmrelease_crd; then
  EXISTING_HRS=$(kubectl get helmrelease -n bigbang -o jsonpath='{.items[*].metadata.name}')
else
  warn "HelmRelease CRD not found. Skipping HelmRelease deletions."
fi

# 1. Process the curated HELMRELEASES list
if test_helmrelease_crd; then
  for hr in "${HELMRELEASES[@]}"; do
    if [[ " $EXISTING_HRS " =~ " $hr " ]]; then
      delete_hr_and_dependents "$hr" "bigbang"
    else
      warn "HelmRelease bigbang/$hr not found, skipping."
    fi
  done
else
  warn "Skipping HelmRelease list processing: CRD not found."
fi

# Patching kiali and alloy to remove finalizers if they are stuck
kubectl patch kiali -n kiali kiali --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
kubectl patch alloy -n alloy alloy-alloy-logs --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true


# 2. Delete our BigBang kustomization
log "Delete the BigBang bigbang/envs/dev/"
kustomize build bigbang/envs/dev/ | kubectl delete -f - || true

# 3. Handle orphan HRs (not in list)

log "Scanning for leftover HelmReleases in bigbang namespace..."
if test_helmrelease_crd; then
  for hr in $(kubectl -n bigbang get helmreleases -o name | cut -d/ -f2); do
    if [[ ! " ${HELMRELEASES[*]} " =~ " $hr " ]]; then
      warn "Found orphan HelmRelease: $hr"
      delete_hr_and_dependents "$hr" "bigbang"
    fi
  done
else
  warn "Skipping orphan HelmRelease cleanup: CRD not found."
fi

log "Waiting for all HelmReleases in bigbang namespace to be deleted..."
if test_helmrelease_crd; then
  until [[ $(kubectl --namespace bigbang get helmreleases.helm.toolkit.fluxcd.io --no-headers) == "" ]]; do
      log "Waiting for cleanup of helmreleases..."
      sleep 5
  done
else
  warn "Skipping HelmRelease wait: CRD not found."
fi

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

cleanup_gateway_elbs
cleanup_gateway_elb_security_groups

success "BigBang and all associated resources have been destroyed successfully 🎉"

# 4. Clean up CRDs and CRs left behind
log "Cleaning up leftover istio CRDs "
istio_crds=$(kubectl get crds -o name 2>/dev/null | grep 'istio.io' || true)
for crd in $istio_crds; do
  if [[ -n "$crd" ]]; then
    log "  Deleting CRD $crd ..."
    kubectl delete "$crd" --ignore-not-found || true
  fi
done

grafana_crds=$(kubectl get crds -o name 2>/dev/null | grep 'grafana.com' || true)
for crd in $grafana_crds; do
  if [[ -n "$crd" ]]; then
    log "  Deleting CRD $crd ..."
    kubectl delete "$crd" --ignore-not-found || true
  fi
done

kiali_crds=$(kubectl get crds -o name 2>/dev/null | grep 'kiali.io' || true)
for crd in $kiali_crds; do
  if [[ -n "$crd" ]]; then
    log "  Deleting CRD $crd ..."
    kubectl delete "$crd" --ignore-not-found || true
  fi
done

wgpolicyk8s_crds=$(kubectl get crds -o name 2>/dev/null | grep 'wgpolicyk8s.io' || true)
for crd in $wgpolicyk8s_crds; do
  if [[ -n "$crd" ]]; then
    log "  Deleting CRD $crd ..."
    kubectl delete "$crd" --ignore-not-found || true
  fi
done

# 5. Patch and delete Terminating namespaces
log "Checking for Terminating namespaces..."
for ns in $(kubectl get ns --no-headers 2>/dev/null | awk '$2=="Terminating"{print $1}'); do
  warn "Namespace $ns is stuck in Terminating. Patching finalizers..."
  kubectl get ns "$ns" -o json \
    | jq '.spec.finalizers = []' \
    | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - || true
  success "Namespace $ns finalized."
done

success "Cluster cleanup completed!"
log "Remaining namespaces:"
kubectl get ns || true
