# Home configurations, both mechanisms: login-managed homes (standalone
# home-manager evaluation with the builder's defaults) and system-managed
# homes (home-manager NixOS module inside the system).
{
  lib,
  myLib,
  nixpkgs,
  inputs,
  system,
  example,
  laptop,
  aliceHome,
  mkProbeSystem,
  exampleDir,
  fixturesDir,
  ...
}:
{
  # no home-manager input -> no home outputs (and no error)
  homes-empty-without-home-manager =
    myLib.buildHomeConfigurations {
      inputs = {
        inherit nixpkgs;
        self = inputs.self;
      };
      inherit system;
    } == { };

  # a removed argument (the old hand-written registry) is a typo now, and
  # throws rather than being silently ignored
  users-typo-throws =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.buildHomeConfigurations {
          inherit inputs system;
          userRegistry = { };
        }
      )
    )).success;

  # every user with a home.nix gets an output -- there is no per-host
  # allowlist to remember, and an output nobody forces costs nothing
  all-users-with-home-get-outputs =
    let
      homes = myLib.buildHomeConfigurations {
        inherit inputs system;
        traceDiscoveredUsers = false;
      };
    in
    builtins.attrNames homes == [
      "alice"
      "bob@laptop"
      # the STANDALONE builder has no declared host list, so it builds
      # every host any user has an override for -- including one no NixOS
      # system in this flake mentions (carol's `otherhost`). The
      # plan-based path (buildConfigurations) emits only declared hosts.
      "carol@otherhost"
      "dave"
      "frank"
      "frank@laptop"
      "grace"
    ];

  # an explicit homeManager input is honored WITHOUT re-running detection
  homes-honor-explicit-home-manager =
    (myLib.buildHomeConfigurations {
      inputs = {
        inherit nixpkgs;
        self = inputs.self;
      };
      inherit system;
      homeManager = inputs.home-manager;
      traceDiscoveredUsers = false;
    }) ? "alice";

  # the single-home primitive throws without home-manager, naming the
  # capability it looked for
  home-builder-throws-without-home-manager =
    !(builtins.tryEval (
      (myLib.mkHomeConfiguration {
        inputs = {
          inherit nixpkgs;
          self = inputs.self;
        };
        inherit system;
        username = "alice";
      }).activationPackage
    )).success;

  home-eval-username = aliceHome.config.home.username == "alice";
  home-eval-home-directory = aliceHome.config.home.homeDirectory == "/home/alice";
  # alice's home.nix PINS stateVersion (as the template should): the pin
  # wins over the builder's default, and no stateVersion warning appears
  home-eval-state-version-pinned =
    aliceHome.config.home.stateVersion == "26.11"
    && !(builtins.any (w: lib.hasInfix "home.stateVersion" w) aliceHome.config.warnings);
  # a login home that does NOT pin keeps the convenience default (the
  # CURRENT nixpkgs release) but is told so: the warning names the user
  # and both pin recipes. Asserted via the `warnings` option -- an eval
  # warning also fires on the VALUE, but is not observable in-language.
  home-eval-state-version-default-warns =
    let
      probe = myLib.mkHomeConfiguration {
        inherit inputs system;
        hostname = "laptop";
        username = "unpinned";
        users = null;
        rootPath = fixturesDir + "/tree-unpinned";
      };
      warning = lib.findFirst (w: lib.hasInfix "home.stateVersion" w) null probe.config.warnings;
    in
    warning != null
    && lib.hasInfix "`unpinned`" warning
    && lib.hasInfix "home.nix" warning
    && lib.hasInfix "homeModules" warning
    # ... and says what counts as a pin: mkOptionDefault does not
    && lib.hasInfix "mkOptionDefault" warning
    && probe.config.home.stateVersion == lib.trivial.release;
  # homeModules (set in the example's _defaults) reach login homes
  home-shared-modules-applied = aliceHome.config.programs.direnv.enable;

  # the warning's own fleet-wide recipe -- a shared homeModules entry
  # pinning via mkDefault -- must BEAT the builder's default, not collide
  # with it at equal priority: the default sits below mkDefault (1250)
  home-state-version-mkdefault-pin-wins =
    let
      probe = myLib.mkHomeConfiguration {
        inherit inputs system;
        hostname = "laptop";
        username = "unpinned";
        users = null;
        rootPath = fixturesDir + "/tree-unpinned";
        homeModules = [
          (
            { lib, ... }:
            {
              home.stateVersion = lib.mkDefault "25.05";
            }
          )
        ];
      };
    in
    probe.config.home.stateVersion == "25.05"
    && !(builtins.any (w: lib.hasInfix "home.stateVersion" w) probe.config.warnings);

  # ... while the warning's mkOptionDefault clause holds: a definition AT
  # OR BELOW the builder's default priority is not a pin -- the builder's
  # default still wins and the home still counts as unpinned
  home-state-version-mkoptiondefault-still-warns =
    let
      probe = myLib.mkHomeConfiguration {
        inherit inputs system;
        hostname = "laptop";
        username = "unpinned";
        users = null;
        rootPath = fixturesDir + "/tree-unpinned";
        homeModules = [
          (
            { lib, ... }:
            {
              home.stateVersion = lib.mkOptionDefault "25.05";
            }
          )
        ];
      };
    in
    probe.config.home.stateVersion == lib.trivial.release
    && builtins.any (w: lib.hasInfix "home.stateVersion" w) probe.config.warnings;

  # ... and throws when the matched registry entries ship no home.nix at
  # all (eve is a system-only user: configuration.nix, no home.nix)
  home-builder-throws-without-home-nix =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.mkHomeConfiguration {
          inherit inputs system;
          hostname = "laptop";
          username = "eve";
        }
      )
    )).success;

  # login homes get `username` as a module argument, and the host's user
  # list as the `nixpkgsLibExtensions.users` option
  username-reaches-login-homes =
    let
      probe = myLib.mkHomeConfiguration {
        inherit inputs system;
        hostname = "laptop";
        username = "alice";
        homeModules = [
          (
            { username, config, ... }:
            {
              home.sessionVariables.WHOAMI = username;
              home.sessionVariables.ALL_USERS = builtins.concatStringsSep "," config.nixpkgsLibExtensions.users;
            }
          )
        ];
      };
    in
    probe.config.home.sessionVariables.WHOAMI == "alice"
    && probe.config.home.sessionVariables.ALL_USERS == "alice,bob,dave,eve,frank,grace";

  # SYSTEM-managed homes are built into the system via home-manager's
  # NixOS module: frank's wildcard entry merges there too
  system-home-wildcard-merge = laptop.config.home-manager.users.frank.programs.git.enable;
  # ... using the system's package set: useGlobalPkgs/useUserPackages
  # default to true ...
  system-homes-use-global-pkgs =
    laptop.config.home-manager.useGlobalPkgs && laptop.config.home-manager.useUserPackages;
  # ... but only mkDefault: a module of the host wins
  system-homes-pkgs-options-overridable =
    !(mkProbeSystem {
      inherit inputs system;
      hostname = "hmopts";
      users = null;
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        { home-manager.useGlobalPkgs = false; }
      ];
    }).config.home-manager.useGlobalPkgs;
  # dave's home.nix pins stateVersion; the pin wins over the builder's
  # default and no warning appears in his SYSTEM-managed home
  system-home-state-version-pinned =
    laptop.config.home-manager.users.dave.home.stateVersion == "26.11"
    && !(builtins.any (
      w: lib.hasInfix "home.stateVersion" w
    ) laptop.config.home-manager.users.dave.warnings);
  # ... while a system-managed home that does NOT pin keeps the default
  # (current release) and gets the same warning the login mechanism emits
  system-home-state-version-default-warns =
    let
      user =
        (mkProbeSystem {
          inherit inputs system;
          hostname = "unpinnedhost";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          users = null;
          rootPath = fixturesDir + "/tree-unpinned";
        }).config.home-manager.users.unpinned;
    in
    builtins.any (w: lib.hasInfix "home.stateVersion" w && lib.hasInfix "`unpinned`" w) user.warnings
    && user.home.stateVersion == lib.trivial.release;
  # `username` reaches system homes as a module argument too
  # (extraSpecialArgs cannot vary per user; _module.args can)
  username-reaches-system-homes =
    (mkProbeSystem {
      inherit inputs system;
      hostname = "whoami";
      users = null;
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      homeModules = [
        ({ username, ... }: { home.sessionVariables.WHOAMI = username; })
      ];
    }).config.home-manager.users.dave.home.sessionVariables.WHOAMI == "dave";
  # ... homeModules reach system homes as well
  system-home-shared-modules-applied = laptop.config.home-manager.users.dave.programs.direnv.enable;
  # ... and exactly the non-login users get one: alice/bob are
  # login-managed, eve is system-only (no home.nix)
  system-homes-only-for-non-login-users =
    builtins.attrNames laptop.config.home-manager.users == [
      "dave"
      "frank"
      "grace"
    ];

  # a home.nix user without any home-manager input: the system still
  # evaluates (with a warning) but carries no home-manager wiring --
  # homes are dropped LOUDLY, not silently
  system-homes-dropped-without-home-manager-warns =
    !(
      (myLib.mkNixosSystem {
        inputs = {
          inherit nixpkgs;
          self = inputs.self;
        };
        inherit system;
        hostname = "nohm";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      }).options ? home-manager
    );
}
