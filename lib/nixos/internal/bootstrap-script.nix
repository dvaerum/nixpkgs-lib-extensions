# Builds the wrapped login-bootstrap script. Shared between
# homeManagerBootstrapModule (with the real home-manager package) and
# checks/bootstrap-script.nix (with a stub that records invocations), so the
# tests exercise exactly the wrapper used in production.
{ pkgs, homeManager }:
pkgs.writeShellApplication {
  name = "home-manager-bootstrap";
  runtimeInputs = [
    homeManager
    pkgs.coreutils
  ];
  text = builtins.readFile ../scripts/home-manager-bootstrap.sh;
}
