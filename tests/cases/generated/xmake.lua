set_project("generated")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("generator")
    set_kind("phony")
    set_values("generated.mode", "base")
    on_prepare(function(target)
        local depend = import("core.project.depend")
        local input = path.join(os.projectdir(), "src", "generator", "spec.txt")
        local output = path.join(os.projectdir(), "build", "generated", "Generated.bsv")
        local mode = target:values("generated.mode")
        if type(mode) == "table" then
            mode = mode[1]
        end
        mode = mode or "base"
        depend.on_changed(function()
            local spec = (io.readfile(input) or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local import_line = ""
            local expression
            if spec == "plain" then
                expression = mode == "offset" and "43" or "42"
            elseif spec == "import" then
                import_line = "import Extra::*;"
                expression = mode == "offset" and "extraValue() + 1" or "extraValue()"
            else
                raise("unknown generated BSV spec %q", spec)
            end
            local contents = table.concat({
                "package Generated;",
                "",
                import_line,
                "",
                "function Integer generatedValue();",
                "    return " .. expression .. ";",
                "endfunction",
                "",
                "endpackage",
                "",
            }, "\n")
            os.mkdir(path.directory(output))
            io.writefile(output, contents)
            cprint("generating Generated.bsv (%s/%s)", spec, mode)
            return {}
        end, {
            dependfile = target:dependfile(output),
            files = {input},
            values = {"generated-bsv-v1", mode},
            changed = not os.isfile(output),
        })
    end)

target("generated")
    add_rules("bluespec.library")
    set_bsc_root("build/generated/Generated.bsv")
    add_bsc_package_dirs("build/generated", {public = true})
    add_bsc_package_dirs("src/deps")
    add_deps("generator")
