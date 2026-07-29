# This file is a function-file: the lib loader (lib/default.nix) applies it to
# `extLib` — the fully assembled nixpkgs-lib-extensions lib. Shared machinery
# lives in ./internal/shared.nix.
extLib:
let
  shared = import ./internal/shared.nix extLib;
in
{
  /**
    Build the standalone home-manager configurations for a host's users, from an
    explicit registry, keyed `"<user>@<hostname>"`.

    Shares the package set, `specialArgs` and auto-collected home-manager modules
    with `nixosConfigurationsBuilder` (it accepts the same shared options). The
    home-manager input is detected by capability (its `lib` exposes
    `homeManagerConfiguration`), regardless of the input's name; when no such
    input exists the result is an empty set.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.homeConfigurationsBuilder {
      inherit inputs;
      hostname = "laptop";
      system   = "x86_64-linux";
      # Every value is a DIRECTORY with home.nix and/or configuration.nix.
      # "alice@*" applies everywhere and MERGES with "alice@laptop" here;
      # "bob" is a standalone default (used since no bob@... matches).
      homeConfigurations = {
        "alice@*"      = ./users/alice;
        "alice@laptop" = ./users/alice-laptop;
        "bob"          = ./users/bob;
      };
    }
    =>
    {
      "alice@laptop" = { ... };
      "bob@laptop" = { ... };
    }
    ```

    Assign the result to your flake's `homeConfigurations` output.

    # Type

    ```
    homeConfigurationsBuilder :: Attribute -> Attribute
    ```

    # Arguments

    inputs
    : The flake's `inputs` set. The home-manager input is detected by capability.

    hostname
    : The host name; the `@<host>` suffix of each generated home configuration.

    system
    : The system double, e.g. `"x86_64-linux"`.

    homeConfigurations
    : Registry of user configuration DIRECTORIES, each containing `home.nix`
    : and/or `configuration.nix`. Key forms: `"<user>@<host>"` (this host),
    : `"<user>@*"` (every host; merges with a matching host entry), and
    : `"<user>"` (standalone default, only used when no @-entry matched).
    : This builder imports the matched `home.nix` files; companion
    : `configuration.nix` files are ignored here but imported into the system
    : by `nixosConfigurationsBuilder` (account/groups). Directories with only
    : a `configuration.nix` are system-only users: no home output here.
    : Default `{ }`. NOTE: in a git-backed flake, `git add` new files or they
    : are invisible to the flake and skipped silently.

    homeSharedModules
    : home-manager modules added to every home configuration, on top of those
    : auto-collected from `inputs`. Default `[ ]`.

    Each home configuration gets overridable (`mkDefault`) values for
    `home.username` (the user), `home.homeDirectory` (`/home/<user>`) and
    `home.stateVersion` -- the latter tracks the CURRENT nixpkgs release,
    so pin it in the user's `home.nix` if you rely on stateVersion
    semantics.

    nixpkgs, systemType, specialArgs, tags, patches,
    extraOverlays, allowedUnfreePackages, permittedInsecurePackages, rootPath
    : Shared options (see `nixosConfigurationsBuilder`).
  */
  homeConfigurationsBuilder =
    {
      inputs,
      hostname,
      system,
      homeConfigurations ? { },
      homeSharedModules ? [ ],
      ...
    }@args:
    let
      ctx = shared.mkContext args;
      inherit (ctx)
        lib
        pkgs
        mySpecialArguments
        home-manager
        autoHomeModules
        ;

      # The host's users, derived from the registry keys ("<user>@<host>" for
      # this host plus plain "<user>" fallback entries).
      users = shared.usersFromRegistry homeConfigurations hostname;

      mkHome =
        username:
        home-manager.lib.homeManagerConfiguration {
          # `lib` explicitly: home-manager re-fixes the module lib via
          # lib.extend, so it must start from the context lib (extLib,
          # input extendLibs and namespaced input libs are all inside its
          # fixed point) -- with the default pkgs.lib the namespaced input
          # libs would be lost in that re-fix
          inherit pkgs lib;
          extraSpecialArgs = mySpecialArguments // {
            inherit username;
            listOfUsernames = users;
          };
          modules =
            autoHomeModules
            ++ homeSharedModules
            # all matched home.nix files: "<user>@*" and "<user>@<host>" merge
            ++ (shared.resolveUser homeConfigurations hostname username).homeModules
            ++ [
              {
                _file = ./homeConfigurationsBuilder.nix;
                home.username = lib.mkDefault username;
                home.homeDirectory = lib.mkDefault "/home/${username}";
                home.stateVersion = lib.mkDefault lib.trivial.release;
              }
            ];
        };
    in
    # Returned as { "<user>@<host>" = <homeManagerConfiguration>; ... }:
    # assign/merge the result into your flake's `homeConfigurations` output
    # yourself. Empty when no home-manager input exists.
    if home-manager == null then
      { }
    else
      builtins.listToAttrs (
        map (u: {
          name = "${u}@${hostname}";
          value = mkHome u;
        })
        # only users with an actual home config get an output (a directory
        # entry shipping only a configuration.nix is system-only)
        (shared.usersWithHome homeConfigurations hostname users)
      );
}
