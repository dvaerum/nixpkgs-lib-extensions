# The login-bootstrap systemd user service: its ExecStart CLI arguments,
# self-gating conditions and standalone use. (Runtime behavior is covered
# by checks/bootstrap-script.nix and the two VM tests.)
{
  lib,
  nixpkgs,
  home-manager,
  inputs,
  server,
  execStart,
  bootstrapModuleFor,
  applyBootstrap,
  repoDir,
  exampleDir,
  ...
}:
{
  # eve is system-only (no home.nix) -> excluded from the bootstrap.
  # Parameters are CLI arguments on ExecStart (escapeShellArgs only quotes
  # arguments when required, so simple words appear bare).
  bootstrap-users-filtered = lib.hasInfix "--users alice bob dave frank grace" execStart;
  bootstrap-flake-ref-defaults-to-self = lib.hasInfix "--flake-ref ${toString exampleDir}" execStart;

  # the server has no registry: no bootstrap
  server-no-bootstrap = !(server.config.systemd.user.services ? home-manager-bootstrap);

  # the bootstrap module works standalone, is tagged for error locations,
  # honors its options, and gates itself off when prerequisites miss
  bootstrap-standalone = applyBootstrap { } ? systemd;
  bootstrap-file-tagged =
    (bootstrapModuleFor { })._file == repoDir + "/lib/nixos/homeManagerBootstrapModule.nix";
  bootstrap-flake-ref-override = lib.hasInfix "--flake-ref /custom" (
    (applyBootstrap { flakeRef = "/custom"; }).systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
  );
  bootstrap-reactivate-flag = lib.hasInfix "--reactivate-every-login" (
    (applyBootstrap { reactivateEveryLogin = true; })
    .systemd.user.services.home-manager-bootstrap.serviceConfig.ExecStart
  );
  bootstrap-gates-without-home-manager = applyBootstrap { inputs = { self = inputs.self; }; } == { };
  bootstrap-gates-without-flake-ref =
    applyBootstrap { inputs = { inherit nixpkgs home-manager; }; } == { };
}
