#!/usr/bin/env bash

set -ux

istioctl operator remove --force
istioctl manifest generate | kubectl delete -f -

sleep 60

kustomize build bigbang/envs/dev/ | kubectl delete -f -

sleep 30

kubectl --namespace istio-system get istiooperator

kubectl delete -k flux

sleep 60

kubectl delete -k cluster-init

sleep 100

kubectl get ns

DEFAULT_NAMESPACES_COUNT="4"

NAMESPACES_COUNT=$(kubectl get ns | sed 1d | wc -l)

if [[ "${DEFAULT_NAMESPACES_COUNT}" != "${NAMESPACES_COUNT}"  ]]; then
    echo "namespaces still pending cleanup"
    exit 1
fi
