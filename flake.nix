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

        # The client itself: a static x86-64 Linux binary with no libc.
        client = pkgs.stdenv.mkDerivation {
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

        # Docker image. dockerTools' streamLayeredImage is a script that
        # writes a docker-save-compatible tarball to stdout:
        #   nix build .#packages.x86_64-linux.dockerImage
        #   docker load -i <(./result -t minimaldog:latest)
        #
        # The binary is static, so the image contains nothing but
        # /bin/minimaldog — no base OS. A default DD_DOGSTATSD_URL is baked
        # in so `docker run minimaldog` works out of the box; override it
        # with -e at run time.
        dockerImage = pkgs.dockerTools.streamLayeredImage {
          name = "minimaldog";
          contents = [ client ];
          config = {
            Entrypoint = [ "/bin/minimaldog" ];
            Env = [ "DD_DOGSTATSD_URL=udp://127.0.0.1:8125" ];
          };
        };
      in
      {
        packages.default = client;
        packages.dockerImage = dockerImage;

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
          program = "${client}/bin/minimaldog";
        };
      }
    );
}
