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
  # (the config stub stands in for the host's users.defaultUserShell)
  aliceModule = (builtins.head (myLib.normalUserModule "alice").imports) {
    inherit lib;
    config.users.defaultUserShell = "SENTINEL-SHELL";
  };
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

  # the shell comes from users.defaultUserShell, defined once at priority
  # 999 with NixOS's useDefaultShell path suppressed -- stronger than the
  # two mkDefault definitions that would collide on root, weaker than a
  # plain `shell = ...` assignment
  normal-user-module-shell =
    aliceModule.users.users.alice.useDefaultShell.priority == 900
    && !aliceModule.users.users.alice.useDefaultShell.content
    && aliceModule.users.users.alice.shell.priority == 999
    && aliceModule.users.users.alice.shell.content == "SENTINEL-SHELL";

  # ... which makes "root" a valid registry user: its built-in shell
  # definition (mkDefault, 1000) loses to ours instead of colliding, and
  # root's other built-ins (home /root, group root) stay in force
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
    root-user.isNormalUser
    && root-user.home == "/root"
    && root-user.group == "root"
    && root-user.shell != null;
  # the default userModuleFn (normalUserModule) creates an account for
  # every derived user, including system-only eve
  user-accounts-created = laptop.config.users.users.dave.isNormalUser && laptop.config.users.users.eve.isNormalUser;

  # ... with a private primary group named after the user
  user-private-group =
    laptop.config.users.users.dave.group == "dave" && laptop.config.users.groups ? dave;

  # ... and the same shell stock NixOS would have given them
  user-default-shell-preserved =
    laptop.config.users.users.dave.shell == laptop.config.users.defaultUserShell;

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
