# Real-login VM test for the home-manager login bootstrap. A stub
# `home-manager` records its invocations, so this verifies the systemd USER
# service wiring in a real booted system -- the service fires when the
# user's session starts, the stamp prevents a re-run on the next
# user-manager instance, and --reactivate-every-login overrides that --
# without any in-VM nix evaluation (see switch-vm.nix for that).
{ pkgs, myLib }:
let
  system = pkgs.stdenv.hostPlatform.system;

  stub = pkgs.writeShellScriptBin "home-manager" ''
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
          userRegistry."alice" = ../example/users/alice;
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
  # --reactivate-every-login overriding the stamp, user filtering, the
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
  '';
}
