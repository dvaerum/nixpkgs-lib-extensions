# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
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

    EXCEPT for the users-tree-DISCOVERY role of `rootPath`, `loginFlakeRef`
    and `traceDiscoveredUsers`: the whole plan scans the tree ONCE, from
    `_defaults`' values of these three ALONE (a `_groups` entry's values
    are NOT consulted either), and shares that single result across every
    host -- a host's own override of any of them still merges normally
    into its arguments (so it still reaches, say, the `hosts/<hostname>.nix`
    lookup or the login-bootstrap's own target, unaffected), but has NO
    effect on which users/`configuration.nix`/`home.nix` are discovered
    for it, or on whether the discovery trace prints. A host needing a
    genuinely DIFFERENT tree needs `mkNixosSystem` called directly for
    it instead -- a plan cannot give two hosts two different trees.

    A second reserved key, `_groups`, holds OPTIONAL per-group defaults: a
    host declaring `group = "<name>";` receives `_groups.<name>` merged
    BETWEEN `_defaults` and its own entry, later layers winning per
    argument. Each group entry takes the same argument names as
    `_defaults` plus an `extra` slot that ADDS to the `_defaults` values
    (same rule as a host's `extra`); it cannot set `group` itself -- its
    attribute name IS the group. When `_groups` is present, every host's
    `group` must name one of its entries (unknown names throw); without
    `_groups`, `group` is the free-form classification it always was.

    Users are declared by the `users/` directory tree (see
    `mkNixosSystem`'s own `users` argument), not by an attrset here; a
    host's `users` key only SELECTS which of them apply to it.

    # Example

    ```nix
    # in your flake:
    # extLib = inputs.nixpkgs-lib-extensions.lib
    nixosConfigurations = extLib.buildNixosConfigurations {
      _defaults = {
        inherit inputs system;
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
        # none of the users/ tree applies to this host
        users = [ ];
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
    : - `users` (which of the users/ tree apply to this host;
    :   omitted = all of them, `[ ]` = none)
    : - `loginHomes`
    : - `homeModules` (applies to BOTH mechanisms: system-managed
    :   homes here, and login-managed homes too when this same hosts
    :   attrset goes through `buildConfigurations`)
    : - `loginFlakeRef`
    : - `loginReactivateEveryLogin`
    : - `traceDiscoveredUsers`
    : - `wrapHomeManagerSwitch`
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
    # projections. `buildHomeConfigurations` does NOT plan -- it is the
    # user-centric standalone entry point (userHomesStandalone); only
    # `buildConfigurations` plans once and takes both projections.
    shared.systemsFromPlan "buildNixosConfigurations" (
      shared.planHosts "buildNixosConfigurations" hosts
    );
}
