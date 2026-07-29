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
  server,
  execStart,
  bootstrapModuleFor,
  applyBootstrap,
  repoDir,
  exampleDir,
  ...
}:
{
  # only loginUsers are bootstrapped: dave/frank/grace are system-managed,
  # eve is system-only (no home.nix). Parameters are CLI arguments on
  # ExecStart (escapeShellArgs only quotes arguments when required, so
  # simple words appear bare).
  bootstrap-users-filtered =
    lib.hasInfix "--users alice bob" execStart && !(lib.hasInfix "dave" execStart);
  bootstrap-flake-ref-defaults-to-self = lib.hasInfix "--flake-ref ${toString exampleDir}" execStart;

  # the server has no registry: no bootstrap
  server-no-bootstrap = !(server.config.systemd.user.services ? home-manager-bootstrap);

  # a loginUsers entry whose registry directory ships no home.nix (eve is
  # a config-only user) has nothing to bootstrap: no service
  no-bootstrap-for-config-only-login-user =
    !(
      (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "evelogin";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."eve" = exampleDir + "/users/eve";
        loginUsers = [ "eve" ];
      }).config.systemd.user.services
      ? home-manager-bootstrap
    );

  # loginUsers names matching NONE of the host's users are ignored without
  # error (the list is usually shared through _defaults across hosts):
  # alice stays system-managed, no bootstrap appears
  unknown-login-users-ignored =
    let
      sys = myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "ghostlogin";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."alice" = exampleDir + "/users/alice";
        loginUsers = [ "ghost" ];
      };
    in
    sys.config.home-manager.users ? alice
    && !(sys.config.systemd.user.services ? home-manager-bootstrap);

  # the bootstrap module works standalone, is tagged for error locations,
  # honors its options, and gates itself off when prerequisites miss
  bootstrap-standalone = applyBootstrap { } ? systemd;
  bootstrap-file-tagged =
    (bootstrapModuleFor { })._file == repoDir + "/lib/nixos/homeManagerBootstrapModule.nix";
  bootstrap-flake-ref-override = lib.hasInfix "--flake-ref /custom" (
    (applyBootstrap { loginFlakeRef = "/custom"; })
    .systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
  );
  bootstrap-reactivate-flag = lib.hasInfix "--reactivate-every-login" (
    (applyBootstrap { loginReactivateEveryLogin = true; })
    .systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
  );
  bootstrap-gates-without-home-manager = applyBootstrap { inputs = { self = inputs.self; }; } == { };
  bootstrap-gates-without-flake-ref =
    applyBootstrap { inputs = { inherit nixpkgs home-manager; }; } == { };
}
