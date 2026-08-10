# PRIVATE (not listed in lib/default.nix). Takes the one calling convention:
# `self` is the fully assembled nixpkgs-lib-extensions lib (a fixed point),
# `lib` is nixpkgs'.
#
# The `nixpkgsLibExtensions` options namespace: the builder-derived values
# modules used to receive as specialArgs (`tags`, `hostGroup`,
# `listOfUsernames`, `inputPkgs`) declared as REAL module options instead.
# specialArgs are import-time constants -- no merging, no priorities, no
# docs, and a shadow-throw was needed to guard every name. As options,
# `tags` MERGES contributions from several modules, the read-only values
# carry types and descriptions, and the module system itself rejects a
# module trying to redefine what only the builder can know. Only the true
# import-time values (`inputs`, `rootPath`, `extLib`, the legacy `pkgs-*`
# variants) remain specialArgs -- see internal/context.nix.
#
# The REMOVED specialArgs do not disappear silently: `_module.args`
# fallbacks throw with the replacement path, so a module still reading
# `{ tags, ... }` fails naming `config.nixpkgsLibExtensions.tags` instead
# of dying with "called with unexpected argument".
{ lib, self, ... }:
let
  inherit (lib) mkOption types;

  # One options module serves BOTH module systems (NixOS and home-manager);
  # only `hostname` differs: a NixOS module reads config.networking.hostName
  # (the builder sets it), while a home has no such option, so the home
  # variant declares `nixpkgsLibExtensions.hostname` itself.
  movedNixosSpecialArgs = {
    hostname = "config.networking.hostName";
    tags = "config.nixpkgsLibExtensions.tags";
    hostGroup = "config.nixpkgsLibExtensions.hostGroup";
    listOfUsernames = "config.nixpkgsLibExtensions.users";
    inputPkgs = "config.nixpkgsLibExtensions.inputPkgs";
  };
  movedHomeSpecialArgs = movedNixosSpecialArgs // {
    hostname = "config.nixpkgsLibExtensions.hostname";
  };

  # The tombstone text, exported as data so the tests can assert the
  # MESSAGE (a throw's text is not recoverable through tryEval).
  movedSpecialArgMessage =
    name: replacement:
    "nixpkgs-lib-extensions: `${name}` is no longer a specialArg (module argument); read `${replacement}` instead.";

  # The option declarations shared by both variants. `tags` is the one
  # MERGING option: the builder's `tags` argument arrives as an ordinary
  # definition (see mkConfig), so modules can contribute further tags and
  # the lists merge. Everything else is derived by the builder from its own
  # arguments and inputs -- a module redefining one would change what other
  # modules SEE without changing what the builder DID (the old
  # specialArg-shadowing split-brain), so those are readOnly.
  sharedOptions =
    {
      hostGroup,
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
      hostGroup = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        default = hostGroup;
        description = ''
          The builder's `hostGroup` argument: free-form host
          classification (also selects the hosts/<hostGroup>/ config
          folder). Read-only -- set the builder argument instead.
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
          `pkgs`. The canonical home of what the legacy `pkgs-<variant>`
          specialArgs expose. Read-only.
        '';
      };
    };

  mkConfig = moved: tags: {
    nixpkgsLibExtensions.tags = tags;
    # tombstones for the moved specialArgs: `_module.args` is consulted only
    # when a name is NOT a specialArg, so after the move a module still
    # destructuring `{ tags, ... }` reaches these throws -- a pointer to the
    # replacement instead of a bare "unexpected argument" error.
    _module.args = builtins.mapAttrs (
      name: replacement: throw (movedSpecialArgMessage name replacement)
    ) moved;
  };
in
{
  inherit movedNixosSpecialArgs movedHomeSpecialArgs movedSpecialArgMessage;

  # The always-imported NixOS module. All values are the builder's own:
  # mk-system.nix closes over them per host.
  extNixosOptionsModule =
    {
      hostGroup,
      tags,
      users,
      inputPkgs,
      channels,
    }:
    {
      _file = ./ext-options.nix;
      options.nixpkgsLibExtensions = sharedOptions {
        inherit
          hostGroup
          users
          inputPkgs
          channels
          ;
      };
      config = mkConfig movedNixosSpecialArgs tags;
    };

  # The home-manager twin: the same namespace and values inside every home,
  # whichever mechanism built it -- mk-system.nix puts it into
  # `home-manager.sharedModules` for SYSTEM-managed homes, mk-home.nix into
  # the module list of the standalone (LOGIN) evaluation. Declares
  # `hostname` in addition: a home has no `networking.hostName` to read.
  extHomeOptionsModule =
    {
      hostname,
      hostGroup,
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
            hostGroup
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
      config = mkConfig movedHomeSpecialArgs tags;
    };
}
