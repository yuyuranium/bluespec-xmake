local config = import("core.project.config")
local resources = import("bluespec.resources")
local tools = import("bluespec.tools")
local util = import("bluespec.util")

local function enabled()
    local value = config.get("bluespec_trace_scan")
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

local function print_trace(event, target, root, scan_id, opt)
    if not enabled() then
        return
    end
    opt = opt or {}
    local now = os.mclock()
    print("BSC_SCAN_TRACE %s target=%s root=%s identity=%s owner=%s wall=%s monotonic_ms=%s elapsed_ms=%s status=%s",
        event, target:fullname(), root, scan_id or "", opt.owner or "",
        os.date("%Y-%m-%dT%H:%M:%S%z"), tostring(now),
        tostring(opt.started and (now - opt.started) or 0), tostring(opt.status or "pending"))
end

function trace(event, target, root, scan_id, opt)
    print_trace(event, target, canonical(root), scan_id, opt)
end

-- Full raw identity. Input stamps are intentionally runtime data: generated
-- BSV is ready by this point, and old scanner-discovered inputs are known.
function identity(root, package_dirs, defines, options, inputs)
    root = canonical(root)
    local parts = {
        "bluespec-raw-scan-v2",
        "root=" .. root,
        "scanner=" .. tools.scanner_identity(),
    }
    for index, directory in ipairs(tools.depend_search_dirs(package_dirs)) do
        table.insert(parts, string.format("search[%d]=%s", index, canonical(directory)))
    end
    for index, define in ipairs(util.list(defines)) do
        table.insert(parts, string.format("define[%d]=%s", index, tostring(define)))
    end
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

-- Only the actual Bluetcl process is inside the scan resource pool and the
-- PROCESS interval. Queueing for --bluespec_scan_jobs is therefore excluded
-- from process elapsed time and no duplicate target enters this function.
function process(target, root, package_dirs, defines, options, scan_id)
    root = canonical(root)
    return resources.with_scan(function()
        local started = os.mclock()
        print_trace("PROCESS_START", target, root, scan_id, {started = started})
        local raw
        local errors
        local succeeded = false
        try {
            function()
                raw = tools.run_depend(target, root, package_dirs, defines, options, {identity = scan_id})
                succeeded = true
            end,
            catch {
                function(run_errors)
                    errors = run_errors
                end,
            },
        }
        print_trace("PROCESS_END", target, root, scan_id, {
            started = started,
            status = succeeded and "0" or "failed",
        })
        if not succeeded then
            raise(errors or "Bluetcl dependency scan failed")
        end
        return raw
    end)
end

function depend(target, root, package_dirs, defines, options, inputs, opt)
    opt = opt or {}
    root = canonical(root)
    local _, scan_id = identity(root, package_dirs, defines, options, inputs)
    if opt.on_owner then
        opt.on_owner()
    end
    -- Direct callers do not participate in the scheduled build's dedup DAG.
    -- The normal rule path always uses graph.schedule_prepare(), where one
    -- explicit owner node is shared by target-specific finalize nodes.
    return process(target, root, package_dirs, defines, options, scan_id)
end
