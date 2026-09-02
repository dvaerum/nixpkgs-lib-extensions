# The users tree for the lib/nixos builders: matching a user's directory
# (and its `hosts/<host>` override) to a user on a host, validating those
# directories, and deriving a host's user lists. One of the concern-files
# aggregated by ./shared.nix (which documents the shared `{ lib, self, ... }`
# calling convention).
{ lib, self, ... }:
let

  # Registry values must be directories: a path literal or an absolute string
  # pointing at an existing directory.
  isDirEntry =
    entry:
    (lib.isPath entry || (lib.isString entry && lib.substring 0 1 entry == "/"))
    && lib.pathExists entry
    && builtins.readFileType entry == "directory";

  # The directories that apply for `username` on `hostname`, in merge order.
  #
  # A user is ONE directory under the users tree; there are no registry
  # keys and no key forms. The base directory applies everywhere, and its
  # `hosts/<hostname>` subdirectory -- when one exists -- merges on top,
  # host-specific config layered over the shared config. `hostname == null`
  # means a HOST-LESS home (`homeConfigurations."<user>"`): the base
  # directory alone, never descending into `hosts/`, because a host-less
  # home by definition has no host whose overrides could apply.
  #
  # A user with ONLY `hosts/<h>` subdirectories (no home.nix or
  # configuration.nix of their own) exists on those hosts and nowhere
  # else -- that is how "this user is only on this machine" is spelled.
  entryDirsFor =
    users: hostname: username:
    let
      base = users.${username} or null;
      hostDir = if base != null && hostname != null then base + "/hosts/${hostname}" else null;
      # A directory contributes only if it actually carries config. A base
      # directory that is just a container for `hosts/` (a user who exists
      # only on specific machines) contributes nothing here rather than
      # being an error -- entryFiles still throws for a directory that
      # carries neither file AND has no hosts/ reason to exist.
      carriesConfig =
        d:
        d != null
        && isDirEntry d
        && (lib.pathExists (d + "/home.nix") || lib.pathExists (d + "/configuration.nix"));
    in
    lib.filter carriesConfig [
      base
      hostDir
    ];

  # The `hosts/<hostname>` subdirectories a user's directory carries --
  # the hostnames that user has machine-specific config for. Same
  # classification rules as `discoverUserRegistry`'s own scan of the users
  # tree (see its doc comment): a subdirectory counts when it ships
  # `home.nix` and/or `configuration.nix`, a dotfile or non-directory is
  # skipped silently, and a directory with neither file warns rather than
  # being silently ignored.
  discoverHostsForUser =
    userDir:
    let
      hostsDir = userDir + "/hosts";
      entriesProbe = builtins.tryEval (
        if isDirEntry userDir && lib.pathExists hostsDir then builtins.readDir hostsDir else { }
      );
      entries = if entriesProbe.success then entriesProbe.value else { };

      # readDir reports "symlink" without following it, so a link is
      # reclassified by what it resolves to -- same rule as
      # discoverUserRegistry/discoverPatches. `toString ... + "/."`, NOT
      # `... + "/."`: the latter stays a Nix PATH value and Nix silently
      # normalizes away a trailing "/." when constructing one.
      resolvedType =
        name: rawType:
        if rawType != "symlink" then
          rawType
        else if builtins.pathExists (toString (hostsDir + "/${name}") + "/.") then
          "directory"
        else
          "regular";

      classify =
        name:
        if lib.hasPrefix "." name then
          "dotfile"
        else if resolvedType name entries.${name} != "directory" then
          "notDirectory"
        else if
          lib.pathExists (hostsDir + "/${name}/home.nix")
          || lib.pathExists (hostsDir + "/${name}/configuration.nix")
        then
          "host"
        else
          "malformed";

      classified = map (name: {
        inherit name;
        class = classify name;
      }) (builtins.attrNames entries);

      hosts = map (e: e.name) (lib.filter (e: e.class == "host") classified);
      malformed = lib.filter (e: e.class == "malformed") classified;

      warnMsg =
        e:
        "nixpkgs-lib-extensions: ${toString hostsDir}/${e.name}: a directory with neither home.nix nor configuration.nix, ignoring it as a per-host override.";
    in
    lib.foldl' (acc: e: lib.warn (warnMsg e) acc) hosts malformed;

  # `loginFlakeRef` as a STRING (not a flake input) is a deliberate escape
  # hatch for a MUTABLE ref home-manager reads LIVE at login, not the
  # immutable store copy an input gives -- see mk-nixos-system.nix's own
  # doc comment. Warned rather than rejected, and the message is exported
  # as data so tests can pin the TEXT (a warning is not observable
  # in-language, unlike a throw).
  stringFlakeRefWarning =
    hostname: ref:
    "nixpkgs-lib-extensions: host `${hostname}`: loginFlakeRef is a string (\"${ref}\"), not a flake input -- home-manager will read it LIVE at login (a mutable checkout, or whatever a remote ref currently resolves to), not the immutable store copy an input gives, and the users tree cannot be scanned from it at evaluation time either, since a raw string has no attributes to read. Intended? No action needed. Otherwise pass a flake input instead (e.g. `loginFlakeRef = inputs.self;`, the default).";

  # Validate one user directory and return its parts. Every directory that
  # counts as a user (or as a per-host override) must ship `home.nix`
  # (home-manager config) and/or `configuration.nix` (NixOS config for that
  # user: account, groups, ...).
  entryFiles =
    username: entry:
    let
      shown = toString entry;
      hasHome = lib.pathExists (entry + "/home.nix");
      hasConf = lib.pathExists (entry + "/configuration.nix");
    in
    if !(isDirEntry entry) then
      throw ''
        The users-tree directory for `${username}` must be an existing
        directory, but got: ${shown}
      ''
    else if !hasHome && !hasConf then
      throw ''
        The users-tree directory for `${username}` (${shown})
        contains neither a `home.nix` nor a `configuration.nix`.
      ''
    else
      {
        homeModule = if hasHome then entry + "/home.nix" else null;
        nixosModule = if hasConf then entry + "/configuration.nix" else null;
      };

  # Everything that applies for a user on a host, across the matched
  # directories (base, then the `hosts/<hostname>` override):
  # `homeModules` for home-manager, `nixosModules` for the system. A user
  # whose directories only ship configuration.nix is system-only
  # (homeModules == [ ]): no home output, no login bootstrap.
  # `hostname == null` resolves the host-less form -- see entryDirsFor.
  resolveUser =
    users: hostname: username:
    let
      parts = map (entryFiles username) (entryDirsFor users hostname username);
      nonNull = lib.filter (x: x != null);
    in
    {
      homeModules = nonNull (map (p: p.homeModule) parts);
      nixosModules = nonNull (map (p: p.nixosModule) parts);
    };

  # The users of a host: every user in the tree whose base directory
  # applies, plus every user who exists ONLY via a `hosts/<hostname>`
  # subdirectory for THIS host. A user with neither is not on this host.
  # Sorted and deduplicated by the attrNames round-trip.
  usersFromRegistry =
    users: hostname:
    lib.filter (
      u:
      (resolveUser users hostname u).homeModules != [ ]
      || (resolveUser users hostname u).nixosModules != [ ]
    ) (lib.attrNames users);

  # Apply a host's own `users` filter to the tree: omitted (null) means
  # every user in the tree applies -- the default -- while a list selects
  # exactly those, and `[ ]` gives a host with no users at all (what an
  # empty `userRegistry` used to say). Names that are not in the tree are
  # a typo and throw, same bar as `loginHomes`.
  filterUsers =
    fnName: hostname: selection: tree:
    if selection == null then
      tree
    else
      let
        unknown = lib.filter (u: !(tree ? ${u})) selection;
      in
      if unknown != [ ] then
        throw "${fnName}: host `${hostname}`: `users` names ${lib.concatStringsSep ", " unknown}, which is not a user in the users tree (typo?). Users in the tree: ${
          if tree == { } then "(none)" else lib.concatStringsSep ", " (lib.attrNames tree)
        }."
      else
        lib.filterAttrs (u: _: lib.elem u selection) tree;

  # The subset of the host's users (usersFromRegistry) that actually have a
  # home configuration.
  usersWithHome =
    users: hostname:
    lib.filter (u: (resolveUser users hostname u).homeModules != [ ]) (
      usersFromRegistry users hostname
    );

  # The login-managed users that actually ship a home.nix on this host:
  # `loginHomes` filtered down to usersWithHome. Exactly the set that gets
  # a "<user>@<host>" flake output (buildHomeConfigurations) and that the
  # login bootstrap activates (homeManagerBootstrapModule).
  loginUsersWithHome =
    users: hostname: loginHomes:
    lib.filter (u: lib.elem u loginHomes) (usersWithHome users hostname);

  # Every user NAME these registries mention, taken from the keys and
  # ignoring which host each key targets. Deliberately not
  # `usersFromRegistry`: a `"bob@laptop"` entry means the registry knows
  # bob, even in a call that only builds `server`. The question this
  # answers is "is this a user at all", not "does it apply here".
  # Every user NAME these user trees mention. Deliberately the union
  # across trees rather than per-host: the question this answers is "is
  # this a user at all", not "does it apply here".
  registryUserNames =
    registries:
    lib.attrNames (
      lib.listToAttrs (
        map (u: {
          name = u;
          value = null;
        }) (lib.concatMap lib.attrNames registries)
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
  # `hosts/<host>/` override directories -- are the documented way to
  # use it.
  validateLoginUsers =
    fnName: perHost:
    let
      known = registryUserNames (map ({ registry, ... }: registry) perHost);
      wanted = lib.attrNames (
        lib.listToAttrs (
          map (u: {
            name = u;
            value = null;
          }) (lib.concatLists (map ({ loginHomes, ... }: loginHomes) perHost))
        )
      );
      unknown = lib.filter (u: !(lib.elem u known)) wanted;
    in
    if unknown == [ ] then
      null
    else
      throw ''
        ${fnName}: loginHomes names ${lib.concatStringsSep ", " unknown}, which is not a user in the users tree on any host (typo?). A login user must exist there; users across all hosts: ${
          if known == [ ] then "(none)" else lib.concatStringsSep ", " known
        }.
      '';

  # The users tree for a build: `{ <username> = <directory>; }`,
  # discovered from `<ref>/users`. There is no hand-written alternative --
  # the directory tree IS the declaration -- so this is the only way a
  # user comes into existence.
  #
  # `ref` is the flake input whose `users/` directory to scan: `rootPath`
  # for a flake's own users, `loginFlakeRef` when the homes live in
  # another flake (see mk-nixos-system.nix's own doc comment). A STRING
  # ref cannot be read at evaluation time at all, so it yields no users --
  # stringFlakeRefWarning says so at the point it is passed.
  resolveUsers =
    {
      ref,
      label,
      traceDiscoveredUsers,
    }:
    # A flake input (attrset) or a path both name a real tree. A bare
    # STRING flake ref ("/etc/nixos", "git+https://...") names something
    # only resolvable at activation time, so it yields no users --
    # stringFlakeRefWarning says so where it is passed.
    if ref == null || (lib.isString ref && !(builtins.hasContext ref)) then
      { }
    else
      let
        # tryEval: `+` on an attrset with no `outPath`/`__toString` (not a
        # genuine flake input, however it got here) throws immediately --
        # before discoverUserRegistry's own guard ever sees a `dir` to
        # check. Same "an unrelated/unpredictable value must not break
        # evaluation for a caller not even using this" reasoning as
        # discoverUserRegistry's own tryEval.
        usersDirProbe = builtins.tryEval (ref + "/users");
        discovered = if usersDirProbe.success then self.discoverUserRegistry usersDirProbe.value else { };
      in
      if discovered == { } || !traceDiscoveredUsers then
        discovered
      else
        lib.trace ''
          nixpkgs-lib-extensions: ${label}: users discovered in ${toString (ref + "/users")}: ${lib.concatStringsSep ", " (lib.attrNames discovered)} -- expected? Silence with `traceDiscoveredUsers = false;`.
        '' discovered;

in
{
  inherit
    resolveUser
    usersFromRegistry
    filterUsers
    usersWithHome
    loginUsersWithHome
    validateLoginUsers
    stringFlakeRefWarning
    resolveUsers
    discoverHostsForUser
    entryDirsFor
    ;
}
