# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
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

    `mkNixosSystem` includes this module automatically when it
    has `loginHomes`, so it normally does not need to be wired up by hand —
    direct use is for custom setups that build their NixOS systems some
    other way. It is driven by the `userRegistry` filtered by `loginHomes`
    (the same arguments the builders take) but is otherwise independent of
    the builders. Self-gating: when no login user matches, the home-manager
    input is missing or the flake reference is unset, the module is empty.

    # Example

    ```nix
    # Only needed when NOT using mkNixosSystem:
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

    users
    : The users tree (`{ <username> = <directory>; }`, as `mkNixosSystem`
    : resolves it). Default `{ }`.

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
      users ? { },
      loginHomes ? [ ],
      loginFlakeRef ? null,
      loginReactivateEveryLogin ? false,
      homeManager ? null,
    }:
    let
      home-manager = if homeManager != null then homeManager else shared.detectHomeManager inputs;
      homeManagerPkg =
        if home-manager == null then null else home-manager.packages.${system}.home-manager;
      # A STRING loginFlakeRef (not a flake input) is a deliberate escape
      # hatch -- see its own doc comment and stringFlakeRefWarning's comment
      # (registry.nix) for why it's warned rather than rejected. A real,
      # tested capability (checks/builders/tests/bootstrap.nix exercises
      # both a bare path string and full flake-ref syntax), not a mistake.
      warnStringFlakeRef =
        v:
        if lib.isString loginFlakeRef then
          lib.warn (shared.stringFlakeRefWarning hostname loginFlakeRef) v
        else
          v;
      effectiveFlakeRef = warnStringFlakeRef (
        if loginFlakeRef != null then loginFlakeRef else (inputs.self or null)
      );
      # login-managed users with an actual home.nix on this host
      usersHome = shared.loginUsersWithHome users hostname loginHomes;

      # WHICH flake attribute each user's home is exported under. A
      # host-agnostic user is `homeConfigurations."<u>"`; one with a
      # `hosts/<hostname>` override is `"<u>@<hostname>"`. Resolved HERE,
      # at Nix evaluation time, rather than reconstructed by the login
      # script: the script cannot see the target flake's outputs, so a
      # name it guesses wrong fails silently at someone's next login on
      # one machine. `?` on a real flake input is cheap and forces no
      # home. A STRING loginFlakeRef is not introspectable at all, so it
      # keeps the historical `<u>@<hostname>` form.
      attrFor =
        u:
        # Only decide from outputs we can actually SEE. A string ref, or an
        # input whose `homeConfigurations` is not readable here (a mock, or
        # a flake whose outputs this evaluation does not force), keeps the
        # historical `<u>@<hostname>` form rather than guessing; the throw
        # is reserved for the one case we can prove wrong -- the outputs
        # exist and contain neither name.
        if !(lib.isAttrs effectiveFlakeRef) || !(effectiveFlakeRef ? homeConfigurations) then
          "${u}@${hostname}"
        else if effectiveFlakeRef.homeConfigurations ? "${u}@${hostname}" then
          "${u}@${hostname}"
        else if effectiveFlakeRef.homeConfigurations ? ${u} then
          u
        else
          throw "homeManagerBootstrapModule: host `${hostname}`: `${toString effectiveFlakeRef}` exports homeConfigurations, but neither `${u}@${hostname}` nor `${u}` is among them, so the login bootstrap would have nothing to activate for `${u}`. Give `${u}` a home.nix in that flake's users/ tree (optionally under hosts/${hostname}/), or drop them from loginHomes.";
    in
    # `_file` points eval errors of this generated module at this file
    # instead of an anonymous <unknown-file> location.
    {
      _file = ./home-manager-bootstrap-module.nix;
      imports = [
        (
          # `utils` is the NixOS module argument carrying
          # escapeSystemdExecArgs -- the systemd-aware quoting (ExecStart
          # lines have their own %-specifier and $-expansion syntax, which
          # lib.escapeShellArgs knows nothing about; a flake ref containing
          # %2F used to reach the unit text unescaped).
          {
            pkgs,
            lib,
            utils,
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
              # StartLimit* belong to [Unit]: at most 4 start attempts per
              # 10 minutes, bounding the Restart loop below.
              unitConfig = {
                StartLimitBurst = 4;
                StartLimitIntervalSec = "10min";
              };
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                # a switch can fail transiently (network, substituters);
                # retry within the session, bounded by the StartLimit
                # above. systemd >= 244 allows Restart=on-failure for
                # oneshot units; on success RemainAfterExit keeps the unit
                # active, and on-failure never fires there.
                Restart = "on-failure";
                RestartSec = "30s";
                # a background provisioning job must not starve the
                # session it runs under
                Nice = 10;
                IOSchedulingClass = "best-effort";
                # a first `home-manager switch` may legitimately build for
                # a long time; the default 90s start timeout would kill it
                TimeoutStartSec = "2h";
                ExecStart = utils.escapeSystemdExecArgs (
                  [
                    "${bootstrapScript}/bin/home-manager-bootstrap"
                    "--flake-ref"
                    (toString effectiveFlakeRef)
                    "--hostname"
                    hostname
                  ]
                  ++ lib.optional loginReactivateEveryLogin "--reactivate-every-login"
                  ++ [ "--user-attrs" ]
                  ++ map (u: "${u}=${attrFor u}") usersHome
                );
              };
            };
          }
        )
      ];
    };
}
