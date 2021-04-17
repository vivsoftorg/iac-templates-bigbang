#!/usr/bin/env bash

set -u -o pipefail

kustomize build bigbang/envs/dev/ | kubectl delete -f -
kubectl delete -k flux
kubectl delete -k cluster-init
