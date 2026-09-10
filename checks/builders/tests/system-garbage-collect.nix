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
    !(off.systemd.services ? nixos-prune-generations) && off.nix.gc.automatic == false;

  # Only that IT is silent. The host still warns about systemAutoUpgrade
  # having no flakeRef, which is a sibling module doing its job.
  system-gc-silent-when-off = !(lib.any (w: lib.hasInfix "systemGarbageCollect" w) off.warnings);

  system-gc-unit-present-when-on = on.systemd.services ? nixos-prune-generations;

  # ── one timer, not two ──
  # It rides nix.gc's timer; a second timer would mean two schedules to
  # keep in step and a GC that can start while a prune is running.
  system-gc-rides-nix-gc-timer =
    let
      s = on.systemd.services.nixos-prune-generations;
    in
    s.before == [ "nix-gc.service" ]
    && s.wantedBy == [ "nix-gc.service" ]
    && !(on.systemd.timers ? nixos-prune-generations);

  # `nix.gc.dates` is a merge-friendly "str or listOf str", so the
  # evaluated value is a list even when one string was written.
  system-gc-seeds-upstream-timer = on.nix.gc.automatic && lib.toList on.nix.gc.dates == [ "weekly" ];

  # ── the invariant the whole design rests on ──
  # `nix.gc.options` must stay free of --delete-older-than: that flag is
  # the one whose missing floor this module exists to supply, and if
  # upstream also deleted generations the floor would be a lie.
  system-gc-upstream-does-not-delete-generations =
    on.nix.gc.options == "" && !(lib.hasInfix "delete" on.nix.gc.options);

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
