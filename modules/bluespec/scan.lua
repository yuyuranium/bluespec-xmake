local config = import("core.project.config")
local scheduler = import("core.base.scheduler")
local tools = import("bluespec.tools")
local util = import("bluespec.util")

-- This table deliberately lives only for the current Xmake invocation.  The
-- target graph/depend cache remains responsible for cross-invocation reuse.
local flights = {}

local function enabled(name)
    local value = config.get(name)
    return value == true or value == "true" or value == "yes" or value == "y" or value == "1"
end

local function stamp(pathname)
    if os.isfile(pathname) then
        return tostring(os.mtime(pathname) or 0) .. ":" .. tostring(os.filesize(pathname) or 0)
    elseif os.isdir(pathname) then
        return "dir:" .. tostring(os.mtime(pathname) or 0)
    end
    return "missing"
end

local function canonical(pathname)
    return path.normalize(path.absolute(pathname, os.projectdir()))
end

local function identity(root, package_dirs, defines, options, inputs)
    root = canonical(root)
    local parts = {
        "bluespec-raw-scan-v1",
        "root=" .. root,
        "scanner=" .. tools.scanner_identity(),
    }
    for index, directory in ipairs(tools.depend_search_dirs(package_dirs)) do
        table.insert(parts, string.format("search[%d]=%s", index, canonical(directory)))
    end
    for index, define in ipairs(util.list(defines)) do
        table.insert(parts, string.format("define[%d]=%s", index, tostring(define)))
    end
    -- BSC options are argv, not a set: preserve their effective order.
    for index, option in ipairs(util.list(options)) do
        table.insert(parts, string.format("option[%d]=%s", index, tostring(option)))
    end
    local scan_inputs = {root}
    for _, pathname in ipairs(util.list(inputs)) do
        table.insert(scan_inputs, canonical(pathname))
    end
    for _, directory in ipairs(tools.depend_search_dirs(package_dirs)) do
        table.insert(scan_inputs, canonical(directory))
    end
    for _, pathname in ipairs(util.unique_sorted(scan_inputs)) do
        table.insert(parts, "input=" .. pathname .. "=" .. stamp(pathname))
    end
    local key = table.concat(parts, "\n")
    return key, tostring(hash.strhash64(key))
end

local function trace(target, root, scan_id, event, mode, started, status)
    if not enabled("bluespec_trace_scan") then
        return
    end
    local now = os.mclock()
    print("BSC_SCAN_TRACE %s target=%s root=%s identity=%s mode=%s wall=%s monotonic_ms=%s elapsed_ms=%s status=%s",
        event, target:fullname(), root, scan_id, mode,
        os.date("%Y-%m-%dT%H:%M:%S%z"), tostring(now),
        tostring(started and (now - started) or 0), tostring(status or "pending"))
end

local function result(state, target, root, scan_id, mode, started)
    if state.succeeded then
        trace(target, root, scan_id, "END", mode, started, "0")
        return state.raw, scan_id
    end
    trace(target, root, scan_id, "END", mode, started, "failed")
    raise(state.errors or "shared Bluetcl dependency scan failed")
end

function depend(target, root, package_dirs, defines, options, inputs, opt)
    opt = opt or {}
    root = canonical(root)
    local key, scan_id = identity(root, package_dirs, defines, options, inputs)
    local started = os.mclock()
    local state = flights[key]
    if state then
        if state.done then
            trace(target, root, scan_id, "START", "reuse", started)
            return result(state, target, root, scan_id, "reuse", started)
        end
        state.waiters = state.waiters + 1
        trace(target, root, scan_id, "START", "wait", started)
        state.semaphore:wait(-1)
        return result(state, target, root, scan_id, "wait", started)
    end

    state = {
        done = false,
        succeeded = false,
        waiters = 0,
        semaphore = scheduler.co_semaphore("bluespec-xmake/scan/" .. scan_id, 0),
    }
    flights[key] = state
    if opt.on_owner then
        opt.on_owner()
    end
    trace(target, root, scan_id, "START", "owner", started)
    try {
        function()
            state.raw = tools.run_depend(target, root, package_dirs, defines, options, {identity = scan_id})
            state.succeeded = true
        end,
        catch {
            function(errors)
                state.errors = errors
            end,
        },
        finally {
            function()
                state.done = true
                if state.waiters > 0 then
                    state.semaphore:post(state.waiters)
                end
            end,
        },
    }
    return result(state, target, root, scan_id, "owner", started)
end
