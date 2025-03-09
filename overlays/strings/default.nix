{ lib
, ...
}:

{
  stringToTitle = (text:
    let
      firstChar = lib.substring 0 1 text;
      theRest = lib.substring 1 (builtins.stringLength text) text;
      result = (lib.toUpper firstChar) + theRest;
    in result
  );
}
