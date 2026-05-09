{ pkgs ? import <nixpkgs> {} }:

let
  # Runtime library dependencies (needed for both linking and LD_LIBRARY_PATH)
  runtimeDeps = with pkgs; [
    raylib
    sqlite
    libmicrohttpd
    cjson
    uthash
  ];
  libPath = pkgs.lib.makeLibraryPath runtimeDeps;
in

pkgs.mkShell {
  # Tools (executables) you want available in the shell
  nativeBuildInputs = with pkgs; [
    gcc
    clang
    llvm
    pkg-config
    uv          # Python package manager
    pandoc      # Document converter
    python3     # Python interpreter
  ];

  # Libraries for compiling/linking
  buildInputs = runtimeDeps;   # sqlite is already here

  shellHook = ''
    export LD_LIBRARY_PATH="${libPath}:$LD_LIBRARY_PATH"
    export C_INCLUDE_PATH="${pkgs.uthash}/include:$C_INCLUDE_PATH"
    export LIBRARY_PATH="${libPath}:$LIBRARY_PATH"
    echo "C development environment ready."
    echo "Additional tools: uv, pandoc, python3"
  '';
}
