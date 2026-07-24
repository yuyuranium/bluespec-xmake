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

local function assert_verilog_filelist(filelist, artifactdir, context)
    if not os.isfile(filelist) then
        raise("%s: missing Verilog filelist %s", context, filelist)
    end
    local root = path.normalize(path.absolute(artifactdir))
    local lines = {}
    for line in (io.readfile(filelist) or ""):gmatch("[^\r\n]+") do
        if not path.is_absolute(line) then
            raise("%s: Verilog filelist contains a non-absolute path: %s", context, line)
        end
        local normalized = path.normalize(line)
        if normalized ~= root and normalized:sub(1, #root + 1) ~= root .. "/" then
            raise("%s: Verilog artifact is outside public directory %s: %s", context, root, normalized)
        end
        table.insert(lines, normalized)
    end
    if #lines == 0 then
        raise("%s: Verilog filelist is empty: %s", context, filelist)
    end
    local sorted = table.clone(lines)
    table.sort(sorted)
    if table.concat(lines, "\n") ~= table.concat(sorted, "\n") then
        raise("%s: Verilog filelist is not deterministically sorted: %s", context, filelist)
    end
    return lines
end

local function artifact_contents(files, context)
    local contents = {}
    for _, file in ipairs(files or {}) do
        table.insert(contents, assert(io.readfile(file), context .. ": missing artifact " .. file))
    end
    return table.concat(contents, "\n")
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
        if os.host() == "macosx" and arguments[1] == "config" then
            arguments = table.clone(arguments)
            local defaults = {
                toolchain = "xcode",
                cc = "/usr/bin/clang",
                cxx = "/usr/bin/clang++",
                ld = "/usr/bin/clang++",
                sh = "/usr/bin/clang++",
            }
            for name, value in pairs(defaults) do
                local prefix = "--" .. name .. "="
                local configured = false
                for _, argument in ipairs(arguments) do
                    if tostring(argument):find(prefix, 1, true) == 1 then
                        configured = true
                        break
                    end
                end
                if not configured then
                    table.insert(arguments, prefix .. value)
                end
            end
        end
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
        local envs = {BLUESPEC_XMAKE_ROOT = root}
        for name, value in pairs(opt.envs or {}) do
            envs[name] = value
        end
        local code, errors = os.execv(os.programfile(), arguments, {
            curdir = opt.curdir or projectdir,
            envs = envs,
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

local configure

local function test_path_relative(root, workroot, run)
    local projectdir = copy_case(root, workroot, "path_relative")
    local outside = path.join(workroot, "path-relative-cwd")
    local wrapper_cwd = path.join(workroot, "path-relative-wrapper-cwd")
    os.mkdir(outside)
    os.mkdir(wrapper_cwd)
    configure(run, projectdir)

    local initial = run(projectdir, {"build", "relative"}, {
        curdir = outside,
        context = "declaration-relative standalone build",
    })
    assert_contains(initial, "scanning Bluespec relative", "declaration-relative standalone build")
    assert_contains(initial, "compiling Bluespec package Helper", "declaration-relative standalone build")
    assert_contains(initial, "compiling Bluespec package Root", "declaration-relative standalone build")
    assert_file(path.join(outside, "build", "**", "bdir", "Root.bo"),
        "declaration-relative standalone root artifact")

    local absolute = run(projectdir, {"build", "absolute"}, {
        curdir = outside,
        context = "absolute Bluespec root build",
    })
    assert_contains(absolute, "scanning Bluespec absolute", "absolute Bluespec root build")
    assert_contains(absolute, "compiling Bluespec package Helper", "absolute Bluespec root build")
    assert_contains(absolute, "compiling Bluespec package Root", "absolute Bluespec root build")

    local cached = run(projectdir, {"build", "relative"}, {
        curdir = outside,
        context = "declaration-relative cache hit",
    })
    assert_bluespec_cache_hit(cached, "declaration-relative cache hit")

    local helper = path.join(projectdir, "nested", "packages", "Helper.bsv")
    os.sleep(1100)
    io.writefile(helper, [[package Helper;

function Integer helperValue();
    return 43;
endfunction

endpackage
]])
    local source_changed = run(projectdir, {"build", "relative"}, {
        curdir = outside,
        context = "declaration-relative source invalidation",
    })
    assert_contains(source_changed, "scanning Bluespec relative", "declaration-relative source invalidation")
    assert_contains(source_changed, "compiling Bluespec package Helper",
        "declaration-relative source invalidation")
    assert_contains(source_changed, "compiling Bluespec package Root",
        "declaration-relative source invalidation")

    local extra = path.join(projectdir, "nested", "packages", "Extra.bsv")
    os.sleep(1100)
    io.writefile(extra, [[package Extra;
endpackage
]])
    local directory_changed = run(projectdir, {"build", "relative"}, {
        curdir = outside,
        context = "declaration-relative package directory invalidation",
    })
    assert_contains(directory_changed, "scanning Bluespec relative",
        "declaration-relative package directory invalidation")
    assert_bluespec_cache_hit(run(projectdir, {"build", "relative"}, {
        curdir = outside,
        context = "declaration-relative post-directory cache hit",
    }), "declaration-relative post-directory cache hit")

    local wrapper = path.join(projectdir, "wrapper")
    configure(run, wrapper)
    local wrapped = run(wrapper, {"build", "relative"}, {
        curdir = wrapper_cwd,
        context = "nested include declaration-relative build",
    })
    assert_contains(wrapped, "scanning Bluespec relative", "nested include declaration-relative build")
    assert_contains(wrapped, "compiling Bluespec package Helper", "nested include declaration-relative build")
    assert_contains(wrapped, "compiling Bluespec package Root", "nested include declaration-relative build")
    local wrapper_root = assert_single_file(path.join(wrapper_cwd, "build", "**", "bdir", "Root.bo"),
        "nested include root artifact")
    local wrapper_cached = run(wrapper, {"build", "relative"}, {
        curdir = wrapper_cwd,
        context = "nested include declaration-relative cache hit",
    })
    assert_bluespec_cache_hit(wrapper_cached, "nested include declaration-relative cache hit")

    run(wrapper, {"config", "-c", "-o", "alt-build"}, {
        curdir = wrapper_cwd,
        context = "declaration-relative alternate builddir configuration",
    })
    local alternate = run(wrapper, {"build", "relative"}, {
        curdir = wrapper_cwd,
        context = "declaration-relative alternate builddir",
    })
    assert_contains(alternate, "scanning Bluespec relative", "declaration-relative alternate builddir")
    assert_file(path.join(wrapper_cwd, "alt-build", "**", "bdir", "Root.bo"),
        "declaration-relative alternate root artifact")
    if not os.isfile(wrapper_root) then
        raise("alternate declaration-relative build removed the default artifact")
    end
end

configure = function(run, projectdir)
    local args = {"config", "-c"}
    run(projectdir, args, {context = "configure " .. path.basename(projectdir)})
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
    local root_outputs = assert_file(path.join(projectdir, "build", "**", "bdir", "Base.bo"),
        "provider package artifact")
    if #root_outputs ~= 1 then
        raise("provider package was compiled into %d output directories; expected exactly one", #root_outputs)
    end
    assert_file(path.join(projectdir, "build", "**", "bdir", "Consumer.bo"),
        "consumer package artifact")
    local old_leaf_bo = assert_single_file(path.join(projectdir, "build", "**", "bdir", "Leaf.bo"),
        "leaf package artifact")
    local old_other_bo = assert_single_file(path.join(projectdir, "build", "**", "bdir", "Other.bo"),
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

    -- A successful package compile leaves a private output-stamp marker.  A
    -- truncated .bo no longer matching that stamp is discarded by its owner
    -- before dependent scans/builds, avoiding BinData.getB on mixed state.
    io.writefile(old_leaf_bo, "truncated\n")
    local recovered = run(projectdir, {"build", "consumer"}, {context = "truncated .bo recovery"})
    assert_contains(recovered, "compiling Bluespec package Leaf", "truncated .bo recovery")
    assert_contains(recovered, "compiling Bluespec package Base", "truncated .bo recovery")
    assert_contains(recovered, "compiling Bluespec package Consumer", "truncated .bo recovery")
    assert_not_contains(recovered, "BinData.getB", "truncated .bo recovery")
    assert_bluespec_cache_hit(run(projectdir, {"build", "consumer"}, {
        context = "post-recovery cache hit",
    }), "post-recovery cache hit")

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
    assert_file(path.join(projectdir, "build", "**", "bdir", "Added.bo"),
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
    assert_file(path.join(projectdir, "build", "**", "bdir", "Generated.bo"),
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
    local extra_bo = assert_single_file(path.join(projectdir, "build", "**", "bdir", "Extra.bo"),
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

local function test_option_groups(root, workroot, run)
    local projectdir = copy_case(root, workroot, "options")
    configure(run, projectdir)

    local first = run(projectdir, {"build", "-v", "consumer"}, {context = "multi-token BSC options"})
    assert_contains(first, "scanning Bluespec option-lib", "multi-token BSC options")
    assert_contains(first, "scanning Bluespec consumer", "multi-token BSC options")
    assert_contains(first, "compiling Bluespec package Lib", "multi-token BSC options")
    assert_contains(first, "compiling Bluespec package Consumer", "multi-token BSC options")
    assert_contains(first,
        "-steps-warn-interval 1000000 -steps-max-intervals 10000000 +RTS -K1G -RTS -check-assert -suppress-warnings G0020:S0077:S0080",
        "multi-token BSC option argv order and propagation")

    assert_bluespec_cache_hit(run(projectdir, {"build", "consumer"}, {
        context = "multi-token BSC options cache hit",
    }), "multi-token BSC options cache hit")

    local projectfile = path.join(projectdir, "xmake.lua")
    local contents = io.readfile(projectfile) or ""
    local changed, replacements = contents:gsub(
        'add_bsc_options%("%-steps%-warn%-interval", "1000000"%)',
        'add_bsc_options("-steps-warn-interval")\n    add_bsc_options("1000000")')
    if replacements ~= 1 then
        raise("multi-token BSC options: expected one option-group boundary to change, got %d", replacements)
    end
    os.sleep(1100)
    io.writefile(projectfile, changed)
    run(projectdir, {"config", "-c"}, {context = "multi-token option-group reconfigure"})
    local group_changed = run(projectdir, {"build", "consumer"}, {
        context = "multi-token option-group invalidation",
    })
    assert_contains(group_changed, "scanning Bluespec consumer", "multi-token option-group invalidation")
    assert_contains(group_changed, "compiling Bluespec package Consumer",
        "multi-token option-group invalidation")
    assert_not_contains(group_changed, "compiling Bluespec package Lib",
        "multi-token option-group invalidation")
    assert_bluespec_cache_hit(run(projectdir, {"build", "consumer"}, {
        context = "multi-token option-group cache hit",
    }), "multi-token option-group cache hit")
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
    local initial_sim_output = run(projectdir, {"run", "sim"}, {context = "xmake run sim"})
    assert_contains(initial_sim_output, "BACKEND_VALUE=1", "initial Bluesim behavior")
    local sim_ba = assert_single_file(path.join(projectdir, "build", "**", "bdir", "mkTop.ba"),
        "initial Bluesim elaboration artifact")
    local initial_sim_ba = assert(io.readfile(sim_ba), "missing initial Bluesim .ba")
    local sim_cached = run(projectdir, {"build", "sim"}, {context = "cached Bluesim build"})
    assert_not_contains(sim_cached, "building Bluespec bluesim", "cached Bluesim build")

    local rtl = run(projectdir, {"build", "rtl_consumer"}, {context = "Verilog public artifact build"})
    assert_contains(rtl, "building Bluespec verilog rtl", "Verilog build")
    local default_builddir = path.join(projectdir, "build")
    local default_filelist = path.join(default_builddir, "Verilog", "rtl.f")
    local default_rtl_dir = path.join(default_builddir, "Verilog", "rtl")
    assert_contains(rtl, "processing Verilog targetfile " .. default_filelist,
        "standard targetfile consumer")
    local initial_rtl_files = assert_verilog_filelist(default_filelist, default_rtl_dir,
        "default Verilog targetfile")
    local initial_rtl_contents = artifact_contents(initial_rtl_files, "initial Verilog behavior")
    local processed = path.join(default_builddir, "processed", "rtl.f")
    if io.readfile(processed) ~= io.readfile(default_filelist) then
        raise("downstream Xmake consumer did not process the public targetfile")
    end

    local rtl_cached = run(projectdir, {"build", "rtl_consumer"},
        {context = "cached Verilog public artifact"})
    assert_bluespec_cache_hit(rtl_cached, "cached Verilog public artifact")
    assert_not_contains(rtl_cached, "processing Verilog targetfile", "cached Verilog consumer")

    local projectfile = path.join(projectdir, "xmake.lua")
    local project_contents = assert(io.readfile(projectfile), "missing backend regression project")
    os.sleep(1100)
    local updated_project, replacements = project_contents:gsub(
        'add_bsc_defines%("BACKEND_VALUE=1"%)', 'add_bsc_defines("BACKEND_VALUE=2")')
    if replacements ~= 2 then
        raise("backend define invalidation: expected two target define settings, got %d", replacements)
    end
    io.writefile(projectfile, updated_project)
    run(projectdir, {"config", "-c"}, {context = "reload backend define"})

    local define_sim = run(projectdir, {"build", "sim"}, {context = "Bluesim define invalidation"})
    assert_contains(define_sim, "scanning Bluespec sim", "Bluesim define invalidation")
    assert_contains(define_sim, "compiling Bluespec package Top", "Bluesim define invalidation")
    assert_contains(define_sim, "building Bluespec bluesim sim", "Bluesim define invalidation")
    local changed_sim_output = run(projectdir, {"run", "sim"}, {context = "changed define xmake run sim"})
    assert_contains(changed_sim_output, "BACKEND_VALUE=2", "changed Bluesim behavior")
    assert_not_contains(changed_sim_output, "BACKEND_VALUE=1", "changed Bluesim behavior")
    if io.readfile(sim_ba) == initial_sim_ba then
        raise("Bluesim define invalidation reused the stale top .ba artifact")
    end
    local define_sim_cached = run(projectdir, {"build", "sim"},
        {context = "cached changed-define Bluesim"})
    assert_bluespec_cache_hit(define_sim_cached, "cached changed-define Bluesim")

    local define_rtl = run(projectdir, {"build", "rtl_consumer"},
        {context = "Verilog define invalidation"})
    assert_contains(define_rtl, "scanning Bluespec rtl", "Verilog define invalidation")
    assert_contains(define_rtl, "compiling Bluespec package Top", "Verilog define invalidation")
    assert_contains(define_rtl, "building Bluespec verilog rtl", "Verilog define invalidation")
    assert_contains(define_rtl, "processing Verilog targetfile " .. default_filelist,
        "Verilog define invalidation")
    local changed_rtl_files = assert_verilog_filelist(default_filelist, default_rtl_dir,
        "changed-define Verilog targetfile")
    if artifact_contents(changed_rtl_files, "changed Verilog behavior") == initial_rtl_contents then
        raise("Verilog define invalidation reused stale elaborated RTL")
    end
    local define_rtl_cached = run(projectdir, {"build", "rtl_consumer"},
        {context = "cached changed-define Verilog"})
    assert_bluespec_cache_hit(define_rtl_cached, "cached changed-define Verilog")
    assert_not_contains(define_rtl_cached, "processing Verilog targetfile",
        "cached changed-define Verilog consumer")

    local source = path.join(projectdir, "src", "Top.bsv")
    local source_contents = assert(io.readfile(source), "missing Verilog regression source")
    local old_filelist_mtime = os.mtime(default_filelist)
    os.sleep(1100)
    io.writefile(source, source_contents .. "\n// force Verilog backend invalidation\n")
    local invalidated = run(projectdir, {"build", "rtl_consumer"},
        {context = "Verilog backend invalidation"})
    assert_contains(invalidated, "scanning Bluespec rtl", "Verilog backend invalidation")
    assert_contains(invalidated, "compiling Bluespec package Top", "Verilog backend invalidation")
    assert_contains(invalidated, "building Bluespec verilog rtl", "Verilog backend invalidation")
    assert_contains(invalidated, "processing Verilog targetfile " .. default_filelist,
        "downstream Verilog invalidation")
    if os.mtime(default_filelist) == old_filelist_mtime then
        raise("Verilog backend invalidation did not update the public targetfile")
    end
    assert_verilog_filelist(default_filelist, default_rtl_dir, "invalidated Verilog targetfile")

    local default_filelist_mtime = os.mtime(default_filelist)
    local default_filelist_contents = io.readfile(default_filelist)
    run(projectdir, {"config", "-c", "-o", "alt-build"}, {context = "configure alt Verilog builddir"})
    local alt = run(projectdir, {"build", "rtl_consumer"}, {context = "alt Verilog builddir"})
    local alt_builddir = path.join(projectdir, "alt-build")
    local alt_filelist = path.join(alt_builddir, "Verilog", "rtl.f")
    local alt_rtl_dir = path.join(alt_builddir, "Verilog", "rtl")
    assert_contains(alt, "building Bluespec verilog rtl", "alt Verilog builddir")
    assert_contains(alt, "processing Verilog targetfile " .. alt_filelist,
        "alt standard targetfile consumer")
    assert_verilog_filelist(alt_filelist, alt_rtl_dir, "alt Verilog targetfile")
    if os.mtime(default_filelist) ~= default_filelist_mtime or
        io.readfile(default_filelist) ~= default_filelist_contents then
        raise("alt Verilog builddir rewrote the default public targetfile")
    end

    local alt_cached = run(projectdir, {"build", "rtl_consumer"},
        {context = "cached alt Verilog builddir"})
    assert_bluespec_cache_hit(alt_cached, "cached alt Verilog builddir")
    assert_not_contains(alt_cached, "processing Verilog targetfile", "cached alt Verilog consumer")

    run(projectdir, {"config", "-c", "-o", "build"}, {context = "restore Verilog builddir"})
    local restored = run(projectdir, {"build", "rtl_consumer"}, {context = "restored Verilog builddir"})
    assert_bluespec_cache_hit(restored, "restored Verilog builddir")
    assert_not_contains(restored, "processing Verilog targetfile", "restored Verilog consumer")
    assert_not_contains(restored, alt_filelist, "restored Verilog targetfile")
end

local function write_cxx_wrapper(filename, driver, marker, fail)
    local function shell_quote(value)
        return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
    end
    local lines = {
        "#!/bin/sh",
        "printf '%s\\n' invoked >> " .. shell_quote(marker),
    }
    if fail then
        table.insert(lines, "exit 99")
    else
        table.insert(lines, "exec " .. shell_quote(driver) .. " \"$@\"")
    end
    io.writefile(filename, table.concat(lines, "\n") .. "\n")
    os.vrunv("chmod", {"+x", filename})
end

local function test_cxx_driver(root, workroot, run)
    local find_tool = import("lib.detect.find_tool")
    local detected = find_tool("c++") or find_tool("g++") or find_tool("clang++")
    if not detected or not detected.program then
        raise("CXX-driver regression requires a C++ compiler")
    end

    local projectdir = copy_case(root, workroot, "cxx_driver")
    local wrapper_a = path.join(projectdir, "selected-cxx-a")
    local wrapper_b = path.join(projectdir, "selected-cxx-b")
    local blocker = path.join(projectdir, "ambient-cxx-must-not-run")
    local marker_a = wrapper_a .. ".log"
    local marker_b = wrapper_b .. ".log"
    local blocker_marker = blocker .. ".log"
    write_cxx_wrapper(wrapper_a, detected.program, marker_a)
    write_cxx_wrapper(wrapper_b, detected.program, marker_b)
    write_cxx_wrapper(blocker, detected.program, blocker_marker, true)

    local function options(selected, context)
        return {
            context = context,
            envs = {
                BSC_TEST_CXX = selected,
                CXX = blocker,
            },
        }
    end

    run(projectdir, {"config", "-c"}, options(wrapper_a, "configure selected CXX A"))
    local initial = run(projectdir, {"build", "sim"}, options(wrapper_a, "selected CXX A build"))
    assert_contains(initial, "building Bluespec bluesim sim", "selected CXX A build")
    assert_file(marker_a, "selected CXX A invocation")
    if os.isfile(blocker_marker) then
        raise("BSC used ambient CXX instead of the target's selected C++ driver")
    end
    local run_output = run(projectdir, {"run", "sim"}, options(wrapper_a, "selected CXX A run"))
    assert_contains(run_output, "CXX_DRIVER_OK", "selected CXX A run")

    local cached = run(projectdir, {"build", "sim"}, options(wrapper_a, "selected CXX A cache hit"))
    assert_bluespec_cache_hit(cached, "selected CXX A cache hit")

    run(projectdir, {"config", "-c"}, options(wrapper_b, "configure selected CXX B"))
    local changed = run(projectdir, {"build", "sim"}, options(wrapper_b, "selected CXX change"))
    assert_contains(changed, "building Bluespec bluesim sim", "selected CXX change")
    assert_contains(changed, "compiling Bluespec package Top", "selected CXX change")
    assert_file(marker_b, "selected CXX B invocation")
    if os.isfile(blocker_marker) then
        raise("BSC used ambient CXX after the target toolchain changed")
    end

    local changed_cached = run(projectdir, {"build", "sim"},
        options(wrapper_b, "selected CXX B cache hit"))
    assert_bluespec_cache_hit(changed_cached, "selected CXX B cache hit")
end

local function test_kind_ownership(root, workroot, run)
    local projectdir = copy_case(root, workroot, "kind_ownership")
    local output = run(projectdir, {"config", "-c"}, {context = "Bluespec rule kind ownership"})
    for _, item in ipairs({
        {"library", "phony"},
        {"check", "phony"},
        {"bluesim", "binary"},
        {"verilog", "binary"},
        {"systemc", "static"},
    }) do
        assert_contains(output, "BLUESPEC_KIND_" .. item[1] .. "=" .. item[2],
            "Bluespec rule kind ownership " .. item[1])
    end
end

local function test_native_bdpi_builddir(root, workroot, run)
    local projectdir = copy_case(root, workroot, "native_bdpi")
    configure(run, projectdir)

    local initial = run(projectdir, {"build", "-v", "native_bdpi"}, {context = "native BDPI build"})
    assert_contains(initial, "scanning Bluespec native_bdpi", "native BDPI build")
    assert_contains(initial, "compiling Bluespec package NativeBDPI", "native BDPI build")
    assert_contains(initial, "building Bluespec bluesim native_bdpi", "native BDPI build")
    assert_contains(initial, "-fPIC", "native BDPI PIC build")

    local builddir = path.join(projectdir, "build")
    local old_bo = assert_single_file(path.join(builddir, "**", "bdir", "NativeBDPI.bo"),
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
    if os.host() == "macosx" then
        assert_contains(initial, "-Wl,-force_load," .. path.absolute(old_golden),
            "native BDPI absolute forced load")
        assert_contains(initial, "-Wl,-force_load," .. path.absolute(old_helper),
            "transitive native BDPI absolute forced load")
    else
        assert_contains(initial, "-Wl,--whole-archive", "native BDPI forced load")
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
    local alt_bo = assert_single_file(path.join(alt_builddir, "**", "bdir", "NativeBDPI.bo"),
        "alt builddir package")
    assert_single_file(path.join(alt_builddir, "**", "libgolden.a"), "alt direct native archive")
    assert_single_file(path.join(alt_builddir, "**", "libgolden_helper.a"), "alt transitive native archive")
    assert_single_file(path.join(alt_builddir, "**", "simdir", "model_mkNativeBDPI.cxx"),
        "alt Bluesim generated source")
    assert_single_file(path.join(alt_builddir, "**", "simdir", "model_mkNativeBDPI.o"),
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

local function parse_tool(output, name, context)
    local value = output:match("BSC_TARGET_TOOL_" .. name .. "=([^\r\n]+)")
    if not value or value == "" then
        raise("%s: missing BSC_TARGET_TOOL_%s in configure output\n%s", context, name, output)
    end
    return path.normalize(value)
end

local function write_driver(pathname, driver)
    io.writefile(pathname, "#!/bin/sh\nexec \"" .. driver .. "\" \"$@\"\n")
    local code, errors = os.execv("chmod", {"755", pathname}, {try = true})
    if code ~= 0 then
        raise("failed to make compiler fixture executable: %s\n%s", pathname, tostring(errors or ""))
    end
end

local function test_bsc_native_toolchain(root, workroot, run)
    if os.host() == "windows" then
        return
    end
    local projectdir = copy_case(root, workroot, "toolchain_identity")
    local configure_args = {"config", "-c"}
    local configured = run(projectdir, configure_args, {
        context = "configure BSC native toolchain",
        envs = {BLUESPEC_XMAKE_REPORT_TOOLS = "1"},
    })
    local cc = parse_tool(configured, "cc", "configure BSC native toolchain")
    local cxx = parse_tool(configured, "cxx", "configure BSC native toolchain")
    local sh = parse_tool(configured, "sh", "configure BSC native toolchain")
    if os.host() == "macosx" and (not cc:find("clang", 1, true) or not cxx:find("clang++", 1, true)) then
        raise("Darwin regression expected Xmake clang drivers, got cc=%s cxx=%s sh=%s", cc, cxx, sh)
    end

    local hostile = path.join(projectdir, "hostile-compiler")
    io.writefile(hostile, "#!/bin/sh\nexit 97\n")
    local code, errors = os.execv("chmod", {"755", hostile}, {try = true})
    if code ~= 0 then
        raise("failed to make hostile compiler executable: %s", tostring(errors or ""))
    end
    local first = run(projectdir, {"build", "-v", "toolchain_sim"}, {
        context = "hostile inherited compiler environment",
        envs = {CC = hostile, CXX = hostile},
    })
    assert_contains(first, "exec: " .. cxx, "BSC selected Xmake C++ driver")
    assert_not_contains(first, "exec: " .. hostile, "BSC ignored inherited CXX")
    assert_contains(run(projectdir, {"run", "toolchain_sim"}, {
        context = "run hostile-environment Bluesim",
        envs = {CC = hostile, CXX = hostile},
    }), "TOOLCHAIN_OK", "run hostile-environment Bluesim")
    local package_bo = assert_single_file(path.join(projectdir, "build", "**", "bdir", "ToolchainTop.bo"),
        "toolchain package output")
    local model = assert_single_file(path.join(projectdir, "build", "**", "simdir", "model_mkToolchainTop.cxx"),
        "toolchain generated model")
    local executable = path.join(projectdir, "build", "bin", "toolchain_sim")
    local package_mtime = os.mtime(package_bo)
    local model_mtime = os.mtime(model)
    local executable_mtime = os.mtime(executable)
    assert_bluespec_cache_hit(run(projectdir, {"build", "toolchain_sim"}, {
        context = "initial toolchain cache hit",
        envs = {CC = hostile, CXX = hostile},
    }), "initial toolchain cache hit")

    local alternate = path.join(projectdir, "alternate-toolchain")
    os.mkdir(alternate)
    local alt_cc = path.join(alternate, path.filename(cc))
    local alt_cxx = path.join(alternate, path.filename(cxx))
    write_driver(alt_cc, cc)
    write_driver(alt_cxx, cxx)
    os.sleep(1100)
    local changed_args = {
        "config", "-c", "--cc=" .. alt_cc, "--cxx=" .. alt_cxx,
        "--ld=" .. alt_cxx, "--sh=" .. alt_cxx,
    }
    local changed_tools = run(projectdir, changed_args, {
        context = "configure alternate Xmake compiler identity",
        envs = {BLUESPEC_XMAKE_REPORT_TOOLS = "1"},
    })
    assert_contains(changed_tools, "BSC_TARGET_TOOL_cxx=" .. alt_cxx,
        "alternate Xmake compiler identity")
    local changed = run(projectdir, {"build", "toolchain_sim"}, {
        context = "Xmake compiler identity invalidation",
        envs = {CC = hostile, CXX = hostile},
    })
    assert_contains(changed, "scanning Bluespec toolchain_sim", "compiler identity graph invalidation")
    assert_contains(changed, "compiling Bluespec package ToolchainTop", "compiler identity package invalidation")
    assert_contains(changed, "building Bluespec bluesim toolchain_sim", "compiler identity backend invalidation")
    if os.mtime(package_bo) == package_mtime then
        raise("compiler identity change did not rebuild the package output")
    end
    if os.mtime(model) == model_mtime or os.mtime(executable) == executable_mtime then
        raise("compiler identity change did not regenerate/relink the Bluesim model")
    end
    assert_contains(run(projectdir, {"run", "toolchain_sim"}, {
        context = "run alternate-identity Bluesim",
        envs = {CC = hostile, CXX = hostile},
    }), "TOOLCHAIN_OK", "run alternate-identity Bluesim")
    assert_bluespec_cache_hit(run(projectdir, {"build", "toolchain_sim"}, {
        context = "alternate toolchain cache hit",
        envs = {CC = hostile, CXX = hostile},
    }), "alternate toolchain cache hit")
end

local function fake_bsc_events(logfile, context)
    local events = {}
    for line in (io.readfile(logfile) or ""):gmatch("[^\r\n]+") do
        local event = {}
        for name, value in line:gmatch("([%w_]+)=([^ ]*)") do
            event[name] = value
        end
        event.time_us = tonumber(event.time_us)
        event.status = tonumber(event.status)
        if not event.event or not event.time_us or not event.kind or not event.target then
            raise("%s: malformed fake BSC event: %s", context, line)
        end
        table.insert(events, event)
    end
    table.sort(events, function(left, right)
        if left.time_us == right.time_us then
            return left.event == "end" and right.event ~= "end"
        end
        return left.time_us < right.time_us
    end)
    return events
end

local function analyze_fake_bsc(logfile, context, opt)
    opt = opt or {}
    local active = 0
    local active_backend = 0
    local maximum = 0
    local maximum_backend = 0
    local active_by_target = {}
    local starts = {}
    local events = fake_bsc_events(logfile, context)
    for _, event in ipairs(events) do
        local key = table.concat({event.target, event.kind, event.phase or ""}, "|")
        if event.event == "start" then
            active = active + 1
            maximum = math.max(maximum, active)
            if event.kind == "backend" then
                active_backend = active_backend + 1
                maximum_backend = math.max(maximum_backend, active_backend)
            end
            local target_active = active_by_target[event.target] or {}
            if event.kind == "backend" and (target_active.package or 0) > 0 then
                raise("%s: target(%s) backend overlapped its package compile", context, event.target)
            elseif event.kind == "package" and (target_active.backend or 0) > 0 then
                raise("%s: target(%s) package compile overlapped its backend", context, event.target)
            end
            target_active[event.kind] = (target_active[event.kind] or 0) + 1
            active_by_target[event.target] = target_active
            starts[key] = (starts[key] or 0) + 1
        elseif event.event == "end" then
            active = active - 1
            if event.kind == "backend" then
                active_backend = active_backend - 1
            end
            local target_active = active_by_target[event.target] or {}
            target_active[event.kind] = (target_active[event.kind] or 0) - 1
            active_by_target[event.target] = target_active
        else
            raise("%s: unknown fake BSC event %s", context, event.event)
        end
        if active < 0 or active_backend < 0 then
            raise("%s: unmatched fake BSC end event", context)
        end
    end
    if not opt.allow_incomplete and (active ~= 0 or active_backend ~= 0) then
        raise("%s: fake BSC process did not record a matching end event", context)
    end
    return {events = events, starts = starts, maximum = maximum, maximum_backend = maximum_backend}
end

local function bsc_trace_argv(output, phase, context)
    local result
    local current
    for line in (output or ""):gmatch("[^\r\n]+") do
        local started = line:match("BSC_TRACE START .* phase=([^ ]+)")
        if started then
            current = started
            if current == phase then
                result = {}
            end
        elseif line:find("BSC_TRACE END", 1, true) then
            current = nil
        elseif current == phase then
            local argument = line:match("BSC_TRACE ARGV%[%d+%]=(.*)$")
            if argument ~= nil then
                table.insert(result, argument)
            end
        end
    end
    if not result then
        raise("%s: missing BSC trace for phase %s", context, phase)
    end
    return result
end

local function assert_argv_sequence(args, expected, context)
    for first = 1, #args - #expected + 1 do
        local matches = true
        for offset, value in ipairs(expected) do
            if args[first + offset - 1] ~= value then
                matches = false
                break
            end
        end
        if matches then
            return
        end
    end
    raise("%s: missing argv sequence [%s]\nactual: [%s]", context,
        table.concat(expected, ", "), table.concat(args, ", "))
end

local function test_systemc_package(root, workroot, run)
    local fake_project = path.join(root, "tests", "fake_bsc")
    local fake_build = path.join(workroot, "fake-systemc-tools-build")
    run(fake_project, {"config", "-c", "-o", fake_build}, {
        context = "configure fake SystemC tools",
    })
    run(fake_project, {"build", "-a", "-j", "1"}, {
        context = "build fake SystemC tools",
    })
    local bindir = path.join(fake_build, "bin")
    local fake_bsc = path.join(bindir, os.host() == "windows" and "bsc.exe" or "bsc")
    local fake_bluetcl = path.join(bindir, os.host() == "windows" and "bluetcl.exe" or "bluetcl")
    if not os.isexec(fake_bsc) or not os.isexec(fake_bluetcl) then
        raise("fake SystemC tools build did not produce bsc and bluetcl executables")
    end

    local projectdir = copy_case(root, workroot, "systemc_package")
    local builddir = path.join(projectdir, "build-systemc")
    local envs = {
        PATH = path.joinenv({bindir, os.getenv("PATH") or ""}),
        BLUESPEC_FAKE_BSC_PACKAGE_MS = "0",
        BLUESPEC_FAKE_BSC_BACKEND_MS = "0",
        BLUESPEC_FAKE_BLUETCL_MS = "0",
    }
    local active_envs = envs
    local active_bluesim_dir = path.join(fake_build, "lib", "Bluesim")
    local function assert_consumer_cache_hit(output, context)
        assert_bluespec_cache_hit(output, context)
        for _, message in ipairs({"compiling.", "linking.", "archiving."}) do
            assert_not_contains(output, message, context)
        end
    end
    local function configure_variant(variant)
        run(projectdir, {
            "config", "-o", builddir,
            "--local_systemc_variant=" .. variant,
            "--bluespec_trace_bsc=y",
        }, {
            context = "configure local SystemC package variant " .. variant,
            envs = active_envs,
        })
    end
    local function check_variant(variant)
        local context = "local SystemC package variant " .. variant
        local output = run(projectdir, {"build", "model"}, {
            context = context .. " model",
            envs = active_envs,
        })
        assert_contains(output, "building Bluespec systemc model", context)
        local args = bsc_trace_argv(output, "systemc-generate", context)
        local prefix = path.absolute(path.join(projectdir, "prefix-" .. variant))
        assert_argv_sequence(args, {"-Xc++", "-I" .. path.join(prefix, "ordinary")},
            context .. " ordinary include")
        assert_argv_sequence(args, {
            "-Xc++", "-isystem", "-Xc++", path.join(prefix, "system"),
        }, context .. " system include")
        assert_argv_sequence(args, {"-L", path.join(prefix, "lib")},
            context .. " package linkdir")
        assert_argv_sequence(args, {"-l", "local_systemc_" .. variant},
            context .. " package link")
        assert_argv_sequence(args, {"-l", "local_runtime_" .. variant},
            context .. " package syslink")
        local ldflag = variant == "a" and "-Wl,-z,relro" or "-Wl,-z,now"
        assert_argv_sequence(args, {"-Xl", ldflag},
            context .. " package ldflag")
        assert_argv_sequence(args, {"-Xc++", "-I" .. active_bluesim_dir},
            context .. " BSC Bluesim include")
        assert_argv_sequence(args, {"-L", active_bluesim_dir},
            context .. " BSC Bluesim linkdir")
        assert_argv_sequence(args, {"-l", "systemc", "-l", "bskernel", "-l", "bsprim"},
            context .. " BSC runtime link order")
        local targetfile = output:match("BSC_TRACE PATH [^\r\n]- targetfile=([^\r\n]+)")
        if not targetfile or not os.isfile(targetfile) then
            raise("%s: missing generated SystemC static archive %s", context,
                tostring(targetfile))
        end
        local consumer_output = run(projectdir, {"build", "consumer"}, {
            context = context .. " native consumer",
            envs = active_envs,
        })
        assert_contains(run(projectdir, {"run", "consumer"}, {
            context = context .. " executable",
            envs = active_envs,
        }), "SYSTEMC_CONSUMER_OK", context .. " executable")
        return output, consumer_output
    end

    configure_variant("a")
    check_variant("a")
    assert_consumer_cache_hit(run(projectdir, {"build", "consumer"}, {
        context = "local SystemC package variant a cache hit",
        envs = active_envs,
    }), "local SystemC package variant a cache hit")

    configure_variant("b")
    check_variant("b")
    assert_consumer_cache_hit(run(projectdir, {"build", "consumer"}, {
        context = "local SystemC package variant b cache hit",
        envs = active_envs,
    }), "local SystemC package variant b cache hit")

    local alternate_bluespecdir = path.join(workroot, "fake-systemc-alternate-sdk")
    active_bluesim_dir = path.join(alternate_bluespecdir, "Bluesim")
    os.mkdir(active_bluesim_dir)
    for _, file in ipairs(os.files(path.join(fake_build, "lib", "Bluesim", "*"))) do
        os.cp(file, active_bluesim_dir)
    end
    active_envs = table.clone(envs)
    active_envs.BLUESPECDIR = alternate_bluespecdir
    configure_variant("b")
    local _, identity_consumer = check_variant("b")
    assert_contains(identity_consumer, "compiling.release consumer.cpp",
        "BSC SDK identity change recompiles native consumer")
    assert_consumer_cache_hit(run(projectdir, {"build", "consumer"}, {
        context = "alternate BSC SDK native consumer cache hit",
        envs = active_envs,
    }), "alternate BSC SDK native consumer cache hit")
end

local function fake_bluetcl_events(logfile, context)
    local events = {}
    for line in (io.readfile(logfile) or ""):gmatch("[^\r\n]+") do
        local event = {}
        for name, value in line:gmatch("([%w_]+)=([^ ]*)") do
            event[name] = value
        end
        event.time_us = tonumber(event.time_us)
        event.status = tonumber(event.status)
        if not event.event or not event.time_us or not event.root then
            raise("%s: malformed fake Bluetcl event: %s", context, line)
        end
        table.insert(events, event)
    end
    table.sort(events, function(left, right)
        if left.time_us == right.time_us then
            return left.event == "end" and right.event ~= "end"
        end
        return left.time_us < right.time_us
    end)
    return events
end

local function analyze_fake_bluetcl(logfile, context)
    local active = 0
    local maximum = 0
    local starts = 0
    local roots = {}
    local first_start = {}
    local last_end = {}
    local starts_by_pid = {}
    local first_start_us
    local last_end_us
    local process_time_us = 0
    local events = fake_bluetcl_events(logfile, context)
    for _, event in ipairs(events) do
        local root = path.filename(event.root)
        if event.event == "start" then
            active = active + 1
            maximum = math.max(maximum, active)
            starts = starts + 1
            roots[root] = (roots[root] or 0) + 1
            first_start[root] = math.min(first_start[root] or event.time_us, event.time_us)
            first_start_us = math.min(first_start_us or event.time_us, event.time_us)
            starts_by_pid[event.pid] = event.time_us
        elseif event.event == "end" then
            active = active - 1
            last_end[root] = math.max(last_end[root] or event.time_us, event.time_us)
            last_end_us = math.max(last_end_us or event.time_us, event.time_us)
            local process_start = starts_by_pid[event.pid]
            if not process_start then
                raise("%s: fake Bluetcl end event has no matching pid=%s start", context, tostring(event.pid))
            end
            process_time_us = process_time_us + event.time_us - process_start
            starts_by_pid[event.pid] = nil
        else
            raise("%s: unknown fake Bluetcl event %s", context, event.event)
        end
        if active < 0 then
            raise("%s: unmatched fake Bluetcl end event", context)
        end
    end
    if active ~= 0 then
        raise("%s: fake Bluetcl process did not record a matching end event", context)
    end
    return {
        events = events,
        starts = starts,
        roots = roots,
        maximum = maximum,
        first_start = first_start,
        last_end = last_end,
        span_us = first_start_us and last_end_us and (last_end_us - first_start_us) or 0,
        process_time_us = process_time_us,
    }
end

local function scan_trace_identities(output, rootname)
    local identities = {}
    for line in (output or ""):gmatch("[^\r\n]+") do
        if line:find("BSC_SCAN_TRACE PROCESS_START", 1, true) and
            line:find("/" .. rootname, 1, true) then
            local identity = line:match(" identity=([^ ]+)")
            if identity then
                identities[identity] = true
            end
        end
    end
    return identities
end

local function only_key(values, context)
    local result
    local count = 0
    for value in pairs(values) do
        result = value
        count = count + 1
    end
    if count ~= 1 then
        raise("%s: expected exactly one identity, got %d", context, count)
    end
    return result
end

local function assert_fake_paths(analysis, builddir, context)
    local root = path.normalize(path.absolute(builddir))
    for _, event in ipairs(analysis.events) do
        if event.event == "start" then
            for _, pathname in ipairs({event.bdir, event.vdir}) do
                if pathname and pathname ~= "" then
                    pathname = path.normalize(path.absolute(pathname))
                    if pathname ~= root and pathname:sub(1, #root + 1) ~= root .. "/" then
                        raise("%s: BSC path escaped builddir %s: %s", context, root, pathname)
                    end
                end
            end
        end
    end
end

local function test_bsc_concurrency(root, workroot, run)
    local fake_project = path.join(root, "tests", "fake_bsc")
    local fake_build = path.join(workroot, "fake-bsc-build")
    run(fake_project, {"config", "-c", "-o", fake_build}, {context = "configure fake BSC"})
    run(fake_project, {"build", "bsc"}, {context = "build fake BSC"})
    local fake_bsc = path.join(fake_build, "bin", os.host() == "windows" and "bsc.exe" or "bsc")
    if not os.isexec(fake_bsc) then
        raise("fake BSC build did not produce executable %s", fake_bsc)
    end

    local projectdir = copy_case(root, workroot, "concurrency")
    local fake_path = path.joinenv({path.directory(fake_bsc), os.getenv("PATH") or ""})
    local function environment(logfile, extra)
        local envs = {
            PATH = fake_path,
            BLUESPEC_FAKE_BSC_LOG = logfile,
            -- Xmake 3.0.4 polls short-lived child processes coarsely. Keep
            -- fake backends alive long enough for ready jobs to overlap.
            BLUESPEC_FAKE_BSC_PACKAGE_MS = "40",
            BLUESPEC_FAKE_BSC_BACKEND_MS = "1500",
        }
        for name, value in pairs(extra or {}) do
            envs[name] = value
        end
        return envs
    end
    local function configure_case(builddir, backend_jobs, bsc_jobs, logfile, trace)
        local arguments = {
            "config", "-c", "-o", builddir,
            "--bluespec_backend_jobs=" .. tostring(backend_jobs),
            "--bluespec_bsc_jobs=" .. tostring(bsc_jobs),
            "--bluespec_trace_bsc=" .. (trace and "y" or "n"),
        }
        run(projectdir, arguments, {context = "configure fake BSC concurrency", envs = environment(logfile)})
    end
    local function build_all(logfile, builddir, context, opt)
        opt = opt or {}
        io.writefile(logfile, "")
        local output = run(projectdir, {"build", "-a", "-j", tostring(opt.jobs or 8)}, {
            context = context,
            fail = opt.fail,
            envs = environment(logfile, opt.envs),
        })
        local analysis = analyze_fake_bsc(logfile, context, {allow_incomplete = opt.allow_incomplete})
        assert_fake_paths(analysis, builddir, context)
        return output, analysis
    end

    local capped_build = path.join(projectdir, "build-backend-two")
    local capped_log = path.join(workroot, "fake-bsc-backend-two.log")
    configure_case(capped_build, 2, 0, capped_log, true)
    local traced, capped = build_all(capped_log, capped_build, "cross-target backend cap")
    if capped.maximum_backend ~= 2 then
        raise("cross-target backend cap: expected maximum backend concurrency 2, got %d",
            capped.maximum_backend)
    end
    for index = 1, 4 do
        local target = "rtl" .. index
        local package_key = table.concat({target, "package", "package"}, "|")
        local backend_key = table.concat({target, "backend", "verilog-generate"}, "|")
        if capped.starts[package_key] ~= 1 or capped.starts[backend_key] ~= 1 then
            raise("cross-target backend cap: target(%s) was not scheduled exactly once (package=%s backend=%s)",
                target, tostring(capped.starts[package_key]), tostring(capped.starts[backend_key]))
        end
    end
    assert_contains(traced, "BSC_TRACE START target=rtl", "BSC trace target/job")
    assert_contains(traced, "pid=", "BSC trace PID")
    assert_contains(traced, "pid=not-exposed-by-xmake", "BSC trace PID capability marker")
    assert_contains(traced, "BSC_TRACE ARGV[", "BSC trace complete argv")
    assert_contains(traced, "BSC_TRACE PATH bdir=", "BSC trace artifact paths")

    io.writefile(capped_log, "")
    local unchanged = run(projectdir, {"build", "-a", "-j", "8"}, {
        context = "cross-target unchanged cache hit",
        envs = environment(capped_log),
    })
    assert_bluespec_cache_hit(unchanged, "cross-target unchanged cache hit")
    if (io.readfile(capped_log) or "") ~= "" then
        raise("cross-target unchanged cache hit unexpectedly invoked BSC")
    end

    local total_build = path.join(projectdir, "build-total-two")
    local total_log = path.join(workroot, "fake-bsc-total-two.log")
    configure_case(total_build, 4, 2, total_log, false)
    local _, total = build_all(total_log, total_build, "project-wide BSC cap")
    if total.maximum ~= 2 or total.maximum_backend > 2 then
        raise("project-wide BSC cap: expected total concurrency 2, got total=%d backend=%d",
            total.maximum, total.maximum_backend)
    end

    local serial_build = path.join(projectdir, "build-serial")
    local serial_log = path.join(workroot, "fake-bsc-serial.log")
    configure_case(serial_build, 4, 4, serial_log, false)
    local _, serial = build_all(serial_log, serial_build, "global -j1 interaction", {jobs = 1})
    if serial.maximum ~= 1 or serial.maximum_backend ~= 1 then
        raise("global -j1 interaction: expected concurrency 1, got total=%d backend=%d",
            serial.maximum, serial.maximum_backend)
    end

    local failure_build = path.join(projectdir, "build-failure")
    local failure_log = path.join(workroot, "fake-bsc-failure.log")
    configure_case(failure_build, 2, 0, failure_log, false)
    build_all(failure_log, failure_build, "backend failure", {
        fail = true,
        allow_incomplete = true,
        envs = {BLUESPEC_FAKE_BSC_FAIL_TOP = "mkTop3"},
    })
    local failed_filelist = path.join(failure_build, "Verilog", "rtl3.f")
    if os.isfile(failed_filelist) then
        raise("backend failure left a public filelist that could be mistaken for completion")
    end
    local completed = {}
    for index = 1, 4 do
        local filelist = path.join(failure_build, "Verilog", "rtl" .. index .. ".f")
        if os.isfile(filelist) then
            completed["rtl" .. index] = true
        end
    end
    local _, retried = build_all(failure_log, failure_build, "backend failure retry")
    if retried.starts["rtl3|backend|verilog-generate"] ~= 1 then
        raise("backend failure retry did not run the failed backend exactly once")
    end
    for target in pairs(completed) do
        if retried.starts[target .. "|backend|verilog-generate"] then
            raise("backend failure retry rebuilt already-completed target(%s)", target)
        end
    end
end

local function test_scan_concurrency(root, workroot, run)
    local fake_project = path.join(root, "tests", "fake_bsc")
    local fake_build = path.join(workroot, "fake-scan-tools-build")
    run(fake_project, {"config", "-c", "-o", fake_build}, {context = "configure fake scan tools"})
    run(fake_project, {"build", "-a", "-j", "1"}, {context = "build fake scan tools"})
    local bindir = path.join(fake_build, "bin")
    local fake_bsc = path.join(bindir, os.host() == "windows" and "bsc.exe" or "bsc")
    local fake_bluetcl = path.join(bindir, os.host() == "windows" and "bluetcl.exe" or "bluetcl")
    if not os.isexec(fake_bsc) or not os.isexec(fake_bluetcl) then
        raise("fake scan tools build did not produce bsc and bluetcl executables")
    end

    local projectdir = copy_case(root, workroot, "scan_concurrency")
    local fake_path = path.joinenv({bindir, os.getenv("PATH") or ""})
    local function environment(logfile, extra)
        local envs = {
            PATH = fake_path,
            BLUESPEC_FAKE_BLUETCL_LOG = logfile,
            BLUESPEC_FAKE_BLUETCL_MS = "700",
            BLUESPEC_FAKE_BSC_PACKAGE_MS = "0",
            BLUESPEC_FAKE_BSC_BACKEND_MS = "0",
        }
        for name, value in pairs(extra or {}) do
            envs[name] = value
        end
        return envs
    end
    local function configure_case(builddir, scan_jobs, logfile, trace)
        run(projectdir, {
            "config", "-c", "-o", builddir,
            "--bluespec_backend_jobs=0",
            "--bluespec_scan_jobs=" .. tostring(scan_jobs),
            "--bluespec_trace_scan=" .. (trace and "y" or "n"),
        }, {
            context = "configure fake Bluetcl concurrency",
            envs = environment(logfile),
        })
    end
    local function build_all(logfile, context, jobs)
        io.writefile(logfile, "")
        local output = run(projectdir, {"build", "-a", "-j", tostring(jobs)}, {
            context = context,
            envs = environment(logfile),
        })
        return output, analyze_fake_bluetcl(logfile, context)
    end
    local function assert_single_flight(analysis, context)
        -- Four unique roots, two four-way shared roots, one provider root and
        -- one two-way shared consumer root: 15 target graphs, 8 raw scans.
        if analysis.starts ~= 8 then
            raise("%s: expected 8 raw scans for 15 target graphs, got %d", context, analysis.starts)
        end
        for _, rootname in ipairs({"SharedA.bsv", "SharedB.bsv", "Consumer.bsv"}) do
            if analysis.roots[rootname] ~= 1 then
                raise("%s: expected one single-flight scan for %s, got %s",
                    context, rootname, tostring(analysis.roots[rootname]))
            end
        end
    end

    local starvation_project = copy_case(root, workroot, "scan_starvation")
    local starvation_build = path.join(starvation_project, "build-scan-starvation")
    local starvation_log = path.join(workroot, "fake-bluetcl-starvation.log")
    local starvation_env = environment(starvation_log, {BLUESPEC_FAKE_BLUETCL_MS = "1500"})
    run(starvation_project, {
        "config", "-c", "-o", starvation_build,
        "--bluespec_backend_jobs=0",
        "--bluespec_scan_jobs=0",
        "--bluespec_trace_scan=y",
    }, {
        context = "configure grouped-root scan starvation",
        envs = starvation_env,
    })
    io.writefile(starvation_log, "")
    local starvation_output = run(starvation_project, {"build", "-a", "-j", "8"}, {
        context = "grouped-root scan starvation",
        envs = starvation_env,
    })
    local starvation = analyze_fake_bluetcl(starvation_log, "grouped-root scan starvation")
    if starvation.starts ~= 16 then
        raise("grouped-root scan starvation: expected 16 raw scans for 64 target graphs, got %d",
            starvation.starts)
    end
    for root_index = 1, 16 do
        local rootname = string.format("Root%02d.bsv", root_index)
        if starvation.roots[rootname] ~= 1 then
            raise("grouped-root scan starvation: expected one raw scan for %s, got %s",
                rootname, tostring(starvation.roots[rootname]))
        end
    end
    if starvation.maximum ~= 8 then
        raise("grouped-root scan starvation: expected all 8 Xmake slots to run unique owners, got %d",
            starvation.maximum)
    end
    local delay_us = 1500000
    local ideal_span_us = math.ceil(16 / 8) * delay_us
    local maximum_span_us = ideal_span_us + 2500000
    if starvation.span_us > maximum_span_us then
        raise("grouped-root scan starvation: process span %.3fs exceeds %.3fs (ideal %.3fs)",
            starvation.span_us / 1000000, maximum_span_us / 1000000, ideal_span_us / 1000000)
    end
    local utilization = starvation.span_us > 0 and
        starvation.process_time_us / (starvation.span_us * 8) or 0
    if utilization < 0.50 then
        raise("grouped-root scan starvation: owner utilization %.1f%% shows mid-build starvation",
            utilization * 100)
    end

    local trace_counts = {}
    local owner_ended = {}
    for line in starvation_output:gmatch("[^\r\n]+") do
        local event = line:match("BSC_SCAN_TRACE ([A-Z_]+)")
        if event then
            trace_counts[event] = (trace_counts[event] or 0) + 1
            local identity = line:match(" identity=([^ ]+)")
            if event == "OWNER_END" then
                owner_ended[identity] = true
            elseif event == "WAITER_RELEASE" or event == "FINALIZE_START" then
                if not owner_ended[identity] then
                    raise("grouped-root scan trace: %s preceded OWNER_END for identity %s",
                        event, tostring(identity))
                end
            end
        end
    end
    local expected_trace_counts = {
        OWNER_START = 16,
        OWNER_END = 16,
        PROCESS_START = 16,
        PROCESS_END = 16,
        WAITER_WAIT = 48,
        WAITER_RELEASE = 48,
        FINALIZE_START = 64,
        FINALIZE_END = 64,
    }
    for event, expected in pairs(expected_trace_counts) do
        if trace_counts[event] ~= expected then
            raise("grouped-root scan trace: expected %d %s events, got %s",
                expected, event, tostring(trace_counts[event]))
        end
    end

    local parallel_build = path.join(projectdir, "build-scan-parallel")
    local parallel_log = path.join(workroot, "fake-bluetcl-parallel.log")
    configure_case(parallel_build, 0, parallel_log, true)
    local traced, parallel = build_all(parallel_log, "parallel single-flight scans", 8)
    assert_single_flight(parallel, "parallel single-flight scans")
    local _, scan_progress_count = traced:gsub("scanning Bluespec", "")
    if scan_progress_count ~= 8 then
        raise("parallel single-flight scans: expected 8 real-scan progress lines, got %d",
            scan_progress_count)
    end
    if parallel.maximum < 2 then
        raise("parallel single-flight scans: independent roots did not overlap (maximum=%d)", parallel.maximum)
    end
    if not parallel.last_end["Provider.bsv"] or not parallel.first_start["Consumer.bsv"] or
        parallel.first_start["Consumer.bsv"] < parallel.last_end["Provider.bsv"] then
        raise("parallel single-flight scans: consumer scan started before its Bluespec dependency completed")
    end
    assert_contains(traced, "BSC_SCAN_TRACE PROCESS_START target=", "scan process trace")
    assert_contains(traced, "BSC_SCAN_TRACE OWNER_START target=", "scan owner trace")
    assert_contains(traced, "BSC_SCAN_TRACE WAITER_WAIT target=", "scan waiter trace")
    assert_contains(traced, "BSC_SCAN_TRACE FINALIZE_START target=", "scan finalize trace")
    assert_contains(traced, " elapsed_ms=", "scan trace elapsed time")
    local parallel_shared_identity = only_key(scan_trace_identities(traced, "SharedA.bsv"),
        "shared-root scan identity excludes top")

    local parallel_four_build = path.join(projectdir, "build-scan-parallel-four")
    local parallel_four_log = path.join(workroot, "fake-bluetcl-parallel-four.log")
    configure_case(parallel_four_build, 0, parallel_four_log, true)
    local traced_four, parallel_four = build_all(parallel_four_log, "parallel scans with -j4", 4)
    assert_single_flight(parallel_four, "parallel scans with -j4")
    if parallel_four.maximum < 2 or parallel_four.maximum > 4 then
        raise("parallel scans with -j4: expected 2..4 concurrent scans, got %d", parallel_four.maximum)
    end
    local parallel_four_identity = only_key(scan_trace_identities(traced_four, "SharedA.bsv"),
        "-j4 shared-root scan identity")
    if parallel_four_identity ~= parallel_shared_identity then
        raise("raw scan identity changed across builddir/-j4/-j8: %s != %s",
            parallel_four_identity, parallel_shared_identity)
    end

    io.writefile(parallel_log, "")
    local unchanged = run(projectdir, {"build", "-a", "-j", "8"}, {
        context = "scan unchanged cache hit",
        envs = environment(parallel_log),
    })
    assert_bluespec_cache_hit(unchanged, "scan unchanged cache hit")
    if (io.readfile(parallel_log) or "") ~= "" then
        raise("scan unchanged cache hit unexpectedly invoked Bluetcl")
    end

    local shared_a = path.join(projectdir, "src", "SharedA.bsv")
    io.writefile(shared_a, assert(io.readfile(shared_a)) .. "\n// invalidate shared scan\n")
    local _, invalidated = build_all(parallel_log, "shared-root scan invalidation", 8)
    if invalidated.starts ~= 1 or invalidated.roots["SharedA.bsv"] ~= 1 then
        raise("shared-root scan invalidation: expected one SharedA raw scan, got %d", invalidated.starts)
    end

    local provider = path.join(projectdir, "src", "Provider.bsv")
    io.writefile(provider, assert(io.readfile(provider)) .. "\n// invalidate provider graph\n")
    local _, provider_invalidated = build_all(parallel_log, "provider graph scan invalidation", 8)
    if provider_invalidated.starts ~= 2 or
        provider_invalidated.roots["Provider.bsv"] ~= 1 or
        provider_invalidated.roots["Consumer.bsv"] ~= 1 then
        raise("provider graph scan invalidation: expected one provider and one shared consumer raw scan, got %d",
            provider_invalidated.starts)
    end

    local capped_build = path.join(projectdir, "build-scan-capped")
    local capped_log = path.join(workroot, "fake-bluetcl-capped.log")
    configure_case(capped_build, 1, capped_log, true)
    local capped_output, capped = build_all(capped_log, "project-wide scan cap", 8)
    assert_single_flight(capped, "project-wide scan cap")
    if capped.maximum ~= 1 then
        raise("project-wide scan cap: expected maximum scan concurrency 1, got %d", capped.maximum)
    end

    local serial_build = path.join(projectdir, "build-scan-serial")
    local serial_log = path.join(workroot, "fake-bluetcl-serial.log")
    configure_case(serial_build, 0, serial_log, true)
    local serial_output, serial = build_all(serial_log, "global -j1 scan interaction", 1)
    assert_single_flight(serial, "global -j1 scan interaction")
    if serial.maximum ~= 1 then
        raise("global -j1 scan interaction: expected maximum scan concurrency 1, got %d", serial.maximum)
    end
    local capped_identity = only_key(scan_trace_identities(capped_output, "SharedA.bsv"),
        "capped shared-root scan identity")
    local serial_identity = only_key(scan_trace_identities(serial_output, "SharedA.bsv"),
        "serial shared-root scan identity")
    if capped_identity ~= serial_identity then
        raise("scan identity changed across builddir/concurrency configuration: %s != %s",
            capped_identity, serial_identity)
    end
    if parallel_shared_identity == capped_identity then
        -- The source was deliberately modified between these builds; its
        -- stamp must participate in the raw scan identity.
        raise("shared-root source modification did not change raw scan identity")
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
        {"declaration-relative path APIs", function() test_path_relative(root, workroot, run) end},
        {"incremental graph/cache", function() test_incremental(root, workroot, run) end},
        {"generated BSV", function() test_generated(root, workroot, run) end},
        {"valued/valueless defines", function() test_defines(root, workroot, run) end},
        {"multi-token BSC option groups", function() test_option_groups(root, workroot, run) end},
        {"Bluesim/Verilog backends", function() test_backends(root, workroot, run) end},
        {"target CXX selection/cache identity", function() test_cxx_driver(root, workroot, run) end},
        {"BSC native toolchain identity", function() test_bsc_native_toolchain(root, workroot, run) end},
        {"SystemC native package propagation", function() test_systemc_package(root, workroot, run) end},
        {"project-wide BSC/backend concurrency", function() test_bsc_concurrency(root, workroot, run) end},
        {"cross-target Bluetcl scan concurrency", function() test_scan_concurrency(root, workroot, run) end},
        {"Bluespec rule kind ownership", function() test_kind_ownership(root, workroot, run) end},
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
