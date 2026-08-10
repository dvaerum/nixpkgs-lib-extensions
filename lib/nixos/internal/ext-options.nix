# PRIVATE (not listed in lib/default.nix). Takes the one calling convention:
# `self` is the fully assembled nixpkgs-lib-extensions lib (a fixed point),
# `lib` is nixpkgs'.
#
# The `nixpkgsLibExtensions` options namespace: the builder-derived
# per-host values (`tags`, `group`, `users`, `inputPkgs`, `channels`),
# declared as REAL module options rather than specialArgs.
# specialArgs are import-time constants -- no merging, no priorities, no
# docs, and a shadow-throw would be needed to guard every name. As
# options, `tags` MERGES contributions from several modules, the
# read-only values carry types and descriptions, and the module system
# itself rejects a module trying to redefine what only the builder can
# know. Only the true import-time values (`inputs`, `rootPath`, `extLib`)
# are specialArgs -- see internal/context.nix.
{ lib, self, ... }:
let
  inherit (lib) mkOption types;

  # One options module serves BOTH module systems (NixOS and home-manager);
  # only `hostname` differs: a NixOS module reads config.networking.hostName
  # (the builder sets it), while a home has no such option, so the home
  # variant declares `nixpkgsLibExtensions.hostname` itself.

  # The option declarations shared by both variants. `tags` is the one
  # MERGING option: the builder's `tags` argument arrives as an ordinary
  # definition (see mkConfig), so modules can contribute further tags and
  # the lists merge. Everything else is derived by the builder from its own
  # arguments and inputs -- a module redefining one would change what other
  # modules SEE without changing what the builder DID (the old
  # specialArg-shadowing split-brain), so those are readOnly.
  sharedOptions =
    {
      group,
      users,
      inputPkgs,
      channels,
    }:
    {
      tags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Free-form host tags. Seeded by the builder's `tags` argument;
          modules ADD to the list by defining this option (list
          definitions merge). The builder labels the boot menu with the
          merged value (`system.nixos.tags`, mkDefault).
        '';
      };
      group = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        default = group;
        description = ''
          The builder's `group` argument: free-form host classification
          (by default it also selects the hosts/<group>/ config folder;
          the `hostFolder` argument overrides that). Read-only -- set
          the builder argument instead.
        '';
      };
      users = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        default = users;
        description = ''
          The host's users, derived from the builder's `userRegistry`
          keys. Read-only -- the registry is the single source.
        '';
      };
      inputPkgs = mkOption {
        type = types.raw;
        readOnly = true;
        default = inputPkgs;
        description = ''
          Every input's packages pre-selected for the host's system,
          keyed by input name (e.g. `inputPkgs.disko.disko-install`).
          Read-only; deliberately not merged into `pkgs`.
        '';
      };
      channels = mkOption {
        type = types.lazyAttrsOf types.raw;
        readOnly = true;
        default = channels;
        description = ''
          The package set of every `nixpkgs-<variant>` input, keyed by
          variant (e.g. `channels.unstable` for `inputs.nixpkgs-unstable`),
          instantiated with the same overlays and config as the primary
          `pkgs`. Read-only.
        '';
      };
    };

  mkConfig = tags: {
    nixpkgsLibExtensions.tags = tags;
  };
in
{
  # The `home.stateVersion` default, shared by both home mechanisms:
  # mk-system.nix wires it into `home-manager.sharedModules` (system-managed
  # homes), mk-home.nix into the standalone module list (login-managed).
  # The value stays the CURRENT nixpkgs release -- the convenience that
  # makes a first home build work -- but a home that actually RELIES on it
  # is warned: stateVersion exists to be pinned, and a default that
  # silently tracks the moving release defeats it. Detection is by
  # definition priority (the same technique as the platform warnings in
  # mk-system.nix): any definition beating this module's mkDefault is a
  # pin, and for a pinned home neither the warning nor the default value is
  # ever evaluated -- losing mkDefault definitions are discarded by
  # priority alone, unforced. The message lands twice on purpose: as an
  # eval warning on the value (visible wherever the home is evaluated) and
  # as a `warnings` entry (testable data; NixOS and home-manager surface
  # it through their normal warning plumbing).
  homeStateVersionModule = hostname: {
    _file = ./ext-options.nix;
    imports = [
      (
        # `username` is the module ARGUMENT both mechanisms wire per home
        # (`_module.args.username`) -- NOT config.home.username, whose
        # home-manager default is itself selected by stateVersion, so
        # reading it here would be infinite recursion.
        {
          options,
          lib,
          username,
          ...
        }:
        let
          relies = options.home.stateVersion.highestPrio >= (lib.mkDefault null).priority;
          msg = "nixpkgs-lib-extensions: host `${hostname}`: the home of `${username}` does not pin `home.stateVersion`, so it follows the CURRENT nixpkgs release (now ${lib.trivial.release}) and changes meaning on every nixpkgs bump. Pin it in that user's home.nix (`home.stateVersion = \"${lib.trivial.release}\";`), or fleet-wide via an entry in the shared `homeModules` builder argument.";
        in
        {
          home.stateVersion = lib.mkDefault (lib.warn msg lib.trivial.release);
          warnings = lib.optional relies msg;
        }
      )
    ];
  };

  # The always-imported NixOS module. All values are the builder's own:
  # mk-system.nix closes over them per host.
  extNixosOptionsModule =
    {
      group,
      tags,
      users,
      inputPkgs,
      channels,
    }:
    {
      _file = ./ext-options.nix;
      options.nixpkgsLibExtensions = sharedOptions {
        inherit
          group
          users
          inputPkgs
          channels
          ;
      };
      config = mkConfig tags;
    };

  # The home-manager twin: the same namespace and values inside every home,
  # whichever mechanism built it -- mk-system.nix puts it into
  # `home-manager.sharedModules` for SYSTEM-managed homes, mk-home.nix into
  # the module list of the standalone (LOGIN) evaluation. Declares
  # `hostname` in addition: a home has no `networking.hostName` to read.
  extHomeOptionsModule =
    {
      hostname,
      group,
      tags,
      users,
      inputPkgs,
      channels,
    }:
    {
      _file = ./ext-options.nix;
      options.nixpkgsLibExtensions =
        sharedOptions {
          inherit
            group
            users
            inputPkgs
            channels
            ;
        }
        // {
          hostname = mkOption {
            type = types.str;
            readOnly = true;
            default = hostname;
            description = ''
              The host this home configuration is built for (the builder's
              `hostname` argument). Read-only. NixOS modules read
              `config.networking.hostName` instead.
            '';
          };
        };
      config = mkConfig tags;
    };
}
