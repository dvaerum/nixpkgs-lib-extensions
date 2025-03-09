{
  inputs = {};

  outputs = { self }: {
    overlays.default = import ./overlays;
  };
}

# Run the following command to test the functions
# nix repl --impure --expr 'rec {nixpkgs = import <nixpkgs>{}; pkgs = nixpkgs; lib = pkgs.lib; self = builtins.getFlake (toString ./.); test_lib = (import <nixpkgs> { system = pkgs.system; overlays = [ self.outputs.overlays.default ]; config = {}; }).lib; }'
