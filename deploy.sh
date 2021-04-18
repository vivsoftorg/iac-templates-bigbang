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
kubectl apply -k flux/
flux check
# create repository credentials
sops -d bigbang/envs/dev/secrets/repository-credentials.enc.yaml | kubectl apply -f -
# install bigbang
kustomize build bigbang/envs/dev/ | kubectl apply -f -

