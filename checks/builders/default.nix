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
    homeModules.default = {
      home.sessionVariables.FROM_INPUT_HM = "1";
    };
    libOverlays.default = final: prev: { autoExtMarker = "auto-ext-marker"; };
    # a standalone `lib` export (NixVirt style): must appear namespaced,
    # as lib.fake-module-input.* / pkgs.lib.fake-module-input.*
    lib.probeGroup = "from-lib-probe";
  };

  # An input named after a lib attribute this repo does NOT own (nixpkgs'
  # `strings`): overwrite detection must SKIP namespacing its `lib` export
  # (with a warning) so nothing in the base lib is ever touched. NOT part
  # of the shared `inputs` set: the warning it provokes would fire on
  # EVERY harness evaluation and drown the CI log in noise -- the
  # collision test threads it in via ctx for one dedicated builder call
  # (like fake-multi-module-input), so a plain probe host evaluates
  # without provoked warnings.
  fake-strings-collision = {
    outPath = "/nix/store/fake-strings-collision";
    lib.hijacked = true;
  };

  # An input named after a namespace this repo OWNS (`disko`, like the
  # real disko flake): its lib export MERGES into the namespace -- our
  # functions win every conflict, the input only adds what is new.
  fake-disko-input = {
    outPath = "/nix/store/fake-disko-input";
    lib = {
      probeHelper = "disko-lib-helper";
      # same name as our function: the existing side must win
      declareZfsRootDisk = "hijack-attempt";
    };
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
  # Ignored under EVERY key, `nur` included: modules.* is not a convention
  # (NUR contributes via overlays.default like any other input).
  nur-shaped = suffix: {
    outPath = "/nix/store/fake-nur-${suffix}";
    modules.nixos.default = {
      users.groups."from-${suffix}-module" = { };
    };
    modules.homeManager.default = {
      home.sessionVariables."FROM_${lib.toUpper suffix}_HM" = "1";
    };
  };

  # An input whose `nixosModules` has NO `default` and SEVERAL entries
  # (nixos-hardware style): auto-import refuses to guess and THROWS with
  # instructions, and the entries' values must never be forced -- real
  # catalogs contain `throw` tombstones for removed entries. NOT part of
  # the shared `inputs` set (it would make every harness evaluation
  # throw); the auto-loading tests thread it in via ctx for dedicated
  # builder calls.
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
  };

  # A multi-entry module catalog WITHOUT any `throw` tombstone, so `"*"`
  # (take everything) is a legal selection for it. Like
  # fake-multi-module-input it stays out of the shared `inputs` set --
  # without a selection it would throw for every host -- and is threaded in
  # via ctx. It exports NOTHING but nixosModules, so a test can select that
  # channel without having to opt out of another catalog in the same input.
  fake-catalog-input = {
    outPath = "/nix/store/fake-catalog-input";
    nixosModules = {
      alpha = {
        users.groups.catalog-alpha = { };
      };
      beta = {
        users.groups.catalog-beta = { };
      };
    };
  };

  # The same, for overlays: both entries write the same attribute, which is
  # how selection ORDER is observed (the last one selected wins).
  fake-overlay-catalog = {
    outPath = "/nix/store/fake-overlay-catalog";
    overlays = {
      first = final: prev: { catalogOrder = "first"; };
      second = final: prev: { catalogOrder = "second"; };
    };
  };

  # An input exporting home modules ONLY under the pre-flake-convention
  # `homeManagerModules` name, which this library does not read: it must
  # contribute NOTHING, and the export must never be forced (its value here
  # is a throw, so merely probing it would take the harness down).
  fake-home-modules-input = {
    outPath = "/nix/store/fake-home-modules-input";
    homeManagerModules = throw "`homeManagerModules` is not a collection convention and must never be consulted";
  };

  # A nixpkgs-TREE-shaped input (legacyPackages + lib.nixosSystem, like a
  # nixpkgs fork or a distribution flake such as nixos-raspberrypi) that also
  # exports an overlay and a module. The three channels treat it differently
  # ON PURPOSE -- see the autoOverlays comment in lib/nixos/internal/context.nix
  # -- and the tree-* assertions pin each of them.
  fake-tree-input = {
    outPath = "/nix/store/fake-tree-input";
    legacyPackages = { };
    lib = {
      nixosSystem = _: { };
      treeHelper = "from-tree-lib";
    };
    overlays.default = final: prev: { from-tree-overlay = "yes"; };
    # a SOLE entry, so the "unambiguous single export" rule would auto-import
    # it if trees were not skipped for modules
    nixosModules.helper = {
      users.groups.from-tree-module = { };
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
  # auto-loaded silently despite the missing `default`.
  fake-single-module-input = {
    outPath = "/nix/store/fake-single-module-input";
    nixosModules.the-only-one = {
      users.groups.single-module = { };
    };
    homeModules.the-only-one = {
      home.sessionVariables.FROM_SINGLE_HM = "1";
    };
  };

  inputs = {
    inherit nixpkgs home-manager;
    # A second package-set input: must surface as the `channels.unstable`
    # option (and its helper nixosModules must NOT be auto-imported).
    nixpkgs-unstable = nixpkgs;
    inherit
      fake-module-input
      fake-home-modules-input
      fake-single-module-input
      fake-sops-shaped-input
      ;
    disko = fake-disko-input;
    fenix = fake-fenix;
    nur = nur-shaped "nur";
    not-nur = nur-shaped "notnur";
    # `self` points at the example directory, which is shaped like a real
    # consumer flake root -- so rootPath defaults (hosts/<hostname>
    # convention, flakeRef) resolve against something that exists. Its
    # `lib` export must surface renamed, as lib.flake (never lib.self).
    self = {
      outPath = toString exampleDir;
      lib.selfHelper = "from-self-lib";
    };
  };

  # The example is a REAL flake.nix; a flake.nix is just an attrset with an
  # `outputs` function, so we import it and call `outputs` with our test
  # inputs -- the same way Nix itself would with the locked inputs.
  moduleLevel = import (repoDir + "/lib/nixos/internal/module-level.nix") {
    lib = nixpkgs.lib;
    self = myLib;
  };

  # What the resolved nixpkgs-lib-extensions input looks like to a consumer.
  # It mirrors flake.nix exactly, through the same shared rule: a fixture that
  # merged differently from the real export would test a setup nobody has.
  ownLibAdditions = moduleLevel.addOwnLib nixpkgs.lib myLib;
  selfLibOverlay =
    final: prev:
    nixpkgs.lib.recursiveUpdate ownLibAdditions (builtins.intersectAttrs ownLibAdditions prev);
  selfInput = {
    outPath = "/nix/store/fake-nixpkgs-lib-extensions";
    lib = myLib;
    libOverlays.default = selfLibOverlay;
  };

  # Every host in the suite sees this repo as one of its own inputs, exactly
  # as a consumer's does. That matters: the builders merge this repo's lib
  # additions themselves AND then run every input's lib overlay, so leaving
  # the self-input out of a probe host hid a double-application bug that
  # fired for real consumers.
  inputsWithSelf = inputs // {
    nixpkgs-lib-extensions = selfInput;
  };

  example = (import (exampleDir + "/flake.nix")).outputs inputsWithSelf;

  laptop = example.nixosConfigurations.laptop;
  server = example.nixosConfigurations.server;

  aliceHome = example.homeConfigurations."alice@laptop";

  execStart = laptop.config.systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart;

  # A kitchen-sink host covering the config knobs the example doesn't use.
  custom = myLib.mkNixosSystem {
    inherit inputs system;
    hostname = "custom";
    # a DIRECT builder call takes the merged arguments -- there is no
    # `extra` slot here, that is a hosts-attrset key resolved by planHosts
    modules = [
      (exampleDir + "/hosts/server/configuration.nix")
      { users.groups.from-additional-module = { }; }
      # observable through group names: the system `lib` must carry both the
      # extension from fake-module-input's lib overlay and this repo's own
      (
        { lib, ... }:
        {
          users.groups.${lib.autoExtMarker} = { };
          users.groups.${lib.stringToTitle "ext-marker"} = { };
        }
      )
    ];
    # selecting NOTHING for a channel is the per-input opt-out
    inputContributions."fake-module-input".nixosModules = null;
    overlays = [ (final: prev: { from-extra-overlay = "yes"; }) ];
    allowedUnfreePackages = [ "allowed-unfree" ];
    tags = [ "kitchen-sink" ];
    nixpkgsConfig.cudaSupport = true;
    group = "server";
    # user-supplied specialArgs ride alongside the builder-assembled ones;
    # a builder-OWNED name throws instead (special-args-shadow-throws)
    specialArgs.probeArg = "from-special-args";
  };

  # The bootstrap module used directly (without mkNixosSystem);
  # `args` overrides the defaults below.
  bootstrapModuleFor =
    args:
    myLib.homeManagerBootstrapModule (
      {
        inherit inputs system;
        hostname = "laptop";
        userRegistry."alice" = exampleDir + "/users/alice";
        loginHomes = [ "alice" ];
      }
      // args
    );
  # The inner module takes the NixOS `utils` module argument (for
  # escapeSystemdExecArgs); applying it by hand means providing the real
  # one -- imported from the nixpkgs under test, so the escaping asserted
  # below is the escaping production gets. `config` is only read lazily by
  # utils helpers this module never calls.
  nixosUtils = import (nixpkgs.outPath + "/nixos/lib/utils.nix") {
    inherit lib pkgs;
    config = { };
  };
  applyBootstrap =
    args:
    (builtins.head (bootstrapModuleFor args).imports) {
      inherit pkgs lib;
      utils = nixosUtils;
    };

  # ONE shared context core for the many probe hosts whose CORE arguments
  # are exactly `inherit inputs system;` -- the same sharing planHosts
  # gives hosts agreeing on `_defaults`. Each direct mkNixosSystem call
  # otherwise pays its own nixpkgs evaluation, which dominated this
  # check's eval time. mkProbeSystem still validates like the public
  # wrapper; a probe overriding ANY core argument (inputs, overlays,
  # nixpkgsConfig, inputContributions, ...) must keep calling
  # myLib.mkNixosSystem, which computes a matching core itself. The guard
  # below ENFORCES that: the pre-built core would win over such an
  # override, so the argument would look applied and silently not be.
  sharedInternal = import (repoDir + "/lib/nixos/internal/shared.nix") {
    inherit lib;
    self = myLib;
  };
  # exported via ctx so the negative test can pin the ambiguous-export
  # throw's text -- tryEval discards throw messages, like the other
  # harness-error assertions
  inherit (sharedInternal) ambiguousExportMessage;
  probeCore = sharedInternal.mkContextCore { inherit inputs system; };
  # exported via ctx so the negative test can pin the text -- tryEval
  # discards throw messages, like the other harness-error assertions
  probeCoreOverrideMessage =
    names:
    "mkProbeSystem shares one context core; probe overrides core argument(s) "
    + lib.concatStringsSep ", " names
    + " -- use myLib.mkNixosSystem directly";
  mkProbeSystem =
    args:
    let
      # `inputs`/`system` are core arguments mkSystem itself also reads, so
      # every probe passes them; the SHARED values are the arrangement,
      # anything else is an override the shared core would discard
      overridden = builtins.filter (
        n:
        builtins.hasAttr n args
        && !(n == "inputs" && args.inputs == inputs)
        && !(n == "system" && args.system == system)
      ) sharedInternal.coreArgNames;
    in
    if overridden != [ ] then
      throw (probeCoreOverrideMessage overridden)
    else
      sharedInternal.mkSystem probeCore (sharedInternal.validateBuilderArgs "mkProbeSystem" [ ] args);

  # The example's user set, derived from its registry: the canonical list
  # the option-value assertions compare against (shared here so no test
  # file keeps a drifting private copy).
  exampleUsers = [
    "alice"
    "bob"
    "dave"
    "eve"
    "frank"
    "grace"
  ];

  # Helper: does building home configs with this registry throw? The
  # entry under test is keyed `bad` and listed in loginHomes, so the
  # throw path (resolving `bad`'s home.nix) is reached by intent, not
  # by incidental strictness of the hosts-level plumbing.
  homesThrow =
    registry:
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.buildHomeConfigurations {
          laptop = {
            inherit inputs system;
            userRegistry = registry;
            loginHomes = [ "bad" ];
          };
        }
      )
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
      bootstrapModuleFor
      applyBootstrap
      homesThrow
      mkProbeSystem
      probeCoreOverrideMessage
      ambiguousExportMessage
      exampleUsers
      fake-strings-collision
      fake-multi-module-input
      fake-catalog-input
      fake-overlay-catalog
      fake-tree-input
      inputsWithSelf
      exampleDir
      fixturesDir
      invalidFixturesDir
      repoDir
      ;
  };

  # Auto-discover the test files and merge their assertion sets.
  assertionSets = map (file: import (./tests + "/${file}") ctx) (
    lib.attrNames (
      lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
        builtins.readDir ./tests
      )
    )
  );
  assertions = lib.mergeAttrsList assertionSets;

  # a silent merge collision would hide a test
  totalDefined = lib.foldl' (sum: s: sum + lib.length (lib.attrNames s)) 0 assertionSets;

  runner = import ../run-assertions.nix { inherit pkgs; };
in
if totalDefined != lib.length (lib.attrNames assertions) then
  throw "checks/builders/tests: duplicate assertion names across test files"
else
  runner.run "lib-nixos-builders-tests" assertions
