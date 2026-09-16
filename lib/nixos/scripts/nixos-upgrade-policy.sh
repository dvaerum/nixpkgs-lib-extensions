# The policy half of systemAutoUpgradeModule: nixpkgs' own
# `system.autoUpgrade` has already fetched, built and STAGED a generation
# (operation = "boot"); everything about what to do with it now lives
# here. Run both right after nixos-upgrade.service and on a poll timer,
# so it has to be idempotent -- every branch below is safe to re-enter.
#
# Paths and policy all arrive as flags with real defaults, so
# checks/system-auto-upgrade/script.nix can drive every branch with stub
# binaries and a fake clock instead of a VM.

booted_system=/run/booted-system
current_system=/run/current-system
profile=/nix/var/nix/profiles/system
runtime_dir=/run/nixos-upgrade-policy
state_file=/var/lib/nixos-upgrade-policy/last-run
shutdown_scheduled=/run/systemd/shutdown/scheduled
user_runtime_dir=/run/user
system_allow_file=/run/nixos-upgrade-policy/allow-reboot
upgrade_unit=nixos-upgrade.service
policy_unit=nixos-upgrade-policy.service
reboot_triggers=kernel,initrd,kernel-modules
reboot_window=
reminders=24:360,4:60,1:15
notify_interval=86400
force_after=
force_grace=5
reboot_grace=1
poll_interval=
pre_command=
on_result=
desktop_notify=0
dry_run=0
now=

usage() {
  cat >&2 <<'EOF'
usage: nixos-upgrade-policy [options]

  --booted-system PATH     what this kernel booted (default /run/booted-system)
  --current-system PATH    what is activated now (default /run/current-system)
  --profile PATH           what nixos-upgrade staged
                           (default /nix/var/nix/profiles/system)
  --runtime-dir PATH       tmpfs bookkeeping (default /run/nixos-upgrade-policy)
  --state-file PATH        persistent last-run record
  --shutdown-scheduled PATH  systemd's own scheduled-shutdown marker
  --user-runtime-dir PATH  where per-user session buses and reboot
                           permissions live (default /run/user)
  --system-allow-file PATH   the machine-wide "reboot regardless of who
                           is logged in" permission
  --upgrade-unit NAME      the engine unit to read a result from
  --policy-unit NAME       this unit's own name, for self-armed wakeups
  --reboot-triggers LIST   comma-separated: kernel,initrd,kernel-modules
  --reboot-window LO-HI    e.g. 04:00-06:00; empty means any time
  --reminders SPEC         remainingHours:everyMinutes, comma-separated
  --notify-interval SEC    cadence outside the reminder ladder
  --force-after SEC        deadline from pending-since; empty means NEVER
  --force-grace MIN        countdown for the DEADLINE reboot
  --reboot-grace MIN       countdown for the ordinary reboot, once
                           nothing is blocking it any more
  --poll-interval SEC      how often this runs, to decide whether to arm
                           an exact wakeup; empty means polling is off
  --pre-command PATH       sourced-ish hook run before anything else
  --on-result PATH         hook run once per NEW upgrade result
  --desktop-notify         allow notify-send on a user's session bus
  --dry-run                log destructive actions instead of doing them
  --now EPOCH              fake clock, for tests
EOF
}

while [ "$#" -gt 0 ]; do
  # every value-taking flag checks $# first: a missing value must be a
  # usage error, not a `set -u` crash on "$2"
  case "$1" in
    --booted-system | --current-system | --profile | --runtime-dir | --state-file | \
      --shutdown-scheduled | --user-runtime-dir | --system-allow-file | \
      --upgrade-unit | --policy-unit | \
      --reboot-triggers | \
      --reboot-window | --reminders | --notify-interval | --force-after | \
      --force-grace | --reboot-grace | --poll-interval | --pre-command | --on-result | --now)
      if [ "$#" -lt 2 ]; then
        echo "nixos-upgrade-policy: $1 needs a value" >&2
        usage
        exit 64
      fi
      ;;
  esac
  case "$1" in
    --booted-system) booted_system="$2"; shift 2 ;;
    --current-system) current_system="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --runtime-dir) runtime_dir="$2"; shift 2 ;;
    --state-file) state_file="$2"; shift 2 ;;
    --shutdown-scheduled) shutdown_scheduled="$2"; shift 2 ;;
    --user-runtime-dir) user_runtime_dir="$2"; shift 2 ;;
    --system-allow-file) system_allow_file="$2"; shift 2 ;;
    --upgrade-unit) upgrade_unit="$2"; shift 2 ;;
    --policy-unit) policy_unit="$2"; shift 2 ;;
    --reboot-triggers) reboot_triggers="$2"; shift 2 ;;
    --reboot-window) reboot_window="$2"; shift 2 ;;
    --reminders) reminders="$2"; shift 2 ;;
    --notify-interval) notify_interval="$2"; shift 2 ;;
    --force-after) force_after="$2"; shift 2 ;;
    --force-grace) force_grace="$2"; shift 2 ;;
    --reboot-grace) reboot_grace="$2"; shift 2 ;;
    --poll-interval) poll_interval="$2"; shift 2 ;;
    --pre-command) pre_command="$2"; shift 2 ;;
    --on-result) on_result="$2"; shift 2 ;;
    --now) now="$2"; shift 2 ;;
    --desktop-notify) desktop_notify=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "nixos-upgrade-policy: unknown argument '$1'" >&2
      usage
      exit 64
      ;;
  esac
done

[ -n "$now" ] || now=$(date +%s)

log() { echo "nixos-upgrade-policy: $*"; }

# Destructive actions only. Notifications stay REAL under --dry-run: the
# whole point of the flag is to see the notification UX on a live desktop
# without losing the machine.
act() {
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN: would run: $*"
  else
    "$@"
  fi
}

# A field that is not there yet -- a state file from before the first
# run -- is an empty answer, not an error: `sed` on a missing file
# exits 2, and under `pipefail` that would abort the whole run.
read_field() {
  [ -f "$2" ] || return 0
  sed -n "s/^$1=//p" "$2"
}

# ── the two questions, kept apart ──────────────────────────────────
# booted vs profile  -> is a REBOOT needed
# current vs profile -> is an ACTIVATION needed
link_of() {
  # A component that does not exist on one side and does on the other is
  # a real difference; an empty answer on both sides is not. Either way
  # a missing path must not abort the run.
  readlink -f "$1" 2>/dev/null || true
}

differing=
IFS=, read -r -a _triggers <<<"$reboot_triggers"
for t in "${_triggers[@]}"; do
  [ -n "$t" ] || continue
  if [ "$(link_of "$booted_system/$t")" != "$(link_of "$profile/$t")" ]; then
    differing="${differing:+$differing,}$t"
  fi
done

if [ -n "$pre_command" ]; then "$pre_command"; fi

mkdir -p "$runtime_dir" "$(dirname "$state_file")"
pending_file="$runtime_dir/pending"

reboot_pending=0
if [ -n "$differing" ]; then reboot_pending=1; fi

# ── record a NEW upgrade result, once ────────────────────────────────
# This unit runs on every poll as well as after the engine, so the
# engine's own exit timestamp is what says "this is a result you have not
# reported yet". Without that, a per-run onResult hook would fire on
# every poll instead of once a day.
# `systemctl show` answers Result=success for a unit that was never
# loaded, so a typo in --upgrade-unit would otherwise read as an endless
# run of successful upgrades. Check that the unit exists before
# believing anything it says. (The timestamp guard below happens to stop
# a phantom result being recorded, but relying on that would be relying
# on a side effect.)
upgrade_loadstate=$(systemctl show "$upgrade_unit" --property=LoadState --value 2>/dev/null || echo unknown)
if [ "$upgrade_loadstate" != "loaded" ]; then
  log "engine unit '$upgrade_unit' is not loaded (LoadState=$upgrade_loadstate) -- not recording a result for it"
fi

upgrade_result=$(systemctl show "$upgrade_unit" --property=Result --value 2>/dev/null || echo unknown)
upgrade_stamp=$(systemctl show "$upgrade_unit" --property=ExecMainExitTimestampMonotonic --value 2>/dev/null || echo 0)
[ -n "$upgrade_result" ] || upgrade_result=unknown
[ -n "$upgrade_stamp" ] || upgrade_stamp=0

previous_stamp=$(read_field upgrade-stamp "$state_file")
if [ "$upgrade_loadstate" = "loaded" ] &&
  [ "$upgrade_stamp" != "0" ] && [ "$upgrade_stamp" != "$previous_stamp" ]; then
  generation=$(link_of "$profile")
  cat >"$state_file" <<EOF
time=$(date -d "@$now" --iso-8601=seconds)
epoch=$now
result=$upgrade_result
upgrade-stamp=$upgrade_stamp
generation=$generation
reboot-pending=$reboot_pending
EOF
  log "recorded upgrade result: $upgrade_result (generation $generation)"
  if [ -n "$on_result" ]; then
    RESULT="$upgrade_result" REBOOT_PENDING="$reboot_pending" \
      GENERATION="$generation" STATE_FILE="$state_file" "$on_result"
  fi
fi

# ── no reboot needed: adopt the staged generation, then stop ─────────
if [ "$reboot_pending" -eq 0 ]; then
  rm -f "$pending_file"
  if [ "$(link_of "$current_system")" != "$(link_of "$profile")" ]; then
    log "no reboot needed; activating the staged generation"
    act "$profile/bin/switch-to-configuration" switch
  else
    log "up to date; nothing to do"
  fi
  exit 0
fi

# ── a reboot IS needed: the generation stays staged, untouched ───────
log "reboot needed (changed: $differing)"

pending_since=$(read_field since "$pending_file")
last_notified=$(read_field last-notified "$pending_file")
# Newly pending is its OWN case, not "last_notified is very old": the
# first time a reboot becomes necessary, say so immediately rather than
# waiting out an interval nobody has started yet.
newly_pending=0
if [ -z "$pending_since" ]; then
  pending_since=$now
  last_notified=0
  newly_pending=1
fi
[ -n "$last_notified" ] || last_notified=0
write_pending() {
  cat >"$pending_file" <<EOF
since=$pending_since
last-notified=$last_notified
changed=$differing
EOF
}

# ── who is actually here ─────────────────────────────────────────────
# An ALLOW-LIST. `manager`/`manager-early` is the session a LINGERING
# user has with nobody logged in; `background`/`background-light` is what
# our own `systemd-run --machine` creates. Neither is a person, and a
# deny-list would have to keep guessing at the next class systemd adds.
#
# A person can also give PERMISSION despite their own block, the only way to say
# "go ahead" short of logging out. Consent is per user and carries an
# expiry, so a yes given this morning cannot fire this afternoon.
permission_active() {
  [ -f "$1" ] || return 1
  local until
  until=$(sed -n 's/^until=//p' "$1" | head -n 1)
  case "$until" in
    session) return 0 ;;
    "") return 1 ;;
    *[!0-9]*) return 1 ;; # unparseable is NOT consent
    *) [ "$now" -lt "$until" ] ;;
  esac
}

# Sets `blocking` (name:uid of everyone still in the way) and
# `allowed_present` (someone IS here but said go ahead -- which is what
# lets the reboot skip the window: there is nobody left to protect).
blocking=
allowed_users=
allowed_present=0
scan_sessions() {
  local id props s_class s_state s_name s_uid
  blocking=
  allowed_users=
  allowed_present=0
  for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    props=$(loginctl show-session "$id" -p Class -p State -p Name -p User 2>/dev/null || true)
    s_class=$(printf '%s\n' "$props" | sed -n 's/^Class=//p')
    s_state=$(printf '%s\n' "$props" | sed -n 's/^State=//p')
    s_name=$(printf '%s\n' "$props" | sed -n 's/^Name=//p')
    s_uid=$(printf '%s\n' "$props" | sed -n 's/^User=//p')
    case "$s_class" in
      user | user-early | user-incomplete) ;;
      *) continue ;;
    esac
    if [ "$s_state" = "closing" ]; then continue; fi
    if permission_active "$user_runtime_dir/$s_uid/nixos-allow-reboot"; then
      allowed_present=1
      allowed_users="${allowed_users:+$allowed_users }$s_name:$s_uid"
      continue
    fi
    case " $blocking " in
      *" $s_name:$s_uid "*) ;;
      *) blocking="${blocking:+$blocking }$s_name:$s_uid" ;;
    esac
  done
}

# The admin-wide override outranks every session: for a remote admin who
# cannot ask each user, and for maintenance scripts.
system_override=0
if permission_active "$system_allow_file"; then
  system_override=1
  log "machine-wide reboot permission is active; sessions will not block"
fi

scan_sessions
if [ "$system_override" -eq 1 ]; then
  blocking=
  allowed_present=1
fi

# ABSOLUTE path, resolved here: `systemd-run --machine=<user>@` looks the
# command up in the TARGET manager's PATH, not this unit's, and a system
# unit's runtimeInputs mean nothing over there. The store is shared, so
# the full path always works. (Found the hard way: the bare name failed
# with 203/EXEC while systemd-run itself still reported success.)
notify_send=$(command -v notify-send 2>/dev/null || true)

notify() {
  local urgency="$1" title="$2" body="$3"
  # Audience defaults to whoever is BLOCKING, which is right for a
  # reminder. The imminent-reboot announcement passes everyone PRESENT
  # instead -- a person who gave permission is still sitting there, and
  # dropping them from the audience would silence exactly the people most
  # likely to be at the keyboard.
  local audience="${4:-$blocking}"
  local need_wall=0 entry name uid
  for entry in $audience; do
    name="${entry%%:*}"
    uid="${entry##*:}"
    if [ "$desktop_notify" -eq 1 ] && [ -n "$notify_send" ] &&
      [ -e "$user_runtime_dir/$uid/bus" ]; then
      # Runs inside that user's own manager, which is where a session bus
      # and a working notification daemon actually are. --wait so a
      # failure INSIDE the transient unit reaches us -- without it
      # systemd-run reports success for merely having started it, and a
      # notification that never appeared looks delivered. Capped, because
      # a wedged notification daemon must not stall the policy run.
      systemd-run --user --machine="$name@.host" --collect --quiet --wait \
        -p RuntimeMaxSec=30 -- \
        "$notify_send" -a "NixOS" -u "$urgency" "$title" "$body" ||
        need_wall=1
    else
      need_wall=1
    fi
  done
  if [ "$need_wall" -eq 1 ]; then
    wall "$title -- $body" || true # a console-less host has nowhere to write; not fatal
  fi
  last_notified=$now
}

# ── the deadline, tested BEFORE the session check ────────────────────
# Under the session check it would only ever fire on machines someone
# uses, leaving an unattended host whose reboot window never coincides
# with it being awake pending forever. Exactly backwards.
deadline=
if [ -n "$force_after" ]; then
  deadline=$((pending_since + force_after))
fi

if [ -n "$deadline" ] && [ "$now" -ge "$deadline" ]; then
  write_pending
  if [ -e "$shutdown_scheduled" ]; then
    log "deadline passed; a shutdown is already scheduled"
    exit 0
  fi
  log "deadline passed; forcing a reboot in $force_grace minute(s)"
  notify critical "NixOS: rebooting in $force_grace minutes" \
    "A required reboot ($differing) is now overdue. Save your work -- run 'shutdown -c' to cancel."
  write_pending
  act shutdown -r "+$force_grace" "NixOS: required reboot ($differing)"
  exit 0
fi

# ── someone is here: remind on the ladder, never force ───────────────
if [ -n "$blocking" ]; then
  interval="$notify_interval"
  remaining=
  if [ -n "$deadline" ]; then
    remaining=$((deadline - now))
    best=
    IFS=, read -r -a _rungs <<<"$reminders"
    for rung in "${_rungs[@]}"; do
      [ -n "$rung" ] || continue
      rung_secs=$(( ${rung%%:*} * 3600 ))
      if [ "$remaining" -le "$rung_secs" ] && { [ -z "$best" ] || [ "$rung_secs" -lt "$best" ]; }; then
        best="$rung_secs"
        interval=$(( ${rung##*:} * 60 ))
      fi
    done
  fi

  if [ "$newly_pending" -eq 1 ] || [ "$((now - last_notified))" -ge "$interval" ]; then
    if [ -n "$remaining" ]; then
      hours=$(( (remaining + 3599) / 3600 ))
      urgency=normal
      if [ "$remaining" -le 3600 ]; then urgency=critical; fi
      notify "$urgency" "NixOS: reboot required" \
        "A required reboot ($differing) is pending; this machine reboots automatically in ~${hours}h."
    else
      notify normal "NixOS: reboot required" \
        "A required reboot ($differing) is pending. It waits until you log out -- nothing is forced."
    fi
  else
    log "someone is logged in; next reminder in $((interval - (now - last_notified)))s"
  fi
  write_pending

  # Arm an exact wakeup only when the next reminder (or the deadline)
  # lands before the next poll would. At the default poll interval this
  # never triggers; it is what makes coarsening --poll-interval safe.
  next=$((last_notified + interval - now))
  if [ -n "$deadline" ] && [ "$((deadline - now))" -lt "$next" ]; then
    next=$((deadline - now))
  fi
  # --poll-interval 0 means "no poll timer exists, nothing else will wake
  # me"; a positive value means "only bother if the event lands sooner
  # than that"; absent means the caller did not say, so do not guess.
  if [ "$next" -gt 0 ] && [ -n "$poll_interval" ] &&
    { [ "$poll_interval" -eq 0 ] || [ "$next" -lt "$poll_interval" ]; }; then
    if ! systemctl is-active --quiet nixos-upgrade-policy-wake.timer 2>/dev/null; then
      # Best-effort by design: a wakeup we failed to arm costs at most a
      # late reminder at the next poll, and must not abort a run that may
      # still have a reboot to perform.
      systemd-run --on-active="$next" --unit=nixos-upgrade-policy-wake --collect --quiet \
        systemctl start "$policy_unit" ||
        log "could not arm an exact wakeup; the next poll will pick this up"
    fi
  fi
  exit 0
fi

# ── nobody is here ───────────────────────────────────────────────────
write_pending

# Minutes-since-midnight, so a window is plain integer arithmetic rather
# than string comparison on "HH:MM" (which is correct but reads like a
# bug, and is one keystroke away from actually being one).
to_minutes() { echo $(( 10#${1%%:*} * 60 + 10#${1##*:} )); }

in_window() {
  [ -n "$reboot_window" ] || return 0
  local lo hi cur
  lo=$(to_minutes "${reboot_window%%-*}")
  hi=$(to_minutes "${reboot_window##*-}")
  cur=$(to_minutes "$(date -d "@$now" +%H:%M)")
  if [ "$lo" -le "$hi" ]; then
    [ "$cur" -ge "$lo" ] && [ "$cur" -le "$hi" ]
  else
    # spans midnight
    [ "$cur" -ge "$lo" ] || [ "$cur" -le "$hi" ]
  fi
}

# The window protects PEOPLE from being interrupted. If the people who
# are here have explicitly said go ahead, there is nobody left to
# protect and waiting until 04:00 only delays it for its own sake.
if [ "$system_override" -eq 1 ]; then
  # NOT the same statement as the one below: nobody here consented, an
  # admin overrode them. Saying "everyone present allowed it" would be
  # a false account of why the machine is about to reboot.
  log "machine-wide permission is active; ignoring the window"
elif [ "$allowed_present" -eq 1 ]; then
  log "everyone logged in has allowed the reboot; ignoring the window"
elif ! in_window; then
  log "nobody logged in, but outside the reboot window ($reboot_window); waiting"
  exit 0
fi

# Cheap, and the alternative is rebooting someone who logged in during
# the handful of milliseconds since the check above. Re-scanned through
# the same function, so a login that has NOT given permission still
# blocks even when everyone who was here had.
if [ "$system_override" -eq 0 ]; then
  scan_sessions
  if [ -n "$blocking" ]; then
    log "someone logged in just now; deferring the reboot"
    exit 0
  fi
fi

if [ -e "$shutdown_scheduled" ]; then
  log "a shutdown is already scheduled"
  exit 0
fi

# A countdown here too, not a bare `systemctl reboot`. Giving permission
# is not the same as wanting the screen to go black mid-sentence, and
# `shutdown` buys the wall broadcast and a working `shutdown -c` for
# free. Shorter than the deadline's, because nobody here objects.
log "nothing is blocking the reboot; rebooting in $reboot_grace minute(s) for: $differing"
notify normal "NixOS: rebooting in $reboot_grace minute(s)" \
  "Applying a required reboot ($differing). Run 'shutdown -c' to cancel." \
  "$blocking $allowed_users"
act shutdown -r "+$reboot_grace" "NixOS: applying a required reboot ($differing)"
