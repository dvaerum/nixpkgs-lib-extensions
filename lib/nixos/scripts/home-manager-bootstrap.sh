# Provision a user's standalone home-manager profile on login.
#
# Invoked by the `home-manager-bootstrap` systemd *user* service. Binaries
# (home-manager, coreutils) are provided on PATH via the wrapper's
# runtimeInputs; the wrapper (writeShellApplication) also provides the
# shebang and `set -eu`. Parameters are passed as CLI arguments:
#
#   --flake-ref <ref>          flake reference to build from
#   --hostname <name>          this host's name
#   --reactivate-every-login   re-activate on every login (default: first login only)
#   --user-attrs <user>=<attr>...  users to bootstrap and the flake
#                             attribute each activates (must come LAST)
#
# Runs in the background (oneshot service) so it never hard-blocks the login.

usage() {
  echo "usage: home-manager-bootstrap --flake-ref <ref> --hostname <name> [--reactivate-every-login] --user-attrs <user>=<attr>..." >&2
}

# a missing VALUE after an option is a usage error (exit 64), not a
# nounset crash on "$2"
require_value() {
  echo "home-manager-bootstrap: $1 requires a value" >&2
  usage
  exit 64
}

flake_ref=""
hostname=""
reactivate=0
user_attrs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --flake-ref)
      [ $# -ge 2 ] || require_value --flake-ref
      flake_ref="$2"
      shift 2
      ;;
    --hostname)
      [ $# -ge 2 ] || require_value --hostname
      hostname="$2"
      shift 2
      ;;
    --reactivate-every-login)
      reactivate=1
      shift
      ;;
    --user-attrs)
      shift
      user_attrs=("$@")
      break
      ;;
    *)
      echo "home-manager-bootstrap: unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [ -z "${flake_ref}" ] || [ -z "${hostname}" ]; then
  echo "home-manager-bootstrap: --flake-ref and --hostname are required" >&2
  usage
  exit 64
fi

# Only act for users that have a resolved home configuration. Each entry
# is `<user>=<attr>`: the flake attribute to switch to, resolved at BUILD
# time by homeManagerBootstrapModule (see its `attrFor`) rather than
# reconstructed here -- this script cannot see the target flake's outputs,
# so a name guessed here would fail at login on one machine, invisibly.
attr=""
for pair in "${user_attrs[@]}"; do
  if [ "${pair%%=*}" = "${USER}" ]; then
    attr="${pair#*=}"
    break
  fi
done
if [ -z "${attr}" ]; then
  exit 0
fi

# The stamp records WHAT was activated, not merely THAT something was:
# a stamp whose content differs from the current parameters -- the flake
# ref or hostname changed, the user moved between home mechanisms, or
# the stamp predates content-carrying stamps -- counts as absent, so the
# bootstrap re-runs instead of skipping on stale state.
stamp="${XDG_STATE_HOME:-${HOME}/.local/state}/home-manager-bootstrap.stamp"
stamp_params="${flake_ref}#${attr}"
if [ "${reactivate}" != "1" ] && [ -e "${stamp}" ] \
  && [ "$(cat "${stamp}")" = "${stamp_params}" ]; then
  exit 0
fi

home-manager switch --flake "${flake_ref}#${attr}"

mkdir -p "$(dirname "${stamp}")"
printf '%s' "${stamp_params}" > "${stamp}"
