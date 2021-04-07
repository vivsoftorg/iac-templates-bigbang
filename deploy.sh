#!/usr/bin/env bash

set -eu -o pipefail

# Deploy flux and wait for it to be ready
echo "Installing Flux"
flux --version
flux check --pre

# create flux namespace
kubectl create ns flux-system || true

# delete flux private-registry secret
kubectl delete secret private-registry -n flux-system || true

# create flux private-registry secret
kubectl create secret docker-registry private-registry -n flux-system \
   --docker-server=registry1.dso.mil \
   --docker-username=${REGISTRY_USERNAME} \
   --docker-password=${REGISTRY_PASSWORD} || true

# install flux
kubectl apply -f ./pb-reqs/flux.yaml

# # wait for flux
flux check

# Create bigbang namespace
kubectl apply -f ./pb-reqs/namespace.yaml

# create git repository credentials
kubectl delete secret repository-credentials -n bigbang || true
kubectl create secret generic repository-credentials -n bigbang \
   --from-literal=username=${REPO_USER} \
   --from-literal=password=${REPO_PASSWORD}

# # deploy bigbang
kustomize build bigbang/envs/dev/ | kubectl apply -f -

# # deploy BigBang using dev sized scaling
# echo "Installing BigBang"
# helm upgrade -i bigbang chart -n bigbang --create-namespace \
# --set registryCredentials[0].username='robot$p1-dev' --set registryCredentials[0].password=${REGISTRY1_PASSWORD} \
# --set registryCredentials[0].registry=registry1.dso.mil \
# -f values.yaml

# # apply secrets kustomization pointing to current branch
# echo "Deploying secrets from the ${CI_COMMIT_REF_NAME} branch"
# if [[ -z "${CI_COMMIT_TAG}" ]]; then
#   cat tests/ci/shared-secrets.yaml | sed 's|master|'$CI_COMMIT_REF_NAME'|g' | kubectl apply -f -
# else
#   # NOTE: $CI_COMMIT_REF_NAME = $CI_COMMIT_TAG when running on a tagged build
#   cat tests/ci/shared-secrets.yaml | sed 's|branch: master|tag: '$CI_COMMIT_REF_NAME'|g' | kubectl apply -f -
# fi
