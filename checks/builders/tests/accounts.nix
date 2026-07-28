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
