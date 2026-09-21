# c3_ls

C3 language server.

## build

requires `c3c` in your path.

```sh
c3c build -O2
```

binary is in `build/c3_ls`.

## flags

* `--stdlib-path <path>`: path to C3 standard library.
* `--compiler-path <path>`: path to `c3c` executable.
* `--log-level <error|warn|info|debug>`: minimum log severity (default: `error`).
* `--log-path <path>`: file path to write logs to.
* `-v, --version`: print version and exit.
* `-h, --help`: print help manual.

### bindgen flags

* `--bindgen <header.h|directory>`: generate C3 bindings from a C header file ir a directory.
* `-o, --output <path>`: output file path (.c3 or .c3i) for bindings.
* `-m, --module <name>`: module name for generated bindings.
* `--type-prefix <prefix>`: type prefix for generated types (e.g. `RL`).
* `--strip-prefix <prefix>`: function prefix to strip (default: `<module>_`).
* `-I, --include <dir>`: include directory for clang.
* `-D, --define <macro>`: macro definition for clang.

## features

* diagnostics
* hover
* goto definition
* completion & resolve
* signature help
* references
* rename & prepare rename
* document & workspace symbols
* semantic tokens
* inlay hints
* folding ranges
* formatting & range formatting
* C binding generator (`--bindgen` & Quick Fix on missing ex:`import sqlite3;`)

## license

mit

## credits

> Special thanks to **m0tholith**, **Zathy**, and **ecoral360** for laying the groundwork and architecture for the C3 language server.