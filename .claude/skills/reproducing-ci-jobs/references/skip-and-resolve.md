# Skipping CI-only steps & resolving unknowable values

## CI-only steps to skip

These `uses:` steps exist for the GitHub runner, not for reproducing the test. Skip them,
leaving a `# skipped: <action> (CI-only)` comment so the omission is visible:

| Action | Why skip | Local equivalent |
|--------|----------|------------------|
| `actions/checkout@*` | The consumer repo is already checked out locally. | — |
| `docker/login-action@*` | Registry auth. | `docker login` once, beforehand, if pulling private images. |
| `catchpoint/workflow-telemetry-action`, `dev-hato/actions-workflow-metrics` | CI telemetry. | — |
| `ubicloud/setup-python`, `actions/setup-python` | Python provisioning. | Use your local venv / `pip3`. |
| `insightsengineering/disk-space-reclaimer` | Frees runner disk. | — |
| `weaviate/github-common-actions/.github/actions/capture-logs` (stern) | Ships pod logs as artifacts. | `kubectl logs` if you need them. |
| `actions/upload-artifact@*` | Uploads logs/results. | Files stay on disk locally. |
| `pmeier/pytest-results-action` | Renders test summary in the CI UI. | pytest's own stdout. |

Everything **not** on this list and not a `weaviate-local-k8s` step is either a `run:` step
(carry it), a local composite action (inline it), or a version-resolution action (resolve it).
If it is none of these, **stop and ask the user** — do not drop it.

## Resolving values not in the YAML

### Workflow inputs
`on.workflow_call.inputs` / `on.workflow_dispatch.inputs` (e.g. `weaviate_version`,
`lsm_access_strategy`, `async_indexing`, `number_nodes`, `replicas`, `pytest_marks`). Each →
`lk8s_input KEY "<description>" [default]`. Honor `${{ inputs.x || 'default' }}` as the default.

### Version-resolution actions
These compute a version from the registry / tags and feed later steps. There is no local
oracle, so resolve them to an explicit value the user supplies:

| Action / output | Bind to | Notes |
|---|---|---|
| `get-previous-version` → `previous_version` | `WEAVIATE_INITIAL_VERSION` | The job sets `WEAVIATE_INITIAL_VERSION` via `>> $GITHUB_ENV`; later steps read it. |
| `get-latest-weaviate-version` → `latest_weaviate_version` | `WEAVIATE_VERSION` | Used when the input is the literal `latest_release`. |
| `real-version-in-tag` (job) → `real_version` | an `lk8s_input` | Strips an image tag to a semver. |

The user can run `gh release list -R weaviate/weaviate` to find appropriate values.

### `needs.<job>.outputs.*`
Cross-job outputs (often version gates like `newer-or-equal-than-1_32.outputs.check`). Most
gate the job's `if:` (ignore those — the user chose this job) or appear in `values-override`
ternaries. Resolve any that affect a reproduced step via `lk8s_input` (usually `'true'`).

### Secrets
Resolve a `secrets.X` **only if a non-skipped step uses it**. In practice the secrets here
(`DOCKER_USERNAME/PASSWORD`, AWS, GCP, telemetry tokens) feed skipped steps and vanish. If one
is genuinely needed, `lk8s_input` it and warn the user it's sensitive.

### `$GITHUB_ENV` / `$GITHUB_OUTPUT`
A `run:` step writing to these files sets values for later steps. Reproduce them as plain
shell variables — do not literally append to the files. Two write forms appear:

- **Single line**: `echo "VAR=value" >> $GITHUB_ENV` → `VAR=value`.
- **Multi-line / heredoc** (used for `VALUES_OVERRIDE`), either written line-by-line or as a
  block:
  ```bash
  { echo 'VALUES_OVERRIDE<<EOF'; echo '<content>'; echo 'EOF'; } >> $GITHUB_ENV
  ```
  → a heredoc-assigned shell var (`VALUES_OVERRIDE=$(cat <<'EOF' … EOF)`), then pass it through
  `lk8s_values_override` for `weaviate-local-k8s` steps that reference it.

### Non-bash shell steps (`shell: python`, …)
A step's `shell:` chooses the interpreter. `shell: python` runs Python — e.g.
`version-change` computes `RAFT_UPGRADE` (does the jump cross the 1.25 RAFT boundary?) and
writes it to `$GITHUB_ENV`; a later `weaviate-local-k8s` step uses it as `delete-sts`.
Reproduce the logic with the right interpreter and capture the result into a shell var:
```bash
RAFT_UPGRADE=$(python3 - "$INITIAL_VERSION" "$REAL_VERSION" <<'PY'
import sys; from packaging import version
raft = version.parse("1.25.0")
print(str(version.parse(sys.argv[2]) >= raft and version.parse(sys.argv[1]) < raft).lower())
PY
)
```

### `docker-config`
Steps often pass `docker-config: /home/runner/.docker/config.json` (runner path for private
registry pulls in Kind). **Omit it locally** — the path doesn't exist and the action default
is empty. `docker login` beforehand if you genuinely need authenticated pulls.

## Local composite actions — recurse and inline, don't skip

A `uses: ./.github/actions/<name>` is a composite action **inside the consumer repo** whose
effect a test depends on. Read its `action.yml`, **bind its `inputs.*` from the calling step's
`with:`**, and process its `steps:` with the normal classification rules. Composites can nest
(a composite calling `generate-config`); recurse at each `uses: ./…`.

Two scales of this:
- **Leaf** — e.g. e2e `./.github/actions/generate-config` just writes `config/default_config.yaml`
  (the client config the pytest reads). Inline its heredoc with the bound `version`/`api_key`;
  skipping it would break the tests.
- **The whole job** — e.g. e2e `./.github/actions/version-change` and `run-local-k8s-test`
  ARE the job: they set up python, write a batch of `$GITHUB_ENV` vars (incl. a multi-line
  `VALUES_OVERRIDE`), deploy via `weaviate-local-k8s` (once or twice), inline
  `generate-config`, and run the pre/post pytest. Recurse fully — the `weaviate-local-k8s`
  steps you translate live *inside* the composite, not in the workflow job.

## Matrices

`strategy.matrix` (sometimes dynamic via `fromJson(needs.<job>.outputs.<matrix>)`, e.g.
recovery-tests generating one entry per test file) fans a job into many runs. For local
reproduction, pick **one** combination — ask the user which `matrix.<key>` value to use and
bind it as a variable.

## Case studies

### chaos `rbac-upgrade-journey` (3 lifecycle ops, RBAC, heredoc auth-config)
- Skip: checkout, docker/login, telemetry, upload-artifact.
- Resolve: `WEAVIATE_VERSION` (input), `WEAVIATE_INITIAL_VERSION` (get-previous-version),
  `lsm_access_strategy` + `async_indexing` (inputs, used inside `VALUES_OVERRIDE`).
- Carry: `pip3 install`, the three `cat > /tmp/rbac_config.yaml` heredocs, all
  `python3 …` role/data checks, `./scripts/restart_and_wait.sh`.
- Translate: the 3 `@v2` steps → `lk8s_weaviate setup/upgrade/upgrade` with rbac + auth-config
  + values-override.
- Full generated artifact: [`examples/reproduce/rbac-upgrade-journey.sh`](../../../../examples/reproduce/rbac-upgrade-journey.sh).

### e2e `upgrade-tests` `upgrade_cluster` (the whole job is a composite action)
The job calls `./.github/actions/version-change` — recurse into it:
- Skip (in the job *and* the composite): checkout, telemetry, disk-space-reclaimer,
  setup-python, both docker/login, capture-logs (stern), upload-artifact, pytest-results.
- Resolve: `WEAVIATE_VERSION`/`REAL_WEAVIATE_VERSION` (real-version-in-tag),
  `WEAVIATE_INITIAL_VERSION` (get-previous-version), `number_nodes` (→ WORKERS/REPLICAS). Omit
  `docker-config`.
- Composite `Set environment variables` step → shell vars + the multi-line `VALUES_OVERRIDE`
  via `lk8s_values_override`.
- Translate the composite's **two** `weaviate-local-k8s` steps: Deploy Initial
  (`setup`, version=INITIAL) and Perform upgrade (`upgrade`, version=TARGET, `delete-sts` from
  the next item).
- Reproduce the `shell: python` `RAFT_UPGRADE` step → `delete-sts` of the upgrade.
- Inline `generate-config` (pre at INITIAL, post at TARGET); carry the `pre_upgrade` /
  `post_upgrade` pytest steps (preserve their exit-code-5 = "no tests collected" handling).
- Full generated artifact: [`examples/reproduce/upgrade-cluster.sh`](../../../../examples/reproduce/upgrade-cluster.sh).

### e2e `config-change-tests` `rbac_enable` (setup → upgrade enabling RBAC)
- Skip: checkout, telemetry, both docker/login, disk-space-reclaimer, setup-python.
- Inline: `./.github/actions/generate-config` (writes client config the pytest reads).
- Resolve: `WEAVIATE_VERSION` (`inputs.weaviate_version || 'latest_release'` →
  get-latest-weaviate-version), `number_nodes` (→ `WORKERS`/`REPLICAS`), `log_level`/`threads`.
- Carry the multi-line `VALUES_OVERRIDE` (via `lk8s_values_override`) and the pytest run.
- Translate: setup step (`rbac=false`) then upgrade step (`operation=upgrade rbac=true`).
