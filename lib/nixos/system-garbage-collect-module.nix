# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ lib, ... }:
{
  /**
    A NixOS module that prunes stale system-profile generations on a
    schedule, and reclaims the store paths they were pinning.

    The system-side counterpart to what a housekeeping timer typically
    does for a home-manager profile. Without it a host accumulates
    generations indefinitely: every `nixos-rebuild switch`, and every
    run of `systemAutoUpgradeModule`, adds one, and nothing removes any.

    It does NOT touch nixpkgs' `nix.gc`, on purpose. Generation
    retention and store collection are different jobs, and a host may
    disable calendar GC for reasons that have nothing to do with
    generations -- because the sweep was deleting local builds with no
    GC root, say. A module that rode that timer would be silently inert
    on such a host; one that switched it back on would break something
    it was never asked to manage. Both were true of the first cut of
    this module.

    `nix.gc` also cannot express what this is for. It offers "delete
    older than N days" and nothing else, so on a host that sat idle past
    the cutoff it deletes every generation but the running one --
    leaving no rollback target on precisely the machine that has been
    unattended longest. A retention FLOOR cannot be written as a flag.

    So: this module owns a timer of its own, decides which generations
    to delete -- older than `keepDays`, except the newest
    `keepGenerations` and the running one -- and then reclaims what they
    were pinning with `nix-collect-garbage`, in the same unit. Deleting
    a generation only makes its closure collectable; without the
    reclaim the generation count falls while the disk stays exactly as
    full, so `collect` is on by default.

    Deleting a generation is not reversible, so `enable` defaults to
    **false** -- deliberately unlike `systemAutoUpgrade`, whose worst
    case is a warning. A library that started deleting things on every
    consuming host the moment it was updated would be indefensible.

    # Example

    ```nix
    # fleet-wide, in a hosts attrset's `_defaults`
    systemGarbageCollect = true;

    # and per host, if the defaults do not suit
    services.systemGarbageCollect = {
      keepDays = 60;
      keepGenerations = 20;
    };
    ```

    # Type

    ```
    systemGarbageCollectModule :: Attribute -> Module
    ```

    # Arguments

    enable
    : The `enable` option's DEFAULT -- what the builder's
    : `systemGarbageCollect` argument feeds in. Default `false`,
    : because the action is destructive and irreversible.
  */
  systemGarbageCollectModule =
    {
      enable ? false,
    }:
    {
      _file = ./system-garbage-collect-module.nix;
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
            cfg = config.services.systemGarbageCollect;

            scripts = import ./internal/garbage-collect-script.nix { inherit pkgs; };

            pruneArgs = [
              "${scripts.prune}/bin/nixos-prune-generations"
              "--profile"
              cfg.profile
              "--keep-days"
              (toString cfg.keepDays)
              "--keep-generations"
              (toString cfg.keepGenerations)
            ]
            ++ lib.optional cfg.collect "--collect"
            ++ lib.optional cfg.dryRun "--dry-run";
          in
          {
            options.services.systemGarbageCollect = {
              enable = mkOption {
                type = types.bool;
                default = enable;
                description = ''
                  Prune stale system-profile generations on a schedule
                  and collect the store paths they were pinning.

                  Seeded by the builder's `systemGarbageCollect`
                  argument, and `false` by default: deleting a
                  generation cannot be undone.
                '';
              };

              keepDays = mkOption {
                type = types.int;
                default = 30;
                description = ''
                  Delete generations older than this many days --
                  subject to `keepGenerations`, which overrides age.
                '';
              };

              keepGenerations = mkOption {
                type = types.int;
                default = 10;
                description = ''
                  Never delete this many newest generations, however old
                  they are. This is the part `nix.gc` cannot express: at
                  `--delete-older-than 30d` alone, a host that has been
                  idle for two months keeps only the generation it is
                  running, so the one machine nobody has been watching
                  is the one with nothing to roll back to.

                  `0` disables the floor and lets age alone govern. The
                  running generation is still never deleted.
                '';
              };

              profile = mkOption {
                type = types.str;
                default = "/nix/var/nix/profiles/system";
                description = ''
                  The profile whose generations are pruned. Rarely worth
                  changing; it exists so the unit can be pointed at a
                  copy when trying the policy out.
                '';
              };

              schedule = mkOption {
                type = types.str;
                default = "weekly";
                description = ''
                  When to run -- an `OnCalendar` expression for this
                  module's own timer. Independent of `nix.gc`, which
                  this module never writes.
                '';
              };

              randomizedDelaySec = mkOption {
                type = types.int;
                default = 3600;
                description = ''
                  Jitter on the timer. Generous by default: pruning
                  walks a profile's whole generation list and the
                  collection it enables is heavy on I/O, so there is no
                  reason for a fleet to start together.
                '';
              };

              persistent = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Catch up a run missed while the machine was off,
                  rather than skipping until next week.
                '';
              };

              collect = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  After pruning, run `nix-collect-garbage` to reclaim
                  the store paths the deleted generations were pinning.

                  On by default, because reclaiming the space is the
                  point: deleting a generation only makes its closure
                  collectable, so without this the generation count
                  falls while the disk stays exactly as full.

                  It runs in this module's own unit. It does NOT switch
                  on `nix.gc`, which is a policy this module never
                  writes -- a host is free to disable calendar GC for
                  its own reasons and still use this.

                  Turn it OFF on a host where a scheduled collection is
                  unwanted -- typically one where people leave `nix
                  build` outputs around without a `result` symlink, so a
                  sweep deletes work still in use. That is worth fixing
                  at the source (give those builds a GC root) rather
                  than living with forever, but the switch is here.
                '';
              };

              dryRun = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Report which generations WOULD be deleted and delete
                  nothing. Worth a cycle or two on a host with a long
                  history before letting it run for real.
                '';
              };
            };

            config = lib.mkIf cfg.enable {
              assertions = [
                {
                  assertion = cfg.keepGenerations >= 0 && cfg.keepDays >= 0;
                  message = "services.systemGarbageCollect.keepDays and keepGenerations cannot be negative.";
                }
              ];

              systemd.services.nixos-prune-generations = {
                description = "Prune stale system-profile generations";
                # A half-finished prune is harmless (the next run
                # continues), but being stopped mid-delete by an
                # unrelated `nixos-rebuild switch` is never what anyone
                # wants, and restarting a oneshot means running an
                # unscheduled prune at activation time.
                restartIfChanged = false;
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = lib.escapeShellArgs pruneArgs;
                };
              };

              # Its OWN timer, and deliberately NOT nixpkgs' `nix.gc`
              # one. Generation retention and store collection are
              # different jobs: a host may disable calendar GC for
              # reasons that have nothing to do with generations --
              # nixos-developer-system does, because the sweep was
              # deleting local builds that had no GC root -- and a
              # module that rode that timer would be silently inert
              # there, or worse would switch it back on and break the
              # thing it was never asked to manage.
              #
              # So this module never writes `nix.gc` at all. Pruning
              # makes the old generations' store paths collectable; WHEN
              # they are actually reclaimed stays the host's own policy,
              # whether that is `nix.gc` on a calendar or
              # `nix.settings.min-free` under pressure.
              systemd.timers.nixos-prune-generations = {
                description = "Prune stale system-profile generations";
                wantedBy = [ "timers.target" ];
                timerConfig = {
                  OnCalendar = cfg.schedule;
                  Persistent = cfg.persistent;
                  RandomizedDelaySec = cfg.randomizedDelaySec;
                };
              };

              # On PATH so the policy can be inspected by hand --
              # `nixos-prune-generations --dry-run` answers "what would
              # this remove" without waiting for the timer.
              environment.systemPackages = [ scripts.prune ];
            };
          }
        )
      ];
    };
}
