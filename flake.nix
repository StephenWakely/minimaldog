{
  description = "Minimal DogStatsD client in x86-64 assembly";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          name = "dogstatsd-client";
          src = ./.;
          nativeBuildInputs = [ pkgs.nasm pkgs.binutils ];
          buildPhase = ''
            nasm -f elf64 -o dogstatsd.o dogstatsd.asm
            ld -o dogstatsd dogstatsd.o
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp dogstatsd $out/bin/
          '';
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.nasm
            pkgs.binutils
            pkgs.python3
            pkgs.python3Packages.pytest
            pkgs.gdb
          ];
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/dogstatsd";
        };
      }
    );
}
