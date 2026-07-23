local util = import("bluespec.util")

local function add_unique(args, seen, kind, pair)
    local key = kind .. "\0" .. table.concat(pair, "\0")
    if not seen[key] then
        seen[key] = true
        table.insert(args, pair)
    end
end

local function add_xlink(args, seen, kind, value)
    add_unique(args, seen, kind, {"-Xl", value})
end

local function config_values(target, name)
    local result = {}
    local seen = {}
    local values = target:get_from(name, "*")
    for _, value in ipairs(util.list(values)) do
        value = tostring(value)
        if not seen[value] then
            seen[value] = true
            table.insert(result, value)
        end
    end
    return result
end

-- Xmake's orderdeps() is a flattened, ordered, deduplicated transitive
-- closure.  Keep that ordering while excluding Bluespec package targets,
-- whose .bo providers are handled by the package graph instead.
function dependencies(target)
    local result = {}
    local seen = {}
    for _, dep in ipairs(target:orderdeps()) do
        if not dep:data("bluespec.rule") and not seen[dep:fullname()] then
            seen[dep:fullname()] = true
            table.insert(result, dep)
        end
    end
    return result
end

-- A Bluesim model is a shared object.  Static Xmake dependencies that are
-- force-loaded into it therefore need position-independent objects on Unix.
-- PE/COFF targets do not use -fPIC.
function configure_bluesim(target)
    if target:is_plat("windows", "mingw") then
        return
    end
    for _, dep in ipairs(dependencies(target)) do
        if dep:is_static() and not dep:data("bluespec.bluesim.pic") then
            dep:add("cxflags", "-fPIC")
            dep:add("mxflags", "-fPIC")
            dep:add("asflags", "-fPIC")
            dep:data_set("bluespec.bluesim.pic", true)
        end
    end
end

local function add_static_archive(args, seen, target, archive)
    if target:is_plat("macosx", "iphoneos", "watchos", "appletvos", "visionos", "xros") then
        -- Apple ld has no --whole-archive state; -force_load applies to one
        -- archive and does not affect neighboring libraries.
        add_xlink(args, seen, "archive", "-Wl,-force_load," .. archive)
    elseif target:is_plat("windows") then
        -- MSVC link.exe/lld-link forced-load spelling.  MinGW is represented
        -- by Xmake's separate `mingw` platform and follows the GNU path.
        add_xlink(args, seen, "archive", "/WHOLEARCHIVE:" .. archive)
    else
        -- GNU ld, gold, and ELF lld process archives before BSC's generated
        -- model objects.  Scope whole-archive to this one dependency so the
        -- consumer's other libraries retain their normal semantics.
        add_xlink(args, seen, "archive-prefix:" .. archive, "-Wl,--whole-archive")
        add_xlink(args, seen, "archive", archive)
        add_xlink(args, seen, "archive-suffix:" .. archive, "-Wl,--no-whole-archive")
    end
end

function link_args(target)
    local args = {}
    local seen = {}
    for _, dep in ipairs(dependencies(target)) do
        local targetfile = dep:targetfile()
        if targetfile and targetfile ~= "" then
            targetfile = path.absolute(targetfile)
            if dep:is_static() then
                add_static_archive(args, seen, target, targetfile)
            else
                add_xlink(args, seen, "targetfile", targetfile)
            end
        end
        for _, linkdir in ipairs(util.list(dep:get("linkdirs"))) do
            add_unique(args, seen, "linkdir", {"-L", tostring(linkdir)})
        end
        for _, link in ipairs(util.list(dep:get("links"))) do
            add_unique(args, seen, "link", {"-l", tostring(link)})
        end
        for _, syslink in ipairs(util.list(dep:get("syslinks"))) do
            add_xlink(args, seen, "syslink", "-l" .. tostring(syslink))
        end
    end
    return args
end

function link_identity(target)
    local result = {}
    for _, pair in ipairs(link_args(target)) do
        local encoded = {}
        for _, value in ipairs(pair) do
            value = tostring(value)
            table.insert(encoded, tostring(#value) .. ":" .. value)
        end
        table.insert(result, table.concat(encoded))
    end
    return table.concat(result, "\n")
end

function include_dirs(target)
    return config_values(target, "includedirs")
end

function sysinclude_dirs(target)
    return config_values(target, "sysincludedirs")
end

-- BSC compiles and links part of a SystemC model internally. Mirror the
-- ordinary Xmake target/package configuration into that invocation. Each
-- compiler token is passed separately because BSC does not split -Xc++
-- arguments.
function systemc_args(target)
    local args = {}
    local seen = {}
    for _, directory in ipairs(include_dirs(target)) do
        add_unique(args, seen, "includedir", {"-Xc++", "-I" .. directory})
    end
    for _, directory in ipairs(sysinclude_dirs(target)) do
        add_unique(args, seen, "sysincludedir-flag:" .. directory, {"-Xc++", "-isystem"})
        add_unique(args, seen, "sysincludedir-path", {"-Xc++", directory})
    end
    for _, directory in ipairs(config_values(target, "linkdirs")) do
        add_unique(args, seen, "linkdir", {"-L", directory})
    end
    for _, link in ipairs(config_values(target, "links")) do
        add_unique(args, seen, "link", {"-l", link})
    end
    for _, link in ipairs(config_values(target, "syslinks")) do
        add_unique(args, seen, "syslink", {"-l", link})
    end
    for _, flag in ipairs(config_values(target, "ldflags")) do
        add_xlink(args, seen, "ldflag", flag)
    end
    for _, dep in ipairs(dependencies(target)) do
        local targetfile = dep:targetfile()
        if targetfile and targetfile ~= "" then
            targetfile = path.absolute(targetfile)
            if dep:is_static() then
                add_static_archive(args, seen, target, targetfile)
            else
                add_xlink(args, seen, "targetfile", targetfile)
            end
        end
    end
    return args
end

function systemc_identity(target)
    local result = {}
    for _, pair in ipairs(systemc_args(target)) do
        local encoded = {}
        for _, value in ipairs(pair) do
            value = tostring(value)
            table.insert(encoded, tostring(#value) .. ":" .. value)
        end
        table.insert(result, table.concat(encoded))
    end
    return table.concat(result, "\n")
end

function targetfiles(target)
    local files = {}
    for _, dep in ipairs(dependencies(target)) do
        local targetfile = dep:targetfile()
        if targetfile and targetfile ~= "" then
            table.insert(files, path.absolute(targetfile))
        end
    end
    return util.unique_sorted(files)
end
