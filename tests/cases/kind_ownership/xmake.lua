set_project("kind-ownership")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

local function report(name)
    return function(target)
        cprint("BLUESPEC_KIND_%s=%s", name, target:kind())
    end
end

target("library")
    set_kind("static")
    add_rules("bluespec.library")
    set_bsc_root("src/Top.bsv")
    on_config(report("library"))

target("check")
    set_kind("shared")
    add_rules("bluespec.check")
    set_bsc_root("src/Top.bsv")
    on_config(report("check"))

target("bluesim")
    set_kind("phony")
    set_default(false)
    add_rules("bluespec.bluesim")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
    on_config(report("bluesim"))

target("verilog")
    set_kind("phony")
    set_default(false)
    add_rules("bluespec.verilog")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
    on_config(report("verilog"))

target("systemc")
    set_kind("binary")
    set_default(false)
    add_rules("bluespec.systemc")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
    on_config(report("systemc"))
