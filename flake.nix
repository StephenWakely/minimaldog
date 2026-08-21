{
  description = "Minimal DogStatsD heartbeat client in x86-64 assembly";

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
          name = "minimal-dogstatsd-heartbeat";
          src = ./.;
          nativeBuildInputs = [ pkgs.nasm pkgs.binutils ];
          buildPhase = ''
            nasm -f elf64 -o minimaldog.o minimaldog.asm
            ld -o minimaldog minimaldog.o
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp minimaldog $out/bin/
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
          program = "${self.packages.${system}.default}/bin/minimaldog";
        };
      }
    );
}
