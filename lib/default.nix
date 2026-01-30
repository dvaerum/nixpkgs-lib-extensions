{ lib }:
let
  # Get all directories in current folder
  entries = builtins.readDir ./.;
  dirNames = lib.attrNames (lib.filterAttrs (n: t: t == "directory") entries);

  # Import each directory
  libraries = lib.genAttrs dirNames (name: import ./${name} { inherit lib; });

  # Merge all for top-level access
  topLevel = lib.foldl' (acc: m: acc // m) {} (lib.attrValues libraries);
in
  # { attrsets = {...}; strings = {...}; <and other folders> } // { func1 = ...; func2 = ...; }
  libraries // topLevel

