#!/usr/bin/env bash

set -ux

kubectl --namespace istio-system delete istiooperators.install.istio.io istiocontrolplane 

until [[ $(kubectl --namespace istio-system get all --no-headers) == "" ]]; do
    echo "Waiting for cleanup of istio..."
    sleep 5
done

kubectl --namespace kiali delete kialis.kiali.io kiali

until [[ $(kubectl --namespace kiali get kialis.kiali.io --no-headers) == "" ]]; do
    echo "Waiting for cleanup of kiali..."
    sleep 5
done

kustomize build bigbang/envs/dev/ | kubectl delete -f -

until [[ $(kubectl --namespace bigbang get helmreleases.helm.toolkit.fluxcd.io --no-headers) == "" ]]; do
    echo "Waiting for cleanup of helmreleases..."
    sleep 5
done

until [[ $(kubectl --namespace bigbang get gitrepositories.source.toolkit.fluxcd.io --no-headers) == "" ]]; do
    echo "Waiting for cleanup of gitrepositories..."
    sleep 5
done

kustomize build flux/ | kubectl delete -f -

until [[ $(kubectl --namespace flux-system get all --no-headers) == "" ]]; do
    echo "Waiting for cleanup of flux components..."
    sleep 5
done

kustomize build cluster-init/ | kubectl delete -f -

until [[ $(kubectl get ns bigbang --no-headers) == "" ]]; do
    echo "Waiting for cleanup of bigbang namespace..."
    sleep 5
done

until [[ $(kubectl get ns flux-system --no-headers) == "" ]]; do
    echo "Waiting for cleanup of flux-system namespace..."
    sleep 5
done

kubectl get ns
