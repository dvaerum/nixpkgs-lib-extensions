# The users tree for the lib/nixos builders: matching a user's directory
# (and its `hosts/<host>` override) to a user on a host, validating those
# directories, and deriving a host's user lists. One of the concern-files
# aggregated by ./shared.nix (which documents the shared `{ lib, self, ... }`
# calling convention).
{ lib, self, ... }:
let
  inherit (import ./inputs.nix { inherit lib self; }) collectFromInputs;

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
  # classification rules as `discoverUserRegistry`'s scan of the users tree
  # (see the table in its doc comment) with ONE exception: a subdirectory
  # counts only when it ships `home.nix` and/or `configuration.nix`. In the
  # users tree a bare `hosts/` is enough to make a user; nothing makes a
  # host but those two files.
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
  # exactly those, and `[ ]` gives a host with no users at all. Names not
  # in the tree are a typo and throw, same bar as `loginHomes`.
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
  # `loginHomes` filtered down to usersWithHome: exactly the set the
  # login bootstrap activates (homeManagerBootstrapModule). NOT the set
  # that gets flake outputs -- every user with a home.nix gets one of
  # those, in or out of loginHomes.
  loginUsersWithHome =
    users: hostname: loginHomes:
    lib.filter (u: lib.elem u loginHomes) (usersWithHome users hostname);

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
  # A name is only an error when the tree does not have it at all: a name
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

  # Turn the raw `loginFlakeRef` argument into the ordered list of
  # `{ source; trusted; }` pairs `resolveUsers` scans. `rootPath` is
  # ALWAYS in that list and ALWAYS trusted -- it's your own flake, there
  # is nothing to withhold from it -- the three forms below only decide
  # what `loginFlakeRef` itself contributes:
  #
  #   null          -> nothing extra; rootPath alone (today's default).
  #   a LIST         -> rootPath PLUS every list entry -- each entry
  #                     untrusted unless wrapped
  #                     `{ source; allowNixosConfig = true; }`.
  #   anything else  -> REPLACES rootPath outright (the pre-existing
  #                     "instead of" meaning, unchanged) -- untrusted
  #                     unless wrapped the same way.
  #
  # Trust governs ONE thing: whether a source's `configuration.nix`
  # files are imported at all (mk-system.nix's `userNixosConfigs`) --
  # they run with FULL, unrestricted NixOS module authority, so a source
  # you do not fully control should not get that by default. `home.nix`
  # carries no such authority (it only ever reaches that one user's own
  # home-manager home), so trust never gates it.
  normalizeSource =
    value:
    # A wrapper `{ source; allowNixosConfig; }` is told apart from a real
    # flake-input attrset by the `source` key -- the same "detect by
    # shape, not by type" convention this library already uses for the
    # home-manager input's capability detection. A real flake exporting
    # its own top-level `source` attribute would collide with this, but
    # no standard flake output uses that name.
    if lib.isAttrs value && value ? source then
      {
        source = value.source;
        trusted = value.allowNixosConfig or false;
        isRootPath = false;
      }
    else
      {
        source = value;
        trusted = false;
        isRootPath = false;
      };

  # `isRootPath = true` marks the ONE entry that is the consumer's own
  # identity, never a foreign source -- see `scanOne`'s use of it: a
  # flake's own `rootPath` (default `inputs.self`) may ALSO happen to
  # export `nixpkgsLibExtensionsLoginContext` (for OTHER consumers'
  # benefit, e.g. home-manager-config exporting it for a THIRD flake to
  # use), and probing it here would rebuild that flake's OWN users with
  # a fresh, minimal core -- losing whatever `overlays`/
  # `allowedUnfreePackages`/`nixpkgsConfig` the ACTUAL build call passed
  # directly (a loginContext only ever carries `inputs`/`specialArgs`,
  # never those), since a login-context-sourced ctx is built from
  # scratch rather than sharing the one this build already has. Caught
  # deploying home-manager-config's own switch once it started exporting
  # this for OTHERS to consume.
  loginFlakeRefSources =
    loginFlakeRef: rootPath:
    if loginFlakeRef == null then
      [
        {
          source = rootPath;
          trusted = true;
          isRootPath = true;
        }
      ]
    else if lib.isList loginFlakeRef then
      [
        {
          source = rootPath;
          trusted = true;
          isRootPath = true;
        }
      ]
      ++ map normalizeSource loginFlakeRef
    else
      [ (normalizeSource loginFlakeRef) ];

  # The users tree for a build: `{ tree = { <username> = <directory>; };
  # untrustedUsers = [ <username> ... ]; }`, discovered from every
  # `<source>/users` in `sources` (see loginFlakeRefSources above) and
  # merged into ONE tree. There is no hand-written alternative -- the
  # directory tree IS the declaration -- so this is the only way a user
  # comes into existence.
  #
  # The SAME username discovered from more than one source is an error:
  # two trees silently deciding who wins would be exactly the ambiguity
  # this library throws on everywhere else (filterUsers' unknown-name
  # throw, hostsProblems' reserved-key throw, ...).
  resolveUsers =
    {
      sources,
      label,
      traceDiscoveredUsers,
    }:
    let
      # A source flake may export its OWN builder context -- the same
      # vocabulary `mkContext` accepts (`inputs`, `specialArgs`, ...) --
      # as a top-level flake output, `nixpkgsLibExtensionsLoginContext`.
      # Deliberately NOT nested under `nixpkgsLibExtensions.*` -- that
      # name is already the NixOS/home-manager OPTION namespace
      # (ext-options.nix), read out of a built `config`; this is a flake
      # OUTPUT, read before any core exists, and docs-integrity's
      # `ext-options-documented-in-guide` check treats every
      # `nixpkgsLibExtensions.<name>` mention in the guide as a claim
      # about a declared OPTION -- reusing the prefix here would make a
      # doc mention of this feature look like an undeclared option.
      # Detected by shape, the same "check what it exports, not what
      # it's called" convention `isNixpkgsTree`/`detectHomeManager`
      # already use (inputs.nix). A source with no such export (a plain
      # path, the common case, or a flake that simply doesn't declare
      # one) yields `null` here, which is what keeps every EXISTING
      # `loginFlakeRef` consumer unaffected. `lib.isAttrs source` first:
      # a bare path/string source cannot carry attributes at all, and
      # `?` on one throws rather than returning false. tryEval on top:
      # an attrset shaped unexpectedly (some OTHER flake's arbitrary
      # export of this name) must not break a caller not even using
      # this feature -- same reasoning as `usersDirProbe` below.
      loginContextOf =
        source:
        let
          probe = builtins.tryEval (
            if lib.isAttrs source then source.nixpkgsLibExtensionsLoginContext or null else null
          );
        in
        if probe.success then probe.value else null;

      scanOne =
        {
          source,
          trusted,
          isRootPath ? false,
        }:
        # A flake input (attrset) or a path both name a real tree. A bare
        # STRING flake ref ("/etc/nixos", "git+https://...") names
        # something only resolvable at activation time, so it yields no
        # users -- stringFlakeRefWarning says so where it is passed.
        if source == null || (lib.isString source && !(builtins.hasContext source)) then
          {
            discovered = { };
            inherit trusted;
            usersDir = null;
            loginContext = null;
          }
        else
          let
            # tryEval: `+` on an attrset with no `outPath`/`__toString`
            # (not a genuine flake input, however it got here) throws
            # immediately -- before discoverUserRegistry's own guard
            # ever sees a `dir` to check. Same "an unrelated/unpredictable
            # value must not break evaluation for a caller not even
            # using this" reasoning as discoverUserRegistry's own tryEval.
            usersDirProbe = builtins.tryEval (source + "/users");
            discovered = if usersDirProbe.success then self.discoverUserRegistry usersDirProbe.value else { };
          in
          {
            inherit discovered trusted;
            usersDir = if usersDirProbe.success then usersDirProbe.value else null;
            # `isRootPath`: never probed for a loginContext -- see
            # `loginFlakeRefSources`' own comment on that flag.
            loginContext = if isRootPath then null else loginContextOf source;
          };

      scanned = map scanOne sources;

      allNames = lib.concatMap (s: lib.attrNames s.discovered) scanned;
      duplicates = lib.unique (lib.filter (n: lib.count (m: m == n) allNames > 1) allNames);
    in
    if duplicates != [ ] then
      throw ''
        ${label}: ${lib.concatStringsSep ", " duplicates} ${
          if lib.length duplicates == 1 then "is a user" else "are users"
        } in more than one users tree (rootPath and/or a loginFlakeRef entry) -- ambiguous, pick one source per username.
      ''
    else
      let
        tree = lib.foldl' (acc: s: acc // s.discovered) { } scanned;
        untrustedUsers = lib.concatMap (s: if s.trusted then [ ] else lib.attrNames s.discovered) scanned;
        # Per-source metadata that would otherwise be lost in the `tree`
        # flatten above -- same "survives the fold as a parallel map"
        # pattern `untrustedUsers` already establishes on this line.
        userLoginContext = lib.foldl' (
          acc: s: acc // (lib.genAttrs (lib.attrNames s.discovered) (_: s.loginContext))
        ) { } scanned;
        result = {
          inherit tree untrustedUsers userLoginContext;
        };
        traceMsgs =
          if !traceDiscoveredUsers then
            [ ]
          else
            map (
              s:
              "nixpkgs-lib-extensions: ${label}: users discovered in ${toString s.usersDir}: ${lib.concatStringsSep ", " (lib.attrNames s.discovered)}${
                if s.trusted then "" else " (untrusted: configuration.nix ignored)"
              } -- expected? Silence with `traceDiscoveredUsers = false;`."
            ) (lib.filter (s: s.discovered != { } && s.usersDir != null) scanned);
      in
      lib.foldl' (acc: msg: lib.trace msg acc) result traceMsgs;

  # The loginContext (or `null`) a given user was discovered under --
  # `userLoginContext` from `resolveUsers`' result, looked up by username.
  # `null` means "no source declared one", the overwhelmingly common case
  # today, which is what keeps every existing `loginFlakeRef` consumer
  # unaffected: mk-home.nix/mk-system.nix build that user exactly as
  # before whenever this is `null`.
  loginContextForUser = userLoginContext: username: userLoginContext.${username} or null;

  # A loginContext's own auto-collected home-manager modules -- computed
  # WITHOUT building a `pkgs` (no `system`/`nixpkgs` needed): a
  # system-managed home cannot use a source's own package set anyway (see
  # mk-system.nix's `useGlobalPkgs`), so only the module-collection half
  # of `collectFromInputs` is needed here, over the loginContext's OWN
  # `inputs` -- never the consumer's.
  homeModulesFromLoginContext =
    loginContext:
    (collectFromInputs {
      inputs = loginContext.inputs;
      inputContributions = loginContext.inputContributions or { };
      baseLib = lib;
    }).collected.homeModules;

  # Splices `overrides` (a loginContext's `rootPath`/`inputs`/
  # `specialArgs`) into a module VALUE and every module it transitively
  # `imports` by PATH -- needed because a real home.nix is rarely one
  # file: home-manager-config's own users/<u>/home.nix imports a sibling
  # `imports.nix`, which is where `rootPath` is actually used, one level
  # below the file mk-system.nix calls directly. Overriding only the
  # outer call's args (a plain `(import path) (moduleArgs // overrides)`)
  # never reaches that nested file: NixOS's own module collection
  # resolves ITS args the standard way (specialArgs/`_module.args`),
  # which is exactly the shared, unoverridable channel this feature
  # exists to route around. So each PATH/function `imports` entry a
  # module returns is wrapped the same way, recursively -- an entry that
  # is already a plain attrset (no args to resolve) is left alone except
  # for recursing into ITS OWN `imports`, in case one of those is a path.
  #
  # Calling the target function directly (bypassing nixpkgs'
  # `applyModuleArgs`) must still replicate ITS per-name resolution
  # (lib/modules.nix: `args.${name} or config._module.args.${name}`) --
  # `pkgs` for a home-manager module is delivered ONLY via
  # `_module.args` (home-manager's own nixpkgs.nix module sets it there,
  # never via specialArgs), so a naive `moduleArgs // overrides` (every
  # OTHER name already present in `moduleArgs`) broke every module
  # destructuring `{ pkgs, ... }:` with "called without required
  # argument 'pkgs'" -- caught against the REAL home-manager-config
  # repo (common/user/tmux/default.nix), which no synthetic fixture in
  # this suite happened to need `pkgs` to expose.
  resolveArgsFor =
    overrides: f: moduleArgs:
    (lib.mapAttrs (name: _: moduleArgs.${name} or moduleArgs.config._module.args.${name}) (
      lib.functionArgs f
    ))
    // moduleArgs
    // overrides;

  wrapModuleWithOverrides =
    overrides: value:
    # A module reference from a REAL flake input is a STRING, not a Nix
    # Path: `entry + "/home.nix"` (entryFiles above) coerces via `+` on
    # an attrset (the input itself), which yields a string-with-context,
    # never a Path value -- `lib.isPath` alone missed this entirely, the
    # gap a synthetic path-literal-only fixture could not have caught
    # (see checks/builders/tests/login-context.nix's nested-imports
    # cycle, added after this was found against the REAL
    # home-manager-config repo). `import` accepts a string path exactly
    # like a Path value, so both resolve the same way. `import`ing a
    # path does not always yield a FUNCTION either -- a module file can
    # just be a plain attrset (`{ imports = [ ... ]; }`, no `{ ... }:`
    # wrapper) -- so that result is recursed into like any other value,
    # never called.
    if lib.isPath value || lib.isString value then
      wrapModuleWithOverrides overrides (import value)
    else if lib.isFunction value then
      moduleArgs: wrapModuleWithOverrides overrides (value (resolveArgsFor overrides value moduleArgs))
    else if lib.isAttrs value && value ? imports then
      value // { imports = map (wrapModuleWithOverrides overrides) value.imports; }
    else
      value;

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
    loginFlakeRefSources
    discoverHostsForUser
    entryDirsFor
    loginContextForUser
    homeModulesFromLoginContext
    wrapModuleWithOverrides
    ;
}
