# Auto-loading of inputs: the generic conventions (nixosModules,
# homeManagerModules/homeModules, overlays, extendLib, nixpkgs-* package
# sets), the keyed special cases (nur), and the inputs/inputPkgs exposure.
{
  myLib,
  inputs,
  system,
  laptop,
  aliceHome,
  custom,
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
  # (sops-nix / plasma-manager style): that entry is auto-loaded
  single-export-without-default-imported =
    laptop.config.users.groups ? single-module
    && aliceHome.config.home.sessionVariables.FROM_SINGLE_HM == "1";
  # ... but SEVERAL entries without `default` is a catalog of opt-in
  # entries (nixos-hardware style) and contributes nothing -- evaluating
  # the host also proves the catalog's `throw` tombstone is never forced
  no-default-catalog-not-imported =
    !(laptop.config.users.groups ? multi-one) && !(laptop.config.users.groups ? multi-two);
  auto-overlay-applied = laptop.pkgs ? from-input-overlay;
  auto-hm-modules-imported =
    aliceHome.config.home.sessionVariables.FROM_INPUT_HM == "1"
    && aliceHome.config.home.sessionVariables.FROM_INPUT_HOME_MODULES == "1";

  # the `nur` special case normalizes modules.nixos / modules.homeManager ...
  nur-special-case-nixos-module = laptop.config.users.groups ? from-nur-module;
  nur-special-case-home-module = aliceHome.config.home.sessionVariables.FROM_NUR_HM == "1";
  # ... but ONLY for the input named `nur`: the same shape under another
  # key is not touched
  nur-special-case-is-name-scoped =
    !(laptop.config.users.groups ? from-notnur-module)
    && !(aliceHome.config.home.sessionVariables ? FROM_NOTNUR_HM);

  # the home-manager input's OWN nixosModules must NOT be auto-imported
  # (it is used standalone; excluded by store-path identity)
  hm-nixos-module-excluded = !(laptop.options ? home-manager);

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
      homeConfigurations."alice" = exampleDir + "/users/alice";
      homeSharedModules = [
        (
          { inputs, ... }:
          {
            home.sessionVariables.PROBE = if inputs ? fenix then "1" else "0";
          }
        )
      ];
    })."alice@laptop".config.home.sessionVariables.PROBE == "1";

  # lib extensions: from an input's extendLib AND this repo's own, both
  # reaching the system `lib` (see the additionalModules of `custom`)
  input-extend-lib-applied = custom.config.users.groups ? auto-ext-marker;
  own-ext-lib-in-system-lib = custom.config.users.groups ? Ext-marker;

  # auto-collection can be opted out per input name
  exclude-module-inputs-respected = !(custom.config.users.groups ? from-input-module);
}
