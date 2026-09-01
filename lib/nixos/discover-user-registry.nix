# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ lib, ... }:
{
  /**
    Auto-discover a `userRegistry` from a `users/` directory: one
    `"<name>@*"` entry per subdirectory that looks like a registry entry.
    You will usually NOT call this directly -- `mkNixosSystem`'s own
    `userRegistry` argument already does this automatically when it is
    omitted and `loginFlakeRef` names a flake input (see its doc comment).
    Call it yourself only for something that convention cannot do: scanning
    a differently-named directory, or filtering/extending the result before
    use (`discoverUserRegistry dir // { "extra@*" = ./local-user; }`).

    | Entry in `dir`                                          | Effect |
    | -------------------------------------------------------- | ------ |
    | subdirectory with `home.nix` and/or `configuration.nix`   | becomes `"<name>@*" = <path>;` |
    | subdirectory with NEITHER file                            | ignored, WITH a warning naming the directory -- a scan guessed wrong, so it degrades to a warning rather than the throw a hand-written registry entry with the same problem gets |
    | a dotfile or dot-directory (`.gitkeep`, `.git`, ...)      | ignored, no warning |
    | anything else (a plain file, `README.md`, ...)            | ignored, no warning -- only a directory could ever be a registry entry, so a stray file is not a mistake worth flagging |

    A symlink is resolved and classified by what it points at, same rule as
    `discoverPatches`/`importIfNixOr`. A missing `dir` is not an error: it
    is treated the same as an empty one (`{ }`) -- most flakes have no
    `users/` directory at all. Likewise if `dir` cannot be read under pure
    evaluation at all (`mkNixosSystem`'s auto-discovery -- see its own doc
    comment -- calls this on whatever `loginFlakeRef`/`inputs.self` happens
    to be, even for a caller who never set either up for this).

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.discoverUserRegistry (inputs.home-manager-config + "/users")
    => { "dennis@*" = <path to .../users/dennis>; "root@*" = <path to .../users/root>; }
    ```

    # Type

    ```
    discoverUserRegistry :: Path -> Attribute
    ```

    # Arguments

    dir
    : The users directory to scan. Non-existent is treated as empty, not an error.
  */
  discoverUserRegistry =
    dir:
    let
      # tryEval, not a bare pathExists guard: `dir` can be a CONTEXT-FREE
      # string (e.g. built from a mock/foreign flake-ref-like value whose
      # `outPath` isn't a real flake input's), which pure evaluation
      # refuses to even STAT, throwing before pathExists returns a plain
      # `false` -- same "a foreign, unpredictable value must not break
      # unrelated evaluation" reasoning as inputs.nix's `libOf`. Caught by
      # actually hitting it (mkNixosSystem's auto-discovery trigger calls
      # this on whatever loginFlakeRef/inputs.self happens to be, even for
      # callers who never set either up for this), not assumed safe.
      entriesProbe = builtins.tryEval (if lib.pathExists dir then builtins.readDir dir else { });
      entries = if entriesProbe.success then entriesProbe.value else { };

      # Same symlink-resolution rule as discoverPatches/importIfNixOr:
      # readDir reports "symlink" without following it, so a link is
      # reclassified by what it resolves to. `toString ... + "/."`, NOT
      # `... + "/."`: the latter stays a Nix PATH value, and Nix silently
      # normalizes away a trailing "/." when constructing one.
      resolvedType =
        name: rawType:
        if rawType != "symlink" then
          rawType
        else if builtins.pathExists (toString (dir + "/${name}") + "/.") then
          "directory"
        else
          "regular";

      classify =
        name:
        if lib.hasPrefix "." name then
          "dotfile"
        else if resolvedType name entries.${name} != "directory" then
          "notDirectory"
        else
          let
            entryDir = dir + "/${name}";
          in
          if lib.pathExists (entryDir + "/home.nix") || lib.pathExists (entryDir + "/configuration.nix") then
            "user"
          else
            "malformed";

      classified = map (name: {
        inherit name;
        class = classify name;
      }) (builtins.attrNames entries);

      users = lib.filter (e: e.class == "user") classified;
      malformed = lib.filter (e: e.class == "malformed") classified;

      registry = lib.listToAttrs (
        map (e: {
          name = "${e.name}@*";
          value = dir + "/${e.name}";
        }) users
      );

      warnMsg =
        e:
        "nixpkgs-lib-extensions: discoverUserRegistry ${toString dir}/${e.name}: a directory with neither home.nix nor configuration.nix, ignoring it as a registry entry.";
    in
    lib.foldl' (acc: e: lib.warn (warnMsg e) acc) registry malformed;
}
