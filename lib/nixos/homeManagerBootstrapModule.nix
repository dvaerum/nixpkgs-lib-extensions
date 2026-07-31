# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
# Shared machinery lives in ./internal/shared.nix.
{ self, lib, ... }:
let
  shared = import ./internal/shared.nix { inherit lib self; };
in
{
  /**
    A NixOS module that provisions each user's standalone home-manager profile on
    login, via a systemd *user* service that runs `home-manager switch` in the
    background (so login is never hard-blocked). First-login-only by default.

    `nixosConfigurationsBuilder` includes this module automatically when it
    has `loginHomes`, so it normally does not need to be wired up by hand —
    direct use is for custom setups that build their NixOS systems some
    other way. It is driven by the `userRegistry` filtered by `loginHomes`
    (the same arguments the builders take) but is otherwise independent of
    the builders. Self-gating: when no login user matches, the home-manager
    input is missing or the flake reference is unset, the module is empty.

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
          userRegistry = { "alice" = ./users/alice; };
          loginHomes = [ "alice" ];
        })
      ];
    }
    ```

    See
    [The bootstrap without the builders](getting-started.md#the-bootstrap-without-the-builders)
    for a complete standalone flake, including what this module does
    NOT do compared to the builder setup.

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

    userRegistry
    : The user registry (as in `nixosConfigurationsBuilder`). Default `{ }`.

    loginHomes
    : The usernames whose homes are login-managed; only these are
    : bootstrapped (and only when the registry gives them a `home.nix`
    : on this host). Default `[ ]` (module is empty).

    loginFlakeRef
    : Flake reference for `home-manager switch --flake <ref>#<user>@<host>`;
    : the flake at this reference must export those
    : `homeConfigurations."<user>@<host>"` outputs. The default
    : `inputs.self` is the immutable store copy of your flake the system
    : was built from (homes match the last `nixos-rebuild`); use a mutable
    : reference like `"/etc/nixos"` to build homes from a live checkout.
    : Default `inputs.self`.

    loginReactivateEveryLogin
    : Re-activate on every login instead of only the first. Default `false`.

    homeManager
    : Explicit home-manager input, bypassing capability detection.
    : Default `null` (detect).
  */
  homeManagerBootstrapModule =
    {
      inputs,
      hostname,
      system,
      userRegistry ? { },
      loginHomes ? [ ],
      loginFlakeRef ? null,
      loginReactivateEveryLogin ? false,
      homeManager ? null,
    }:
    let
      home-manager = if homeManager != null then homeManager else shared.detectHomeManager inputs;
      homeManagerPkg =
        if home-manager == null then null else home-manager.packages.${system}.home-manager;
      effectiveFlakeRef = if loginFlakeRef != null then loginFlakeRef else (inputs.self or null);
      registry = if userRegistry == null then { } else userRegistry;
      # login-managed users with an actual home.nix on this host
      usersHome = shared.loginUsersWithHome registry hostname loginHomes;
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
                  ++ lib.optional loginReactivateEveryLogin "--reactivate-every-login"
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
