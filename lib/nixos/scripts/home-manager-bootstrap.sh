#!/usr/bin/env bash
#
# Provision a user's standalone home-manager profile on login.
#
# Invoked by the `home-manager-bootstrap` systemd *user* service. Binaries
# (home-manager, coreutils) are provided on PATH via the wrapper's
# runtimeInputs; parameters are passed as CLI arguments:
#
#   --flake-ref <ref>          flake reference to build from
#   --hostname <name>          this host's name
#   --reactivate-every-login   re-activate on every login (default: first login only)
#   --users <user>...          users that have a home config (must come LAST)
#
# Runs in the background (oneshot service) so it never hard-blocks the login.

set -eu

flake_ref=""
hostname=""
reactivate=0
users=()

while [ $# -gt 0 ]; do
  case "$1" in
    --flake-ref)
      flake_ref="$2"
      shift 2
      ;;
    --hostname)
      hostname="$2"
      shift 2
      ;;
    --reactivate-every-login)
      reactivate=1
      shift
      ;;
    --users)
      shift
      users=("$@")
      break
      ;;
    *)
      echo "home-manager-bootstrap: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

if [ -z "${flake_ref}" ] || [ -z "${hostname}" ]; then
  echo "home-manager-bootstrap: --flake-ref and --hostname are required" >&2
  exit 64
fi

# Only act for users that have a resolved home configuration.
found=0
for user in "${users[@]}"; do
  if [ "${user}" = "${USER}" ]; then
    found=1
    break
  fi
done
if [ "${found}" != "1" ]; then
  exit 0
fi

stamp="${XDG_STATE_HOME:-${HOME}/.local/state}/home-manager-bootstrap.stamp"
if [ "${reactivate}" != "1" ] && [ -e "${stamp}" ]; then
  exit 0
fi

home-manager switch --flake "${flake_ref}#${USER}@${hostname}"

mkdir -p "$(dirname "${stamp}")"
touch "${stamp}"
