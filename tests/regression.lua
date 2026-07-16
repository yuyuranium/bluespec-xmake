local function strip_ansi(text)
    return (text or ""):gsub("\27%[[%d;]*m", "")
end

local function assert_contains(text, expected, context)
    if not text:find(expected, 1, true) then
        raise("%s: expected output to contain %q\n%s", context, expected, text)
    end
end

local function assert_not_contains(text, unexpected, context)
    if text:find(unexpected, 1, true) then
        raise("%s: output unexpectedly contains %q\n%s", context, unexpected, text)
    end
end

local function assert_file(pattern, context)
    local files = os.files(pattern)
    if #files == 0 then
        raise("%s: no file matched %s", context, pattern)
    end
    return files
end

local function copy_case(root, workroot, name)
    local source = path.join(root, "tests", "cases", name)
    local destination = path.join(workroot, name)
    os.mkdir(workroot)
    os.cp(source, workroot)
    if not os.isdir(destination) then
        raise("failed to copy regression case %s to %s", name, destination)
    end
    return destination
end

local function runner(root, workroot)
    local sequence = 0
    return function(projectdir, arguments, opt)
        opt = opt or {}
        local project_arguments = {arguments[1], "-P", projectdir}
        for index = 2, #arguments do
            table.insert(project_arguments, arguments[index])
        end
        arguments = project_arguments
        sequence = sequence + 1
        local logdir = path.join(workroot, "logs")
        os.mkdir(logdir)
        local basename = string.format("%03d-%s", sequence, path.basename(projectdir))
        local stdout = path.join(logdir, basename .. ".out")
        local stderr = path.join(logdir, basename .. ".err")
        local code, errors = os.execv(os.programfile(), arguments, {
            curdir = projectdir,
            envs = {BLUESPEC_XMAKE_ROOT = root},
            stdout = stdout,
            stderr = stderr,
            try = true,
        })
        local output = strip_ansi((io.readfile(stdout) or "") .. (io.readfile(stderr) or ""))
        if opt.fail then
            if code == 0 then
                raise("%s unexpectedly succeeded\n%s", opt.context or table.concat(arguments, " "), output)
            end
        elseif code ~= 0 then
            raise("%s failed (%s)\n%s\n%s", opt.context or table.concat(arguments, " "),
                tostring(code), output, tostring(errors or ""))
        end
        return output
    end
end

local function configure(run, projectdir)
    run(projectdir, {"config", "-c"}, {context = "configure " .. path.basename(projectdir)})
end

local function test_incremental(root, workroot, run)
    local projectdir = copy_case(root, workroot, "incremental")
    configure(run, projectdir)

    local first = run(projectdir, {"build", "consumer"}, {context = "initial package build"})
    assert_contains(first, "scanning Bluespec library", "initial package build")
    assert_contains(first, "compiling Bluespec package Base", "initial package build")
    assert_contains(first, "compiling Bluespec package Consumer", "initial package build")
    local root_outputs = assert_file(path.join(projectdir, "build", "**", "packages", "Base.bo"),
        "provider package artifact")
    if #root_outputs ~= 1 then
        raise("provider package was compiled into %d output directories; expected exactly one", #root_outputs)
    end
    assert_file(path.join(projectdir, "build", "**", "packages", "Consumer.bo"),
        "consumer package artifact")

    local cached = run(projectdir, {"build", "consumer"}, {context = "cache-hit build"})
    for _, message in ipairs({"scanning Bluespec", "compiling Bluespec package", "building Bluespec"}) do
        assert_not_contains(cached, message, "cache-hit build")
    end

    local leaf = path.join(projectdir, "src", "library", "Leaf.bsv")
    os.sleep(1100)
    io.writefile(leaf, [[package Leaf;

function Integer leafValue();
    return 2;
endfunction

endpackage
]])
    local changed = run(projectdir, {"build", "consumer"}, {context = "source invalidation"})
    assert_contains(changed, "scanning Bluespec library", "source invalidation")
    assert_contains(changed, "compiling Bluespec package Leaf", "source invalidation")
    assert_contains(changed, "compiling Bluespec package Base", "source invalidation")
    assert_contains(changed, "compiling Bluespec package Consumer", "source invalidation")

    local base = path.join(projectdir, "src", "library", "Base.bsv")
    os.sleep(1100)
    io.writefile(base, [[package Base;

import Added::*;

function Integer baseValue();
    return addedValue();
endfunction

endpackage
]])
    local import_changed = run(projectdir, {"build", "consumer"}, {context = "dynamic import invalidation"})
    assert_contains(import_changed, "scanning Bluespec library", "dynamic import invalidation")
    assert_contains(import_changed, "compiling Bluespec package Added", "dynamic import invalidation")
    assert_contains(import_changed, "compiling Bluespec package Base", "dynamic import invalidation")
    assert_file(path.join(projectdir, "build", "**", "packages", "Added.bo"),
        "dynamic import package artifact")

    local cached_again = run(projectdir, {"build", "consumer"}, {context = "post-invalidation cache hit"})
    assert_not_contains(cached_again, "scanning Bluespec", "post-invalidation cache hit")
    assert_not_contains(cached_again, "compiling Bluespec package", "post-invalidation cache hit")
end

local function test_generated(root, workroot, run)
    local projectdir = copy_case(root, workroot, "generated")
    configure(run, projectdir)
    local output = run(projectdir, {"build", "generated"}, {context = "generated BSV build"})
    assert_contains(output, "generating Generated.bsv", "generated BSV build")
    assert_contains(output, "scanning Bluespec generated", "generated BSV build")
    assert_contains(output, "compiling Bluespec package Generated", "generated BSV build")
    assert_file(path.join(projectdir, "build", "**", "packages", "Generated.bo"),
        "generated BSV artifact")
end

local function test_backends(root, workroot, run)
    local projectdir = copy_case(root, workroot, "backends")
    configure(run, projectdir)

    local sim = run(projectdir, {"build", "sim"}, {context = "Bluesim build"})
    assert_contains(sim, "building Bluespec bluesim sim", "Bluesim build")
    local executable = path.join(projectdir, "build", "bin", "sim")
    if not os.isfile(executable) or not os.isexec(executable) then
        raise("Bluesim executable is missing or not executable: %s", executable)
    end
    assert_file(executable .. ".so", "Bluesim shared object")
    run(projectdir, {"run", "sim"}, {context = "xmake run sim"})
    local sim_cached = run(projectdir, {"build", "sim"}, {context = "cached Bluesim build"})
    assert_not_contains(sim_cached, "building Bluespec bluesim", "cached Bluesim build")

    local rtl = run(projectdir, {"build", "rtl"}, {context = "Verilog build"})
    assert_contains(rtl, "building Bluespec verilog rtl", "Verilog build")
    local filelists = assert_file(path.join(projectdir, "build", "**", "verilog", "rtl.f"),
        "Verilog filelist")
    if #filelists ~= 1 then
        raise("Verilog build produced %d rtl.f files; expected one", #filelists)
    end
    local lines = {}
    for line in (io.readfile(filelists[1]) or ""):gmatch("[^\r\n]+") do
        if not path.is_absolute(line) then
            raise("Verilog filelist contains a non-absolute path: %s", line)
        end
        table.insert(lines, line)
    end
    if #lines == 0 then
        raise("Verilog filelist is empty: %s", filelists[1])
    end
    local sorted = table.clone(lines)
    table.sort(sorted)
    if table.concat(lines, "\n") ~= table.concat(sorted, "\n") then
        raise("Verilog filelist is not deterministically sorted: %s", filelists[1])
    end
end

local function test_cycle(root)
    local parser = import("bluespec.parser")
    local projectdir = os.projectdir()
    local a = path.join(projectdir, "A.bsv")
    local b = path.join(projectdir, "B.bsv")
    local output = table.concat({
        "A.bo: " .. a .. " B.bo",
        "B.bo: " .. b .. " A.bo",
    }, "\n")
    local errors
    local accepted = try {
        function()
            parser.parse(output, a)
            return true
        end,
        catch {
            function(parse_errors)
                errors = tostring(parse_errors)
            end,
        },
    }
    if accepted then
        raise("cycle diagnostic: parser unexpectedly accepted a package cycle")
    end
    assert_contains(errors, "circular Bluespec package dependency detected", "cycle diagnostic")
end

local function test_failure(root, workroot, run, name, expected)
    local projectdir = copy_case(root, workroot, name)
    configure(run, projectdir)
    local output = run(projectdir, {"build", "consumer"}, {fail = true, context = name})
    assert_contains(output, expected, name)
end

function main()
    local root = os.projectdir()
    local workroot = path.join(root, "build", "regression")
    os.rm(workroot)
    os.mkdir(workroot)
    local run = runner(root, workroot)
    local tests = {
        {"incremental graph/cache", function() test_incremental(root, workroot, run) end},
        {"generated BSV", function() test_generated(root, workroot, run) end},
        {"Bluesim/Verilog backends", function() test_backends(root, workroot, run) end},
        {"cycle diagnostic", function() test_cycle(root) end},
        {"duplicate provider", function()
            test_failure(root, workroot, run, "duplicate_provider", "duplicate Bluespec package provider Dup")
        end},
        {"unexported package", function()
            test_failure(root, workroot, run, "unexported_package",
                "package Hidden is located in a dependency package directory but is not exported")
        end},
    }
    for index, item in ipairs(tests) do
        cprint("${bright}[%d/%d]${clear} %s", index, #tests, item[1])
        item[2]()
    end
    cprint("${green bright}all %d bluespec-xmake regression tests passed", #tests)
end
