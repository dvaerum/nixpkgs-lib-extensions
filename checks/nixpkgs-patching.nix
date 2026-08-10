# The `patches` argument: a host built from a PATCHED nixpkgs source tree.
#
# Its own check, deliberately. Verifying a patch means BUILDING the patched
# nixpkgs tree during evaluation (import-from-derivation) -- a
# multi-hundred-megabyte copy. Inside checks/builders that IFD sat in front
# of all ~140 cheap assertions, in `nix flake check` and in CI's aarch64
# drvPath loop alike, so the fast eval assertions could not report until the
# copy existed. Split out, the two cache and fail independently.
#
# Pinned to x86_64-linux: the IFD must be buildable on the machine running
# the checks, so a floating system would break `--all-systems` evaluation
# for platforms this machine cannot build.
{
  pkgs,
  nixpkgs,
  myLib,
}:
let
  lib = pkgs.lib;

  markerPatch = pkgs.writeText "add-marker.patch" ''
    --- /dev/null
    +++ b/nixpkgs-lib-extensions-test-marker
    @@ -0,0 +1 @@
    +marker
  '';

  patched = myLib.nixosConfigurationsBuilder {
    inputs = {
      inherit nixpkgs;
      self.outPath = toString ../checks/example;
    };
    system = "x86_64-linux";
    hostname = "patched";
    modules = [ ../checks/example/hosts/server/configuration.nix ];
    patches = [ markerPatch ];
  };

  # A variant nixpkgs-* input must NOT be patched: a nixpkgs PR diff
  # essentially never applies to a different tree, so doing so broke
  # pkgs-unstable lazily, far from the `patches = [ ... ]` line.
  variantUnpatched = myLib.nixosConfigurationsBuilder {
    inputs = {
      inherit nixpkgs;
      nixpkgs-variant = nixpkgs;
      self.outPath = toString ../checks/example;
    };
    system = "x86_64-linux";
    hostname = "patchedvariant";
    modules = [ ../checks/example/hosts/server/configuration.nix ];
    patches = [ markerPatch ];
  };

  assertions = {
    # the system really is evaluated from the patched tree
    patches-applied = builtins.pathExists "${patched.pkgs.path}/nixpkgs-lib-extensions-test-marker";
    # ... and registry/NIX_PATH pinning follows it: on the patched route
    # (raw eval-config, lib.nixosSystem is bypassed) the builder sets
    # nixpkgs.flake.source to the PATCHED tree itself
    patched-flake-source = toString patched.config.nixpkgs.flake.source == toString patched.pkgs.path;
    # ... while the pkgs-* variant is built from the pristine one
    variant-not-patched =
      !builtins.pathExists "${variantUnpatched._module.specialArgs.pkgs-variant.path}/nixpkgs-lib-extensions-test-marker";
  };

  runner = import ./run-assertions.nix { inherit pkgs; };
in
runner.run "nixpkgs-patching-tests" assertions
