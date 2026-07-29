# Builds the wrapped login-bootstrap script. Shared between
# homeManagerBootstrapModule (with the real home-manager package) and
# checks/bootstrap/script.nix (with a stub that records invocations), so the
# tests exercise exactly the wrapper used in production.
{ pkgs, homeManager }:
pkgs.writeShellApplication {
  name = "home-manager-bootstrap";
  runtimeInputs = [
    homeManager
    pkgs.coreutils
    # the home-manager CLI shells out to `nix`, and a systemd user
    # service's PATH does not include the system profile -- without this
    # the service dies with exit 127 (`nix: command not found`) on real
    # hosts, even though interactive shells would find nix
    pkgs.nix
  ];
  text = builtins.readFile ../scripts/home-manager-bootstrap.sh;
}
