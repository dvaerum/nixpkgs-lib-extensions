# This file is a function-file: the lib loader (lib/default.nix) applies it to
# `extLib` — the fully assembled nixpkgs-lib-extensions lib. Shared machinery
# lives in ./internal/shared.nix.
extLib:
let
  shared = import ./internal/shared.nix extLib;
in
{
  /**
    A NixOS module that provisions each user's standalone home-manager profile on
    login, via a systemd *user* service that runs `home-manager switch` in the
    background (so login is never hard-blocked). First-login-only by default.

    `nixosConfigurationsBuilder` includes this module automatically when it is
    given a non-empty `homeConfigurations` registry, so it normally does not need
    to be wired up by hand — direct use is for custom setups that build their
    NixOS systems some other way. It is driven by the home-configuration
    *registry* (the same one passed to `homeConfigurationsBuilder`) but is
    otherwise independent of the builders. Self-gating: when the registry is
    empty, the home-manager input is missing, the flake reference is unset or no
    user matches, the module is empty.

    # Example

    ```nix
    # Only needed when NOT using nixosConfigurationsBuilder:
    # extLib = inputs.nixpkgs-lib-extensions.lib
    {
      imports = [
        (extLib.homeManagerBootstrapModule {
          inherit inputs;
          hostname = "laptop";
          system   = "x86_64-linux";
          homeConfigurations = { "alice" = ./users/alice; };
        })
      ];
    }
    ```

    # Type

    ```
    homeManagerBootstrapModule :: Attribute -> Module
    ```

    # Arguments

    inputs
    : The flake's `inputs` set (home-manager detected by capability; `self` used
    : as the default flake reference).

    hostname
    : The host name; the `@<host>` suffix of the flake attribute to activate.

    system
    : The system double, e.g. `"x86_64-linux"`.

    homeConfigurations
    : The same registry passed to `homeConfigurationsBuilder`; its keys define
    : which users are bootstrapped on this host. Default `{ }`.

    flakeRef
    : Flake reference for `home-manager switch --flake <ref>#<user>@<host>`.
    : Default `inputs.self`.

    reactivateEveryLogin
    : Re-activate on every login instead of only the first. Default `false`.
  */
  homeManagerBootstrapModule =
    {
      inputs,
      hostname,
      system,
      homeConfigurations ? { },
      flakeRef ? null,
      reactivateEveryLogin ? false,
    }:
    let
      home-manager = shared.detectHomeManager inputs;
      homeManagerPkg = if home-manager == null then null else home-manager.packages.${system}.home-manager;
      effectiveFlakeRef = if flakeRef != null then flakeRef else (inputs.self or null);
      usersHome = shared.usersWithHome homeConfigurations hostname (
        shared.usersFromRegistry homeConfigurations hostname
      );
    in
    # `_file` points eval errors of this generated module at this file
    # instead of an anonymous <unknown-file> location.
    {
      _file = ./homeManagerBootstrapModule.nix;
      imports = [
        (
          {
            pkgs,
            lib,
            ...
          }:
          let
            # Binaries the script needs come from runtimeInputs (PATH);
            # parameters are passed as CLI arguments on ExecStart.
            bootstrapScript = import ./internal/bootstrap-script.nix {
              inherit pkgs;
              homeManager = homeManagerPkg;
            };
          in
          lib.optionalAttrs (homeManagerPkg != null && effectiveFlakeRef != null && usersHome != [ ]) {
            systemd.user.services.home-manager-bootstrap = {
              description = "Provision the user's home-manager profile on login";
              wantedBy = [ "default.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = lib.escapeShellArgs (
                  [
                    "${bootstrapScript}/bin/home-manager-bootstrap"
                    "--flake-ref"
                    (toString effectiveFlakeRef)
                    "--hostname"
                    hostname
                  ]
                  ++ lib.optional reactivateEveryLogin "--reactivate-every-login"
                  ++ [ "--users" ]
                  ++ usersHome
                );
              };
            };
          }
        )
      ];
    };
}
