# VM test for SYSTEM-managed homes: the home ships with the system (via
# home-manager's NixOS module) and activates on boot through the
# home-manager-<user>.service unit -- no login bootstrap, no flake
# outputs involved.
#
# The node MIRRORS the wiring nixosConfigurationsBuilder produces for
# its system-managed homes (import the home-manager NixOS module,
# useGlobalPkgs/useUserPackages, sharedModules plus a per-user imports
# list) instead of REUSING the builder: runNixOSTest owns the nixpkgs
# evaluation of its nodes, so a builder-built nixosSystem cannot be a
# node -- and the mirror keeps this runtime test independent of the
# builder's eval-time plumbing, which checks/builders already covers.
# Keep the wiring here in sync with the systemHomesModule of
# lib/nixos/nixosConfigurationsBuilder.nix.
#
# Deliberately light: no in-VM evaluation happens (the home closure is
# part of the system closure), so no useNixStoreImage is needed.
{
  pkgs,
  nixpkgs,
  home-manager,
}:
pkgs.testers.runNixOSTest {
  name = "system-homes";

  nodes.machine = {
    imports = [ home-manager.nixosModules.default ];

    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    # stands in for the builder's homeModules slot
    home-manager.sharedModules = [
      { home.file.".system-home-marker".text = "ok"; }
    ];
    home-manager.users.alice = {
      imports = [ ../example/users/alice/home.nix ];
      home.stateVersion = nixpkgs.lib.trivial.release;
    };

    users.users.alice.isNormalUser = true;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    # oneshot + RemainAfterExit: `status` exits 0 only while the unit is
    # active (exited), i.e. the home activation ran and succeeded
    machine.succeed("systemctl status home-manager-alice.service")
    machine.succeed("test -f /home/alice/.system-home-marker")
    machine.succeed('[ "$(cat /home/alice/.system-home-marker)" = ok ]')
  '';
}
