# Unit tests for the plain library functions (lib/strings, lib/attrsets,
# lib/imports). The cases mirror the Example sections of the functions' doc
# comments, so the documented behavior is the tested behavior.
{
  pkgs,
  nixpkgs,
  myLib,
}:
let
  lib = pkgs.lib;

  # the importIfNix*/readIfPlain* validity probes are IFD (built during
  # evaluation), so they are pinned to x86_64-linux here -- like the other
  # IFD steps -- to keep cross-system EVALUATION of this check buildable
  # on the test machine
  importIfNix = myLib.importIfNix nixpkgs.legacyPackages."x86_64-linux";
  importIfNixOr = myLib.importIfNixOr nixpkgs.legacyPackages."x86_64-linux";
  readIfPlain = myLib.readIfPlain nixpkgs.legacyPackages."x86_64-linux";
  readIfPlainOr = myLib.readIfPlainOr nixpkgs.legacyPackages."x86_64-linux";

  assertions = {
    string-to-title-sentence = myLib.stringToTitle "hello world" == "Hello world";
    string-to-title-word = myLib.stringToTitle "foobar" == "Foobar";
    string-to-title-empty = myLib.stringToTitle "" == "";
    # the documented difference from nixpkgs' toSentenceCase: the tail is
    # preserved, not lower-cased
    string-to-title-tail-preserved = myLib.stringToTitle "fooBar" == "FooBar";

    recursive-merge-mixed =
      myLib.recursiveMerge [
        {
          a = 1;
          b = {
            x = 1;
          };
          c = [
            1
            2
          ];
        }
        {
          a = 2;
          b = {
            y = 2;
          };
          c = [
            2
            3
          ];
        }
      ] == {
        a = 2;
        b = {
          x = 1;
          y = 2;
        };
        c = [
          1
          2
          3
        ];
      };

    recursive-merge-attrsets =
      myLib.recursiveMerge [
        { users.alice.shell = "bash"; }
        { users.bob.shell = "zsh"; }
      ] == {
        users = {
          alice.shell = "bash";
          bob.shell = "zsh";
        };
      };

    # importIfNix: the documented outcomes, against real repo files
    import-if-nix-file = builtins.isFunction (
      importIfNix ../checks/example/users/dave/configuration.nix
    );
    import-if-nix-non-nix-file = importIfNix ../README.md == { };
    import-if-nix-directory-with-default = builtins.isFunction (importIfNix ../lib);
    import-if-nix-directory-without-default =
      importIfNix ../checks/invalid-fixtures/no-nix-files == { };
    import-if-nix-missing-path = importIfNix ../does-not-exist == { };
    # a symlink is followed and classified by its target: a link named
    # *.nix to a valid Nix file imports like the target itself (the
    # fixture links to dave's configuration.nix, a module function)
    import-if-nix-symlink-to-valid = builtins.isFunction (
      importIfNix ../checks/fixtures/symlink-to-valid.nix
    );
    # the git-crypt case: right name, encrypted (binary) content -> { }
    import-if-nix-git-crypted-content = importIfNix ../checks/invalid-fixtures/git-crypted.nix == { };
    # right name, text content that is not Nix -> { }
    import-if-nix-invalid-syntax = importIfNix ../checks/invalid-fixtures/not-nix-syntax.nix == { };

    # importIfNixOr: a caller-supplied default replaces { } on invalid ...
    import-if-nix-or-custom-default =
      importIfNixOr ../checks/invalid-fixtures/git-crypted.nix { tester = 1212; } == {
        tester = 1212;
      };
    # ... and is ignored when the file imports fine
    import-if-nix-or-ignores-default-when-valid = builtins.isFunction (
      importIfNixOr ../checks/example/users/dave/configuration.nix { tester = 1212; }
    );

    # readIfPlain: the documented outcomes, against real repo files
    read-if-plain-plaintext-file =
      readIfPlain ../checks/fixtures/plain-secret.txt == "not-actually-a-secret-but-plain-text\n";
    # the same git-crypt fixture importIfNix uses -- its magic header is
    # what readIfPlain* detects too, regardless of the plaintext's shape
    read-if-plain-git-crypted-file = readIfPlain ../checks/invalid-fixtures/git-crypted.nix == "";
    read-if-plain-missing-path = readIfPlain ../does-not-exist == "";
    read-if-plain-directory = readIfPlain ../lib == "";

    # readIfPlainOr: a caller-supplied default replaces "" on invalid ...
    read-if-plain-or-custom-default =
      readIfPlainOr ../checks/invalid-fixtures/git-crypted.nix "fallback" == "fallback";
    # ... and is ignored when the file reads fine
    read-if-plain-or-ignores-default-when-plain =
      readIfPlainOr ../checks/fixtures/plain-secret.txt "fallback"
      == "not-actually-a-secret-but-plain-text\n";

    # list dedup fires only when a key occurs in 2+ sets: a
    # single-occurrence list keeps its duplicates (pinned current
    # behavior, documented in the docstring)
    recursive-merge-single-occurrence-keeps-duplicates =
      myLib.recursiveMerge [
        {
          tags = [
            "web"
            "web"
          ];
        }
        { other = 1; }
      ] == {
        tags = [
          "web"
          "web"
        ];
        other = 1;
      };

    recursive-merge-lists-dedup =
      myLib.recursiveMerge [
        {
          tags = [
            "web"
            "prod"
          ];
        }
        {
          tags = [
            "prod"
            "critical"
          ];
        }
      ] == {
        tags = [
          "web"
          "prod"
          "critical"
        ];
      };
  };

  runner = import ./run-assertions.nix { inherit pkgs; };
in
runner.run "lib-functions-tests" assertions
