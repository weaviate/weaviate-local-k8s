# Weaviate Local K8s

Tool for deploying and managing local Weaviate clusters in Kind (Kubernetes in Docker). Used for testing, development, bug reproduction, and CI/CD integration.

## Skills

This repository includes two Claude Code skills in `.claude/skills/`:

### operating-weaviate-local-k8s

Operator skill for deploying, upgrading, and cleaning up Weaviate clusters. Knows how to translate cluster requirements into the correct environment variables and commands. Use when you need to:

- Deploy a Weaviate cluster with specific configuration
- Reproduce a bug with a particular setup
- Set up clusters for integration or exploratory testing
- Configure authentication, modules, backup, or monitoring

Invoke: `/operating-weaviate-local-k8s`

### contributing-to-weaviate-local-k8s

Contributor and reviewer skill with expert knowledge of the codebase. Covers bash script architecture, Helm values generation, Kind cluster management, GitHub Actions, and testing patterns. Use when you need to:

- Implement a new feature in weaviate-local-k8s
- Review a pull request
- Add or improve CI test coverage
- Understand the code architecture

Invoke: `/contributing-to-weaviate-local-k8s`

## Quick Start

```bash
# Deploy a single-node cluster
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup

# Verify
curl localhost:8080/v1/meta

# Clean up
./local-k8s.sh clean
```

## Key Files

| File | Purpose |
|------|---------|
| `local-k8s.sh` | Main entry point (setup/upgrade/clean) |
| `utilities/helpers.sh` | All helper functions |
| `action.yml` | GitHub Actions composite action |
| `.github/workflows/main.yml` | CI test matrix |
| `scripts/` | OIDC helper scripts |
| `manifests/` | Kubernetes manifests and Grafana dashboards |

## Skill Maintenance

**When adding new features to weaviate-local-k8s, update the skills:**

1. **New env var or feature flag**: Update `operating-weaviate-local-k8s/SKILL.md` (decision guide and feature selection table) and `references/environment-variables.md`
2. **New deployment pattern**: Update `references/deployment-patterns.md`
3. **New module support**: Update `references/modules-config.md`
4. **New auth mechanism**: Update `references/auth-config.md`
5. **New service (like Dash0/Keycloak)**: Update `references/observability-config.md` or relevant reference
6. **Code architecture changes**: Update `contributing-to-weaviate-local-k8s/references/architecture.md`
7. **New CI test**: Update `references/testing-quality.md` (coverage map)
8. **New action.yml input**: Update `references/github-actions.md`

This ensures the skills stay accurate and agents always have current context.
