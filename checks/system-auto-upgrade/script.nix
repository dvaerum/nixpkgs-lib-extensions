# Sandboxed behaviour test for scripts/nixos-upgrade-policy.sh and
# scripts/nixos-upgrade-status.sh, run by `nix flake check`. Stub
# `loginctl`/`systemctl`/`systemd-run`/`wall`/`shutdown` binaries record
# their invocations, so every branch of the reboot policy -- including
# the forced one -- is exercised without a VM, a guest, or an actual
# reboot. Same arrangement as checks/auto-upgrade/script.nix.
{ pkgs }:
let
  # Sessions come from $SESSIONS as "id:class:state:name:uid" words, so a
  # test can describe exactly who is logged in.
  stub-systemd = pkgs.runCommand "stub-systemd" { } ''
    mkdir -p $out/bin

    cat > $out/bin/loginctl <<'EOF'
    #!/bin/sh
    case "$1" in
      list-sessions)
        for s in ''${SESSIONS:-}; do echo "''${s%%:*}"; done
        ;;
      show-session)
        for s in ''${SESSIONS:-}; do
          id=$(echo "$s" | cut -d: -f1)
          [ "$id" = "$2" ] || continue
          echo "Class=$(echo "$s" | cut -d: -f2)"
          echo "State=$(echo "$s" | cut -d: -f3)"
          echo "Name=$(echo "$s" | cut -d: -f4)"
          echo "User=$(echo "$s" | cut -d: -f5)"
        done
        ;;
    esac
    EOF

    cat > $out/bin/systemctl <<'EOF'
    #!/bin/sh
    case "$*" in
      *--property=Result*)                    echo "''${UPGRADE_RESULT:-success}" ;;
      *--property=ExecMainExitTimestampMonotonic*) echo "''${UPGRADE_STAMP:-0}" ;;
      *is-active*nixos-upgrade-policy-wake*)  exit "''${WAKE_ACTIVE:-1}" ;;
      *) echo "systemctl $*" >> "$RECORD" ;;
    esac
    EOF

    for b in systemd-run wall shutdown notify-send; do
      cat > $out/bin/$b <<EOF
    #!/bin/sh
    echo "$b \$*" >> "\$RECORD"
    EOF
    done

    chmod +x $out/bin/*
  '';

  scripts = import ../../lib/nixos/internal/system-auto-upgrade-script.nix {
    inherit pkgs;
    systemdPackage = stub-systemd;
    extraInputs = [ stub-systemd ];
  };
in
pkgs.runCommand "nixos-upgrade-policy-script-test" { } ''
  set -x
  export RECORD=$TMPDIR/record
  policy=${scripts.policy}/bin/nixos-upgrade-policy
  status=${scripts.status}/bin/nixos-upgrade-status

  # Two fake system trees. `gen1` is what we booted, `gen2` what
  # nixos-upgrade staged; pointing the flags at one or the other is how
  # each branch below is selected.
  mkdir -p $TMPDIR/gen1/bin $TMPDIR/gen2/bin $TMPDIR/store
  for g in gen1 gen2; do
    for c in kernel initrd kernel-modules; do
      echo "$g-$c" > $TMPDIR/store/$g-$c
      ln -s $TMPDIR/store/$g-$c $TMPDIR/$g/$c
    done
    cat > $TMPDIR/$g/bin/switch-to-configuration <<EOF
  #!/bin/sh
  echo "switch-to-configuration($g) \$*" >> "\$RECORD"
  EOF
    chmod +x $TMPDIR/$g/bin/switch-to-configuration
  done
  # a same-kernel generation: only kernel-modules moved (the nvidia/ZFS
  # case that makes kernel-modules the noisy trigger)
  mkdir -p $TMPDIR/gen3/bin
  ln -s $TMPDIR/store/gen1-kernel  $TMPDIR/gen3/kernel
  ln -s $TMPDIR/store/gen1-initrd  $TMPDIR/gen3/initrd
  echo gen3-mods > $TMPDIR/store/gen3-kernel-modules
  ln -s $TMPDIR/store/gen3-kernel-modules $TMPDIR/gen3/kernel-modules
  cat > $TMPDIR/gen3/bin/switch-to-configuration <<'EOF'
  #!/bin/sh
  echo "switch-to-configuration(gen3) $*" >> "$RECORD"
  EOF
  chmod +x $TMPDIR/gen3/bin/switch-to-configuration

  rt=$TMPDIR/run
  state=$TMPDIR/state/last-run
  base=(--runtime-dir "$rt" --state-file "$state" --shutdown-scheduled "$TMPDIR/no-shutdown")

  reset() { : > "$RECORD"; }

  # ── argument handling ──
  rc=0; "$policy" --bogus || rc=$?
  [ "$rc" -eq 64 ]
  rc=0; msg=$("$policy" --profile 2>&1) || rc=$?
  [ "$rc" -eq 64 ]
  echo "$msg" | grep -q "usage:"

  # ── booted == staged, but not yet activated -> adopt it ──
  reset
  SESSIONS="" "$policy" "''${base[@]}" \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen1
  ! grep -q "switch-to-configuration" "$RECORD"
  # current points at an OLDER generation than the profile: activate
  reset
  ln -sfn $TMPDIR/gen1 $TMPDIR/current
  SESSIONS="" "$policy" "''${base[@]}" \
    --booted-system $TMPDIR/gen2 --current-system $TMPDIR/current --profile $TMPDIR/gen2
  grep -q "switch-to-configuration(gen2) switch" "$RECORD"
  ! grep -q "reboot" "$RECORD"

  # ... and a second consecutive poll must NOT re-activate
  reset
  ln -sfn $TMPDIR/gen2 $TMPDIR/current
  SESSIONS="" "$policy" "''${base[@]}" \
    --booted-system $TMPDIR/gen2 --current-system $TMPDIR/current --profile $TMPDIR/gen2
  [ ! -s "$RECORD" ]

  # ── rebootTriggers actually selects what is compared ──
  # gen3 differs from gen1 ONLY in kernel-modules
  reset
  SESSIONS="" "$policy" "''${base[@]}" --reboot-triggers kernel,initrd \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen3
  grep -q "switch-to-configuration(gen3) switch" "$RECORD"   # not pending -> adopted
  [ ! -e "$rt/pending" ]

  reset
  res=$(SESSIONS="" "$policy" "''${base[@]}" --reboot-window 23:00-23:01 --now 0 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen3 2>&1)
  echo "$res" | grep -q "reboot needed (changed: kernel-modules)"
  ! grep -q "switch-to-configuration" "$RECORD"
  rm -f "$rt/pending"

  # ── reboot needed, nobody here, no window -> reboot ──
  reset
  SESSIONS="" "$policy" "''${base[@]}" \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "systemctl reboot" "$RECORD"
  ! grep -q "switch-to-configuration" "$RECORD"
  rm -f "$rt/pending"

  # ── ... outside the window -> wait ──
  reset
  # --now 0 is 00:00 UTC; the sandbox has no TZ, so this is stable
  SESSIONS="" "$policy" "''${base[@]}" --reboot-window 04:00-06:00 --now 0 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  ! grep -q "reboot" "$RECORD"
  grep -q "since=0" "$rt/pending"
  # ... and inside it, the same call reboots
  reset
  SESSIONS="" "$policy" "''${base[@]}" --reboot-window 04:00-06:00 --now 18000 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "systemctl reboot" "$RECORD"
  rm -f "$rt/pending"

  # ── who counts as logged in ──
  # a LINGERING user's manager session alone must not block
  reset
  SESSIONS="c1:manager:active:dennis:1000" "$policy" "''${base[@]}" \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "systemctl reboot" "$RECORD"
  rm -f "$rt/pending"

  # neither does a background session -- which is what our OWN
  # systemd-run --machine creates, so notifying must not make the
  # machine believe someone showed up
  reset
  SESSIONS="c1:background:active:dennis:1000" "$policy" "''${base[@]}" \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "systemctl reboot" "$RECORD"
  rm -f "$rt/pending"

  # nor a session on its way out
  reset
  SESSIONS="c1:user:closing:dennis:1000" "$policy" "''${base[@]}" \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "systemctl reboot" "$RECORD"
  rm -f "$rt/pending"

  # ... but a real login alongside that same lingering manager DOES
  reset
  SESSIONS="c1:manager:active:dennis:1000 5:user:active:dennis:1000" \
    "$policy" "''${base[@]}" --now 100 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  ! grep -q "reboot" "$RECORD"
  grep -q "wall " "$RECORD"          # no bus in the sandbox -> wall
  grep -q "changed=kernel,initrd,kernel-modules" "$rt/pending"

  # ── notification cadence ──
  # a second run inside notifyIntervalSec is silent
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" --now 200 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  [ ! -s "$RECORD" ]
  # ... and after it, it nags again
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" --now 90000 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "wall " "$RECORD"

  # ── desktop delivery when the user's bus is reachable ──
  mkdir -p $TMPDIR/user/1000
  touch $TMPDIR/user/1000/bus
  rm -f "$rt/pending"
  reset
  # the script looks under /run/user/<uid>; no bus exists in the sandbox,
  # so this asserts the wall FALLBACK rather than the bus path
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" --desktop-notify --now 300 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "wall " "$RECORD"
  rm -f "$rt/pending"

  # ── the deadline is OFF by default ──
  reset
  for t in 400 1000000 100000000; do
    SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" --now "$t" \
      --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  done
  ! grep -q "shutdown" "$RECORD"
  rm -f "$rt/pending"

  # ── the reminder ladder, walked with a fake clock ──
  # pending starts at 0, deadline at +48h
  deadline=(--force-after 172800 --now)
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" "''${deadline[@]}" 0 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "automatically in ~48h" "$RECORD"
  # 30h remaining -> still the daily rung, so 1h later is silent
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" "''${deadline[@]}" 68400 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  [ ! -s "$RECORD" ]
  # 20h remaining -> the 6h rung; last notify was at 0, so it fires
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" "''${deadline[@]}" 100800 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "automatically in ~20h" "$RECORD"
  # 40 min remaining -> critical, and an exact wakeup is armed because
  # the next rung (15 min) lands before a 2h poll
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" "''${deadline[@]}" 170400 \
    --poll-interval 7200 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "systemd-run --on-active=900" "$RECORD"
  # ... at the default 15-minute poll, nothing needs arming
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" "''${deadline[@]}" 171300 \
    --poll-interval 900 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  ! grep -q -- "--on-active" "$RECORD"
  # ... and with polling disabled entirely, the armed wakeup is the ONLY
  # thing that would ever fire, so it is armed regardless of distance
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" "''${deadline[@]}" 172000 \
    --poll-interval 0 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q -- "--on-active" "$RECORD"

  # ── past the deadline -> shutdown -r +5, once, window ignored ──
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" "''${base[@]}" "''${deadline[@]}" 172800 \
    --reboot-window 04:00-04:01 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "shutdown -r +5" "$RECORD"
  # a second poll with systemd's marker present must not stack another
  touch $TMPDIR/scheduled
  reset
  SESSIONS="5:user:active:dennis:1000" "$policy" \
    --runtime-dir "$rt" --state-file "$state" --shutdown-scheduled "$TMPDIR/scheduled" \
    "''${deadline[@]}" 173000 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  ! grep -q "shutdown" "$RECORD"
  # ... and it fires with NOBODY logged in too: the deadline is the
  # backstop for the unattended host, not only the occupied one
  reset
  SESSIONS="" "$policy" "''${base[@]}" "''${deadline[@]}" 172800 --reboot-window 04:00-04:01 \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "shutdown -r +5" "$RECORD"

  # ── --dry-run logs destructive actions instead of doing them ──
  reset
  res=$(SESSIONS="" "$policy" "''${base[@]}" --dry-run \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2 2>&1)
  echo "$res" | grep -q "DRY-RUN: would run: systemctl reboot"
  ! grep -q "systemctl reboot" "$RECORD"
  rm -f "$rt/pending"

  # ── the result is recorded ONCE per engine run, not once per poll ──
  reset
  UPGRADE_STAMP=111 SESSIONS="" "$policy" "''${base[@]}" --dry-run --now 500 \
    --on-result ${pkgs.writeShellScript "hook" ''echo "HOOK result=$RESULT pending=$REBOOT_PENDING" >> "$RECORD"''} \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "HOOK result=success pending=1" "$RECORD"
  grep -q "result=success" "$state"
  reset
  UPGRADE_STAMP=111 SESSIONS="" "$policy" "''${base[@]}" --dry-run --now 600 \
    --on-result ${pkgs.writeShellScript "hook2" ''echo "HOOK again" >> "$RECORD"''} \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  ! grep -q "HOOK" "$RECORD"
  # a NEW engine run is a new result
  reset
  UPGRADE_STAMP=222 UPGRADE_RESULT=failed SESSIONS="" "$policy" "''${base[@]}" --dry-run --now 700 \
    --on-result ${pkgs.writeShellScript "hook3" ''echo "HOOK result=$RESULT" >> "$RECORD"''} \
    --booted-system $TMPDIR/gen1 --current-system $TMPDIR/gen1 --profile $TMPDIR/gen2
  grep -q "HOOK result=failed" "$RECORD"

  # ── the status command ──
  # pending + a recorded failure
  res=$("$status" --pending-file "$rt/pending" --state-file "$state" --now 3600) || rc=$?
  echo "$res" | grep -q "FAILED"
  echo "$res" | grep -q "reboot required"
  rc=0; "$status" --only-news --pending-file "$rt/pending" --state-file "$state" || rc=$?
  [ "$rc" -eq 1 ]
  # clean: --only-news says nothing at all
  echo "result=success" > $TMPDIR/clean-state
  echo "time=now" >> $TMPDIR/clean-state
  [ -z "$("$status" --only-news --pending-file "$TMPDIR/absent" --state-file "$TMPDIR/clean-state")" ]
  "$status" --pending-file "$TMPDIR/absent" --state-file "$TMPDIR/clean-state" | grep -q "no reboot pending"
  # never run is not a failure
  rc=0; "$status" --only-news --pending-file "$TMPDIR/absent" --state-file "$TMPDIR/absent" || rc=$?
  [ "$rc" -eq 0 ]

  touch $out
''
