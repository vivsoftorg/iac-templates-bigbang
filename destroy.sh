#!/usr/bin/env bash

set -eu -o pipefail

kustomize build bigbang/envs/dev/ | kubectl delete -f -
kubectl delete -k flux
kubectl delete -k cluster-init
