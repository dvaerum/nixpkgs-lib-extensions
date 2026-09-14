# Refresh a user's standalone home-manager profile from a LIVE flake ref.
#
# Invoked by the `hm-auto-upgrade` systemd *user* service (itself timer
# -triggered). Binaries (home-manager, nix, coreutils, ...) come from the
# wrapper's runtimeInputs; the wrapper (writeShellApplication) provides
# the shebang and `set -euo pipefail`. Parameters are CLI arguments:
#
#   --flake-ref <ref>         LIVE flake reference to track (required)
#   --username <name>         whose home to switch
#   --state-file <path>       where the run's outcome is recorded
#   --keep-generations <n>    profile generations to retain (0 = never prune)
#   --ssh-key <path>          private key for an SSH-flavoured ref
#   --ssh-auth-sock <path>    agent socket, when not already in the env
#   --ssh-option <opt>        extra `ssh -o` option (repeatable)
#   --git-credentials <path>  git-credentials-format file for HTTPS
#   --pre-command <path>      shell fragment SOURCED before the switch
#   --on-result <path>        shell fragment SOURCED after, sees $RESULT
#   --desktop-notify          allow desktop notifications
#
# Unlike the login bootstrap, the target attribute is resolved HERE, at
# run time: the whole point is to track a ref whose outputs may have
# changed since this system was built, so a build-time answer would go
# stale (see homeManagerBootstrapModule's attrFor for the eval-time
# counterpart, which is correct for ITS pinned-ref job).

usage() {
  echo "usage: hm-auto-upgrade --flake-ref <ref> --username <name> --state-file <path> [options]" >&2
}

require_value() {
  echo "hm-auto-upgrade: $1 requires a value" >&2
  usage
  exit 64
}

flake_ref=""
username=""
state_file=""
keep_generations=0
ssh_key=""
ssh_auth_sock=""
ssh_options=()
git_credentials=""
pre_command=""
on_result=""
desktop_notify=0

while [ $# -gt 0 ]; do
  case "$1" in
    --flake-ref) [ $# -ge 2 ] || require_value --flake-ref; flake_ref="$2"; shift 2 ;;
    --username) [ $# -ge 2 ] || require_value --username; username="$2"; shift 2 ;;
    --state-file) [ $# -ge 2 ] || require_value --state-file; state_file="$2"; shift 2 ;;
    --keep-generations) [ $# -ge 2 ] || require_value --keep-generations; keep_generations="$2"; shift 2 ;;
    --ssh-key) [ $# -ge 2 ] || require_value --ssh-key; ssh_key="$2"; shift 2 ;;
    --ssh-auth-sock) [ $# -ge 2 ] || require_value --ssh-auth-sock; ssh_auth_sock="$2"; shift 2 ;;
    --ssh-option) [ $# -ge 2 ] || require_value --ssh-option; ssh_options+=("$2"); shift 2 ;;
    --git-credentials) [ $# -ge 2 ] || require_value --git-credentials; git_credentials="$2"; shift 2 ;;
    --pre-command) [ $# -ge 2 ] || require_value --pre-command; pre_command="$2"; shift 2 ;;
    --on-result) [ $# -ge 2 ] || require_value --on-result; on_result="$2"; shift 2 ;;
    --desktop-notify) desktop_notify=1; shift ;;
    *)
      echo "hm-auto-upgrade: unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [ -z "${flake_ref}" ] || [ -z "${username}" ] || [ -z "${state_file}" ]; then
  echo "hm-auto-upgrade: --flake-ref, --username and --state-file are required" >&2
  usage
  exit 64
fi

config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/hm-auto-upgrade"

# Never let nix serve a CACHED view of the ref we are supposed to be
# tracking. A `git+https://`/`github:` ref carrying no rev is cached for
# `tarball-ttl` (default 3600s), so a run started within an hour of the
# last fetch applies whatever was current THEN and reports success --
# an auto-upgrade that silently installs an hour-old revision is worse
# than one that fails, because nothing says it happened. Verified: a
# push followed by an immediate run resolved the previous commit until
# the TTL was bypassed.
#
# Set through NIX_CONFIG rather than a CLI flag so it reaches every nix
# subprocess uniformly -- the eval probe below AND the `nix build` that
# home-manager runs internally, which no flag of ours would reach.
export NIX_CONFIG="tarball-ttl = 0
${NIX_CONFIG:-}"

# ---------------------------------------------------------------- state
# Read the PREVIOUS outcome before overwriting: a success is only worth
# notifying about when it ends a run of failures (see notify() below).
previous_status="unknown"
if [ -r "${state_file}" ]; then
  previous_status="$(sed -n 's/^status=//p' "${state_file}" | head -n1)"
  [ -n "${previous_status}" ] || previous_status="unknown"
fi

write_state() {
  mkdir -p "$(dirname "${state_file}")"
  cat > "${state_file}" <<EOF
status=$1
exit_code=$2
target=${3}
flake_ref=${flake_ref}
timestamp=$(date -Is)
previous_status=${previous_status}
EOF
}

# Desktop notification, best-effort and STRICTLY optional: a headless or
# pre-login run legitimately has no session bus, and that must not turn a
# successful upgrade into a failed unit. Every failure here is swallowed
# on purpose -- the journal and the state file are the reliable records;
# this is only the convenience layer on top.
notify() {
  [ "${desktop_notify}" = "1" ] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  # a session bus must actually be reachable, else notify-send blocks or
  # errors depending on the backend
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ ! -S "/run/user/$(id -u)/bus" ]; then
    return 0
  fi
  notify-send --app-name="home-manager" "$1" "$2" >/dev/null 2>&1 || true
}

# ---------------------------------------------------- credential wiring
# Force a NON-INTERACTIVE credential chain for this process only. The
# default chain can include helpers (git-credential-oauth and friends)
# that block FOREVER on "complete authentication in your browser" with no
# timeout -- fatal for an unattended timer, and invisible: the unit just
# hangs until RuntimeMaxSec kills it. GIT_CONFIG_* is read last and is
# inherited by nix's own git subprocesses.
export GIT_TERMINAL_PROMPT=0

# A credential file readable by anyone else is refused rather than used
# -- same stance ssh takes on private keys. Cheap insurance against a
# hand-created file left at 0644.
require_private() {
  local path="$1" kind="$2" mode
  mode="$(stat -c '%a' "${path}")"
  case "${mode}" in
    600 | 400) ;;
    *)
      echo "hm-auto-upgrade: ${kind} ${path} is mode ${mode}; refusing to use it." >&2
      echo "hm-auto-upgrade: fix with: chmod 600 ${path}" >&2
      return 1
      ;;
  esac
}

# HTTPS: an explicit path wins, else the conventional runtime location.
# Only the PATH is ever configured in nix -- the content is read here, so
# rotating a token needs no rebuild.
if [ -z "${git_credentials}" ] && [ -r "${config_dir}/git-credentials" ]; then
  git_credentials="${config_dir}/git-credentials"
fi
if [ -n "${git_credentials}" ]; then
  if [ ! -r "${git_credentials}" ]; then
    echo "hm-auto-upgrade: git credentials file ${git_credentials} is not readable" >&2
    exit 1
  fi
  require_private "${git_credentials}" "git credentials file"
fi

# Reset the chain to store-only ALWAYS, not just when a file was
# configured. GIT_TERMINAL_PROMPT=0 governs git's OWN prompting, not a
# credential HELPER: git-credential-oauth and friends are separate
# programs that print a URL and wait for a browser, indefinitely, with
# no timeout. Leaving the ambient chain in place for an unattended timer
# is how a run hangs until RuntimeMaxSec kills it. With no file
# configured this still narrows the chain to `store` reading git's own
# default (~/.git-credentials).
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=
export GIT_CONFIG_KEY_1=credential.helper
if [ -n "${git_credentials}" ]; then
  export GIT_CONFIG_VALUE_1="store --file=${git_credentials}"
else
  export GIT_CONFIG_VALUE_1=store
fi

# SSH: explicit key, else conventional runtime key, else an agent that is
# genuinely reachable. BatchMode is the ssh-side counterpart of
# GIT_TERMINAL_PROMPT=0 -- no passphrase or host-key prompt, fail fast
# instead of hanging.
if [ -z "${ssh_key}" ] && [ -r "${config_dir}/ssh-key" ]; then
  ssh_key="${config_dir}/ssh-key"
fi
if [ -n "${ssh_auth_sock}" ]; then
  export SSH_AUTH_SOCK="${ssh_auth_sock}"
fi

ssh_cmd="ssh -o BatchMode=yes"
if [ -n "${ssh_key}" ]; then
  if [ ! -r "${ssh_key}" ]; then
    echo "hm-auto-upgrade: ssh key ${ssh_key} is not readable" >&2
    exit 1
  fi
  require_private "${ssh_key}" "ssh key"
  ssh_cmd="${ssh_cmd} -i ${ssh_key} -o IdentitiesOnly=yes"
fi
for opt in ${ssh_options[@]+"${ssh_options[@]}"}; do
  ssh_cmd="${ssh_cmd} -o ${opt}"
done
export GIT_SSH_COMMAND="${ssh_cmd}"

# An SSH-flavoured ref with no usable credential at all would hit
# BatchMode and fail with a bare "Permission denied (publickey)" that
# names none of the fixes. Say so up front instead.
case "${flake_ref}" in
  *git+ssh://* | *ssh://* | *git@*)
    have_agent=0
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
      have_agent=1
    fi
    if [ -z "${ssh_key}" ] && [ "${have_agent}" != "1" ]; then
      echo "hm-auto-upgrade: ${flake_ref} needs SSH credentials, but none are available:" >&2
      echo "  - no key configured (services.homeManagerAutoUpgrade.sshKeyPath)" >&2
      echo "  - no key at ${config_dir}/ssh-key" >&2
      echo "  - no reachable agent (SSH_AUTH_SOCK unset or its socket missing;" >&2
      echo "    a systemd user service does NOT inherit a login shell's agent --" >&2
      echo "    see services.homeManagerAutoUpgrade.sshAuthSock)" >&2
      write_state fail 1 ""
      notify "Home Manager auto-upgrade failed" "No SSH credentials available for ${flake_ref}"
      exit 1
    fi
    ;;
esac

# ------------------------------------------------------------- pre-hook
# Sourced, not executed: a consumer's fragment commonly exports
# environment for the switch that follows.
if [ -n "${pre_command}" ]; then
  # shellcheck source=/dev/null
  . "${pre_command}"
fi

# -------------------------------------------------------- resolve target
# Prefer this host's own override when the LIVE flake exports one. Not
# cached and not decided at build time: a hosts/<hostname>/ directory
# added since the last rebuild must take effect on the next run.
# `uname -n`, not `hostname`: same value, but from coreutils, which the
# wrapper already provides -- the `hostname` binary lives in a separate
# package that a user service's PATH would otherwise need too.
host_target="${username}@$(uname -n)"
target="${username}"
if nix eval "${flake_ref}#homeConfigurations" \
     --apply "x: builtins.hasAttr \"${host_target}\" x" --json 2>/dev/null \
     | grep -qx true; then
  target="${host_target}"
fi

echo "hm-auto-upgrade: switching to ${flake_ref}#${target}"

# ------------------------------------------------------------- the switch
# `set -e` would abort before the result can be recorded or notified, so
# the exit code is captured explicitly.
result=0
home-manager switch \
  --flake "${flake_ref}#${target}" \
  -b "hm-backup-$(date +%Y%m%dT%H%M%S)" || result=$?

# Pruning is best-effort and deliberately never fails the run: an upgrade
# that succeeded must not be reported as failed because cleanup of OLD
# generations hit a lock or a read-only store.
if [ "${keep_generations}" -gt 0 ]; then
  nix-env --delete-generations "+${keep_generations}" \
    --profile "${HOME}/.local/state/nix/profiles/home-manager" >/dev/null 2>&1 \
    || echo "hm-auto-upgrade: pruning old generations failed (upgrade itself was fine)" >&2
fi

if [ "${result}" -eq 0 ]; then
  write_state ok 0 "${target}"
  # Success is only news when it ENDS a failing streak; a daily "still
  # fine" popup trains you to dismiss the ones that matter.
  if [ "${previous_status}" = "fail" ]; then
    notify "Home Manager auto-upgrade recovered" "Now succeeding again for ${target}"
  fi
else
  write_state fail "${result}" "${target}"
  notify "Home Manager auto-upgrade failed" "Exit ${result} for ${target} -- see: journalctl --user -u hm-auto-upgrade"
fi

# ------------------------------------------------------------ post-hook
if [ -n "${on_result}" ]; then
  # TRANSITION is the decision this script already made to choose its own
  # notification, handed over rather than left to be re-derived. Without
  # it a hook has to sed `previous_status=` out of the state file, which
  # couples consumer code to a format that is nobody's public interface
  # and makes it re-implement a rule that can then drift from this one.
  if [ "${result}" -ne 0 ]; then
    TRANSITION=fail
  elif [ "${previous_status}" = "fail" ]; then
    TRANSITION=recover
  else
    TRANSITION=steady
  fi

  # EXECUTED, not sourced. Sourcing gave a hook two ways to break its
  # host silently: an `exit` anywhere in it terminated this script
  # mid-run, and its variables shared this script's namespace -- the
  # real consumer declared `previous_status`, the very name used above,
  # and got away with it only because nothing read it afterwards.
  RESULT="${result}" TARGET="${target}" STATE_FILE="${state_file}" \
    PREVIOUS_STATUS="${previous_status}" TRANSITION="${TRANSITION}" \
    "${on_result}"
fi

exit "${result}"
