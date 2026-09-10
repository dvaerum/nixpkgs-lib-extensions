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

    It WRAPS nixpkgs' `nix.gc`, but only for the half `nix.gc` does
    well. Upstream can express "delete older than 30 days" and nothing
    else, and on a host that sat idle past that cutoff it deletes every
    generation but the current one -- leaving no rollback target on
    precisely the machine that has been unattended longest. A retention
    FLOOR cannot be written as a flag, so choosing the generations is
    this module's job; `nix.gc` is left to collect the unreferenced
    paths afterwards, which needs no policy at all.

    So the split is:

    - `nixos-prune-generations.service` (this module) decides which
      generations to delete: older than `keepDays`, except the newest
      `keepGenerations` and the running one.
    - `nix-gc.service` (nixpkgs) then collects whatever is no longer
      referenced. It rides its own timer, so there is only one schedule.

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
                  When to run -- an `OnCalendar` expression, applied to
                  nixpkgs' own `nix.gc` timer, which triggers this
                  module's prune first and then the collection.
                '';
              };

              randomizedDelaySec = mkOption {
                type = types.int;
                default = 3600;
                description = ''
                  Jitter on the timer. Generous by default: a garbage
                  collection is heavy on I/O and there is no reason for
                  a fleet to start one simultaneously.
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

              # Upstream for the half that needs no policy. `options` is
              # pinned EMPTY on purpose: its `--delete-older-than` is
              # exactly the flag whose missing floor this module exists
              # to supply, and letting both delete generations would
              # make the floor a lie.
              nix.gc = {
                automatic = mkBuilderDefault true;
                dates = mkBuilderDefault cfg.schedule;
                randomizedDelaySec = mkBuilderDefault cfg.randomizedDelaySec;
                persistent = mkBuilderDefault cfg.persistent;
                options = mkBuilderDefault "";
              };

              systemd.services.nixos-prune-generations = {
                description = "Prune stale system-profile generations";
                # Rides nix-gc's timer rather than adding a second one,
                # and strictly before it: pruning first is what turns
                # those generations' store paths into garbage for the
                # collection to find.
                before = [ "nix-gc.service" ];
                wantedBy = [ "nix-gc.service" ];
                # A half-finished prune is harmless (the next run
                # continues), but being stopped mid-delete by an
                # unrelated `nixos-rebuild switch` is never what anyone
                # wants, and restarting a oneshot means running an
                # unscheduled GC pass at activation time.
                restartIfChanged = false;
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = lib.escapeShellArgs pruneArgs;
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
