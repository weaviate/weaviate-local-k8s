---
name: reproducing-ci-jobs
description: Reproduce locally a GitHub Actions CI job that uses the weaviate/weaviate-local-k8s action. Reads an existing, unchanged workflow + job, sets aside CI-only steps, translates the weaviate-local-k8s steps into local-k8s.sh calls, carries the interleaved test/run steps, and emits a deterministic, re-runnable bash script (optionally running it). Use when a developer wants to debug or rerun a chaos-engineering / e2e-tests / weaviate-cli k8s job on their laptop without hand-translating each step.
---

# Reproducing weaviate-local-k8s CI jobs locally

CI jobs in repos like weaviate-chaos-engineering, weaviate-e2e-tests, and weaviate-cli use
the `weaviate/weaviate-local-k8s@vN` composite action across **many interleaved steps**
(setup → tests → upgrade → tests → downgrade), with `${{ }}` expressions, inline
`auth-config`/`values-override`, and version-resolution actions. Unlike docker-based jobs
(one committed script you can run anywhere), there is **no single artifact** a developer can
run to reproduce a k8s job — so this skill produces one *from the unchanged workflow*.

**The output is a plain bash script.** It is deterministic to run and re-run without Claude;
only (re)generation uses this skill. The mechanical, error-prone translation lives in a
deterministic helper lib (`utilities/reproduce-lib.sh`), so you never hand-derive the
action-input → env-var mapping or the action's input defaults.

Worked reference: [`examples/reproduce/rbac-upgrade-journey.sh`](../../../examples/reproduce/rbac-upgrade-journey.sh)
(+ `.inputs`) reproduces the real chaos `rbac-upgrade-journey` job. Study it before generating a new one.

## Inputs to collect from the user

| Need | Notes |
|------|-------|
| Workflow file | Path to the `.github/workflows/*.yaml` in the consumer repo (leave it unchanged). |
| Job id | The job to reproduce (e.g. `rbac-upgrade-journey`, `rbac_enable`). |
| Consumer repo path | Where the `run:` steps' `cd`/`working-directory` resolve and where local composite actions live. |
| Inputs file (optional) | `KEY=value` file for values not in the YAML; missing keys are prompted at run time. |
| Output path (optional) | Default `<consumer-repo>/reproduce/<job>.sh`. |
| Run now? | Emit only (default) or emit + run. |

## Procedure

### 1. Parse the workflow (use `yq`)
- Read `on.workflow_call.inputs` / `on.workflow_dispatch.inputs` — each becomes an `lk8s_input` key.
- Build the env map: workflow-level `env:` merged with the job's `env:`. Record which values
  contain `${{ }}` (they need resolution).
- Read the named job's `steps:` **in order**. Job-level `if:`/`needs:` gates are ignored
  (the user explicitly chose this job).

### 2. Classify every step (never skip the table)
See [references/skip-and-resolve.md](references/skip-and-resolve.md) for the full skip-list,
version-resolution, secrets, composite-action, and matrix guidance.

| Step kind | Action |
|-----------|--------|
| `uses: weaviate/weaviate-local-k8s@*` | **Translate** → `lk8s_weaviate "$LK8S" <operation> key=value …` using the step's `with:` (keys are the kebab-case inputs verbatim). Inline `values-override` → `lk8s_values_override`. `auth-config` stays a file path. `values-inline` passes through verbatim. |
| `run:` (any `shell:`) | **Carry verbatim**, in order. Wrap in `( cd <working-directory or repo subdir> && … )`. Expand `${{ }}`. Turn `$GITHUB_ENV`/`$GITHUB_OUTPUT` writes into plain shell variables (see "Non-bash shells & GITHUB_ENV" below). A non-bash `shell:` (e.g. `shell: python`) must run with that interpreter — reproduce its logic and capture what it writes. A dependency-install step (`pip install -r …`) → `lk8s_pip_install <reqs>` (isolated venv — see "Python deps → isolated venv" below), **not** a raw `pip install`. |
| local composite `uses: ./.github/actions/*` | **Recurse and inline** (see "Composite actions that ARE the job"). Read that action's `action.yml`, map the calling step's `with:` → the composite's `inputs.*`, then classify the composite's own steps with this same table — they often contain the `weaviate-local-k8s` steps, nested composites, `$GITHUB_ENV` writes, and the pytest steps. |
| version-resolution `uses:` (`get-latest-weaviate-version`, `get-previous-version`, `real-version-in-tag`) | **Resolve to a value** via `lk8s_input` and bind to the variable later steps read (e.g. `WEAVIATE_INITIAL_VERSION`). |
| CI-only `uses:` (checkout, docker/login, telemetry, setup-python, disk-space-reclaimer, capture-logs/stern, upload-artifact, pytest-results) | **Skip** with a `# skipped: <action> (CI-only)` comment. |
| anything else | **STOP and ask the user** — never silently drop a step. |

> **Composite actions that ARE the job.** Many e2e jobs do their real work in a single
> consumer-repo composite action (e.g. `./.github/actions/version-change`,
> `run-local-k8s-test`) — the job step is just `uses: ./.github/actions/X with: {…}`. Recurse:
> read `X/action.yml`, bind its `inputs.*` from the caller's `with:`, and process **its**
> `steps:` with the table above. That composite typically: sets a batch of `$GITHUB_ENV`
> vars (including a multi-line `VALUES_OVERRIDE`), deploys via `weaviate-local-k8s` (often
> twice — initial + upgrade), inlines a further nested composite (`generate-config`), and runs
> the pre/post pytest. Composites can nest; recurse at each `uses: ./…`. The worked example
> [`examples/reproduce/upgrade-cluster.sh`](../../../examples/reproduce/upgrade-cluster.sh)
> reproduces `version-change` end to end.

> **Non-bash shells & `$GITHUB_ENV`.** A `run:` step's `shell:` selects the interpreter —
> `shell: python` runs Python (e.g. `version-change` computes `RAFT_UPGRADE` to drive the
> 2nd deploy's `delete-sts`); reproduce that logic and capture its output into a shell var
> (`RAFT_UPGRADE=$(python3 - … <<'PY' … PY)`). `$GITHUB_ENV` has two write forms, both → plain
> shell vars: single-line `echo "VAR=value" >> $GITHUB_ENV`, and multi-line
> `echo "VAR<<EOF" >> $GITHUB_ENV; …; echo "EOF" >> $GITHUB_ENV` (used for `VALUES_OVERRIDE`) →
> a heredoc-assigned var, then pass it through `lk8s_values_override`.

> **Python deps → isolated venv.** A CI "Install python dependencies" step
> (`pip install -r requirements.txt`, often `--ignore-installed`) runs on a throwaway runner.
> Locally, installing into the active global/pyenv env can corrupt it — e.g.
> `--ignore-installed` layers a pinned version over a different pre-existing one, leaving a
> mixed install (`ImportError: cannot import name …`) — and a stray `.python-version` may
> select the wrong interpreter. **Translate every such step to
> `lk8s_pip_install <requirements-file | pip-spec …>`**, not a raw `pip install`: it
> creates/reuses a dedicated venv, activates it for the rest of the script (so every later
> `python3`/`pytest` uses it), and installs cleanly. Pin the base interpreter with
> `LK8S_PYTHON=python3.12` if needed.

### 3. Resolve `${{ }}` expressions
- `inputs.X` → `lk8s_input X "<description>" [default]`. Honor `${{ inputs.x || 'default' }}`.
- `env.X` → the resolved env value (resolve recursively; env values may themselves be expressions).
- `needs.J.outputs.X` → `lk8s_input` (a cross-job value, not derivable locally).
- `steps.ID.outputs.X` → from the producing step: version-resolution → `lk8s_input`; a prior
  `$GITHUB_OUTPUT` write → the shell variable you created for it.
- `secrets.X` → only if a **non-skipped** step needs it → `lk8s_input` (warn the user). Most
  secrets feed skipped steps (docker login) and disappear.
- Functions/operators: `||` (default), `&&`/ternary, `contains()`, `fromJson()`, `format()` —
  evaluate with judgment. For a `strategy.matrix`, pick **one** combination (ask which).

### 4. Emit the script
Structure (see the worked reference for a full example):

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "<path-to>/reproduce-lib.sh"   # vendor a copy next to the script, or point at the repo

VER=$(lk8s_input WEAVIATE_VERSION "target version")
# … resolve every unknowable value up front …

LK8S=$(lk8s_bootstrap "${LK8S_REF:-v2}")   # pin to the @ref the workflow used
lk8s_cleanup_trap "$LK8S"                  # local-k8s.sh clean on exit

# then: steps in workflow order — lk8s_values_override / lk8s_weaviate / carried run: blocks
```

Use the helper API (full contract in `utilities/reproduce-lib.sh`):
- `lk8s_bootstrap [ref]` → resolves a local-k8s.sh checkout ($WEAVIATE_LOCAL_K8S_DIR or a pinned clone); echoes its dir.
- `lk8s_input KEY [prompt] [default]` → env var → `$LK8S_INPUTS` file → interactive prompt. Expands a leading `~`.
- `lk8s_pip_install <requirements-file | pip-spec …>` → creates/activates an isolated venv and installs deps (replaces a CI `pip install` step; avoids polluting the global/pyenv env). Knobs: `LK8S_VENV`, `LK8S_PYTHON`, `LK8S_VENV_RECREATE`.
- `lk8s_values_override DIR` (heredoc on stdin) → writes `DIR/values-override.yaml` (mirrors action.yml).
- `lk8s_weaviate DIR OPERATION key=value…` → deterministic translation + setup retry. Applies the **action's** input defaults for unset keys (these differ from local-k8s.sh's own defaults).
- `lk8s_cleanup_trap DIR` → on EXIT: **keeps the cluster if a step failed** (so you can debug the same failure the CI job hit), tears it down on success. `LK8S_KEEP=true` always keeps; `LK8S_KEEP=false` always cleans.

### 5. Guardrails — stick to the job's steps
- Preserve step **order** exactly; reproduce every load-bearing step.
- Only omit steps on the documented CI-only skip-list. Anything else → ask.
- Do not invent, reorder, or alter test commands.
- After generating, print a **mapping summary**: each workflow step → translated / carried /
  skipped / resolved, plus the list of `lk8s_input` keys the user must supply. Let them review.

### 6. Run (optional)
```bash
LK8S_INPUTS=<inputs-file> <output>/<job>.sh    # non-interactive
```
Knobs:
- **Debugging a failure** — by default a failed step **leaves the cluster up** (the script
  prints how to reach it: `kubectl get pods -n weaviate`, `curl localhost:8080/v1/meta`, and
  the `clean` command). This reproduces the CI failure and lets you poke at the live cluster.
- `LK8S_KEEP=true` always keeps the cluster (even on success); `LK8S_KEEP=false` always tears
  it down (CI-like).
- `LK8S_MAX_RETRIES=1` fails fast (no setup retry); `WEAVIATE_LOCAL_K8S_DIR=<checkout>` uses a
  local working copy instead of cloning a pinned ref.

## References
- [references/action-input-mapping.md](references/action-input-mapping.md) — `with:` key → env var, special cases, and the default-divergence gotcha.
- [references/skip-and-resolve.md](references/skip-and-resolve.md) — skip-list, version/secret/composite/matrix resolution, and real case studies.
- Cluster config semantics (env vars, Helm precedence, auth): see the `operating-weaviate-local-k8s` skill.
- Action/CI internals: see `contributing-to-weaviate-local-k8s/references/github-actions.md`.
