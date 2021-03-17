#!/usr/bin/env bash

set -eux

# Deploy flux and wait for it to be ready
echo "Installing Flux"
flux --version
flux check --pre

# Install flux in the cluster
kubectl create ns flux-system || true

kubectl create secret docker-registry private-registry -n flux-system \
   --docker-server=registry1.dsop.io \
   --docker-username=${REGISTRY1_USERNAME} \
   --docker-password=${REGISTRY1_PASSWORD} \
   --docker-email=bigbang@bigbang.dev || true

kubectl apply -f fluxcd/flux.yaml

# Wait for flux
kubectl wait --for=condition=available --timeout 300s -n "flux-system" "deployment/helm-controller"
kubectl wait --for=condition=available --timeout 300s -n "flux-system" "deployment/source-controller"

# check the flux 
flux check

# Deploy BigBang using dev sized scaling
echo "Installing BigBang"
helm upgrade -i bigbang chart -n bigbang --create-namespace \
  --set registryCredentials.username='robot$p1-dev' --set registryCredentials.password=${REGISTRY1_PASSWORD} \
  -f values.yaml
