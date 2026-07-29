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
  # normalUserModule as a unit: apply its inner module function directly.
  # The config stub supplies the merged uid the module inspects; its
  # conditional settings come back as mkIf structures (condition/content).
  unitModule =
    username: uid:
    (builtins.head (myLib.normalUserModule username).imports) {
      inherit lib;
      config.users.users.${username}.uid = uid;
    };
  aliceModule = unitModule "alice" null;
  rootModule = unitModule "root" 0;
in
{
  # the module itself declares the account, the private group, and sets the
  # primary group at priority 900 (beats isNormalUser's mkDefault "users",
  # loses to a plain assignment)
  normal-user-module-unit =
    aliceModule.users.users.alice.isNormalUser.condition
    && aliceModule.users.users.alice.isNormalUser.content
    && aliceModule.users.groups.condition
    && aliceModule.users.groups.content ? alice
    && aliceModule.users.users.alice.group.condition
    && aliceModule.users.users.alice.group.content.priority == 900
    && aliceModule.users.users.alice.group.content.content == "alice";

  # a merged uid below 1000 marks a system account: everything the module
  # would set is condition-gated off (NixOS forbids isNormalUser there)
  normal-user-module-uid-gated =
    !rootModule.users.users.root.isNormalUser.condition
    && !rootModule.users.users.root.group.condition
    && !rootModule.users.groups.condition;

  # ... so "root" is a valid registry user: the account stays the
  # NixOS-defined system one, and ALL of NixOS's own assertions hold
  # (forcing them is what catches uid/isNormalUser conflicts -- reading
  # individual attributes alone would not)
  root-registry-entry-safe =
    let
      cfg =
        (myLib.nixosConfigurationsBuilder {
          inherit inputs system;
          hostname = "rootentry";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          userRegistry."root" = exampleDir + "/users/alice";
        }).rootentry.config;
    in
    !cfg.users.users.root.isNormalUser
    && cfg.users.users.root.home == "/root"
    && cfg.users.users.root.group == "root"
    && cfg.users.users.root.shell != null
    && builtins.all (a: a.assertion) cfg.assertions;
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
        userRegistry."alice" = exampleDir + "/users/alice";
        userModuleFn = null;
      }).noaccounts.config.users.users ? alice
    );
}
