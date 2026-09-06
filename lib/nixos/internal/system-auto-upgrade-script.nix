# Builds the wrapped NixOS auto-upgrade policy scripts. Shared between
# systemAutoUpgradeModule and checks/system-auto-upgrade/script.nix
# (which passes stubs that record invocations), so the tests exercise
# exactly the wrappers used in production -- the same arrangement as
# ./auto-upgrade-script.nix and ./bootstrap-script.nix.
#
# `extraInputs` exists because writeShellApplication puts runtimeInputs
# AHEAD of the ambient PATH: a test cannot shadow them from outside, so
# they have to be swappable here.
{
  pkgs,
  systemdPackage ? pkgs.systemd,
  extraInputs ? [ ],
}:
{
  policy = pkgs.writeShellApplication {
    name = "nixos-upgrade-policy";
    runtimeInputs = [
      pkgs.coreutils # date, readlink, mkdir, cat, head, dirname, rm
      pkgs.gnused # state-file field extraction
      pkgs.gawk # session-id column
      # loginctl (who is here), systemctl (the engine's result, reboot),
      # systemd-run (notify inside a user's manager, self-armed wakeups),
      # wall and shutdown (the countdown a forced reboot announces).
      systemdPackage
      # the notification itself, resolved by absolute path inside the
      # target user's manager -- the store is shared, so this works from
      # a system unit
      pkgs.libnotify
    ]
    ++ extraInputs;
    text = builtins.readFile ../scripts/nixos-upgrade-policy.sh;
  };

  # Separate wrapper: --only-news runs on every interactive shell start,
  # so it must not drag systemd or libnotify onto that path.
  status = pkgs.writeShellApplication {
    name = "nixos-upgrade-status";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
    ];
    text = builtins.readFile ../scripts/nixos-upgrade-status.sh;
  };
}
