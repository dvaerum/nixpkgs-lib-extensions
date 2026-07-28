# Sandboxed behavior test for scripts/home-manager-bootstrap.sh, run by
# `nix flake check`. A stub `home-manager` binary records its invocations,
# so the whole flow (argument parsing, user filtering, first-login stamp,
# re-activation) is exercised without a VM or network access.
{ pkgs }:
let
  stub-home-manager = pkgs.writeShellScriptBin "home-manager" ''
    if [ -n "''${HM_STUB_FAIL:-}" ]; then
      echo "simulated switch failure" >&2
      exit 1
    fi
    echo "$@" >> "$RECORD"
  '';

  # Exactly the wrapper used in production, with the stub swapped in.
  script = import ../../lib/nixos/internal/bootstrap-script.nix {
    inherit pkgs;
    homeManager = stub-home-manager;
  };
in
pkgs.runCommand "home-manager-bootstrap-script-test" { } ''
  set -x
  export USER=alice
  export HOME=$TMPDIR/home
  export RECORD=$TMPDIR/record
  mkdir -p "$HOME"
  bootstrap=${script}/bin/home-manager-bootstrap

  # unknown argument -> exit 64
  rc=0; "$bootstrap" --bogus || rc=$?
  [ "$rc" -eq 64 ]

  # missing required arguments -> exit 64
  rc=0; "$bootstrap" --users alice || rc=$?
  [ "$rc" -eq 64 ]

  # user not in the list -> exit 0 and home-manager is NOT called
  "$bootstrap" --flake-ref /f --hostname h --users bob carol
  [ ! -e "$RECORD" ]

  # a FAILING switch propagates the error and does NOT write the stamp,
  # so the next login retries
  rc=0; HM_STUB_FAIL=1 "$bootstrap" --flake-ref /f --hostname h --users alice || rc=$?
  [ "$rc" -ne 0 ]
  [ ! -e "$HOME/.local/state/home-manager-bootstrap.stamp" ]

  # listed user -> home-manager switch is called for <user>@<host>
  "$bootstrap" --flake-ref /f --hostname h --users alice bob
  grep -q "switch --flake /f#alice@h" "$RECORD"
  [ "$(wc -l < "$RECORD")" -eq 1 ]

  # second login: stamp exists -> NOT called again
  "$bootstrap" --flake-ref /f --hostname h --users alice bob
  [ "$(wc -l < "$RECORD")" -eq 1 ]

  # --reactivate-every-login ignores the stamp -> called again
  "$bootstrap" --flake-ref /f --hostname h --reactivate-every-login --users alice bob
  [ "$(wc -l < "$RECORD")" -eq 2 ]

  touch $out
''
