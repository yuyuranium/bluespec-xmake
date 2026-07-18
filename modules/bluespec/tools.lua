local util = import("bluespec.util")

local tool_cache = {}

local function find_program(name)
    if path.is_absolute(name) then
        return os.isfile(name) and name or nil
    end
    local pathenv = os.getenv("PATH") or ""
    for _, directory in ipairs(path.splitenv(pathenv)) do
        if directory ~= "" then
            local candidate = path.join(directory, name)
            if os.isfile(candidate) and os.isexec(candidate) then
                return candidate
            end
        end
    end
    return nil
end

local function canonical_program(program)
    if not program or program == "" then
        return nil
    end
    local resolved
    if path.is_absolute(program) then
        resolved = program
    elseif os.isfile(program) then
        resolved = path.absolute(program)
    else
        resolved = find_program(program)
    end
    return resolved and path.normalize(path.absolute(resolved)) or nil
end

local function program_stamp(program)
    if os.isfile(program) then
        return tostring(os.mtime(program) or 0) .. ":" .. tostring(os.filesize(program) or 0)
    end
    return "missing"
end

local function target_driver(target, kind)
    local program, name = target:tool(kind)
    program = canonical_program(program)
    if not program then
        raise("target(%s) has no Xmake %s compiler driver for BSC", target:name(), kind)
    end
    return {
        kind = kind,
        name = tostring(name or ""),
        program = program,
        stamp = program_stamp(program),
    }
end

local function quote_tcl(value)
    value = tostring(value)
    value = value:gsub("\\", "\\\\")
    value = value:gsub("\"", "\\\"")
    value = value:gsub("%$", "\\$")
    value = value:gsub("%[", "\\[")
    value = value:gsub("%]", "\\]")
    return "\"" .. value .. "\""
end

local function run_quiet(program, args, options)
    local stdout, stderr = os.iorunv(program, args, options or {})
    return stdout, stderr
end

local function raise_bsc_state_error(target, errors)
    errors = tostring(errors or "")
    if target and errors:find("BinData.getB: unexpected end of byte stream", 1, true) then
        local util = import("bluespec.util")
        raise("BSC detected truncated or mixed compiler state for target(%s) in %s; " ..
            "only this target's private Bluespec state should be rebuilt " ..
            "(run `xmake clean %s` and then build it again)\n%s",
            target:name(), util.state_dir(target), target:name(), errors)
    end
    raise("%s", errors ~= "" and errors or "BSC invocation failed")
end

function tools()
    if not tool_cache.bsc then
        local bsc = find_program("bsc")
        local bluetcl = find_program("bluetcl")
        if not bsc or not bluetcl then
            raise("bluespec-xmake requires both bsc and bluetcl in PATH; use shell.nix or set PATH")
        end
        tool_cache.bsc = bsc
        tool_cache.bluetcl = bluetcl
        local bscdir = os.getenv("BLUESPECDIR")
        if not bscdir or bscdir == "" then
            bscdir = path.join(path.directory(tool_cache.bsc), "..", "lib")
        end
        tool_cache.bluespecdir = path.absolute(bscdir)
        local version, _ = run_quiet(tool_cache.bsc, {"-v"})
        tool_cache.version = (version or "unknown"):gsub("\r", ""):gsub("\n+$", "")
    end
    return tool_cache
end

function version()
    return tools().version
end

function identity()
    local toolset = tools()
    return table.concat({toolset.bsc, toolset.bluetcl, toolset.bluespecdir, toolset.version}, "|")
end

-- BSC invokes native compilers internally for Bluesim/SystemC.  Derive both
-- its environment and its incremental identity from the target's compiler
-- slots, never from the shared-library linker slot (`sh` can be link.exe).
function execution_environment(target)
    local toolset = tools()
    local cc = target_driver(target, "cc")
    local cxx = target_driver(target, "cxx")
    return {
        BLUESPECDIR = toolset.bluespecdir,
        CC = cc.program,
        CXX = cxx.program,
    }, {cc = cc, cxx = cxx}
end

function execution_identity(target)
    local _, drivers = execution_environment(target)
    local values = {"bsc-native-toolchain-v1"}
    for _, kind in ipairs({"cc", "cxx"}) do
        local driver = drivers[kind]
        table.insert(values, table.concat({
            kind,
            driver.program,
            driver.name,
            driver.stamp,
        }, "="))
    end
    return table.concat(values, "|")
end

function builtin_dirs()
    local toolset = tools()
    local result = {}
    for _, name in ipairs({"Libraries", "BSVSource"}) do
        local directory = path.join(toolset.bluespecdir, name)
        if os.isdir(directory) then
            table.insert(result, directory)
        end
    end
    return result
end

function builtin_packages()
    local packages = {}
    for _, directory in ipairs(builtin_dirs()) do
        for _, pattern in ipairs({"*.bo", "**/*.bo"}) do
            for _, output in ipairs(os.files(path.join(directory, pattern))) do
                local name = path.basename(output)
                local extension = path.extension(name)
                if extension ~= "" then
                    name = name:sub(1, #name - #extension)
                end
                packages[name] = true
            end
        end
    end
    return packages
end

function run_depend(target, root, package_dirs, defines, options)
    local toolset = tools()
    local search = {}
    for _, dir in ipairs(util.list(package_dirs)) do
        table.insert(search, dir)
    end
    for _, dir in ipairs(builtin_dirs()) do
        table.insert(search, dir)
    end
    search = util.unique_sorted(search)

    local commands = {
        "Bluetcl::flags reset",
        "Bluetcl::flags set -p " .. quote_tcl(util.concat_path_list(search)),
    }
    local flags = {}
    for _, define in ipairs(util.list(defines)) do
        table.insert(flags, "-D")
        table.insert(flags, tostring(define))
    end
    for _, option in ipairs(util.list(options)) do
        if tostring(option) ~= "" then
            table.insert(flags, tostring(option))
        end
    end
    if #flags > 0 then
        local command = "Bluetcl::flags set"
        for _, flag in ipairs(flags) do
            command = command .. " " .. quote_tcl(flag)
        end
        table.insert(commands, command)
    end
    table.insert(commands, "puts [Bluetcl::depend make " .. quote_tcl(root) .. "]")
    table.insert(commands, "exit")

    -- Bluetcl is a Tcl API, but the process is driven entirely by Xmake Lua.
    -- The input file is an ephemeral stdin buffer and is removed immediately.
    local input = os.tmpfile()
    io.writefile(input, table.concat(commands, "\n") .. "\n")
    local output, errors
    local succeeded = try {
        function()
            output, errors = run_quiet(toolset.bluetcl, {}, {stdin = input})
            return true
        end,
        catch {
            function(run_errors)
                errors = tostring(run_errors)
            end,
        },
    }
    os.rm(input)
    if not succeeded then
        raise_bsc_state_error(target, errors)
    end
    if not output or output == "" then
        if errors and tostring(errors):find("BinData.getB: unexpected end of byte stream", 1, true) then
            raise_bsc_state_error(target, errors)
        end
        raise("Bluetcl dependency scan failed for %s\n%s", root, errors or "")
    end
    return output
end

function package_args(target, graph, package, backend)
    local toolset = tools()
    local args = {}
    local outdir = graph.output_dir
    local dirs = {}
    for _, dir in ipairs(graph.search_dirs or {}) do
        table.insert(dirs, dir)
    end
    for _, provider in pairs(graph.providers or {}) do
        if provider.output_dir then
            table.insert(dirs, provider.output_dir)
        end
    end
    for _, dir in ipairs(builtin_dirs()) do
        table.insert(dirs, dir)
    end
    table.insert(args, "-bdir")
    table.insert(args, outdir)
    table.insert(args, "-info-dir")
    table.insert(args, util.infodir(target))
    table.insert(args, "-p")
    table.insert(args, util.concat_path_list(dirs))
    for _, define in ipairs(graph.effective_defines or {}) do
        table.insert(args, "-D")
        table.insert(args, tostring(define))
    end
    for _, option in ipairs(graph.effective_options or {}) do
        table.insert(args, tostring(option))
    end
    if backend == "bluesim" then
        table.insert(args, "-sim")
    elseif backend == "verilog" then
        table.insert(args, "-verilog")
    elseif backend == "systemc" then
        table.insert(args, "-systemc")
    end
    if package then
        table.insert(args, package.source)
    end
    return toolset.bsc, args
end

function run_bsc(target, args)
    local toolset = tools()
    local envs = execution_environment(target)
    local errors
    local succeeded = try {
        function()
            os.vrunv(toolset.bsc, args, {envs = envs})
            return true
        end,
        catch {
            function(run_errors)
                errors = tostring(run_errors)
            end,
        },
    }
    if not succeeded then
        raise_bsc_state_error(target, errors)
    end
end
