# Deploying Big Bang on AKS with Azure Key Vault SOPS

This guide documents the AKS-specific setup required when deploying Big Bang
through ENBUILD while using Azure Key Vault as the SOPS backend.

This is an operator guide, not a template-default guide. AKS-specific values,
identity wiring, and sizing overrides should be supplied at deployment time and
must not be hardcoded into the shared Big Bang template.

## What this guide covers

- how to use Azure Key Vault for SOPS encryption and Flux decryption
- how to configure AKS so the Flux `kustomize-controller` can use the Azure key
- what ENBUILD users must provide during deployment
- what to validate before calling the AKS path complete

## What this guide does not change

- Big Bang package tags
- shared default values under `bigbang/envs/dev/values/*.yaml`
- `deploy.sh` kubeconfig handling

If cluster-specific tuning is required, pass it through ENBUILD values and
secrets for that deployment.

## Prerequisites

You need all of the following before attempting the AKS path:

1. An AKS cluster with:
   - `oidc_issuer_enabled = true`
   - `workload_identity_enabled = true`
2. An Azure Key Vault and cryptographic key for SOPS, for example:
   - `sops-key`
   - `sops-aks-key`
3. A user-assigned managed identity for Flux decryption
4. Key Vault permissions on that identity for:
   - `encrypt`
   - `decrypt`
5. Access to the AKS kubeconfig as a file in CI
6. Registry and repository credentials required by Big Bang

## Recommended identity model

The historical reference for this flow is
`SOPS_with_Azure_KeyVault_secret_and_AKS_AAD_Pod_Identity.pdf`, but that
document uses the older AAD Pod Identity pattern.

For current AKS deployments, prefer Azure Workload Identity.

The current repo already contains a helper script that reflects the intended
modern pattern:

- `scripts/workload_identity.sh`

Use that flow as the canonical direction for new AKS work.

## Step 1: Create or identify the Azure Key Vault key

Create or reuse the Key Vault key that will be referenced in `sops.yaml`.

Example commands:

```bash
export KEY_VAULT_NAME=bigbang-demo-enbuild
export KEY_VAULT_RESOURCE_GROUP=enbuild-demo
export LOCATION=eastus
export SOPS_KEY_NAME=sops-key

az keyvault create \
  --name "$KEY_VAULT_NAME" \
  --resource-group "$KEY_VAULT_RESOURCE_GROUP" \
  --location "$LOCATION"

az keyvault key create \
  --name "$SOPS_KEY_NAME" \
  --vault-name "$KEY_VAULT_NAME" \
  --protection software \
  --ops encrypt decrypt
```

Capture the full key URL for use in `sops.yaml`.

## Step 2: Create the managed identity used by Flux

Create or reuse a user-assigned managed identity dedicated to SOPS decryption.

Example:

```bash
export IDENTITY_NAME=SopsDecryptorIdentity
export IDENTITY_RESOURCE_GROUP=enbuild-demo

az identity create \
  -n "$IDENTITY_NAME" \
  -g "$IDENTITY_RESOURCE_GROUP" \
  -l "$LOCATION"
```

Grant that identity access to the Key Vault key:

```bash
OBJECT_ID=$(az identity show \
  -g "$IDENTITY_RESOURCE_GROUP" \
  -n "$IDENTITY_NAME" \
  --query principalId -o tsv)

az keyvault set-policy \
  --name "$KEY_VAULT_NAME" \
  --resource-group "$KEY_VAULT_RESOURCE_GROUP" \
  --object-id "$OBJECT_ID" \
  --key-permissions encrypt decrypt
```

If your cluster-side flow also reads secrets from Key Vault, include the
minimum additional secret permissions required by that path.

## Step 3: Bind the identity to Flux using Workload Identity

The Flux `kustomize-controller` must be able to exchange its service-account
token for the Azure managed identity.

The validated pattern is:

1. Read the AKS OIDC issuer URL
2. Create a federated credential on the managed identity
3. Annotate the Flux service account with the managed identity client ID
4. Restart `kustomize-controller`

Use the helper script in this repo when possible:

```bash
scripts/workload_identity.sh
```

That flow expects or derives:

- `AKS_CLUSTER_NAME`
- `RESOURCE_GROUP_NAME`
- `KEY_VAULT_NAME`
- `KEY_VAULT_RESOURCE_GROUP`
- `IDENTITY_NAME`
- `IDENTITY_RESOURCE_GROUP`
- `FLUX_NAMESPACE`
- `FLUX_SERVICE_ACCOUNT`

After the patch, verify the service account annotation:

```bash
kubectl -n flux-system get serviceaccount kustomize-controller -o yaml
```

Then restart the controller:

```bash
kubectl rollout restart deployment/kustomize-controller -n flux-system
```

## Step 4: Encrypt secrets with Azure Key Vault

Create a `sops.yaml` that points to the Azure Key Vault key URL.

Example:

```yaml
---
creation_rules:
  - azure_keyvault: https://YOUR-KEY-VAULT.vault.azure.net/keys/sops-key/KEY_VERSION
    encrypted_regex: "^(data|stringData)$"
```

Validate the SOPS path before involving Flux:

```bash
sops --config sops.yaml -e sample-secret.yaml > sample-secret-enc.yaml
sops -d sample-secret-enc.yaml
```

Do not use the AWS KMS path for AKS.

## Step 5: Provide the correct inputs in ENBUILD

When deploying Big Bang through ENBUILD to AKS:

1. Provide the `sops.yaml` content that references Azure Key Vault
2. Provide registry credentials for the Flux and Big Bang images
3. Provide repository credentials for dependent charts and repos
4. Provide the cluster kubeconfig as a file-backed input in CI
5. Provide any AKS-specific value overrides through ENBUILD values/secrets

Examples of overrides that may be needed on small AKS dev clusters:

- reduced package CPU and memory requests
- Alloy annotations required by AKS networking
- removal of EKS-specific node-affinity assumptions
- package-specific tuning for daemonsets or sidecars

These should be treated as deployment inputs, not shared defaults.

### Suggested ENBUILD input checklist for AKS

At minimum, the operator should be ready to provide:

1. Azure infrastructure inputs
   - service principal client ID
   - tenant ID
   - subscription ID
   - service principal client secret
   - target resource group / region for the AKS cluster path
2. Big Bang repo inputs
   - registry URL
   - registry username
   - registry password or token
   - repository username
   - repository password or token
3. Big Bang deployment inputs
   - `sops.yaml` that references the Azure Key Vault key URL
   - domain and TLS material for the target ingress domain
   - any AKS-specific values overrides required by the target cluster size
4. Kubeconfig delivery
   - kubeconfig must be available to the deploy job as a file

If you are deploying into a small AKS dev cluster, plan for additional user
overrides rather than assuming the generic defaults will converge unchanged.

## Step 6: CI runner expectations

The deployment logic should consume kubeconfig as a file path.

For GitLab:

- store kubeconfig as a file-type variable
- make it available to the deploy job as a file

For GitHub Actions:

- store kubeconfig content as a secret
- write it to a file in the workflow before calling `deploy.sh`

Do not add kubeconfig content-to-file normalization to the shared `deploy.sh`
for the AKS path.

## Step 7: Prove Flux can decrypt before deploying full Big Bang

Before attempting the full Big Bang install, validate the Azure Key Vault path
with a small Flux-managed encrypted secret.

Recommended sequence:

1. Create a test namespace manifest
2. Create a Kubernetes Secret manifest with plain `stringData`
3. Encrypt that secret with `sops` using the Azure Key Vault-backed `sops.yaml`
4. Store the encrypted manifest in a Git repo that Flux can read
5. Create a Flux `GitRepository`
6. Create a Flux `Kustomization` with:
   - `decryption.provider: sops`
7. Wait for the `GitRepository` and `Kustomization` to become `Ready=True`
8. Verify the secret exists in-cluster with decrypted values

Example verification commands:

```bash
kubectl -n flux-system wait gitrepository/flux-azure-sops-proof --for=condition=ready=True --timeout=3m
kubectl -n flux-system wait kustomization/flux-azure-sops-proof --for=condition=ready=True --timeout=5m
kubectl -n sops-proof get secret azure-sops-proof -o jsonpath='{.data.message}' | base64 -d
```

If this proof fails, do not proceed to the full Big Bang deployment until the
Key Vault identity mapping and controller permissions are corrected.

## Step 8: AKS-specific operator notes from validation

The following notes came from live AKS validation and should be treated as
operator guidance, not shared template defaults.

### Workload Identity details

- The federated credential must use the **current AKS OIDC issuer URL** for the
  cluster being deployed, not a stale issuer from an older cluster.
- The `flux-system/kustomize-controller` service account must carry the Azure
  Workload Identity annotations for the managed identity client and tenant.
- Restart `kustomize-controller` after changing the service account annotation.

### Small AKS cluster sizing and policy notes

On smaller AKS dev clusters, some packages may require user-supplied overrides.
Examples observed during validation:

- reduced CPU and memory requests for:
  - `istiod`
  - `grafana`
  - `monitoring`
  - `tempo`
  - `neuvector`
- package-specific wait or hook jobs may need smaller requests
- some pods may need:
  - sidecar injection disabled where it is unnecessary
  - `automountServiceAccountToken: false` where cluster policy requires it

These should be passed as deployment-specific values and reviewed per
environment.

### Troubleshooting patterns observed on AKS

If Flux or Big Bang packages do not converge on AKS, check these first:

1. Flux / SOPS
   - `GitRepository` ready
   - `Kustomization` ready
   - `kustomize-controller` has the right Workload Identity annotations
   - test encrypted secret decrypts successfully in-cluster
2. Cluster policy interactions
   - required labels
   - service-account token automount restrictions
   - pod-sidecar injection policy
3. Cluster capacity
   - insufficient CPU for daemonsets, hooks, or mesh sidecars
4. Package-specific service discovery
   - internal headless services publishing addresses early enough for startup

Document the exact overrides and operator actions used for each environment
rather than making the shared template AKS-specific by default.

## Validation checklist

Before marking the AKS + Big Bang path complete, validate all of the following:

1. SOPS local validation
   - Azure Key Vault encryption works
   - Azure Key Vault decryption works

2. AKS identity validation
   - AKS OIDC issuer is enabled
   - workload identity is enabled
   - federated credential exists for Flux
   - `kustomize-controller` service account has the workload identity annotation

3. Flux validation
   - `kustomize-controller` can reconcile without Azure auth errors
   - an encrypted test secret can be decrypted through Flux

4. ENBUILD validation
   - ENBUILD creates the GitLab deployment repo
   - the pipeline sees kubeconfig as a file
   - Flux can decrypt an Azure-Key-Vault-encrypted test secret
   - Big Bang deploy runs successfully against AKS

5. Runtime validation
   - `kubectl -n bigbang get hr`
   - Flux controllers healthy
   - Big Bang packages reach the expected ready state

## Evidence to capture

For handoff or RTM evidence, collect:

- Key Vault key name and resource identifiers used
- managed identity name and client ID
- federated credential creation evidence
- service account annotation output
- Flux test secret decryption output
- encrypted/decrypted sample secret output
- ENBUILD-generated GitLab repo and pipeline links
- `kubectl -n bigbang get hr`
- any AKS-specific values supplied through ENBUILD for that run

## Legacy reference

The following document is still useful for conceptual background, but it uses
AAD Pod Identity and should not be copied blindly into current AKS guidance:

- `SOPS_with_Azure_KeyVault_secret_and_AKS_AAD_Pod_Identity.pdf`

Prefer the Workload Identity flow for current implementations.
