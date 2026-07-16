set_project("generated")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("generator")
    set_kind("phony")
    on_prepare(function(target)
        local output = path.join(os.projectdir(), "build", "generated", "Generated.bsv")
        os.mkdir(path.directory(output))
        io.writefile(output, [[package Generated;

function Integer generatedValue();
    return 42;
endfunction

endpackage
]])
        cprint("generating Generated.bsv")
    end)

target("generated")
    set_kind("phony")
    add_rules("bluespec.library")
    set_bsc_root("build/generated/Generated.bsv")
    add_bsc_package_dirs("build/generated", {public = true})
    add_deps("generator")
