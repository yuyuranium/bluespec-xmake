local util = import("bluespec.util")
local tools = import("bluespec.tools")
local parser = import("bluespec.parser")
local cache = import("bluespec.cache")
local progress = import("utils.progress")

local pending_orders = {}

local function data(target, key)
    return target:data(key)
end

local function is_bluespec(target)
    return data(target, "bluespec.rule") ~= nil
end

local function ordered_deps(target)
    local deps = target:orderdeps()
    if deps then
        return deps
    end
    return target:deps() or {}
end

local function append(dst, values)
    for _, value in ipairs(util.list(values)) do
        table.insert(dst, value)
    end
end

local function own_config(target)
    local dirs = util.package_dirs(target)
    local defines = util.defines(target)
    local options = util.options(target)
    local link_options = util.link_options(target)
    return dirs, defines, options, link_options
end

local function dep_graphs(target)
    local result = {}
    for _, dep in ipairs(ordered_deps(target)) do
        if is_bluespec(dep) then
            local graph = get(dep)
            if not graph then
                raise("Bluespec dependency target(%s) has no prepared graph; dependency scan ordering is invalid", dep:name())
            end
            table.insert(result, {target = dep, graph = graph})
        end
    end
    return result
end

local function effective_config(target, deps)
    local dirs, own_defines, own_options, own_link_options = own_config(target)
    local effective_dirs = {}
    append(effective_dirs, dirs.all)
    local effective_defines = {}
    append(effective_defines, own_defines.private)
    append(effective_defines, own_defines.public)
    append(effective_defines, own_defines.interface)
    local effective_options = {}
    append(effective_options, own_options.private)
    append(effective_options, own_options.public)
    append(effective_options, own_options.interface)
    local effective_link_options = {}
    append(effective_link_options, own_link_options.private)
    append(effective_link_options, own_link_options.public)
    append(effective_link_options, own_link_options.interface)
    local exported_dirs = {}
    append(exported_dirs, dirs.public)
    append(exported_dirs, dirs.interface)
    local exported_defines = {}
    append(exported_defines, own_defines.public)
    append(exported_defines, own_defines.interface)
    local exported_options = {}
    append(exported_options, own_options.public)
    append(exported_options, own_options.interface)
    local exported_link_options = {}
    append(exported_link_options, own_link_options.public)
    append(exported_link_options, own_link_options.interface)
    local dep_contexts = {}
    local dependency_exported_dirs = {}
    local scanner_dirs = {}
    for _, item in ipairs(deps) do
        local graph = item.graph
        -- Consumers compile against the dependency's package output.  Source
        -- exports are added separately to the scanner path below so a clean
        -- scan can discover provider imports before those outputs exist.
        local provider_dirs = {}
        local exports_any = false
        for _, exported in pairs(graph.exports or {}) do
            if exported then
                exports_any = true
                break
            end
        end
        if exports_any then
            table.insert(provider_dirs, graph.output_dir)
        end
        for _, provider in pairs(graph.providers or {}) do
            if provider.bo and provider.output_dir then
                table.insert(provider_dirs, provider.output_dir)
            end
        end
        append(effective_dirs, provider_dirs)
        -- The compile path must only expose dependency .bo outputs, but a
        -- clean dependency output directory is empty while prepare scans are
        -- running.  Let Bluetcl inspect exported provider sources during the
        -- scan so cross-target import edges are complete on the first build.
        -- finalize() still resolves those names through provider_index(), and
        -- package compilation continues to consume only provider .bo files.
        append(scanner_dirs, graph.exported_dirs)
        append(dependency_exported_dirs, graph.exported_dirs)
        append(effective_defines, graph.exported_defines)
        append(effective_options, graph.exported_options)
        append(effective_link_options, graph.exported_link_options)
        append(exported_dirs, graph.exported_dirs)
        append(exported_defines, graph.exported_defines)
        append(exported_options, graph.exported_options)
        append(exported_link_options, graph.exported_link_options)
        table.insert(dep_contexts, item.target:fullname() .. "=" .. tostring(graph.fingerprint))
    end
    append(scanner_dirs, effective_dirs)
    return {
        dirs = dirs,
        own_dirs = util.unique_sorted(dirs.all),
        search_dirs = util.unique_sorted(effective_dirs),
        scanner_dirs = util.unique_sorted(scanner_dirs),
        effective_defines = util.unique_sorted(effective_defines),
        effective_options = util.unique_sorted(effective_options),
        effective_link_options = util.unique_sorted(effective_link_options),
        exported_dirs = util.unique_sorted(exported_dirs),
        exported_defines = util.unique_sorted(exported_defines),
        exported_options = util.unique_sorted(exported_options),
        exported_link_options = util.unique_sorted(exported_link_options),
        dependency_exported_dirs = util.unique_sorted(dependency_exported_dirs),
        dep_contexts = util.sorted(dep_contexts),
    }
end

local function is_under(pathname, dirs)
    pathname = path.normalize(pathname)
    for _, dir in ipairs(dirs or {}) do
        dir = path.normalize(dir)
        if pathname == dir or pathname:sub(1, #dir + 1) == dir .. "/" then
            return true
        end
    end
    return false
end

local function provider_index(deps)
    local providers = {}
    local function add_provider(name, provider, owner)
        if providers[name] and providers[name].target ~= provider.target then
            raise("duplicate Bluespec package provider %s: target(%s) and target(%s)",
                name, providers[name].target, provider.target)
        end
        providers[name] = {
            target = provider.target,
            target_name = provider.target_name or owner:name(),
            output_dir = provider.output_dir,
            bo = provider.bo,
            source = provider.source,
            public_dirs = provider.public_dirs or {},
        }
    end
    for _, item in ipairs(deps) do
        local graph = item.graph
        for name, package in pairs(graph.packages or {}) do
            if graph.exports and graph.exports[name] then
                add_provider(name, {
                    target = item.target:fullname(),
                    target_name = item.target:name(),
                    output_dir = graph.output_dir,
                    bo = package.bo,
                    source = package.source,
                    public_dirs = graph.exported_dirs,
                }, item.target)
            end
        end
        for name, provider in pairs(graph.providers or {}) do
            if provider.bo then
                add_provider(name, provider, item.target)
            end
        end
    end
    return providers
end

local function config_items(target, config, old)
    local inputs = {}
    -- Track local source directories so added/removed package sources can
    -- invalidate the scan.  Dependency output directories are deliberately
    -- excluded: creating a provider .bo after prepare changes that directory
    -- mtime and would otherwise force an unchanged consumer to rescan on the
    -- next invocation.  Dependency graph fingerprints already propagate the
    -- provider's semantic changes.
    append(inputs, config.own_dirs)
    if old then
        for _, package in pairs(old.packages or {}) do
            for source in pairs(package.sources or {}) do
                table.insert(inputs, source)
            end
            for input in pairs(package.inputs or {}) do
                table.insert(inputs, input)
            end
        end
    end
    local values = {
        util.canonical_root(target),
        util.top(target, false) or "",
        table.concat(config.search_dirs, "\n"),
        table.concat(config.scanner_dirs, "\n"),
        table.concat(config.exported_dirs, "\n"),
        table.concat(config.effective_defines, "\n"),
        table.concat(config.effective_options, "\n"),
        table.concat(config.effective_link_options, "\n"),
        table.concat(config.dep_contexts, "\n"),
    }
    return util.unique_sorted(inputs), values
end

local function source_package_name(source)
    local name = path.basename(source)
    local extension = path.extension(name)
    if extension ~= "" then
        name = name:sub(1, #name - #extension)
    end
    return name
end

local function validate_local_sources(config)
    local providers = {}
    local builtins = tools.builtin_packages()
    for _, directory in ipairs(config.dirs.all or {}) do
        for _, source in ipairs(os.files(path.join(directory, "*.bsv"))) do
            local name = source_package_name(source)
            if builtins[name] then
                raise("source %s conflicts with the BSC builtin package %s", source, name)
            end
            if providers[name] and providers[name] ~= source then
                raise("duplicate Bluespec package source %s: %s and %s", name, providers[name], source)
            end
            providers[name] = source
        end
    end
end

local function finalize(target, parsed, config, deps)
    local output_dir = util.bdir(target)
    local providers = provider_index(deps)
    local packages = parsed.packages
    local exports = {}
    local owned = {}
    local builtin = {}

    for name in pairs(tools.builtin_packages()) do
        builtin[name] = true
    end

    -- Bluetcl represents builtin libraries as $(BLUESPECDIR)/Libraries/*.bo
    -- prerequisites without a corresponding source rule.  Remember those
    -- names so they are accepted as already-provided packages.
    for _, package in pairs(packages) do
        for name, dependency_path in pairs(package.dep_paths or {}) do
            if tostring(dependency_path):find("%$%(BLUESPECDIR%)", 1, false) or
                is_under(dependency_path, tools.builtin_dirs()) then
                builtin[name] = true
            end
        end
    end

    for name, package in pairs(packages) do
        local provider = providers[name]
        if provider then
            if builtin[name] and provider.source and not is_under(provider.source, tools.builtin_dirs()) then
                raise("package %s is provided by target(%s) but conflicts with a BSC builtin package",
                    name, provider.target_name)
            end
            if package.source and package.source ~= provider.source then
                if is_under(package.source, provider.public_dirs) then
                    raise("package %s is provided by target(%s), but target(%s) also found source %s",
                        name, provider.target_name, target:name(), package.source)
                elseif is_under(package.source, config.own_dirs) then
                    raise("package %s is provided by target(%s), but target(%s) owns conflicting source %s",
                        name, provider.target_name, target:name(), package.source)
                end
            end
        elseif package.source and is_under(package.source, config.dependency_exported_dirs) then
            raise("package %s is located in a dependency package directory but is not exported by that target", name)
        elseif builtin[name] then
            if package.source and not is_under(package.source, tools.builtin_dirs()) then
                raise("package %s in source %s conflicts with a BSC builtin package", name, package.source)
            end
        elseif package.source and is_under(package.source, tools.builtin_dirs()) then
            builtin[name] = true
        elseif not package.source then
            raise("package %s has no source, dependency provider, or BSC builtin", name)
        else
            owned[name] = true
            package.bo = path.join(output_dir, name .. ".bo")
            package.target = target:fullname()
            exports[name] = data(target, "bluespec.rule") == "bluespec.library"
        end
    end

    for name, package in pairs(packages) do
        for dep in pairs(package.deps or {}) do
            if not packages[dep] and not providers[dep] and not builtin[dep] then
                raise("package %s imports unresolved package %s", name, dep)
            end
        end
    end

    local source_inputs = {}
    for _, package in pairs(packages) do
        for source in pairs(package.sources or {}) do
            table.insert(source_inputs, source)
        end
        for input in pairs(package.inputs or {}) do
            table.insert(source_inputs, input)
        end
    end
    append(source_inputs, config.own_dirs)
    source_inputs = util.unique_sorted(source_inputs)
    local fingerprint = cache.fingerprint(target, source_inputs, {
        util.canonical_root(target),
        util.top(target, false) or "",
        table.concat(config.search_dirs, "\n"),
        table.concat(config.scanner_dirs, "\n"),
        table.concat(config.exported_dirs, "\n"),
        table.concat(config.effective_defines, "\n"),
        table.concat(config.effective_options, "\n"),
        table.concat(config.effective_link_options, "\n"),
        table.concat(config.dep_contexts, "\n"),
    })

    return {
        schema = 6,
        target = target:fullname(),
        root = parsed.root,
        root_name = parsed.root_name,
        top = util.top(target, false),
        output_dir = output_dir,
        packages = packages,
        order = parsed.order,
        owned = owned,
        exports = exports,
        builtin = builtin,
        providers = providers,
        search_dirs = config.search_dirs,
        scanner_dirs = config.scanner_dirs,
        exported_dirs = config.exported_dirs,
        effective_defines = config.effective_defines,
        effective_options = config.effective_options,
        effective_link_options = config.effective_link_options,
        exported_defines = config.exported_defines,
        exported_options = config.exported_options,
        exported_link_options = config.exported_link_options,
        dependency_exported_dirs = config.dependency_exported_dirs,
        dep_contexts = config.dep_contexts,
        fingerprint = fingerprint,
    }
end

local function cleanup_removed_packages(target, old, graph)
    if not old or not old.output_dir or path.normalize(old.output_dir) ~= path.normalize(graph.output_dir) then
        return
    end
    for name, package in pairs(old.packages or {}) do
        if old.owned and old.owned[name] and package.bo then
            local current = graph.packages and graph.packages[name]
            local current_bo = current and current.bo
            if current_bo ~= package.bo and is_under(package.bo, {old.output_dir}) then
                os.rm(package.bo)
                util.invalidate_artifact(package.bo)
                os.rm(target:dependfile(package.bo))
            end
        end
    end
end

local function discard_incomplete_packages(target, graph)
    if not graph or not graph.output_dir then
        return
    end
    for name, package in pairs(graph.packages or {}) do
        if graph.owned and graph.owned[name] and package.bo and
            is_under(package.bo, {graph.output_dir}) and os.isfile(package.bo) and
            not util.artifact_complete(package.bo) then
            -- The marker is removed before BSC starts and records the final
            -- output stamp only after success.  A missing/mismatched marker
            -- therefore identifies target-owned interrupted or truncated
            -- state without inspecting or deleting provider artifacts.
            os.rm(package.bo)
            util.invalidate_artifact(package.bo)
            os.rm(target:dependfile(package.bo))
        end
    end
end

function get(target)
    local graph = data(target, "bluespec.graph")
    return graph or cache.get(target)
end

function prepare(target, opt)
    local old = get(target)
    discard_incomplete_packages(target, old)
    local deps = dep_graphs(target)
    local config = effective_config(target, deps)
    validate_local_sources(config)
    local inputs, config_items_value = config_items(target, config, old)
    if old and not cache.changed(target, old, inputs, config_items_value) then
        target:data_set("bluespec.graph", old)
        return old
    end
    if opt and opt.progress then
        progress.show(opt.progress, "scanning Bluespec %s", target:name())
    end
    local raw = tools.run_depend(target, util.canonical_root(target), config.scanner_dirs,
        config.effective_defines, config.effective_options)
    local parsed = parser.parse(raw, util.canonical_root(target))
    local graph = finalize(target, parsed, config, deps)
    cleanup_removed_packages(target, old, graph)
    discard_incomplete_packages(target, graph)
    cache.set(target, graph)
    return graph
end

local function add_pending(dep_job, consumer_job)
    pending_orders[dep_job] = pending_orders[dep_job] or {}
    table.insert(pending_orders[dep_job], consumer_job)
end

function schedule_prepare(target, jobgraph)
    local job = target:fullname() .. "/bluespec/scan"
    if not jobgraph:has(job) then
        jobgraph:add(job, function(_, _, opt)
            prepare(target, opt)
        end)
    end
    local pending = pending_orders[job]
    if pending then
        for _, consumer_job in ipairs(pending) do
            jobgraph:add_orders(job, consumer_job)
        end
        pending_orders[job] = nil
    end
    for _, dep in ipairs(ordered_deps(target)) do
        if is_bluespec(dep) then
            local dep_job = dep:fullname() .. "/bluespec/scan"
            if jobgraph:has(dep_job) then
                jobgraph:add_orders(dep_job, job)
            else
                add_pending(dep_job, job)
            end
        end
    end
    target:data_set("bluespec.scan_job", job)
end
