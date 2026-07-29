# Auto-loading of inputs: the generic conventions (nixosModules,
# homeManagerModules/homeModules, overlays, extendLib, nixpkgs-* package
# sets), the keyed special cases (nur), and the inputs/inputPkgs exposure.
{
  myLib,
  inputs,
  system,
  laptop,
  server,
  aliceHome,
  custom,
  fake-multi-module-input,
  exampleDir,
  ...
}:
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
  # inputSpecialCases remedies instead of silently skipping the input
  multi-export-without-default-throws =
    !(builtins.tryEval (
      (myLib.nixosConfigurationsBuilder {
        inputs = inputs // { inherit fake-multi-module-input; };
        inherit system;
        hostname = "multithrow";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      }).config.users.groups
      ? multi-one
    )).success;
  # ... and the escape hatch works: opting the channel out via
  # inputSpecialCases makes evaluation succeed with NONE of the entries
  # imported -- which also proves the catalog's `throw` tombstone entry
  # is never forced (the decision reads attrNames only)
  catalog-opt-out-imports-nothing =
    let
      groups =
        (myLib.nixosConfigurationsBuilder {
          inputs = inputs // { inherit fake-multi-module-input; };
          inherit system;
          hostname = "catalogoptout";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          inputSpecialCases."fake-multi-module-input" = _: { nixosModules = { }; };
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
  # ... with every input's packages pre-selected for this system
  input-pkgs-special-arg =
    (laptop._module.specialArgs.inputPkgs.fenix.complete.withComponents [ ]) == "fake-rust-toolchain";
  # ... and home-manager modules via extraSpecialArgs
  inputs-reach-home-modules =
    (myLib.homeConfigurationsBuilder {
      inherit inputs system;
      hostname = "laptop";
      username = "alice";
      userRegistry."alice" = exampleDir + "/users/alice";
      homeSharedModules = [
        (
          { inputs, ... }:
          {
            home.sessionVariables.PROBE = if inputs ? fenix then "1" else "0";
          }
        )
      ];
    }).config.home.sessionVariables.PROBE == "1";

  # lib extensions: from an input's extendLib AND this repo's own, both
  # reaching the system `lib` (see the additionalModules of `custom`)
  input-extend-lib-applied = custom.config.users.groups ? auto-ext-marker;
  own-ext-lib-in-system-lib = custom.config.users.groups ? Ext-marker;

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
      homeSharedModules = [
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

  # auto-collection can be opted out per input name
  exclude-module-inputs-respected = !(custom.config.users.groups ? from-input-module);

  # consumer-provided inputSpecialCases extend the built-in table: the
  # nur-shaped `not-nur` input can be normalized onto the conventions ...
  input-special-cases-consumer =
    (myLib.nixosConfigurationsBuilder {
      inherit inputs system;
      hostname = "scprobe";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      inputSpecialCases."not-nur" = v: { nixosModules = v.modules.nixos or { }; };
    }).config.users.groups ? from-notnur-module;
  # ... and double as the per-input opt-out for any channel
  input-special-cases-opt-out =
    !(
      (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "scoptout";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        inputSpecialCases."fake-module-input" = _: { nixosModules = { }; };
      }).config.users.groups
      ? from-input-module
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
}
