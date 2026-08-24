# c3_ls

C3 language server.

## build

requires `c3c` in your path.

```sh
c3c build
```

binary is in `build/c3_ls`.

## flags

* `--stdlib-path <path>`: path to C3 standard library.
* `--log-level <error|warn|info|debug>`: minimum log severity (default: `error`).
* `--log-path <path>`: file path to write logs to.
* `-v, --version`: print version and exit.

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

## license

mit

## credits

> Special thanks to **m0tholith**, **Zathy**, and **ecoral360** for laying the groundwork and architecture for the C3 language server.