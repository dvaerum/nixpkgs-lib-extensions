# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ lib, ... }:
{
  /**
    A NixOS module that keeps a HOST current on a timer and owns the one
    thing nixpkgs' own `system.autoUpgrade` has no place for: what to do
    when the new generation needs a reboot.

    It WRAPS `system.autoUpgrade` rather than replacing it. Upstream stays
    the engine -- it fetches with `--refresh`, evaluates, builds, and
    stages -- pinned here to `operation = "boot"` and
    `allowReboot = false`, so it never activates and never reboots. A
    `nixos-upgrade-policy` unit then decides:

    - nothing needs a reboot, and the staged generation is not yet
      activated: activate it (`switch-to-configuration switch` on the
      profile itself -- no second evaluation, so it cannot drift onto a
      newer commit than the one that was staged and boot-defaulted);
    - a reboot IS needed: leave it staged, and tell whoever is here.

    Whether a reboot is needed is DERIVED on every run, by comparing
    `/run/booted-system` against the staged profile -- never remembered,
    so it cannot be wrong. `/run` holds only bookkeeping (since when,
    last notified), which is exactly what should vanish on reboot.

    Advisory by default: a logged-in session postpones the reboot
    indefinitely and nothing overrides that. `forceRebootAfter` opts into
    a deadline, with escalating reminders and a cancellable
    `shutdown -r +N` at the end.

    The builders inject this into every host they produce, so a consumer
    normally sets the `systemAutoUpgrade`/`systemAutoUpgradeFlakeRef`
    ARGUMENTS on `buildNixosConfigurations`/`buildConfigurations`/
    `mkNixosSystem` rather than calling this directly; everything else is
    configured through the `services.systemAutoUpgrade.*` options this
    declares (which is also where credentials go, since a host's
    `configuration.nix` has `config.sops.*` in scope and a flake's
    argument list does not).

    The home-manager counterpart is `homeManagerAutoUpgradeModule`. The
    two are deliberately independent: this one never triggers that one.
    A standalone home has its own daily timer, and coupling them would
    only add a way for one to fail because the other did.

    # Example

    ```nix
    # in a host's configuration.nix -- the flake ref itself normally
    # comes from the builder argument, so what is left here is policy:
    services.systemAutoUpgrade = {
      rebootWindow = {
        lower = "04:00";
        upper = "06:00";
      };
      gitCredentialsFile = config.sops.templates."nixos-upgrade-git-credentials".path;
    };
    ```

    # Type

    ```
    systemAutoUpgradeModule :: Attribute -> Module
    ```

    # Arguments

    enable
    : The `enable` option's DEFAULT -- what the builder's
    : `systemAutoUpgrade` argument feeds in. A definition in the
    : consumer's own `configuration.nix` beats it, as any definition
    : beats any default. Default `true`.

    flakeRef
    : The `flakeRef` option's default -- the builder's
    : `systemAutoUpgradeFlakeRef`. `null` warns at evaluation time when
    : `enable` is on, and creates nothing. Default `null`.
  */
  systemAutoUpgradeModule =
    {
      enable ? true,
      flakeRef ? null,
    }:
    {
      _file = ./system-auto-upgrade-module.nix;
      imports = [
        (
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            inherit (lib) mkOption types;
            inherit (import ./internal/priorities.nix { inherit lib; }) mkBuilderDefault;
            cfg = config.services.systemAutoUpgrade;

            scripts = import ./internal/system-auto-upgrade-script.nix { inherit pkgs; };

            runtimeDir = "/run/nixos-upgrade-policy";
            systemAllowFile = "${runtimeDir}/allow-reboot";
            stateFile = "/var/lib/nixos-upgrade-policy/last-run";
            pendingFile = "${runtimeDir}/pending";

            # Arbitrary consumer shell reaches the script as a FILE it
            # runs, not as spliced text: the script itself stays a real,
            # shellcheck-verified .sh file rather than becoming a Nix
            # string concatenation.
            fragmentFor =
              name: text: if text == "" then null else pkgs.writeShellScript "nixos-upgrade-${name}" text;
            preFragment = fragmentFor "pre" cfg.preCommand;
            resultFragment = fragmentFor "on-result" cfg.onResult;

            secondsOf = d: d.days * 86400 + d.hours * 3600;

            policyArgs = [
              "${scripts.policy}/bin/nixos-upgrade-policy"
              "--runtime-dir"
              runtimeDir
              "--system-allow-file"
              systemAllowFile
              "--state-file"
              stateFile
              "--reboot-triggers"
              (lib.concatStringsSep "," cfg.rebootTriggers)
              "--reminders"
              (lib.concatMapStringsSep "," (
                r: "${toString r.remainingHours}:${toString r.everyMinutes}"
              ) cfg.reminders)
              "--notify-interval"
              (toString cfg.notifyIntervalSec)
              "--force-grace"
              (toString cfg.forceGraceMinutes)
              "--reboot-grace"
              (toString cfg.rebootGraceMinutes)
              # 0 means "no poll timer exists", which is what tells the
              # script to arm its own wakeup for every reminder instead
              # of assuming something else will come along
              "--poll-interval"
              (toString (if cfg.pollIntervalSec == null then 0 else cfg.pollIntervalSec))
            ]
            ++ lib.optionals (cfg.rebootWindow != null) [
              "--reboot-window"
              "${cfg.rebootWindow.lower}-${cfg.rebootWindow.upper}"
            ]
            ++ lib.optionals (cfg.forceRebootAfter != null) [
              "--force-after"
              (toString (secondsOf cfg.forceRebootAfter))
            ]
            ++ lib.optionals (preFragment != null) [
              "--pre-command"
              "${preFragment}"
            ]
            ++ lib.optionals (resultFragment != null) [
              "--on-result"
              "${resultFragment}"
            ]
            ++ lib.optional cfg.desktop.enable "--desktop-notify"
            ++ lib.optional cfg.dryRun "--dry-run";

            # GIT_TERMINAL_PROMPT governs git's OWN prompting and not a
            # credential HELPER, so an ambient helper (git-credential-oauth
            # and friends) would otherwise sit waiting on a browser
            # forever in a unit nobody is watching. The empty VALUE_0
            # resets the inherited chain; VALUE_1 is then the only helper
            # left. Paths only -- the secret is read at run time, by root.
            credentialEnv = {
              GIT_TERMINAL_PROMPT = "0";
              GIT_CONFIG_COUNT = "2";
              GIT_CONFIG_KEY_0 = "credential.helper";
              GIT_CONFIG_VALUE_0 = "";
              GIT_CONFIG_KEY_1 = "credential.helper";
              GIT_CONFIG_VALUE_1 =
                if cfg.gitCredentialsFile != null then "store --file=${cfg.gitCredentialsFile}" else "store";
            }
            // lib.optionalAttrs (cfg.sshKeyPath != null) {
              # BatchMode is the SSH analogue of GIT_TERMINAL_PROMPT=0:
              # fail fast rather than block on a passphrase or an unknown
              # host key. IdentitiesOnly stops ssh offering every other
              # key first and tripping MaxAuthTries.
              GIT_SSH_COMMAND = lib.concatStringsSep " " (
                [
                  "ssh"
                  "-i"
                  cfg.sshKeyPath
                  "-o"
                  "IdentitiesOnly=yes"
                  "-o"
                  "BatchMode=yes"
                ]
                ++ lib.concatMap (o: [
                  "-o"
                  o
                ]) cfg.sshExtraOptions
              );
            };

            statusLine = "${scripts.status}/bin/nixos-upgrade-status --only-news --pending-file ${pendingFile} --state-file ${stateFile} || true";

            wanted = cfg.enable && cfg.flakeRef != null;
          in
          {
            options.services.systemAutoUpgrade = {
              enable = mkOption {
                type = types.bool;
                default = enable;
                description = ''
                  Keep this host current on a timer, and own the reboot
                  policy for it. Seeded by the builder's
                  `systemAutoUpgrade` argument.

                  With no `flakeRef` this warns and creates nothing;
                  setting it to `false` is the single off switch, and is
                  silent.
                '';
              };

              flakeRef = mkOption {
                type = types.nullOr types.str;
                default = flakeRef;
                example = "git+https://example.org/nixos-config.git";
                description = ''
                  The LIVE flake reference to track, seeded by the
                  builder's `systemAutoUpgradeFlakeRef`. Must be mutable:
                  a ref pinned to a revision can never pick up a new
                  commit, so the timer would rebuild the same thing
                  forever.
                '';
              };

              schedule = mkOption {
                type = types.str;
                default = "04:45";
                description = ''
                  When the ENGINE runs -- an `OnCalendar` expression for
                  `system.autoUpgrade`. This is the only part that
                  fetches and builds; the reboot policy runs far more
                  often and costs nothing.
                '';
              };

              randomizedDelaySec = mkOption {
                type = types.int;
                default = 900;
                description = ''
                  Jitter on the engine timer, so a fleet booted together
                  does not hit the substituter at the same instant.
                '';
              };

              persistent = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Catch up an engine run missed while the machine was
                  off, rather than skipping until tomorrow.
                '';
              };

              runtimeMaxSec = mkOption {
                type = types.int;
                default = 10800;
                description = ''
                  Hard cap on one engine run. An unattended build that
                  hangs -- on a credential prompt, on an unreachable
                  substituter -- must eventually fail rather than sit
                  there until someone notices.
                '';
              };

              pollIntervalSec = mkOption {
                type = types.nullOr types.int;
                default = 900;
                description = ''
                  How often the reboot POLICY re-runs. This does not
                  check for updates: it is three `readlink`s and one
                  `loginctl` call, so it is essentially free. What it
                  bounds is reaction time -- how soon after the last
                  user logs out the machine reboots, and how late a
                  reminder can land.

                  `null` disables the poll timer entirely; the policy
                  then runs only after the engine, and arms its own
                  one-shot wakeups for anything time-critical.
                '';
              };

              pollRandomizedDelaySec = mkOption {
                type = types.int;
                default = 0;
                description = ''
                  Jitter on the poll timer. Zero by default: the run
                  touches nothing shared, so there is no herd to spread,
                  and jitter approaching the interval would only blur
                  the reminder ladder.
                '';
              };

              rebootTriggers = mkOption {
                type = types.listOf (
                  types.enum [
                    "kernel"
                    "initrd"
                    "kernel-modules"
                  ]
                );
                default = [
                  "kernel"
                  "initrd"
                  "kernel-modules"
                ];
                description = ''
                  Which components, compared between the booted system
                  and the staged one, mean a reboot is required. The
                  same three nixpkgs itself compares.

                  `kernel-modules` is the noisy one: it moves without
                  the kernel moving whenever an out-of-tree module does
                  (nvidia, ZFS, v4l2loopback). That is exactly when the
                  module loaded in RAM and the tree on disk disagree, so
                  it stays on by default -- an extra reboot prompt is
                  cheaper than an unimportable pool. A host with no
                  out-of-tree modules can drop it.
                '';
              };

              rebootWindow = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      lower = mkOption {
                        type = types.str;
                        example = "04:00";
                        description = "Start of the window, `HH:MM`.";
                      };
                      upper = mkOption {
                        type = types.str;
                        example = "06:00";
                        description = "End of the window, `HH:MM`.";
                      };
                    };
                  }
                );
                default = null;
                description = ''
                  When an UNATTENDED reboot may happen. `null` means any
                  time is fine, which is usually right: nobody is logged
                  in, so nobody is interrupted.

                  Unlike `system.autoUpgrade.rebootWindow`, this one is
                  actually consulted -- upstream's is only read inside
                  its `allowReboot` branch, which this module pins off.

                  A `forceRebootAfter` deadline deliberately ignores
                  this: a deadline a window can postpone indefinitely is
                  not a deadline.
                '';
              };

              forceRebootAfter = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      days = mkOption {
                        type = types.int;
                        default = 0;
                        description = "Whole days of grace.";
                      };
                      hours = mkOption {
                        type = types.int;
                        default = 0;
                        description = "Additional hours of grace.";
                      };
                    };
                  }
                );
                default = null;
                example = {
                  days = 7;
                  hours = 0;
                };
                description = ''
                  How long a required reboot may stay pending before it
                  happens anyway, measured from when it first became
                  necessary. `null` -- the default -- never forces
                  anything: a logged-in session postpones the reboot for
                  as long as it lasts.

                  The clock only counts time the machine was up and
                  pending, because it lives in `/run`; a laptop closed
                  for a week does not burn its grace period.
                '';
              };

              forceGraceMinutes = mkOption {
                type = types.int;
                default = 5;
                description = ''
                  The `shutdown -r +N` countdown once the deadline
                  passes. systemd broadcasts and re-broadcasts its own
                  wall warning over this period, and `shutdown -c`
                  cancels it.
                '';
              };

              rebootGraceMinutes = mkOption {
                type = types.int;
                default = 1;
                description = ''
                  The countdown for an ORDINARY reboot -- one taken
                  because nothing is blocking it any more, rather than
                  because a deadline expired.

                  Shorter than `forceGraceMinutes`, because by then
                  either nobody is logged in or everyone present has run
                  `nixos-allow-reboot`. It is not zero: having said "go
                  ahead" is not the same as wanting the screen to go
                  black mid-sentence, and the countdown also buys
                  systemd's wall broadcast and a working `shutdown -c`.
                '';
              };

              reminders = mkOption {
                type = types.listOf (
                  types.submodule {
                    options = {
                      remainingHours = mkOption {
                        type = types.int;
                        description = "Applies once this many hours or fewer remain.";
                      };
                      everyMinutes = mkOption {
                        type = types.int;
                        description = "Re-notify at most this often while it applies.";
                      };
                    };
                  }
                );
                default = [
                  {
                    remainingHours = 24;
                    everyMinutes = 360;
                  }
                  {
                    remainingHours = 4;
                    everyMinutes = 60;
                  }
                  {
                    remainingHours = 1;
                    everyMinutes = 15;
                  }
                ];
                description = ''
                  How reminders escalate as a `forceRebootAfter`
                  deadline approaches; the narrowest matching rung wins.
                  Outside every rung -- and always, when no deadline is
                  configured -- `notifyIntervalSec` applies.

                  A rung finer than `pollIntervalSec` still lands on
                  time: the policy arms a one-shot wakeup for it.
                '';
              };

              notifyIntervalSec = mkOption {
                type = types.int;
                default = 86400;
                description = ''
                  How often to re-notify about a pending reboot outside
                  the reminder ladder. The FIRST detection always
                  notifies regardless.
                '';
              };

              desktop.enable = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Deliver notifications into each logged-in user's own
                  session bus with `notify-send`, where a graphical
                  session has somewhere to show them. A user with no
                  reachable bus (a console or SSH login) falls back to
                  `wall`, which is also what happens when this is off.
                '';
              };

              console.enable = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Print a line at interactive shell start while a reboot
                  is pending or the last upgrade failed -- and nothing
                  at all otherwise. Also installs `nixos-upgrade-status`
                  for checking deliberately.
                '';
              };

              sshKeyPath = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "/run/secrets/nixos-upgrade-ssh-key";
                description = ''
                  Private key for a `git+ssh` reference, as a PATH --
                  typically `config.sops.secrets."...".path`. Must be
                  passphrase-less (nothing can type one at 04:45) and
                  the host must already be in `known_hosts`.
                '';
              };

              sshExtraOptions = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [ "StrictHostKeyChecking=accept-new" ];
                description = ''
                  Extra `ssh -o` options. Host-key checking is not
                  weakened by default; this is the escape hatch for
                  anyone who wants it to be.
                '';
              };

              gitCredentialsFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "/run/secrets/nixos-upgrade-git-credentials";
                description = ''
                  A file in `git-credential-store` format
                  (`https://user:token@host` lines), as a PATH. Compose
                  it from an existing token with a sops TEMPLATE rather
                  than storing the whole line as a second secret.
                '';
              };

              preCommand = mkOption {
                type = types.lines;
                default = "";
                description = ''
                  Shell run before the policy decides anything, for
                  setups the options above do not cover.
                '';
              };

              onResult = mkOption {
                type = types.lines;
                default = "";
                description = ''
                  Shell run ONCE per engine run -- not once per poll --
                  with `$RESULT`, `$REBOOT_PENDING`, `$GENERATION` and
                  `$STATE_FILE` in the environment. This is where a push
                  notification or a monitoring ping goes; the library
                  deliberately bakes in neither.
                '';
              };

              dryRun = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Log destructive actions (activate, reboot, schedule a
                  shutdown) instead of performing them. Notifications
                  still go out for real, which is the point: it is how
                  the reboot UX gets exercised on a live desktop.
                '';
              };
            };

            config = lib.mkMerge [
              {
                warnings = lib.optional (cfg.enable && cfg.flakeRef == null) ''
                  nixpkgs-lib-extensions: services.systemAutoUpgrade is enabled for `${config.networking.hostName}` but no flake reference is configured, so nothing is created. Set the builder's `systemAutoUpgradeFlakeRef` argument (or `services.systemAutoUpgrade.flakeRef`) to a mutable ref like `"git+https://..."`. If you update this host yourself, set `services.systemAutoUpgrade.enable = false;`.
                '';
              }

              (lib.mkIf wanted {
                assertions = [
                  {
                    assertion = config.system.switch.enable;
                    message = "services.systemAutoUpgrade activates a staged generation with switch-to-configuration, which system.switch.enable = false does not build. Enable one or the other.";
                  }
                  {
                    assertion = !config.system.autoUpgrade.allowReboot;
                    message = "services.systemAutoUpgrade owns the reboot decision; system.autoUpgrade.allowReboot = true would have nixpkgs reboot on its own schedule as well. Leave it false.";
                  }
                ];

                # Upstream as the ENGINE only: fetch, evaluate, build,
                # stage. `boot` (never `switch`) is what leaves the
                # activation decision to the policy unit below.
                system.autoUpgrade = {
                  enable = mkBuilderDefault true;
                  flake = mkBuilderDefault cfg.flakeRef;
                  operation = mkBuilderDefault "boot";
                  allowReboot = mkBuilderDefault false;
                  dates = mkBuilderDefault cfg.schedule;
                  persistent = mkBuilderDefault cfg.persistent;
                  randomizedDelaySec = mkBuilderDefault "${toString cfg.randomizedDelaySec}s";
                };

                systemd.services.nixos-upgrade = {
                  environment = credentialEnv;
                  serviceConfig.RuntimeMaxSec = mkBuilderDefault cfg.runtimeMaxSec;
                };

                systemd.services.nixos-upgrade-policy = {
                  description = "Decide what to do with the staged NixOS generation";
                  # `after` + `wantedBy` and deliberately NOT `bindsTo`:
                  # binding to a Type=oneshot engine that has already
                  # exited stops this unit the instant it is ordered to
                  # start, which is why the hand-rolled version of this
                  # never ran once.
                  after = [ "nixos-upgrade.service" ];
                  wantedBy = [ "nixos-upgrade.service" ];
                  # This unit runs `switch-to-configuration switch`, which
                  # stops every unit whose store path changed -- including
                  # THIS one, killing the activation half-way through.
                  # Observed for real: "stopping the following units:
                  # nixos-upgrade-policy.service / Main process exited,
                  # code=killed, status=15/TERM", unit left `failed` and
                  # the generation half-applied. It fires exactly when the
                  # upgrade changes the module itself -- so on every bump
                  # of this library, which is the common case, not an edge
                  # one.
                  #
                  # `restartIfChanged = false` renders X-RestartIfChanged,
                  # which switch-to-configuration reads to put the unit in
                  # units_to_skip (switch-to-configuration-ng main.rs:738)
                  # and then leaves it alone entirely. Correct for a
                  # timer-driven oneshot: it is not a daemon, so there is
                  # nothing to keep current -- the next timer firing picks
                  # up the new version from the new /etc. The alternative,
                  # detaching the switch the way the home half does, would
                  # move this unit's own log lines into a transient unit
                  # and cost the observability that made this bug findable.
                  restartIfChanged = false;
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = lib.escapeShellArgs policyArgs;
                  };
                };

                systemd.timers.nixos-upgrade-policy = lib.mkIf (cfg.pollIntervalSec != null) {
                  description = "Re-check the pending-reboot decision";
                  wantedBy = [ "timers.target" ];
                  timerConfig = {
                    # Monotonic, not calendar: "every N" is what this
                    # actually means, and it keeps the interval the
                    # script reasons about and the interval the timer
                    # uses from being two options that can disagree.
                    OnBootSec = "5min";
                    OnUnitActiveSec = "${toString cfg.pollIntervalSec}s";
                    RandomizedDelaySec = "${toString cfg.pollRandomizedDelaySec}s";
                    AccuracySec = "1min";
                  };
                };
              })

              # Worth having even where no timer runs: a host that USED
              # to auto-upgrade still has a last-run record worth
              # reporting.
              (lib.mkIf cfg.console.enable {
                environment.systemPackages = [
                  scripts.status
                  # Installed alongside the status line rather than under
                  # `wanted`: a user needs to be able to say "go ahead"
                  # even on a host whose timer someone has since turned
                  # off, and an absent command is a worse answer than one
                  # that reports nothing is pending.
                  scripts.allowReboot
                ];
                environment.interactiveShellInit = statusLine;

                # ... except that the line above never reaches an
                # interactive FISH. NixOS feeds
                # environment.interactiveShellInit to fish through
                # `fenv source ... > /dev/null` (programs.fish's own
                # sourceEnv, at the useBabelfish = false default): that
                # imports the environment and discards anything printed,
                # which is right for fenv and fatal for a status line.
                # The babelfish path sources a translated file normally
                # and DOES print, so defining this there too would print
                # twice -- hence the condition on both.
                programs.fish.interactiveShellInit = lib.mkIf (
                  config.programs.fish.enable && !config.programs.fish.useBabelfish
                ) statusLine;
              })
            ];
          }
        )
      ];
    };
}
