# userRegistry machinery for the lib/nixos builders: matching entries to
# a user on a host, validating entry directories, and deriving a host's
# user lists from the registry keys. One of the four concern-files
# aggregated by ./shared.nix.
#
# Like the builder files it is a function of `extLib` — the fully
# assembled nixpkgs-lib-extensions lib.
extLib:
let
  inherit (import ./inputs.nix extLib) warn;

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
      (if fallback != null then
        warn ''
          userRegistry: the plain `${username}` entry is IGNORED on host
          `${hostname}` because `${username}@...` entries exist. Plain entries
          are standalone defaults, never merged with @-entries; import the
          directory explicitly from an @-entry if you want to reuse it.
        '' atTier
      else
        atTier)
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
  # `loginUsers` filtered down to usersWithHome. Exactly the set that gets
  # a "<user>@<host>" flake output (buildHomeConfigurations) and that the
  # login bootstrap activates (homeManagerBootstrapModule).
  loginUsersWithHome =
    userRegistry: hostname: loginUsers:
    builtins.filter (u: builtins.elem u loginUsers) (usersWithHome userRegistry hostname);
in
{
  inherit
    resolveUser
    usersFromRegistry
    usersWithHome
    loginUsersWithHome
    ;
}
