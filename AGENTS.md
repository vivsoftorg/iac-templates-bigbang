# AGENTS.md - BigBang IaC Template

## Overview

This is a BigBang infrastructure template repository that deploys standard BigBang components on Kubernetes clusters using GitOps (Flux). Supports both GitHub and GitLab CI/CD pipelines.

## Repository Structure

```
.
├── deploy.sh              # Main deployment script
├── destroy.sh             # Cleanup/destruction script
├── gitlab-ci.yml         # GitLab CI (copy to .gitlab-ci.yaml)
├── .github/workflows/    # GitHub Actions workflows
├── cluster-init/         # Cluster initialization manifests
├── flux/                 # Flux GitOps configuration
├── bigbang/envs/dev/    # Environment-specific configs
│   ├── values/          # Package Helm values
│   ├── secrets/         # Encrypted secrets (sops)
│   └── bigbang-*.yaml
└── scripts/             # Helper scripts
```

## Build, Lint, and Test Commands

### CI/CD Triggers

| Platform | Trigger | Action |
|----------|---------|--------|
| GitHub | Commit msg "run-ci" | Runs deploy.sh |
| GitLab | Commit msg "run-ci" | Runs deploy.sh |
| GitLab | Manual trigger | Runs destroy.sh |

### Local Validation

```bash
# Preflight - verify required tools (flux, kubectl, sops, kustomize)
./deploy.sh

# Validate Flux manifests
flux check --pre

# Dry-run cluster-init manifests
kubectl apply -k cluster-init/ --dry-run=client

# Dry-run BigBang manifests
kustomize build bigbang/envs/dev/ | kubectl apply --dry-run=client

# Validate kustomize builds
kustomize build flux/
kustomize build bigbang/envs/dev/

# YAML syntax validation
yamllint bigbang/envs/dev/values/*.yaml
```

### Secrets Management

```bash
# View encrypted secrets (read-only)
sops bigbang/envs/dev/secrets/private-registry.enc.yaml

# Edit secrets (requires SOPS_KEY env var)
sops bigbang/envs/dev/secrets/private-registry.enc.yaml
```

## Code Style Guidelines

### YAML Files

- 2-space indentation
- kebab-case for keys
- Uppercase booleans: `true`/`false` (not `True`/`False`)
- Quote potential booleans: `"true"` vs `true`

```yaml
# Good
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-config
  namespace: bigbang
data:
  key: value
```

### Shell Scripts

- Use `#!/usr/bin/env bash`
- Use `set -euo pipefail`
- Functions: `log()`, `success()`, `warn()`, `error_exit()`
- Colored output with ANSI codes
- Check required commands at start

```bash
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
NC='\033[0m'

error_exit() {
  echo -e "${RED}✖ $1${NC}"
  exit 1
}

for cmd in flux kubectl; do
  command -v $cmd >/dev/null 2>&1 || error_exit "$cmd not found"
done
```

### Kubernetes Resources

- Lowercase with hyphens: `my-resource-name`
- Semantic names: `bigbang`, `istio-system`, `monitoring`
- Standard labels:
```yaml
metadata:
  labels:
    app.kubernetes.io/name: example
    app.kubernetes.io/part-of: bigbang
```

### Secrets

- All secrets use SOPS encryption (`.enc.yaml` suffix)
- Never commit plaintext secrets
- Use `.gitignore` to exclude unencrypted files

## Git Workflow

### Commit Messages

```
feat: add new package
run-ci

# Regular commits
docs: update README
fix: correct typo in values
chore: update package version
```

### Branching

- Main: `main`
- Features: `feature/description`
- Hotfixes: `fix/description`

## Common Tasks

### Add New Package

1. Create `bigbang/envs/dev/values/<package>.yaml`
2. Add to `bigbang/envs/dev/kustomization.yaml`
3. Validate: `kustomize build bigbang/envs/dev/`
4. Commit with "run-ci" to deploy

### Update Existing Package

1. Modify `bigbang/envs/dev/values/<package>.yaml`
2. Sync: `flux reconcile hr <package> -n bigbang`

## Important Notes

- Template repository - meant to be copied and customized
- For GitLab: copy `gitlab-ci.yml` → `.gitlab-ci.yaml` after repo creation
- Secrets must be encrypted with SOPS before commit
- Flux must be bootstrapped before first deployment
- Requires Kubernetes cluster with sufficient permissions

## Dependencies

- `kubectl` - Kubernetes CLI
- `flux` - GitOps toolkit
- `kustomize` - Manifest customization
- `sops` - Secrets encryption
- `jq` - JSON processing
- `yq` - YAML processing (optional)
