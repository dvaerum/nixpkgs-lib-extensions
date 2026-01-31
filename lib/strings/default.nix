{ lib
, ...
}:

{
  /**
    Capitalize the first character of a string.

    # Type
    stringToTitle :: String -> String

    # Arguments
    text
    : The input string to capitalize

    # Example
    ```nix
    stringToTitle "hello world"
    => "Hello world"

    stringToTitle "foobar"
    => "Foobar"

    stringToTitle ""
    => ""
    ```
  */
  stringToTitle = (text:
    let
      firstChar = lib.substring 0 1 text;
      theRest = lib.substring 1 (builtins.stringLength text) text;
      result = (lib.toUpper firstChar) + theRest;
    in result
  );
}
