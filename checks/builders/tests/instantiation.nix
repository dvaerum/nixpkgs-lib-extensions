# Full instantiation: force the derivations, not just option reads.
{
  lib,
  myLib,
  inputs,
  system,
  laptop,
  server,
  aliceHome,
  exampleDir,
  ...
}:
{
  # instantiating the full system forces NixOS assertions/warnings that
  # option-level reads skip
  laptop-toplevel-instantiates = builtins.isString laptop.config.system.build.toplevel.drvPath;
  server-toplevel-instantiates = builtins.isString server.config.system.build.toplevel.drvPath;
  # proves the home configuration can actually produce its activation
  # package, not just evaluate options
  alice-home-activation-instantiates = builtins.isString aliceHome.activationPackage.drvPath;

  # ROUTE PARITY: mk-system has two evaluation routes -- lib.nixosSystem
  # for an unpatched nixpkgs flake, and eval-config imported from the
  # selected tree otherwise (patched trees, or a nixpkgs input exposing no
  # lib.nixosSystem). Both must produce the SAME system. Route B is forced
  # on an UNPATCHED tree by handing the builder a nixpkgs whose lib lacks
  # nixosSystem (same outPath, same lib otherwise), so the only difference
  # between the two builds is the route taken -- and the toplevel drvPaths
  # must be identical.
  eval-routes-agree =
    let
      mkRoute =
        nixpkgs:
        (myLib.mkNixosSystem {
          inherit inputs system nixpkgs;
          hostname = "routeparity";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        }).config.system.build.toplevel.drvPath;
      noNixosSystem = inputs.nixpkgs // {
        lib = builtins.removeAttrs inputs.nixpkgs.lib [ "nixosSystem" ];
      };
    in
    mkRoute inputs.nixpkgs == mkRoute noNixosSystem;

  # `nixpkgs.lib` must be nixpkgs' OWN library, not merely something that
  # LOOKS like a nixpkgs tree by isNixpkgsTree's capability check -- see
  # context.nix's `baseLib` comment (mkContextCore) for the nixos-raspberrypi
  # incident this guards against and why the failure used to be so opaque.
  nixpkgs-lib-not-real-throws =
    let
      narrowLibNixpkgs = inputs.nixpkgs // {
        # mimics nixos-raspberrypi's own lib shape: makeExtensible gives it
        # `.extend`, but none of the actual standard-library functions
        lib = lib.makeExtensible (_: {
          someVendorHelper = 1;
        });
      };
    in
    !(builtins.tryEval (
      (myLib.mkNixosSystem {
        inherit inputs system;
        nixpkgs = narrowLibNixpkgs;
        hostname = "narrowlibthrow";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      }).config.system.build.toplevel.drvPath
    )).success;
  # ... and the same for a `nixpkgs` with no `lib` at all
  nixpkgs-lib-missing-throws =
    let
      noLibNixpkgs = builtins.removeAttrs inputs.nixpkgs [ "lib" ];
    in
    !(builtins.tryEval (
      (myLib.mkNixosSystem {
        inherit inputs system;
        nixpkgs = noLibNixpkgs;
        hostname = "nolibthrow";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      }).config.system.build.toplevel.drvPath
    )).success;
}
