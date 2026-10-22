set_project("synthesis-boundaries")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("provider")
    add_rules("bluespec.library")
    set_bsc_root("src/provider/Root.bsv")
    -- Deliberately keep source search paths private. The test first builds
    -- this library, so consumers scan its exported .bo interface only.
    add_bsc_package_dirs("src/provider")

for _, name in ipairs({"sim_a", "sim_b", "rtl"}) do
    target(name)
        set_default(false)
        add_rules(name == "rtl" and "bluespec.verilog" or "bluespec.bluesim")
        set_bsc_root("src/consumer/Top.bsv")
        set_bsc_top("mkTop")
        add_deps("provider")
end

for _, name in ipairs({"shared_root", "shared_root_rtl"}) do
    target(name)
        set_default(false)
        add_rules(name == "shared_root_rtl" and "bluespec.verilog" or "bluespec.bluesim")
        set_bsc_root("src/provider/Root.bsv")
        set_bsc_top("mkProviderTop")
        add_bsc_defines("ROOT_VALUE=2")
        add_deps("provider")
end

target("all")
    set_kind("phony")
    add_deps("sim_a", "sim_b", "rtl", "shared_root", "shared_root_rtl")

target("sims")
    set_default(false)
    set_kind("phony")
    add_deps("sim_a", "sim_b")

target("check")
    set_default(false)
    add_rules("bluespec.check")
    set_bsc_root("src/check/Check.bsv")
    add_deps("provider")

target("checked_sims")
    set_default(false)
    set_kind("phony")
    add_deps("check", "sims")
