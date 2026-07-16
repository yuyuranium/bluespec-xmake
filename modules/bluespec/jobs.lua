local util = import("bluespec.util")
local tools = import("bluespec.tools")
local graphmod = import("bluespec.graph")
local native = import("bluespec.native")
local compiler = import("core.tool.compiler")
local linker = import("core.tool.linker")
local depend = import("core.project.depend")
local progress = import("utils.progress")
local pending_orders = {}

local function package_job(target, name)
    return target:fullname() .. "/bluespec/package/" .. name
end

local function backend_job(target, backend)
    return target:fullname() .. "/bluespec/backend/" .. backend
end

local function package_names(graph)
    local result = {}
    for _, name in ipairs(graph.order or {}) do
        if graph.owned and graph.owned[name] then
            table.insert(result, name)
        end
    end
    table.sort(result)
    return result
end

local function provider_job(jobgraph, provider, package_name)
    if not provider or not provider.target then
        return nil
    end
    return provider.target .. "/bluespec/package/" .. package_name
end

local function add_order(jobgraph, before, after)
    if jobgraph:has(before) and jobgraph:has(after) then
        jobgraph:add_orders(before, after)
    else
        pending_orders[before] = pending_orders[before] or {}
        table.insert(pending_orders[before], after)
    end
end

local function flush_orders(jobgraph, job)
    local pending = pending_orders[job]
    if pending then
        for _, after in ipairs(pending) do
            if jobgraph:has(after) then
                jobgraph:add_orders(job, after)
            end
        end
        pending_orders[job] = nil
    end
end

local function schedule_packages(target, jobgraph, graph, backend)
    local names = package_names(graph)
    local jobs = {}
    for _, name in ipairs(names) do
        local package = graph.packages[name]
        if package.source then
            local job = package_job(target, name)
            jobs[name] = job
            if not jobgraph:has(job) then
                jobgraph:add(job, function(index, total, opt)
                    local inputs = {package.source}
                    for input in pairs(package.inputs or {}) do
                        table.insert(inputs, input)
                    end
                    for depname in pairs(package.deps or {}) do
                        local dep_package = graph.packages[depname]
                        local provider = graph.providers and graph.providers[depname]
                        if dep_package and dep_package.bo then
                            table.insert(inputs, dep_package.bo)
                        elseif provider and provider.bo then
                            table.insert(inputs, provider.bo)
                        end
                    end
                    inputs = util.unique_sorted(inputs)
                    local values = {
                        name,
                        graph.fingerprint,
                        tools.identity(),
                        table.concat(graph.effective_defines or {}, "\n"),
                        table.concat(graph.effective_options or {}, "\n"),
                    }
                    depend.on_changed(function()
                        if opt and opt.progress then
                            progress.show(opt.progress, "compiling Bluespec package %s", name)
                        end
                        os.mkdir(graph.output_dir)
                        local program, args = tools.package_args(target, graph, package, nil)
                        tools.run_bsc(target, args)
                        return {}
                    end, {
                        dependfile = target:dependfile(package.bo),
                        files = inputs,
                        values = values,
                        changed = target:is_rebuilt() or not os.isfile(package.bo),
                    })
                end)
            end
            flush_orders(jobgraph, job)
        end
    end

    for _, name in ipairs(names) do
        local package = graph.packages[name]
        local job = jobs[name]
        if job then
            for dep in pairs(package.deps or {}) do
                local depjob = jobs[dep]
                if not depjob then
                    depjob = provider_job(jobgraph, graph.providers and graph.providers[dep], dep)
                end
                if depjob then
                    add_order(jobgraph, depjob, job)
                end
            end
        end
    end
    target:data_set("bluespec.package_jobs", jobs)
    return jobs
end

local function append_pairs(args, pairs)
    for _, pair in ipairs(pairs or {}) do
        for _, value in ipairs(pair) do
            table.insert(args, value)
        end
    end
end

local function backend_args(target, graph, backend, phase)
    local program, args = tools.package_args(target, graph, nil, backend)
    local outdir = util.backend_dir(target, backend)
    if backend == "bluesim" then
        table.insert(args, "-simdir")
        table.insert(args, outdir)
    elseif backend == "verilog" then
        table.insert(args, "-vdir")
        table.insert(args, outdir)
    elseif backend == "systemc" then
        table.insert(args, "-simdir")
        table.insert(args, outdir)
    end
    if phase == "generate" then
        if backend == "systemc" then
            table.insert(args, "-e")
            table.insert(args, assert(graph.top, "Bluespec backend requires a top module"))
        else
            table.insert(args, "-g")
            table.insert(args, assert(graph.top, "Bluespec backend requires a top module"))
            table.insert(args, "-u")
            table.insert(args, graph.root)
        end
    elseif phase == "link" then
        table.insert(args, "-e")
        table.insert(args, assert(graph.top, "Bluespec backend requires a top module"))
        table.insert(args, "-o")
        table.insert(args, path.absolute(target:targetfile()))
        append_pairs(args, native.link_args(target))
        for _, option in ipairs(graph.effective_link_options or {}) do
            table.insert(args, "-Xl")
            table.insert(args, option)
        end
    end
    return program, args
end

local function generated_sources(directory)
    local result = {}
    for _, pattern in ipairs({"*.c", "*.cc", "*.cpp", "*.cxx"}) do
        for _, source in ipairs(os.files(path.join(directory, pattern))) do
            table.insert(result, source)
        end
        for _, source in ipairs(os.files(path.join(directory, "**", pattern))) do
            table.insert(result, source)
        end
    end
    local unique = {}
    local ordered = {}
    for _, source in ipairs(result) do
        if not unique[source] then
            unique[source] = true
            table.insert(ordered, source)
        end
    end
    table.sort(ordered)
    return ordered
end

local function build_systemc(target, graph)
    local systemc_dir = util.backend_dir(target, "systemc")
    os.rm(systemc_dir)
    os.mkdir(systemc_dir)
    local include_dir = path.join(systemc_dir, "include")
    os.mkdir(include_dir)
    -- SystemC elaboration consumes the Bluesim .ba/object closure first;
    -- the SystemC link step then emits the native C/C++ model sources.
    local _, elaboration_args = tools.package_args(target, graph, nil, "bluesim")
    table.insert(elaboration_args, "-simdir")
    table.insert(elaboration_args, systemc_dir)
    table.insert(elaboration_args, "-g")
    table.insert(elaboration_args, assert(graph.top, "Bluespec backend requires a top module"))
    table.insert(elaboration_args, "-u")
    table.insert(elaboration_args, graph.root)
    tools.run_bsc(target, elaboration_args)
    local program, args = backend_args(target, graph, "systemc", "generate")
    local bsc_output = path.join(util.backend_dir(target, "systemc"), ".bsc-systemc-model")
    table.insert(args, "-o")
    table.insert(args, bsc_output)
    for _, includedir in ipairs(target:get("includedirs") or {}) do
        table.insert(args, "-Xc++")
        table.insert(args, "-I" .. includedir)
    end
    for _, includedir in ipairs(native.include_dirs(target)) do
        table.insert(args, "-Xc++")
        table.insert(args, "-I" .. includedir)
    end
    tools.run_bsc(target, args)
    local headers = {}
    for _, pattern in ipairs({"*.h", "*.hh", "*.hpp", "*.hxx"}) do
        for _, header in ipairs(os.files(path.join(systemc_dir, pattern))) do
            table.insert(headers, header)
        end
        for _, header in ipairs(os.files(path.join(systemc_dir, "**", pattern))) do
            if path.normalize(header) ~= path.normalize(include_dir) and
                not (path.normalize(header):sub(1, #path.normalize(include_dir) + 1) ==
                    path.normalize(include_dir) .. "/") then
                table.insert(headers, header)
            end
        end
    end
    for _, header in ipairs(headers) do
        local relative = path.relative(header, systemc_dir)
        local destination = path.join(include_dir, relative)
        os.mkdir(path.directory(destination))
        os.cp(header, destination)
    end
    local sources = generated_sources(util.backend_dir(target, "systemc"))
    if #sources == 0 then
        raise("BSC SystemC backend produced no C/C++ sources for target(%s)", target:name())
    end
    local objects = {}
    for _, source in ipairs(sources) do
        local object = target:objectfile(source)
        os.mkdir(path.directory(object))
        local includedirs = {
            include_dir,
            path.join(tools.tools().bluespecdir, "Bluesim"),
        }
        for _, directory in ipairs(target:get("includedirs") or {}) do
            table.insert(includedirs, directory)
        end
        for _, directory in ipairs(native.include_dirs(target)) do
            table.insert(includedirs, directory)
        end
        local configs = {includedirs = includedirs}
        compiler.compile(source, object, {target = target, configs = configs})
        table.insert(objects, object)
    end
    linker.link("static", "cxx", objects, path.absolute(target:targetfile()), {target = target})
    os.rm(bsc_output)
end

local function build_verilog(target, graph)
    local rtl_dir = util.backend_dir(target, "verilog")
    os.rm(rtl_dir)
    os.mkdir(rtl_dir)
    local program, args = backend_args(target, graph, "verilog", "generate")
    tools.run_bsc(target, args)
    local files = os.files(path.join(rtl_dir, "*.v"))
    table.sort(files)
    if #files == 0 then
        raise("BSC Verilog backend produced no Verilog files for target(%s)", target:name())
    end
    local filelist = path.join(rtl_dir, target:name() .. ".f")
    local lines = {}
    for _, file in ipairs(files) do
        table.insert(lines, file)
    end
    io.writefile(filelist, table.concat(lines, "\n") .. "\n")
    target:data_set("bluespec.verilog.filelist", filelist)
end

local function build_bluesim(target, graph)
    local sim_dir = util.backend_dir(target, "bluesim")
    os.rm(sim_dir)
    os.mkdir(sim_dir)
    local program, args = backend_args(target, graph, "bluesim", "generate")
    tools.run_bsc(target, args)
    local link_program, link_args = backend_args(target, graph, "bluesim", "link")
    os.mkdir(path.directory(path.absolute(target:targetfile())))
    tools.run_bsc(target, link_args)
end

local function backend_inputs(target, graph)
    local files = {}
    for _, package in pairs(graph.packages or {}) do
        if package.bo then
            table.insert(files, package.bo)
        end
    end
    for _, provider in pairs(graph.providers or {}) do
        if provider.bo then
            table.insert(files, provider.bo)
        end
    end
    -- Native BDPI/static dependencies are ordinary Xmake targets.  Their
    -- archives must participate in the backend dependfile just like `.bo`
    -- providers do.
    for _, targetfile in ipairs(native.targetfiles(target)) do
        table.insert(files, targetfile)
    end
    return util.unique_sorted(files)
end

local function backend_ready(target, graph, backend)
    if backend == "bluesim" then
        local output = path.absolute(target:targetfile())
        return os.isfile(output) and os.isfile(output .. ".so")
    elseif backend == "verilog" then
        local directory = util.backend_dir(target, "verilog")
        return os.isfile(path.join(directory, target:name() .. ".f")) and
            #os.files(path.join(directory, "*.v")) > 0
    elseif backend == "systemc" then
        local include_dir = path.join(util.backend_dir(target, "systemc"), "include")
        local headers = os.files(path.join(include_dir, "*.h"))
        for _, pattern in ipairs({"*.hh", "*.hpp", "*.hxx"}) do
            for _, header in ipairs(os.files(path.join(include_dir, pattern))) do
                table.insert(headers, header)
            end
        end
        for _, pattern in ipairs({"*.h", "*.hh", "*.hpp", "*.hxx"}) do
            for _, header in ipairs(os.files(path.join(include_dir, "**", pattern))) do
                table.insert(headers, header)
            end
        end
        return os.isfile(path.absolute(target:targetfile())) and
            #headers > 0
    end
    return true
end

local function backend_depend(target, graph, backend, callback)
    local marker
    if backend == "verilog" then
        marker = path.join(util.backend_dir(target, "verilog"), target:name() .. ".f")
    else
        marker = path.absolute(target:targetfile())
    end
    local values = {
        backend,
        graph.fingerprint,
        graph.top or "",
        tools.identity(),
        table.concat(graph.effective_link_options or {}, "\n"),
        table.concat(util.list(target:get("links")), "\n"),
        table.concat(util.list(target:get("linkdirs")), "\n"),
        table.concat(util.list(target:get("syslinks")), "\n"),
        native.link_identity(target),
    }
    depend.on_changed(callback, {
        dependfile = target:dependfile(marker),
        files = backend_inputs(target, graph),
        values = values,
        changed = target:is_rebuilt() or not backend_ready(target, graph, backend),
    })
end

local function schedule_backend(target, jobgraph, graph, backend, package_jobs)
    local job = backend_job(target, backend)
    if not jobgraph:has(job) then
        jobgraph:add(job, function(index, total, opt)
            local function show_progress()
                if opt and opt.progress then
                    progress.show(opt.progress, "building Bluespec %s %s", backend, target:name())
                end
            end
            if backend == "bluesim" then
                backend_depend(target, graph, backend, function()
                    show_progress()
                    build_bluesim(target, graph)
                    return {}
                end)
            elseif backend == "verilog" then
                backend_depend(target, graph, backend, function()
                    show_progress()
                    build_verilog(target, graph)
                    return {}
                end)
            elseif backend == "systemc" then
                backend_depend(target, graph, backend, function()
                    show_progress()
                    build_systemc(target, graph)
                    return {}
                end)
            end
        end)
    end
    for _, package_job_name in pairs(package_jobs) do
        if jobgraph:has(package_job_name) then
            add_order(jobgraph, package_job_name, job)
        end
    end
    target:data_set("bluespec.backend_job", job)
end

function schedule_build(target, jobgraph, backend)
    local graph = graphmod.get(target)
    if not graph then
        raise("target(%s) has no Bluespec graph; prepare phase did not run", target:name())
    end
    local package_jobs = schedule_packages(target, jobgraph, graph, backend)
    if backend == "bluesim" or backend == "verilog" or backend == "systemc" then
        schedule_backend(target, jobgraph, graph, backend, package_jobs)
    end
end
