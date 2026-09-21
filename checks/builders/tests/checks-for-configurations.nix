# checksForConfigurations: what a flake's `checks` output gets from the
# builders -- the two halves' different build attributes, and the
# per-system bucketing that a hand-written `checks.x86_64-linux =
# mapAttrs ...` silently gets wrong on a mixed fleet.
{
  lib,
  myLib,
  inputs,
  system,
  ...
}:
let
  built = myLib.buildConfigurations {
    _defaults = {
      inherit inputs system;
      traceDiscoveredUsers = false;
      homeAutoUpgrade = false;
      loginHomes = [ "alice" ];
    };
    laptop = { };
  };

  checks = myLib.checksForConfigurations built;
in
{
  # ── both halves reach the output, under their own prefixes ──
  checks-for-configurations-covers-hosts = checks.${system} ? "nixos-laptop";

  checks-for-configurations-covers-homes = lib.any (n: lib.hasPrefix "home-" n) (
    lib.attrNames checks.${system}
  );

  # ── and they are the RIGHT derivations, not merely present ──
  checks-for-configurations-host-is-toplevel =
    checks.${system}."nixos-laptop" == built.nixosConfigurations.laptop.config.system.build.toplevel;

  checks-for-configurations-home-is-activation-package =
    let
      name = lib.head (lib.filter (n: lib.hasPrefix "home-" n) (lib.attrNames checks.${system}));
      home = built.homeConfigurations.${lib.removePrefix "home-" name};
    in
    checks.${system}.${name} == home.activationPackage;

  # ── the bucketing is per DERIVATION, not a hardcoded system ──
  # An aarch64 host's toplevel filed under x86_64-linux is a check that
  # `nix flake check` reports without ever having been able to run it.
  #
  # Raw derivations rather than real cross-arch hosts: what is under test
  # is "group by drv.system" and nothing else, and evaluating an aarch64
  # NixOS toplevel would add minutes to every run of this suite for no
  # extra coverage. The assertions above already prove the REAL
  # configurations reach the right attribute.
  checks-for-configurations-buckets-by-system =
    let
      fake =
        sys:
        derivation {
          name = "fake";
          system = sys;
          builder = "/bin/sh";
        };
      mixed = myLib.checksForConfigurations {
        nixosConfigurations.amd.config.system.build.toplevel = fake "x86_64-linux";
        nixosConfigurations.arm.config.system.build.toplevel = fake "aarch64-linux";
        homeConfigurations.pi.activationPackage = fake "aarch64-linux";
      };
    in
    lib.sort (a: b: a < b) (lib.attrNames mixed) == [
      "aarch64-linux"
      "x86_64-linux"
    ]
    && mixed.x86_64-linux ? "nixos-amd"
    && mixed.aarch64-linux ? "nixos-arm"
    && mixed.aarch64-linux ? "home-pi"
    # the whole point: the arm host must NOT appear under x86_64
    && !(mixed.x86_64-linux ? "nixos-arm")
    && !(mixed.x86_64-linux ? "home-pi");

  # ── it accepts either single-purpose builder's output as-is ──
  checks-for-configurations-accepts-partial =
    myLib.checksForConfigurations { } == { }
    && (myLib.checksForConfigurations {
      inherit (built) nixosConfigurations;
    }).${system}
      ? "nixos-laptop";

  # An empty result is a silent no-op gate, so the function warns. The
  # WARNING TEXT is not assertable in pure eval (lib.warn is a trace, and
  # tryEval does not catch it), so this pins the two things that are: the
  # bug case still returns `{ }` rather than throwing, and the correct
  # call is unaffected. The messages themselves were verified live --
  # both branches fire, the correct path is silent.
  checks-for-configurations-bare-output-yields-nothing =
    myLib.checksForConfigurations built.nixosConfigurations == { };

  checks-for-configurations-empty-input-yields-nothing = myLib.checksForConfigurations { } == { };
}
