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

  # the importIfNix* validity probe is IFD (built during evaluation), so it
  # is pinned to x86_64-linux here -- like the other IFD steps -- to keep
  # cross-system EVALUATION of this check buildable on the test machine
  importIfNix = myLib.importIfNix nixpkgs.legacyPackages."x86_64-linux";
  importIfNixOr = myLib.importIfNixOr nixpkgs.legacyPackages."x86_64-linux";

  assertions = {
    string-to-title-sentence = myLib.stringToTitle "hello world" == "Hello world";
    string-to-title-word = myLib.stringToTitle "foobar" == "Foobar";
    string-to-title-empty = myLib.stringToTitle "" == "";

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
    import-if-nix-file = builtins.isFunction (importIfNix ../checks/example/users/dave/configuration.nix);
    import-if-nix-non-nix-file = importIfNix ../README.md == { };
    import-if-nix-directory-with-default = builtins.isFunction (importIfNix ../lib);
    import-if-nix-directory-without-default = importIfNix ../checks/invalid-fixtures/no-nix-files == { };
    import-if-nix-missing-path = importIfNix ../does-not-exist == { };
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

  failed = lib.attrNames (lib.filterAttrs (_: ok: ok != true) assertions);
in
if failed == [ ] then
  pkgs.runCommand "lib-functions-tests" { } "touch $out"
else
  throw "lib function tests failed: ${lib.concatStringsSep ", " failed}"
