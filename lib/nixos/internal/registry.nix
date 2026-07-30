# userRegistry machinery for the lib/nixos builders: matching entries to
# a user on a host, validating entry directories, and deriving a host's
# user lists from the registry keys. One of the four concern-files
# aggregated by ./shared.nix.
#
# Like the builder files it is a function of `extLib` — the fully
# assembled nixpkgs-lib-extensions lib.
extLib:
let

  # Registry values must be directories: a path literal or an absolute string
  # pointing at an existing directory.
  isDirEntry =
    entry:
    (builtins.isPath entry || (builtins.isString entry && builtins.substring 0 1 entry == "/"))
    && builtins.pathExists entry
    && builtins.readFileType entry == "directory";

  # The registry entries that apply for `username` on `hostname`:
  # "<user>@<host>" and "<user>@*" both apply (and merge); the plain "<user>"
  # entry is a standalone default, used ONLY when no @-entry matched -- it is
  # never merged with @-entries (import it explicitly from another entry to
  # reuse it). A plain entry shadowed by @-entries triggers a warning.
  matchedEntries =
    userRegistry: hostname: username:
    let
      atTier = builtins.filter (e: e != null) [
        (userRegistry."${username}@*" or null)
        (userRegistry."${username}@${hostname}" or null)
      ];
      fallback = userRegistry.${username} or null;
    in
    if atTier != [ ] then
      (
        if fallback != null then
          builtins.warn ''
            userRegistry: the plain `${username}` entry is IGNORED on host
            `${hostname}` because `${username}@...` entries exist. Plain entries
            are standalone defaults, never merged with @-entries; import the
            directory explicitly from an @-entry if you want to reuse it.
          '' atTier
        else
          atTier
      )
    else if fallback != null then
      [ fallback ]
    else
      [ ];

  # Validate one registry entry and return its parts. Every entry must be a
  # directory shipping `home.nix` (home-manager config) and/or
  # `configuration.nix` (NixOS config for that user: account, groups, ...).
  entryFiles =
    username: entry:
    let
      shown =
        if builtins.isPath entry || builtins.isString entry then
          toString entry
        else
          "a value of type `${builtins.typeOf entry}`";
      hasHome = builtins.pathExists (entry + "/home.nix");
      hasConf = builtins.pathExists (entry + "/configuration.nix");
    in
    if !(isDirEntry entry) then
      throw ''
        The userRegistry entry for `${username}` must be an existing
        directory (as a path), but got: ${shown}
      ''
    else if !hasHome && !hasConf then
      throw ''
        The userRegistry directory for `${username}` (${shown})
        contains neither a `home.nix` nor a `configuration.nix`.
      ''
    else
      {
        homeModule = if hasHome then entry + "/home.nix" else null;
        nixosModule = if hasConf then entry + "/configuration.nix" else null;
      };

  # Everything that applies for a user on a host, across the matched entries:
  # `homeModules` for home-manager, `nixosModules` for the system. A user
  # whose matched entries only ship configuration.nix is system-only
  # (homeModules == [ ]): no home output, no login bootstrap.
  resolveUser =
    userRegistry: hostname: username:
    let
      parts = map (entryFiles username) (matchedEntries userRegistry hostname username);
      nonNull = builtins.filter (x: x != null);
    in
    {
      homeModules = nonNull (map (p: p.homeModule) parts);
      nixosModules = nonNull (map (p: p.nixosModule) parts);
    };

  # The users of a host, derived from the registry keys: "<user>@<host>" entries
  # for this host, "<user>@*" wildcard entries (every host), plus plain
  # "<user>" fallback entries (any host). Deduplicated (and sorted) via the
  # listToAttrs/attrNames round-trip.
  usersFromRegistry =
    userRegistry: hostname:
    let
      toUser =
        key:
        let
          m = builtins.match "(.*)@(.*)" key;
          host = builtins.elemAt m 1;
        in
        if m == null then
          key
        else if host == hostname || host == "*" then
          builtins.head m
        else
          null;
      names = builtins.filter (u: u != null) (map toUser (builtins.attrNames userRegistry));
    in
    builtins.attrNames (
      builtins.listToAttrs (
        map (u: {
          name = u;
          value = null;
        }) names
      )
    );

  # The subset of the host's users (usersFromRegistry) that actually have a
  # home configuration.
  usersWithHome =
    userRegistry: hostname:
    builtins.filter (u: (resolveUser userRegistry hostname u).homeModules != [ ]) (
      usersFromRegistry userRegistry hostname
    );

  # The login-managed users that actually ship a home.nix on this host:
  # `loginHomes` filtered down to usersWithHome. Exactly the set that gets
  # a "<user>@<host>" flake output (buildHomeConfigurations) and that the
  # login bootstrap activates (homeManagerBootstrapModule).
  loginUsersWithHome =
    userRegistry: hostname: loginHomes:
    builtins.filter (u: builtins.elem u loginHomes) (usersWithHome userRegistry hostname);

  # Every user NAME these registries mention, taken from the keys and
  # ignoring which host each key targets. Deliberately not
  # `usersFromRegistry`: a `"bob@laptop"` entry means the registry knows
  # bob, even in a call that only builds `server`. The question this
  # answers is "is this a user at all", not "does it apply here".
  registryUserNames =
    registries:
    builtins.attrNames (
      builtins.listToAttrs (
        map
          (u: {
            name = u;
            value = null;
          })
          (
            builtins.concatMap (
              r:
              map (
                key:
                let
                  m = builtins.match "(.*)@(.*)" key;
                in
                if m == null then key else builtins.head m
              ) (builtins.attrNames r)
            ) registries
          )
      )
    );

  # `loginHomes` was the only name surface in this library that matched
  # SILENTLY: every other unknown name throws. A typo there does not fail,
  # it flips the user's home to the OPPOSITE mechanism -- no flake output,
  # silently system-managed, and the system still builds and boots, so
  # nothing ever tells you.
  #
  # A name is only an error when NO registry mentions it at all: a name
  # that simply does not apply to a given host stays legal, because one
  # shared `loginHomes` in `_defaults` across a fleet -- and per-host
  # `"<user>@<host>"` keys -- are the documented way to use it.
  validateLoginUsers =
    fnName: perHost:
    let
      known = registryUserNames (map ({ registry, ... }: registry) perHost);
      wanted = builtins.attrNames (
        builtins.listToAttrs (
          map (u: {
            name = u;
            value = null;
          }) (builtins.concatLists (map ({ loginHomes, ... }: loginHomes) perHost))
        )
      );
      unknown = builtins.filter (u: !(builtins.elem u known)) wanted;
    in
    if unknown == [ ] then
      null
    else
      throw ''
        ${fnName}: loginHomes names ${builtins.concatStringsSep ", " unknown}, which is not a userRegistry user on any host (typo?). A login user must exist in the registry; registry users across all hosts: ${
          if known == [ ] then "(none)" else builtins.concatStringsSep ", " known
        }.
      '';
in
{
  inherit
    resolveUser
    usersFromRegistry
    usersWithHome
    loginUsersWithHome
    validateLoginUsers
    ;
}
