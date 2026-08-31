# Behavior tests for lib.systemd.{detachedRun,interceptingWrapper}, run by
# `nix flake check`. No real systemd --user session needed: `systemd-run`/
# `journalctl`/`systemctl` are stubbed (same sed-substitution technique
# checks/zfs-key-file.nix uses for dmidecode) rather than exercised for
# real, since a build sandbox has no live user session to run them against.
#
# The stub systemd-run runs the given command SYNCHRONOUSLY (real
# systemd-run detaches and returns immediately) and records its exit
# status to a per-unit state file; the stub systemctl reports that unit as
# already-inactive on the very first `is-active` poll (true by construction,
# since the stub already finished by the time anything asks) and answers
# `show --property=Result` from that recorded state. This tests the actual
# generated scripts, not a hand-written copy of their logic.
{ pkgs, myLib }:
let
  lib = pkgs.lib;

  # Any argument starting with "--" is a systemd-run/systemctl FLAG to the
  # stub; the first non-"--" argument starts the real command being run
  # (systemd-run) or is the unit name (systemctl) -- true regardless of how
  # many --setenv=/--property= flags precede it, so the stub never needs to
  # know the exact flag set detachedRun happens to pass.
  systemdRunStub = pkgs.writeShellScript "systemd-run-stub" ''
    unit=""
    declare -a rest=()
    capture=0
    for arg in "$@"; do
      if [ "$capture" = 1 ]; then
        rest+=("$arg")
        continue
      fi
      case "$arg" in
        --unit=*) unit="''${arg#--unit=}" ;;
        --*) : ;;
        *)
          capture=1
          rest+=("$arg")
          ;;
      esac
    done
    echo "$@" > "$STUB_STATE_DIR/$unit.invocation"
    "''${rest[@]}" > "$STUB_STATE_DIR/$unit.output" 2>&1
    code=$?
    if [ "$code" -eq 0 ]; then
      echo success > "$STUB_STATE_DIR/$unit.result"
    else
      echo failed > "$STUB_STATE_DIR/$unit.result"
    fi
    exit 0
  '';

  # Stands in for `journalctl -f`, run in the background and killed once
  # the (already-finished, per the stub above) unit stops -- just needs to
  # block until killed, real journal content is not what is under test.
  journalctlStub = pkgs.writeShellScript "journalctl-stub" ''
    exec sleep 100
  '';

  systemctlStub = pkgs.writeShellScript "systemctl-stub" ''
    if [ "$1" = "--user" ] && [ "$2" = "--quiet" ] && [ "$3" = "is-active" ]; then
      # the stub systemd-run above already ran synchronously, so the unit
      # is always already inactive by the time anything polls it
      exit 1
    fi
    if [ "$1" = "--user" ] && [ "$2" = "show" ]; then
      unit="$3"
      cat "$STUB_STATE_DIR/$unit.result" 2>/dev/null || true
      exit 0
    fi
    echo "systemctl-stub: unexpected invocation: $*" >&2
    exit 1
  '';

  stubSystemd = pkgs.linkFarm "stub-systemd" {
    "bin/systemd-run" = systemdRunStub;
    "bin/journalctl" = journalctlStub;
    "bin/systemctl" = systemctlStub;
  };

  # Precise substitution, same reasoning as checks/zfs-key-file.nix's
  # dmidecode sed: only the systemd PACKAGE prefix is swapped, so every
  # `${pkgs.systemd}/bin/<tool>` call in the generated text resolves to the
  # matching stub without needing three separate substitutions.
  stubify =
    text:
    pkgs.runCommand "stubified" { } ''
      sed -e "s|${toString pkgs.systemd}|${toString stubSystemd}|g" \
        ${pkgs.writeText "text" text} > $out
    '';

  # A fake "real" command for interceptingWrapper tests: echoes a marker
  # and exits 0, or exits 1 (after echoing) when FAIL is set -- lets the
  # same fixture exercise both the success and failure paths.
  fakeReal = pkgs.writeShellScriptBin "fake-real" ''
    echo "fake-real ran: $*"
    if [ "''${FAIL:-}" = "1" ]; then
      exit 1
    fi
  '';

  runScript =
    name: script:
    {
      setup ? "",
      args ? "",
    }:
    ''
      echo "=== ${name} ==="
      work="$TMPDIR/${name}"
      mkdir -p "$work/state"
      STUB_STATE_DIR="$work/state"
      export STUB_STATE_DIR
      cat ${stubify script} > "$work/run.sh"
      rc=0
      ( cd "$work" && ${setup} bash ./run.sh ${args} > out.log 2> err.log ) || rc=$?
      echo "$rc" > "$work/exit_code"
    '';

  # The real, built wrapper: exercises interceptingWrapper's OWN generated
  # script (real=... / if shouldDetach / exec passthrough), not a
  # hand-written stand-in for it.
  wrappedFakeReal = myLib.systemd.interceptingWrapper pkgs {
    package = fakeReal;
    binary = "fake-real";
    shouldDetach = ''[ "''${1:-}" = "detach-me" ]'';
    label = "test-wrap";
  };
  wrappedScript = builtins.readFile "${wrappedFakeReal}/bin/fake-real";
in
pkgs.runCommand "systemd-wrapping-test"
  {
    nativeBuildInputs = [ pkgs.bash ];
  }
  ''
    ${runScript "detached-success" (myLib.systemd.detachedRun pkgs {
      label = "test-unit";
      command = "echo hello-from-command";
    }) { }}
    grep -q "hello-from-command" "$TMPDIR/detached-success/state/"test-unit-*.output
    [ "$(cat "$TMPDIR/detached-success/exit_code")" -eq 0 ]

    ${runScript "detached-failure" (myLib.systemd.detachedRun pkgs {
      label = "test-unit-fail";
      command = "sh -c 'echo boom >&2; exit 3'";
    }) { }}
    [ "$(cat "$TMPDIR/detached-failure/exit_code")" -eq 1 ]
    grep -q "test-unit-fail failed" "$TMPDIR/detached-failure/err.log"

    ${runScript "detached-extra-env" (myLib.systemd.detachedRun pkgs {
      label = "test-unit-env";
      command = "sh -c 'echo FOO=$FOO'";
      extraEnv = [ "FOO" ];
    }) { setup = "FOO=bar-value"; }}
    invocation="$(cat "$TMPDIR/detached-extra-env/state/"test-unit-env-*.invocation)"
    case "$invocation" in
      *"--setenv=FOO=bar-value"*) : ;;
      *) echo "extraEnv did not forward FOO: $invocation" >&2; exit 1 ;;
    esac

    ${runScript "detached-extra-properties" (myLib.systemd.detachedRun pkgs {
      label = "test-unit-props";
      command = "true";
      extraProperties = [ "RuntimeMaxSec=7200" ];
    }) { }}
    invocation="$(cat "$TMPDIR/detached-extra-properties/state/"test-unit-props-*.invocation)"
    case "$invocation" in
      *"--property=RuntimeMaxSec=7200"*) : ;;
      *) echo "extraProperties did not reach systemd-run: $invocation" >&2; exit 1 ;;
    esac

    # interceptingWrapper: shouldDetach false -- straight exec, no
    # systemd-run invocation at all (no state files created)
    ${runScript "wrapper-passthrough" wrappedScript { args = "passthrough-arg"; }}
    [ "$(cat "$TMPDIR/wrapper-passthrough/exit_code")" -eq 0 ]
    grep -q "fake-real ran: passthrough-arg" "$TMPDIR/wrapper-passthrough/out.log"
    [ -z "$(ls "$TMPDIR/wrapper-passthrough/state" 2>/dev/null)" ]

    # interceptingWrapper: shouldDetach true -- routes through the SAME
    # detachedRun mechanism tested above, wrapping the real fakeReal binary
    ${runScript "wrapper-detach" wrappedScript { args = "detach-me"; }}
    [ "$(cat "$TMPDIR/wrapper-detach/exit_code")" -eq 0 ]
    grep -q "fake-real ran: detach-me" "$TMPDIR/wrapper-detach/state/"test-wrap-*.output

    touch $out
  ''
