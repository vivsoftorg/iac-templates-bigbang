# EKS SOPS Decryption Setup

Manual steps to enable SOPS decryption with AWS KMS on EKS clusters using EKS Pod Identity.

## Prerequisites

- EKS cluster with Flux installed
- KMS key ARN

## Manual Steps


### 1. Create IAM Role for Flux SOPS Decryption

Create the IAM role with a trust policy for EKS Pod Identity:

```bash
aws iam create-role \
  --role-name <CLUSTER_NAME>-flux-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "pods.eks.amazonaws.com"
        },
        "Action": ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  }'
```

Create and attach the KMS decryption policy:

```bash
aws iam create-policy \
  --policy-name <CLUSTER_NAME>-flux-sops-policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["kms:Decrypt", "kms:DescribeKey"],
        "Resource": "<KMS_KEY_ARN>"
      }
    ]
  }'

aws iam attach-role-policy \
  --role-name <CLUSTER_NAME>-flux-role \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/<CLUSTER_NAME>-flux-sops-policy
```

### 2. Enable Feature Gate for Kustomize Controller

Add the feature gate to `flux/kustomization.yaml`:

```yaml
patches:
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
```

Apply changes:

```bash
kustomize build flux/ | kubectl apply -f -
```

### 3. Patch Deployment to Use Service Account

```bash
kubectl patch deployment kustomize-controller \
  -n flux-system \
  --type merge \
  -p '{"spec":{"template":{"spec":{"serviceAccountName":"kustomize-controller"}}}}'
```

### 4. Create Pod Identity Association

```bash
aws eks create-pod-identity-association \
  --cluster-name <CLUSTER_NAME> \
  --namespace flux-system \
  --service-account kustomize-controller \
  --role-arn <IAM_ROLE_ARN>
```

### 5. Restart Kustomize Controller Pod

Delete existing pods to pick up the new identity:

```bash
kubectl delete pods -l app=kustomize-controller -n flux-system
```

Wait for the new pod to be ready:

```bash
kubectl rollout status deployment/kustomize-controller -n flux-system
```

## Verification

```bash
# Check kustomization status
kubectl get kustomization -A

# Check kustomize-controller logs for decryption errors
kubectl logs deployment/kustomize-controller -n flux-system --tail=50
```

## Troubleshooting

### Error: Failed to decrypt sops data key

```
failed to decrypt sops data key with AWS KMS: operation error KMS: Decrypt
```

Check:
1. IAM role has KMS decryption permissions
2. KMS key policy allows the IAM role to decrypt
3. Pod Identity association is created in `flux-system` namespace
4. Service account name is `kustomize-controller`
