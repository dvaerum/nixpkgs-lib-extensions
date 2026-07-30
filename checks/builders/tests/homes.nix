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
        loginUsers = [ "alice" ];
      };
    } == { };

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
          loginUsers = [ "alice" ];
        };
      }
    ) == [ "alice@laptop" ];

  # ... but the per-user builder THROWS: one explicitly requested home
  # that cannot be built is an error, not an empty result
  home-builder-throws-without-home-manager =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.homeConfigurationsBuilder {
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
  home-eval-state-version-default = aliceHome.config.home.stateVersion == lib.trivial.release;
  # homeSharedModules (set in the example's _defaults) reach login homes
  home-shared-modules-applied = aliceHome.config.programs.direnv.enable;

  # ... and throws when the matched registry entries ship no home.nix at
  # all (eve is a system-only user: configuration.nix, no home.nix)
  home-builder-throws-without-home-nix =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.homeConfigurationsBuilder {
          inherit inputs system;
          hostname = "laptop";
          username = "eve";
          userRegistry."eve" = exampleDir + "/users/eve";
        }
      )
    )).success;

  # login homes get `username` and `listOfUsernames` as module arguments
  # (via extraSpecialArgs)
  username-reaches-login-homes =
    let
      probe = myLib.homeConfigurationsBuilder {
        inherit inputs system;
        hostname = "laptop";
        username = "alice";
        userRegistry = {
          "alice" = exampleDir + "/users/alice";
          "dave" = exampleDir + "/users/dave";
        };
        homeSharedModules = [
          (
            { username, listOfUsernames, ... }:
            {
              home.sessionVariables.WHOAMI = username;
              home.sessionVariables.ALL_USERS = builtins.concatStringsSep "," listOfUsernames;
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
    !(myLib.nixosConfigurationsBuilder {
      inherit inputs system;
      hostname = "hmopts";
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        { home-manager.useGlobalPkgs = false; }
      ];
      userRegistry."dave" = exampleDir + "/users/dave";
    }).config.home-manager.useGlobalPkgs;
  # each system home gets home.stateVersion defaulted to the CURRENT
  # nixpkgs release (dave's home.nix does not pin one)
  system-home-state-version-default =
    laptop.config.home-manager.users.dave.home.stateVersion == lib.trivial.release;
  # `username` reaches system homes as a module argument too
  # (extraSpecialArgs cannot vary per user; _module.args can)
  username-reaches-system-homes =
    (myLib.nixosConfigurationsBuilder {
      inherit inputs system;
      hostname = "whoami";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      userRegistry."dave" = exampleDir + "/users/dave";
      homeSharedModules = [
        ({ username, ... }: { home.sessionVariables.WHOAMI = username; })
      ];
    }).config.home-manager.users.dave.home.sessionVariables.WHOAMI == "dave";
  # ... homeSharedModules reach system homes as well
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
      (myLib.nixosConfigurationsBuilder {
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
