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
