# The consent half of systemAutoUpgradeModule. Without it, logging out is
# the only way to tell the updater "go ahead" -- a silly thing to have to
# do to a machine you are actively using.
#
# Writes a waiver the policy run reads. Per user by default, in
# $XDG_RUNTIME_DIR (tmpfs, owned by that user, gone at logout), so no
# privilege is needed to consent on your own behalf. --system needs root
# and outranks every session.

runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
system_file=/run/nixos-upgrade-policy/allow-reboot
pending_file=/run/nixos-upgrade-policy/pending
target=
duration=3600
mode=grant

usage() {
  cat >&2 <<'EOF'
usage: nixos-allow-reboot [options]

Tell the NixOS auto-upgrader it may reboot without waiting for you to
log out. Consent EXPIRES, so a yes given this morning cannot fire this
afternoon.

  (no options)      allow for the next hour
  --until DURATION  allow for this long (30m, 2h, 1d, or plain seconds)
  --session         allow until you log out, with no expiry
  --cancel          withdraw consent
  --status          show the current state and exit
  --system          act on the machine-wide waiver instead of your own.
                    Outranks every session; needs root.

Examples:
  nixos-allow-reboot --until 2h     # going to lunch
  nixos-allow-reboot --session      # this machine is not mine today
  sudo nixos-allow-reboot --system --until 30m
EOF
}

# Accepts 90, 90s, 30m, 2h, 1d. A bare number is seconds, which is what
# anyone scripting this would assume.
parse_duration() {
  local v="$1" n="${1%[smhd]}" unit="${1#"${1%?}"}"
  case "$v" in
    *[!0-9smhd]* | "") return 1 ;;
  esac
  case "$v" in
    *[0-9]) echo "$v" ;;
    *s) echo "$n" ;;
    *m) echo $((n * 60)) ;;
    *h) echo $((n * 3600)) ;;
    *d) echo $((n * 86400)) ;;
    *) return 1 ;;
  esac
  [ -n "$unit" ] || true
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --until)
      if [ "$#" -lt 2 ]; then
        echo "nixos-allow-reboot: --until needs a value" >&2
        usage
        exit 64
      fi
      if ! duration=$(parse_duration "$2"); then
        echo "nixos-allow-reboot: cannot parse duration '$2' (try 30m, 2h, 1d)" >&2
        exit 64
      fi
      shift 2
      ;;
    --session) duration=session; shift ;;
    --cancel) mode=cancel; shift ;;
    --status) mode=status; shift ;;
    --system) target=system; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "nixos-allow-reboot: unknown argument '$1'" >&2
      usage
      exit 64
      ;;
  esac
done

if [ "$target" = system ]; then
  file="$system_file"
  who="machine-wide"
else
  file="$runtime_dir/nixos-allow-reboot"
  who="$(id -un)"
fi

now=$(date +%s)

describe() {
  local until
  if [ ! -f "$file" ]; then
    echo "no reboot waiver for $who"
    return
  fi
  until=$(sed -n 's/^until=//p' "$file" | head -n 1)
  case "$until" in
    session) echo "reboot allowed for $who until logout" ;;
    *[!0-9]* | "") echo "reboot waiver for $who is unreadable; treated as NO consent" ;;
    *)
      if [ "$now" -lt "$until" ]; then
        echo "reboot allowed for $who until $(date -d "@$until" '+%H:%M') ($(((until - now) / 60)) min left)"
      else
        echo "reboot waiver for $who EXPIRED at $(date -d "@$until" '+%H:%M')"
      fi
      ;;
  esac
}

case "$mode" in
  status)
    describe
    exit 0
    ;;
  cancel)
    rm -f "$file"
    echo "reboot waiver for $who withdrawn"
    exit 0
    ;;
esac

mkdir -p "$(dirname "$file")"
if [ "$duration" = session ]; then
  echo "until=session" >"$file"
else
  echo "until=$((now + duration))" >"$file"
fi
describe

# Say what it actually means right now, so "allowed" is not mistaken for
# "about to happen" on a machine with nothing staged.
if [ -f "$pending_file" ]; then
  changed=$(sed -n 's/^changed=//p' "$pending_file" | head -n 1)
  echo "a reboot IS pending (${changed:-unknown} changed) -- it will happen at the next policy check"
else
  echo "no reboot is pending right now; this applies to the next one"
fi
