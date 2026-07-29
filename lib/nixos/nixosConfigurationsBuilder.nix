# This file is a function-file: the lib loader (lib/default.nix) applies it to
# `extLib` — the fully assembled nixpkgs-lib-extensions lib. Shared machinery
# lives in ./internal/shared.nix.
extLib:
let
  shared = import ./internal/shared.nix extLib;
in
{
  /**
    Build a NixOS system for a host.

    The flake `inputs` are passed as a field, and a number of things are wired in
    automatically when the matching input exists:

    - NixOS modules from any input exposing `nixosModules.default` (excluded:
      the home-manager input, since it is used standalone, and nixpkgs trees
      -- anything with `legacyPackages` AND `lib.nixosSystem` -- whose helper
      modules would break the system; opt out more via `excludeModuleInputs`).
      The `default` export is auto-loaded; without one, a set with exactly one
      entry is used as-is (sops-nix style), while a multi-entry set is treated
      as a catalog of opt-in entries (nixos-hardware style) and contributes
      nothing -- import catalog entries explicitly, e.g.
      `inputs.nixos-hardware.nixosModules.dell-xps-13-9310`.
    - overlays from any input exposing `overlays.default` (same rule).
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
      are not namespaced at all (their lib is the base).
    - every `nixpkgs-*` input as a `pkgs-*` specialArg (e.g. `inputs.nixpkgs-unstable`
      becomes the `pkgs-unstable` specialArg).

    The whole `inputs` set is also passed through as the `inputs` specialArg
    (and home-manager extraSpecialArg), so modules can reach anything not
    covered by those conventions (e.g. `inputs.fenix`) themselves — the
    builders carry no policy for specific inputs. The only per-input handling
    is a small normalization table for flakes with nonstandard export names
    (currently just `nur`, whose `modules.nixos`/`modules.homeManager` are
    mapped onto the standard conventions); it applies strictly by input name.
    As a convenience, `inputPkgs` holds every input's packages pre-selected
    for the host's system (`inputPkgs.disko.disko-install`); they are
    deliberately not merged into `pkgs`, where input names would shadow
    nixpkgs attributes.

    The host's own configuration is included by convention: relative to
    `rootPath` (default: the consuming flake, `inputs.self`), either
    `hosts/<hostname>.nix` or `hosts/<hostname>/configuration.nix` is
    imported automatically when it exists (both existing is an error).
    Setting `systemType` groups hosts one folder deeper: the lookup then
    happens under `hosts/<systemType>/` instead of `hosts/`.

    The host's users are derived from the `homeConfigurations` registry keys —
    there is no separate `users` argument. Home configurations are built
    separately by `homeConfigurationsBuilder`, but when a `homeConfigurations`
    registry is passed here as well, the login bootstrap
    (`homeManagerBootstrapModule`) is included automatically. Without a registry
    (or without a home-manager input) no bootstrap is added.

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

      # Same registry as homeConfigurationsBuilder; defines the host's users
      # and enables the login bootstrap. Every value is a DIRECTORY with
      # home.nix and/or configuration.nix.
      homeConfigurations = {
        "alice@*"      = ./users/alice;        # on every host
        "alice@laptop" = ./users/alice-laptop; # merged in on laptop
        "bob"          = ./users/bob;          # only when no bob@... matches
      };
    }
    =>
    { laptop = <nixosSystem>; }
    ```

    Assign the result to your flake's `nixosConfigurations` output, merging
    several hosts with `//` — or use `buildNixosConfigurations` to build a
    whole set of hosts in one call.

    # Type

    ```
    nixosConfigurationsBuilder :: Attribute -> Attribute
    ```

    # Arguments

    inputs
    : The flake's `inputs` set. Used to auto-discover modules, overlays, lib
    : extensions and `nixpkgs-*` variants.

    hostname
    : The host name; also the key of the returned attrset.

    system
    : The system double, e.g. `"x86_64-linux"`.

    nixpkgs
    : The single preferred nixpkgs flake used to build the system. Default `inputs.nixpkgs`.

    modules
    : Extra NixOS modules, on top of those auto-collected from `inputs` and
    : the host's own `hosts/<hostname>(.nix|/configuration.nix)`. Default `[ ]`.

    additionalModules
    : Further NixOS modules, appended after `modules`. Default `[ ]`.
    : With `buildNixosConfigurations` this is the per-host half of the
    : layered pair: shared modules go in `_defaults.modules`, a host's
    : extras go here.

    userModuleFn
    : A function `username -> NixOS module`, applied for each user derived from
    : `homeConfigurations`. Defaults to `normalUserModule`, which creates a
    : normal login account per user; pass your own function for richer
    : accounts, or `null` to disable account creation entirely.

    excludeModuleInputs
    : Input names to skip when auto-collecting NixOS modules. Default `[ ]`.

    homeConfigurations
    : The registry also passed to `homeConfigurationsBuilder`. Every value
    : must be a DIRECTORY containing `home.nix` (the user's home-manager
    : config) and/or `configuration.nix` (NixOS config for that user: the
    : account, its groups, ...). Companion `configuration.nix` files are
    : imported into the system automatically; a directory with only a
    : `configuration.nix` is a system-only user (no home output, no login
    : bootstrap). Keys select where an entry applies:
    :   `"<user>@<host>"`  this host only
    :   `"<user>@*"`       every host; MERGES with a matching `"<user>@<host>"`
    :   `"<user>"`         standalone default, used only when NO @-entry
    :                      matched -- never merged with @-entries (a shadowed
    :                      plain entry triggers an eval warning; import its
    :                      directory explicitly from an @-entry to reuse it)
    : Example: with `"alice@*"` and `"alice@laptop"` both defined, both
    : apply on laptop; a plain `"alice"` would then never be used anywhere.
    : The keys define the host's users (exposed as `listOfUsernames`); when
    : the registry is non-empty and a home-manager input exists the login
    : bootstrap is enabled. `null` or `{ }` disables all of it. Default `{ }`.
    : WARNING: in a git-backed flake only TRACKED files exist -- `git add` a
    : new home.nix/configuration.nix or it is skipped silently.

    flakeRef
    : Flake reference used by the login bootstrap. Default `inputs.self`.

    reactivateEveryLogin
    : Bootstrap re-activates on every login instead of only the first. Default `false`.

    tags
    : List of string tags, passed to modules as the `tags` specialArg.
    : `"cudaSupport"` is the one tag with package-set effect (it enables
    : `nixpkgs.config.cudaSupport`). Default `[ ]`.

    patches
    : Patch files applied to the nixpkgs SOURCE tree (via `applyPatches`)
    : before the system is evaluated from it. Default `[ ]` (no patching,
    : no source copy).

    extraOverlays
    : Overlays applied on top of the ones auto-collected from `inputs`.
    : Default `[ ]`.

    allowedUnfreePackages
    : Unfree package names to allow (matched by `lib.getName` via
    : `allowUnfreePredicate`). Default `[ ]`.

    permittedInsecurePackages
    : Passed through to `nixpkgs.config.permittedInsecurePackages`.
    : Default `[ ]`.

    specialArgs
    : Extra specialArgs merged after everything the builder assembled
    : (including `inputs`, `rootPath`, ...), overriding it. Default `{ }`.

    additionalSpecialArgs
    : Further specialArgs merged after `specialArgs`, overriding it on
    : conflicts. Default `{ }`. With `buildNixosConfigurations` this is
    : the per-host half of the layered pair: shared specialArgs go in
    : `_defaults.specialArgs`, a host's extras go here.

    systemType
    : Free-form host classification, e.g. `"vm"` or `"server"`. Passed to
    : modules as the `systemType` specialArg, and when non-null the host
    : config convention looks under `hosts/<systemType>/` instead of
    : `hosts/`. Default `null` (no grouping folder).

    desktopEnvironment
    : Passed to modules as the `desktopEnvironment` specialArg; has no
    : effect beyond that. Default `"plasma"`.

    rootPath
    : The root for the `hosts/<hostname>` convention and the `rootPath`
    : specialArg. Default `inputs.self` (the consuming flake).

    `homeConfigurationsBuilder` accepts this same shared set, so both
    builders can be called with one common argument attrset.
  */
  nixosConfigurationsBuilder =
    {
      inputs,
      hostname,
      system,
      modules ? [ ],
      additionalModules ? [ ],
      userModuleFn ? extLib.normalUserModule,
      homeConfigurations ? { },
      flakeRef ? null,
      reactivateEveryLogin ? false,
      ...
    }@args:
    let
      ctx = shared.mkContext args;
      inherit (ctx)
        lib
        pkgs
        selectedSrc
        mySpecialArguments
        autoNixosModules
        ;

      registry = if homeConfigurations == null then { } else homeConfigurations;

      # The host's users, derived from the registry keys ("<user>@<host>" for
      # this host plus plain "<user>" fallback entries).
      users = shared.usersFromRegistry registry hostname;

      perUserModules = lib.optionals (userModuleFn != null) (lib.forEach users userModuleFn);

      # Every matched registry directory may ship a configuration.nix
      # (e.g. creating the user's account and groups); all of them are
      # applied to the system automatically.
      userNixosConfigs = lib.concatMap (u: (shared.resolveUser registry hostname u).nixosModules) users;

      # The host's own configuration, by convention relative to `rootPath`
      # (default: the consuming flake, `inputs.self`): either
      # hosts/<hostname>.nix or hosts/<hostname>/configuration.nix -- and
      # when `systemType` is set, grouped one level deeper under
      # hosts/<systemType>/.
      autoHostModules =
        let
          hostsDir =
            mySpecialArguments.rootPath
            + (if mySpecialArguments.systemType == null then "/hosts" else "/hosts/${mySpecialArguments.systemType}");
          file = hostsDir + "/${hostname}.nix";
          dir = hostsDir + "/${hostname}/configuration.nix";
          fileExists = builtins.pathExists file;
          dirExists = builtins.pathExists dir;
        in
        if fileExists && dirExists then
          throw ''
            nixosConfigurationsBuilder: host `${hostname}` has both
            ${toString file} and ${toString dir}; keep only one.
          ''
        else
          lib.optional fileExists file ++ lib.optional dirExists dir;

      # Login bootstrap, reusing the host's arguments. Self-gating: it evaluates
      # to an empty module when `homeConfigurations` is null/empty or no
      # home-manager input exists.
      bootstrapModule = extLib.homeManagerBootstrapModule {
        inherit
          inputs
          hostname
          system
          flakeRef
          reactivateEveryLogin
          ;
        homeConfigurations = registry;
      };
    in
    # Returned as { <hostname> = <system>; }: assign/merge the result into
    # your flake's `nixosConfigurations` output yourself.
    {
      ${hostname} = import "${selectedSrc}/nixos/lib/eval-config.nix" {
        inherit system lib pkgs;
        specialArgs = mySpecialArguments // {
          listOfUsernames = users;
        };
        modules =
          [
            {
              _file = ./nixosConfigurationsBuilder.nix;
              networking.hostName = lib.mkDefault hostname;
            }
            bootstrapModule
          ]
          ++ autoNixosModules
          ++ autoHostModules
          ++ modules
          ++ perUserModules
          ++ userNixosConfigs
          ++ additionalModules;
      };
    };
}
