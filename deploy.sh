#!/usr/bin/env bash

set -eu -o pipefail

# Deploy flux and wait for it to be ready
echo "Installing Flux"
flux check --pre

# install PSP and StorageClass
kubectl apply -k cluster-init/
# create private registry credentials
sops -d bigbang/envs/dev/secrets/private-registry.enc.yaml | kubectl apply -f -
# install flux
kustomize build flux/ | kubectl apply -f -
flux check
# create repository credentials
sops -d bigbang/envs/dev/secrets/repository-credentials.enc.yaml | kubectl apply -f -
# install bigbang
kustomize build bigbang/envs/dev/ | kubectl apply -f -

kubectl wait --for=condition=Ready=True --timeout 500s helmreleases bigbang
kubectl wait --for=condition=Ready=True --timeout 700s helmreleases gatekeeper
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases istio-operator
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases istio
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases jaeger
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases kiali
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases ek
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases cluster-auditor
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases fluent-bit
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases eck-operator
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases monitoring
kubectl wait --for=condition=Ready=True --timeout 500s helmreleases twistlock
