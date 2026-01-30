{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ...}:
  let
    myLib = import ./lib { inherit (nixpkgs) lib; };
  in {
    lib = myLib;
    overlays.default = final: prev: {
      lib = prev.lib.recursiveUpdate prev.lib myLib;
    };
  };
}

# Test:
# nix repl --impure --expr 'builtins.getFlake (toString ./.).lib'
# nix repl --impure --expr '(import <nixpkgs> { overlays = [(builtins.getFlake (toString ./.)).overlays.default]; }).lib'

