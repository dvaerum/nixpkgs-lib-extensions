# The runtime checks covering both home-manager mechanisms, from cheap
# to expensive:
#   bootstrap-script          sandboxed behavior test of the script (stubbed CLI)
#   bootstrap-login-vm        real boot + login: the systemd user service wiring
#   bootstrap-system-homes-vm real boot: a SYSTEM-managed home activates with the system
#   bootstrap-switch-vm       real `home-manager switch` inside the VM
# The attribute names are referenced elsewhere (flake.nix's comment, CI
# logs); keep them stable.
{
  pkgs,
  nixpkgs,
  home-manager,
  myLib,
}:
{
  bootstrap-script = import ./script.nix { inherit pkgs; };
  bootstrap-login-vm = import ./login-vm.nix { inherit pkgs myLib; };
  bootstrap-system-homes-vm = import ./system-homes-vm.nix {
    inherit pkgs nixpkgs home-manager;
  };
  bootstrap-switch-vm = import ./switch-vm.nix {
    inherit
      pkgs
      nixpkgs
      home-manager
      myLib
      ;
  };
}
