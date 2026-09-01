# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
{ self, lib, ... }:
let
  shared = import ./internal/shared.nix { inherit lib self; };
in
{
  /**
    Build several NixOS systems in one call: applies
    `mkNixosSystem` to every value of `hosts`, with the
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

    A second reserved key, `_groups`, holds OPTIONAL per-group defaults: a
    host declaring `group = "<name>";` receives `_groups.<name>` merged
    BETWEEN `_defaults` and its own entry, later layers winning per
    argument. Each group entry takes the same argument names as
    `_defaults` plus an `extra` slot that ADDS to the `_defaults` values
    (same rule as a host's `extra`); it cannot set `group` itself -- its
    attribute name IS the group. When `_groups` is present, every host's
    `group` must name one of its entries (unknown names throw); without
    `_groups`, `group` is the free-form classification it always was.

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
    : Attribute set mapping hostnames to `mkNixosSystem`
    : argument sets. The key provides `hostname`, so entries do not set
    : it themselves. Host entry keys are checked against the same
    : allowlist as `_defaults` plus the per-host-only keys (`extra`, and a
    : redundant `hostname` equal to the attribute key); anything else
    : throws, so typos and leftover arguments fail loudly. `extra` accepts
    : the same argument names, and its keys are checked the same way.

    _defaults
    : Optional reserved entry of `hosts` (never a hostname): arguments
    : merged under every host entry, the host winning per argument. Can
    : provide a default for every `mkNixosSystem` argument
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
    : - `traceDiscoveredUsers`
    : - `tags`
    : - `group` (also selects the host's `_groups` layer)
    : - `hostFolder`
    : - `patches`
    : - `overlays`
    : - `allowedUnfreePackages`
    : - `permittedInsecurePackages`
    : - `nixpkgsConfig`
    : - `specialArgs`
    : - `homeManager`
    : - `inputContributions`
    :
    : This list is an enforced ALLOWLIST: any other key throws, so typos
    : (`homeConfiguration`, ...) fail loudly instead of being dropped
    : silently. `hostname` (it comes from each attribute key) and `extra`
    : (per-host only) get their own explanatory errors.

    _groups
    : Optional reserved entry of `hosts` (never a hostname): per-group
    : argument sets, applied between `_defaults` and the host entries
    : that declare the matching `group` -- see the description above.
  */
  buildNixosConfigurations =
    hosts:
    # `planHosts` does the split, the `_defaults` merge, the validation and
    # the context-core decision; `systemsFromPlan` is one of its two
    # projections. buildHomeConfigurations runs the SAME code over its own
    # plan of the same hosts attrset -- only `buildConfigurations` plans
    # once and takes both projections from it.
    shared.systemsFromPlan "buildNixosConfigurations" (
      shared.planHosts "buildNixosConfigurations" hosts
    );
}
