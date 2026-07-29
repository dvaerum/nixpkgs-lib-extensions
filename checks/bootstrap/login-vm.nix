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
          loginUsers = [ "alice" ];
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

  nodes = {
    machine = mkNode { };
    reactivating = mkNode { loginReactivateEveryLogin = true; };
  };

  testScript = ''
    start_all()

    def first_run(m):
        m.wait_for_unit("multi-user.target")
        # the autologin session starts alice's user manager -> the service runs
        m.wait_until_succeeds("test -f /tmp/hm-record")
        m.succeed("grep -q -- 'switch --flake /fake-flake#alice@vmhost' /tmp/hm-record")
        m.wait_until_succeeds("test -f ~alice/.local/state/home-manager-bootstrap.stamp")
        m.succeed('[ "$(wc -l < /tmp/hm-record)" -eq 1 ]')
        # a fresh user-manager instance = the next login
        m.succeed("systemctl restart user@$(id -u alice).service")
        m.wait_until_succeeds(
            "su -l alice -c 'env XDG_RUNTIME_DIR=/run/user/$(id -u alice) "
            "systemctl --user is-active home-manager-bootstrap.service'"
        )

    first_run(machine)
    first_run(reactivating)

    # the stamp prevents a re-run on the next user-manager instance ...
    machine.succeed('[ "$(wc -l < /tmp/hm-record)" -eq 1 ]')
    # ... unless --reactivate-every-login is set
    reactivating.wait_until_succeeds('[ "$(wc -l < /tmp/hm-record)" -eq 2 ]')
  '';
}
