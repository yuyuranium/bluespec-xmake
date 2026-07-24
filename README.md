# bluespec-xmake

`bluespec-xmake` provides Bluespec build rules implemented entirely in Xmake
Lua.  The prepare stage invokes `bluetcl`, parses its Tcl dependency list in
Lua, and stores the package graph in Xmake memory/local cache.  The build stage
adds one job for each owned package and orders those jobs by the import DAG.
No public manifest or JSON analysis file is generated.

## Development shell

The repository follows the active `<nixpkgs>` channel:

```sh
direnv allow          # .envrc runs: use nix
xmake build
```

The shell provides `xmake`, `bsc`, and `bluetcl` from `shell.nix`.

Run the Xmake-Lua regression suite with:

```sh
xmake regression
```

## Consumer example

```lua
add_moduledirs("path/to/bluespec-xmake/modules")
includes("path/to/bluespec-xmake/rules/bluespec.lua")

target("lib")
    add_rules("bluespec.library")
    set_bsc_root("src/Lib.bsv")
    add_bsc_package_dirs("src", {public = true})
    add_bsc_defines("USE_FAST", {interface = true})

target("check")
    add_rules("bluespec.check")
    set_bsc_root("src/Check.bsv")
    add_deps("lib")

target("sim")
    add_rules("bluespec.bluesim")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")

target("rtl")
    add_rules("bluespec.verilog")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")

target("rtl_consumer")
    set_kind("phony")
    add_deps("rtl")
    on_build(function(target)
        local filelist = assert(target:dep("rtl"):targetfile())
        local contents = assert(io.readfile(path.absolute(filelist)))
        -- Process `contents` and its listed RTL with pure Xmake Lua.
    end)
```

The other backend rules are `bluespec.verilog` and `bluespec.systemc`.
Backend targets require `set_bsc_top`; every buildable target requires exactly
one `set_bsc_root`.

Bluespec rules own the Xmake target kind and set it during `on_load`: library
and check targets are `phony`, Bluesim and Verilog targets are `binary`, and
SystemC targets are `static`.  Consumers should not call `set_kind()` on these
targets; an explicitly conflicting kind is replaced by the rule.  Native and
BDPI targets remain ordinary Xmake targets and keep their consumer-selected
`static`, `shared`, or `binary` kind.

The complete target-scope API is `set_bsc_root`, `set_bsc_top`,
`add_bsc_package_dirs`, `add_bsc_defines`, `add_bsc_options`, and
`add_bsc_link_options`.  The equivalent low-level Xmake values are under
`bluespec.root`, `bluespec.top`, and the `.private`/`.public`/`.interface`
keys below those namespaces.

`set_bsc_root` and `add_bsc_package_dirs` are path-valued APIs: relative paths
are resolved against the `xmake.lua` that declares the target (including a
nested `includes()` file), while absolute paths are preserved.  The define,
option, and link-option APIs remain opaque argument lists and are not
rewritten as paths.

Visibility follows dependency-to-consumer propagation: private values affect
the declaring target, while public/interface package directories, defines,
options, and link options are exported to consumers.
Each `add_bsc_options(...)` invocation is retained as one ordered argv group,
so a flag and its value (or an RTS sequence such as `+RTS`, `-K1G`, `-RTS`)
remain adjacent through dependency propagation.  A one-token invocation keeps
the existing single-token behavior.
Native C/C++ targets can be attached with ordinary `add_deps()`; Bluesim link
jobs force-load direct and transitive static dependencies into the shared model
and build those archives as PIC where the platform requires it.  SystemC
targets are ordinary native dependencies too: their PUBLIC interface exports
the generated model headers, BSC's `Bluesim` SDK headers, the model archive,
and the ordered `systemc`, `bskernel`, and `bsprim` runtime links.  A native
consumer therefore only needs `add_deps()` and can include the generated
`*_systemc.h` without discovering `BLUESPECDIR` or internal build paths.
Generated BSV inputs must be emitted during Xmake's prepare phase (for example,
by an `on_prepare` generator target); ordinary `on_build` generation happens
after dependency scanning.  The generator should use
`core.project.depend.on_changed` with both its input files and configuration
values, and should only rewrite its output when those inputs change.  This lets
the scanner update import edges in the same invocation while keeping unchanged
builds quiet.  `tests/cases/generated` is a complete example.

Dependency scans are ordinary prepare-jobgraph jobs.  A Bluespec dependency's
scan is ordered before its consumers, while independent targets can run
Bluetcl concurrently under Xmake's global `-j`.  Within one Xmake invocation,
targets with the same raw scan identity share one explicit jobgraph owner node.
Their target-specific finalize nodes depend on that owner; duplicate targets do
not start coroutine waiters and therefore do not consume Xmake `-j` slots while
the raw scan is running.  Each target still parses/finalizes its own graph, so
provider ownership and target-specific `.bo` paths are never shared.  The
ordinary `scanning Bluespec` progress line is emitted by the owner and counts
real Bluetcl invocations rather than duplicate target graphs.

The raw identity covers the canonical root and input stamps, ordered scanner
argv (defines/options), canonical search directories, and the stamped
BSC/Bluetcl identity.  Top module, backend, and the consumer target's output
directory are deliberately excluded because they do not change imports.
Nothing is written as a public scan manifest or metadata file.

Each package compile is an ordinary Xmake job and follows Xmake's global `-j`
setting.  Backend elaboration additionally uses a project-wide resource pool,
shared by all Bluesim, Verilog, and SystemC targets in the invocation.  The
configuration options are:

- `--bluespec_backend_jobs=N`: maximum simultaneous backend transactions;
  defaults to `1`.  Use `0` to inherit only the global `-j` limit.
- `--bluespec_bsc_jobs=N`: optional maximum simultaneous BSC processes across
  package and backend jobs; defaults to `0` (disabled).
- `--bluespec_scan_jobs=N`: optional project-wide maximum for actual Bluetcl
  scans; defaults to `0`, so independent scans follow only Xmake's `-j`.
- `--bluespec_trace_bsc=y`: print the target/job/phase, execution identity,
  full indexed argv, bdir/search/provider/output paths, and start/end timing
  for each BSC process.
- `--bluespec_trace_scan=y`: print separate raw-process, owner lifecycle,
  duplicate waiter/release, and target-finalize events with target, root, scan
  identity, status, and timing.

Configure persistent limits in the ordinary Xmake configuration, for example:

```sh
xmake f --bluespec_backend_jobs=1 --bluespec_bsc_jobs=2 --bluespec_scan_jobs=0
xmake -j 12 -a
```

The effective concurrency never exceeds Xmake's `-j`: resource pools only
reduce the number of ready jobs that enter BSC.  A backend slot covers the
whole backend transaction, including its generated model/link phases, and is
acquired only after incremental checking finds real work.  Package jobs remain
parallel subject to their import DAG and the optional all-BSC cap.
The scan pool is separate from both BSC pools and limits only real Bluetcl
processes; it is not required to enable scan parallelism or single-flight.

Xmake 3.0.4's `os.vrunv()` API does not expose its child PID.  Trace output
marks this explicitly and exports `BLUESPEC_XMAKE_TARGET`,
`BLUESPEC_XMAKE_JOB`, `BLUESPEC_XMAKE_PHASE`, and the unique
`BLUESPEC_XMAKE_INVOCATION` into the BSC environment, allowing an OS process
observer to correlate the actual PID without adding a wrapper executable or
changing BSC scheduling.

## Artifacts and incremental state

Only build artifacts are exposed: `.bo`, Bluesim output (the executable defaults
to `build/bin/<target>`), Verilog plus a sorted `.f` filelist, or SystemC
generated sources/headers and a static archive.  For `bluespec.verilog`, the
filelist is the target's standard `targetfile()`; its default location is
`build/Verilog/<target>.f`, with raw BSC output in
`build/Verilog/<target>/*.v`.  Standard `set_targetdir`/`set_filename` settings
are respected.  Dependency consumers use `target:dep("rtl"):targetfile()` and
never need internal target data or knowledge of `.gens` paths.  Filelist entries
are sorted absolute paths to this public RTL directory and relocate with the
builddir.  Internal BSC state follows the compiler's flag terminology: `bdir`
for `.bo`/`.ba`, `simdir` for Bluesim intermediates, and `info` for
informational output.
Package and backend dependfiles, graph cache, and Xmake's `.xmake` state are
internal.  Graph entries are scoped to the configured build/autogen/output
directories; source/import changes, include paths, flags, and the BSC identity
invalidate the relevant scan or package/backend job.

Xmake can only clean targets present in the currently loaded project.  Run
`xmake clean -a` before deleting a target definition, or remove the configured
build directory afterward if obsolete target state must be reclaimed.
