# EKS SOPS Decryption Setup

This document describes the manual changes required to enable SOPS decryption with AWS KMS on EKS clusters.

## Prerequisites

- EKS cluster with Flux installed
- AWS KMS key with decryption permissions
- IAM role with KMS decryption policy

## Manual Changes Required

### 1. Enable Feature Gate for Kustomize Controller

The `ObjectLevelWorkloadIdentity` feature gate is required for Flux to use IAM roles with service accounts for SOPS decryption.

**File:** `flux/kustomization.yaml`

Add the feature gate to the kustomize-controller deployment:

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
            automountServiceAccountToken: true
            containers:
            - name: manager
              args:
                - --feature-gates=ObjectLevelWorkloadIdentity=true
```

Apply changes:
```bash
kustomize build flux/ | kubectl apply -f -
kubectl rollout status deployment/kustomize-controller -n flux-system
```

### 2. Create Service Account with IAM Role (Two Options)

#### Option A: EKS Pod Identity (Recommended for EKS)

Create the service account in the namespace where secrets are deployed (typically `bigbang`):

```bash
# Create service account
kubectl create sa kustomize-controller -n bigbang

# Add IAM role annotation
kubectl annotate sa kustomize-controller -n bigbang \
  eks.amazonaws.com/role-arn=arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME \
  --overwrite
```

Create the EKS Pod Identity association:

```bash
aws eks create-pod-identity-association \
  --cluster-name YOUR_CLUSTER_NAME \
  --namespace bigbang \
  --service-account kustomize-controller \
  --role-arn arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME
```

#### Option B: Node IAM Role (Alternative)

If the EKS node IAM role already has KMS decryption permissions, no additional setup is needed. Just ensure the kustomize-controller pod can access the KMS key through the node's IAM role.

### 3. Configure Kustomization for Decryption

**File:** `bigbang/envs/dev/bigbang-helm-values.yaml`

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: bigbang-secrets
  namespace: bigbang
spec:
  # ... other config
  decryption:
    provider: sops
    # Optional: specify service account for IAM authentication
    # serviceAccountName: bigbang/kustomize-controller
    # Remove this line to use node IAM role
```

### 4. IAM Policy Requirements

The IAM role must have permission to decrypt with your KMS key:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "arn:aws:kms:REGION:ACCOUNT_ID:key/KMS_KEY_ID"
    }
  ]
}
```

## Troubleshooting

### Error: ServiceAccount not found

If you see:
```
failed to get service account 'bigbang/kustomize-controller': ServiceAccount "kustomize-controller" not found
```

Ensure the service account exists in the namespace where the Kustomization runs.

### Error: Failed to get data key

If you see:
```
failed to decrypt sops data key with AWS KMS: operation error KMS: Decrypt
```

Check:
1. IAM role has KMS decryption permissions
2. KMS key policy allows the IAM role to decrypt
3. EKS Pod Identity association is correctly configured

## Verification

```bash
# Check kustomization status
kubectl get kustomization -A

# Check secrets are decrypted
kubectl get secrets -n bigbang

# Check kustomize-controller logs
kubectl logs deployment/kustomize-controller -n flux-system -f
```
