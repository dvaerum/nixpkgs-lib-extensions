# users/<u>/_defaults.nix and users/<u>/hosts/<h>/_defaults.nix: per-user
# builder arguments, read by userHomesStandalone/userHomesFromPlan
# (hosts-args.nix). Exists to remove the `anyHost` bug: a host-less home
# used to build against "whichever declared host sorts first
# alphabetically", so renaming an unrelated host silently changed
# another user's architecture. Fixture tree: fixtures/tree-userdefaults.
{
  lib,
  myLib,
  inputs,
  system,
  fixturesDir,
  repoDir,
  ...
}:
let
  # Direct import, like defaults.nix does for allowedHostArgs: these are
  # not part of the builders' own public surface, so shared.nix does not
  # re-export them.
  userDefaultsLib = import (repoDir + "/lib/nixos/internal/user-defaults.nix") {
    inherit lib;
    self = myLib;
  };
  hostsArgsLib = import (repoDir + "/lib/nixos/internal/hosts-args.nix") {
    inherit lib;
    self = myLib;
  };

  tree = fixturesDir + "/tree-userdefaults";

  standalone = myLib.buildHomeConfigurations {
    inherit inputs system;
    rootPath = tree;
    traceDiscoveredUsers = false;
  };

  # A second standalone system, for the "does the user's own system win"
  # sanity check -- opposite of the fleet's `system`.
  standaloneOtherArch = myLib.buildHomeConfigurations {
    inherit inputs;
    system = "aarch64-linux";
    rootPath = tree;
    traceDiscoveredUsers = false;
  };

  # Two declared hosts of different architectures, no `_defaults.system`
  # -- the exact shape of the reported bug.
  mixedNoDefault = myLib.buildConfigurations {
    _defaults = {
      inherit inputs;
      rootPath = tree;
      traceDiscoveredUsers = false;
      systemAutoUpgrade = false;
      homeAutoUpgrade = false;
      users = [ ];
    };
    zzzhost = {
      inherit system;
    };
    ahost = {
      system = "aarch64-linux";
    };
  };

  # Same shape, WITH `_defaults.system` -- the fallback that makes a
  # host-less home stop depending on host naming order. Built twice with
  # the architectures swapped between the two hostnames: under the old
  # `anyHost` code the alphabetically-FIRST host's arch would flip
  # between the two calls; the fallback must not.
  mkMixedWithDefault =
    firstArch: secondArch:
    myLib.buildConfigurations {
      _defaults = {
        inherit inputs;
        system = "x86_64-linux";
        rootPath = tree;
        traceDiscoveredUsers = false;
        systemAutoUpgrade = false;
        homeAutoUpgrade = false;
        users = [ ];
      };
      ahost = {
        system = firstArch;
      };
      zzzhost = {
        system = secondArch;
      };
    };
  mixedWithDefaultA = mkMixedWithDefault "aarch64-linux" "x86_64-linux";
  mixedWithDefaultB = mkMixedWithDefault "x86_64-linux" "aarch64-linux";

  # frank@pi: host `pi` AGREES with users/frank/hosts/pi/_defaults.nix
  # (both aarch64-linux) -- must build, no conflict.
  frankAgree = myLib.buildConfigurations {
    _defaults = {
      inherit inputs;
      rootPath = tree;
      traceDiscoveredUsers = false;
      systemAutoUpgrade = false;
      homeAutoUpgrade = false;
      users = [ "frank" ];
    };
    pi = {
      system = "aarch64-linux";
    };
  };

  # frank@pi: host `pi` CONTRADICTS users/frank/hosts/pi/_defaults.nix
  # (x86_64-linux vs. the file's aarch64-linux) -- must throw.
  frankConflict = myLib.buildConfigurations {
    _defaults = {
      inherit inputs;
      rootPath = tree;
      traceDiscoveredUsers = false;
      systemAutoUpgrade = false;
      homeAutoUpgrade = false;
      users = [ "frank" ];
    };
    pi = {
      system = "x86_64-linux";
    };
  };

  # bob is NOT in loginHomes here, so buildConfigurations builds him a
  # SYSTEM-MANAGED home -- cycle 11: his users/bob/_defaults.nix
  # (system = aarch64-linux) must be completely ignored; the system's own
  # pkgs apply.
  systemManaged = myLib.buildConfigurations {
    _defaults = {
      inherit inputs system;
      rootPath = tree;
      traceDiscoveredUsers = false;
      systemAutoUpgrade = false;
      homeAutoUpgrade = false;
      users = [ "bob" ];
      loginHomes = [ ];
    };
    onehost = { };
  };
in
{
  # ── cycle 1: the attrset form reaches the home at all ──────────────
  ud-attrset-form-applies = standalone ? bob;

  # ── cycle 2: `system` from the file reaches `pkgs`, not just the
  # argument -- the stale-core failure mode. Built with a FLEET system
  # of x86_64-linux, so a pass here can only be explained by the file. ──
  ud-system-reaches-pkgs = standalone.bob.pkgs.stdenv.hostPlatform.system == "aarch64-linux";

  # ── cycle 3: a user with no override (alice), and one overriding only
  # a NON-core argument (grace: homeModules), share the SAME core as
  # each other -- proving overrides are not multiplying nixpkgs
  # evaluations for users who never touch a core argument. ──
  ud-no-core-override-shares-base-core =
    standalone.alice.pkgs.hello.outPath == standalone.grace.pkgs.hello.outPath;
  # ... and really is a DIFFERENT core than bob's own (sanity: the
  # sharing above is not just "everything happens to match")
  ud-core-override-really-differs =
    standalone.alice.pkgs.hello.outPath != standalone.bob.pkgs.hello.outPath;

  # ── cycle 4: function form receives username/hostname/inputs/rootPath/
  # extLib, and nixpkgs' PLAIN lib (not the module lib -- it must NOT
  # carry this library's own additions). ──
  ud-function-form-context =
    let
      probe = standalone.carol._module.specialArgs.userDefaultsContextProbe;
    in
    probe.username == "carol"
    && probe.hostname == null
    && probe.gotInputs
    && probe.gotRootPath
    && probe.gotExtLib
    && probe.gotPlainLib;
  ud-function-form-system-reaches-pkgs =
    standalone.carol.pkgs.stdenv.hostPlatform.system == "aarch64-linux";

  # ── cycle 5: a non-attrset return throws a shape error naming the
  # file, and the message is checked as DATA (a throw's own text is not
  # observable in-language). ──
  ud-shape-error-message =
    let
      msg = userDefaultsLib.userDefaultsShapeMessage (
        tree + "/users/dave/_defaults.nix"
      ) "not an attrset";
    in
    lib.hasInfix "must evaluate to an attribute set" msg && lib.hasInfix "dave/_defaults.nix" msg;
  ud-shape-error-really-throws =
    !(builtins.tryEval standalone.dave.activationPackage.drvPath).success;

  # ── cycle 6 (the reported bug): two hosts of different architectures,
  # no `_defaults.system` -- alice (host-less, no file of her own) MUST
  # throw rather than silently pick one. ──
  ud-hostless-throws-without-defaults-system =
    !(builtins.tryEval mixedNoDefault.homeConfigurations.alice.activationPackage.drvPath).success;
  # ... but the ATTRIBUTE NAMES still compute -- see cycle 12, this is
  # the same guarantee in the specific shape of the reported bug.
  ud-hostless-throw-does-not-block-attrnames =
    (builtins.tryEval (builtins.attrNames mixedNoDefault.homeConfigurations)).success;

  # ── cycle 7 (regression guard): with `_defaults.system` set, alice's
  # architecture must be THAT value regardless of which declared host
  # sorts first alphabetically -- the `anyHost` mechanism, if it still
  # existed, would flip this between the two calls below. ──
  ud-hostless-uses-defaults-system-regardless-of-order-a =
    mixedWithDefaultA.homeConfigurations.alice.pkgs.stdenv.hostPlatform.system == "x86_64-linux";
  ud-hostless-uses-defaults-system-regardless-of-order-b =
    mixedWithDefaultB.homeConfigurations.alice.pkgs.stdenv.hostPlatform.system == "x86_64-linux";
  # ... and a user's OWN file still wins over `_defaults.system` even
  # when one is set fleet-wide (bob's file says aarch64-linux; the fleet
  # default here is x86_64-linux).
  ud-own-file-wins-over-defaults-system =
    mixedWithDefaultA.homeConfigurations.bob.pkgs.stdenv.hostPlatform.system == "aarch64-linux";

  # ── cycle 8: `frank@pi` -- host and file AGREE -> builds; host and
  # file CONTRADICT -> throws, and the message names the file, the host,
  # and both systems. ──
  ud-host-file-agreement-builds =
    (builtins.tryEval frankAgree.homeConfigurations."frank@pi".activationPackage.drvPath).success;
  ud-host-file-conflict-throws =
    !(builtins.tryEval frankConflict.homeConfigurations."frank@pi".activationPackage.drvPath).success;
  ud-host-file-conflict-message =
    let
      msg =
        hostsArgsLib.hostSystemConflictMessage "buildConfigurations" "frank" "pi" "x86_64-linux"
          "aarch64-linux";
    in
    lib.hasInfix "frank@pi" msg
    && lib.hasInfix "x86_64-linux" msg
    && lib.hasInfix "aarch64-linux" msg
    && lib.hasInfix "users/frank/hosts/pi/_defaults.nix" msg;

  # ── cycle 9: an unknown key, and a REJECTED-but-real builder argument
  # (`rootPath` -- circular, it would move the lookup of this very
  # file), each throw naming the file and the accepted list. ──
  ud-unknown-key-throws =
    userDefaultsLib.userDefaultsProblems userDefaultsLib.allowedUserDefaultsArgs false (tree + "/x") {
      thisIsNotARealArgument = true;
    } != [ ];
  ud-rejected-key-message =
    let
      msgs = userDefaultsLib.userDefaultsProblems userDefaultsLib.allowedUserDefaultsArgs false (
        tree + "/users/erin/_defaults.nix"
      ) { rootPath = ./.; };
    in
    lib.length msgs == 1
    && lib.hasInfix "rootPath" (lib.head msgs)
    && lib.hasInfix "erin" (lib.head msgs);
  ud-erin-really-throws = !(builtins.tryEval standalone.erin.activationPackage.drvPath).success;

  # ── cycle 10: at the HOST layer, `extra.<key>` ADDS to the base
  # file's value; a BARE key REPLACES it outright.
  #
  # grace: base users/grace/_defaults.nix sets homeModules to one marker;
  # users/grace/hosts/pi/_defaults.nix sets `extra.homeModules` to a
  # second -- both markers must land in grace@pi.
  ud-extra-adds-to-base =
    let
      vars = standalone."grace@pi".config.home.sessionVariables;
    in
    (vars.UD_MARKER_BASE or null) == "1" && (vars.UD_MARKER_EXTRA or null) == "1";

  # ivan: same base shape, but users/ivan/hosts/pi/_defaults.nix sets a
  # BARE homeModules -- only the host layer's marker may land in ivan@pi,
  # proving the base value was REPLACED rather than added to.
  ud-bare-replaces-base =
    let
      vars = standalone."ivan@pi".config.home.sessionVariables;
    in
    (vars.UD_MARKER_REPLACE or null) == "1" && !(vars ? UD_MARKER_BASE);

  # ── cycle 11: a SYSTEM-MANAGED home (bob is not in loginHomes here)
  # ignores users/bob/_defaults.nix entirely -- the system's own pkgs
  # apply, not the aarch64-linux the file asks for. ──
  ud-system-managed-home-ignores-file =
    systemManaged.nixosConfigurations.onehost.pkgs.stdenv.hostPlatform.system == system;

  # ── cycle 12 (laziness guard): computing homeConfigurations' attribute
  # NAMES must succeed even though users/dave/_defaults.nix cannot parse
  # as a valid override -- only building dave's own home may fail. If
  # the read were hoisted out of the per-home thunk (into the name-
  # computing filter), THIS assertion is what would catch it: every
  # user's tree, dave's included, would need reading just to answer
  # "what users exist", including dave's before its shape is even
  # checked -- and dave's cannot be read without throwing. ──
  ud-laziness-attrnames-survive-a-broken-file =
    (builtins.tryEval (builtins.attrNames standalone)).success && standalone ? dave;
}
