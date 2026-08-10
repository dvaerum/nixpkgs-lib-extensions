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
  exampleDir,
  fixturesDir,
  ...
}:
{
  # no home-manager input -> no home outputs from the hosts-level builder
  # (and no error)
  homes-empty-without-home-manager =
    myLib.buildHomeConfigurations {
      laptop = {
        inputs = {
          inherit nixpkgs;
          self = inputs.self;
        };
        inherit system;
        userRegistry."alice" = exampleDir + "/users/alice";
        loginHomes = [ "alice" ];
      };
    } == { };

  # a loginHomes TYPO used to be silent: no flake output, the home quietly
  # system-managed instead, and the system still built and booted. The
  # hosts-level builders see every host's registry, so a name matching no
  # user anywhere is a typo and throws.
  login-users-typo-throws =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.buildHomeConfigurations {
          laptop = {
            inherit inputs system;
            userRegistry."alice" = exampleDir + "/users/alice";
            loginHomes = [ "alicce" ];
          };
        }
      )
    )).success;

  # ... while a name that simply does not apply to THIS host stays legal:
  # one shared loginHomes in _defaults across a fleet is the documented way
  # to use it, so bob (a user on laptop only) must not break server
  login-users-unmatched-on-one-host-ok =
    builtins.attrNames (
      myLib.buildHomeConfigurations {
        _defaults = {
          inherit inputs system;
          loginHomes = [
            "alice"
            "bob"
          ];
        };
        laptop = {
          userRegistry = {
            "alice" = exampleDir + "/users/alice";
            "bob@laptop" = exampleDir + "/users/bob";
          };
        };
        server = {
          userRegistry."alice" = exampleDir + "/users/alice";
        };
      }
    ) == [
      "alice@laptop"
      "alice@server"
      "bob@laptop"
    ];

  # `userRegistry = null` is a documented value: a null-registry host in
  # the same plan as a loginHomes host must not crash the plan-wide
  # loginHomes validation (it read the RAW argument, and null slipped
  # through `or` into lib.attrNames as a bare type error)
  null-registry-host-beside-login-host =
    builtins.attrNames (
      myLib.buildHomeConfigurations {
        _defaults = {
          inherit inputs system;
        };
        laptop = {
          userRegistry."alice" = exampleDir + "/users/alice";
          loginHomes = [ "alice" ];
        };
        bare = {
          userRegistry = null;
        };
      }
    ) == [ "alice@laptop" ];

  # an explicit `homeManager` is honored by the hosts-level builder too: it
  # exists to BYPASS capability detection, so the per-host gate must not
  # re-run detection over `inputs` and silently return { }
  homes-honor-explicit-home-manager =
    builtins.attrNames (
      myLib.buildHomeConfigurations {
        laptop = {
          inputs = {
            inherit nixpkgs;
            self = inputs.self;
          };
          inherit system;
          homeManager = inputs.home-manager;
          userRegistry."alice" = exampleDir + "/users/alice";
          loginHomes = [ "alice" ];
        };
      }
    ) == [ "alice@laptop" ];

  # ... but the per-user builder THROWS: one explicitly requested home
  # that cannot be built is an error, not an empty result
  home-builder-throws-without-home-manager =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.mkHomeConfiguration {
          inputs = {
            inherit nixpkgs;
            self = inputs.self;
          };
          inherit system;
          hostname = "laptop";
          username = "alice";
          userRegistry."alice" = exampleDir + "/users/alice";
        }
      )
    )).success;

  # LOGIN-managed homes REALLY evaluate through home-manager's module
  # system (real input, not a stub), with the builder's defaults applied
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
        userRegistry."unpinned" = fixturesDir + "/unpinned-home";
      };
      warning = lib.findFirst (w: lib.hasInfix "home.stateVersion" w) null probe.config.warnings;
    in
    warning != null
    && lib.hasInfix "`unpinned`" warning
    && lib.hasInfix "home.nix" warning
    && lib.hasInfix "homeModules" warning
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
        userRegistry."unpinned" = fixturesDir + "/unpinned-home";
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

  # ... and throws when the matched registry entries ship no home.nix at
  # all (eve is a system-only user: configuration.nix, no home.nix)
  home-builder-throws-without-home-nix =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.mkHomeConfiguration {
          inherit inputs system;
          hostname = "laptop";
          username = "eve";
          userRegistry."eve" = exampleDir + "/users/eve";
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
        userRegistry = {
          "alice" = exampleDir + "/users/alice";
          "dave" = exampleDir + "/users/dave";
        };
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
    && probe.config.home.sessionVariables.ALL_USERS == "alice,dave";

  # SYSTEM-managed homes are built into the system via home-manager's
  # NixOS module: frank's wildcard entry merges there too
  system-home-wildcard-merge = laptop.config.home-manager.users.frank.programs.git.enable;
  # ... using the system's package set: useGlobalPkgs/useUserPackages
  # default to true ...
  system-homes-use-global-pkgs =
    laptop.config.home-manager.useGlobalPkgs && laptop.config.home-manager.useUserPackages;
  # ... but only mkDefault: a module of the host wins
  system-homes-pkgs-options-overridable =
    !(myLib.mkNixosSystem {
      inherit inputs system;
      hostname = "hmopts";
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        { home-manager.useGlobalPkgs = false; }
      ];
      userRegistry."dave" = exampleDir + "/users/dave";
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
        (myLib.mkNixosSystem {
          inherit inputs system;
          hostname = "unpinnedhost";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          userRegistry."unpinned" = fixturesDir + "/unpinned-home";
        }).config.home-manager.users.unpinned;
    in
    builtins.any (w: lib.hasInfix "home.stateVersion" w && lib.hasInfix "`unpinned`" w) user.warnings
    && user.home.stateVersion == lib.trivial.release;
  # `username` reaches system homes as a module argument too
  # (extraSpecialArgs cannot vary per user; _module.args can)
  username-reaches-system-homes =
    (myLib.mkNixosSystem {
      inherit inputs system;
      hostname = "whoami";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      userRegistry."dave" = exampleDir + "/users/dave";
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
        userRegistry."alice" = exampleDir + "/users/alice";
      }).options ? home-manager
    );
}
