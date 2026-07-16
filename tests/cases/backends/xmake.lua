set_project("backends")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("native")
    set_kind("static")
    add_files("src/native/bridge.cpp")

target("sim")
    set_kind("binary")
    set_default(false)
    add_rules("bluespec.bluesim")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
    add_deps("native")

target("rtl")
    set_kind("phony")
    set_default(false)
    add_rules("bluespec.verilog")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")

target("rtl_consumer")
    set_kind("phony")
    set_default(false)
    add_deps("rtl")
    on_build(function(target)
        local config = import("core.project.config")
        local depend = import("core.project.depend")
        local rtl = assert(target:dep("rtl"), "missing rtl dependency")
        local filelist = assert(rtl:targetfile(), "rtl dependency has no targetfile")
        filelist = path.absolute(filelist)
        local output = path.absolute(path.join(config.builddir(), "processed", "rtl.f"))
        depend.on_changed(function()
            local contents = assert(io.readfile(filelist), "missing public Verilog filelist " .. filelist)
            os.mkdir(path.directory(output))
            io.writefile(output, contents)
            cprint("processing Verilog targetfile %s", filelist)
            return {}
        end, {
            dependfile = target:dependfile(output),
            files = {filelist},
            values = {"verilog-targetfile-consumer-v1", filelist},
            changed = not os.isfile(output),
        })
    end)
