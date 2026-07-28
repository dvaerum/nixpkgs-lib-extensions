# User account creation: the normalUserModule default, its private primary
# group, and disabling via userModuleFn = null.
{
  lib,
  myLib,
  inputs,
  system,
  laptop,
  exampleDir,
  ...
}:
let
  # normalUserModule as a unit: apply its inner module function directly
  aliceModule = (builtins.head (myLib.normalUserModule "alice").imports) { inherit lib; };
in
{
  # the module itself declares the account, the private group, and sets the
  # primary group at priority 900 (beats isNormalUser's mkDefault "users",
  # loses to a plain assignment)
  normal-user-module-unit =
    aliceModule.users.users.alice.isNormalUser
    && aliceModule.users.groups ? alice
    && aliceModule.users.users.alice.group.priority == 900
    && aliceModule.users.users.alice.group.content == "alice";
  # root is special-cased to an empty module: NixOS fully defines the
  # account itself, and isNormalUser would add second definitions of the
  # unique `shell`/`home` options
  normal-user-module-root-empty =
    (builtins.head (myLib.normalUserModule "root").imports) { inherit lib; } == { };

  # ... so a host with "root" in the registry evaluates: root keeps its
  # NixOS-defined system account (uid 0's home, not isNormalUser)
  root-registry-entry-safe =
    let
      root-user =
        (myLib.nixosConfigurationsBuilder {
          inherit inputs system;
          hostname = "rootentry";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          homeConfigurations."root" = exampleDir + "/users/alice";
        }).rootentry.config.users.users.root;
    in
    !root-user.isNormalUser && root-user.home == "/root";

  # the default userModuleFn (normalUserModule) creates an account for
  # every derived user, including system-only eve
  user-accounts-created = laptop.config.users.users.dave.isNormalUser && laptop.config.users.users.eve.isNormalUser;

  # ... with a private primary group named after the user
  user-private-group =
    laptop.config.users.users.dave.group == "dave" && laptop.config.users.groups ? dave;

  # userModuleFn = null disables account creation
  user-module-fn-null-disables =
    !(
      (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "noaccounts";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        homeConfigurations."alice" = exampleDir + "/users/alice";
        userModuleFn = null;
      }).noaccounts.config.users.users ? alice
    );
}
