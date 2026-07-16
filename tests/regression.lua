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

local function assert_bluespec_cache_hit(output, context)
    for _, message in ipairs({"scanning Bluespec", "compiling Bluespec package", "building Bluespec"}) do
        assert_not_contains(output, message, context)
    end
end

local function assert_file(pattern, context)
    local files = os.files(pattern)
    if #files == 0 then
        raise("%s: no file matched %s", context, pattern)
    end
    return files
end

local function assert_single_file(pattern, context)
    local files = assert_file(pattern, context)
    if #files ~= 1 then
        raise("%s: expected one file matching %s, got %d", context, pattern, #files)
    end
    return files[1]
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
    assert_contains(first, "compiling Bluespec package Leaf", "initial package build")
    assert_contains(first, "compiling Bluespec package Other", "initial package build")
    assert_contains(first, "compiling Bluespec package Base", "initial package build")
    assert_contains(first, "compiling Bluespec package Consumer", "initial package build")
    local root_outputs = assert_file(path.join(projectdir, "build", "**", "packages", "Base.bo"),
        "provider package artifact")
    if #root_outputs ~= 1 then
        raise("provider package was compiled into %d output directories; expected exactly one", #root_outputs)
    end
    assert_file(path.join(projectdir, "build", "**", "packages", "Consumer.bo"),
        "consumer package artifact")
    local old_leaf_bo = assert_single_file(path.join(projectdir, "build", "**", "packages", "Leaf.bo"),
        "leaf package artifact")
    local old_other_bo = assert_single_file(path.join(projectdir, "build", "**", "packages", "Other.bo"),
        "unrelated package artifact")

    local initial_rtl = run(projectdir, {"build", "rtl"}, {context = "initial incremental backend"})
    assert_contains(initial_rtl, "scanning Bluespec rtl", "initial incremental backend")
    assert_contains(initial_rtl, "compiling Bluespec package Top", "initial incremental backend")
    assert_contains(initial_rtl, "building Bluespec verilog rtl", "initial incremental backend")

    local cached = run(projectdir, {"build", "consumer"}, {context = "cache-hit build"})
    for _, message in ipairs({"scanning Bluespec", "compiling Bluespec package", "building Bluespec"}) do
        assert_not_contains(cached, message, "cache-hit build")
    end
    local cached_rtl = run(projectdir, {"build", "rtl"}, {context = "cache-hit incremental backend"})
    assert_bluespec_cache_hit(cached_rtl, "cache-hit incremental backend")

    local leaf = path.join(projectdir, "src", "library", "Leaf.bsv")
    os.sleep(1100)
    io.writefile(leaf, [[package Leaf;

function Integer leafValue();
    return 2;
endfunction

endpackage
]])
    local changed = run(projectdir, {"build", "rtl"}, {context = "source invalidation"})
    assert_contains(changed, "scanning Bluespec library", "source invalidation")
    assert_contains(changed, "compiling Bluespec package Leaf", "source invalidation")
    assert_contains(changed, "compiling Bluespec package Base", "source invalidation")
    assert_contains(changed, "compiling Bluespec package Top", "source invalidation")
    assert_contains(changed, "building Bluespec verilog rtl", "source invalidation")
    assert_not_contains(changed, "compiling Bluespec package Other", "source invalidation")

    local consumer_changed = run(projectdir, {"build", "consumer"}, {context = "provider invalidation"})
    assert_contains(consumer_changed, "scanning Bluespec consumer", "provider invalidation")
    assert_contains(consumer_changed, "compiling Bluespec package Consumer", "provider invalidation")
    assert_not_contains(consumer_changed, "compiling Bluespec package Leaf", "provider invalidation")
    assert_not_contains(consumer_changed, "compiling Bluespec package Base", "provider invalidation")
    assert_not_contains(consumer_changed, "compiling Bluespec package Other", "provider invalidation")

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
    assert_contains(import_changed, "compiling Bluespec package Consumer", "dynamic import invalidation")
    assert_not_contains(import_changed, "compiling Bluespec package Leaf", "dynamic import invalidation")
    assert_not_contains(import_changed, "compiling Bluespec package Other", "dynamic import invalidation")
    assert_file(path.join(projectdir, "build", "**", "packages", "Added.bo"),
        "dynamic import package artifact")
    if os.isfile(old_leaf_bo) or os.isfile(old_other_bo) then
        raise("removed packages left stale .bo artifacts after the import graph changed")
    end

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

    local cached = run(projectdir, {"build", "generated"}, {context = "generated BSV cache hit"})
    assert_not_contains(cached, "generating Generated.bsv", "generated BSV cache hit")
    assert_bluespec_cache_hit(cached, "generated BSV cache hit")

    local spec = path.join(projectdir, "src", "generator", "spec.txt")
    os.sleep(1100)
    io.writefile(spec, "import\n")
    local import_added = run(projectdir, {"build", "generated"}, {context = "generated import addition"})
    assert_contains(import_added, "generating Generated.bsv", "generated import addition")
    assert_contains(import_added, "scanning Bluespec generated", "generated import addition")
    assert_contains(import_added, "compiling Bluespec package Extra", "generated import addition")
    assert_contains(import_added, "compiling Bluespec package Generated", "generated import addition")
    local extra_bo = assert_single_file(path.join(projectdir, "build", "**", "packages", "Extra.bo"),
        "generated dependency artifact")

    local import_cached = run(projectdir, {"build", "generated"}, {context = "generated import cache hit"})
    assert_not_contains(import_cached, "generating Generated.bsv", "generated import cache hit")
    assert_bluespec_cache_hit(import_cached, "generated import cache hit")

    local projectfile = path.join(projectdir, "xmake.lua")
    local project_contents = io.readfile(projectfile) or ""
    local changed, replacements = project_contents:gsub(
        'set_values%("generated%.mode", "base"%)', 'set_values("generated.mode", "offset")')
    if replacements ~= 1 then
        raise("generated config invalidation: expected one mode setting, got %d", replacements)
    end
    os.sleep(1100)
    io.writefile(projectfile, changed)
    run(projectdir, {"config", "-c"}, {context = "reload generated config"})
    local config_changed = run(projectdir, {"build", "generated"}, {context = "generated config invalidation"})
    assert_contains(config_changed, "generating Generated.bsv", "generated config invalidation")
    assert_contains(config_changed, "scanning Bluespec generated", "generated config invalidation")
    assert_contains(config_changed, "compiling Bluespec package Generated", "generated config invalidation")
    assert_not_contains(config_changed, "compiling Bluespec package Extra", "generated config invalidation")

    os.sleep(1100)
    io.writefile(spec, "plain\n")
    local import_removed = run(projectdir, {"build", "generated"}, {context = "generated import removal"})
    assert_contains(import_removed, "generating Generated.bsv", "generated import removal")
    assert_contains(import_removed, "scanning Bluespec generated", "generated import removal")
    assert_contains(import_removed, "compiling Bluespec package Generated", "generated import removal")
    assert_not_contains(import_removed, "compiling Bluespec package Extra", "generated import removal")
    if os.isfile(extra_bo) then
        raise("generated import removal left stale Extra.bo")
    end

    local final_cached = run(projectdir, {"build", "generated"}, {context = "generated final cache hit"})
    assert_not_contains(final_cached, "generating Generated.bsv", "generated final cache hit")
    assert_bluespec_cache_hit(final_cached, "generated final cache hit")
end

local function test_defines(root, workroot, run)
    local projectdir = copy_case(root, workroot, "defines")
    configure(run, projectdir)

    local first = run(projectdir, {"build", "define-repro"}, {context = "initial define build"})
    assert_contains(first, "scanning Bluespec define-lib", "initial define build")
    assert_contains(first, "scanning Bluespec define-repro", "initial define build")
    assert_contains(first, "compiling Bluespec package DefineLib", "initial define build")
    assert_contains(first, "compiling Bluespec package DefineRepro", "initial define build")
    assert_contains(first, "building Bluespec verilog define-repro", "initial define build")

    local cached = run(projectdir, {"build", "define-repro"}, {context = "cached define build"})
    for _, message in ipairs({"scanning Bluespec", "compiling Bluespec package", "building Bluespec"}) do
        assert_not_contains(cached, message, "cached define build")
    end

    local projectfile = path.join(projectdir, "xmake.lua")
    local contents = io.readfile(projectfile)
    if not contents then
        raise("define invalidation: could not read %s", projectfile)
    end
    local changed, replacements = contents:gsub("DEPTH=128", "DEPTH=256")
    if replacements ~= 1 then
        raise("define invalidation: expected one DEPTH=128 occurrence, got %d", replacements)
    end
    os.sleep(1100)
    io.writefile(projectfile, changed)

    local rebuilt = run(projectdir, {"build", "define-repro"}, {context = "define invalidation"})
    assert_contains(rebuilt, "scanning Bluespec define-lib", "define invalidation")
    assert_contains(rebuilt, "scanning Bluespec define-repro", "define invalidation")
    assert_contains(rebuilt, "compiling Bluespec package DefineLib", "define invalidation")
    assert_contains(rebuilt, "compiling Bluespec package DefineRepro", "define invalidation")
    assert_contains(rebuilt, "building Bluespec verilog define-repro", "define invalidation")

    local cached_again = run(projectdir, {"build", "define-repro"}, {context = "changed define cache hit"})
    for _, message in ipairs({"scanning Bluespec", "compiling Bluespec package", "building Bluespec"}) do
        assert_not_contains(cached_again, message, "changed define cache hit")
    end
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

local function test_native_bdpi_builddir(root, workroot, run)
    local projectdir = copy_case(root, workroot, "native_bdpi")
    configure(run, projectdir)

    local initial = run(projectdir, {"build", "-v", "native_bdpi"}, {context = "native BDPI build"})
    assert_contains(initial, "scanning Bluespec native_bdpi", "native BDPI build")
    assert_contains(initial, "compiling Bluespec package NativeBDPI", "native BDPI build")
    assert_contains(initial, "building Bluespec bluesim native_bdpi", "native BDPI build")
    assert_contains(initial, "-Wl,--whole-archive", "native BDPI forced load")
    assert_contains(initial, "-fPIC", "native BDPI PIC build")

    local builddir = path.join(projectdir, "build")
    local old_bo = assert_single_file(path.join(builddir, "**", "packages", "NativeBDPI.bo"),
        "default builddir package")
    local old_golden = assert_single_file(path.join(builddir, "**", "libgolden.a"),
        "direct native archive")
    local old_helper = assert_single_file(path.join(builddir, "**", "libgolden_helper.a"),
        "transitive native archive")
    local old_executable = path.join(builddir, "bin", "native_bdpi")
    assert_file(old_executable, "default builddir Bluesim executable")
    assert_file(old_executable .. ".so", "default builddir Bluesim model")
    if old_golden == old_helper then
        raise("native BDPI closure unexpectedly collapsed two archives into one path")
    end

    local run_output = run(projectdir, {"run", "native_bdpi"}, {context = "run native BDPI"})
    assert_contains(run_output, "OK", "run native BDPI")
    local cached = run(projectdir, {"build", "native_bdpi"}, {context = "cached native BDPI build"})
    assert_bluespec_cache_hit(cached, "cached native BDPI build")

    local golden_source = path.join(projectdir, "src", "native", "golden.c")
    local golden_contents = io.readfile(golden_source)
    if not golden_contents then
        raise("native BDPI invalidation: could not read %s", golden_source)
    end
    os.sleep(1100)
    io.writefile(golden_source, golden_contents .. "\n/* force native archive rebuild */\n")
    local native_changed = run(projectdir, {"build", "native_bdpi"}, {context = "native BDPI invalidation"})
    assert_not_contains(native_changed, "scanning Bluespec", "native BDPI invalidation")
    assert_not_contains(native_changed, "compiling Bluespec package", "native BDPI invalidation")
    assert_contains(native_changed, "building Bluespec bluesim native_bdpi", "native BDPI invalidation")
    local changed_run = run(projectdir, {"run", "native_bdpi"}, {context = "run rebuilt native BDPI"})
    assert_contains(changed_run, "OK", "run rebuilt native BDPI")

    local old_bo_mtime = os.mtime(old_bo)
    local old_model_mtime = os.mtime(old_executable .. ".so")
    run(projectdir, {"config", "-c", "-o", "alt-build"}, {context = "configure alt builddir"})
    local alt = run(projectdir, {"build", "-v", "native_bdpi"}, {context = "alt builddir"})
    assert_contains(alt, "scanning Bluespec native_bdpi", "alt builddir")
    assert_contains(alt, "compiling Bluespec package NativeBDPI", "alt builddir")
    assert_contains(alt, "building Bluespec bluesim native_bdpi", "alt builddir")
    assert_not_contains(alt, path.directory(old_bo), "alt builddir package command")

    local alt_builddir = path.join(projectdir, "alt-build")
    local alt_bo = assert_single_file(path.join(alt_builddir, "**", "packages", "NativeBDPI.bo"),
        "alt builddir package")
    assert_single_file(path.join(alt_builddir, "**", "libgolden.a"), "alt direct native archive")
    assert_single_file(path.join(alt_builddir, "**", "libgolden_helper.a"), "alt transitive native archive")
    assert_single_file(path.join(alt_builddir, "**", "bluesim", "model_mkNativeBDPI.cxx"),
        "alt Bluesim generated source")
    assert_single_file(path.join(alt_builddir, "**", "bluesim", "model_mkNativeBDPI.o"),
        "alt Bluesim generated object")
    local alt_executable = path.join(alt_builddir, "bin", "native_bdpi")
    assert_file(alt_executable, "alt Bluesim executable")
    assert_file(alt_executable .. ".so", "alt Bluesim model")
    if os.mtime(old_bo) ~= old_bo_mtime or os.mtime(old_executable .. ".so") ~= old_model_mtime then
        raise("alt builddir unexpectedly rewrote artifacts in the default builddir")
    end
    if path.normalize(path.directory(alt_bo)) == path.normalize(path.directory(old_bo)) then
        raise("alt builddir reused the default package output directory")
    end
    local alt_run = run(projectdir, {"run", "native_bdpi"}, {context = "run alt native BDPI"})
    assert_contains(alt_run, "OK", "run alt native BDPI")
    local alt_cached = run(projectdir, {"build", "native_bdpi"}, {context = "cached alt builddir"})
    assert_bluespec_cache_hit(alt_cached, "cached alt builddir")

    run(projectdir, {"config", "-c", "-o", "build"}, {context = "restore default builddir"})
    local restored = run(projectdir, {"build", "-v", "native_bdpi"}, {context = "restored builddir"})
    assert_not_contains(restored, path.directory(alt_bo), "restored builddir package command")
    assert_file(old_bo, "restored default package")
    assert_file(old_executable, "restored default executable")
    assert_file(old_executable .. ".so", "restored default model")
    local restored_run = run(projectdir, {"run", "native_bdpi"}, {context = "run restored native BDPI"})
    assert_contains(restored_run, "OK", "run restored native BDPI")
    local restored_cached = run(projectdir, {"build", "native_bdpi"}, {context = "cached restored builddir"})
    assert_bluespec_cache_hit(restored_cached, "cached restored builddir")
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
        {"valued/valueless defines", function() test_defines(root, workroot, run) end},
        {"Bluesim/Verilog backends", function() test_backends(root, workroot, run) end},
        {"native BDPI/builddir isolation", function() test_native_bdpi_builddir(root, workroot, run) end},
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
