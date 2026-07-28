# The three checks covering the home-manager login bootstrap, from cheap to
# expensive:
#   bootstrap-script     sandboxed behavior test of the script (stubbed CLI)
#   bootstrap-login-vm   real boot + login: the systemd user service wiring
#   bootstrap-switch-vm  real `home-manager switch` inside the VM
# The attribute names are referenced by CI; keep them stable.
{
  pkgs,
  nixpkgs,
  home-manager,
  myLib,
}:
{
  bootstrap-script = import ./script.nix { inherit pkgs; };
  bootstrap-login-vm = import ./login-vm.nix { inherit pkgs myLib; };
  bootstrap-switch-vm = import ./switch-vm.nix {
    inherit
      pkgs
      nixpkgs
      home-manager
      myLib
      ;
  };
}
