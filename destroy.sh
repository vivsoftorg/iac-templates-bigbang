#!/usr/bin/env bash

set -u

kustomize build bigbang/envs/dev/ | kubectl delete -f -

sleep 300

kubectl delete -k flux

sleep 300

kubectl get ns

DEFAULT_NAMESPACES_COUNT="4"

NAMESPACES_COUNT=$(kubectl get ns | sed 1d | wc -l)

if [[ "${DEFAULT_NAMESPACES_COUNT}" != "${NAMESPACES_COUNT}"  ]]; then
    echo "namespaces still pending cleanup"
    exit 1
fi
