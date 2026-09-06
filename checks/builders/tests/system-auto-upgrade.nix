# The host-level auto-upgrade wiring (systemAutoUpgradeModule): what the
# builder seeds into nixpkgs' `system.autoUpgrade` engine, which units
# the reboot policy produces, and how policy reaches the script as
# flags. The script's own behaviour (what counts as a login, the
# reminder ladder, the deadline) is covered by
# checks/system-auto-upgrade/script.nix.
{
  lib,
  myLib,
  inputs,
  system,
  ...
}:
let
  liveRef = "git+https://example.org/nixos-config.git";

  hostWith =
    extra:
    (myLib.buildNixosConfigurations {
      _defaults = {
        inherit inputs system;
        traceDiscoveredUsers = false;
        users = [ ];
      }
      // extra;
      upgradehost = { };
    }).upgradehost;

  withRef = (hostWith { systemAutoUpgradeFlakeRef = liveRef; }).config;
  withoutRef = (hostWith { }).config;
  disabled = (hostWith { systemAutoUpgrade = false; }).config;

  # the ExecStart is one escaped command line; asserting on its TEXT is
  # what proves an option actually reaches the script rather than merely
  # being declared
  execOf = cfg: cfg.systemd.services.nixos-upgrade-policy.serviceConfig.ExecStart;
  execWith =
    homeModules: execOf (hostWith ({ systemAutoUpgradeFlakeRef = liveRef; } // homeModules)).config;
in
{
  # ── the engine: build and stage, never activate, never reboot ──
  system-auto-upgrade-engine-seeded =
    let
      u = withRef.system.autoUpgrade;
    in
    u.enable && u.flake == liveRef && u.operation == "boot" && u.allowReboot == false;

  # `boot` is the whole point: with `switch` upstream would activate a
  # new kernel's userspace behind our back, and the reboot decision
  # would have nothing left to decide
  system-auto-upgrade-engine-schedule = withRef.system.autoUpgrade.dates == "04:45";

  # ── the policy: a service always, a timer unless polling is off ──
  system-auto-upgrade-units-present =
    withRef.systemd.services ? nixos-upgrade-policy && withRef.systemd.timers ? nixos-upgrade-policy;

  # ... and NOT bound to the engine. bindsTo on a Type=oneshot target
  # that has already exited stops this unit the instant it is ordered to
  # start -- the bug that kept the hand-rolled version from ever running.
  system-auto-upgrade-policy-not-bound =
    let
      s = withRef.systemd.services.nixos-upgrade-policy;
    in
    s.after == [ "nixos-upgrade.service" ]
    && s.wantedBy == [ "nixos-upgrade.service" ]
    && (s.bindsTo or [ ]) == [ ];

  system-auto-upgrade-poll-timer-defaults =
    let
      t = withRef.systemd.timers.nixos-upgrade-policy.timerConfig;
    in
    t.OnUnitActiveSec == "900s" && t.RandomizedDelaySec == "0s";

  # polling off means the poll TIMER goes away, and the script is told
  # so (0) rather than left to guess -- that is what makes it arm its
  # own wakeups instead of assuming something else will
  system-auto-upgrade-poll-disabled =
    let
      cfg =
        (hostWith {
          systemAutoUpgradeFlakeRef = liveRef;
          modules = [ { services.systemAutoUpgrade.pollIntervalSec = null; } ];
        }).config;
    in
    !(cfg.systemd.timers ? nixos-upgrade-policy) && lib.hasInfix "--poll-interval 0" (execOf cfg);

  # ── no ref: warn, create nothing ──
  system-auto-upgrade-no-units-without-ref = !(withoutRef.systemd.services ? nixos-upgrade-policy);

  system-auto-upgrade-warns-without-ref = lib.any (
    w: lib.hasInfix "no flake reference is configured" w
  ) withoutRef.warnings;

  # `systemAutoUpgrade = false` is the single off switch: nothing AND no nag
  system-auto-upgrade-disabled-is-silent =
    !(disabled.systemd.services ? nixos-upgrade-policy) && disabled.warnings == [ ];

  # ── a host's own definition beats the builder-seeded default ──
  system-auto-upgrade-consumer-overrides-builder =
    (hostWith {
      systemAutoUpgradeFlakeRef = liveRef;
      modules = [ { system.autoUpgrade.dates = "02:00"; } ];
    }).config.system.autoUpgrade.dates == "02:00";

  # ── policy reaches the script as flags ──
  system-auto-upgrade-window-wired = lib.hasInfix "--reboot-window 04:00-06:00" (execWith {
    modules = [
      {
        services.systemAutoUpgrade.rebootWindow = {
          lower = "04:00";
          upper = "06:00";
        };
      }
    ];
  });

  system-auto-upgrade-triggers-wired =
    lib.hasInfix "--reboot-triggers kernel,initrd,kernel-modules" (execOf withRef)
    && lib.hasInfix "--reboot-triggers kernel,initrd" (execWith {
      modules = [
        {
          services.systemAutoUpgrade.rebootTriggers = [
            "kernel"
            "initrd"
          ];
        }
      ];
    });

  system-auto-upgrade-reminder-ladder-wired = lib.hasInfix "--reminders 24:360,4:60,1:15" (
    execOf withRef
  );

  # the deadline is OFF by default, and "off" has to mean the flag is
  # ABSENT -- a --force-after with some placeholder value would quietly
  # reboot people
  system-auto-upgrade-no-deadline-by-default = !(lib.hasInfix "--force-after" (execOf withRef));

  system-auto-upgrade-deadline-wired = lib.hasInfix "--force-after 601200" (execWith {
    modules = [
      {
        services.systemAutoUpgrade.forceRebootAfter = {
          days = 6;
          hours = 23;
        };
      }
    ];
  });

  system-auto-upgrade-dry-run-wired = lib.hasInfix "--dry-run" (execWith {
    modules = [ { services.systemAutoUpgrade.dryRun = true; } ];
  });

  system-auto-upgrade-desktop-notify-default = lib.hasInfix "--desktop-notify" (execOf withRef);

  # ── credentials reach the ENGINE unit as environment, not as files ──
  # the hand-rolled version wrote /root/.git-credentials and left a
  # global credential.helper behind that its own postStop never undid
  system-auto-upgrade-git-credentials-wired =
    let
      env =
        (hostWith {
          systemAutoUpgradeFlakeRef = liveRef;
          modules = [
            { services.systemAutoUpgrade.gitCredentialsFile = "/run/secrets/nixos-upgrade-creds"; }
          ];
        }).config.systemd.services.nixos-upgrade.environment;
    in
    env.GIT_TERMINAL_PROMPT == "0"
    && env.GIT_CONFIG_VALUE_0 == ""
    && env.GIT_CONFIG_VALUE_1 == "store --file=/run/secrets/nixos-upgrade-creds";

  # with no file configured the chain is STILL narrowed to store-only:
  # GIT_TERMINAL_PROMPT does not govern a credential HELPER, so an
  # ambient oauth helper would otherwise wait on a browser forever
  system-auto-upgrade-credential-chain-always-reset =
    withRef.systemd.services.nixos-upgrade.environment.GIT_CONFIG_VALUE_1 == "store";

  system-auto-upgrade-ssh-key-wired =
    let
      env =
        (hostWith {
          systemAutoUpgradeFlakeRef = liveRef;
          modules = [
            {
              services.systemAutoUpgrade = {
                sshKeyPath = "/run/secrets/upgrade-key";
                sshExtraOptions = [ "StrictHostKeyChecking=accept-new" ];
              };
            }
          ];
        }).config.systemd.services.nixos-upgrade.environment;
    in
    lib.hasInfix "-i /run/secrets/upgrade-key" env.GIT_SSH_COMMAND
    && lib.hasInfix "IdentitiesOnly=yes" env.GIT_SSH_COMMAND
    && lib.hasInfix "BatchMode=yes" env.GIT_SSH_COMMAND
    && lib.hasInfix "StrictHostKeyChecking=accept-new" env.GIT_SSH_COMMAND;

  # ── reporting ──
  system-auto-upgrade-status-installed = lib.any (
    p: (p.name or "") == "nixos-upgrade-status"
  ) withRef.environment.systemPackages;

  system-auto-upgrade-status-line-wired = lib.hasInfix "nixos-upgrade-status --only-news" withRef.environment.interactiveShellInit;

  # ... and it must actually be VISIBLE in each shell exactly once.
  # NixOS pipes environment.interactiveShellInit into fish through
  # `fenv source ... > /dev/null`, which discards output -- so with the
  # default (useBabelfish = false) fish needs its own definition, and
  # with babelfish it must NOT get one or the line prints twice.
  system-auto-upgrade-status-line-fish-fenv =
    let
      cfg =
        (hostWith {
          systemAutoUpgradeFlakeRef = liveRef;
          modules = [ { programs.fish.enable = true; } ];
        }).config;
    in
    lib.hasInfix "nixos-upgrade-status" cfg.programs.fish.interactiveShellInit;

  system-auto-upgrade-status-line-fish-babelfish =
    let
      cfg =
        (hostWith {
          systemAutoUpgradeFlakeRef = liveRef;
          modules = [
            {
              programs.fish.enable = true;
              programs.fish.useBabelfish = true;
            }
          ];
        }).config;
    in
    !(lib.hasInfix "nixos-upgrade-status" cfg.programs.fish.interactiveShellInit);

  # a host with no fish at all gets no fish definition
  system-auto-upgrade-status-line-no-fish =
    !(lib.hasInfix "nixos-upgrade-status" withRef.programs.fish.interactiveShellInit);

  # ── the guard against two things racing to reboot ──
  system-auto-upgrade-asserts-allow-reboot-off =
    let
      failing = lib.filter (a: !a.assertion) (
        (hostWith {
          systemAutoUpgradeFlakeRef = liveRef;
          modules = [ { system.autoUpgrade.allowReboot = true; } ];
        }).config.assertions
      );
    in
    lib.any (a: lib.hasInfix "owns the reboot decision" a.message) failing;

  # ── it reaches through the combined builder too ──
  system-auto-upgrade-through-build-configurations =
    let
      out = myLib.buildConfigurations {
        _defaults = {
          inherit inputs system;
          traceDiscoveredUsers = false;
          users = [ ];
          systemAutoUpgradeFlakeRef = liveRef;
        };
        combohost = { };
      };
    in
    out.nixosConfigurations.combohost.config.system.autoUpgrade.flake == liveRef;
}
