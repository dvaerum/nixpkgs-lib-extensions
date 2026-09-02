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

  patched = myLib.mkNixosSystem {
    inputs = {
      inherit nixpkgs;
      self.outPath = toString ../checks/example;
    };
    system = "x86_64-linux";
    hostname = "patched";
    modules = [ ../checks/example/hosts/server/configuration.nix ];
    patches = [ markerPatch ];
    # unrelated to patching -- no users here, so this check does not pay
    # for evaluating checks/example's users tree
    users = [ ];
  };

  # A variant nixpkgs-* input must NOT be patched: a nixpkgs PR diff
  # essentially never applies to a different tree, so doing so broke the
  # variant channel lazily, far from the `patches = [ ... ]` line.
  variantUnpatched = myLib.mkNixosSystem {
    inputs = {
      inherit nixpkgs;
      nixpkgs-variant = nixpkgs;
      self.outPath = toString ../checks/example;
    };
    system = "x86_64-linux";
    hostname = "patchedvariant";
    modules = [ ../checks/example/hosts/server/configuration.nix ];
    patches = [ markerPatch ];
    users = [ ]; # see `patched` above for why
  };

  # A `patches` element that is a DIRECTORY auto-expands via
  # discoverPatches (context.nix) -- built for real (IFD), same as
  # `patched` above, to prove the expansion actually reaches
  # `applyPatches` and not just a pure-eval classification.
  patchedFromDir = myLib.mkNixosSystem {
    inputs = {
      inherit nixpkgs;
      self.outPath = toString ../checks/example;
    };
    system = "x86_64-linux";
    hostname = "patchedfromdir";
    modules = [ ../checks/example/hosts/server/configuration.nix ];
    patches = [ ../checks/fixtures/nixpkgs-patching-dir ];
    users = [ ]; # see `patched` above for why
  };

  # A `patches` directory that expands to `[ ]` (nothing applicable inside
  # it) must NOT force a patched-tree rebuild -- `selectedSrc` stays the
  # pristine input, so this needs no IFD/build at all, unlike the
  # assertions above.
  emptyDirPatched = myLib.mkNixosSystem {
    inputs = {
      inherit nixpkgs;
      self.outPath = toString ../checks/example;
    };
    system = "x86_64-linux";
    hostname = "emptydirpatched";
    modules = [ ../checks/example/hosts/server/configuration.nix ];
    patches = [ ../checks/fixtures/nixpkgs-patching-empty-dir ];
    users = [ ]; # see `patched` above for why
  };

  assertions = {
    # the system really is evaluated from the patched tree
    patches-applied = builtins.pathExists "${patched.pkgs.path}/nixpkgs-lib-extensions-test-marker";
    # ... and registry/NIX_PATH pinning follows it: on the patched route
    # (raw eval-config, lib.nixosSystem is bypassed) the builder sets
    # nixpkgs.flake.source to the PATCHED tree itself
    patched-flake-source = toString patched.config.nixpkgs.flake.source == toString patched.pkgs.path;
    # ... while the variant channel is built from the pristine one
    variant-not-patched =
      !builtins.pathExists "${variantUnpatched.config.nixpkgsLibExtensions.channels.variant.path}/nixpkgs-lib-extensions-test-marker";

    # a `patches` DIRECTORY reaches the same real, built tree as an
    # explicit patch derivation does -- not just a classification result
    directory-patch-applied = builtins.pathExists "${patchedFromDir.pkgs.path}/nixpkgs-lib-extensions-test-dir-marker";

    # a directory with nothing applicable in it does not force a rebuild:
    # `pkgs.path` stays the pristine input, comparable WITHOUT building
    # anything (identity, not content, is what's being checked here)
    empty-directory-not-patched = toString emptyDirPatched.pkgs.path == toString nixpkgs;
  };

  runner = import ./run-assertions.nix { inherit pkgs; };
in
runner.run "nixpkgs-patching-tests" assertions
