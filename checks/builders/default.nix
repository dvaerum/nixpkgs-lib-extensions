# Eval-time tests for the lib/nixos builders, run by `nix flake check`.
#
# This file is the HARNESS: it builds the shared test context (fake inputs,
# the example flake evaluated as a consumer would, helper hosts and helper
# functions) and auto-discovers the actual assertions from ./tests/*.nix.
# Each test file is a function `ctx: { <assertion-name> = <bool>; ... }`;
# adding a test area = dropping a file into tests/ (mirroring how
# lib/default.nix loads the library folders). Duplicate assertion names
# across files are an error -- a silent merge would hide a test.
#
# The configurations under test come from ../example -- a complete, worked
# consumer setup (see example/flake.nix). Because the assertions evaluate
# the example, the example is guaranteed to keep working.
#
# Uses the REAL home-manager flake input, so the home configurations are
# fully evaluated by home-manager's module system, not stubbed. Fake
# module-providing inputs stand in for flakes like disko/sops-nix/nur to
# prove the auto-collection conventions.
{
  pkgs,
  nixpkgs,
  home-manager,
  myLib,
}:
let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;

  exampleDir = ../example;
  fixturesDir = ../fixtures;
  invalidFixturesDir = ../invalid-fixtures;
  repoDir = ../..;

  # A typical module-providing input (exports `default` everywhere), which
  # also extends `lib` (like nixpkgs-lib-extensions itself would).
  fake-module-input = {
    outPath = "/nix/store/fake-module-input";
    nixosModules.default = {
      users.groups.from-input-module = { };
    };
    overlays.default = final: prev: { from-input-overlay = "yes"; };
    homeManagerModules.default = {
      home.sessionVariables.FROM_INPUT_HM = "1";
    };
    extendLib = prev: { autoExtMarker = "auto-ext-marker"; };
  };

  # An input matching NO generic convention (like fenix): it must ride along
  # unharmed and be reachable through the `inputs` specialArg. Its packages
  # are keyed both by the example's fixed system (x86_64-linux) and the
  # check's current system, so `--all-systems` evaluation finds them too.
  fake-fenix = {
    outPath = "/nix/store/fake-fenix";
    packages =
      lib.genAttrs
        (lib.unique [
          "x86_64-linux"
          system
        ])
        (_: {
          complete.withComponents = _: "fake-rust-toolchain";
        });
  };

  # NUR-shaped: nonstandard `modules.nixos`/`modules.homeManager` exports.
  # Under the key `nur` the special case normalizes them; under ANY other key
  # the same shape must be ignored (cases apply strictly by input name).
  nur-shaped = suffix: {
    outPath = "/nix/store/fake-nur-${suffix}";
    modules.nixos.default = {
      users.groups."from-${suffix}-module" = { };
    };
    modules.homeManager.default = {
      home.sessionVariables."FROM_${lib.toUpper suffix}_HM" = "1";
    };
  };

  # An input whose `nixosModules` has NO `default` and SEVERAL entries: a
  # catalog of opt-in entries (nixos-hardware style). NONE of them may be
  # auto-imported, and their values must never be forced -- real catalogs
  # contain `throw` tombstones for removed entries. Its `homeModules.default`
  # IS still auto-loaded.
  fake-multi-module-input = {
    outPath = "/nix/store/fake-multi-module-input";
    nixosModules = {
      one = {
        users.groups.multi-one = { };
      };
      two = {
        users.groups.multi-two = { };
      };
      removed-tombstone = throw "this catalog entry must never be forced";
    };
    homeModules.default = {
      home.sessionVariables.FROM_INPUT_HOME_MODULES = "1";
    };
  };

  # An input exporting `legacyPackages` (sops-nix publishes docs/packages
  # there) that is NOT a nixpkgs tree (no `lib.nixosSystem`): its
  # `nixosModules.default` must still be auto-imported. Only real nixpkgs
  # trees are excluded from the module auto-import.
  fake-sops-shaped-input = {
    outPath = "/nix/store/fake-sops-shaped-input";
    legacyPackages = { };
    nixosModules.default = {
      users.groups.from-sops-shaped-module = { };
    };
  };

  # An input exporting exactly ONE module under a name other than `default`
  # (sops-nix / plasma-manager style): unambiguous, so that entry is
  # auto-loaded despite the missing `default`.
  fake-single-module-input = {
    outPath = "/nix/store/fake-single-module-input";
    nixosModules.the-only-one = {
      users.groups.single-module = { };
    };
    homeManagerModules.the-only-one = {
      home.sessionVariables.FROM_SINGLE_HM = "1";
    };
  };

  inputs = {
    inherit nixpkgs home-manager;
    # A second package-set input: must be exposed as the `pkgs-unstable`
    # specialArg (and its helper nixosModules must NOT be auto-imported).
    nixpkgs-unstable = nixpkgs;
    inherit fake-module-input fake-multi-module-input fake-single-module-input fake-sops-shaped-input;
    fenix = fake-fenix;
    nur = nur-shaped "nur";
    not-nur = nur-shaped "notnur";
    # `self` points at the example directory, which is shaped like a real
    # consumer flake root -- so rootPath defaults (hosts/<hostname>
    # convention, flakeRef) resolve against something that exists.
    self = {
      outPath = toString exampleDir;
    };
  };

  # The example is a REAL flake.nix; a flake.nix is just an attrset with an
  # `outputs` function, so we import it and call `outputs` with our test
  # inputs -- the same way Nix itself would with the locked inputs.
  example = (import (exampleDir + "/flake.nix")).outputs (
    inputs
    // {
      # what the resolved nixpkgs-lib-extensions input looks like to a consumer
      nixpkgs-lib-extensions = {
        outPath = "/nix/store/fake-nixpkgs-lib-extensions";
        lib = myLib;
        extendLib = lib': nixpkgs.lib.recursiveUpdate lib' myLib;
      };
    }
  );

  laptop = example.nixosConfigurations.laptop;
  server = example.nixosConfigurations.server;

  aliceHome = example.homeConfigurations."alice@laptop";

  execStart = laptop.config.systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart;

  # A kitchen-sink host covering the config knobs the example doesn't use.
  custom =
    (myLib.nixosConfigurationsBuilder {
      inherit inputs system;
      hostname = "custom";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      excludeModuleInputs = [ "fake-module-input" ];
      extraOverlays = [ (final: prev: { from-extra-overlay = "yes"; }) ];
      allowedUnfreePackages = [ "allowed-unfree" ];
      tags = [ "cudaSupport" ];
      systemType = "server";
      additionalModules = [
        { users.groups.from-additional-module = { }; }
        # observable through group names: the system `lib` must carry both the
        # extension from fake-module-input's extendLib and this repo's own
        (
          { lib, ... }:
          {
            users.groups.${lib.autoExtMarker} = { };
            users.groups.${lib.stringToTitle "ext-marker"} = { };
          }
        )
      ];
      # user-supplied specialArgs override the builder-assembled ones
      specialArgs.desktopEnvironment = "gnome";
    }).custom;

  # A host built from a PATCHED nixpkgs; the marker file proves the system
  # was evaluated from the patched tree (forces building the patched source).
  markerPatch = pkgs.writeText "add-marker.patch" ''
    --- /dev/null
    +++ b/nixpkgs-lib-extensions-test-marker
    @@ -0,0 +1 @@
    +marker
  '';
  # Pinned to x86_64-linux: verifying the patch forces BUILDING the patched
  # nixpkgs tree during evaluation (IFD), which must happen on the machine
  # running the checks -- a floating system would break `--all-systems`
  # evaluation for platforms this machine cannot build.
  patched =
    (myLib.nixosConfigurationsBuilder {
      inherit inputs;
      system = "x86_64-linux";
      hostname = "patched";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      patches = [ markerPatch ];
    }).patched;

  # The bootstrap module used directly (without nixosConfigurationsBuilder);
  # `args` overrides the defaults below.
  bootstrapModuleFor =
    args:
    myLib.homeManagerBootstrapModule (
      {
        inherit inputs system;
        hostname = "laptop";
        homeConfigurations."alice" = exampleDir + "/users/alice";
      }
      // args
    );
  applyBootstrap = args: (builtins.head (bootstrapModuleFor args).imports) { inherit pkgs lib; };

  # Helper: does building home configs with this registry throw?
  homesThrow =
    registry:
    !(builtins.tryEval (
      builtins.attrNames (myLib.homeConfigurationsBuilder {
        inherit inputs system;
        hostname = "laptop";
        homeConfigurations = registry;
      })
    )).success;

  # Everything a test file may need.
  ctx = {
    inherit
      pkgs
      lib
      system
      nixpkgs
      home-manager
      myLib
      inputs
      example
      laptop
      server
      aliceHome
      execStart
      custom
      patched
      bootstrapModuleFor
      applyBootstrap
      homesThrow
      exampleDir
      fixturesDir
      invalidFixturesDir
      repoDir
      ;
  };

  # Auto-discover the test files and merge their assertion sets.
  assertionSets = map (file: import (./tests + "/${file}") ctx) (
    lib.attrNames (
      lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (builtins.readDir ./tests)
    )
  );
  assertions = lib.mergeAttrsList assertionSets;

  # a silent merge collision would hide a test
  totalDefined = lib.foldl' (sum: s: sum + lib.length (lib.attrNames s)) 0 assertionSets;

  failed = lib.attrNames (lib.filterAttrs (_: ok: ok != true) assertions);
in
if totalDefined != lib.length (lib.attrNames assertions) then
  throw "checks/builders/tests: duplicate assertion names across test files"
else if failed == [ ] then
  pkgs.runCommand "lib-nixos-builders-tests" { } "touch $out"
else
  throw "lib/nixos builder tests failed: ${lib.concatStringsSep ", " failed}"
