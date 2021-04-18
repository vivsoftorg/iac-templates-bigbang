#!/usr/bin/env bash

set -u -o pipefail

kubectl delete ns bigbang
kustomize build bigbang/envs/dev/ | kubectl delete -f -
kubectl delete ns flux
kubectl delete -k flux
kubectl delete -k cluster-init

