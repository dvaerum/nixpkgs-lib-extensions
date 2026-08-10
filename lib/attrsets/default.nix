{
  lib,
  ...
}:

{
  /**
    Recursively merge a list of attribute sets.

    Merge strategy:
    - Single value: use as-is
    - All lists: concatenate and deduplicate
    - All attrsets: recursively merge
    - Mixed types: last value wins (rightmost)

    Note that list deduplication only fires when a key occurs in TWO or
    more of the merged sets: a key occurring in a single set is taken
    verbatim, duplicates inside its list included.

    # Type
    ```
    recursiveMerge :: [AttrSet] -> AttrSet
    ```

    # Arguments
    attrList
    : List of attribute sets to merge

    # Example
    ```nix
    recursiveMerge [
      { a = 1; b = { x = 1; }; c = [ 1 2 ]; }
      { a = 2; b = { y = 2; }; c = [ 2 3 ]; }
    ]
    => { a = 2; b = { x = 1; y = 2; }; c = [ 1 2 3 ]; }

    recursiveMerge [
      { users = { alice = { shell = "bash"; }; }; }
      { users = { bob = { shell = "zsh"; }; }; }
    ]
    => { users = { alice = { shell = "bash"; }; bob = { shell = "zsh"; }; }; }

    recursiveMerge [
      { tags = [ "web" "prod" ]; }
      { tags = [ "prod" "critical" ]; }
    ]
    => { tags = [ "web" "prod" "critical" ]; }
    ```
  */
  recursiveMerge = (
    attrList:
    let
      f = lib.zipAttrsWith (
        n: values:
        if lib.tail values == [ ] then
          lib.head values
        else if lib.all lib.isList values then
          lib.unique (lib.concatLists values)
        else if lib.all lib.isAttrs values then
          f values
        else
          lib.last values
      );
    in
    f attrList
  );
}
