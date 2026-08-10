{
  lib,
  ...
}:

{
  /**
    Capitalize the first character of a string, leaving the rest as it
    was.

    Deliberately NOT nixpkgs' `lib.toSentenceCase`, which upper-cases the
    first character and LOWER-cases everything after it: this function
    preserves the tail, so casing that carries meaning survives --
    `stringToTitle "fooBar"` is `"FooBar"` where `toSentenceCase` gives
    `"Foobar"`. For a string that is already all lowercase the two agree.

    # Type
    ```
    stringToTitle :: String -> String
    ```

    # Arguments
    text
    : The input string to capitalize

    # Example
    ```nix
    stringToTitle "hello world"
    => "Hello world"

    stringToTitle "fooBar"
    => "FooBar"

    stringToTitle ""
    => ""
    ```
  */
  stringToTitle = (
    text:
    let
      firstChar = lib.substring 0 1 text;
      theRest = lib.substring 1 (lib.stringLength text) text;
      result = (lib.toUpper firstChar) + theRest;
    in
    result
  );
}
