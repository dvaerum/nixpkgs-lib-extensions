# This file is a function-file: the lib loader (lib/default.nix) applies it to
# `extLib` — the fully assembled nixpkgs-lib-extensions lib. Shared machinery
# lives in ./internal/shared.nix.
extLib:
let
  shared = import ./internal/shared.nix extLib;
in
{
  /**
    Build ONE user's standalone home-manager configuration for one host —
    the single-user primitive underneath `buildHomeConfigurations`, which
    calls it for every login-managed user of every host. Use it directly
    to export an individual home:

    ```nix
    homeConfigurations."alice@laptop" =
      extLib.homeConfigurationsBuilder {
        inherit inputs system;
        hostname = "laptop";
        username = "alice";
        userRegistry."alice" = ./users/alice;
      };
    ```

    The user's `home.nix` files come from the `userRegistry` entries
    matching the host (`"<user>@<host>"` and `"<user>@*"` merge; plain
    `"<user>"` is the standalone fallback). Companion `configuration.nix`
    files are ignored here — they are system configuration, imported by
    `nixosConfigurationsBuilder`. Shares the package set, `specialArgs`
    and auto-collected home-manager modules with the other builders (it
    accepts the same shared options). The home-manager input is detected
    by capability (its `lib` exposes `homeManagerConfiguration`),
    regardless of the input's name.

    Throws when no home-manager input exists or the user has no matching
    `home.nix` on this host — a single requested home that cannot be
    built is an error, not an empty result.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.homeConfigurationsBuilder {
      inherit inputs;
      hostname = "laptop";
      system   = "x86_64-linux";
      username = "alice";
      userRegistry = {
        "alice@*"      = ./users/alice;
        "alice@laptop" = ./users/alice-laptop; # merged in on laptop
      };
    }
    =>
    <homeManagerConfiguration for alice@laptop>
    ```

    # Type

    ```
    homeConfigurationsBuilder :: Attribute -> HomeManagerConfiguration
    ```

    # Arguments

    inputs
    : The flake's `inputs` set. The home-manager input is detected by capability.

    hostname
    : The host name the home is built for (selects the matching registry
    : entries).

    username
    : The user whose home to build.

    system
    : The system double, e.g. `"x86_64-linux"`.

    userRegistry
    : The user registry (same shape as in `nixosConfigurationsBuilder`);
    : only the entries matching `username` on `hostname` are used here.
    : Default `{ }`.
    : NOTE: in a git-backed flake, `git add` new files or they are
    : invisible to the flake and skipped silently.

    homeSharedModules
    : home-manager modules added to the home configuration, on top of those
    : auto-collected from `inputs`. Default `[ ]`.

    The home configuration gets overridable (`mkDefault`) values for
    `home.username` (the user), `home.homeDirectory` (`/home/<user>`) and
    `home.stateVersion` -- the latter tracks the CURRENT nixpkgs release,
    so pin it in the user's `home.nix` if you rely on stateVersion
    semantics.

    nixpkgs, systemType, specialArgs, additionalSpecialArgs, tags, patches,
    nixpkgsConfig, extraOverlays, allowedUnfreePackages,
    permittedInsecurePackages, rootPath
    : Shared options (see `nixosConfigurationsBuilder`).
  */
  homeConfigurationsBuilder =
    {
      inputs,
      hostname,
      system,
      username,
      userRegistry ? { },
      homeSharedModules ? [ ],
      ...
    }@args:
    let
      # throws on unknown argument names -- forced via the seq below
      validArgs = shared.validateBuilderArgs "homeConfigurationsBuilder" [ "username" ] args;
      ctx = shared.mkContext validArgs;
      inherit (ctx)
        lib
        pkgs
        mySpecialArguments
        home-manager
        autoHomeModules
        ;

      registry = if userRegistry == null then { } else userRegistry;
      homeModules = (shared.resolveUser registry hostname username).homeModules;
    in
    builtins.seq validArgs (
      if home-manager == null then
        throw ''
          homeConfigurationsBuilder: no home-manager input found (detected
          by capability: an input whose `lib` has `homeManagerConfiguration`).
        ''
      else if homeModules == [ ] then
        throw ''
          homeConfigurationsBuilder: `${username}` has no home.nix in
          `userRegistry` matching host `${hostname}` (unmatched keys,
          or a system-only entry shipping just a configuration.nix).
        ''
      else
        home-manager.lib.homeManagerConfiguration {
          # `lib` explicitly: home-manager re-fixes the module lib via
          # lib.extend, so it must start from the context lib (extLib,
          # input extendLibs and namespaced input libs are all inside its
          # fixed point) -- with the default pkgs.lib the namespaced input
          # libs would be lost in that re-fix
          inherit pkgs lib;
          extraSpecialArgs = mySpecialArguments // {
            inherit username;
            listOfUsernames = shared.usersFromRegistry registry hostname;
          };
          modules =
            autoHomeModules
            ++ homeSharedModules
            # all matched home.nix files: "<user>@*" and "<user>@<host>" merge
            ++ homeModules
            ++ [
              {
                _file = ./homeConfigurationsBuilder.nix;
                home.username = lib.mkDefault username;
                home.homeDirectory = lib.mkDefault "/home/${username}";
                home.stateVersion = lib.mkDefault lib.trivial.release;
              }
            ];
        }
    );
}
