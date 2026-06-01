# Action input → env var mapping

The `weaviate/weaviate-local-k8s` composite action (`action.yml`) maps each kebab-case
`with:` input to a `SCREAMING_SNAKE` environment variable, then runs `local-k8s.sh
<operation>`. `lk8s_weaviate` in `utilities/reproduce-lib.sh` does this translation for you —
this reference documents the contract and the one real gotcha.

## The mapping is mechanical

`env var = uppercase(input) with '-' → '_'`. Verified against every input in `action.yml`:

| `with:` input | env var | | `with:` input | env var |
|---|---|---|---|---|
| `operation` | *(subcommand, not env)* | | `dash0` | `DASH0` |
| `weaviate-port` | `WEAVIATE_PORT` | | `cluster-name` | `CLUSTER_NAME` |
| `weaviate-grpc-port` | `WEAVIATE_GRPC_PORT` | | `dash0-token` | `DASH0_TOKEN` |
| `workers` | `WORKERS` | | `dash0-endpoint` | `DASH0_ENDPOINT` |
| `replicas` | `REPLICAS` | | `dash0-api-endpoint` | `DASH0_API_ENDPOINT` |
| `weaviate-version` | `WEAVIATE_VERSION` | | `expose-pods` | `EXPOSE_PODS` |
| `helm-branch` | `HELM_BRANCH` | | `rbac` | `RBAC` |
| `modules` | `MODULES` | | `oidc` | `OIDC` |
| `values-override` | *(file, see below)* | | `dynamic-users` | `DYNAMIC_USERS` |
| `values-inline` | `VALUES_INLINE` | | `auth-config` | `AUTH_CONFIG` |
| `enable-backup` | `ENABLE_BACKUP` | | `debug` | `DEBUG` |
| `collection-export` | `COLLECTION_EXPORT` | | `enable-runtime-overrides` | `ENABLE_RUNTIME_OVERRIDES` |
| `s3-offload` | `S3_OFFLOAD` | | `docker-config` | `DOCKER_CONFIG` |
| `usage-s3` | `USAGE_S3` | | `mcp` | `MCP` |
| `delete-sts` | `DELETE_STS` | | `mcp-write-access` | `MCP_WRITE_ACCESS` |
| `observability` | `OBSERVABILITY` | | | |

## Special cases

- **`operation`** → the `local-k8s.sh` subcommand (`setup` / `upgrade` / `clean`), passed as
  the 2nd arg to `lk8s_weaviate`, not as an env var. (`upgrade` to an older version = a
  downgrade.)
- **`values-override`** → its YAML string is written to `<local-k8s-dir>/values-override.yaml`
  (action.yml's "Create values-override.yaml" step). Use `lk8s_values_override`, **not** a
  `values-override=` arg to `lk8s_weaviate`.
- **`auth-config`** → a **file path** passed straight to Helm via `-f`. The file must exist
  before the call — usually created by a preceding heredoc `run:` step. Keep it a path.
- **`values-inline`** → raw Helm `--set` flags, passed through verbatim (preserve spaces;
  quote the whole value).

## The gotcha: action defaults ≠ script defaults

The action declares its own `inputs.<name>.default` and passes **every** input on **every**
invocation. Some of those defaults differ from `local-k8s.sh`'s own `${VAR:-default}`:

| input | action default | local-k8s.sh default | consequence if you forget |
|---|---|---|---|
| `replicas` | `3` | `1` | single node instead of 3 |
| `workers` | `3` | (unset) | wrong kind node count |
| `observability` | `false` | `true` (`OBSERVABILITY`) | monitoring stack starts unexpectedly, slower |
| `weaviate-version` | `latest` | (unset) | — |
| `expose-pods` | `true` | `true` | (same) |

So reproducing a step means applying the **action's** defaults for unset keys, not the
script's. `lk8s_weaviate` does this automatically (its `_lk8s_action_defaults` map mirrors
`action.yml`). **If you add or change an action input, update both `action.yml` and that map.**
