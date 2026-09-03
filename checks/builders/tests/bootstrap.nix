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
  fixturesDir,
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
  # each login user is passed as `<user>=<attr>`: the flake attribute
  # resolved at BUILD time (see homeManagerBootstrapModule's attrFor), so
  # the login script never guesses a name it cannot verify. alice is
  # host-less here, bob has a hosts/laptop override.
  # The harness's `self` is a MOCK with only an outPath, so its
  # homeConfigurations cannot be introspected -- attrFor's documented
  # fallback keeps the historical `<u>@<host>` form. The resolving path
  # is covered by bootstrap-attr-resolves-hostless below.
  bootstrap-users-filtered =
    lib.hasInfix ''"--user-attrs" "alice=alice@laptop" "bob=bob@laptop"'' execStart
    && !(lib.hasInfix "dave" execStart);

  # ... and when the target flake's outputs ARE visible, a host-less home
  # resolves to the bare `<user>` attribute rather than `<user>@<host>`:
  # exactly the case a hardcoded shell string used to get wrong at login.
  bootstrap-attr-resolves-hostless =
    let
      refWithOutputs = {
        outPath = toString exampleDir;
        homeConfigurations = {
          alice = { };
        };
      };
      unit =
        (applyBootstrap { loginFlakeRef = refWithOutputs; }).systemd.user.services.home-manager-bootstrap;
    in
    lib.hasInfix ''"alice=alice"'' unit.serviceConfig.ExecStart;

  # ... and a flake that exports homeConfigurations but has NEITHER name
  # is a build-time throw, not a silent login-time failure on one machine
  bootstrap-attr-missing-throws =
    !(builtins.tryEval (
      (applyBootstrap {
        loginFlakeRef = {
          outPath = toString exampleDir;
          homeConfigurations = {
            someone-else = { };
          };
        };
      }).systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
    )).success;
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
        loginHomes = [ "alice" ];
        wrapHomeManagerSwitch = false;
      }
    ));

  # ── list loginFlakeRef: out of scope for the login bootstrap ──
  # per-user tree resolution (loginFlakeRefSources) only exists on the
  # account/mkNixosSystem side; this module still resolves ONE
  # effectiveFlakeRef shared by every loginHomes user, so a list here has
  # no single flake to activate against. Must fail loudly, not silently
  # guess against the wrong tree (see effectiveFlakeRef's own comment).
  bootstrap-list-loginflakeref-with-loginhomes-throws =
    !(builtins.tryEval (
      (applyBootstrap {
        loginFlakeRef = [ (fixturesDir + "/tree-per") ];
      }).systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
    )).success;
  # ... but only when there is an actual login-managed user to resolve on
  # THIS host -- a list loginFlakeRef alongside loginHomes that simply
  # doesn't apply here (nobody in loginHomes has a home) is unaffected:
  # the module self-gates to `{ }` the same as any other missing
  # prerequisite (bootstrap-gates-without-home-manager above), not a throw.
  bootstrap-list-loginflakeref-without-loginhomes-is-fine =
    applyBootstrap {
      loginFlakeRef = [ (fixturesDir + "/tree-per") ];
      loginHomes = [ ];
    } == { };
}
