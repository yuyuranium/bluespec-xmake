-- Real BSC/Bluetcl: backend demand is independent of source equality and
-- includes transitive providers with distinct explicit compile contexts.
function main()
    local root = path.absolute(path.join(os.scriptdir(), ".."))
    local work = os.tmpfile() .. "-package-demand"
    os.mkdir(work)
    os.cp(path.join(root, "tests/cases/package_demand"), work)
    local project = path.join(work, "package_demand")
    local sequence = 0
    local function run(arguments)
        sequence = sequence + 1
        local stdout = path.join(work, sequence .. ".out")
        local stderr = path.join(work, sequence .. ".err")
        local command = {arguments[1], "-P", project}
        for index = 2, #arguments do table.insert(command, arguments[index]) end
        local code = os.execv(os.programfile(), command, {
            curdir = project, envs = {BLUESPEC_XMAKE_ROOT = root},
            stdout = stdout, stderr = stderr, try = true,
        })
        local output = (io.readfile(stdout) or "") .. (io.readfile(stderr) or "")
        assert(code == 0, "package demand failed; logs in " .. work .. "\n" .. output)
        return output
    end
    local function configure(directory)
        run({"config", "-c", "-y", "-o", directory or "build",
            "--bluespec_backend_jobs=1", "--bluespec_bsc_jobs=2",
            "--bluespec_scan_jobs=2", "--bluespec_trace_bsc=y"})
    end
    local function build(target)
        return run({"build", "-j2", target})
    end
    local function count(output, token, expected)
        local actual = 0
        for line in output:gmatch("[^\r\n]+") do
            if line:find("BSC_TRACE START ", 1, true) and line:find(token, 1, true) then
                actual = actual + 1
            end
        end
        assert(actual == expected, string.format("expected %d %s jobs, got %d; logs in %s\n%s",
            expected, token, actual, work, output))
    end
    local function quiet(target)
        local output = build(target)
        for _, message in ipairs({"scanning Bluespec", "compiling Bluespec", "building Bluespec"}) do
            assert(not output:find(message, 1, true), "cache miss: " .. output)
        end
    end
    local function behavior()
        for _, test in ipairs({{"sim_a", 7}, {"sim_a2", 7}, {"sim_b", 41}}) do
            assert(run({"run", test[1]}):find("VALUE=" .. test[2], 1, true),
                "provider contexts were merged for " .. test[1])
        end
    end

    configure()
    -- Default selection is the ordinary phony aggregator, not every library.
    local cold = build(nil)
    count(cold, "phase=package ", 0)
    count(cold, "phase=package-sim ", 4)
    count(cold, "job=leaf_a/bluespec/sim/package/Leaf ", 1)
    count(cold, "job=lib_a/bluespec/sim/package/Lib ", 1)
    behavior()
    quiet("sims")

    os.sleep(1100)
    local leaf = path.join(project, "leaf/Leaf.bsv")
    io.writefile(leaf, assert(io.readfile(leaf)) .. "\n// changed source input\n")
    local changed = build("sims")
    count(changed, "phase=package ", 0)
    count(changed, "phase=package-sim ", 4)
    behavior()
    quiet("sims")

    local mixed = build("mixed")
    count(mixed, "phase=package ", 3) -- Leaf, Lib, Check
    count(mixed, "phase=package-sim ", 0) -- SystemC reuses sim providers
    count(mixed, "phase=package-verilog ", 2)
    behavior()
    quiet("mixed")

    -- Explicitly requesting a library retains neutral validation semantics.
    local library = build("lib_b")
    count(library, "phase=package ", 2)
    count(library, "phase=package-sim ", 0)
    quiet("lib_b")

    configure("alt-build")
    local model = build("model")
    count(model, "phase=package ", 0)
    count(model, "phase=package-sim ", 2)
    quiet("model")
    local relocated = build("mixed")
    count(relocated, "phase=package ", 3)
    count(relocated, "phase=package-sim ", 2) -- only context b is new
    count(relocated, "phase=package-verilog ", 2)
    behavior()
    quiet("mixed")
    configure("build")
    quiet("mixed")
    configure("fresh-mixed")
    local fresh = build("mixed")
    count(fresh, "phase=package ", 3)
    count(fresh, "phase=package-sim ", 4)
    count(fresh, "phase=package-verilog ", 2)
    behavior()
    quiet("mixed")
    -- All/group selection goes through the same Xmake selector as build.
    quiet("-a")
    local grouped = run({"build", "-j2", "-g", "endpoints"})
    count(grouped, "phase=package ", 0)
    os.rm(work)
    print("Bluespec consumer package demand checks passed")
end
