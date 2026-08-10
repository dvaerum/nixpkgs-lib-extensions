# Auto-loading of inputs: the generic conventions (nixosModules,
# homeManagerModules/homeModules, overlays, extendLib, nixpkgs-* package
# sets), the inputContributions forms (per-channel selections, input-level
# null, the function escape hatch) and the inputs/inputPkgs exposure.
{
  myLib,
  inputs,
  system,
  laptop,
  server,
  inputsWithSelf,
  aliceHome,
  custom,
  fake-multi-module-input,
  fake-catalog-input,
  fake-overlay-catalog,
  fake-tree-input,
  exampleDir,
  ...
}:
let
  moduleLib =
    (myLib.nixosConfigurationsBuilder {
      # inputsWithSelf, not inputs: this repo's own `extendLib` must run over
      # a lib that already holds its additions, which is the case a consumer
      # actually hits
      inputs = inputsWithSelf;
      inherit system;
      hostname = "libprobe";
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        (
          { lib, ... }:
          {
            users.groups = lib.genAttrs (
              lib.optional (lib ? buildConfigurations) "flake-buildConfigurations"
              ++ lib.optional (lib ? nixosConfigurationsBuilder) "flake-nixosConfigurationsBuilder"
              ++ lib.optional (lib.nixos ? buildConfigurations) "flake-nixos-namespace-polluted"
              ++ lib.optional (lib.nixos ? evalModules) "nixpkgs-nixos-evalModules"
              ++ lib.optional (lib ? declareZfsRootDisk) "mod-declareZfsRootDisk"
              ++ lib.optional (lib ? importIfNix) "mod-importIfNix"
              ++ lib.optional (lib ? recursiveMerge) "mod-recursiveMerge"
              ++ lib.optional (lib.attrsets ? recursiveMerge) "mod-attrsets-recursiveMerge"
              ++ lib.optional (lib.strings ? stringToTitle) "mod-strings-stringToTitle"
              ++ lib.optional (lib.attrsets ? filterAttrs) "nixpkgs-attrsets-filterAttrs"
              ++ lib.optional (lib.strings ? hasInfix) "nixpkgs-strings-hasInfix"
            ) (_: { });
          }
        )
      ];
    }).config.users.groups;

  # A minimal host whose only interesting part is its inputContributions.
  probeHost =
    hostname: extraInputs: cases:
    myLib.nixosConfigurationsBuilder {
      inputs = inputs // extraInputs;
      inherit system hostname;
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      inputContributions = cases;
    };
  # Forcing the group names reaches the auto-collection (and its throws).
  throwsGroups = sys: !(builtins.tryEval (builtins.attrNames sys.config.users.groups)).success;
in
{
  # every `nixpkgs-*` input becomes a `pkgs-*` specialArg
  pkgs-variant-exposed = laptop._module.specialArgs ? pkgs-unstable;

  auto-nixos-module-imported = laptop.config.users.groups ? from-input-module;
  # `legacyPackages` alone must not exclude an input from the module
  # auto-import (sops-nix exports it next to its real default module);
  # only nixpkgs trees (legacyPackages + lib.nixosSystem) are skipped
  legacy-packages-alone-does-not-exclude = laptop.config.users.groups ? from-sops-shaped-module;
  # a set without `default` but exactly ONE entry is unambiguous
  # (sops-nix / plasma-manager style): that entry is auto-loaded,
  # silently -- no lock-fragility warning
  single-export-without-default-imported =
    laptop.config.users.groups ? single-module
    && aliceHome.config.home.sessionVariables.FROM_SINGLE_HM == "1";
  # ... but SEVERAL entries without `default` (nixos-hardware style) is
  # ambiguous: auto-import refuses to guess and THROWS with the
  # inputContributions remedies instead of silently skipping the input
  multi-export-without-default-throws =
    !(builtins.tryEval (
      (myLib.nixosConfigurationsBuilder {
        inputs = inputs // {
          inherit fake-multi-module-input;
        };
        inherit system;
        hostname = "multithrow";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      }).config.users.groups ? multi-one
    )).success;
  # ... and the escape hatch works: opting the channel out via
  # inputContributions makes evaluation succeed with NONE of the entries
  # imported. (It says nothing about laziness -- the function form REPLACES
  # the whole export set before any decision is made. The tombstone proof
  # is channel-selection-skips-tombstone below.)
  catalog-opt-out-imports-nothing =
    let
      groups =
        (myLib.nixosConfigurationsBuilder {
          inputs = inputs // {
            inherit fake-multi-module-input;
          };
          inherit system;
          hostname = "catalogoptout";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          inputContributions."fake-multi-module-input" = _: { nixosModules = { }; };
        }).config.users.groups;
    in
    !(groups ? multi-one) && !(groups ? multi-two);
  auto-overlay-applied = laptop.pkgs ? from-input-overlay;
  auto-hm-modules-imported =
    aliceHome.config.home.sessionVariables.FROM_INPUT_HM == "1"
    && aliceHome.config.home.sessionVariables.FROM_INPUT_HOME_MODULES == "1";

  # NUR-shaped `modules.nixos`/`modules.homeManager` exports are NOT a
  # convention: nothing is imported from them, under the `nur` key or any
  # other (NUR's contribution is its overlays.default, applied by the
  # generic overlay collector; its default modules would only inject the
  # same overlay again, warning under useGlobalPkgs)
  nur-shaped-modules-not-imported =
    !(laptop.config.users.groups ? from-nur-module)
    && !(laptop.config.users.groups ? from-notnur-module)
    && !(aliceHome.config.home.sessionVariables ? FROM_NUR_HM)
    && !(aliceHome.config.home.sessionVariables ? FROM_NOTNUR_HM);

  # the home-manager input's OWN nixosModules must NOT be AUTO-imported
  # (excluded by store-path identity): the server -- no system-managed
  # homes -- has no home-manager options. The laptop has them, but only
  # because the builder imports the module DELIBERATELY for its
  # system-managed homes.
  hm-nixos-module-excluded = !(server.options ? home-manager) && laptop.options ? home-manager;

  # the whole inputs set is exposed (no per-input policy): NixOS modules
  # get it as a specialArg ...
  inputs-special-arg = laptop._module.specialArgs.inputs ? fenix;
  # ... with every input's packages pre-selected for this system, as the
  # `nixpkgsLibExtensions.inputPkgs` option (no longer a specialArg)
  input-pkgs-option =
    (laptop.config.nixpkgsLibExtensions.inputPkgs.fenix.complete.withComponents [ ])
    == "fake-rust-toolchain";
  # ... and home-manager modules via extraSpecialArgs
  inputs-reach-home-modules =
    (myLib.homeConfigurationsBuilder {
      inherit inputs system;
      hostname = "laptop";
      username = "alice";
      userRegistry."alice" = exampleDir + "/users/alice";
      homeModules = [
        (
          { inputs, ... }:
          {
            home.sessionVariables.PROBE = if inputs ? fenix then "1" else "0";
          }
        )
      ];
    }).config.home.sessionVariables.PROBE == "1";

  # lib extensions: from an input's extendLib AND this repo's own, both
  # reaching the system `lib` (see the extra.modules of `custom`)
  input-extend-lib-applied = custom.config.users.groups ? auto-ext-marker;
  own-ext-lib-in-system-lib = custom.config.users.groups ? Ext-marker;

  # `libOverlays.default` is the CANONICAL lib-contribution form: a real
  # overlay reaches the system `lib`, and one addition can reference
  # another through `final` -- which the endomorphic extendLib cannot
  # express at all
  input-lib-overlay-applied =
    (myLib.nixosConfigurationsBuilder {
      inputs = inputs // {
        overlaid = {
          outPath = "/nix/store/fake-lib-overlay-input";
          libOverlays.default = final: prev: {
            libOverlayMarker = "from-lib-overlay";
            libOverlayViaFinal = final.libOverlayMarker + "-via-final";
          };
        };
      };
      inherit system;
      hostname = "liboverlay";
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        ({ lib, ... }: { users.groups.${lib.libOverlayViaFinal} = { }; })
      ];
    }).config.users.groups ? from-lib-overlay-via-final;

  # when an input exports BOTH forms, the overlay wins and the legacy
  # extendLib is never even consulted (its value here is a throw)
  lib-overlay-preferred-over-extend-lib =
    (myLib.nixosConfigurationsBuilder {
      inputs = inputs // {
        both-forms = {
          outPath = "/nix/store/fake-both-forms-input";
          libOverlays.default = final: prev: { bothFormsMarker = "overlay-won"; };
          extendLib = throw "extendLib must not be consulted when libOverlays.default exists";
        };
      };
      inherit system;
      hostname = "bothforms";
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        ({ lib, ... }: { users.groups.${lib.bothFormsMarker} = { }; })
      ];
    }).config.users.groups ? overlay-won;

  # ... and both forms answer to the ONE `extendLib` channel of
  # inputContributions: opting it out drops the overlay too
  lib-overlay-respects-channel-opt-out =
    (myLib.nixosConfigurationsBuilder {
      inputs = inputs // {
        overlaid = {
          outPath = "/nix/store/fake-lib-overlay-input";
          libOverlays.default = final: prev: { libOverlayMarker = "from-lib-overlay"; };
        };
      };
      inherit system;
      hostname = "liboverlayoff";
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        ({ lib, ... }: {
          users.groups.${if lib ? libOverlayMarker then "has-marker" else "no-marker"} = { };
        })
      ];
      inputContributions."overlaid".extendLib = null;
    }).config.users.groups ? no-marker;

  # an input's standalone `lib` export is namespaced by input name into
  # the module-arg lib ...
  input-lib-namespaced-in-module-lib =
    (myLib.nixosConfigurationsBuilder {
      inherit inputs system;
      hostname = "libprobe";
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        ({ lib, ... }: { users.groups.${lib.fake-module-input.probeGroup} = { }; })
      ];
    }).config.users.groups ? from-lib-probe;

  # ... and into pkgs.lib; nixpkgs trees are NOT namespaced (their lib
  # IS the base)
  input-lib-namespaced-in-pkgs-lib =
    laptop.pkgs.lib.fake-module-input.probeGroup == "from-lib-probe"
    && !(laptop.pkgs.lib ? nixpkgs-unstable);

  # ... and home-manager modules see it too (via the context lib)
  input-lib-reaches-home-modules =
    (myLib.homeConfigurationsBuilder {
      inherit inputs system;
      hostname = "laptop";
      username = "alice";
      userRegistry."alice" = exampleDir + "/users/alice";
      homeModules = [
        (
          { lib, ... }:
          {
            home.sessionVariables.LIB_PROBE = lib.fake-module-input.probeGroup;
          }
        )
      ];
    }).config.home.sessionVariables.LIB_PROBE == "from-lib-probe";

  # overwrite detection: the input named `strings` collides with
  # lib.strings -- a namespace this repo does NOT own -- so its lib
  # export is skipped (warning) and the base lib survives untouched
  input-lib-collision-skipped =
    laptop.pkgs.lib.strings ? concatStringsSep && !(laptop.pkgs.lib.strings ? hijacked);

  # ... but the input named `disko` hits a namespace this repo OWNS:
  # its lib MERGES in -- our declareZfsRootDisk wins the key conflict,
  # the input's own helper is added next to it
  input-lib-owned-namespace-merged =
    builtins.isFunction laptop.pkgs.lib.disko.declareZfsRootDisk
    && laptop.pkgs.lib.disko.probeHelper == "disko-lib-helper";

  # the consuming flake's own lib (inputs.self) surfaces renamed:
  # lib.flake, never lib.self
  self-lib-renamed-to-flake =
    laptop.pkgs.lib.flake.selfHelper == "from-self-lib" && !(laptop.pkgs.lib ? self);

  # ... but an explicit input actually NAMED `flake` claims the name:
  # its lib wins, self's lib is dropped (with a warning), never merged
  explicit-flake-input-wins-over-self-lib =
    let
      pkgsLib =
        (myLib.nixosConfigurationsBuilder {
          inherit system;
          inputs = inputs // {
            flake = {
              outPath = "/nix/store/fake-flake-input";
              lib.marker = "explicit";
            };
          };
          hostname = "flakeclaim";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        }).pkgs.lib;
    in
    pkgsLib.flake.marker == "explicit" && !(pkgsLib.flake ? selfHelper);

  # ── nixpkgs trees: each channel treats them differently, ON PURPOSE ──
  # (see the autoOverlays comment in lib/nixos/internal/context.nix; these
  # three assertions exist so nobody "fixes" the asymmetry for symmetry)

  # a tree's MODULES are skipped -- even a sole unambiguous entry, which the
  # single-export rule would otherwise auto-import
  tree-modules-skipped =
    !((probeHost "treeprobe" { inherit fake-tree-input; } { }).config.users.groups ? from-tree-module);
  # its LIB is not namespaced: a tree's lib IS the base lib
  tree-lib-not-namespaced =
    !((probeHost "treelib" { inherit fake-tree-input; } { }).pkgs.lib ? fake-tree-input);
  # but its OVERLAY *is* applied: a fork exporting `overlays.default`
  # deliberately means it to be
  tree-overlay-applied =
    (probeHost "treeoverlay" { inherit fake-tree-input; } { }).pkgs ? from-tree-overlay;

  # ── inputContributions: per-channel selections ──

  # selecting NOTHING for a channel is the per-input opt-out (the `custom`
  # host switches fake-module-input's nixosModules off this way)
  channel-selection-none-excludes = !(custom.config.users.groups ? from-input-module);

  # naming entries takes exactly those -- SEVERAL of them, which the
  # `default`-or-sole-entry rule cannot express at all
  channel-selection-named-entries =
    let
      groups =
        (probeHost "selnamed" { inherit fake-catalog-input; } {
          "fake-catalog-input".nixosModules = [
            "alpha"
            "beta"
          ];
        }).config.users.groups;
    in
    groups ? catalog-alpha && groups ? catalog-beta;

  # ... and leaves the unnamed ones out
  channel-selection-subset =
    let
      groups =
        (probeHost "selsubset" { inherit fake-catalog-input; } {
          "fake-catalog-input".nixosModules = [ "beta" ];
        }).config.users.groups;
    in
    groups ? catalog-beta && !(groups ? catalog-alpha);

  # "*" takes every entry
  channel-selection-star-takes-all =
    let
      groups =
        (probeHost "selstar" { inherit fake-catalog-input; } {
          "fake-catalog-input".nixosModules = "*";
        }).config.users.groups;
    in
    groups ? catalog-alpha && groups ? catalog-beta;

  # the list ORDER is the auto-import order: both of this catalog's overlays
  # write `catalogOrder`, so whichever is selected LAST wins
  channel-selection-order-preserved =
    (probeHost "selorder" { inherit fake-overlay-catalog; } {
      "fake-overlay-catalog".overlays = [
        "first"
        "second"
      ];
    }).pkgs.catalogOrder == "second"
    &&
      (probeHost "selorderrev" { inherit fake-overlay-catalog; } {
        "fake-overlay-catalog".overlays = [
          "second"
          "first"
        ];
      }).pkgs.catalogOrder == "first";

  # a selection never forces the entries it did NOT pick -- real catalogs
  # carry `throw` tombstones for removed ones
  channel-selection-skips-tombstone =
    (probeHost "seltombstone" { inherit fake-multi-module-input; } {
      "fake-multi-module-input".nixosModules = [ "one" ];
    }).config.users.groups ? multi-one;

  # an explicit selection overrides a built-in skip: home-manager's NixOS
  # module is normally kept out of the auto-collected set (by store-path
  # identity), but naming it is the opposite of a guess
  selection-overrides-builtin-skip =
    (probeHost "hmselected" { } {
      "home-manager".nixosModules = [ "default" ];
    }).options ? home-manager;

  # input-level `null`: the input contributes NOTHING, on every channel --
  # modules, overlays, extendLib and its namespaced lib
  input-level-null-kills-every-channel =
    let
      sys = probeHost "nullcase" { } { "fake-module-input" = null; };
      home = myLib.homeConfigurationsBuilder {
        inherit inputs system;
        hostname = "laptop";
        username = "alice";
        userRegistry."alice" = exampleDir + "/users/alice";
        inputContributions."fake-module-input" = null;
      };
    in
    !(sys.config.users.groups ? from-input-module)
    && !(sys.pkgs ? from-input-overlay)
    && !(sys.pkgs.lib ? autoExtMarker)
    && !(sys.pkgs.lib ? fake-module-input)
    && !(home.config.home.sessionVariables ? FROM_INPUT_HM);

  # an input whose `lib` THROWS must not take the whole host with it: it is
  # simply not namespaced. `v.lib or { }` did not cover this -- `or` catches
  # a MISSING attribute, while `?` forces the value.
  throwing-lib-input-tolerated =
    let
      sys = myLib.nixosConfigurationsBuilder {
        inputs = inputs // {
          badlib = {
            outPath = "/nix/store/fake-badlib";
            legacyPackages = { };
            lib = throw "this input's lib must not break every host";
            nixosModules.default = {
              users.groups.from-badlib = { };
            };
          };
        };
        inherit system;
        hostname = "badlibprobe";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      };
    in
    !(sys.pkgs.lib ? badlib) && sys.config.users.groups ? from-input-module;

  # ── validation: every typo fails loudly instead of quietly doing nothing ──

  channel-selection-unknown-entry-throws = throwsGroups (
    probeHost "selbadentry" { inherit fake-catalog-input; } {
      "fake-catalog-input".nixosModules = [
        "alpha"
        "nope"
      ];
    }
  );
  channel-selection-unknown-channel-throws = throwsGroups (
    # nixosModule, not nixosModules
    probeHost "selbadchannel" { inherit fake-catalog-input; } {
      "fake-catalog-input".nixosModule = null;
    }
  );
  # a bare entry name is not a selection: only a list or `"*"`
  channel-selection-bad-value-throws = throwsGroups (
    probeHost "selbadvalue" { inherit fake-catalog-input; } {
      "fake-catalog-input".nixosModules = "alpha";
    }
  );
  # a case keyed by an input that does not exist would silently do nothing
  input-special-cases-unknown-input-throws = throwsGroups (
    probeHost "selbadinput" { } { "no-such-input".overlays = null; }
  );
  # extendLib/lib hold ONE value: there is nothing to name in them
  single-value-channel-selection-throws = throwsGroups (
    probeHost "selsinglebad" { } { "fake-module-input".extendLib = [ "default" ]; }
  );
  # ... and that check must not hide behind "does this input even export
  # extendLib?" -- `fenix` exports none, so a guard in the wrong order would
  # drop the malformed selection silently
  single-value-selection-checked-without-export = throwsGroups (
    probeHost "selsinglenoexport" { } { "fenix".extendLib = [ "default" ]; }
  );
  # a list must hold entry NAMES; anything else used to die in string
  # interpolation with an uncatchable coercion error
  channel-selection-non-string-entry-throws = throwsGroups (
    probeHost "selnonstring" { inherit fake-catalog-input; } {
      "fake-catalog-input".nixosModules = [ 1 ];
    }
  );
  # a typo is validated EAGERLY, even for a channel this host never
  # collects: `probeHost` has no userRegistry, so no system-managed homes
  # exist and autoHomeModules is never consumed -- the selection must still
  # be checked, because the docs promise every typo fails loudly
  channel-selection-validated-when-channel-unused = throwsGroups (
    probeHost "selunused" { } { "fake-module-input".homeModules = [ "nope" ]; }
  );

  # ── inputContributions: the function escape hatch ──

  # consumer-provided cases extend the built-in table: the
  # nur-shaped `not-nur` input can be normalized onto the conventions ...
  input-special-cases-consumer =
    (myLib.nixosConfigurationsBuilder {
      inherit inputs system;
      hostname = "scprobe";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      inputContributions."not-nur" = v: { nixosModules = v.modules.nixos or { }; };
    }).config.users.groups ? from-notnur-module;
  # ... and the function form ALSO overrides the built-in skips, exactly as
  # a named selection does. Without that, remapping a nixpkgs-TREE-shaped
  # distribution flake (nixos-raspberrypi and friends: legacyPackages +
  # lib.nixosSystem, modules under a nonstandard path) applied the remap and
  # then silently discarded the result -- the documented escape hatch
  # evaluating, building and booting without the modules it was written for.
  input-special-cases-function-overrides-skip =
    (myLib.nixosConfigurationsBuilder {
      inputs = inputs // {
        distro = {
          outPath = "/nix/store/fake-distro";
          legacyPackages = { };
          lib.nixosSystem = _: { };
          modules.nixos.default = {
            users.groups.from-remapped-tree = { };
          };
        };
      };
      inherit system;
      hostname = "treeremap";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      inputContributions."distro" = v: { nixosModules = v.modules.nixos; };
    }).config.users.groups ? from-remapped-tree;

  # ... and double as the per-input opt-out for any channel
  input-special-cases-opt-out =
    !(
      (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "scoptout";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        inputContributions."fake-module-input" = _: { nixosModules = { }; };
      }).config.users.groups ? from-input-module
    );

  # the homeManager argument bypasses capability detection (here with a
  # second home-manager-shaped input present, which detection would have
  # had to warn about)
  home-manager-explicit-override =
    (myLib.homeConfigurationsBuilder {
      inputs = inputs // {
        zz-hm-clone = inputs.home-manager;
      };
      inherit system;
      hostname = "laptop";
      username = "alice";
      userRegistry."alice" = exampleDir + "/users/alice";
      homeManager = inputs.home-manager;
    }).config.home.username == "alice";

  # ── module-level vs flake-level lib ──
  # What a MODULE's `lib` argument holds. Not `pkgs.lib`, which is a
  # different value (nixpkgs' own lib plus the namespaced input libs, see
  # the overlay in context.nix) -- so this probes it where modules see it.
  # The `nixos` namespace builds SYSTEMS; a module is already inside one.
  # It used to be merged into the module `lib` anyway, so every NixOS and
  # home-manager module carried lib.buildConfigurations and friends.
  module-lib-omits-flake-level-api =
    !(moduleLib ? flake-buildConfigurations)
    && !(moduleLib ? flake-nixosConfigurationsBuilder)
    # nixpkgs has its OWN `lib.nixos` (evalModules and friends). This repo's
    # `nixos` namespace used to be recursiveUpdate'd straight into it.
    && !(moduleLib ? flake-nixos-namespace-polluted)
    && moduleLib ? nixpkgs-nixos-evalModules;

  # ... while the module-level helpers are still there, both flat and in
  # their namespace, and joining a namespace nixpkgs also defines does not
  # displace what nixpkgs put in it
  module-lib-keeps-module-level-helpers =
    moduleLib ? mod-declareZfsRootDisk
    && moduleLib ? mod-importIfNix
    && moduleLib ? mod-recursiveMerge
    && moduleLib ? mod-attrsets-recursiveMerge
    && moduleLib ? mod-strings-stringToTitle
    && moduleLib ? nixpkgs-attrsets-filterAttrs
    && moduleLib ? nixpkgs-strings-hasInfix;

  # the flake-level half is reachable from a module through the specialArg,
  # which is what it is for
  ext-lib-special-arg-has-flake-level-api =
    laptop._module.specialArgs.extLib ? buildConfigurations
    && laptop._module.specialArgs.extLib ? nixosConfigurationsBuilder;
}
