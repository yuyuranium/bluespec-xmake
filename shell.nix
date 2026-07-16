{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
    packages = [
        pkgs.xmake
        pkgs.bluespec
    ];
}
