#!/usr/bin/env bash
# reproduce-lib.sh — deterministic helpers for locally reproducing CI jobs that use the
# weaviate/weaviate-local-k8s GitHub Action.
#
# These functions are the *mechanical, error-prone* parts of translating an action step
# into a local `local-k8s.sh` invocation: the action-input -> env-var mapping, the action's
# own input defaults, writing values-override.yaml / auth-config the way the action does,
# bootstrapping a pinned local-k8s.sh checkout, and the setup retry loop. Keeping them here
# (rather than re-deriving them in every generated script) is what makes the reproduction
# deterministic.
#
# Generated repro scripts `source` this file and call:
#   LK8S=$(lk8s_bootstrap v2)            # resolve a local-k8s.sh checkout
#   lk8s_cleanup_trap "$LK8S"            # run `local-k8s.sh clean` on EXIT
#   VER=$(lk8s_input WEAVIATE_VERSION "target Weaviate version")
#   lk8s_values_override "$LK8S" <<'EOF' ... EOF   # inline helm value overrides
#   lk8s_weaviate "$LK8S" setup weaviate-version="$VER" replicas=3 rbac=true ...
#
# This file is sourced, not executed: it sets no global shell options. The sourcing script
# is expected to run under `set -euo pipefail`.

# Requires bash 4+ (associative arrays). macOS ships bash 3.2; install a modern one with
# `brew install bash` and run scripts with `/usr/bin/env bash`.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf 'reproduce-lib.sh requires bash 4+ (found: %s). On macOS: brew install bash\n' "${BASH_VERSION:-non-bash shell}" >&2
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------------------
# Logging — all informational output goes to stderr so command substitution
# (e.g. LK8S=$(lk8s_bootstrap)) captures only the intended value on stdout.
# ---------------------------------------------------------------------------------------
lk8s_log()  { printf '\033[0;34m[reproduce]\033[0m %s\n' "$*" >&2; }
lk8s_warn() { printf '\033[0;33m[reproduce] WARNING:\033[0m %s\n' "$*" >&2; }
lk8s_err()  { printf '\033[0;31m[reproduce] ERROR:\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------------------
# Action input defaults — MUST mirror action.yml's `inputs.<name>.default`.
# The action passes every input (filling gaps with these defaults) on every invocation, so
# faithful reproduction requires applying them too. Note several differ from local-k8s.sh's
# own ${VAR:-default} values (e.g. observability=false here vs OBSERVABILITY=true in the
# script, replicas=3 here vs 1 in the script); the action's value is the one that ran in CI.
# ---------------------------------------------------------------------------------------
# Keys are the kebab-case action input names. `operation` and `values-override` are handled
# specially (subcommand / file) and are intentionally absent from this map.
_lk8s_action_defaults() {
  cat <<'EOF'
weaviate-port=8080
weaviate-grpc-port=50051
workers=3
replicas=3
weaviate-version=latest
helm-branch=
modules=
values-inline=
enable-backup=false
collection-export=false
s3-offload=false
usage-s3=false
delete-sts=false
observability=false
dash0=false
cluster-name=weaviate-local-cluster
dash0-token=
dash0-endpoint=
dash0-api-endpoint=
expose-pods=true
rbac=false
oidc=false
dynamic-users=false
auth-config=
debug=false
enable-runtime-overrides=false
docker-config=
mcp=false
mcp-write-access=false
EOF
}

# Convert a kebab-case action input name to its local-k8s.sh env-var name.
# Mechanical rule (verified against every input in action.yml): uppercase + '-' -> '_'.
#   weaviate-version -> WEAVIATE_VERSION   s3-offload -> S3_OFFLOAD
#   mcp-write-access -> MCP_WRITE_ACCESS   dash0-api-endpoint -> DASH0_API_ENDPOINT
lk8s_key_to_env() {
  # tr handles both lowercase->uppercase and '-'->'_' in one portable pass.
  printf '%s' "$1" | tr 'a-z-' 'A-Z_'
}

# ---------------------------------------------------------------------------------------
# lk8s_bootstrap [ref]
# Resolve a usable local-k8s.sh checkout and echo its directory on stdout.
#   - If $WEAVIATE_LOCAL_K8S_DIR points at a checkout, use it as-is (no network, no pin).
#   - Otherwise clone weaviate-local-k8s into $LK8S_CACHE (default ~/.cache/weaviate-local-k8s)
#     and check out `ref` (default: arg, else $LK8S_REF, else v2) so the local code matches
#     the @ref the CI workflow used.
# ---------------------------------------------------------------------------------------
lk8s_bootstrap() {
  local ref="${1:-${LK8S_REF:-v2}}"

  if [[ -n "${WEAVIATE_LOCAL_K8S_DIR:-}" ]]; then
    if [[ -f "$WEAVIATE_LOCAL_K8S_DIR/local-k8s.sh" ]]; then
      lk8s_log "Using local checkout from \$WEAVIATE_LOCAL_K8S_DIR: $WEAVIATE_LOCAL_K8S_DIR"
      printf '%s' "$WEAVIATE_LOCAL_K8S_DIR"
      return 0
    fi
    lk8s_warn "\$WEAVIATE_LOCAL_K8S_DIR is set but $WEAVIATE_LOCAL_K8S_DIR/local-k8s.sh not found; falling back to a clone."
  fi

  local cache="${LK8S_CACHE:-$HOME/.cache/weaviate-local-k8s}"
  local url="${LK8S_REPO_URL:-https://github.com/weaviate/weaviate-local-k8s}"
  if [[ ! -d "$cache/.git" ]]; then
    lk8s_log "Cloning $url -> $cache"
    git clone --quiet "$url" "$cache" >&2
  fi
  lk8s_log "Pinning local-k8s.sh to ref '$ref'"
  git -C "$cache" fetch --quiet --tags origin >&2 || lk8s_warn "git fetch failed; using cached refs"
  git -C "$cache" checkout --quiet "$ref" >&2
  printf '%s' "$cache"
}

# ---------------------------------------------------------------------------------------
# lk8s_input KEY [prompt-text] [default]
# Resolve a value not derivable from the workflow YAML (workflow inputs, version-resolution
# outputs, secrets a non-skipped step needs). Resolution order:
#   1. An already-set environment variable named KEY (e.g. exported, or sourced inputs file).
#   2. A `KEY=value` line in the inputs file named by $LK8S_INPUTS.
#   3. Interactive prompt on the terminal (uses `default` if the user just presses Enter).
# Echoes the resolved value on stdout. Errors if unresolved and no terminal/default.
# ---------------------------------------------------------------------------------------
lk8s_input() {
  local key="$1" prompt="${2:-$1}" default="${3:-}"
  local val="" resolved=0

  # 1. pre-set environment variable
  if [[ -n "${!key:-}" ]]; then
    val="${!key}"; resolved=1
  fi

  # 2. inputs file (KEY=value)
  if [[ "$resolved" -eq 0 && -n "${LK8S_INPUTS:-}" && -f "$LK8S_INPUTS" ]]; then
    val="$(sed -n "s/^${key}=//p" "$LK8S_INPUTS" | head -n1)"
    [[ -n "$val" ]] && resolved=1
  fi

  # 3. interactive prompt
  if [[ "$resolved" -eq 0 && -r /dev/tty ]]; then
    local suffix=""
    [[ -n "$default" ]] && suffix=" [$default]"
    printf '\033[0;36m[reproduce] %s (%s)%s: \033[0m' "$prompt" "$key" "$suffix" >/dev/tty
    read -r val </dev/tty
    [[ -z "$val" && -n "$default" ]] && val="$default"
    [[ -n "$val" ]] && resolved=1
  fi

  # 4. default fallback
  if [[ "$resolved" -eq 0 && -n "$default" ]]; then
    val="$default"; resolved=1
  fi

  if [[ "$resolved" -eq 0 ]]; then
    lk8s_err "No value for '$key'. Set it in \$LK8S_INPUTS, export it, or run interactively."
    return 1
  fi

  # Expand a leading ~ or ~/ to $HOME. Values from an inputs file, env var, or prompt are
  # plain strings — the shell's tilde expansion only fires on unquoted ~ tokens at parse
  # time, so a path like `~/repos/foo` would otherwise reach `cd` with a literal tilde and
  # fail. (We deliberately don't handle ~user/ — not needed for these inputs.)
  case "$val" in
    "~")   val="$HOME" ;;
    "~/"*) val="$HOME/${val#\~/}" ;;
  esac

  printf '%s' "$val"
}

# ---------------------------------------------------------------------------------------
# lk8s_values_override DIR   (content read from stdin)
# Replicates action.yml's "Create values-override.yaml" step: writes the given helm value
# overrides to DIR/values-override.yaml, which local-k8s.sh picks up via `-f`.
# Pass /dev/null content (empty stdin) to clear a previously written file.
# ---------------------------------------------------------------------------------------
lk8s_values_override() {
  local dir="$1"
  local content
  content="$(cat)"
  if [[ -z "$content" ]]; then
    rm -f "$dir/values-override.yaml"
    lk8s_log "Cleared $dir/values-override.yaml"
    return 0
  fi
  printf '%s\n' "$content" > "$dir/values-override.yaml"
  lk8s_log "Wrote $dir/values-override.yaml ($(printf '%s' "$content" | grep -c . ) non-empty lines)"
}

# ---------------------------------------------------------------------------------------
# lk8s_pip_install [requirements-file | pip-spec ...]
# Reproduce a CI "Install python dependencies" step WITHOUT polluting the developer's machine.
#
# On a throwaway CI runner, `pip install -r requirements.txt` (often `--ignore-installed`) is
# harmless. Locally it installs into whatever interpreter is active — frequently a shared
# global/pyenv env that already has a different weaviate-client. `--ignore-installed` then
# layers the pinned version on top WITHOUT uninstalling the old one, leaving a corrupted
# mixed install (e.g. `ImportError: cannot import name 'ConnectionType'`). A stray
# `.python-version` can also silently select the wrong interpreter.
#
# This installs into a dedicated venv and ACTIVATES it for the rest of the (sourcing) script,
# so every later `python3`/`pip` resolves there — the clean-environment semantics CI gets.
# Args that are existing files become `-r <file>`; anything else is passed as a literal pip
# spec. `--ignore-installed` is intentionally NOT used: in a clean venv, pip's normal resolver
# replaces versions cleanly.
#
#   lk8s_pip_install "$CHAOS/apps/foo/requirements.txt"
#   lk8s_pip_install 'weaviate-client==4.12.0' loguru
#
# Knobs:
#   LK8S_VENV           venv directory (default: $LK8S_CACHE/repro-venv, reused across runs).
#   LK8S_PYTHON         base interpreter used to CREATE the venv (default: python3 on PATH).
#                       Set e.g. LK8S_PYTHON=python3.12 to dodge a stray .python-version/pyenv.
#   LK8S_VENV_RECREATE  =true to delete and rebuild the venv from scratch first.
# ---------------------------------------------------------------------------------------
lk8s_pip_install() {
  local venv="${LK8S_VENV:-${LK8S_CACHE:-$HOME/.cache/weaviate-local-k8s}/repro-venv}"
  local base_python="${LK8S_PYTHON:-python3}"

  if [[ "${LK8S_VENV_RECREATE:-false}" == "true" && -d "$venv" ]]; then
    lk8s_log "LK8S_VENV_RECREATE=true — removing existing venv $venv"
    rm -rf "$venv"
  fi

  if [[ ! -x "$venv/bin/python" ]]; then
    if ! command -v "$base_python" >/dev/null 2>&1; then
      lk8s_err "Base python '$base_python' not found. Install it or set \$LK8S_PYTHON."
      return 1
    fi
    lk8s_log "Creating isolated repro venv at $venv (base: $("$base_python" --version 2>&1))"
    "$base_python" -m venv "$venv"
  else
    lk8s_log "Reusing isolated repro venv at $venv"
  fi

  # Activate for the remainder of the script: put venv/bin first so plain `python3`/`pip`
  # resolve here (bypassing pyenv shims and the global env). Subshells inherit the exported
  # PATH, so `( cd … && python3 … )` steps below use the venv too.
  export VIRTUAL_ENV="$venv"
  export PATH="$venv/bin:$PATH"
  unset PYTHONHOME 2>/dev/null || true
  hash -r 2>/dev/null || true

  local -a install_args=()
  local a
  for a in "$@"; do
    if [[ -f "$a" ]]; then
      install_args+=(-r "$a")
    else
      install_args+=("$a")
    fi
  done

  if [[ ${#install_args[@]} -eq 0 ]]; then
    lk8s_warn "lk8s_pip_install called with no requirements; venv activated, nothing installed."
    return 0
  fi

  lk8s_log "pip install ${install_args[*]}  (into $venv)"
  "$venv/bin/python" -m pip install --quiet --disable-pip-version-check "${install_args[@]}"
}

# ---------------------------------------------------------------------------------------
# lk8s_weaviate DIR OPERATION [key=value ...]
# The deterministic translation of a `uses: weaviate/weaviate-local-k8s` step into a local
# `local-k8s.sh OPERATION` call. `key` is the kebab-case action input; provided keys override
# the action defaults, all keys are mapped to env vars and passed for that single invocation
# only (hermetic per call, exactly as the action passes every input each time).
#
#   lk8s_weaviate "$LK8S" setup weaviate-version=1.31.0 replicas=3 rbac=true auth-config=/tmp/a.yaml
#
# `values-override` is NOT accepted here — use lk8s_values_override (it is a file, not env).
# Retries setup like the action does (MAX_RETRIES, clean-before-retry); override with
# $LK8S_MAX_RETRIES (set to 1 to fail fast while debugging).
# ---------------------------------------------------------------------------------------
lk8s_weaviate() {
  local dir="$1" operation="$2"; shift 2

  # Start from the action's input defaults, then apply provided overrides.
  declare -A vals=()
  local line key val
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    vals["${line%%=*}"]="${line#*=}"
  done < <(_lk8s_action_defaults)

  for arg in "$@"; do
    key="${arg%%=*}"
    val="${arg#*=}"
    if [[ "$key" == "values-override" ]]; then
      lk8s_warn "values-override passed to lk8s_weaviate; use lk8s_values_override instead. Ignoring."
      continue
    fi
    if [[ -z "${vals[$key]+set}" ]]; then
      lk8s_warn "Unknown action input '$key' — mapping it generically to $(lk8s_key_to_env "$key")."
    fi
    vals["$key"]="$val"
  done

  # Build the per-invocation environment.
  local -a env_assignments=()
  for key in "${!vals[@]}"; do
    env_assignments+=("$(lk8s_key_to_env "$key")=${vals[$key]}")
  done

  local -a cmd=("$dir/local-k8s.sh" "$operation")
  [[ "${LK8S_LOCAL_IMAGES:-false}" == "true" ]] && cmd+=("--local-images")

  lk8s_log "weaviate: $operation  (version=${vals[weaviate-version]} replicas=${vals[replicas]} workers=${vals[workers]} rbac=${vals[rbac]} oidc=${vals[oidc]} modules='${vals[modules]}' auth-config='${vals[auth-config]}' delete-sts=${vals[delete-sts]})"

  local max_retries="${LK8S_MAX_RETRIES:-2}" retry_delay="${LK8S_RETRY_DELAY:-30}" attempt
  for (( attempt=1; attempt<=max_retries; attempt++ )); do
    lk8s_log "Attempt $attempt of $max_retries"
    if env "${env_assignments[@]}" "${cmd[@]}"; then
      return 0
    fi
    if (( attempt < max_retries )); then
      lk8s_warn "Attempt $attempt failed; retrying in ${retry_delay}s"
      sleep "$retry_delay"
      if [[ "$operation" == "setup" ]]; then
        lk8s_log "Cleaning up before retry"
        env "${env_assignments[@]}" "$dir/local-k8s.sh" clean || true
      fi
    else
      lk8s_err "All $max_retries attempts of '$operation' failed"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------------------
# Exit handler — decides whether to tear down the cluster, based on $LK8S_KEEP and the
# script's exit code. Tri-state, so a failing run leaves the cluster up for debugging:
#   LK8S_KEEP=true   -> always keep (even on success)
#   LK8S_KEEP=false  -> always clean (even on failure; CI-like)
#   LK8S_KEEP unset  -> KEEP on failure (non-zero exit), CLEAN on success  [default]
# ---------------------------------------------------------------------------------------
_lk8s_on_exit() {
  local dir="$1" rc="$2" keep
  case "${LK8S_KEEP:-}" in
    true)  keep=yes ;;
    false) keep=no ;;
    *)     [[ "$rc" -ne 0 ]] && keep=yes || keep=no ;;
  esac

  if [[ "$keep" == "yes" ]]; then
    if [[ "$rc" -ne 0 ]]; then
      lk8s_warn "A step failed (exit $rc) — leaving the cluster UP so you can debug it (the CI job failed at the same point)."
    else
      lk8s_log "LK8S_KEEP=true — leaving the cluster up."
    fi
    lk8s_log "Inspect:  kubectl get pods -n weaviate   |   curl localhost:8080/v1/meta"
    lk8s_log "Clean up: $dir/local-k8s.sh clean   (or re-run with LK8S_KEEP=false to always tear down)"
  else
    lk8s_log "Tearing down cluster (it auto-keeps on failure; set LK8S_KEEP=true to always keep)"
    "$dir/local-k8s.sh" clean || true
  fi
}

# ---------------------------------------------------------------------------------------
# lk8s_cleanup_trap DIR
# Register the exit handler so a repro has the same build-test-teardown-in-one property as
# the docker-based CI jobs — but, by default, a FAILED run leaves the cluster up for
# debugging (see _lk8s_on_exit for the LK8S_KEEP tri-state).
# ---------------------------------------------------------------------------------------
lk8s_cleanup_trap() {
  local dir="$1"
  # shellcheck disable=SC2064  # intentional: expand $dir now, defer $? to trap time
  trap "_lk8s_on_exit '$dir' \$?" EXIT
}
