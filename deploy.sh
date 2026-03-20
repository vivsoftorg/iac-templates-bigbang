#!/usr/bin/env bash

set -euo pipefail

# Colors for pretty output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
  echo -e "${CYAN}==> $1${NC}"
}

success() {
  echo -e "${GREEN}✔ $1${NC}"
}

warn() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

error_exit() {
  echo -e "${RED}✖ $1${NC}"
  exit 1
}

normalize_kubeconfig() {
  if [[ -z "${KUBECONFIG:-}" ]]; then
    error_exit "KUBECONFIG is not set"
  fi

  if [[ -f "${KUBECONFIG}" ]]; then
    return
  fi

  local kubeconfig_file
  kubeconfig_file="$(mktemp /tmp/enbuild-kubeconfig.XXXXXX.yaml)"
  printf '%s\n' "${KUBECONFIG}" > "${kubeconfig_file}"
  chmod 600 "${kubeconfig_file}"
  export KUBECONFIG="${kubeconfig_file}"
  success "Materialized KUBECONFIG content to ${kubeconfig_file}"
}

sync_registry_secret() {
  local source_namespace="$1"
  local secret_name="$2"
  local target_namespace="$3"

  kubectl get namespace "${target_namespace}" >/dev/null 2>&1 || kubectl create namespace "${target_namespace}" >/dev/null
  kubectl get secret "${secret_name}" -n "${source_namespace}" -o json | \
    python3 -c 'import json, sys
target_namespace = sys.argv[1]
doc = json.load(sys.stdin)
for key in ["uid", "resourceVersion", "creationTimestamp", "managedFields", "selfLink"]:
    doc["metadata"].pop(key, None)
doc["metadata"]["namespace"] = target_namespace
doc["metadata"]["annotations"] = {}
print(json.dumps(doc))' "${target_namespace}" | kubectl apply -f - >/dev/null
}

# Preflight checks
for cmd in flux kubectl sops kustomize; do
  command -v $cmd >/dev/null 2>&1 || error_exit "$cmd not found in PATH"
done
success "All required tools are available"

normalize_kubeconfig

# Deploy Flux
log "Checking Flux prerequisites"
flux check --pre || error_exit "Flux prerequisites failed"

log "Applying PSP and StorageClass (cluster-init/)"
kubectl apply -k cluster-init/ || error_exit "Failed to apply cluster-init manifests"

if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  log "Creating Flux SOPS AWS KMS secret"
  kubectl create secret generic sops-aws-kms \
    -n bigbang \
    --from-literal=sops.aws-kms="$(cat <<EOF
aws_access_key_id: ${AWS_ACCESS_KEY_ID}
aws_secret_access_key: ${AWS_SECRET_ACCESS_KEY}
${AWS_SESSION_TOKEN:+aws_session_token: ${AWS_SESSION_TOKEN}}
EOF
)" \
    --dry-run=client -o yaml | kubectl apply -f - || error_exit "Failed to create sops-aws-kms secret"
  success "Flux SOPS AWS KMS secret applied"
else
  warn "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not set; expecting sops-aws-kms secret to already exist in bigbang namespace"
fi

# Private registry credentials
log "Creating private registry credentials"
sops -d bigbang/envs/dev/secrets/private-registry.enc.yaml | kubectl apply -n flux-system -f - || error_exit "Failed to create creds in flux-system"
sops -d bigbang/envs/dev/secrets/private-registry.enc.yaml | kubectl apply -n bigbang -f - || error_exit "Failed to create creds in bigbang"
success "Private registry credentials applied"

# Install Flux
log "Deploying Flux manifests"
kustomize build flux/ | kubectl apply -f - || error_exit "Failed to apply Flux manifests"
log "Waiting for Flux to become ready"
flux_ready=0
for attempt in $(seq 1 20); do
  if flux check; then
    flux_ready=1
    break
  fi
  warn "Flux not ready yet (attempt ${attempt}/20); retrying in 30s"
  sleep 30
done
[[ "${flux_ready}" -eq 1 ]] || error_exit "Flux not ready"
success "Flux installed successfully"

# Repository credentials
log "Creating repository credentials"
sops -d bigbang/envs/dev/secrets/repository-credentials.enc.yaml | kubectl apply -f - || error_exit "Failed to create repository credentials"
success "Repository credentials applied"

# Install BigBang
log "Deploying BigBang"
kustomize build bigbang/envs/dev/ | kubectl apply -f - || error_exit "Failed to apply BigBang manifests"

log "Waiting for BigBang HelmRelease to be Ready (timeout 500s)"
kubectl wait --for=condition=Ready=True --timeout=500s helmreleases bigbang -n bigbang || error_exit "BigBang HelmRelease not ready in time"

log "Syncing private registry credentials to Big Bang target namespaces"
kubectl get hr -n bigbang -o jsonpath='{range .items[*]}{.spec.targetNamespace}{"\n"}{end}' | sort -u | while read -r namespace; do
  [[ -z "${namespace}" ]] && continue
  sync_registry_secret "bigbang" "private-registry" "${namespace}"
done
success "Private registry credentials synced"

# Wait for all dependent HelmReleases
log "Waiting for all HelmReleases in bigbang namespace (timeout 3600s)"
hr=$(kubectl get hr -n bigbang -o custom-columns=NAME:.metadata.name --no-headers=true)
kubectl wait --for=condition=Ready=True --timeout=3600s helmreleases $hr -n bigbang || error_exit "One or more HelmReleases failed to become ready"

success "BigBang and all HelmReleases deployed successfully 🎉"
kubectl get hr -n bigbang

log "Following VirtualService are created:"
kubectl get virtualservices.networking.istio.io -A
