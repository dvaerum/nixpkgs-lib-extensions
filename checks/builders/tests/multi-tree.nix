# Multi-tree `loginFlakeRef`: combining rootPath's own tree with one or
# more additional trees on the SAME host, and the per-tree trust
# decision that gates whether an additional tree's configuration.nix
# (full, unrestricted NixOS module authority) gets imported at all.
# home.nix and the account itself (userModule) are never gated by trust
# -- see registry.nix's loginFlakeRefSources doc comment.
{
  lib,
  myLib,
  inputs,
  system,
  mkProbeSystem,
  fixturesDir,
  exampleDir,
  ...
}:
{
  # a bare list entry (no wrapper) is untrusted by default: the account
  # exists, home.nix applies, but configuration.nix is dropped
  bare-list-entry-drops-configuration =
    let
      sys = mkProbeSystem {
        inherit inputs system;
        hostname = "multitree-bare";
        users = [ "per" ];
        loginFlakeRef = [ (fixturesDir + "/tree-per") ];
      };
    in
    sys.config.users.users ? per && !(sys.config.users.groups ? per-marker-group);

  # ... and home.nix still applies for that same untrusted user -- trust
  # only ever gates configuration.nix, never the home side
  bare-list-entry-keeps-home =
    (mkProbeSystem {
      inherit inputs system;
      hostname = "multitree-bare-home";
      users = [ "per" ];
      loginFlakeRef = [ (fixturesDir + "/tree-per") ];
    }).config.home-manager.users ? per;

  # `{ source; allowNixosConfig = true; }` is the opt-in: configuration.nix
  # IS imported for that source
  wrapped-entry-trusts-configuration =
    (mkProbeSystem {
      inherit inputs system;
      hostname = "multitree-trusted";
      users = [ "bo" ];
      loginFlakeRef = [
        {
          source = fixturesDir + "/tree-bo";
          allowNixosConfig = true;
        }
      ];
    }).config.users.groups ? bo-marker-group;

  # a wrapper with allowNixosConfig = false (explicit) behaves exactly
  # like the bare/default form
  wrapped-entry-explicit-false-drops-configuration =
    !(
      (mkProbeSystem {
        inherit inputs system;
        hostname = "multitree-explicit-false";
        users = [ "per" ];
        loginFlakeRef = [
          {
            source = fixturesDir + "/tree-per";
            allowNixosConfig = false;
          }
        ];
      }).config.users.groups ? per-marker-group
    );

  # rootPath's OWN tree is ALWAYS trusted, list form or not -- eve (from
  # exampleDir, this probe's rootPath) keeps her configuration.nix
  # (backup-operators group) on a host that ALSO has an untrusted list
  # entry (per, marker dropped) -- both properties proven on one host so
  # the list form can't be accidentally replacing rootPath instead of
  # adding to it.
  rootpath-stays-trusted-alongside-a-list =
    let
      sys = mkProbeSystem {
        inherit inputs system;
        hostname = "multitree-rootpath";
        users = [
          "eve"
          "per"
        ];
        loginFlakeRef = [ (fixturesDir + "/tree-per") ];
      };
    in
    sys.config.users.groups ? backup-operators && !(sys.config.users.groups ? per-marker-group);

  # the SAME username discovered from more than one source is ambiguous
  # -- must throw, never silently pick one (checks/fixtures/tree-collide
  # deliberately reuses "per")
  cross-source-collision-throws =
    !(builtins.tryEval (
      (mkProbeSystem {
        inherit inputs system;
        hostname = "multitree-collide";
        users = [ "per" ];
        loginFlakeRef = [
          (fixturesDir + "/tree-per")
          (fixturesDir + "/tree-collide")
        ];
      }).config.users.users
    )).success;

  # the same collision, but between rootPath's OWN tree and a list
  # entry -- not just between two list entries. loginFlakeRefSources
  # always prepends rootPath as a source, so resolveUsers' duplicate
  # check must see it too.
  cross-source-collision-includes-rootpath =
    !(builtins.tryEval (
      (mkProbeSystem {
        inherit inputs system;
        hostname = "multitree-collide-rootpath";
        users = [ "per" ];
        rootPath = fixturesDir + "/tree-per";
        loginFlakeRef = [ (fixturesDir + "/tree-collide") ];
      }).config.users.users
    )).success;

  # singular (non-list) loginFlakeRef now defaults to untrusted too --
  # the deliberate breaking-change default flip (see the plan/commit
  # message): replaces rootPath entirely (unchanged "instead of"
  # meaning), but its configuration.nix is dropped unless wrapped.
  singular-bare-defaults-untrusted =
    !(
      (mkProbeSystem {
        inherit inputs system;
        hostname = "multitree-singular-bare";
        users = [ "per" ];
        loginFlakeRef = fixturesDir + "/tree-per";
      }).config.users.groups ? per-marker-group
    );
  singular-wrapped-can-opt-in =
    (mkProbeSystem {
      inherit inputs system;
      hostname = "multitree-singular-wrapped";
      users = [ "bo" ];
      loginFlakeRef = {
        source = fixturesDir + "/tree-bo";
        allowNixosConfig = true;
      };
    }).config.users.groups ? bo-marker-group;
  # singular still REPLACES rootPath outright (unchanged from before this
  # feature) -- eve, who lives in rootPath/exampleDir, is absent from the
  # tree entirely when loginFlakeRef is singular (unlike the list form
  # above, which keeps her), so merely SELECTING her throws (the same
  # typo error `users` gives for any name outside the tree) rather than
  # her configuration.nix quietly being missing.
  singular-still-replaces-rootpath =
    !(builtins.tryEval (
      (mkProbeSystem {
        inherit inputs system;
        hostname = "multitree-singular-replaces";
        users = [ "eve" ];
        loginFlakeRef = {
          source = fixturesDir + "/tree-bo";
          allowNixosConfig = true;
        };
      }).config.users.users
    )).success;

  # Under a PLAN (buildNixosConfigurations), the users-tree is scanned
  # ONCE from `_defaults`' own rootPath/loginFlakeRef alone and shared
  # verbatim by every host -- a host's own override of either merges
  # normally into its OTHER arguments, but has NO effect on which users
  # are discovered for it (see build-nixos-configurations.nix's doc
  # comment for the full explanation). `laptop` here sets its own
  # rootPath naming a tree with "bo"; the plan-wide scan (from
  # `_defaults`, naming "per") wins regardless -- selecting "bo" on
  # `laptop` is therefore a typo (unknown user) and throws.
  plan-host-rootpath-override-is-ignored-for-discovery =
    !(builtins.tryEval (
      (myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          rootPath = fixturesDir + "/tree-per";
          users = [ "per" ];
        };
        laptop = {
          rootPath = fixturesDir + "/tree-bo";
          users = [ "bo" ];
        };
      }).laptop.config.users.users
    )).success;
}
