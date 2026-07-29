set_project("backends")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("native")
    set_kind("static")
    add_files("src/native/bridge.cpp")

target("sim")
    set_default(false)
    add_rules("bluespec.bluesim")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
    add_bsc_defines("BACKEND_VALUE=1")
    add_deps("native")

target("rtl")
    set_default(false)
    add_rules("bluespec.verilog")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
    add_bsc_defines("BACKEND_VALUE=1")

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
        local librarydirs = table.wrap(assert(
            rtl:values("bluespec.verilog.sdk.librarydirs"),
            "rtl dependency has no public BSC Verilog SDK directories"))
        local interface_librarydirs = table.wrap(assert(
            rtl:get("values.bluespec.verilog.sdk.librarydirs", {interface = true}),
            "BSC Verilog SDK directories are not a PUBLIC target value"))
        assert(table.concat(librarydirs, "\n") == table.concat(interface_librarydirs, "\n"),
            "public BSC Verilog SDK interface differs from dep:values()")
        local sdk_identity = assert(rtl:values("bluespec.verilog.sdk.identity"),
            "rtl dependency has no public BSC Verilog SDK identity")
        assert(rtl:get("values.bluespec.verilog.sdk.identity", {interface = true}),
            "BSC Verilog SDK identity is not a PUBLIC target value")
        local sdk_files = {}
        for _, directory in ipairs(librarydirs) do
            assert(path.is_absolute(directory),
                "BSC Verilog SDK directory is not absolute: " .. directory)
            assert(os.isdir(directory), "missing BSC Verilog SDK directory " .. directory)
            for _, file in ipairs(os.files(path.join(directory, "*.v"))) do
                table.insert(sdk_files, file)
            end
        end
        assert(#sdk_files > 0, "BSC Verilog SDK contains no primitive .v files")
        table.sort(sdk_files)
        local inputs = {filelist}
        table.join2(inputs, sdk_files)
        local output = path.absolute(path.join(config.builddir(), "processed", "rtl.f"))
        local sdk_output = path.absolute(path.join(config.builddir(), "processed", "rtl.sdk"))
        depend.on_changed(function()
            local contents = assert(io.readfile(filelist), "missing public Verilog filelist " .. filelist)
            os.mkdir(path.directory(output))
            io.writefile(output, contents)
            io.writefile(sdk_output, table.concat(librarydirs, "\n") .. "\n")
            cprint("processing Verilog targetfile %s", filelist)
            for _, directory in ipairs(librarydirs) do
                cprint("processing BSC Verilog SDK %s", directory)
            end
            return {}
        end, {
            dependfile = target:dependfile(output),
            files = inputs,
            values = {
                "verilog-targetfile-consumer-v2",
                filelist,
                table.concat(librarydirs, "\n"),
                sdk_identity,
            },
            changed = not os.isfile(output) or not os.isfile(sdk_output),
        })
    end)
