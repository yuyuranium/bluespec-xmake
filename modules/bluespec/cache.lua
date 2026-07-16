local localcache = import("core.cache.localcache")
local config = import("core.project.config")
local tools = import("bluespec.tools")

local memory = {}
local cache_name = "bluespec-xmake"

local function absolute(pathname)
    return path.normalize(path.absolute(pathname))
end

local function target_key(target)
    return table.concat({
        "schema=3",
        "project=" .. absolute(os.projectdir()),
        "target=" .. target:fullname(),
        "plat=" .. tostring(target:plat()),
        "arch=" .. tostring(target:arch()),
        "mode=" .. tostring(target:get("mode") or config.mode() or ""),
        "builddir=" .. absolute(config.builddir({absolute = true})),
        "autogendir=" .. absolute(target:autogendir()),
        "targetdir=" .. absolute(target:targetdir()),
    }, "|")
end

local function stat(pathname)
    if os.isfile(pathname) then
        return tostring(os.mtime(pathname) or 0) .. ":" .. tostring(os.filesize(pathname) or 0)
    elseif os.isdir(pathname) then
        return tostring(os.mtime(pathname) or 0)
    end
    return "missing"
end

function key(target)
    return target_key(target)
end

function get(target)
    local key = target_key(target)
    if memory[key] then
        return memory[key]
    end
    local value = localcache.get(cache_name, key)
    if value then
        memory[key] = value
    end
    return value
end

function set(target, value)
    local key = target_key(target)
    memory[key] = value
    target:data_set("bluespec.graph", value)
    localcache.set(cache_name, key, value)
    localcache.save(cache_name)
end

function fingerprint(target, inputs, config)
    local parts = {
        "schema=3",
        "target=" .. target_key(target),
        "bsc=" .. tools.identity(),
    }
    for _, value in ipairs(config or {}) do
        table.insert(parts, "config=" .. tostring(value))
    end
    for _, pathname in ipairs(inputs or {}) do
        table.insert(parts, pathname .. "=" .. stat(pathname))
    end
    table.sort(parts)
    return tostring(hash.strhash64(table.concat(parts, "\n")))
end

function changed(target, old_graph, inputs, config)
    if not old_graph or not old_graph.fingerprint then
        return true
    end
    return old_graph.fingerprint ~= fingerprint(target, inputs, config)
end
