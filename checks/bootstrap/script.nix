# Sandboxed behavior test for scripts/home-manager-bootstrap.sh, run by
# `nix flake check`. A stub `home-manager` binary records its invocations,
# so the whole flow (argument parsing, user filtering, first-login stamp,
# re-activation) is exercised without a VM or network access.
#
# The real end-to-end regression (reboot across a system rebuild must not
# revert a manually-switched home) is checks/bootstrap/login-vm.nix --
# this file only covers the script's own argument/stamp logic in isolation.
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
  rc=0; "$bootstrap" --user-attrs alice=alice@h || rc=$?
  [ "$rc" -eq 64 ]

  # a missing VALUE after --flake-ref/--hostname -> exit 64 with the
  # usage message, not a nounset crash on "$2"
  rc=0; msg=$("$bootstrap" --flake-ref 2>&1) || rc=$?
  [ "$rc" -eq 64 ]
  echo "$msg" | grep -q "usage:"
  rc=0; msg=$("$bootstrap" --hostname 2>&1) || rc=$?
  [ "$rc" -eq 64 ]
  echo "$msg" | grep -q "usage:"

  # user not in the list -> exit 0 and home-manager is NOT called
  "$bootstrap" --flake-ref /f --hostname h --user-attrs bob=bob@h carol=carol@h
  [ ! -e "$RECORD" ]

  # a FAILING switch propagates the error and does NOT write the stamp,
  # so the next login retries
  rc=0; HM_STUB_FAIL=1 "$bootstrap" --flake-ref /f --hostname h --user-attrs alice=alice@h || rc=$?
  [ "$rc" -ne 0 ]
  [ ! -e "$HOME/.local/state/home-manager-bootstrap.stamp" ]

  # listed user -> home-manager switch is called for <user>@<host>
  "$bootstrap" --flake-ref /f --hostname h --user-attrs alice=alice@h bob=bob@h
  grep -q "switch --flake /f#alice@h" "$RECORD"
  [ "$(wc -l < "$RECORD")" -eq 1 ]
  # ... and the stamp still records the activation PARAMETERS (useful for
  # --reactivate on-target-change below), even though the DEFAULT check
  # does not compare them -- see the next block
  stamp="$HOME/.local/state/home-manager-bootstrap.stamp"
  [ "$(cat "$stamp")" = "/f#alice@h" ]

  # second login: the stamp exists -> NOT called again
  "$bootstrap" --flake-ref /f --hostname h --user-attrs alice=alice@h bob=bob@h
  [ "$(wc -l < "$RECORD")" -eq 1 ]

  # ── default is PRESENCE-only: "first login" means ONCE EVER for this
  # user, full stop -- a DIFFERENT flake-ref/attr in the stamp is simply
  # ignored. Deliberately NOT content-comparison: `inputs.self` gets a
  # brand-new store path on every `nixos-rebuild switch`, even for a
  # change completely unrelated to home.nix, so comparing stamp content
  # made a routine system rebuild (or this library's own
  # systemAutoUpgradeModule, unattended) look identical to "the user
  # needs re-bootstrapping" -- silently reverting anything the user had
  # since switched to by hand. See docs/getting-started.md.
  printf '%s' "/old-ref#alice@h" > "$stamp"
  "$bootstrap" --flake-ref /f --hostname h --user-attrs alice=alice@h bob=bob@h
  [ "$(wc -l < "$RECORD")" -eq 1 ]
  [ "$(cat "$stamp")" = "/old-ref#alice@h" ]

  # an EMPTY stamp (e.g. left by a much older version of this script that
  # only ever touched the file, no content) counts as present too --
  # presence is the only thing the default check looks at
  : > "$stamp"
  "$bootstrap" --flake-ref /f --hostname h --user-attrs alice=alice@h bob=bob@h
  [ "$(wc -l < "$RECORD")" -eq 1 ]

  # ── --reactivate on-target-change opts back into the OLD
  # content-comparing behavior, for whoever genuinely wants "resync to
  # whatever the latest build declares" as a standing policy. Honest
  # about what it actually does: it reacts to ANY change in the resolved
  # flake-ref/attr STRING, not specifically a deliberate migration -- a
  # routine rebuild looks identical to a real migration to this check,
  # exactly as it did when this was the only behavior.
  printf '%s' "/old-ref#alice@h" > "$stamp"
  "$bootstrap" --flake-ref /f --hostname h --reactivate on-target-change --user-attrs alice=alice@h bob=bob@h
  [ "$(wc -l < "$RECORD")" -eq 2 ]
  [ "$(cat "$stamp")" = "/f#alice@h" ]

  # ... and once the stamp matches again, it goes back to skipping
  "$bootstrap" --flake-ref /f --hostname h --reactivate on-target-change --user-attrs alice=alice@h bob=bob@h
  [ "$(wc -l < "$RECORD")" -eq 2 ]

  # --reactivate every-login ignores the stamp entirely -> called again,
  # regardless of the mode used above
  "$bootstrap" --flake-ref /f --hostname h --reactivate every-login --user-attrs alice=alice@h bob=bob@h
  [ "$(wc -l < "$RECORD")" -eq 3 ]

  # an unknown --reactivate value -> usage error, not a silent fall-through
  rc=0; msg=$("$bootstrap" --flake-ref /f --hostname h --reactivate bogus --user-attrs alice=alice@h 2>&1) || rc=$?
  [ "$rc" -eq 64 ]
  echo "$msg" | grep -q "must be one of"
  # ... and a missing VALUE after --reactivate is the same usage error as
  # --flake-ref/--hostname's, not a nounset crash on "$2"
  rc=0; msg=$("$bootstrap" --flake-ref /f --hostname h --reactivate 2>&1) || rc=$?
  [ "$rc" -eq 64 ]
  echo "$msg" | grep -q "usage:"

  touch $out
''
