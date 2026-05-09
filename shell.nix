{ pkgs ? import <nixpkgs> {} }:

let
  # Runtime library dependencies (needed for C linking and LD_LIBRARY_PATH)
  runtimeDeps = with pkgs; [
    raylib
    sqlite
    libmicrohttpd
    cjson
    uthash
  ];
  libPath = pkgs.lib.makeLibraryPath runtimeDeps;

  # Lua 5.2 with the luasql-sqlite3 module pre‑available
  luaWithSqlite = pkgs.lua5_2.withPackages (ps: [ ps.luasql-sqlite3 ]);
in

pkgs.mkShell {
  # Tools (executables) and interpreters
  nativeBuildInputs = with pkgs; [
    gcc
    clang
    llvm
    pkg-config
    uv
    pandoc
    python3
    luaWithSqlite
  ];

  # Libraries for compiling/linking (C/C++)
  buildInputs = runtimeDeps;

  shellHook = ''
    export LD_LIBRARY_PATH="${libPath}:$LD_LIBRARY_PATH"
    export C_INCLUDE_PATH="${pkgs.uthash}/include:$C_INCLUDE_PATH"
    export LIBRARY_PATH="${libPath}:$LIBRARY_PATH"
    echo "C development environment ready."
    echo "Additional tools: uv, pandoc, python3, lua (with luasql-sqlite3)"
  '';
}
