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

  # Loads the import file and returns a attrubute,
  # If the value loaded is a function, when the filename
  # is used as the attribure key. If the value is an attrubute,
  # when the filename is ignored and the attribure is just returned
  import_file = folder_name: file_name:
    let
      unknown_import = import ./${folder_name}/${file_name};
      basename = lib.removeSuffix ".nix" "${file_name}";
    in
      if builtins.isAttrs unknown_import
      then unknown_import
      else if builtins.isFunction unknown_import
      then { "${basename}" = unknown_import; }
      else throw "The file `${folder_name}/${file_name}` have to either contain an attribute or a function"
  ;

  # Import each directory. Check if the folder contain default.nix,
  # if it does load its content.
  # If the folder does not contain default.nix, when it will load
  # all the .nix files in the folder
  libraries = (lib.genAttrs dirNames (folder_name:
    if (builtins.pathExists ./${folder_name}/default.nix)
    then import ./${folder_name} { inherit lib; }
    else (
      lib.mergeAttrsList
      (
        lib.forEach
        ( get_file_names ./${folder_name} )
        ( import_file folder_name )
      )
    )
  ));

  # Merge all for top-level access
  topLevel = lib.foldl' (acc: m: acc // m) {} (lib.attrValues libraries);
in
  # { attrsets = {...}; strings = {...}; <and other folders> } // { func1 = ...; func2 = ...; }
  libraries // topLevel
