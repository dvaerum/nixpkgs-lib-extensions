# The one branch a sandbox cannot reach: what the reboot policy does when
# NOBODY is logged in.
#
# Every other path has been driven with stubs or on a live host, but this
# one needs `loginctl` to genuinely report zero `Class=user` sessions --
# and on a machine someone is using it never will. Giving permission does
# not help either: that sets allowed_present, which BYPASSES the window
# by design, routing around the very branch under test.
#
# A booted VM with no autologin is the only honest way to get there.
#
# Exposed as a PACKAGE, not a check: `nix flake check` evaluates packages
# without building them, so this stays runnable on demand
# (`nix build .#no-sessions-vm`) without adding a guest boot to the gate.
{ pkgs, myLib }:
let
  scripts = import ../../lib/nixos/internal/system-auto-upgrade-script.nix { inherit pkgs; };

  # Two fake system trees standing in for booted-vs-staged. Building a
  # genuine kernel delta inside a VM would test nixpkgs' rebuild, not this
  # policy; what has never been exercised is the SESSION and WINDOW logic
  # against a real systemd-logind, and that is what the VM supplies.
  gen =
    name:
    pkgs.runCommand "fake-${name}" { } ''
      mkdir -p $out/bin
      for c in kernel initrd kernel-modules; do echo "${name}-$c" > $out/$c; done
      cat > $out/bin/switch-to-configuration <<EOF
      #!/bin/sh
      echo "switch-to-configuration(${name}) \$*" >> /tmp/record
      EOF
      chmod +x $out/bin/switch-to-configuration
    '';
  booted = gen "booted";
  staged = gen "staged";
in
pkgs.testers.runNixOSTest {
  name = "nixos-upgrade-policy-no-sessions";

  # No autologin, no getty user: the point of the node is that nobody is
  # on it.
  nodes.machine = {
    environment.systemPackages = [ scripts.policy ];
    virtualisation.graphics = false;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # The precondition the whole test rests on. Assert it rather than
    # assume it -- a stray greeter or lingering manager session would
    # make everything below pass for the wrong reason.
    sessions = machine.succeed(
        "loginctl list-sessions --no-legend | awk '{print $1}' | "
        "while read -r i; do loginctl show-session $i -p Class --value; done || true"
    )
    assert "user" not in sessions.split(), f"expected no user sessions, got: {sessions!r}"

    base = (
        "nixos-upgrade-policy --dry-run "
        "--runtime-dir /tmp/rt --state-file /tmp/state "
        "--shutdown-scheduled /tmp/no-sched "
        "--booted-system ${booted} --profile ${staged} "
        "--current-system ${staged} "
    )

    # ── THE BRANCH ── nobody here, clock outside the window: decline,
    # and say why. --now 0 is 00:00 UTC, so 04:00-06:00 is closed.
    out = machine.succeed(base + "--reboot-window 04:00-06:00 --now 0 2>&1")
    assert "outside the reboot window" in out, out
    assert "rebooting" not in out, out
    machine.fail("test -e /tmp/record")

    # ... and the same call INSIDE the window goes ahead, which is what
    # proves the decline was the window's doing and not something else
    # quietly blocking it.
    machine.succeed("rm -f /tmp/rt/pending")
    out = machine.succeed(base + "--reboot-window 04:00-06:00 --now 18000 2>&1")
    assert "nothing is blocking the reboot" in out, out
    assert "DRY-RUN" in out, out

    # ... and with no window configured at all, likewise.
    machine.succeed("rm -f /tmp/rt/pending")
    out = machine.succeed(base + "--now 0 2>&1")
    assert "nothing is blocking the reboot" in out, out

    # A machine with nobody on it must never take the reminder path --
    # there is no one to remind.
    assert "someone is logged in" not in out, out
  '';
}
