# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ self, lib, ... }:
{
  /**
    A home-manager module that keeps a STANDALONE home current: a systemd
    user timer re-runs `home-manager switch` against a LIVE flake
    reference on a schedule, resolving `"<user>@<hostname>"` vs
    `"<user>"` freshly on every run.

    The builders inject this into every standalone home they produce, so
    a consumer normally sets the `autoUpgrade`/`autoUpgradeFlakeRef`
    ARGUMENTS on `buildHomeConfigurations`/`buildConfigurations`/
    `mkHomeConfiguration` rather than calling this directly; everything
    else is configured through the `services.homeManagerAutoUpgrade.*`
    options this declares (which is also where credentials go, since a
    `home.nix` has `config.sops.secrets.*` in scope and a flake's
    argument list does not).

    Deliberately the mirror image of `homeManagerBootstrapModule`, not a
    replacement for it: that one provisions a home ONCE at first login
    from a PINNED ref, resolving the attribute at EVALUATION time
    (`attrFor`) so a wrong guess fails the build. This one tracks a ref
    whose outputs may change after the system was built, so its
    resolution has to happen at RUN time -- a build-time answer would go
    stale the moment a `hosts/<hostname>/` directory is added.

    Only ever active for a STANDALONE home. A system-managed home (built
    into a NixOS system via home-manager's NixOS module) already switches
    with `nixos-rebuild`; running `home-manager switch` against it on a
    timer would create a second, competing generation lineage over one
    profile. The builders still inject this module there so the options
    exist -- one `users/<user>/home.nix` is evaluated by BOTH mechanisms,
    and an option that vanished on one of them would break the other --
    but it produces no unit, and warns if asked to.

    # Example

    ```nix
    # in a user's home.nix -- the flake ref itself normally comes from
    # the builder argument, so what is left here is the credential:
    services.homeManagerAutoUpgrade = {
      gitCredentialsFile = config.sops.secrets."hm-auto-upgrade/git-credentials".path;
      schedule = "daily";
    };
    ```

    # Type

    ```
    homeManagerAutoUpgradeModule :: Attribute -> Module
    ```

    # Arguments

    enable
    : The `enable` option's DEFAULT -- what the builder's `autoUpgrade`
    : argument feeds in. A definition in the consumer's own `home.nix`
    : beats it, as any definition beats any default. Default `true`.

    flakeRef
    : The `flakeRef` option's default -- the builder's
    : `autoUpgradeFlakeRef`. `null` warns at evaluation time when
    : `enable` is on. Default `null`.
    :
    : Deliberately NOT defaulted from `loginFlakeRef`, though it usually
    : names the same repository: a flake INPUT is an immutable
    : `/nix/store` path, so switching to it repeatedly could never pick
    : up a new commit, and the one shape that IS live -- a bare string --
    : cannot be scanned for users at evaluation time, so a home built
    : that way does not exist to carry a timer. No configuration exists
    : in which such a fallback both fires and is useful.

    homeManagerPackage
    : The home-manager CLI to run. Defaults to `pkgs.home-manager` when
    : `null`, which is right for a standalone caller; the builders pass
    : the package from the flake's own home-manager input so the timer
    : runs the same version the home was built with.

    systemManaged
    : Declare the options but never produce a unit -- what the builders
    : pass on the system-managed path. Also flips `enable`'s default to
    : `false`, so the "not supported here" warning fires only for someone
    : who explicitly asked for it. Default `false`.
  */
  homeManagerAutoUpgradeModule =
    {
      enable ? true,
      flakeRef ? null,
      homeManagerPackage ? null,
      systemManaged ? false,
    }:
    {
      _file = ./home-manager-auto-upgrade-module.nix;
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
            cfg = config.services.homeManagerAutoUpgrade;

            scripts = import ./internal/auto-upgrade-script.nix {
              inherit pkgs;
              homeManager = if homeManagerPackage != null then homeManagerPackage else pkgs.home-manager;
            };

            stateFile = "${config.xdg.stateHome}/hm-auto-upgrade/last-run";

            # Arbitrary consumer shell reaches the script as a FILE it
            # sources, not as spliced text: the script itself stays a
            # real, shellcheck-verified .sh file rather than becoming a
            # Nix string concatenation.
            fragmentFor =
              name: text: if text == "" then null else pkgs.writeShellScript "hm-auto-upgrade-${name}" text;
            preFragment = fragmentFor "pre" cfg.preCommand;
            resultFragment = fragmentFor "on-result" cfg.onResult;

            upgradeArgs = [
              "${scripts.upgrade}/bin/hm-auto-upgrade"
              "--flake-ref"
              (toString cfg.flakeRef)
              "--username"
              config.home.username
              "--state-file"
              stateFile
              "--keep-generations"
              (toString cfg.keepGenerations)
            ]
            ++ lib.optionals (cfg.sshKeyPath != null) [
              "--ssh-key"
              (toString cfg.sshKeyPath)
            ]
            ++ lib.optionals (cfg.sshAuthSock != null) [
              "--ssh-auth-sock"
              (toString cfg.sshAuthSock)
            ]
            ++ lib.concatMap (o: [
              "--ssh-option"
              o
            ]) cfg.sshExtraOptions
            ++ lib.optionals (cfg.gitCredentialsFile != null) [
              "--git-credentials"
              (toString cfg.gitCredentialsFile)
            ]
            ++ lib.optionals (preFragment != null) [
              "--pre-command"
              "${preFragment}"
            ]
            ++ lib.optionals (resultFragment != null) [
              "--on-result"
              "${resultFragment}"
            ]
            ++ lib.optional cfg.desktop.enable "--desktop-notify";

            # Detached for the same reason the interactive wrapper is
            # (see `detachedRun`): the switch this unit runs restarts
            # every user unit whose store path changed -- which can
            # include THIS one, killing the activation mid-flight. The
            # transient unit is never in that restart set.
            launcher = pkgs.writeShellScript "hm-auto-upgrade-launch" (
              self.detachedRun pkgs {
                label = "hm-auto-upgrade-run";
                command = lib.escapeShellArgs upgradeArgs;
                extraProperties = [ "RuntimeMaxSec=${toString cfg.runtimeMaxSec}" ];
              }
            );

            statusLine = "${scripts.status}/bin/hm-auto-upgrade-status --only-failures ${stateFile} || true";

            wanted = cfg.enable && !systemManaged && cfg.flakeRef != null;
          in
          {
            options.services.homeManagerAutoUpgrade = {
              enable = mkOption {
                type = types.bool;
                default = if systemManaged then false else enable;
                description = ''
                  Whether to keep this home current with a scheduled
                  `home-manager switch` against {option}`flakeRef`.
                  Seeded by the builder's `autoUpgrade` argument. Setting
                  this to `false` is the single off switch: no unit is
                  produced AND the unconfigured-reference warning is
                  silenced, for someone who manages updates themselves.
                '';
              };

              flakeRef = mkOption {
                type = types.nullOr types.str;
                default = flakeRef;
                example = "git+https://example.org/home-manager-config.git";
                description = ''
                  The LIVE flake reference to track -- a mutable one
                  (`git+https://...`, `github:...`, `/etc/nixos`), NOT a
                  flake input: an input resolves to an immutable
                  `/nix/store` path, so switching to it repeatedly can
                  never pick up a new commit. Seeded by the builder's
                  `autoUpgradeFlakeRef` and never from `loginFlakeRef` --
                  see this module's own doc comment for why that
                  fallback cannot work. `null` warns.
                '';
              };

              schedule = mkOption {
                type = types.str;
                default = "daily";
                description = "The timer's `OnCalendar` expression.";
              };

              persistent = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Whether a run missed while the machine was off (or
                  while no user session existed) fires as soon as the
                  timer is next active, instead of being skipped until
                  the next scheduled point.
                '';
              };

              randomizedDelaySec = mkOption {
                type = types.ints.unsigned;
                default = 300;
                description = ''
                  Random delay before each trigger, in seconds. With
                  {option}`persistent` a caught-up run would otherwise
                  start a full build at the exact moment of login; this
                  lets the session settle first, and staggers a fleet
                  booted together. `0` disables it.
                '';
              };

              keepGenerations = mkOption {
                type = types.ints.unsigned;
                default = 10;
                description = ''
                  Home-manager profile generations to keep after a
                  successful switch. `0` never prunes. Pruning failures
                  never fail the run -- an upgrade that worked is not
                  reported as broken because cleanup of OLD generations
                  hit a lock.
                '';
              };

              runtimeMaxSec = mkOption {
                type = types.ints.unsigned;
                default = 7200;
                description = ''
                  Backstop for the detached unit. Nothing else supervises
                  it, so a switch that blocks silently (a stuck
                  credential prompt, a dead remote) would otherwise hang
                  forever; on expiry systemd terminates it and the
                  ordinary failure path reports it.
                '';
              };

              sshKeyPath = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Path to a private key for an SSH-flavoured
                  {option}`flakeRef`. A PATH, never a key: point it at a
                  decrypted secret (`config.sops.secrets."...".path`) or
                  any file on disk. When unset, the script falls back to
                  `$XDG_CONFIG_HOME/hm-auto-upgrade/ssh-key` if that
                  exists, so a machine can be set up with no Nix change
                  at all. The key must be passphrase-less (nothing can
                  type one at 03:00) and the host must already be in
                  `known_hosts`.
                '';
              };

              sshAuthSock = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Agent socket to use. A systemd USER service does not
                  inherit a login shell's `SSH_AUTH_SOCK` -- it only sees
                  one if the agent is itself a user service, or something
                  imported it into the user manager's environment. Set
                  this when you know the path and the agent is the
                  credential you want used.
                '';
              };

              sshExtraOptions = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [ "StrictHostKeyChecking=accept-new" ];
                description = ''
                  Extra `ssh -o` options. Host-key checking is NOT
                  weakened by default; this is the escape hatch for a
                  consumer who wants that trade deliberately.
                '';
              };

              gitCredentialsFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Path to a git-credentials-format file
                  (`https://user:secret@host`, one per line) for an HTTPS
                  {option}`flakeRef`. A PATH, never a credential. When
                  unset, the script falls back to
                  `$XDG_CONFIG_HOME/hm-auto-upgrade/git-credentials` if
                  that exists. Either way the file is read at RUN time,
                  so rotating a token needs no rebuild. A file readable
                  by group or others is refused rather than used.
                '';
              };

              preCommand = mkOption {
                type = types.lines;
                default = "";
                description = ''
                  Shell sourced before the switch -- for a credential
                  setup this module does not model. Sourced, not
                  executed, so it can export environment for the switch.
                '';
              };

              onResult = mkOption {
                type = types.lines;
                default = "";
                description = ''
                  Shell sourced after the switch, with `$RESULT` (the
                  exit code), `$TARGET` and `$STATE_FILE` exported --
                  for a consumer's own alerting, on top of (not instead
                  of) the built-in reporting.
                '';
              };

              console.enable = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Print a one-line warning at interactive shell start
                  when the LAST run failed. Silent on success -- a line
                  that appears every day is one nobody reads. Hooked into
                  whichever of bash/zsh/fish this home enables;
                  `hm-auto-upgrade-status` is always available to check
                  deliberately.
                '';
              };

              desktop.enable = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Send a desktop notification on failure, and on the
                  first success that ends a failing streak -- never a
                  daily "still fine" popup. A reachable session bus is
                  probed first, so a headless run stays silent instead of
                  failing.
                '';
              };
            };

            config = lib.mkMerge [
              {
                warnings =
                  lib.optional (cfg.enable && systemManaged) ''
                    nixpkgs-lib-extensions: services.homeManagerAutoUpgrade is enabled for `${config.home.username}`, whose home is SYSTEM-managed on this host (built into the NixOS system). No timer is created: that home switches with `nixos-rebuild`, and a second `home-manager switch` on a timer would fight it over one profile. Move the user to `loginHomes` for a standalone home, or set `services.homeManagerAutoUpgrade.enable = false;` to silence this.
                  ''
                  ++ lib.optional (cfg.enable && !systemManaged && cfg.flakeRef == null) ''
                    nixpkgs-lib-extensions: services.homeManagerAutoUpgrade is enabled for `${config.home.username}` but no LIVE flake reference is available, so no timer is created. Set the builder's `autoUpgradeFlakeRef` argument (or `services.homeManagerAutoUpgrade.flakeRef`) to a mutable ref like `"git+https://..."`. A `loginFlakeRef` that is a flake INPUT cannot be used: it resolves to an immutable /nix/store path, which can never pick up a new commit. If you update this home yourself, set `services.homeManagerAutoUpgrade.enable = false;`.
                  '';
              }

              (lib.mkIf wanted {
                home.packages = [ scripts.status ];

                systemd.user.services."hm-auto-upgrade" = {
                  Unit = {
                    Description = "Home Manager auto upgrade (detached launcher)";
                    After = [
                      "network-online.target"
                      # secrets are decrypted by sops-nix's own user
                      # service at default.target; a Persistent timer
                      # catching up at manager start would otherwise race
                      # it and read a credential path that does not exist
                      # yet. Harmless when sops-nix is not in use.
                      "sops-nix.service"
                    ];
                    Wants = [
                      "network-online.target"
                      "sops-nix.service"
                    ];
                  };
                  Service = {
                    Type = "oneshot";
                    ExecStart = "${launcher}";
                  };
                };

                systemd.user.timers."hm-auto-upgrade" = {
                  Unit.Description = "Home Manager auto upgrade timer";
                  Timer = {
                    OnCalendar = cfg.schedule;
                    Persistent = cfg.persistent;
                    RandomizedDelaySec = cfg.randomizedDelaySec;
                  };
                  Install.WantedBy = [ "timers.target" ];
                };
              })

              # The status line is worth having even where no timer runs
              # (a home that USED to auto-upgrade still has a last-run
              # state file worth reporting), so it is gated only on the
              # console switch and on the shell actually being enabled.
              (lib.mkIf (cfg.console.enable && !systemManaged) {
                programs.bash.initExtra = lib.mkIf config.programs.bash.enable statusLine;
                programs.zsh.initExtra = lib.mkIf config.programs.zsh.enable statusLine;
                programs.fish.interactiveShellInit = lib.mkIf config.programs.fish.enable statusLine;
              })
            ];
          }
        )
      ];
    };
}
