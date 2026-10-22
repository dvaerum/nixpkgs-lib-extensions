# Provision a user's standalone home-manager profile on login.
#
# Invoked by the `home-manager-bootstrap` systemd *user* service. Binaries
# (home-manager, coreutils) are provided on PATH via the wrapper's
# runtimeInputs; the wrapper (writeShellApplication) also provides the
# shebang and `set -euo pipefail`. Parameters are passed as CLI arguments:
#
#   --flake-ref <ref>          flake reference to build from
#   --hostname <name>          this host's name
#   --reactivate-every-login   re-activate on every login (default: first login only)
#   --reactivate-on-target-change  re-activate whenever the resolved
#                             flake-ref/attr differs from the last
#                             recorded activation, even on an otherwise
#                             ordinary login (default: off -- presence of
#                             the stamp alone is enough to skip)
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
reactivate_on_target_change=0
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
    --reactivate-on-target-change)
      reactivate_on_target_change=1
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

# "First login" means ONCE EVER for this user -- presence of the stamp
# is enough to skip, regardless of what it contains. Deliberately NOT a
# content comparison by default: `inputs.self` (the usual default
# flakeRef) gets a brand-new store path on every `nixos-rebuild switch`,
# even for a change with nothing to do with home.nix, so comparing stamp
# content made an ordinary rebuild indistinguishable from "this user
# needs re-provisioning" -- silently reverting anything switched to by
# hand since. The stamp still RECORDS the activation parameters
# (flake-ref#attr) regardless, both for operator visibility and for
# --reactivate-on-target-change below, which opts back into comparing
# them for whoever wants that as a standing policy -- note it reacts to
# ANY change in the resolved string, not specifically a deliberate
# migration; a routine rebuild looks the same to it as a real one would.
stamp="${XDG_STATE_HOME:-${HOME}/.local/state}/home-manager-bootstrap.stamp"
stamp_params="${flake_ref}#${attr}"
if [ "${reactivate}" != "1" ] && [ -e "${stamp}" ]; then
  if [ "${reactivate_on_target_change}" != "1" ] || [ "$(cat "${stamp}")" = "${stamp_params}" ]; then
    exit 0
  fi
fi

home-manager switch --flake "${flake_ref}#${attr}"

mkdir -p "$(dirname "${stamp}")"
printf '%s' "${stamp_params}" > "${stamp}"
