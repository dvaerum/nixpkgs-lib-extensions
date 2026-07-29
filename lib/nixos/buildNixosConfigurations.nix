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
    : it themselves. Host entry keys are checked against the same
    : allowlist as `_defaults` plus the per-host-only keys
    : (`additionalModules`, `additionalSpecialArgs`, and a redundant
    : `hostname` equal to the attribute key); anything else throws, so
    : typos and leftover arguments fail loudly.

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
    : This list is an enforced ALLOWLIST: any other key throws, so typos
    : (`homeConfiguration`, ...) fail loudly instead of being dropped
    : silently. `hostname` (it comes from each attribute key) and the
    : `additional*` arguments (the per-host halves of the layered pairs)
    : get their own explanatory errors.
  */
  buildNixosConfigurations =
    hosts:
    let
      defaults = hosts._defaults or { };
      # ALLOWLIST: every nixosConfigurationsBuilder argument that may be
      # defaulted. A key outside this list throws -- the builder itself
      # ignores unknown arguments (its pattern ends in `...`), so a typo
      # like `homeConfiguration` would otherwise be dropped silently.
      # Keep in sync with the argument list in the doc comment above and
      # in nixosConfigurationsBuilder.
      allowedDefaults = [
        "inputs"
        "system"
        "nixpkgs"
        "rootPath"
        "modules"
        "userModuleFn"
        "excludeModuleInputs"
        "homeConfigurations"
        "flakeRef"
        "reactivateEveryLogin"
        "tags"
        "systemType"
        "patches"
        "extraOverlays"
        "allowedUnfreePackages"
        "permittedInsecurePackages"
        "specialArgs"
      ];
      complaint =
        name:
        if name == "hostname" then
          "- `hostname`: never a default -- it comes from each attribute key. Drop it."
        else if builtins.substring 0 10 name == "additional" then
          "- `${name}`: the `additional*` arguments are the per-host halves of the layered pairs (modules/additionalModules, specialArgs/additionalSpecialArgs). Set the base half in `_defaults`, the additional half on the host entry."
        else
          "- `${name}`: not a nixosConfigurationsBuilder argument (typo?). `_defaults` accepts: ${builtins.concatStringsSep ", " allowedDefaults}.";
      badDefaults = builtins.filter (k: !(builtins.elem k allowedDefaults)) (
        builtins.attrNames defaults
      );

      # Host entries share the allowlist, extended by the per-host-only
      # keys: the additional* halves of the layered pairs, and a redundant
      # `hostname` (tolerated when equal to the key, checked below).
      allowedHostArgs = allowedDefaults ++ [
        "hostname"
        "additionalModules"
        "additionalSpecialArgs"
      ];
      hostEntries = builtins.removeAttrs hosts [ "_defaults" ];
      badHostKeys = builtins.concatLists (
        builtins.attrValues (
          builtins.mapAttrs (
            hostname: args:
            map (
              k:
              "- `${hostname}`: `${k}` is not a nixosConfigurationsBuilder argument (typo?). Host entries accept: ${builtins.concatStringsSep ", " allowedHostArgs}."
            ) (builtins.filter (k: !(builtins.elem k allowedHostArgs)) (builtins.attrNames args))
          ) hostEntries
        )
      );
    in
    if badDefaults != [ ] then
      throw ''
        buildNixosConfigurations: invalid `_defaults` key(s):
        ${builtins.concatStringsSep "\n" (map complaint badDefaults)}
      ''
    else if badHostKeys != [ ] then
      throw ''
        buildNixosConfigurations: invalid host entry key(s):
        ${builtins.concatStringsSep "\n" badHostKeys}
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
      ) hostEntries;
}
