{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ...}:
  let

    myLib = import ./lib { inherit (nixpkgs) lib; };

  in {
    lib = myLib;

    # Keep overlay for pkgs.lib (works in some contexts)
    overlays.default = final: prev: {
      lib = prev.lib.recursiveUpdate prev.lib myLib;
    };

    # Helper for consumers
    extendLib = lib: nixpkgs.lib.recursiveUpdate lib myLib;
  };
}

# Test:
# nix repl --impure --expr '(builtins.getFlake (toString ./.)).outputs'
# nix repl --impure --expr '(import <nixpkgs> { overlays = [(builtins.getFlake (toString ./.)).overlays.default]; }).lib'

