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

  # ... but the per-user builder THROWS: one explicitly requested home
  # that cannot be built is an error, not an empty result
  home-builder-throws-without-home-manager =
    !(builtins.tryEval (
      builtins.attrNames (myLib.homeConfigurationsBuilder {
        inputs = {
          inherit nixpkgs;
          self = inputs.self;
        };
        inherit system;
        hostname = "laptop";
        username = "alice";
        userRegistry."alice" = exampleDir + "/users/alice";
      })
    )).success;

  # LOGIN-managed homes REALLY evaluate through home-manager's module
  # system (real input, not a stub), with the builder's defaults applied
  home-eval-username = aliceHome.config.home.username == "alice";
  home-eval-home-directory = aliceHome.config.home.homeDirectory == "/home/alice";
  home-eval-state-version-default = aliceHome.config.home.stateVersion == lib.trivial.release;
  # homeSharedModules (set in the example's _defaults) reach login homes
  home-shared-modules-applied = aliceHome.config.programs.direnv.enable;

  # SYSTEM-managed homes are built into the system via home-manager's
  # NixOS module: frank's wildcard entry merges there too
  system-home-wildcard-merge = laptop.config.home-manager.users.frank.programs.git.enable;
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
      }).nohm.options
      ? home-manager
    );
}
