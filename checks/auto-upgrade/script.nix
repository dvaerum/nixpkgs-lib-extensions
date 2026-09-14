# Sandboxed behaviour test for scripts/home-manager-auto-upgrade.sh, run
# by `nix flake check`. Stub `home-manager`/`nix`/`notify-send` binaries
# record their invocations, so credential resolution, live target
# re-resolution, the state file and the notification transitions are all
# exercised without a VM, a network, or a real profile -- the same
# arrangement as checks/bootstrap/script.nix.
{ pkgs }:
let
  stub-home-manager = pkgs.writeShellScriptBin "home-manager" ''
    if [ -n "''${HM_STUB_FAIL:-}" ]; then
      echo "simulated switch failure" >&2
      exit 1
    fi
    echo "$@" >> "$RECORD"
  '';

  # `nix eval` decides whether the LIVE flake exports <user>@<host>;
  # `nix-env` is the generation prune. Both are answered from the
  # environment so a test can pick the branch it wants.
  stub-nix = pkgs.runCommand "stub-nix" { } ''
    mkdir -p $out/bin
    cat > $out/bin/nix <<'EOF'
    #!/bin/sh
    # only `nix eval ... --json` is used by the script
    echo "''${NIX_STUB_HOST_ATTR:-false}"
    EOF
    cat > $out/bin/nix-env <<'EOF'
    #!/bin/sh
    echo "nix-env $*" >> "$PRUNE_RECORD"
    EOF
    chmod +x $out/bin/nix $out/bin/nix-env
  '';

  stub-notify = pkgs.writeShellScriptBin "notify-send" ''
    echo "$@" >> "$NOTIFY_RECORD"
  '';

  scripts = import ../../lib/nixos/internal/auto-upgrade-script.nix {
    inherit pkgs;
    homeManager = stub-home-manager;
    nixPackage = stub-nix;
    extraInputs = [ stub-notify ];
  };
in
pkgs.runCommand "home-manager-auto-upgrade-script-test" { } ''
  set -x
  export HOME=$TMPDIR/home
  export XDG_CONFIG_HOME=$HOME/.config
  export RECORD=$TMPDIR/record
  export PRUNE_RECORD=$TMPDIR/prune
  export NOTIFY_RECORD=$TMPDIR/notify
  # a reachable session bus is a precondition for notifying; the stub
  # never touches it, but the script's own guard must be satisfied
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null
  mkdir -p "$HOME"
  state=$TMPDIR/state
  up=${scripts.upgrade}/bin/hm-auto-upgrade
  status=${scripts.status}/bin/hm-auto-upgrade-status

  # ── argument handling ──
  rc=0; "$up" --bogus || rc=$?
  [ "$rc" -eq 64 ]
  # missing required arguments
  rc=0; "$up" --flake-ref /f || rc=$?
  [ "$rc" -eq 64 ]
  # a missing VALUE is a usage error, not a nounset crash on "$2"
  rc=0; msg=$("$up" --flake-ref 2>&1) || rc=$?
  [ "$rc" -eq 64 ]
  echo "$msg" | grep -q "usage:"

  base=(--flake-ref /live --username alice --state-file "$state")

  # ── live target re-resolution ──
  # the flake does NOT export <user>@<host> -> the bare <user> is used
  NIX_STUB_HOST_ATTR=false "$up" "''${base[@]}"
  grep -q -- "--flake /live#alice " "$RECORD"
  grep -q "status=ok" "$state"
  grep -q "target=alice" "$state"

  # ... and when it DOES, the host-specific attribute wins. Decided per
  # run, not cached: a hosts/<host>/ directory added since the last
  # rebuild must take effect without one.
  : > "$RECORD"
  NIX_STUB_HOST_ATTR=true "$up" "''${base[@]}"
  grep -q -- "--flake /live#alice@$(uname -n) " "$RECORD"

  # ── the tracked ref is never served from nix's cache ──
  # a git+https ref with no rev is cached for tarball-ttl (default 1h),
  # so without this a run started soon after a push applies the OLDER
  # revision and still reports success
  captured=$("$up" "''${base[@]}" --pre-command ${pkgs.writeShellScript "show-ttl" ''echo "TTL=[$NIX_CONFIG]"''} 2>&1)
  echo "$captured" | grep -q "tarball-ttl = 0"

  # ── generation pruning ──
  : > "$PRUNE_RECORD"
  "$up" "''${base[@]}" --keep-generations 7
  grep -q -- "--delete-generations +7" "$PRUNE_RECORD"
  # 0 means never prune
  : > "$PRUNE_RECORD"
  "$up" "''${base[@]}" --keep-generations 0
  [ ! -s "$PRUNE_RECORD" ]

  # ── credentials: the conventional RUNTIME path, no nix involved ──
  mkdir -p "$XDG_CONFIG_HOME/hm-auto-upgrade"
  conv="$XDG_CONFIG_HOME/hm-auto-upgrade/git-credentials"
  echo "https://u:tok@example.org" > "$conv"
  chmod 600 "$conv"
  # GIT_CONFIG_VALUE_1 carries the store helper; prove the file we
  # dropped in with no rebuild is the one that gets used
  captured=$("$up" "''${base[@]}" --pre-command ${pkgs.writeShellScript "show-cred" ''echo "CRED=''${GIT_CONFIG_VALUE_1:-none}"''} 2>&1)
  echo "$captured" | grep -q "CRED=store --file=$conv"

  # an EXPLICIT path beats the conventional one
  other=$TMPDIR/explicit-credentials
  echo "https://u:other@example.org" > "$other"
  chmod 600 "$other"
  captured=$("$up" "''${base[@]}" --git-credentials "$other" --pre-command ${pkgs.writeShellScript "show-cred2" ''echo "CRED=''${GIT_CONFIG_VALUE_1:-none}"''} 2>&1)
  echo "$captured" | grep -q "CRED=store --file=$other"

  # with NO credentials file at all the chain is still narrowed to
  # store-only: GIT_TERMINAL_PROMPT=0 does not govern a credential
  # HELPER, so an ambient oauth helper would otherwise wait on a browser
  # forever in an unattended run
  rm -f "$conv"
  captured=$("$up" "''${base[@]}" --pre-command ${pkgs.writeShellScript "show-cred3" ''echo "CRED=''${GIT_CONFIG_VALUE_1:-none}/PROMPT=$GIT_TERMINAL_PROMPT"''} 2>&1)
  echo "$captured" | grep -q "CRED=store/PROMPT=0"
  echo "https://u:tok@example.org" > "$conv"; chmod 600 "$conv"

  # ── a loosely-permissioned credential file is REFUSED, not used ──
  chmod 644 "$other"
  rc=0; msg=$("$up" "''${base[@]}" --git-credentials "$other" 2>&1) || rc=$?
  [ "$rc" -ne 0 ]
  echo "$msg" | grep -q "refusing to use it"
  echo "$msg" | grep -q "chmod 600 $other"
  chmod 600 "$other"

  # ── an SSH ref with no usable credential fails FAST and says how ──
  rm -f "$XDG_CONFIG_HOME/hm-auto-upgrade/ssh-key"
  unset SSH_AUTH_SOCK
  rc=0; msg=$("$up" --flake-ref "git+ssh://git@example.org/cfg" \
        --username alice --state-file "$state" 2>&1) || rc=$?
  [ "$rc" -ne 0 ]
  echo "$msg" | grep -q "needs SSH credentials"
  echo "$msg" | grep -q "sshKeyPath"
  echo "$msg" | grep -q "sshAuthSock"
  # the failure is recorded and notified like any other
  grep -q "status=fail" "$state"

  # ... and a conventional ssh key alone satisfies it. Captured, not
  # piped into `grep -q`: grep exits at the first match and the script
  # then dies on SIGPIPE under `set -o pipefail`.
  key="$XDG_CONFIG_HOME/hm-auto-upgrade/ssh-key"
  echo fake-key > "$key"; chmod 600 "$key"
  captured=$("$up" --flake-ref "git+ssh://git@example.org/cfg" --username alice \
    --state-file "$state" --pre-command ${pkgs.writeShellScript "show-ssh" ''echo "SSH=$GIT_SSH_COMMAND"''} 2>&1)
  echo "$captured" | grep -q "IdentitiesOnly=yes"
  echo "$captured" | grep -q -- "-i $key"
  rm -f "$key"

  # ── notification transitions ──
  # failure always notifies
  : > "$NOTIFY_RECORD"
  rc=0; HM_STUB_FAIL=1 "$up" "''${base[@]}" --desktop-notify || rc=$?
  [ "$rc" -ne 0 ]
  grep -q "failed" "$NOTIFY_RECORD"
  grep -q "status=fail" "$state"

  # the NEXT success ends a failing streak -> a recovery notification
  : > "$NOTIFY_RECORD"
  "$up" "''${base[@]}" --desktop-notify
  grep -q "recovered" "$NOTIFY_RECORD"

  # ... but a further success is silent: a daily "still fine" popup is
  # how a real failure gets dismissed unread
  : > "$NOTIFY_RECORD"
  "$up" "''${base[@]}" --desktop-notify
  [ ! -s "$NOTIFY_RECORD" ]

  # without --desktop-notify nothing is sent even on failure
  : > "$NOTIFY_RECORD"
  rc=0; HM_STUB_FAIL=1 "$up" "''${base[@]}" || rc=$?
  [ ! -s "$NOTIFY_RECORD" ]

  # ── the post-run hook sees the outcome ──
  captured=$("$up" "''${base[@]}" --on-result ${pkgs.writeShellScript "show-result" ''echo "HOOK result=$RESULT target=$TARGET"''} 2>&1)
  echo "$captured" | grep -q "HOOK result=0 target=alice"

  # ── a hook can report its OWN health back through the state file ──
  # An onResult hook that pushes notifications cannot tell anyone when
  # the pushing itself is broken -- the broken channel is the one it
  # would use. `warn=` is the way back: the status line already runs at
  # every shell start and does not depend on notifications working.
  : > "$state"
  printf 'status=ok\ntimestamp=T\ntarget=alice\nwarn=alert delivery failed\n' > "$state"
  "$status" "$state" | grep -q "alert delivery failed"
  # a warning is news even on an otherwise SUCCESSFUL run -- that is the
  # whole point, the run worked and the reporting did not
  msg=$("$status" --only-failures "$state" 2>&1) || rc=$?
  echo "$msg" | grep -q "alert delivery failed"
  # ... but it is not itself a failure: exit stays 0
  rc=0; "$status" --only-failures "$state" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
  # no warn field -> nothing extra printed
  printf 'status=ok\ntimestamp=T\ntarget=alice\n' > "$state"
  [ -z "$("$status" --only-failures "$state")" ]

  # ── the hook runs in its OWN process ──
  # It used to be SOURCED, which has two teeth: a hook that calls `exit`
  # takes the whole upgrade script down with it, and a hook's variables
  # share the script's namespace -- the real consumer already declared
  # `previous_status`, which is the exact name the script uses
  # internally. Both are silent until the day they are not.
  captured=$("$up" "''${base[@]}" --on-result ${pkgs.writeShellScript "exiting-hook" ''
    echo "HOOK ran"
    exit 0
  ''} 2>&1)
  echo "$captured" | grep -q "HOOK ran"
  # the script must have carried on past the hook and written its state
  grep -q "status=ok" "$state"

  # a hook cannot clobber the script's own variables
  captured=$("$up" "''${base[@]}" --on-result ${pkgs.writeShellScript "clobbering-hook" ''
    previous_status=CLOBBERED
    echo "HOOK previous_status=$previous_status"
  ''} 2>&1)
  echo "$captured" | grep -q "HOOK previous_status=CLOBBERED"
  grep -q "status=ok" "$state"

  # ── the hook is TOLD the transition, not left to derive it ──
  # Without this a consumer has to sed `previous_status=` out of the
  # state file -- coupling its code to a library-internal format, and
  # forcing it to re-implement a decision the library already made.
  : > "$state"
  HM_STUB_FAIL=1 "$up" "''${base[@]}" --on-result ${pkgs.writeShellScript "t1" ''echo "T=$TRANSITION P=$PREVIOUS_STATUS"''} >/dev/null 2>&1 || true
  captured=$("$up" "''${base[@]}" --on-result ${pkgs.writeShellScript "t2" ''echo "T=$TRANSITION P=$PREVIOUS_STATUS"''} 2>&1)
  echo "$captured" | grep -q "T=recover P=fail"
  # a further success is steady, not another recovery
  captured=$("$up" "''${base[@]}" --on-result ${pkgs.writeShellScript "t3" ''echo "T=$TRANSITION"''} 2>&1)
  echo "$captured" | grep -q "T=steady"
  # and a failure says so
  rc=0; captured=$(HM_STUB_FAIL=1 "$up" "''${base[@]}" --on-result ${pkgs.writeShellScript "t4" ''echo "T=$TRANSITION"''} 2>&1) || rc=$?
  echo "$captured" | grep -q "T=fail"

  # ── the status line: silent on success, loud on failure ──
  "$up" "''${base[@]}"
  [ -z "$("$status" --only-failures "$state")" ]
  "$status" "$state" | grep -q "last succeeded"

  rc=0; HM_STUB_FAIL=1 "$up" "''${base[@]}" || rc=$?
  rc=0; msg=$("$status" --only-failures "$state" 2>&1) || rc=$?
  [ "$rc" -eq 1 ]
  echo "$msg" | grep -q "FAILED"
  # never-run is not a failure
  rc=0; "$status" --only-failures "$TMPDIR/absent" || rc=$?
  [ "$rc" -eq 0 ]

  touch $out
''
