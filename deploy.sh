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

# Preflight checks
for cmd in flux kubectl sops kustomize; do
  command -v $cmd >/dev/null 2>&1 || error_exit "$cmd not found in PATH"
done
success "All required tools are available"

# Deploy Flux
log "Checking Flux prerequisites"
flux check --pre || error_exit "Flux prerequisites failed"

log "Applying PSP and StorageClass (cluster-init/)"
kubectl apply -k cluster-init/ || error_exit "Failed to apply cluster-init manifests"

# Private registry credentials
log "Creating private registry credentials"
sops -d bigbang/envs/dev/secrets/private-registry.enc.yaml | kubectl apply -n flux-system -f - || error_exit "Failed to create creds in flux-system"
sops -d bigbang/envs/dev/secrets/private-registry.enc.yaml | kubectl apply -n bigbang -f - || error_exit "Failed to create creds in bigbang"
success "Private registry credentials applied"

# Install Flux
log "Deploying Flux manifests"
kustomize build flux/ | kubectl apply -f - || error_exit "Failed to apply Flux manifests"
flux check || error_exit "Flux not ready"
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

# Wait for all dependent HelmReleases
log "Waiting for all HelmReleases in bigbang namespace (timeout 3600s)"
hr=$(kubectl get hr -n bigbang -o custom-columns=NAME:.metadata.name --no-headers=true)
kubectl wait --for=condition=Ready=True --timeout=3600s helmreleases $hr -n bigbang || error_exit "One or more HelmReleases failed to become ready"

success "BigBang and all HelmReleases deployed successfully 🎉"

log "Following VirtualService are created:"
kubectl get virtualservices.networking.istio.io -A
