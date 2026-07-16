set_project("bluespec-fixture")
includes("../../rules/bluespec.lua")

target("common")
    set_kind("phony")
    add_rules("bluespec.library")
    set_bsc_root("src/common/Common.bsv")
    add_bsc_package_dirs("src/common", {public = true})

target("check")
    set_kind("phony")
    add_rules("bluespec.check")
    set_bsc_root("src/check/Check.bsv")
    add_deps("common")

target("native")
    set_kind("static")
    add_files("src/native/bridge.cpp")

target("sim")
    set_kind("binary")
    set_default(false)
    add_rules("bluespec.bluesim")
    set_bsc_root("src/top/Top.bsv")
    set_bsc_top("mkTop")
    add_deps("native")

target("rtl")
    set_kind("phony")
    set_default(false)
    add_rules("bluespec.verilog")
    set_bsc_root("src/top/Top.bsv")
    set_bsc_top("mkTop")

target("systemc")
    set_kind("static")
    set_default(false)
    add_rules("bluespec.systemc")
    set_bsc_root("src/top/Top.bsv")
    set_bsc_top("mkTop")

-- Exercise the documented low-level values representation as well as the
-- convenience helpers used by the other targets.
target("raw-values")
    set_kind("phony")
    set_default(false)
    add_rules("bluespec.library")
    set_values("bluespec.root", "src/common/Common.bsv")
    set_values("bluespec.package_dirs.public", "src/common")
