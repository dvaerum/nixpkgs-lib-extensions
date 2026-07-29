# The standalone home configurations: real home-manager evaluation with the
# builder's defaults, shared modules, and the no-home-manager gate.
{
  lib,
  myLib,
  nixpkgs,
  inputs,
  system,
  example,
  aliceHome,
  exampleDir,
  ...
}:
{
  # no home-manager input -> no home outputs (and no error)
  homes-empty-without-home-manager =
    myLib.homeConfigurationsBuilder {
      inputs = {
        inherit nixpkgs;
        self = inputs.self;
      };
      inherit system;
      hostname = "laptop";
      userRegistry."alice" = exampleDir + "/users/alice";
    } == { };

  # the home configurations REALLY evaluate through home-manager's module
  # system (real input, not a stub), with the builder's defaults applied
  home-eval-username = aliceHome.config.home.username == "alice";
  home-eval-home-directory = aliceHome.config.home.homeDirectory == "/home/alice";
  home-eval-state-version-default = aliceHome.config.home.stateVersion == lib.trivial.release;
  # frank's home comes from the frank@* wildcard entry
  home-eval-wildcard-merge = example.homeConfigurations."frank@laptop".config.programs.git.enable;
  # homeSharedModules (set in the example) reach every home
  home-shared-modules-applied = aliceHome.config.programs.direnv.enable;
}
