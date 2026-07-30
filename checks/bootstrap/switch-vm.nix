# Full end-to-end VM test for the home-manager login bootstrap: on first
# login a REAL `home-manager switch --flake ...` runs inside the VM,
# evaluating a real flake and activating a real home-manager profile.
#
# To work offline inside the VM, the flake it switches to is GENERATED with
# `path:` inputs pointing at the nixpkgs and home-manager store paths (path
# inputs need no network, and flake purity permits declared inputs where it
# forbids raw store-path imports).
#
# The guest gets the store as a disk image (useNixStoreImage) instead of the
# default 9p share -- evaluating nixpkgs over 9p is so slow the switch never
# finished. The activation package is pre-built on the HOST and seeded into
# the image: the VM still locks, evaluates and switches for real, but the
# resulting store path already exists. `homeModule` is defined once and
# rendered into the flake text, so host and guest provably build the same
# configuration.
#
# What this test does NOT prove (known fidelity limits): production
# bootstraps from `inputs.self` -- a store-path flake whose lock points at
# remote inputs -- while this VM switches a generated flake with `path:`
# inputs and a pre-seeded closure, so lock resolution/fetching of the
# production shape is never exercised. Keep such limits in mind before
# concluding "the VM passed, so production works".
{
  pkgs,
  nixpkgs,
  home-manager,
  myLib,
}:
let
  system = pkgs.stdenv.hostPlatform.system;

  homeModule = {
    home.username = "alice";
    home.homeDirectory = "/home/alice";
    home.stateVersion = nixpkgs.lib.trivial.release;
    home.file."hm-activated".text = "home-manager was here";
  };

  # nix refuses to CREATE a missing flake.lock inside the read-only store,
  # so the lock is generated here on the host and shipped with the flake --
  # in-VM evaluation then only verifies it. The narHash comes from a tiny
  # host derivation (pure fetchTree cannot hash an unlocked path input).
  lockedRefFor = input: {
    type = "path";
    path = toString input;
    lastModified = 0;
    # pinned to x86_64-linux: this runs during EVALUATION (IFD) and must be
    # buildable on the machine evaluating the checks, whatever system the
    # check itself targets
    narHash = builtins.readFile (
      nixpkgs.legacyPackages."x86_64-linux".runCommand "narhash" { } ''
        ${
          nixpkgs.legacyPackages."x86_64-linux".nix
        }/bin/nix-hash --type sha256 --sri ${input} | tr -d '\n' > $out
      ''
    );
  };

  flakeLock = builtins.toJSON {
    version = 7;
    root = "root";
    nodes = {
      root.inputs = {
        nixpkgs = "nixpkgs";
        home-manager = "home-manager";
      };
      nixpkgs = {
        locked = lockedRefFor nixpkgs;
        original = {
          type = "path";
          path = toString nixpkgs;
        };
      };
      home-manager = {
        inputs.nixpkgs = [ "nixpkgs" ];
        locked = lockedRefFor home-manager;
        original = {
          type = "path";
          path = toString home-manager;
        };
      };
    };
  };

  flakeNix = ''
    {
      inputs = {
        nixpkgs.url = "path:${nixpkgs}";
        home-manager = {
          url = "path:${home-manager}";
          inputs.nixpkgs.follows = "nixpkgs";
        };
      };

      outputs = { self, nixpkgs, home-manager }: {
        homeConfigurations."alice@fullvm" = home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs { system = "${system}"; };
          modules = [ ${nixpkgs.lib.generators.toPretty { } homeModule} ];
        };
      };
    }
  '';

  testFlake = pkgs.runCommand "test-flake" { } ''
    mkdir $out
    cp ${pkgs.writeText "flake.nix" flakeNix} $out/flake.nix
    cp ${pkgs.writeText "flake.lock" flakeLock} $out/flake.lock
  '';

  # the exact same configuration, built on the host to seed the VM's store
  hostBuiltHome = home-manager.lib.homeManagerConfiguration {
    pkgs = import nixpkgs { inherit system; };
    modules = [ homeModule ];
  };
in
pkgs.testers.runNixOSTest {
  name = "home-manager-bootstrap-switch";

  nodes.machine =
    { config, ... }:
    {
      imports = [
        (myLib.homeManagerBootstrapModule {
          inputs = { inherit home-manager; };
          inherit system;
          hostname = "fullvm";
          userRegistry."alice" = ../example/users/alice;
          loginHomes = [ "alice" ];
          loginFlakeRef = testFlake;
        })
      ];

      users.users.alice.isNormalUser = true;
      # log alice in at boot; her systemd user instance starts the bootstrap
      services.getty.autologinUser = "alice";

      # `home-manager switch` evaluates and builds inside the VM
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      # deliberately NO extra PATH for the service: the bootstrap wrapper
      # must be self-contained (pkgs.nix in its runtimeInputs). A real
      # host's systemd user service has no system profile on PATH -- that
      # exact gap once broke production with exit 127 while this test,
      # then carrying a `path = [ config.nix.package ]` workaround,
      # stayed green. Do not add PATH entries here.
      virtualisation.useNixStoreImage = true;
      virtualisation.writableStore = true;
      virtualisation.additionalPaths = [
        testFlake
        hostBuiltHome.activationPackage
        # the home-manager CLI also builds the news JSON on every switch
        # (before it even looks at news.display), so seed that too
        hostBuiltHome.config.news.json.output
      ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
    };

  testScript = ''
    import time

    status_cmd = (
        "su -l alice -c 'env XDG_RUNTIME_DIR=/run/user/$(id -u alice) "
        "systemctl --user is-active home-manager-bootstrap.service' 2>&1 || true"
    )

    machine.wait_for_unit("multi-user.target")

    # poll the unit VISIBLY until it reaches a final state, so a failure log
    # shows what the unit was doing instead of an opaque timeout
    state = "unknown"
    for _ in range(180):
        state = machine.execute(status_cmd)[1].strip()
        print(f"bootstrap unit state: {state!r}")
        if state in ("active", "failed"):
            break
        time.sleep(10)

    # always dump the service's own journal for diagnosability
    print(machine.execute("journalctl --no-pager -t home-manager-bootstrap | tail -n 100")[1])

    assert state == "active", f"bootstrap unit ended as {state!r}"

    machine.succeed("grep -q 'home-manager was here' /home/alice/hm-activated")
    machine.succeed("test -f ~alice/.local/state/home-manager-bootstrap.stamp")
  '';
}
