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

kubectl wait --for=condition=Ready=True --timeout 500s helmreleases bigbang -n bigbang # This confirms BigBang Chart is deployed, now we can check all other charts

hr=$(kubectl get hr -n bigbang -o custom-columns=NAME:.metadata.name --no-headers=true)
kubectl wait --for=condition=Ready=True --timeout 3600s helmreleases $hr -n bigbang
