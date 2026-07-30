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
    or attrsets. For "shared base plus per-host extras" use the layered
    argument pairs instead -- `modules` (in `_defaults`) with
    `additionalModules` (per host), and `specialArgs` with
    `additionalSpecialArgs`; the pairs concatenate/merge by design.

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
        # extends _defaults.modules
        additionalModules = [ ./common/laptop-extras.nix ];
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
    : - `userRegistry`
    : - `loginUsers`
    : - `homeSharedModules` (applies to BOTH mechanisms: system-managed
    :   homes here, login-managed homes in `buildHomeConfigurations`)
    : - `loginFlakeRef`
    : - `loginReactivateEveryLogin`
    : - `tags`
    : - `systemType`
    : - `patches`
    : - `extraOverlays`
    : - `allowedUnfreePackages`
    : - `permittedInsecurePackages`
    : - `nixpkgsConfig`
    : - `specialArgs`
    : - `homeManager`
    : - `inputSpecialCases`
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
    let
      split = shared.splitHostsArgs "buildNixosConfigurations" hosts;
      # CONTEXT SHARING: the expensive host-independent part of the
      # evaluation context (one `import nixpkgs { ... }` per context) is
      # computed ONCE from `_defaults` and passed as `_core` to every
      # host that overrides NONE of the core arguments
      # (shared.coreArgNames); a host overriding any of them gets its own
      # context from its merged arguments, exactly as before. Lazy, so it
      # is never forced when every host overrides a core argument.
      defaultsCore = shared.mkContextCore split.defaults;
      # A loginUsers typo is otherwise silent: the home flips to the
      # system-managed mechanism and everything still builds. Only checkable
      # HERE, where every host's registry is in view -- a name that matches
      # no user on one host is legal (one shared list across a fleet), a
      # name matching none anywhere is a typo.
      loginUsersChecked = shared.validateLoginUsers "buildNixosConfigurations" (
        builtins.attrValues (
          builtins.mapAttrs (hostname: args: {
            inherit hostname;
            registry = (split.defaults // args).userRegistry or { };
            loginUsers = (split.defaults // args).loginUsers or [ ];
          }) split.hostEntries
        )
      );
      coreArgSet = builtins.listToAttrs (
        map (n: {
          name = n;
          value = null;
        }) shared.coreArgNames
      );
    in
    builtins.seq loginUsersChecked (
      builtins.mapAttrs (
        hostname: args:
        extLib.nixosConfigurationsBuilder (
          split.defaults
          // args
          // {
            inherit hostname;
          }
          // (if builtins.intersectAttrs coreArgSet args == { } then { _core = defaultsCore; } else { })
        )
      ) split.hostEntries
    );
}
