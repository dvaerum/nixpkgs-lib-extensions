# Builds the wrapped auto-upgrade scripts. Shared between
# homeManagerAutoUpgradeModule (with the real home-manager package) and
# checks/auto-upgrade/script.nix (with a stub that records invocations), so
# the tests exercise exactly the wrappers used in production -- the same
# arrangement as ./bootstrap-script.nix.
# `nixPackage`/`extraInputs` exist for the same reason `homeManager` does:
# writeShellApplication puts runtimeInputs AHEAD of the ambient PATH, so a
# test cannot shadow them from outside -- they have to be swappable here.
{
  pkgs,
  homeManager,
  nixPackage ? pkgs.nix,
  extraInputs ? [ ],
}:
{
  upgrade = pkgs.writeShellApplication {
    name = "hm-auto-upgrade";
    runtimeInputs = [
      homeManager
      pkgs.coreutils # date, stat, mkdir, cat, head, id, uname
      pkgs.gnused # state-file field extraction
      pkgs.gnugrep
      # the home-manager CLI shells out to `nix`, and a systemd user
      # service's PATH does not include the system profile -- without
      # this the service dies with exit 127 on real hosts even though
      # interactive shells would find nix. `nix-env` (generation
      # pruning) comes from here too.
      nixPackage
      # nix's git fetcher consults git's own configuration for
      # credentials; the credential chain this script forces
      # (GIT_CONFIG_*) is only meaningful with a git binary present.
      pkgs.git
      # referenced through GIT_SSH_COMMAND for git+ssh refs
      pkgs.openssh
      # `desktop.enable` defaults to TRUE, and the script's guard is
      # `command -v notify-send || return 0` -- so without this the
      # option is a SILENT no-op on any host that does not happen to
      # have notify-send ambient, which a systemd user service usually
      # does not. Found the hard way: notify-send was absent from the
      # login PATH, the system profile, the user profile and a user
      # service's PATH on the one machine running this, so the built-in
      # desktop notification had never fired once.
      pkgs.libnotify
    ]
    ++ extraInputs;
    text = builtins.readFile ../scripts/home-manager-auto-upgrade.sh;
  };

  # Separate wrapper: the status line runs on every interactive shell
  # start, so it must not drag home-manager/nix/git onto that path.
  status = pkgs.writeShellApplication {
    name = "hm-auto-upgrade-status";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
    ];
    text = builtins.readFile ../scripts/home-manager-auto-upgrade-status.sh;
  };
}
