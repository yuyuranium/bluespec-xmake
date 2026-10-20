-- Real BSC integration, deliberately serial: exercise the public build/run
-- paths with dependency sources outside the consumer's compile search path.
function main()
    local root = path.absolute(path.join(os.scriptdir(), ".."))
    local work = os.tmpfile() .. "-synthesis-boundaries"
    os.mkdir(work)
    os.cp(path.join(root, "tests/cases/synthesis_boundaries"), work)
    local project = path.join(work, "synthesis_boundaries")
    local sequence = 0
    local function run(arguments, expected_error)
        sequence = sequence + 1
        local stdout = path.join(work, tostring(sequence) .. ".out")
        local stderr = path.join(work, tostring(sequence) .. ".err")
        local command = {arguments[1], "-P", project}
        for index = 2, #arguments do table.insert(command, arguments[index]) end
        local code = os.execv(os.programfile(), command, {
            curdir = project,
            envs = {BLUESPEC_XMAKE_ROOT = root},
            stdout = stdout, stderr = stderr, try = true,
        })
        local output = (io.readfile(stdout) or "") .. (io.readfile(stderr) or "")
        if expected_error then
            assert(code ~= 0 and output:find(expected_error, 1, true),
                "expected boundary rejection; logs in " .. work .. "\n" .. output)
        else
            assert(code == 0, "boundary fixture failed; logs in " .. work .. "\n" .. output)
        end
        return output
    end
    local function one(pattern)
        local files = os.files(path.join(project, "build", pattern))
        assert(#files == 1, "expected one " .. pattern .. "; logs in " .. work)
        return files[1]
    end
    local function cache_hit()
        local output = run({"build", "-j1", "all"})
        for _, message in ipairs({"scanning Bluespec", "compiling Bluespec", "building Bluespec"}) do
            assert(not output:find(message, 1, true), "unchanged build: " .. output)
        end
    end
    local function public_rtl(child_expected)
        local filelist = one("Verilog/rtl.f")
        local directory = path.join(path.directory(filelist), "rtl")
        local files, child = {}, false
        for file in (io.readfile(filelist) or ""):gmatch("[^\r\n]+") do
            assert(path.is_absolute(file) and path.directory(file) == directory,
                "RTL filelist escapes consumer artifacts: " .. file)
            assert(os.isfile(file), "filelist contains missing RTL: " .. file)
            child = child or path.filename(file) == "mkChild.v"
            table.insert(files, file)
        end
        assert(child == child_expected and #files == (child_expected and 2 or 1),
            "incorrect synthesized RTL closure: " .. table.concat(files, ", "))
        local sorted = table.clone(files)
        table.sort(sorted)
        assert(table.concat(files, "\n") == table.concat(sorted, "\n"), "unsorted RTL filelist")
        return path.join(directory, "mkChild.v")
    end

    -- BSC's package paths are nonrecursive. An ancestor source directory
    -- must not claim packages found only through a nested provider's hint.
    local boundaries = project
    project = path.join(work, "nested-private-source")
    os.cp(path.join(root, "tests/cases/unexported_package"), project)
    local nested_recipe = path.join(project, "xmake.lua")
    io.writefile(nested_recipe, (assert(io.readfile(nested_recipe))
        :gsub('add_bsc_package_dirs%("src/library", {public = true}%)', "")
        :gsub('add_bsc_package_dirs%("src/library"%)', "")
        :gsub("src/consumer/Consumer%.bsv", "src/Consumer.bsv")))
    io.writefile(path.join(project, "src/Consumer.bsv"),
        (assert(io.readfile(path.join(project, "src/consumer/Consumer.bsv")))
            :gsub("import Hidden::%*;", "import Public::*;\nimport Hidden::*;")))
    run({"config", "-c", "-y", "--bluespec_backend_jobs=1", "--bluespec_bsc_jobs=1",
        "--bluespec_scan_jobs=1"})
    run({"build", "-j1", "consumer"},
        "package Hidden is located in a dependency package directory but is not exported")
    project = boundaries

    -- Provider and consumer may own separate packages in the same directory.
    -- A scan hint is not a public source-directory ownership declaration.
    os.cp(path.join(root, "tests/cases/scan_concurrency"), work)
    project = path.join(work, "scan_concurrency")
    io.writefile(path.join(project, "src/Local.bsv"),
        "package Local; function Bit#(1) localValue = 1; endpackage\n")
    local consumer = path.join(project, "src/Consumer.bsv")
    io.writefile(consumer, (assert(io.readfile(consumer)):gsub(
        "import Provider::%*;", "import Provider::*;\nimport Local::*;")))
    run({"config", "-c", "-y", "--bluespec_backend_jobs=1", "--bluespec_bsc_jobs=1",
        "--bluespec_scan_jobs=1"})
    run({"build", "-j1", "consumer1"})
    one("**/packages/verilog/Local/Local.bo")
    one("Verilog/consumer1.f")
    project = boundaries

    run({"config", "-c", "-y", "--bluespec_backend_jobs=1", "--bluespec_bsc_jobs=1",
        "--bluespec_scan_jobs=1", "--bluespec_trace_bsc=y"})
    -- No provider .bo exists during the first prepare phase. Its exported
    -- packages must still appear in the consumer's scan, even though their
    -- source directory is private and compilation only accepts provider .bo.
    local cold = run({"build", "-j1", "sim_a"})
    assert(cold:find("provider/bluespec/sim/package/Child", 1, true),
        "cold consumer did not schedule its imported provider package: " .. cold)
    assert(run({"run", "sim_a"}):find("BOUNDARY_OK", 1, true),
        "cold consumer did not execute its imported synthesized child")
    -- Reset artifacts before the separate prebuilt-provider/partial-scan case.
    os.rm(path.join(project, "build"))
    run({"config", "-c", "-y", "--bluespec_backend_jobs=1", "--bluespec_bsc_jobs=1",
        "--bluespec_scan_jobs=1", "--bluespec_trace_bsc=y"})
    -- A prebuilt provider lets Bluetcl report only an imported .bo edge,
    -- omitting that package's source rule from a consumer's partial closure.
    run({"build", "-j1", "provider"})
    local output = run({"build", "-j1", "all"})
    local _, count = output:gsub("BSC_TRACE START target=provider job=provider/bluespec/sim/package/Child phase=package%-sim", "")
    assert(count == 1, "sim consumers did not share one provider package job: " .. output)
    assert(not output:match("BSC_TRACE ARGV%[%d+%]=%-u[\r\n]"), "backend recompiles an opaque closure")
    for _, target in ipairs({"sim_a", "sim_b"}) do
        assert(run({"run", target}):find("BOUNDARY_OK", 1, true), "simulation did not execute")
    end
    -- The library's default is 1. A provided-root endpoint must elaborate its
    -- own configuration, and link its private .ba ahead of the provider's.
    assert(run({"run", "shared_root"}):find("ROOT_VALUE=2", 1, true),
        "provided-root endpoint linked the library's default elaboration")
    local shared_filelist = one("Verilog/shared_root_rtl.f")
    local shared_rtl = assert(io.readfile(shared_filelist))
    assert(shared_rtl:find("/shared_root_rtl/mkChild.v", 1, true) and
        shared_rtl:find("/shared_root_rtl/mkProviderTop.v", 1, true),
        "provided-root endpoint lost its public synthesized closure")
    local public_child = public_rtl(true)
    local ba = one("**/packages/sim/Child/mkChild.ba")
    local child_rtl = one("**/packages/verilog/Child/rtl/mkChild.v")
    cache_hit()

    -- A surviving .bo is insufficient: consumers need the synthesized child.
    os.rm(ba)
    run({"build", "-j1", "all"})
    assert(os.isfile(ba), "missing provider .ba was not restored")
    cache_hit()
    os.rm(child_rtl)
    run({"build", "-j1", "all"})
    assert(os.isfile(child_rtl), "missing private provider RTL was not restored")
    public_rtl(true)
    cache_hit()
    os.rm(public_child)
    run({"build", "-j1", "all"})
    public_rtl(true)
    cache_hit()

    -- Endpoint roots have no package compile job: their direct source and
    -- include inputs must still invalidate the private top elaboration.
    local top = path.join(project, "src/consumer/Top.bsv")
    local include = path.join(project, "src/consumer/Value.bsvh")
    os.sleep(1100)
    io.writefile(include, "`define FINISH_COUNT 4\n")
    local include_changed = run({"build", "-j1", "all"})
    assert(not include_changed:find("compiling Bluespec package Child", 1, true),
        "endpoint include rebuilt a provider package")
    assert(run({"run", "sim_a"}):find("BOUNDARY_OK count=4", 1, true),
        "endpoint include change did not reach the executable")
    cache_hit()
    os.sleep(1100)
    local updated = assert(io.readfile(top)):gsub("BOUNDARY_OK", "BOUNDARY_UPDATED")
    io.writefile(top, updated)
    run({"build", "-j1", "all"})
    assert(run({"run", "sim_a"}):find("BOUNDARY_UPDATED count=4", 1, true),
        "endpoint source change did not reach the executable")
    cache_hit()

    -- Remove the synthesized boundary while keeping the same package/module.
    -- No stale private child may leak back into the public consumer filelist.
    local source = path.join(project, "src/provider/Child.bsv")
    local contents = assert(io.readfile(source))
    contents = contents:gsub('%(%* synthesize %*%)', "")
        :gsub('%(%* execution_order = "req, advance" %*%)', "")
    io.writefile(source, contents)
    run({"build", "-j1", "all"})
    assert(not os.isfile(ba) and not os.isfile(child_rtl), "stale private synthesis outputs survived")
    assert(not os.isfile(public_child), "stale public synthesized module survived")
    public_rtl(false)
    cache_hit()

    -- Seeing a provider's source dir during scanning must not export a
    -- neighboring package that the library never owned. It is outside the
    -- consumer's own source dirs, so accepting it would leak private sources.
    io.writefile(path.join(project, "src/provider/Hidden.bsv"),
        "package Hidden; function Bit#(1) hiddenValue = 1; endpackage\n")
    io.writefile(top, (assert(io.readfile(top)):gsub(
        "import Child::%*;", "import Child::*;\nimport Hidden::*;")))
    run({"build", "-j1", "sim_a"},
        "package Hidden is located in a dependency package directory but is not exported")

    -- Explicit public-dir ownership retains its existing stricter guardian,
    -- even if the consumer also declares that directory as a source path.
    os.cp(path.join(root, "tests/cases/unexported_package"), work)
    project = path.join(work, "unexported_package")
    run({"config", "-c", "-y", "--bluespec_backend_jobs=1", "--bluespec_bsc_jobs=1",
        "--bluespec_scan_jobs=1"})
    run({"build", "-j1", "consumer"},
        "package Hidden is located in a dependency package directory but is not exported")
    os.rm(work)
    print("Bluespec synthesis boundary checks passed")
end
