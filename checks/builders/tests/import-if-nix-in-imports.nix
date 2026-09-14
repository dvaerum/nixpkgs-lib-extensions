# importIfNix inside a module's `imports` list -- the context its own doc
# comment names as the whole point ("Dropped into a NixOS/home-manager
# module's `imports` list, that is exactly what you want"), and the one
# context no test covered.
#
# checks/lib-functions.nix calls the helpers DIRECTLY, with a package set
# built outside any module system -- which is precisely the situation that
# cannot deadlock, so a thorough suite there proved nothing about this.
# Reaching for the module-arg `pkgs` here recurses forever: the IFD probe
# must be BUILT to decide what goes in `imports`, building it forces
# `pkgs`, `pkgs` comes out of the config fixed point, and that fixed point
# is what the imports list is being assembled for. `builderPkgs` is the
# set the builder hands to the module system, reached without going
# through `config`, so it is the one that works -- these assertions are
# what keeps that true.
{
  lib,
  myLib,
  inputs,
  nixpkgs,
  system,
  mkProbeSystem,
  fixturesDir,
  invalidFixturesDir,
  ...
}:
let
  validModule = fixturesDir + "/import-if-nix-in-imports/valid.nix";
  validHomeModule = fixturesDir + "/import-if-nix-in-imports/valid-home.nix";
  ciphertext = invalidFixturesDir + "/git-crypted.nix";

  # A host whose imports list is DECIDED by the IFD probe, exactly as a
  # git-crypt-encrypted `private.nix` call site does it.
  hostProbe =
    path:
    mkProbeSystem {
      inherit inputs system;
      hostname = "import-if-nix-probe";
      modules = [
        (
          { extLib, builderPkgs, ... }:
          {
            imports = [ (extLib.importIfNix builderPkgs path) ];
          }
        )
      ];
    };

  homeProbe =
    path:
    myLib.mkHomeConfiguration {
      inherit inputs system;
      hostname = "laptop";
      username = "alice";
      homeModules = [
        (
          { extLib, builderPkgs, ... }:
          {
            imports = [ (extLib.importIfNix builderPkgs path) ];
          }
        )
      ];
    };
in
{
  # ── the plaintext branch: the file is really imported, and its option
  # assignment lands in the evaluated config ──
  import-if-nix-in-imports-applies-valid-module =
    (hostProbe validModule).config.users.groups ? from-import-if-nix;

  # ── the ciphertext branch: degrades to `{ }` and the host still
  # evaluates, which is the entire promise of the function ──
  import-if-nix-in-imports-skips-ciphertext =
    let
      probe = hostProbe ciphertext;
    in
    !(probe.config.users.groups ? from-import-if-nix)
    && probe.config.networking.hostName == "import-if-nix-probe";

  # ── the same wiring reaches a home: mk-home passes the builder's
  # specialArgs as extraSpecialArgs, so both mechanisms behave alike ──
  import-if-nix-in-imports-reaches-homes =
    (homeProbe validHomeModule).config.home.sessionVariables ? FROM_IMPORT_IF_NIX;

  # ── builderPkgs is the builder's OWN package set, not a second
  # nixpkgs: the builder's overlays and patches, same store paths as the
  # module-arg `pkgs` for a host that adds no module-level
  # `nixpkgs.overlays` (those compose onto `pkgs` only -- which is why
  # this probe host deliberately declares none).
  # A call site building its own `import inputs.nixpkgs { ... }` to escape
  # the recursion silently probes with a DIFFERENT nixpkgs than the host
  # is built from, which is the trap this argument exists to remove.
  # (Forcing `pkgs` in a module BODY is ordinary and does not recurse --
  # only an `imports` entry cannot do it.) ──
  builder-pkgs-is-the-builders-own-package-set =
    let
      probe = mkProbeSystem {
        inherit inputs system;
        hostname = "builder-pkgs-identity";
        modules = [
          (
            { pkgs, builderPkgs, ... }:
            {
              users.groups = lib.optionalAttrs (builderPkgs.hello.outPath == pkgs.hello.outPath) {
                builder-pkgs-matches = { };
              };
            }
          )
        ];
      };
    in
    probe.config.users.groups ? builder-pkgs-matches;
}
