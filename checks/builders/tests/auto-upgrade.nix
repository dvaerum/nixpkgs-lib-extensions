# The scheduled auto-upgrade timer (homeManagerAutoUpgradeModule): which
# homes get a unit, the LIVE-ref requirement, and the standalone-only
# rule. The shell script's own behaviour (credential resolution, target
# re-resolution, state file) is covered by checks/auto-upgrade/script.nix.
{
  lib,
  myLib,
  inputs,
  system,
  laptop,
  ...
}:
let
  liveRef = "git+https://example.org/home-manager-config.git";

  homesWith =
    extra:
    myLib.buildHomeConfigurations (
      {
        inherit inputs system;
        traceDiscoveredUsers = false;
      }
      // extra
    );

  withRef = (homesWith { homeAutoUpgradeFlakeRef = liveRef; }).alice.config;
  withoutRef = (homesWith { }).alice.config;
  disabled = (homesWith { homeAutoUpgrade = false; }).alice.config;

  timerOf = cfg: cfg.systemd.user.timers.hm-auto-upgrade.Timer;
  # home-manager normalizes a single ExecStart into a one-element list
  # (systemd allows several); take whichever shape came back.
  execStartOf =
    cfg:
    let
      v = cfg.systemd.user.services.hm-auto-upgrade.Service.ExecStart;
    in
    if lib.isList v then lib.head v else v;
  # the launcher is a store path; its TEXT is the detachedRun fragment
  launcherOf = cfg: builtins.readFile (execStartOf cfg);

  # a system-managed home: dave is NOT in the example's loginHomes, so
  # laptop builds his home into the system via home-manager's NixOS module
  systemManaged = laptop.config.home-manager.users.dave;
in
{
  # ── which homes get a unit ──
  auto-upgrade-unit-for-standalone-home =
    withRef.systemd.user.timers ? hm-auto-upgrade && withRef.systemd.user.services ? hm-auto-upgrade;

  # no LIVE ref means nothing to track: no unit, rather than a timer that
  # would run `home-manager switch` against nothing
  auto-upgrade-no-unit-without-ref = !(withoutRef.systemd.user.timers ? hm-auto-upgrade);

  # ... and that case WARNS, since homeAutoUpgrade is on by default and the
  # user has not said they handle updates themselves
  auto-upgrade-warns-without-ref = lib.any (
    w: lib.hasInfix "no LIVE flake reference" w
  ) withoutRef.warnings;

  # `homeAutoUpgrade = false` is the single off switch: no unit AND no nag
  auto-upgrade-disabled-is-silent =
    !(disabled.systemd.user.timers ? hm-auto-upgrade) && disabled.warnings == [ ];

  # the combined builder's home half reaches the same injection point in
  # mk-home.nix, so it gets the timer too -- true by construction, but
  # the construction is exactly the kind of thing that quietly stops
  # being true, and this is the builder a fleet with NixOS hosts uses
  auto-upgrade-through-build-configurations =
    let
      out = myLib.buildConfigurations {
        _defaults = {
          inherit inputs system;
          traceDiscoveredUsers = false;
          homeAutoUpgradeFlakeRef = liveRef;
        };
        laptop = { };
      };
      cfg = out.homeConfigurations.alice.config;
    in
    cfg.systemd.user.timers ? hm-auto-upgrade
    && cfg.services.homeManagerAutoUpgrade.flakeRef == liveRef;

  # ── the timer itself ──
  auto-upgrade-timer-defaults =
    let
      t = timerOf withRef;
    in
    t.OnCalendar == "daily" && t.Persistent == true && t.RandomizedDelaySec == 300;

  # Persistent alone would start a full build at the instant of login
  # after a missed run; the delay is what keeps that off the login path
  auto-upgrade-delay-is-configurable =
    (timerOf
      (homesWith {
        homeAutoUpgradeFlakeRef = liveRef;
        homeModules = [ { services.homeManagerAutoUpgrade.randomizedDelaySec = 0; } ];
      }).alice.config
    ).RandomizedDelaySec == 0;

  # a consumer's own definition beats the builder-seeded default
  auto-upgrade-consumer-overrides-builder =
    (timerOf
      (homesWith {
        homeAutoUpgradeFlakeRef = liveRef;
        homeModules = [ { services.homeManagerAutoUpgrade.schedule = "weekly"; } ];
      }).alice.config
    ).OnCalendar == "weekly";

  # keepGenerations is a plain option default, not a baked-in constant:
  # the library is the thing CREATING a generation a day here, so it
  # prunes by default -- but how many to keep is the consumer's call,
  # and 0 opts out entirely for anyone whose store GC already covers it.
  auto-upgrade-keep-generations-default = lib.hasInfix "keep-generations 10" (launcherOf withRef);

  auto-upgrade-keep-generations-overridable =
    let
      with42 =
        launcherOf
          (homesWith {
            homeAutoUpgradeFlakeRef = liveRef;
            homeModules = [ { services.homeManagerAutoUpgrade.keepGenerations = 42; } ];
          }).alice.config;
      withOff =
        launcherOf
          (homesWith {
            homeAutoUpgradeFlakeRef = liveRef;
            homeModules = [ { services.homeManagerAutoUpgrade.keepGenerations = 0; } ];
          }).alice.config;
    in
    lib.hasInfix "keep-generations 42" with42 && lib.hasInfix "keep-generations 0" withOff;

  # ── the switch is detached, for the same reason the interactive
  #    wrapper is: activation restarts user units, including this one ──
  auto-upgrade-runs-detached =
    let
      launcher = launcherOf withRef;
    in
    lib.hasInfix "systemd-run" launcher && lib.hasInfix "RuntimeMaxSec=7200" launcher;

  auto-upgrade-passes-flake-ref = lib.hasInfix liveRef (launcherOf withRef);

  # ── credentials reach the script as PATHS ──
  auto-upgrade-credential-paths-wired =
    let
      launcher = launcherOf (
        (homesWith {
          homeAutoUpgradeFlakeRef = liveRef;
          homeModules = [
            {
              services.homeManagerAutoUpgrade = {
                sshKeyPath = "/run/secrets/hm-ssh-key";
                gitCredentialsFile = "/run/secrets/hm-git-credentials";
                sshExtraOptions = [ "StrictHostKeyChecking=accept-new" ];
              };
            }
          ];
        }).alice.config
      );
    in
    lib.hasInfix "--ssh-key" launcher
    && lib.hasInfix "/run/secrets/hm-ssh-key" launcher
    && lib.hasInfix "--git-credentials" launcher
    && lib.hasInfix "/run/secrets/hm-git-credentials" launcher
    && lib.hasInfix "StrictHostKeyChecking=accept-new" launcher;

  # ── reporting ──
  auto-upgrade-status-command-installed = lib.any (
    p: (p.name or "") == "hm-auto-upgrade-status"
  ) withRef.home.packages;

  # ── standalone ONLY: a system-managed home switches with
  #    nixos-rebuild, so a timer would fight it over one profile ──
  auto-upgrade-system-managed-has-no-unit = !(systemManaged.systemd.user.timers ? hm-auto-upgrade);

  # ... but the OPTIONS still exist there, because ONE users/<u>/home.nix
  # is evaluated by both mechanisms -- an option that vanished on the
  # system-managed side would make that same file fail to evaluate
  auto-upgrade-system-managed-still-declares-options =
    systemManaged.services.homeManagerAutoUpgrade.enable == false;

  # asking for it anyway is a warning, not silence
  auto-upgrade-system-managed-warns-when-forced-on =
    let
      sys = myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "amhost";
        users = [ "dave" ];
        homeModules = [ { services.homeManagerAutoUpgrade.enable = true; } ];
      };
    in
    lib.any (w: lib.hasInfix "SYSTEM-managed" w) sys.config.home-manager.users.dave.warnings;
}
