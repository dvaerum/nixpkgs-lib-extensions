# This file is a function-file: the lib loader (lib/default.nix) applies it to
# `extLib` — the fully assembled nixpkgs-lib-extensions lib.
extLib:
let
  shared = import ./internal/shared.nix extLib;
in
{
  /**
    Build several NixOS systems in one call: applies
    `nixosConfigurationsBuilder` to every value of `hosts`, with the
    attribute key as the hostname. The result has the same keys, so it can
    be assigned to a flake's `nixosConfigurations` output directly.
    Duplicate hostnames are impossible by construction (attrset keys are
    unique); an entry that also sets a *conflicting* inner `hostname`
    throws.

    The reserved key `_defaults` (never a hostname -- a hostname cannot
    START with `_`) provides arguments for every host. Merging is
    per-argument and a host entry wins entirely: no deep-merging of lists
    or attrsets. For "shared base plus per-host extras" put the addition in
    that host's `extra` slot instead -- ONE rule for every argument: a bare
    key REPLACES the default, `extra.<key>` ADDS to it (lists concatenate,
    attrsets merge with `extra` winning a conflict).

    The same hosts attrset is designed to also feed
    `buildHomeConfigurations`, producing the matching `homeConfigurations`
    outputs the login bootstrap needs -- define it once, pass it to both.

    # Example

    ```nix
    # in your flake:
    # extLib = inputs.nixpkgs-lib-extensions.lib
    nixosConfigurations = extLib.buildNixosConfigurations {
      _defaults = {
        inherit inputs system userRegistry;
        modules = [ ./common/base.nix ];
      };
      # each host's config is found by convention:
      # ./hosts/<hostname>.nix or
      # ./hosts/<hostname>/configuration.nix
      laptop = {
        # ADDS to _defaults.modules instead of replacing it
        extra.modules = [ ./common/laptop-extras.nix ];
      };
      server = {
        # per-argument override: replaces the registry entirely
        userRegistry = { };
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
    : allowlist as `_defaults` plus the per-host-only keys (`extra`, and a
    : redundant `hostname` equal to the attribute key); anything else
    : throws, so typos and leftover arguments fail loudly. `extra` accepts
    : the same argument names, and its keys are checked the same way.

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
    : - `userModule`
    : - `userRegistry`
    : - `loginHomes`
    : - `homeModules` (applies to BOTH mechanisms: system-managed
    :   homes here, login-managed homes in `buildHomeConfigurations`)
    : - `loginFlakeRef`
    : - `loginReactivateEveryLogin`
    : - `tags`
    : - `hostGroup`
    : - `patches`
    : - `extraOverlays`
    : - `allowedUnfreePackages`
    : - `permittedInsecurePackages`
    : - `nixpkgsConfig`
    : - `specialArgs`
    : - `homeManager`
    : - `inputContributions`
    :
    : This list is an enforced ALLOWLIST: any other key throws, so typos
    : (`homeConfiguration`, ...) fail loudly instead of being dropped
    : silently. `hostname` (it comes from each attribute key) and the
    : `additional*` arguments (the per-host halves of the layered pairs)
    : get their own explanatory errors.
  */
  buildNixosConfigurations =
    hosts:
    # validation (allowlists, hostname conflicts) is shared with
    # buildHomeConfigurations: one hosts attrset feeds both
    # `planHosts` does the split, the `_defaults` merge and the
    # context-core decision once; `buildHomeConfigurations` and
    # `buildConfigurations` use the very same plan.
    shared.systemsFromPlan "buildNixosConfigurations" (
      shared.planHosts "buildNixosConfigurations" hosts
    );
}
