# Fixture checks

Run the automated regression suite inside the development shell:

```sh
nix-shell --run 'xmake regression'
```

The runner is implemented in Xmake Lua and uses isolated copies below
`build/regression`.  It covers cache hits, source and dynamic-import
invalidation, dependency `.bo` reuse, generated BSV in the same invocation,
valued/valueless defines and define invalidation/propagation, Bluesim
execution/output placement, direct/transitive static BDPI dependencies,
builddir graph isolation, deterministic Verilog filelists, cycles, duplicate
providers, and unexported packages.  It does not require a shell/Python test
script or produce a public manifest.

Generated BSV that feeds dependency scanning must be produced by a generator
target's prepare hook.  A normal `on_build` hook is too late because Xmake
finishes the global prepare graph before it starts build jobs.

Run the fixture from the repository root inside the development shell:

```sh
nix-shell --run 'xmake config -P tests/fixture'
nix-shell --run 'xmake build -P tests/fixture common'
nix-shell --run 'xmake build -P tests/fixture check'
nix-shell --run 'xmake build -P tests/fixture sim'
nix-shell --run 'xmake run -P tests/fixture sim'
nix-shell --run 'xmake build -P tests/fixture rtl'
```

`check` imports the `.bo` files produced by `common`; its output directory
contains only `Check.bo`.  `rtl` writes a sorted, absolute-path `rtl.f` next to
the generated Verilog.  `sim` also depends on the ordinary Xmake static target
`native` (the same path used for BDPI libraries).  SystemC additionally needs a
SystemC SDK in the compiler include/link paths:

```sh
nix-shell -p xmake bluespec systemc --run \
  'xmake build -P tests/fixture systemc'
```

If the shell does not export the SDK paths automatically, set `CPATH` to the
SystemC `include` directory and `LIBRARY_PATH` to its `lib` directory before
the command.

The fixture intentionally has no external scanner or manifest-generation
script.  Xmake's normal `.xmake`/dependfile state and the backend artifacts are
the only files created by a build.
