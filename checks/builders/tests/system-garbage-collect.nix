# systemGarbageCollectModule's wiring: that it is OFF unless asked, that
# it rides nixpkgs' nix.gc timer rather than adding a second one, and
# that the retention policy reaches the script. The policy's own
# behaviour (the floor, never-delete-current, the fail-closed refusal)
# is covered by checks/system-garbage-collect/script.nix.
{
  lib,
  myLib,
  inputs,
  system,
  ...
}:
let
  hostWith =
    extra:
    (myLib.buildNixosConfigurations {
      _defaults = {
        inherit inputs system;
        traceDiscoveredUsers = false;
        users = [ ];
      }
      // extra;
      gchost = { };
    }).gchost.config;

  off = hostWith { };
  on = hostWith { systemGarbageCollect = true; };

  execOf = cfg: cfg.systemd.services.nixos-prune-generations.serviceConfig.ExecStart;
in
{
  # ── OFF unless asked, unlike its auto-upgrade siblings ──
  # Their worst case is a warning; this one deletes things that cannot
  # be recovered, so a library that shipped it on by default would start
  # removing generations on every consuming host the moment it updated.
  system-gc-off-by-default =
    !(off.systemd.services ? nixos-prune-generations)
    && !(off.systemd.timers ? nixos-prune-generations);

  # Only that IT is silent. The host still warns about systemAutoUpgrade
  # having no flakeRef, which is a sibling module doing its job.
  system-gc-silent-when-off = !(lib.any (w: lib.hasInfix "systemGarbageCollect" w) off.warnings);

  system-gc-unit-present-when-on = on.systemd.services ? nixos-prune-generations;

  # ── it must NOT touch the host's GC policy ─────────────────────────
  # The first cut rode nix.gc's timer and set `nix.gc.automatic = true`
  # to get one. That is a landmine in a library: a host may disable
  # calendar GC deliberately -- nixos-developer-system does, because the
  # sweep was deleting unrooted local builds -- and a module that quietly
  # switches it back on breaks something it was never asked to manage.
  #
  # Asserted as "identical with the module on and off", which is the
  # property that matters and cannot rot into a weaker check.
  system-gc-leaves-nix-gc-alone =
    on.nix.gc.automatic == off.nix.gc.automatic
    && on.nix.gc.options == off.nix.gc.options
    && on.nix.gc.dates == off.nix.gc.dates
    && on.nix.gc.persistent == off.nix.gc.persistent;

  # ... which means it needs its own timer, not upstream's
  system-gc-has-its-own-timer =
    let
      t = on.systemd.timers.nixos-prune-generations.timerConfig;
    in
    t.OnCalendar == "weekly" && t.Persistent == true && t.RandomizedDelaySec == 3600;

  system-gc-timer-enabled = on.systemd.timers.nixos-prune-generations.wantedBy == [ "timers.target" ];

  # and no ordering edge onto a unit that may not be scheduled at all
  system-gc-not-coupled-to-nix-gc =
    let
      s = on.systemd.services.nixos-prune-generations;
    in
    (s.before or [ ]) == [ ] && (s.wantedBy or [ ]) == [ ];

  # ── the policy reaches the script ──
  system-gc-retention-wired =
    lib.hasInfix "--keep-days 30" (execOf on) && lib.hasInfix "--keep-generations 10" (execOf on);

  system-gc-retention-overridable =
    let
      cfg = hostWith {
        systemGarbageCollect = true;
        modules = [
          {
            services.systemGarbageCollect = {
              keepDays = 60;
              keepGenerations = 20;
            };
          }
        ];
      };
    in
    lib.hasInfix "--keep-days 60" (execOf cfg) && lib.hasInfix "--keep-generations 20" (execOf cfg);

  # dry-run must be absent unless asked: a flag that silently defaulted
  # on would make the whole thing a no-op that looks like it is working
  system-gc-no-dry-run-by-default = !(lib.hasInfix "--dry-run" (execOf on));

  system-gc-dry-run-wired = lib.hasInfix "--dry-run" (
    execOf (hostWith {
      systemGarbageCollect = true;
      modules = [ { services.systemGarbageCollect.dryRun = true; } ];
    })
  );

  # ── a host's own definition still wins ──
  system-gc-consumer-overrides-builder =
    (hostWith {
      systemGarbageCollect = true;
      modules = [ { nix.gc.dates = "daily"; } ];
    }).nix.gc.dates == [ "daily" ];

  # ── inspectable by hand ──
  system-gc-command-installed = lib.any (
    p: (p.name or "") == "nixos-prune-generations"
  ) on.environment.systemPackages;

  # ── not stopped mid-delete by an unrelated activation ──
  system-gc-not-in-restart-set =
    on.systemd.services.nixos-prune-generations.restartIfChanged == false;
}
