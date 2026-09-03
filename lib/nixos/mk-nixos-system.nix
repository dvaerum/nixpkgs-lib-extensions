# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
# Shared machinery lives in ./internal/shared.nix.
{ self, lib, ... }:
let
  shared = import ./internal/shared.nix { inherit lib self; };
in
{
  /**
    Build a NixOS system for a host.

    The flake `inputs` are passed as a field, and a number of things are wired in
    automatically when the matching input exists:

    - NixOS modules from any input exposing `nixosModules.default` (excluded:
      the home-manager input, since it is used standalone, and nixpkgs trees
      -- anything with `legacyPackages` AND `lib.nixosSystem` -- whose helper
      modules would break the system). The `default` export is auto-loaded;
      without one, a set with exactly one entry is used as-is (sops-nix
      style), while a multi-entry set with no `default` is ambiguous
      (nixos-hardware style catalogs) and the builder THROWS rather than
      guess, naming the selections that resolve it -- see
      `inputContributions`, which also narrows a channel (this doc's term
      for an export KIND: `nixosModules`/`homeModules`/`overlays`/
      `libOverlays`/`lib` -- unrelated to the `nixpkgsLibExtensions.channels`
      package-set option further below, which reuses the same word for a
      different thing) to named entries or switches it off.
    - overlays from any input exposing `overlays.default` (same
      default/sole-entry rule, but no exclusions -- overlays are collected
      from every input, nixpkgs trees included).
    - lib extensions from any input exposing a lib overlay
      `libOverlays.default = final: prev: { ... };` -- it composes through
      `lib.extend`, so one addition can reference another via `final`.
      This repo's own extensions are always applied to the system `lib`
      and also passed as the `extLib` specialArg. Governed by the
      `libOverlays` channel of `inputContributions`.
    - each input's standalone `lib` export, namespaced by input name:
      `lib.<inputName>` in modules and `pkgs.lib.<inputName>` (e.g.
      `lib.NixVirt.domain`). Never merged flat -- a lib overlay is the
      composable way into the flat lib -- and never overwriting: if the
      name is a namespace this repo owns (`disko`, ...) the input's lib is
      MERGED into it with the existing side winning every conflict (so a
      `disko` input's helpers join `declareZfsRootDisk` under `lib.disko`);
      any other existing name is skipped with a warning, and nixpkgs trees
      are not namespaced at all (their lib is the base). The consuming
      flake's own `lib` output (`inputs.self`) is renamed to `lib.flake`
      -- export your helper functions there and every module gets them as
      `lib.flake.<helper>` with zero wiring.
    - every `nixpkgs-*` input as a package set under the
      `nixpkgsLibExtensions.channels.<variant>` option (an unrelated reuse
      of the word "channel" from the export-KIND sense above -- this one
      names a package-set variant, not a kind of export) (e.g.
      `inputs.nixpkgs-unstable` becomes
      `config.nixpkgsLibExtensions.channels.unstable`), built with the same
      overlays and config as the primary `pkgs`.

    The whole `inputs` set is also passed through as the `inputs` specialArg
    (and home-manager extraSpecialArg), so modules can reach anything not
    covered by those conventions (e.g. `inputs.fenix`) themselves — the
    builders carry no policy for specific inputs. The only per-input hook
    is a normalization table for flakes with nonstandard export names,
    applied strictly by input name -- currently empty (NUR, the Nix User
    Repository, was its one former entry; it now contributes via
    `overlays.default` like any other input).
    As a convenience, `nixpkgsLibExtensions.inputPkgs` holds every input's
    packages pre-selected for the host's system
    (`config.nixpkgsLibExtensions.inputPkgs.disko.disko-install`); they are
    deliberately not merged into `pkgs`, where input names would shadow
    nixpkgs attributes.

    The builder-derived per-host values are declared as options under
    `nixpkgsLibExtensions.*` in every NixOS module set AND every home
    (whichever mechanism built it): `tags` (mergeable), `group`,
    `users`, `inputPkgs` and `channels` (read-only), plus `hostname` in
    homes only -- NixOS modules read `config.networking.hostName`, which
    the builder sets.

    The host's own configuration is included by convention: relative to
    `rootPath` (default: the consuming flake, `inputs.self`), either
    `hosts/<hostname>.nix` or `hosts/<hostname>/configuration.nix` is
    imported automatically when it exists (both existing is an error).
    Setting `group` groups hosts one folder deeper: the lookup then
    happens under `hosts/<group>/` instead of `hosts/` (`hostFolder`
    overrides the folder segment without touching the classification).

    The host's users come from the `users/` DIRECTORY TREE (see the
    `users` argument) — every user gets an account (unless
    `userModule = null`, or the account is a system one with a uid below
    1000) and their `configuration.nix` imported into the system. How
    each user's `home.nix` is activated is selected by `loginHomes`:

    - not listed (the default) — SYSTEM-managed home: wired into the
      system via home-manager's NixOS module
      (`home-manager.users.<user>`), activated by `nixos-rebuild
      switch`. No flake outputs, no bootstrap.
    - listed in `loginHomes` — LOGIN-managed home: activated on first
      login by the bootstrap (`homeManagerBootstrapModule`) running
      `home-manager switch` against that flake's matching
      `homeConfigurations` output (`<user>`, or `<user>@<host>` where the
      user has a `hosts/<host>/` override -- resolved at evaluation
      time); the flake must export one of them --
      `buildConfigurations` does, from the same hosts attrset, and
      `buildHomeConfigurations` from its own flat argument set.

    A home is managed by exactly one mechanism, by construction.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.mkNixosSystem {
      inherit inputs;
      hostname = "laptop";
      system   = "x86_64-linux";
      nixpkgs  = inputs.nixpkgs;
      # ./hosts/laptop.nix (or ./hosts/laptop/configuration.nix) is
      # imported automatically; `modules` is only for anything extra.

      # Users are the ./users tree, discovered automatically -- nothing
      # to list here. Every users/<name>/ directory gets an account,
      # its configuration.nix, and its home.nix activated with the
      # system, unless listed in loginHomes:
      #   users/alice/home.nix                  on every host
      #   users/alice/hosts/laptop/home.nix     merged in on laptop
      #   users/bob/home.nix
      #
      # bob's home.nix activates on his first login instead (needs the
      # homeConfigurations outputs from buildHomeConfigurations)
      loginHomes = [ "bob" ];
    }
    =>
    <nixosSystem>
    ```

    The system is returned BARE (like `mkHomeConfiguration`), so
    assign it to your flake's `nixosConfigurations` output under an
    explicit key, e.g.
    `nixosConfigurations.laptop = extLib.mkNixosSystem { ... }`
    — or use `buildNixosConfigurations` to build a whole keyed set of
    hosts in one call.

    # Type

    ```
    mkNixosSystem :: Attribute -> NixosSystem
    ```

    # Arguments

    inputs
    : The flake's `inputs` set. Used to auto-discover modules, overlays, lib
    : extensions and `nixpkgs-*` variants.

    hostname
    : The host name.

    system
    : The system double, e.g. `"x86_64-linux"`.

    nixpkgs
    : The single preferred nixpkgs flake used to build the system. Default `inputs.nixpkgs`.

    modules
    : Extra NixOS modules, on top of those auto-collected from `inputs` and
    : the host's own `hosts/<hostname>(.nix|/configuration.nix)`. Default `[ ]`.
    : In a hosts attrset, a host adds to the shared list with
    : `extra.modules = [ ... ];` rather than replacing it.

    userModule
    : A function `username -> NixOS module`, applied for each user the
    : users tree gives this host. Defaults to `normalUserModule`, which creates
    : a normal login account per user; pass your own function for richer
    : accounts, or `null` to disable account creation entirely.

    users
    : WHICH of the users tree applies to this host. Users themselves are
    : declared by DIRECTORIES, not by this argument -- see the `users/`
    : tree convention below -- so this only selects among them: omitted
    : (the default) means every user in the tree, `[ ]` means none, and a
    : list names exactly those wanted. A name that is not in the tree is a
    : typo and THROWS.
    :
    : The tree is read from `rootPath` (default: your flake,
    : `inputs.self`), or from `loginFlakeRef` when the homes live in
    : another flake. Each `users/<name>/` directory may contain `home.nix`
    : (the user's home-manager config) and/or `configuration.nix` (NixOS
    : config for that user: the account, its groups, ...), plus
    : `hosts/<hostname>/` subdirectories carrying the same two files for
    : one host only:
    :
    : - a user's own files apply on EVERY host;
    : - a `hosts/<hostname>/` subdirectory applies on that host and MERGES
    :   on top of them;
    : - a user with ONLY `hosts/` subdirectories exists on those hosts and
    :   nowhere else;
    : - a directory with only `configuration.nix` is a system-only user
    :   (account, no home).
    :
    : `configuration.nix` files are imported into the system
    : automatically. `home.nix` files are wired into
    : `home-manager.users.<user>` via home-manager's NixOS module -- built
    : and activated WITH the system on `nixos-rebuild switch`
    : (`useGlobalPkgs`/`useUserPackages` default to true, overridable;
    : each home gets `home.stateVersion` defaulted to the CURRENT nixpkgs
    : release, with a WARNING for any home relying on that moving default
    : -- pin it in the user's `home.nix` or fleet-wide via `homeModules`
    : -- and receives `username` as a module argument) -- unless the user
    : is listed in `loginHomes`.
    :
    : The tree defines the host's users (exposed as the
    : `nixpkgsLibExtensions.users` option), and what it found is announced
    : via `traceDiscoveredUsers` (default `true`).
    : WARNING: in a git-backed flake only TRACKED files exist -- `git add` a
    : new home.nix/configuration.nix or it is skipped silently.

    loginHomes
    : List of usernames (from the users tree) whose `home.nix` is
    : LOGIN-managed instead of system-managed: not part of the system,
    : activated on the user's first login by the bootstrap via
    : `home-manager switch` against that flake's matching output --
    : `#<user>`, or `#<user>@<host>` where the user has a
    : `hosts/<host>/` override, resolved at EVALUATION time. The flake
    : must export one of them (`buildConfigurations` does, from the same
    : hosts attrset; `buildHomeConfigurations` from its own flat args). Accounts
    : and `configuration.nix` handling are unaffected. Names not
    : matching any of this host's users are ignored in a DIRECT call
    : like this (the list is usually shared through `_defaults` across
    : hosts, so "not on this host" is normal) -- but the hosts-attrset
    : builders see every host at once, and a name that matches no
    : user on ANY host is a typo and THROWS there. Default
    : `[ ]` (every home is system-managed).

    loginFlakeRef
    : Where the login bootstrap finds the home configurations of
    : `loginHomes` users: on first login it runs `home-manager switch`
    : against that flake's matching output -- `"<user>@<hostname>"` when
    : the user has a `hosts/<hostname>/` override, else `"<user>"`,
    : decided when the system is built.
    : The default `inputs.self` is the IMMUTABLE store copy of your flake
    : that the running system was built from -- homes then always match
    : the last `nixos-rebuild`, but local edits are invisible until the
    : next rebuild. Point it at a mutable checkout (e.g. `"/etc/nixos"`
    : or `"git+https://..."`) to make the bootstrap build from the live
    : tree instead -- a real, supported capability (not eval-time
    : knowable, so the users tree cannot be scanned from it; passing one
    : WARNS, naming the trade-off, not because it is wrong).
    : Irrelevant without `loginHomes` users.
    : Default `inputs.self`.

    traceDiscoveredUsers
    : Whether scanning the users tree (see the `users` argument)
    : announces what it found: `users discovered in <ref>/users:
    : <names>`. Nothing is printed when the scan finds no users. May
    : print more than once when a build resolves the tree at more than
    : one entry point, which Nix gives no way to deduplicate.
    : Default `true`.

    loginReactivateEveryLogin
    : Bootstrap re-activates on every login instead of only the first.
    : Irrelevant without `loginHomes` users. Default `false`.

    wrapHomeManagerSwitch
    : Whether a login-managed user's host also gets a detach-safe
    : `home-manager` on `environment.systemPackages`, so they can manually
    : re-run `switch` between logins (the bootstrap service is otherwise
    : the only thing that ever invokes it). Wrapped via
    : `systemd.interceptingWrapper`/`detachedRun` -- see their own doc
    : comments -- because `switch`'s own activation can restart the very
    : unit the invoking shell's cgroup lives in, terminating itself
    : mid-activation. Self-gating like the bootstrap module: no effect
    : without a `loginHomes` user actually shipping a `home.nix` on this
    : host. Default `true`.

    homeModules
    : home-manager modules added to every SYSTEM-managed home (on top of
    : those auto-collected from `inputs`). The same argument is read by
    : `mkHomeConfiguration`/`buildHomeConfigurations` for the
    : login-managed homes, so under `buildConfigurations` (which shares
    : one hosts attrset) it applies to both kinds. Default `[ ]`.

    tags
    : List of string tags, seeding the `nixpkgsLibExtensions.tags` option
    : -- modules can ADD tags by defining that option, and the list
    : definitions merge. The merged value is set as `system.nixos.tags`
    : (mkDefault) so tags label the host's boot-menu entries; a host
    : defining that option itself overrides this. Tags carry no other
    : behavior. Default `[ ]`.

    nixpkgsConfig
    : Attribute set merged into `nixpkgs.config` for the host's package
    : set -- e.g. `{ cudaSupport = true; }`. Merged last, so it can also
    : override what `allowedUnfreePackages`/`permittedInsecurePackages`
    : produced. This is the ONLY route for nixpkgs config here: the builder
    : passes a package set it built itself, and nixpkgs asserts that the
    : `nixpkgs.config` module option is empty in that case ("nixpkgs.config
    : options should be passed when creating the instance instead"). Setting
    : it from a module therefore fails an assertion rather than being
    : ignored. Default `{ }`.

    patches
    : Patch files applied to the nixpkgs SOURCE tree (via `applyPatches`)
    : before the system is evaluated from it. Default `[ ]` (no patching,
    : no source copy). A non-empty list requires import-from-derivation:
    : the patched tree is BUILT during evaluation, so that host fails
    : under `--no-allow-import-from-derivation` (and eval-only workflows
    : like `nix flake check --no-build` stop working for it). See
    : [Patching nixpkgs itself](getting-started.md#patching-nixpkgs-itself)
    : for an example and the costs involved.
    : A list element that is a directory auto-expands via `discoverPatches`
    : -- `patches = [ ./patches ];` works directly, mixed with explicit
    : `.patch` paths or derivations if wanted. See `discoverPatches`'s own
    : doc comment for the directory's file-classification rules.

    overlays
    : Overlays applied on top of the ones auto-collected from `inputs`.
    : Unlike `nixpkgsConfig`, this is not the only route: a
    : module's own `nixpkgs.overlays` works too and composes with these
    : (nixpkgs appends module overlays onto the package set passed in),
    : so a third-party module bringing its own overlays needs nothing
    : special. Prefer this argument when you want explicit ordering or
    : want the overlay in the package set the builder shares with
    : home-manager. Default `[ ]`.

    allowedUnfreePackages
    : Unfree package names to allow (matched by `lib.getName` via
    : `allowUnfreePredicate`) -- a shorthand for the `nixpkgsConfig`
    : recipe `nixpkgsConfig.allowUnfreePredicate = pkg:
    : builtins.elem (lib.getName pkg) [ ... ];`, which is the canonical
    : path when you need anything beyond a name list. Default `[ ]`.

    permittedInsecurePackages
    : Passed through to `nixpkgs.config.permittedInsecurePackages` -- a
    : shorthand for the `nixpkgsConfig` recipe
    : `nixpkgsConfig.permittedInsecurePackages = [ ... ];`. Default `[ ]`.

    specialArgs
    : Extra specialArgs, merged alongside the ones the builder assembles
    : (`inputs`, `rootPath`, `extLib`). Redefining
    : a builder-owned name THROWS: overriding one changed only what
    : modules see, not what the builder did. The option-backed names
    : (`hostname`, `tags`, `group`, `users`, `inputPkgs`, `channels`,
    : `username`) throw too -- they are options (or module arguments),
    : and a specialArg of the same name would mask the real value -- as
    : do the module-system-owned `pkgs`, `lib`, `config`, `options` and
    : `modulesPath`. Set the corresponding builder argument instead.
    : Default `{ }`.

    group
    : Free-form host classification, e.g. `"vm"` or `"server"`.
    : Exposed to modules as the read-only `nixpkgsLibExtensions.group`
    : option; in a hosts attrset it also selects that host's `_groups`
    : defaults layer (see `buildNixosConfigurations`). When non-null the
    : host config convention looks under `hosts/<group>/` instead of
    : `hosts/`, unless `hostFolder` overrides the segment. Default
    : `null` (no classification, no grouping folder).

    hostFolder
    : The folder segment of the host config convention, overriding the
    : `group` default: the lookup happens under `hosts/<hostFolder>/`
    : whatever `group` says. Decouples the folder layout from the
    : classification. Default `null` (folder follows `group`).

    rootPath
    : The root for the `hosts/<hostname>` convention and the `rootPath`
    : specialArg. Default `inputs.self` (the consuming flake); throws
    : when neither is available.

    homeManager
    : Explicit home-manager input, bypassing the capability detection --
    : use it when several inputs look like home-manager (the detection
    : warns and picks the alphabetically first otherwise). Default `null`
    : (detect).

    inputContributions
    : Per-input control of the auto-collection, keyed by input NAME and
    : merged over the built-in table. Each entry takes one of three forms:
    :   `null`                 the input contributes NOTHING, to any channel
    :   `{ <channel> = ...; }` a per-channel SELECTION (below)
    :   a function             escape hatch for exports living under
    :                          nonstandard paths: maps the input onto the
    :                          convention attributes, e.g.
    :                          `v: { nixosModules = v.modules.nixos; }`
    : A selection value is a list of entry names (auto-imported in the order
    : given), `"*"` (every entry, alphabetically), or `null`/`[ ]` (none).
    : The selectable channels are `nixosModules`, `homeModules` and
    : `overlays`; `libOverlays` and `lib` hold a single value, so for them
    : only `null`/`[ ]` (off) and `"*"` (on) apply. Naming entries is how you take
    : SEVERAL of a catalog's exports -- and it is validated: an unknown
    : channel key, an unknown entry name, or a case keyed by an input that is
    : not in `inputs` all throw, listing the valid options. An explicit
    : selection also overrides the built-in skips (the home-manager input,
    : nixpkgs trees), which only exist to prevent guessing. UNAFFECTED BY
    : ANY OF THIS: the `nixpkgsLibExtensions.channels` package-set variants
    : (an unrelated use of "channel" from the export-kind sense above),
    : `inputPkgs`, and the home-manager capability detection are all
    : computed from `inputs` directly, so no `inputContributions` case
    : touches them --
    : `inputContributions."nixpkgs-unstable" = null;` still yields a
    : `channels.unstable` entry. An input reached by hand via the `inputs`
    : specialArg or the `inputPkgs` option likewise always works.
    : Example: `inputContributions."nixos-raspberrypi".overlays =
    : [ "bootloader" "vendor-kernel" ];`
    : Default `{ }`.

    `mkHomeConfiguration` accepts this same shared set, so both
    builders can be called with one common argument attrset.
  */
  # Validate here, where the caller's function name is known, then hand the
  # arguments to the shared implementation with NO evaluation core: a direct
  # call builds its own. (buildNixosConfigurations goes through planHosts,
  # which validates the same way and DOES pass a core, so hosts sharing
  # `_defaults` share one nixpkgs evaluation.)
  #
  # Destructuring validArgs forces the check, so even a consumer that only
  # reads attrNames of the result hits it.
  mkNixosSystem = args: shared.mkSystem null (shared.validateBuilderArgs "mkNixosSystem" [ ] args);
}
