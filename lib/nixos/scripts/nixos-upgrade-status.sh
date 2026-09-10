# The reporting half of systemAutoUpgradeModule. Runs on every
# interactive shell start in --only-news mode, so it stays deliberately
# cheap: two small files, no systemctl, no store access, no nix.
#
# It reads the files the policy run writes rather than re-deriving
# pending-ness, so the shell line and the notification can never disagree
# about what is going on.

pending_file=/run/nixos-upgrade-policy/pending
state_file=/var/lib/nixos-upgrade-policy/last-run
allow_file="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/nixos-allow-reboot"
only_news=0
now=

usage() {
  cat >&2 <<'EOF'
usage: nixos-upgrade-status [--only-news] [--pending-file PATH]
                            [--state-file PATH] [--allow-file PATH]
                            [--now EPOCH]

  --only-news    print nothing unless a reboot is pending or the last
                 upgrade failed (what the shell-start line uses)
  --allow-file   this user's reboot permission, as written by
                 nixos-allow-reboot
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pending-file | --state-file | --allow-file | --now)
      if [ "$#" -lt 2 ]; then
        echo "nixos-upgrade-status: $1 needs a value" >&2
        usage
        exit 64
      fi
      ;;
  esac
  case "$1" in
    --pending-file) pending_file="$2"; shift 2 ;;
    --state-file) state_file="$2"; shift 2 ;;
    --allow-file) allow_file="$2"; shift 2 ;;
    --now) now="$2"; shift 2 ;;
    --only-news) only_news=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "nixos-upgrade-status: unknown argument '$1'" >&2
      usage
      exit 64
      ;;
  esac
done

[ -n "$now" ] || now=$(date +%s)

# A field that is not there yet -- a state file from before the first
# run -- is an empty answer, not an error: `sed` on a missing file
# exits 2, and under `pipefail` that would abort the whole run.
read_field() {
  [ -f "$2" ] || return 0
  sed -n "s/^$1=//p" "$2"
}

pending_since=$(read_field since "$pending_file")
changed=$(read_field changed "$pending_file")
result=$(read_field result "$state_file")
when=$(read_field time "$state_file")

failed=0
if [ -n "$result" ] && [ "$result" != "success" ]; then failed=1; fi

if [ -z "$pending_since" ] && [ "$failed" -eq 0 ]; then
  if [ "$only_news" -eq 0 ]; then
    if [ -n "$when" ]; then
      echo "NixOS auto-upgrade: last run succeeded at $when; no reboot pending."
    else
      echo "NixOS auto-upgrade: has not run yet."
    fi
  fi
  exit 0
fi

if [ "$failed" -eq 1 ]; then
  echo "NixOS auto-upgrade: last run FAILED (result: $result) at ${when:-unknown}."
fi

if [ -n "$pending_since" ]; then
  hours=$(( (now - pending_since) / 3600 ))
  echo "NixOS auto-upgrade: reboot required (${changed:-unknown} changed), pending for ${hours}h."

  # Say whether YOU are the one holding it up. Without this the two
  # commands describe the same situation from different halves and
  # neither puts them together: this one says a reboot is pending, and
  # `nixos-allow-reboot --status` says you allowed it.
  allow_until=$(read_field until "$allow_file")
  case "$allow_until" in
    session) echo "  You have allowed it (until you log out)." ;;
    "" | *[!0-9]*) ;;
    *)
      if [ "$now" -lt "$allow_until" ]; then
        echo "  You have allowed it (for another $(((allow_until - now) / 60)) min); it happens at the next check."
      fi
      ;;
  esac
fi

# A recorded failure is the actionable case, so it is also the exit code
# -- a pending reboot alone is information, not an error.
exit "$failed"
