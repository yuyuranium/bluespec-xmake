local config = import("core.project.config")
local scheduler = import("core.base.scheduler")

local pools = {}

local function configured_limit(name, default)
    local value = config.get(name)
    if value == nil or value == "" then
        value = default
    end
    value = tonumber(value)
    if not value or value < 0 or value ~= math.floor(value) then
        raise("--%s requires a non-negative integer, got %s", name, tostring(config.get(name)))
    end
    return value
end

local function pool(name, limit)
    if limit == 0 then
        return nil
    end
    local key = name .. "=" .. tostring(limit)
    if not pools[key] then
        local project = path.normalize(path.absolute(os.projectdir()))
        local semaphore_name = "bluespec-xmake/" .. tostring(hash.strhash64(project)) .. "/" .. key
        pools[key] = scheduler.co_semaphore(semaphore_name, limit)
        local trace = config.get("bluespec_trace_bsc")
        if trace == true or trace == "true" or trace == "yes" or trace == "y" or trace == "1" then
            print("BSC_RESOURCE pool=%s limit=%d", name, limit)
        end
    end
    return pools[key]
end

local function with_pool(semaphore, callback)
    if not semaphore then
        return callback()
    end
    semaphore:wait(-1)
    local results
    local errors
    local succeeded = false
    try {
        function()
            results = table.pack(callback())
            succeeded = true
        end,
        catch {
            function(run_errors)
                errors = run_errors
            end,
        },
        finally {
            function()
                semaphore:post(1)
            end,
        },
    }
    if not succeeded then
        raise(errors or "Bluespec resource-controlled operation failed")
    end
    return table.unpack(results, 1, results.n)
end

function with_backend(callback)
    local limit = configured_limit("bluespec_backend_jobs", 1)
    return with_pool(pool("backend", limit), callback)
end

function with_bsc(callback)
    local limit = configured_limit("bluespec_bsc_jobs", 0)
    return with_pool(pool("bsc", limit), callback)
end
