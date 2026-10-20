-- Real SystemC integration. Supply the SDK through the ordinary compiler/link
-- environment (for example CPLUS_INCLUDE_PATH and LIBRARY_PATH), not a mock.
function main()
    local root = path.absolute(path.join(os.scriptdir(), ".."))
    local work = os.tmpfile() .. "-systemc-isolation"
    os.mkdir(work)
    os.cp(path.join(root, "tests/cases/systemc_isolation"), work)
    local project = path.join(work, "systemc_isolation")
    local sequence = 0
    local function run(arguments)
        sequence = sequence + 1
        local stdout = path.join(work, tostring(sequence) .. ".out")
        local stderr = path.join(work, tostring(sequence) .. ".err")
        local command = {arguments[1], "-P", project}
        for index = 2, #arguments do table.insert(command, arguments[index]) end
        local code = os.execv(os.programfile(), command, {
            curdir = project, envs = {BLUESPEC_XMAKE_ROOT = root},
            stdout = stdout, stderr = stderr, try = true,
        })
        local output = (io.readfile(stdout) or "") .. (io.readfile(stderr) or "")
        assert(code == 0, "SystemC isolation failed; logs in " .. work .. "\n" .. output)
        return output
    end
    local function behavior()
        local output = run({"run", "consumer"})
        assert(output:find("First: 7, second: 41", 1, true), "wrong SystemC models: " .. output)
    end
    local function cache_hit()
        local output = run({"build", "-j1", "consumer"})
        for _, message in ipairs({"scanning Bluespec", "compiling", "building Bluespec", "linking"}) do
            assert(not output:find(message, 1, true), "unchanged SystemC build: " .. output)
        end
    end
    run({"config", "-c", "-y", "--bluespec_backend_jobs=1", "--bluespec_bsc_jobs=1",
        "--bluespec_scan_jobs=1"})
    run({"build", "-j1", "consumer"})
    behavior()
    cache_hit()

    -- A shared child header must coexist in one translation unit, and
    -- changing archive/include order must not select the other model.
    local source = path.join(project, "consumer.cc")
    local contents = assert(io.readfile(source)):gsub(
        '#include "mkFirst_systemc.h"\n#include "mkSecond_systemc.h"',
        '#include "mkSecond_systemc.h"\n#include "mkFirst_systemc.h"')
    io.writefile(source, contents)
    local projectfile = path.join(project, "xmake.lua")
    contents = assert(io.readfile(projectfile)):gsub(
        'add_deps%("first", "second"%)', 'add_deps("second", "first")')
    io.writefile(projectfile, contents)
    run({"config", "-c", "-y"})
    run({"build", "-j1", "consumer"})
    behavior()
    cache_hit()
    os.rm(work)
    print("Bluespec SystemC model isolation checks passed")
end
