# Real-login VM test for the home-manager login bootstrap. A stub
# `home-manager` records its invocations, so this verifies the systemd USER
# service wiring in a real booted system -- the service fires when the
# user's session starts, the stamp prevents a re-run on the next
# user-manager instance EVEN when its content is stale (the regression this
# guards: a routine `nixos-rebuild switch` gives `inputs.self` a new store
# path regardless of whether home.nix changed, so content-comparing the
# stamp made an ordinary rebuild revert anything the user had switched to
# by hand since -- see home-manager-bootstrap-module.nix's
# loginReactivate doc comment), and loginReactivate = "every-login"
# overrides that -- without any in-VM nix evaluation (see switch-vm.nix for
# that). The opt-in content-comparing mode itself ("on-target-change") is
# exercised at the ExecStart-flag level by checks/builders/tests/bootstrap.nix
# and at the script-logic level by checks/bootstrap/script.nix -- both with
# the exact same code this test would otherwise re-prove in a second, slower
# VM boot.
{ pkgs, myLib }:
let
  system = pkgs.stdenv.hostPlatform.system;

  # The failure scenario flips the stub via a flag FILE (not an env var:
  # the systemd user service's environment is not reachable from the test
  # driver between logins).
  stub = pkgs.writeShellScriptBin "home-manager" ''
    if [ -e /tmp/hm-fail ]; then
      echo "simulated switch failure" >&2
      exit 1
    fi
    echo "$@" >> /tmp/hm-record
  '';

  # Shaped like the home-manager flake input, but delivering the stub.
  stubHomeManagerInput = {
    outPath = toString stub;
    lib.homeManagerConfiguration = _: { };
    packages.${system}.home-manager = stub;
  };

  mkNode = extraBootstrapArgs: {
    imports = [
      (myLib.homeManagerBootstrapModule (
        {
          inputs = {
            home-manager = stubHomeManagerInput;
            self.outPath = "/fake-flake";
          };
          inherit system;
          hostname = "vmhost";
          users.alice = ../example/users/alice;
          loginHomes = [ "alice" ];
        }
        // extraBootstrapArgs
      ))
    ];
    users.users.alice.isNormalUser = true;
    # log alice in at boot; her systemd user instance starts the bootstrap
    services.getty.autologinUser = "alice";
  };
in
pkgs.testers.runNixOSTest {
  name = "home-manager-bootstrap-login";

  # ONE node. This test exists for the one thing only a booted machine can
  # show: that the systemd USER service actually fires when a session
  # starts, and that the stamp survives into the next user-manager
  # instance. The FLAG behaviors it used to boot a second VM for --
  # loginReactivate = "every-login" overriding the stamp, user filtering, the
  # failure path -- are all covered deterministically and in seconds by
  # checks/bootstrap/script.nix, which drives the very same wrapper with a
  # recording stub. A second full boot bought no unique coverage.
  nodes.machine = mkNode { };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    # the autologin session starts alice's user manager -> the service runs
    machine.wait_until_succeeds("test -f /tmp/hm-record")
    machine.succeed("grep -q -- 'switch --flake /fake-flake#alice@vmhost' /tmp/hm-record")
    machine.wait_until_succeeds("test -f ~alice/.local/state/home-manager-bootstrap.stamp")
    machine.succeed('[ "$(wc -l < /tmp/hm-record)" -eq 1 ]')

    # a fresh user-manager instance = the next login
    machine.succeed("systemctl restart user@$(id -u alice).service")
    machine.wait_until_succeeds(
        "su -l alice -c 'env XDG_RUNTIME_DIR=/run/user/$(id -u alice) "
        "systemctl --user is-active home-manager-bootstrap.service'"
    )
    # ... and the stamp keeps it from switching again
    machine.succeed('[ "$(wc -l < /tmp/hm-record)" -eq 1 ]')

    # ── presence-only by DEFAULT: STALE stamp content is NOT acted on ──
    # The regression this guards: `inputs.self` gets a brand-new store
    # path on every `nixos-rebuild switch` regardless of whether home.nix
    # changed, so a content-comparing stamp made an ordinary rebuild (or
    # this library's own unattended systemAutoUpgradeModule) silently
    # revert anything the user had switched to by hand since bootstrap.
    # A real reboot-equivalent (fresh user-manager instance) is the one
    # thing only a booted machine can prove here.
    machine.succeed(
        "su -l alice -c 'echo /old-flake#alice@oldhost > "
        "~/.local/state/home-manager-bootstrap.stamp'"
    )
    machine.succeed("systemctl restart user@$(id -u alice).service")
    machine.wait_until_succeeds(
        "su -l alice -c 'env XDG_RUNTIME_DIR=/run/user/$(id -u alice) "
        "systemctl --user is-active home-manager-bootstrap.service'"
    )
    # still just the one switch from first login -- the stale stamp did
    # not trigger a second one
    machine.succeed('[ "$(wc -l < /tmp/hm-record)" -eq 1 ]')
    # ... and the stamp is untouched: this run never got far enough to
    # rewrite it
    machine.succeed(
        "grep -q '/old-flake#alice@oldhost' ~alice/.local/state/home-manager-bootstrap.stamp"
    )
    # restore a stamp matching the current parameters before the next
    # scenario, which counts switches from a clean baseline
    machine.succeed(
        "su -l alice -c 'echo /fake-flake#alice@vmhost > "
        "~/.local/state/home-manager-bootstrap.stamp'"
    )

    # ── failure, then retry on a later login ──
    machine.succeed("su -l alice -c 'rm ~/.local/state/home-manager-bootstrap.stamp'")
    machine.succeed("touch /tmp/hm-fail")
    machine.succeed("systemctl restart user@$(id -u alice).service")
    # the run failed: Result records the exit-code (ActiveState may read
    # activating/auto-restart -- the unit retries within the session too,
    # Restart=on-failure -- so is-failed alone would race that)
    machine.wait_until_succeeds(
        "su -l alice -c 'env XDG_RUNTIME_DIR=/run/user/$(id -u alice) "
        "systemctl --user show home-manager-bootstrap.service -p Result' "
        "| grep -q exit-code"
    )
    # ... and no stamp was written
    machine.succeed("test ! -e ~alice/.local/state/home-manager-bootstrap.stamp")

    # ── Restart=on-failure heals WITHIN the session ──
    # remove the transient cause without touching the user manager: the
    # pending in-session retry (RestartSec=30s) succeeds on its own
    machine.succeed("rm /tmp/hm-fail")
    machine.wait_until_succeeds(
        "test -f ~alice/.local/state/home-manager-bootstrap.stamp", timeout=60
    )
    machine.succeed('[ "$(wc -l < /tmp/hm-record)" -eq 2 ]')

    # ── failure again, then retry on a later login ──
    machine.succeed("su -l alice -c 'rm ~/.local/state/home-manager-bootstrap.stamp'")
    machine.succeed("touch /tmp/hm-fail")
    machine.succeed("systemctl restart user@$(id -u alice).service")
    machine.wait_until_succeeds(
        "su -l alice -c 'env XDG_RUNTIME_DIR=/run/user/$(id -u alice) "
        "systemctl --user show home-manager-bootstrap.service -p Result' "
        "| grep -q exit-code"
    )
    # next login: the transient cause is gone, the same service succeeds
    machine.succeed("rm /tmp/hm-fail")
    machine.succeed("systemctl restart user@$(id -u alice).service")
    machine.wait_until_succeeds("test -f ~alice/.local/state/home-manager-bootstrap.stamp")
    machine.succeed("grep -q '/fake-flake#alice@vmhost' ~alice/.local/state/home-manager-bootstrap.stamp")
    machine.succeed('[ "$(wc -l < /tmp/hm-record)" -eq 3 ]')
  '';
}
