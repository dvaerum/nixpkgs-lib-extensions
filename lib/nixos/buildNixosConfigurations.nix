# This file is a function-file: the lib loader (lib/default.nix) applies it to
# `extLib` — the fully assembled nixpkgs-lib-extensions lib.
extLib:
{
  /**
    Build several NixOS systems in one call: applies
    `nixosConfigurationsBuilder` to every value of `hosts`, with the
    attribute key as the hostname. The result has the same keys, so it can
    be assigned to a flake's `nixosConfigurations` output directly.
    Duplicate hostnames are impossible by construction (attrset keys are
    unique); an entry that also sets a *conflicting* inner `hostname`
    throws.

    The reserved key `_defaults` (never a hostname -- hostnames cannot
    contain `_`) provides arguments for every host. Merging is
    per-argument and a host entry wins entirely: no deep-merging of lists
    or attrsets. For "shared base plus per-host extras" use the layered
    argument pairs instead -- `modules` (in `_defaults`) with
    `additionalModules` (per host), and `specialArgs` with
    `additionalSpecialArgs`; the pairs concatenate/merge by design.

    # Example

    ```nix
    # in your flake:
    # extLib = inputs.nixpkgs-lib-extensions.lib
    nixosConfigurations = extLib.buildNixosConfigurations {
      _defaults = {
        inherit inputs system homeConfigurations;
        modules = [ ./common/base.nix ];
      };
      # each host's config is found by convention:
      # ./hosts/<hostname>.nix or
      # ./hosts/<hostname>/configuration.nix
      laptop = {
        # extends _defaults.modules
        additionalModules = [ ./common/laptop-extras.nix ];
      };
      server = {
        # per-argument override: replaces the registry entirely
        homeConfigurations = { };
      };
    };
    =>
    { laptop = <nixosSystem>; server = <nixosSystem>; }
    ```

    # Type

    ```
    buildNixosConfigurations ::
      { <hostname> = Attribute; } -> { <hostname> = NixosSystem; }
    ```

    # Arguments

    hosts
    : Attribute set mapping hostnames to `nixosConfigurationsBuilder`
    : argument sets. The key provides `hostname`, so entries do not set
    : it themselves.

    _defaults
    : Optional reserved entry of `hosts` (never a hostname): arguments
    : merged under every host entry, the host winning per argument. Can
    : provide a default for every `nixosConfigurationsBuilder` argument
    : except the per-host ones:
    :
    : - `inputs`
    : - `system`
    : - `nixpkgs`
    : - `rootPath`
    : - `modules`
    : - `userModuleFn`
    : - `excludeModuleInputs`
    : - `homeConfigurations`
    : - `flakeRef`
    : - `reactivateEveryLogin`
    : - `tags`
    : - `systemType`
    : - `patches`
    : - `extraOverlays`
    : - `allowedUnfreePackages`
    : - `permittedInsecurePackages`
    : - `specialArgs`
    :
    : Not allowed (throws): `hostname` (it comes from each attribute key)
    : and `additionalModules`/`additionalSpecialArgs` (the per-host halves
    : of the layered pairs).
  */
  buildNixosConfigurations =
    hosts:
    let
      defaults = hosts._defaults or { };
      forbidden = builtins.filter (k: defaults ? ${k}) [
        "hostname"
        "additionalModules"
        "additionalSpecialArgs"
      ];
    in
    if forbidden != [ ] then
      throw ''
        buildNixosConfigurations: `_defaults` must not set ${builtins.concatStringsSep ", " forbidden}. `hostname` comes from each attribute key; the `additional*` arguments are the per-host extension slots for the layered pairs (modules/additionalModules, specialArgs/additionalSpecialArgs) -- set the base half in `_defaults` instead.
      ''
    else
      builtins.mapAttrs (
        hostname: args:
        if args ? hostname && args.hostname != hostname then
          throw ''
            buildNixosConfigurations: the entry `${hostname}` also sets
            `hostname = "${args.hostname}"`. The attribute key is the
            hostname; drop the inner one.
          ''
        else
          (extLib.nixosConfigurationsBuilder (defaults // args // { inherit hostname; })).${hostname}
      ) (builtins.removeAttrs hosts [ "_defaults" ]);
}
