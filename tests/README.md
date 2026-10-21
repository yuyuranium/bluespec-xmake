# Fixture checks

Run the automated regression suite with the BSC and SystemC SDKs available:

```sh
nix-shell -p xmake bluespec systemc --run 'xmake regression'
```

For the dependency parser alone, without compilation or parallel build jobs:

```sh
xmake lua tests/parser.lua
```

This checks textual `.bsv` includes, primary-source selection, and explicit or
implicit source-only packages in partial dependency closures. Same-basename
includes are tested before and after the declaring source, in both supported
record formats; explicit declarations take precedence over implicit fallback.

For real Bluetcl and BSC same-basename include checks:

```sh
xmake lua tests/include_fragments.lua
```

This first validates the input using native `bsc -u`, then builds both
`bluespec.check` and `bluespec.verilog`. Changing the include's typedef must
recompile its package in both flavors and change the generated RTL port width;
unchanged builds must stay cached.

For real Bluetcl flag/error handling and scanner cache identity, without BSC
compilation:

```sh
xmake lua tests/scanner.lua
```

This checks conditional imports with Haskell RTS options, preserves the BSC
compile arguments, rejects Tcl failures, and invalidates raw/parsed graph caches
when the scanner contract changes.

For serial, real-BSC synthesis boundary checks:

```sh
xmake lua tests/boundaries.lua
```

This builds and runs two Bluesim consumers sharing a synthesized dependency,
checks the self-contained public Verilog closure, and verifies cache hits,
missing `.ba`/`.v` recovery, and removal of stale synthesized children.
The provider is built before consumers and keeps its source paths private,
covering partial scanner closures containing only imported `.bo` edges. A
consumer with the library's root source also verifies that its private defines
select its own elaboration rather than the provider's prebuilt `.ba`.

For serial, real-SystemC model isolation checks:

```sh
xmake lua tests/systemc_isolation.lua
```

The native compiler must find SystemC headers and libraries. An existing SDK
can be supplied through ordinary `CPLUS_INCLUDE_PATH`/`LIBRARY_PATH` settings.
Two models contain the same synthesized child with different register reset
values; one executable includes both public headers and verifies both values.
The check repeats with reversed header/archive order and verifies cache hits.

The runner is implemented in Xmake Lua and uses isolated copies below
`build/regression`; the focused boundary/isolation runners use temporary
directories. It covers package-level reverse-dependency invalidation,
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
`build/Verilog/rtl/*.v`).  Its PUBLIC
`bluespec.verilog.sdk.librarydirs` target value exposes the BSC primitive
Verilog search directory without adding those files to `rtl.f`; the companion
opaque `bluespec.verilog.sdk.identity` value supports downstream invalidation.
`sim` also
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

The regression suite also builds an ordinary C++ executable which depends on a
`bluespec.systemc` target, includes its generated `*_systemc.h`, and links the
model plus BSC's `bskernel`/`bsprim` runtime through the target's PUBLIC Xmake
interface.  It checks link order, BSC SDK relocation invalidation, execution,
and an unchanged native/Bluespec cache hit.  Its first clean command builds the
consumer directly through a PUBLIC phony aggregator, proving that native object
compilation waits until the generated SystemC headers exist.

The fixture intentionally has no external scanner or manifest-generation
script.  Xmake's normal `.xmake`/dependfile state and the backend artifacts are
the only files created by a build.
