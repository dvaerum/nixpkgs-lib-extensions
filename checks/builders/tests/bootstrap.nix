# The login-bootstrap systemd user service: its ExecStart CLI arguments,
# self-gating conditions and standalone use. (Runtime behavior is covered
# by checks/bootstrap/script.nix and the VM tests.)
{
  lib,
  myLib,
  nixpkgs,
  home-manager,
  inputs,
  system,
  laptop,
  server,
  execStart,
  bootstrapModuleFor,
  applyBootstrap,
  repoDir,
  exampleDir,
  ...
}:
let
  # ── wrapHomeManagerSwitch: a detach-safe `home-manager` for a login user
  #    to manually re-run `switch` between logins ──
  hasWrappedHomeManager =
    sys: lib.any (p: (p.name or "") == "home-manager-wrapped") sys.config.environment.systemPackages;
in
{
  # only loginHomes are bootstrapped: dave/frank/grace are system-managed,
  # eve is system-only (no home.nix). Parameters are CLI arguments on
  # ExecStart, quoted by escapeSystemdExecArgs (every argument is
  # double-quoted; % and $ are doubled for systemd's specifier syntax).
  bootstrap-users-filtered =
    lib.hasInfix ''"--users" "alice" "bob"'' execStart && !(lib.hasInfix "dave" execStart);
  bootstrap-flake-ref-defaults-to-self = lib.hasInfix ''"--flake-ref" "${toString exampleDir}"'' execStart;

  # systemd's own escaping, not shell escaping: a flake ref containing a
  # %-escape (a branch name with %2F, say) must reach the unit text with
  # the % DOUBLED, or systemd expands it as a specifier
  bootstrap-percent-ref-systemd-escaped =
    lib.hasInfix ''"--flake-ref" "github:me/repo?ref=feat%%2Fx"''
      (
        (applyBootstrap { loginFlakeRef = "github:me/repo?ref=feat%2Fx"; })
        .systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
      );

  # the server has no registry: no bootstrap
  server-no-bootstrap = !(server.config.systemd.user.services ? home-manager-bootstrap);

  # a loginHomes entry whose registry directory ships no home.nix (eve is
  # a config-only user) has nothing to bootstrap: no service
  no-bootstrap-for-config-only-login-user =
    !(
      (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "evelogin";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."eve" = exampleDir + "/users/eve";
        loginHomes = [ "eve" ];
      }).config.systemd.user.services ? home-manager-bootstrap
    );

  # loginHomes names matching NONE of the host's users are ignored without
  # error (the list is usually shared through _defaults across hosts):
  # alice stays system-managed, no bootstrap appears
  unknown-login-users-ignored =
    let
      sys = myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "ghostlogin";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."alice" = exampleDir + "/users/alice";
        loginHomes = [ "ghost" ];
      };
    in
    sys.config.home-manager.users ? alice
    && !(sys.config.systemd.user.services ? home-manager-bootstrap);

  # the bootstrap module works standalone, is tagged for error locations,
  # honors its options, and gates itself off when prerequisites miss
  bootstrap-standalone = applyBootstrap { } ? systemd;
  bootstrap-file-tagged =
    (bootstrapModuleFor { })._file == repoDir + "/lib/nixos/home-manager-bootstrap-module.nix";
  bootstrap-flake-ref-override = lib.hasInfix ''"--flake-ref" "/custom"'' (
    (applyBootstrap { loginFlakeRef = "/custom"; })
    .systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
  );
  bootstrap-reactivate-flag = lib.hasInfix ''"--reactivate-every-login"'' (
    (applyBootstrap { loginReactivateEveryLogin = true; })
    .systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
  );
  bootstrap-gates-without-home-manager =
    applyBootstrap {
      inputs = {
        self = inputs.self;
      };
    } == { };
  bootstrap-gates-without-flake-ref =
    applyBootstrap { inputs = { inherit nixpkgs home-manager; }; } == { };

  # laptop has login-managed users (alice, bob) shipping a home.nix: gets it
  wrapped-home-manager-for-login-host = hasWrappedHomeManager laptop;
  # the server has no registry, so no login user, so no wrapper either
  server-no-wrapped-home-manager = !(hasWrappedHomeManager server);

  # a loginHomes user with NO home.nix on this host (eve is config-only) is
  # the same self-gating condition the bootstrap service itself uses: no
  # wrapper, mirroring no-bootstrap-for-config-only-login-user above
  no-wrapper-for-config-only-login-user =
    !(hasWrappedHomeManager (
      myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "evelogin";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."eve" = exampleDir + "/users/eve";
        loginHomes = [ "eve" ];
      }
    ));

  # the escape hatch actually disables it
  wrap-home-manager-switch-false-disables =
    !(hasWrappedHomeManager (
      myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "nowrapper";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."alice" = exampleDir + "/users/alice";
        loginHomes = [ "alice" ];
        wrapHomeManagerSwitch = false;
      }
    ));
}
