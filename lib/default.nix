{ lib, ... }:
let
  # Get all directories in current folder
  entries = builtins.readDir ./.;
  dirNames = lib.attrNames (lib.filterAttrs (n: t: t == "directory") entries);

  # Get all .nix files from the folder
  get_file_names = (folder:
    lib.attrNames
    (lib.filterAttrs (filename: type: lib.hasSuffix ".nix" "${filename}" && type == "regular")
    (builtins.readDir folder))
  );

  # Loads an import file and returns its attribute set.
  #
  # If the file evaluates to an attribute set it is returned as-is.
  # If it evaluates to a function it is applied to `self` — the fully assembled
  # extension lib (a fixed point) — so a file can reference sibling extensions
  # without taking them as a flake input. Such a function must return an
  # attribute set, and must not force `self` while being applied (only inside the
  # bodies it returns), otherwise the fixed point would not terminate.
  import_file = self: folder_name: file_name:
    let
      unknown_import = import ./${folder_name}/${file_name};
    in
      if builtins.isFunction unknown_import
      then unknown_import self
      else if builtins.isAttrs unknown_import
      then unknown_import
      else throw "The file `${folder_name}/${file_name}` has to contain either an attribute set or a function"
  ;

in
  # Tie the knot: `self` is the merged result, so the function-files loaded by
  # `import_file` can reference any sibling extension through it.
  lib.fix (self:
    let
      # Import each directory. Check if the folder contains default.nix,
      # if it does load its content.
      # If the folder does not contain default.nix, then it will load
      # all the .nix files in the folder.
      libraries = (lib.genAttrs dirNames (folder_name:
        if (builtins.pathExists ./${folder_name}/default.nix)
        then import ./${folder_name} { inherit lib; }
        else (
          lib.mergeAttrsList
          (
            lib.forEach
            ( get_file_names ./${folder_name} )
            ( import_file self folder_name )
          )
        )
      ));

      # Merge all for top-level access
      topLevel = lib.foldl' (acc: m: acc // m) {} (lib.attrValues libraries);
    in
      # { attrsets = {...}; strings = {...}; <and other folders> } // { func1 = ...; func2 = ...; }
      libraries // topLevel
  )
