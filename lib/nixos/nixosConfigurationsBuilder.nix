# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
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
      `inputContributions`, which also narrows a channel to named entries or
      switches it off.
    - overlays from any input exposing `overlays.default` (same
      default/sole-entry rule, but no exclusions -- overlays are collected
      from every input, nixpkgs trees included).
    - lib extensions from any input exposing an `extendLib` function; this repo's
      own extensions are always applied to the system `lib` and also passed as the
      `extLib` specialArg.
    - each input's standalone `lib` export, namespaced by input name:
      `lib.<inputName>` in modules and `pkgs.lib.<inputName>` (e.g.
      `lib.NixVirt.domain`). Never merged flat -- `extendLib` is the
      composable way into the flat lib -- and never overwriting: if the
      name is a namespace this repo owns (`disko`, ...) the input's lib is
      MERGED into it with the existing side winning every conflict (so a
      `disko` input's helpers join `declareZfsRootDisk` under `lib.disko`);
      any other existing name is skipped with a warning, and nixpkgs trees
      are not namespaced at all (their lib is the base). The consuming
      flake's own `lib` output (`inputs.self`) is renamed to `lib.flake`
      -- export your helper functions there and every module gets them as
      `lib.flake.<helper>` with zero wiring.
    - every `nixpkgs-*` input as a `pkgs-*` specialArg (e.g. `inputs.nixpkgs-unstable`
      becomes the `pkgs-unstable` specialArg).

    The whole `inputs` set is also passed through as the `inputs` specialArg
    (and home-manager extraSpecialArg), so modules can reach anything not
    covered by those conventions (e.g. `inputs.fenix`) themselves — the
    builders carry no policy for specific inputs. The only per-input hook
    is a normalization table for flakes with nonstandard export names,
    applied strictly by input name -- currently empty (NUR, its one
    former entry, contributes via `overlays.default` like any other
    input).
    As a convenience, `inputPkgs` holds every input's packages pre-selected
    for the host's system (`inputPkgs.disko.disko-install`); they are
    deliberately not merged into `pkgs`, where input names would shadow
    nixpkgs attributes.

    The host's own configuration is included by convention: relative to
    `rootPath` (default: the consuming flake, `inputs.self`), either
    `hosts/<hostname>.nix` or `hosts/<hostname>/configuration.nix` is
    imported automatically when it exists (both existing is an error).
    Setting `hostGroup` groups hosts one folder deeper: the lookup then
    happens under `hosts/<hostGroup>/` instead of `hosts/`.

    The host's users come from ONE `userRegistry` — every user gets an
    account (unless `userModule = null`, or the account is a system one
    with a uid below 1000) and their `configuration.nix` imported into
    the system. How
    each user's `home.nix` is activated is selected by `loginHomes`:

    - not listed (the default) — SYSTEM-managed home: wired into the
      system via home-manager's NixOS module
      (`home-manager.users.<user>`), activated by `nixos-rebuild
      switch`. No flake outputs, no bootstrap.
    - listed in `loginHomes` — LOGIN-managed home: activated on first
      login by the bootstrap (`homeManagerBootstrapModule`) running
      `home-manager switch --flake <loginFlakeRef>#<user>@<host>`; the
      flake must export those `homeConfigurations` outputs (built by
      `buildHomeConfigurations` from the same hosts attrset).

    A home is managed by exactly one mechanism, by construction.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.nixosConfigurationsBuilder {
      inherit inputs;
      hostname = "laptop";
      system   = "x86_64-linux";
      nixpkgs  = inputs.nixpkgs;
      # ./hosts/laptop.nix (or ./hosts/laptop/configuration.nix) is
      # imported automatically; `modules` is only for anything extra.

      # ALL users: accounts + configuration.nix, and home.nix activated
      # with the system (home-manager NixOS module) unless listed in
      # loginHomes. Every value is a DIRECTORY with home.nix and/or
      # configuration.nix.
      userRegistry = {
        "alice@*"      = ./users/alice;        # on every host
        "alice@laptop" = ./users/alice-laptop; # merged in on laptop
        "bob"          = ./users/bob;          # only when no bob@... matches
      };
      # bob's home.nix activates on his first login instead (needs the
      # homeConfigurations outputs from buildHomeConfigurations)
      loginHomes = [ "bob" ];
    }
    =>
    <nixosSystem>
    ```

    The system is returned BARE (like `homeConfigurationsBuilder`), so
    assign it to your flake's `nixosConfigurations` output under an
    explicit key, e.g.
    `nixosConfigurations.laptop = extLib.nixosConfigurationsBuilder { ... }`
    — or use `buildNixosConfigurations` to build a whole keyed set of
    hosts in one call.

    # Type

    ```
    nixosConfigurationsBuilder :: Attribute -> NixosSystem
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
    : A function `username -> NixOS module`, applied for each user derived
    : from the `userRegistry`. Defaults to `normalUserModule`, which creates
    : a normal login account per user; pass your own function for richer
    : accounts, or `null` to disable account creation entirely.

    userRegistry
    : THE user registry: every host user, whatever their home mechanism.
    : Every value must be a DIRECTORY containing `home.nix` (the user's
    : home-manager config) and/or `configuration.nix` (NixOS config for
    : that user: the account, its groups, ...). `configuration.nix` files
    : are imported into the system automatically. `home.nix` files are
    : wired into `home-manager.users.<user>` via home-manager's NixOS
    : module -- built and activated WITH the system on `nixos-rebuild
    : switch` (`useGlobalPkgs`/`useUserPackages` default to true,
    : overridable; each home gets `home.stateVersion` defaulted to the
    : CURRENT nixpkgs release, so pin it in the user's `home.nix` if you
    : rely on stateVersion semantics, and receives `username` as a module
    : argument) -- unless the user is listed in `loginHomes`. A
    : directory with only a `configuration.nix` is a system-only user
    : (account, no home). Keys select where an entry applies:
    :   `"<user>@<host>"`  this host only
    :   `"<user>@*"`       every host; MERGES with a matching `"<user>@<host>"`
    :   `"<user>"`         standalone default, used only when NO @-entry
    :                      matched -- never merged with @-entries (a shadowed
    :                      plain entry triggers an eval warning; import its
    :                      directory explicitly from an @-entry to reuse it)
    : Example: with `"alice@*"` and `"alice@laptop"` both defined, both
    : apply on laptop; a plain `"alice"` would then never be used anywhere.
    : The keys define the host's users (exposed as `listOfUsernames`).
    : `null` or `{ }` disables it. Default `{ }`.
    : WARNING: in a git-backed flake only TRACKED files exist -- `git add` a
    : new home.nix/configuration.nix or it is skipped silently.

    loginHomes
    : List of usernames (from `userRegistry`) whose `home.nix` is
    : LOGIN-managed instead of system-managed: not part of the system,
    : activated on the user's first login by the bootstrap via
    : `home-manager switch --flake <loginFlakeRef>#<user>@<host>` -- the
    : flake must export those `homeConfigurations` outputs (built by
    : `buildHomeConfigurations` from the same hosts attrset). Accounts
    : and `configuration.nix` handling are unaffected. Names not
    : matching any of this host's users are ignored (the list is
    : usually shared through `_defaults` across hosts). Default `[ ]`
    : (every home is system-managed).

    loginFlakeRef
    : Where the login bootstrap finds the home configurations of
    : `loginHomes` users: on first login it runs
    : `home-manager switch --flake <loginFlakeRef>#<user>@<hostname>`, so the
    : flake at this reference must export
    : `homeConfigurations."<user>@<hostname>"`.
    : The default `inputs.self` is the IMMUTABLE store copy of your flake
    : that the running system was built from -- homes then always match
    : the last `nixos-rebuild`, but local edits are invisible until the
    : next rebuild. Point it at a mutable checkout (e.g. `"/etc/nixos"`
    : or `"git+https://..."`) to make the bootstrap build from the live
    : tree instead. Irrelevant without `loginHomes` users.
    : Default `inputs.self`.

    loginReactivateEveryLogin
    : Bootstrap re-activates on every login instead of only the first.
    : Irrelevant without `loginHomes` users. Default `false`.

    homeModules
    : home-manager modules added to every SYSTEM-managed home (on top of
    : those auto-collected from `inputs`). The same argument is read by
    : `homeConfigurationsBuilder`/`buildHomeConfigurations` for the
    : login-managed homes, so in a shared hosts attrset it applies to
    : both kinds. Default `[ ]`.

    tags
    : List of string tags, passed to modules as the `tags` specialArg and
    : set as `system.nixos.tags` (mkDefault) so they label the host's
    : boot-menu entries; a host defining that option itself overrides
    : this. Tags carry no other behavior. Default `[ ]`.

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
    : no source copy). See
    : [Patching nixpkgs itself](getting-started.md#patching-nixpkgs-itself)
    : for an example and the costs involved.

    extraOverlays
    : Overlays applied on top of the ones auto-collected from `inputs`.
    : Unlike `nixpkgsConfig`, this is not the only route: a module's own
    : `nixpkgs.overlays` works too and composes with these (nixpkgs appends
    : module overlays onto the package set passed in), so a third-party
    : module bringing its own overlays needs nothing special. Prefer this
    : argument when you want explicit ordering or want the overlay in the
    : package set the builder shares with home-manager. Default `[ ]`.

    allowedUnfreePackages
    : Unfree package names to allow (matched by `lib.getName` via
    : `allowUnfreePredicate`). Default `[ ]`.

    permittedInsecurePackages
    : Passed through to `nixpkgs.config.permittedInsecurePackages`.
    : Default `[ ]`.

    specialArgs
    : Extra specialArgs, merged alongside the ones the builder assembles.
    : Redefining a builder-OWNED name (`hostname`, `inputs`, `rootPath`,
    : `tags`, `extLib`, `hostGroup`, `inputPkgs`, any `pkgs-*`) THROWS:
    : overriding one changed only what modules see, not what the builder
    : did, so `specialArgs.hostname` gave modules one name while
    : `networking.hostName` and the `hosts/<hostname>` lookup kept another.
    : Set the corresponding builder argument instead. Default `{ }`.

    hostGroup
    : Free-form host classification, e.g. `"vm"` or `"server"`. Passed to
    : modules as the `hostGroup` specialArg, and when non-null the host
    : config convention looks under `hosts/<hostGroup>/` instead of
    : `hosts/`. Default `null` (no grouping folder).

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
    : `overlays`; `extendLib` and `lib` hold a single value, so for them only
    : `null`/`[ ]` (off) and `"*"` (on) apply. A `homeModules` selection also
    : covers an input that only exports the older `homeManagerModules` name:
    : that alias is read when `homeModules` is absent, and never touched when
    : it is present (flakes deprecating it warn on access). Naming entries is how you take
    : SEVERAL of a catalog's exports -- and it is validated: an unknown
    : channel key, an unknown entry name, or a case keyed by an input that is
    : not in `inputs` all throw, listing the valid options. An explicit
    : selection also overrides the built-in skips (the home-manager input,
    : nixpkgs trees), which only exist to prevent guessing. CHANNELS ONLY:
    : the `pkgs-*` specialArgs, `inputPkgs` and the home-manager capability
    : detection are computed from `inputs` directly and no case affects
    : them -- `inputContributions."nixpkgs-unstable" = null;` still yields a
    : `pkgs-unstable` specialArg. An input reached by hand via the
    : `inputs`/`inputPkgs` specialArgs likewise always works.
    : Example: `inputContributions."nixos-raspberrypi".overlays =
    : [ "bootloader" "vendor-kernel" ];`
    : Default `{ }`.

    `homeConfigurationsBuilder` accepts this same shared set, so both
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
  nixosConfigurationsBuilder =
    args: shared.mkSystem null (shared.validateBuilderArgs "nixosConfigurationsBuilder" [ ] args);
}
