# attrsets {#sec-functions-library-attrsets}


## `lib.attrsets.recursiveMerge` {#lib.attrsets.recursiveMerge}

Recursively merge a list of attribute sets.

Merge strategy:
- Single value: use as-is
- All lists: concatenate and deduplicate
- All attrsets: recursively merge
- Mixed types: last value wins (rightmost)

### Type
recursiveMerge :: [AttrSet] -> AttrSet

### Arguments
attrList
: List of attribute sets to merge

### Example
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


# strings {#sec-functions-library-strings}


## `lib.strings.stringToTitle` {#lib.strings.stringToTitle}

Capitalize the first character of a string.

### Type
stringToTitle :: String -> String

### Arguments
text
: The input string to capitalize

### Example
```nix
stringToTitle "hello world"
=> "Hello world"

stringToTitle "foobar"
=> "Foobar"

stringToTitle ""
=> ""
```


