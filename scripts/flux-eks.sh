#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-}"
ROLE_ARN="${ROLE_ARN:-}"

[[ -z "$CLUSTER_NAME" ]] && echo "CLUSTER_NAME required" && exit 1
[[ -z "$ROLE_ARN" ]] && echo "ROLE_ARN required" && exit 1

KUSTOMIZATION_FILE="flux/kustomization.yaml"

if [[ -f "$KUSTOMIZATION_FILE" ]]; then
  if ! grep -q "ObjectLevelWorkloadIdentity" "$KUSTOMIZATION_FILE"; then
    cat >> "$KUSTOMIZATION_FILE" << 'EOF'
  - target:
      kind: Deployment
      name: kustomize-controller
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: kustomize-controller
      spec:
        template:
          spec:
            containers:
            - name: manager
              args:
                - --feature-gates=ObjectLevelWorkloadIdentity=true
EOF
  fi
fi

kustomize build flux | kubectl apply -f -

kubectl patch deployment kustomize-controller \
  -n flux-system \
  --type merge \
  -p '{"spec":{"template":{"spec":{"serviceAccountName":"kustomize-controller"}}}}'

kubectl rollout restart deployment/kustomize-controller -n flux-system

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" \
  --namespace flux-system \
  --service-account kustomize-controller \
  --role-arn "$ROLE_ARN" 2>/dev/null || true

kubectl delete pods -l app=kustomize-controller -n flux-system --ignore-not-found=true
