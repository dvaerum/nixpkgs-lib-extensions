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
    other way. It is driven by a resolved users tree (`{ <username> =
    <directory>; }` -- note this is the RESOLVED tree, unlike
    `mkNixosSystem`'s `users`, which is a list of names to select)
    filtered by `loginHomes` but is otherwise independent of
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
          users = { alice = ./users/alice; };
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
    : The host name. Used to look for a `<user>@<hostname>` output (and
    : falling back to a bare `<user>` one) when resolving what to
    : activate -- see `loginFlakeRef`.

    system
    : The system double, e.g. `"x86_64-linux"`.

    users
    : The users tree (`{ <username> = <directory>; }`, as `mkNixosSystem`
    : resolves it). Default `{ }`.

    loginHomes
    : The usernames whose homes are login-managed; only these are
    : bootstrapped (and only when the users tree gives them a `home.nix`
    : on this host). Default `[ ]` (module is empty).

    loginFlakeRef
    : Flake reference for `home-manager switch --flake <ref>#<user>@<host>`;
    : the flake at this reference must export a matching
    : `homeConfigurations."<user>@<host>"` or `."<user>"` output. Which
    : one is used is decided at EVALUATION time by looking at that
    : flake's actual outputs: the host-suffixed name wins when present,
    : else the bare one, and a flake that exports `homeConfigurations`
    : holding neither throws during evaluation. Two cases cannot be
    : introspected and keep the `<user>@<host>` form: a flake-ref
    : STRING, and a flake exporting no `homeConfigurations` at all. The default
    : `inputs.self` is the immutable store copy of your flake the system
    : was built from (homes match the last `nixos-rebuild`); use a mutable
    : reference like `"/etc/nixos"` to build homes from a live checkout.
    : This module always resolves against ONE flake shared by every
    : login-managed user -- unlike `mkNixosSystem`'s own `loginFlakeRef`
    : (which also selects account/`configuration.nix` sources and accepts
    : a LIST of them), a list value here THROWS if any login-managed user
    : actually needs resolving: there is no per-user tree to pick from at
    : this level.
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
      # `loginFlakeRefSources`'s wrapper form, unwrapped: a singular
      # `{ source; allowNixosConfig; }` names the SOURCE at `.source`, not
      # itself a flake ref. This module never touches configuration.nix,
      # so the trust flag is irrelevant here -- only the activation
      # target matters. A LIST is handled separately below (effectiveFlakeRef);
      # `singularRef` is meaningless (and unused) in that case.
      singularRef =
        let
          v = if loginFlakeRef != null then loginFlakeRef else (inputs.self or null);
        in
        if lib.isAttrs v && v ? source then v.source else v;

      # A STRING loginFlakeRef (not a flake input) is a deliberate escape
      # hatch -- see its own doc comment and stringFlakeRefWarning's comment
      # (registry.nix) for why it's warned rather than rejected. A real,
      # tested capability (checks/builders/tests/bootstrap.nix exercises
      # both a bare path string and full flake-ref syntax), not a mistake.
      warnStringFlakeRef =
        v:
        if lib.isString singularRef then
          lib.warn (shared.stringFlakeRefWarning hostname singularRef) v
        else
          v;
      # login-managed users with an actual home.nix on this host
      usersHome = shared.loginUsersWithHome users hostname loginHomes;

      # `loginFlakeRefSources` (registry.nix) lets DIFFERENT users live in
      # DIFFERENT trees for account/configuration.nix discovery, but this
      # module resolves ONE effectiveFlakeRef/attrFor pair shared by every
      # user in usersHome -- there is no per-user tree here to pick from.
      # Fail loudly rather than silently falling back to attrFor's
      # historical `<u>@<hostname>` guess against what could be the wrong
      # tree entirely. Only matters when there is an actual login-managed
      # user to resolve on THIS host -- a fleet-wide `loginHomes` that
      # simply doesn't apply here is unaffected.
      effectiveFlakeRef =
        if lib.isList loginFlakeRef && usersHome != [ ] then
          throw "homeManagerBootstrapModule: host `${hostname}`: loginFlakeRef is a list (multiple users trees), which the login bootstrap cannot resolve per-user -- it activates every loginHomes user against ONE flake. Keep ${lib.concatStringsSep ", " usersHome} system-managed instead (drop them from loginHomes), or use a single, non-list loginFlakeRef for this host."
        else if lib.isList loginFlakeRef then
          # never forced further: usersHome == [ ] short-circuits below
          loginFlakeRef
        else
          warnStringFlakeRef singularRef;

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
