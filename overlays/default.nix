final: prev: let

  attrsets_default = import ./attrsets { inherit (prev) lib; };
  strings_default = import ./strings { inherit (prev) lib; };

in {
  lib = prev.lib.recursiveUpdate prev.lib {
    attrsets = attrsets_default;
    strings = strings_default;
  } // attrsets_default // strings_default;
}
