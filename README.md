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
    set_kind("binary")
    add_rules("bluespec.bluesim")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
```

The other backend rules are `bluespec.verilog` and `bluespec.systemc`.
Backend targets require `set_bsc_top`; every buildable target requires exactly
one `set_bsc_root`.

The complete target-scope API is `set_bsc_root`, `set_bsc_top`,
`add_bsc_package_dirs`, `add_bsc_defines`, `add_bsc_options`, and
`add_bsc_link_options`.  The equivalent low-level Xmake values are under
`bluespec.root`, `bluespec.top`, and the `.private`/`.public`/`.interface`
keys below those namespaces.

Visibility follows dependency-to-consumer propagation: private values affect
the declaring target, while public/interface package directories, defines,
options, and link options are exported to consumers.
Native C/C++ targets can be attached with ordinary `add_deps()`; Bluesim link
jobs force-load direct and transitive static dependencies into the shared model
and build those archives as PIC where the platform requires it.  SystemC
targets publish generated includes plus the `systemc` link requirement.
Generated BSV inputs must be emitted during Xmake's prepare phase (for example,
by an `on_prepare` generator target); ordinary `on_build` generation happens
after dependency scanning.

## Artifacts and incremental state

Only build artifacts are exposed: `.bo`, Bluesim output (the executable defaults
to `build/bin/<target>`), Verilog plus a sorted
`.f` filelist, or SystemC generated sources/headers and a static archive.
Package and backend dependfiles, graph cache, and Xmake's `.xmake` state are
internal.  Graph entries are scoped to the configured build/autogen/output
directories; source/import changes, include paths, flags, and the BSC identity
invalidate the relevant scan or package/backend job.
