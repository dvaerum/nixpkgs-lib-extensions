# End-to-end VM test for `services.systemAutoUpgrade.activate`: the REAL
# module, the REAL `nixos-upgrade.service` (`nixos-rebuild boot --flake`)
# and the REAL policy unit, updating a booted NixOS guest from a flake.
#
# Two guests run the same update:
#
#   stageonly  activate = false  -> the next generation is staged as the
#                                   boot default and the running system
#                                   is NEVER switched; a marker says an
#                                   update is waiting for the next boot
#   control    activate = true   -> the policy says it WOULD switch
#
# The control is what keeps `stageonly` from passing vacuously: it proves
# the very same update does reach the activation step when the option is
# left alone. It runs with `dryRun` because a real switch to the minimal
# target system would tear down the test backdoor mid-test; the script
# test (script.nix) covers the real `switch-to-configuration` call.
#
# Offline, like checks/bootstrap/switch-vm.nix: the update's flake is
# GENERATED with a `path:` nixpkgs input and a lock made on the host, and
# the target systems are pre-built on the host and seeded into the guest's
# store. The guest still fetches, locks, evaluates and stages for real; the
# resulting store paths already exist. The target is evaluated through
# nixpkgs' own `eval-config.nix` on BOTH sides, so host and guest provably
# build the same system.
#
# What this does NOT prove: the real-world fetch (git over https) and a
# reboot into the staged generation -- the target here is not bootable.
{
  pkgs,
  nixpkgs,
  myLib,
}:
let
  system = pkgs.stdenv.hostPlatform.system;

  # Plain data on purpose: it is rendered into the flake text AND
  # evaluated on the host, so the two cannot diverge.
  targetModule = hostName: {
    networking.hostName = hostName;
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };
    system.stateVersion = nixpkgs.lib.trivial.release;
    environment.etc."stage-test-marker".text = "next generation";
  };

  hostNames = [
    "stageonly"
    "control"
  ];

  targets = nixpkgs.lib.genAttrs hostNames (
    name:
    import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [ (targetModule name) ];
    }
  );

  # nix refuses to CREATE a missing flake.lock inside the read-only store,
  # so the lock is generated here and shipped with the flake (see
  # checks/bootstrap/switch-vm.nix, from which this pattern is taken).
  narHash = builtins.readFile (
    nixpkgs.legacyPackages."x86_64-linux".runCommand "narhash" { } ''
      ${
        nixpkgs.legacyPackages."x86_64-linux".nix
      }/bin/nix-hash --type sha256 --sri ${nixpkgs} | tr -d '\n' > $out
    ''
  );

  flakeLock = builtins.toJSON {
    version = 7;
    root = "root";
    nodes = {
      root.inputs.nixpkgs = "nixpkgs";
      nixpkgs = {
        locked = {
          type = "path";
          path = toString nixpkgs;
          lastModified = 0;
          inherit narHash;
        };
        original = {
          type = "path";
          path = toString nixpkgs;
        };
      };
    };
  };

  flakeNix = ''
    {
      inputs.nixpkgs.url = "path:${nixpkgs}";

      outputs = { self, nixpkgs }: {
        nixosConfigurations = {
          ${nixpkgs.lib.concatMapStringsSep "\n      " (name: ''
            ${name} = import "''${nixpkgs}/nixos/lib/eval-config.nix" {
                    system = "${system}";
                    modules = [ ${nixpkgs.lib.generators.toPretty { } (targetModule name)} ];
                  };'') hostNames}
        };
      };
    }
  '';

  testFlake = pkgs.runCommand "stage-only-test-flake" { } ''
    mkdir $out
    cp ${pkgs.writeText "flake.nix" flakeNix} $out/flake.nix
    cp ${pkgs.writeText "flake.lock" flakeLock} $out/flake.lock
  '';

  # `nixos-rebuild` re-executes the copy built from the TARGET flake, so
  # that package has to be in the guest's store too, not just the system.
  seededFor = name: [
    targets.${name}.config.system.build.toplevel
    targets.${name}.config.system.build.nixos-rebuild
  ];

  node =
    name: policy:
    { lib, ... }:
    {
      imports = [ (myLib.systemAutoUpgradeModule { flakeRef = "path:${testFlake}"; }) ];

      services.systemAutoUpgrade = policy // {
        # the target is not comparable to the running test VM (different
        # initrd, kernel params), so a kernel/initrd "difference" would send
        # every run down the reboot-needed branch. This test is about the
        # config-only update, where activation is the only open question.
        rebootTriggers = [ ];
        pollIntervalSec = null;
      };

      # test VMs build without switch-to-configuration; the activating mode
      # needs it on the host (stage-only does not -- the assertion allows it)
      system.switch.enable = lib.mkIf (policy.activate or true) (lib.mkForce true);

      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      virtualisation.useNixStoreImage = true;
      virtualisation.writableStore = true;
      virtualisation.additionalPaths = [
        testFlake
        nixpkgs
      ]
      ++ seededFor name;
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
    };
in
pkgs.testers.runNixOSTest {
  name = "system-auto-upgrade-stage-only";

  nodes = {
    stageonly = node "stageonly" { activate = false; };
    control = node "control" { dryRun = true; };
  };

  testScript = ''
    start_all()
    for m in (stageonly, control):
        m.wait_for_unit("multi-user.target")

    def run_update(m, label):
        before = m.succeed("readlink /run/current-system").strip()
        # blocks until the engine has finished; the policy unit follows it
        m.succeed("systemctl start nixos-upgrade.service")
        m.succeed("systemctl start nixos-upgrade-policy.service")
        print(f"[{label}] engine journal:")
        print(m.execute("journalctl -u nixos-upgrade --no-pager -o cat | tail -n 15")[1])
        print(f"[{label}] policy journal:")
        policy_log = m.execute("journalctl -u nixos-upgrade-policy --no-pager -o cat")[1]
        print(policy_log)
        return before, policy_log

    # ── stage only ──────────────────────────────────────────────────────
    target = "${targets.stageonly.config.system.build.toplevel}"
    before, policy_log = run_update(stageonly, "stageonly")

    # the update was really staged as the next boot's generation ...
    staged = stageonly.succeed("readlink -f /nix/var/nix/profiles/system").strip()
    assert staged == target, f"profile is {staged}, expected {target}"

    # ... and the running system was never switched to it
    assert stageonly.succeed("readlink /run/current-system").strip() == before
    stageonly.fail("test -e /etc/stage-test-marker")
    assert "--no-activate" in stageonly.succeed(
        "systemctl cat nixos-upgrade-policy.service"
    )
    assert "leaving the staged generation for the next boot" in policy_log, policy_log
    assert "activating the staged generation" not in policy_log, policy_log

    # an update is announced, without a reboot being pending or scheduled
    marker = stageonly.succeed("cat /run/nixos-upgrade-policy/staged")
    assert f"generation={target}" in marker, marker
    stageonly.fail("test -e /run/nixos-upgrade-policy/pending")
    stageonly.fail("test -e /run/systemd/shutdown/scheduled")
    status = stageonly.succeed("nixos-upgrade-status")
    assert "update staged" in status and "next boot" in status, status

    # polling again must not change any of that (the policy runs every
    # few minutes on a real host)
    stageonly.succeed("systemctl start nixos-upgrade-policy.service")
    assert stageonly.succeed("readlink /run/current-system").strip() == before
    stageonly.succeed("grep -q since= /run/nixos-upgrade-policy/staged")

    # ── control: the same update, default policy ────────────────────────
    ctarget = "${targets.control.config.system.build.toplevel}"
    cbefore, clog = run_update(control, "control")
    assert control.succeed("readlink -f /nix/var/nix/profiles/system").strip() == ctarget
    assert "--no-activate" not in control.succeed("systemctl cat nixos-upgrade-policy.service")
    # it reaches the activation step (dryRun logs instead of switching)
    assert "activating the staged generation" in clog, clog
    # (through the profile, which is asserted above to be the target)
    assert (
        "DRY-RUN: would run: /nix/var/nix/profiles/system/bin/switch-to-configuration switch"
        in clog
    ), clog
    control.fail("test -e /run/nixos-upgrade-policy/staged")
  '';
}
