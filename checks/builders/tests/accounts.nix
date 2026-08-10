# User account creation: the normalUserModule default, its private primary
# group, and disabling via userModule = null.
{
  lib,
  myLib,
  inputs,
  system,
  laptop,
  exampleDir,
  fixturesDir,
  ...
}:
let
  # normalUserModule as a unit: apply its inner module function directly.
  # The config stub supplies the merged uid the module inspects; its
  # conditional settings come back as mkIf structures (condition/content).
  unitModule =
    username: uid: isSystemUser:
    (builtins.head (myLib.normalUserModule username).imports) {
      inherit lib;
      config.users.users.${username} = { inherit uid isSystemUser; };
    };
  aliceModule = unitModule "alice" null false;
  rootModule = unitModule "root" 0 false;
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

  # `isSystemUser` cannot GATE the definitions above -- users.groups and the
  # user submodule are mutually dependent in NixOS, so deciding what to
  # define by reading it is an infinite recursion. It is caught by an
  # assertion instead, which names this module and the ways out; NixOS's own
  # message ("exactly one of isSystemUser and isNormalUser must be set") is
  # true but never says who set the other one.
  system-user-conflict-explained =
    let
      cfg =
        (myLib.mkNixosSystem {
          inherit inputs system;
          hostname = "sysuser";
          modules = [
            (exampleDir + "/hosts/server/configuration.nix")
            { users.users.eve.isSystemUser = true; }
          ];
          userRegistry."eve" = exampleDir + "/users/eve";
        }).config;
      failed = builtins.filter (a: !a.assertion) cfg.assertions;
    in
    builtins.any (a: lib.hasInfix "userModule" a.message) failed;

  # ... so "root" is a valid registry user: the account stays the
  # NixOS-defined system one, and ALL of NixOS's own assertions hold
  # (forcing them is what catches uid/isNormalUser conflicts -- reading
  # individual attributes alone would not)
  root-registry-entry-safe =
    let
      cfg =
        (myLib.mkNixosSystem {
          inherit inputs system;
          hostname = "rootentry";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          userRegistry."root" = exampleDir + "/users/alice";
        }).config;
    in
    !cfg.users.users.root.isNormalUser
    && cfg.users.users.root.home == "/root"
    && cfg.users.users.root.group == "root"
    && cfg.users.users.root.shell != null
    && builtins.all (a: a.assertion) cfg.assertions;
  # normalUserModule reads the MERGED uid (config.users.users.<name>.uid)
  # while defining entries the same merge feeds, so recursion-freedom is a
  # property to PIN, not to assume: a registry user whose own
  # configuration.nix pins a uid must still evaluate, on either side of
  # the 1000 boundary. Below it (999) the module contributes nothing --
  # no isNormalUser on a system account; at 1000 it must still fire.
  # `builtins.all` over cfg.assertions forces the full account wiring.
  uid-999-registry-pin-stays-system =
    let
      cfg =
        (myLib.mkNixosSystem {
          inherit inputs system;
          hostname = "uid999";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          userRegistry."svc" = fixturesDir + "/uid-999";
        }).config;
    in
    cfg.users.users.svc.uid == 999
    && !cfg.users.users.svc.isNormalUser
    && cfg.users.users.svc.isSystemUser
    && cfg.users.users.svc.group == "svc"
    && builtins.all (a: a.assertion) cfg.assertions;

  uid-1000-registry-pin-gets-normal =
    let
      cfg =
        (myLib.mkNixosSystem {
          inherit inputs system;
          hostname = "uid1000";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          userRegistry."meg" = fixturesDir + "/uid-1000";
        }).config;
    in
    cfg.users.users.meg.uid == 1000
    && cfg.users.users.meg.isNormalUser
    && cfg.users.users.meg.group == "meg"
    && cfg.users.groups ? meg
    && builtins.all (a: a.assertion) cfg.assertions;

  # the default userModule (normalUserModule) creates an account for
  # every derived user, including system-only eve
  user-accounts-created =
    laptop.config.users.users.dave.isNormalUser && laptop.config.users.users.eve.isNormalUser;

  # ... with a private primary group named after the user
  user-private-group =
    laptop.config.users.users.dave.group == "dave" && laptop.config.users.groups ? dave;

  # ... and the same shell stock NixOS would have given them
  user-default-shell-preserved =
    laptop.config.users.users.dave.shell == laptop.config.users.defaultUserShell;

  # userModule = null disables account creation (alice as a login user:
  # a system-managed home would add a users.users.alice entry itself via
  # home-manager's useUserPackages)
  user-module-fn-null-disables =
    !(
      (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "noaccounts";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."alice" = exampleDir + "/users/alice";
        loginHomes = [ "alice" ];
        userModule = null;
      }).config.users.users ? alice
    );
}
