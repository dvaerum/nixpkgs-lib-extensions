# User account creation: the normalUserModule default, its private primary
# group, disabling via userModule = null, and the `_defaults.nix`-declared
# account-kind resolution (isSystemUser/isNormalUser) that replaced the
# old uid-read (see normal-user-module.nix and user-defaults.nix's own
# comments on why: reading the merged uid from inside account-creation
# modules once caused a genuine infinite recursion on a real host).
{
  lib,
  myLib,
  inputs,
  system,
  laptop,
  mkProbeSystem,
  exampleDir,
  fixturesDir,
  ...
}:
let
  # normalUserModule as a unit: apply its inner module function directly,
  # with the resolved `isNormalUser` handed in like mk-system.nix's own
  # pre-bound default does. `extraUserConfig` stubs whatever else the
  # config the module reads (only ever `isSystemUser`, inside its own
  # ASSERTION -- never a definition, so this stub cannot feed back into
  # the wiring being tested).
  unitModule =
    username: isNormalUser: extraUserConfig:
    (builtins.head (myLib.normalUserModule username isNormalUser).imports) {
      inherit lib;
      config.users.users.${username} = extraUserConfig;
    };
  aliceModule = unitModule "alice" true { isSystemUser = false; };
  svcModule = unitModule "svc" false { isSystemUser = true; };
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

  # `isNormalUser = false` (a resolved SYSTEM account): the module sets
  # ONLY `isSystemUser = true;` -- `isNormalUser`/`group`/the private
  # group are all still condition-gated off entirely (NixOS forbids
  # isNormalUser there)
  normal-user-module-system-gated =
    svcModule.users.users.svc.isSystemUser.condition
    && svcModule.users.users.svc.isSystemUser.content
    && !svcModule.users.users.svc.isNormalUser.condition
    && !svcModule.users.users.svc.group.condition
    && !svcModule.users.groups.condition;

  # a conflicting `configuration.nix` (isSystemUser = true) for a user
  # this module resolved as NORMAL (no `isSystemUser = true;` in that
  # user's `_defaults.nix`) is caught by an assertion, which names this
  # module and the ways out; NixOS's own message ("exactly one of
  # isSystemUser and isNormalUser must be set") is true but never says
  # who set the other one.
  system-user-conflict-explained =
    let
      cfg =
        (mkProbeSystem {
          inherit inputs system;
          hostname = "sysuser";
          users = null;
          modules = [
            (exampleDir + "/hosts/server/configuration.nix")
            { users.users.eve.isSystemUser = true; }
          ];
        }).config;
      failed = builtins.filter (a: !a.assertion) cfg.assertions;
    in
    builtins.any (a: lib.hasInfix "userModule" a.message) failed;

  # the reverse conflict: a user resolved as SYSTEM (`isSystemUser = true;`
  # in `_defaults.nix`) whose `configuration.nix` ALSO redundantly sets
  # `isNormalUser = true;` -- caught the same way, naming the actual fix.
  normal-user-conflict-explained =
    let
      cfg =
        (mkProbeSystem {
          inherit inputs system;
          hostname = "normaluserconflict";
          modules = [
            (exampleDir + "/hosts/server/configuration.nix")
            { users.users.svc.isNormalUser = true; }
          ];
          users = null;
          rootPath = fixturesDir + "/tree-uid999";
        }).config;
      failed = builtins.filter (a: !a.assertion) cfg.assertions;
    in
    builtins.any (a: lib.hasInfix "_defaults.nix" a.message) failed;

  # ... so "root" is a valid registry user: the account stays the
  # NixOS-defined system one (mk-system.nix always resolves `root` to a
  # system account, regardless of `_defaults.nix`), and ALL of NixOS's own
  # assertions hold (forcing them is what catches isNormalUser conflicts
  # -- reading individual attributes alone would not)
  root-registry-entry-safe =
    let
      cfg =
        (mkProbeSystem {
          inherit inputs system;
          hostname = "rootentry";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          users = null;
          rootPath = fixturesDir + "/tree-root";
        }).config;
    in
    !cfg.users.users.root.isNormalUser
    && cfg.users.users.root.home == "/root"
    && cfg.users.users.root.group == "root"
    && cfg.users.users.root.shell != null
    && builtins.all (a: a.assertion) cfg.assertions;

  # a registry user declaring `isSystemUser = true;` in `_defaults.nix`
  # stays a system account -- no isNormalUser, no private group -- and
  # its OWN configuration.nix's uid/isSystemUser/group all still apply.
  # `builtins.all` over cfg.assertions forces the full account wiring.
  defaults-declared-system-user-stays-system =
    let
      cfg =
        (mkProbeSystem {
          inherit inputs system;
          hostname = "uid999";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          users = null;
          rootPath = fixturesDir + "/tree-uid999";
        }).config;
    in
    cfg.users.users.svc.uid == 999
    && !cfg.users.users.svc.isNormalUser
    && cfg.users.users.svc.isSystemUser
    && cfg.users.users.svc.group == "svc"
    && cfg.nixpkgsLibExtensions.systemUsers == [ "svc" ]
    && cfg.nixpkgsLibExtensions.normalUsers == [ ]
    && builtins.all (a: a.assertion) cfg.assertions;

  # a registry user with NO `_defaults.nix` at all defaults to normal --
  # the common case, unchanged from before this mechanism existed.
  no-defaults-file-gets-normal =
    let
      cfg =
        (mkProbeSystem {
          inherit inputs system;
          hostname = "uid1000";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          users = null;
          rootPath = fixturesDir + "/tree-uid1000";
        }).config;
    in
    cfg.users.users.meg.isNormalUser
    && cfg.users.users.meg.group == "meg"
    && cfg.users.groups ? meg
    && cfg.nixpkgsLibExtensions.normalUsers == [ "meg" ]
    && cfg.nixpkgsLibExtensions.systemUsers == [ ]
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
      (mkProbeSystem {
        inherit inputs system;
        hostname = "noaccounts";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        loginHomes = [ "alice" ];
        userModule = null;
      }).config.users.users
        ? alice
    );
}
