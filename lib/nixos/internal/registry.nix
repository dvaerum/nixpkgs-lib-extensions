# userRegistry machinery for the lib/nixos builders: matching entries to
# a user on a host, validating entry directories, and deriving a host's
# user lists from the registry keys. One of the concern-files
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

  # The registry entries that apply for `username` on `hostname`:
  # "<user>@<host>" and "<user>@*" both apply (and merge); the plain "<user>"
  # entry is a standalone default, used ONLY when no @-entry matched -- it is
  # never merged with @-entries (import it explicitly from another entry to
  # reuse it). A plain entry shadowed by @-entries triggers a warning.
  #
  # A "<user>@*" entry ALSO auto-detects a `hosts/<hostname>` subdirectory
  # and merges it in like an explicit "<user>@<hostname>" entry would --
  # see `mkNixosSystem`'s doc comment (`docs/lib.md`, `userRegistry`) for
  # the full convention and the ambiguous-entry throw. Scoped to "@*"
  # only: a plain "<user>" entry's directory is never auto-scanned,
  # consistent with plain entries never merging with anything else
  # (unlike the plain-vs-@ shadowing above, which has one simple,
  # predictable winner, the folder-vs-explicit-key clash throws instead
  # of picking one).
  matchedEntries =
    userRegistry: hostname: username:
    let
      wildcardEntry = userRegistry."${username}@*" or null;
      explicitHostEntry = userRegistry."${username}@${hostname}" or null;
      autoHostDir =
        if wildcardEntry != null && isDirEntry wildcardEntry then
          wildcardEntry + "/hosts/${hostname}"
        else
          null;
      autoHostEntry = if autoHostDir != null && isDirEntry autoHostDir then autoHostDir else null;
      hostEntry =
        if explicitHostEntry != null && autoHostEntry != null then
          throw ''
            userRegistry: `${username}@${hostname}` is ambiguous -- both an explicit registry entry (${toString explicitHostEntry}) and an auto-detected `hosts/${hostname}` folder under the `${username}@*` entry (${toString autoHostEntry}) claim it. Remove one: delete the explicit `"${username}@${hostname}"` key to use the auto-detected folder, or delete/rename the `hosts/${hostname}` folder to use the explicit entry.
          ''
        else if explicitHostEntry != null then
          explicitHostEntry
        else
          autoHostEntry;
      atTier = lib.filter (e: e != null) [
        wildcardEntry
        hostEntry
      ];
      fallback = userRegistry.${username} or null;
    in
    if atTier != [ ] then
      (
        if fallback != null then
          lib.warn ''
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

  # An absolute path STRING still works as a registry entry, but a
  # CONTEXT-FREE one (hand-typed: `"/home/me/users/alice"`) is a pure-eval
  # hazard: unlike a path VALUE it is never copied into the store, so it
  # escapes the flake -- the build depends on whatever happens to sit at
  # that filesystem location, and pure evaluation (`nix flake check`, CI)
  # refuses to read it outright.
  #
  # A string built by concatenating onto a flake INPUT
  # (`inputs.foo + "/users/alice"`) is NOT the same hazard, despite also
  # being a string: Nix strings can carry "context" -- an invisible record
  # of which store paths they reference -- and `+` onto an input inherits
  # it. Confirmed empirically, not assumed: `builtins.hasContext` is true
  # for the concatenated form and false for a hand-typed one, and
  # `readDir`/`pathExists`/`readFile` all work on the concatenated form
  # under PURE evaluation (no `--impure`). An earlier version of this
  # comment (and this library's own docs) claimed the concatenated form
  # "fails under pure evaluation" and had "no fix on this side of the
  # boundary" -- that was wrong, caught by testing the actual claim rather
  # than trusting it. Only the context-free lane still warns.
  #
  # Warned, not thrown; message exported as data so the tests can pin the
  # TEXT (a warning is not observable in-language, unlike a throw).
  stringPathEntryWarning =
    username: entry:
    "nixpkgs-lib-extensions: the userRegistry entry for `${username}` is an absolute path STRING with no store context (${entry}). Such a string is never copied into the flake's store copy, so it escapes the flake and pure evaluation (`nix flake check`, CI) refuses to read it. Write a path value instead (e.g. `./users/${username}`) -- or, if this directory lives in ANOTHER flake input, concatenate onto the input directly (`inputs.foo + \"/users/${username}\"`): unlike a hand-typed string, that produces a string WITH context (store-pinned, pure-eval-safe), which this library accepts without warning.";

  # `loginFlakeRef` as a STRING (not a flake input) is a deliberate escape
  # hatch for a MUTABLE ref home-manager reads LIVE at login, not the
  # immutable store copy an input gives -- see mk-nixos-system.nix's own
  # doc comment. Warned, same "warn, don't remove" treatment as
  # stringPathEntryWarning above, and for the same reason: message
  # exported as data so tests can pin the TEXT.
  stringFlakeRefWarning =
    hostname: ref:
    "nixpkgs-lib-extensions: host `${hostname}`: loginFlakeRef is a string (\"${ref}\"), not a flake input -- home-manager will read it LIVE at login (a mutable checkout, or whatever a remote ref currently resolves to), not the immutable store copy an input gives, and userRegistry auto-discovery (see its own doc comment) never applies to it either, since a raw string has no attributes to read. Intended? No action needed. Otherwise pass a flake input instead (e.g. `loginFlakeRef = inputs.self;`, the default).";

  # Validate one registry entry and return its parts. Every entry must be a
  # directory shipping `home.nix` (home-manager config) and/or
  # `configuration.nix` (NixOS config for that user: account, groups, ...).
  entryFiles =
    username: entry:
    let
      shown =
        if lib.isPath entry || lib.isString entry then
          toString entry
        else
          "a value of type `${builtins.typeOf entry}`";
      hasHome = lib.pathExists (entry + "/home.nix");
      hasConf = lib.pathExists (entry + "/configuration.nix");
      # Only a CONTEXT-FREE string warns -- see stringPathEntryWarning's
      # own comment for why a context-carrying one (from concatenating
      # onto a flake input) is not the hazard this guards against.
      warnStringEntry =
        parts:
        if lib.isString entry && !(builtins.hasContext entry) then
          lib.warn (stringPathEntryWarning username entry) parts
        else
          parts;
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
      warnStringEntry {
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
      nonNull = lib.filter (x: x != null);
    in
    {
      homeModules = nonNull (map (p: p.homeModule) parts);
      nixosModules = nonNull (map (p: p.nixosModule) parts);
    };

  # A registry key that can never match anything, or that names an empty
  # user. `usersFromRegistry` drops `"alice@"` (its host part matches no
  # host and not `*`) while `registryUserNames` keeps `alice` -- so the two
  # parsers disagreed and `loginHomes = [ "alice" ]` passed validation for a
  # user no host had. `"@laptop"` is the mirror image: it produced a real
  # account named "" , a group named "", and a ZFS dataset `HOME/`.
  badRegistryKey =
    key:
    let
      m = builtins.match "(.*)@(.*)" key;
    in
    if key == "" then
      "the empty string is not a user name"
    else if m == null then
      null
    else if lib.head m == "" then
      "it has no user before the `@`"
    else if lib.elemAt m 1 == "" then
      "it has no host after the `@` (write `${lib.head m}` for every host, or `${lib.head m}@*`)"
    else
      null;

  validateRegistryKeys =
    fnName: registries:
    let
      problems = lib.concatLists (
        map (
          r:
          lib.concatLists (
            map (
              key:
              let
                bad = badRegistryKey key;
              in
              if bad == null then [ ] else [ "- `${key}`: ${bad}." ]
            ) (lib.attrNames r)
          )
        ) registries
      );
    in
    if problems == [ ] then
      null
    else
      throw ''
        ${fnName}: unusable userRegistry key(s):
        ${lib.concatStringsSep "
" problems}
      '';

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
          host = lib.elemAt m 1;
        in
        if m == null then
          key
        else if host == hostname || host == "*" then
          lib.head m
        else
          null;
      names = lib.filter (u: u != null) (map toUser (lib.attrNames userRegistry));
    in
    lib.attrNames (
      lib.listToAttrs (
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
    lib.filter (u: (resolveUser userRegistry hostname u).homeModules != [ ]) (
      usersFromRegistry userRegistry hostname
    );

  # The login-managed users that actually ship a home.nix on this host:
  # `loginHomes` filtered down to usersWithHome. Exactly the set that gets
  # a "<user>@<host>" flake output (buildHomeConfigurations) and that the
  # login bootstrap activates (homeManagerBootstrapModule).
  loginUsersWithHome =
    userRegistry: hostname: loginHomes:
    lib.filter (u: lib.elem u loginHomes) (usersWithHome userRegistry hostname);

  # Every user NAME these registries mention, taken from the keys and
  # ignoring which host each key targets. Deliberately not
  # `usersFromRegistry`: a `"bob@laptop"` entry means the registry knows
  # bob, even in a call that only builds `server`. The question this
  # answers is "is this a user at all", not "does it apply here".
  registryUserNames =
    registries:
    lib.attrNames (
      lib.listToAttrs (
        map
          (u: {
            name = u;
            value = null;
          })
          (
            lib.concatMap (
              r:
              map (
                key:
                let
                  m = builtins.match "(.*)@(.*)" key;
                in
                if m == null then key else lib.head m
              ) (lib.attrNames r)
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
        ${fnName}: loginHomes names ${lib.concatStringsSep ", " unknown}, which is not a userRegistry user on any host (typo?). A login user must exist in the registry; registry users across all hosts: ${
          if known == [ ] then "(none)" else lib.concatStringsSep ", " known
        }.
      '';

  # The EFFECTIVE userRegistry for one host: the caller's own value if
  # `userRegistry` was given at all (even `null`/`{ }`, both documented as
  # "no users"), or an auto-discovered one -- via self.discoverUserRegistry
  # -- when it was OMITTED ENTIRELY and `loginFlakeRef` resolves to a flake
  # input (an attrset). A bare flake-ref STRING (`"/etc/nixos"`,
  # `"git+https://..."`) cannot be read at eval time at all -- see
  # `loginFlakeRef`'s own doc comment -- so those setups keep writing
  # `userRegistry` by hand, same as before this existed.
  #
  # `wasGiven`: whether the CALLER's own argument attrset included the
  # `userRegistry` key at all. `?`-shorthand defaulting cannot distinguish
  # "omitted" from "explicitly passed the same value the default would
  # be" (both `null` and `{ }` are already claimed as documented
  # "disabled" values, so neither can double as a NEW "omitted" sentinel);
  # every call site instead passes `args ? userRegistry` (mk-system.nix,
  # mk-home.nix) or its hosts-attrset equivalent (hosts-args.nix).
  #
  # Called from THREE sites for one host with login-managed homes
  # (hosts-args.nix's plan, mk-system.nix's own registry, and once per
  # login-managed user from mk-home.nix) -- a pure function of the same
  # inputs each time, so the RESULT never disagrees between them, but the
  # adoption trace below can fire more than once per host as a result
  # (accepted: `traceDiscoveredUsers` is about surfacing adoption, not
  # deduplicating a side effect Nix gives no way to deduplicate across
  # independently-forced call sites).
  resolveUserRegistry =
    {
      wasGiven,
      userRegistry,
      inputs,
      loginFlakeRef,
      hostname,
      traceDiscoveredUsers,
    }:
    if wasGiven then
      (if userRegistry == null then { } else userRegistry)
    else
      let
        # Same defaulting as home-manager-bootstrap-module.nix's
        # effectiveFlakeRef -- duplicated rather than shared, because that
        # module's own argument shape is its public contract and this
        # needs the resolved value a layer earlier, before the registry
        # that module reads even exists.
        effectiveLoginFlakeRef = if loginFlakeRef != null then loginFlakeRef else (inputs.self or null);
      in
      if !(lib.isAttrs effectiveLoginFlakeRef) then
        { }
      else
        let
          # tryEval: `+` on an attrset with no `outPath`/`__toString` (not
          # a genuine flake input, however it got here) throws immediately
          # -- before discoverUserRegistry's own guard ever sees a `dir`
          # to check. Same "an unrelated/unpredictable value must not
          # break evaluation for a caller not even using this feature"
          # reasoning as discoverUserRegistry's own tryEval.
          usersDirProbe = builtins.tryEval (effectiveLoginFlakeRef + "/users");
          discovered = if usersDirProbe.success then self.discoverUserRegistry usersDirProbe.value else { };
        in
        if discovered == { } || !traceDiscoveredUsers then
          discovered
        else
          lib.trace ''
            nixpkgs-lib-extensions: host `${hostname}`: userRegistry auto-discovered from ${
              toString (effectiveLoginFlakeRef + "/users")
            }: ${lib.concatStringsSep ", " (map (lib.removeSuffix "@*") (lib.attrNames discovered))} -- expected? Silence with `traceDiscoveredUsers = false;` (a builder argument, goes where `system`/`patches` do). Unexpected? Set `userRegistry = { };` to disable discovery.
          '' discovered;
in
{
  inherit
    resolveUser
    usersFromRegistry
    usersWithHome
    loginUsersWithHome
    validateLoginUsers
    validateRegistryKeys
    stringPathEntryWarning
    stringFlakeRefWarning
    resolveUserRegistry
    ;
}
