# Fixture checks

Run the automated regression suite inside the development shell:

```sh
nix-shell --run 'xmake regression'
```

The runner is implemented in Xmake Lua and uses isolated copies below
`build/regression`.  It covers package-level reverse-dependency invalidation,
dynamic import edge changes, dependency `.bo` reuse, generated BSV input/config
invalidation and cache hits, valued/valueless defines, ordered multi-token BSC
option groups with PUBLIC/INTERFACE propagation, and define
invalidation/propagation, Bluesim execution/output placement,
direct/transitive static BDPI dependencies, builddir graph isolation,
target-selected C++ driver pinning and backend invalidation when that driver
changes (including protection from an unrelated ambient `CXX`),
rule-owned target kinds and conflicting `set_kind()` recovery,
deterministic Verilog filelists exposed through standard `targetfile()`,
downstream filelist invalidation, Verilog builddir relocation, cycles,
duplicate providers, and unexported packages.  A native fake-BSC fixture also
checks project-wide cross-target backend/all-BSC caps, `-j1` interaction,
same-target package/backend ordering, exactly-once all-target scheduling,
failure retry/completion state, and unchanged cache hits.  It does not require a
shell/Python test script or produce a public manifest.  A native delayed
fake-Bluetcl fixture measures actual PID/timestamp overlap, shared-root
single-flight, dependency-to-consumer ordering, the optional scan cap, `-j1`,
source and provider-graph invalidation, builddir-independent raw identity, and
unchanged cache hits.  Its grouped-root stress case declares 64 targets as 16
adjacent four-target groups and checks both full `-j8` owner concurrency and
whole-scan utilization, catching duplicate waiters that occupy worker slots and
starve later unique roots.

Generated BSV that feeds dependency scanning must be produced by a generator
target's prepare hook.  A normal `on_build` hook is too late because Xmake
finishes the global prepare graph before it starts build jobs.  The
`cases/generated` fixture uses `core.project.depend.on_changed` to track the
generator input and configuration; its regression adds and removes an import,
checks the resulting package DAG, and verifies unchanged cache hits.

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
contains only `Check.bo`.  `rtl` exposes a sorted, absolute-path `rtl.f` as its
standard Xmake targetfile (by default `build/Verilog/rtl.f`, listing
`build/Verilog/rtl/*.v`).  `sim` also
depends on the ordinary Xmake static target `native` (the same path used for
BDPI libraries).  SystemC additionally needs a SystemC SDK in the compiler
include/link paths:

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
