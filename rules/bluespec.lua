-- Public Bluespec rules and description-scope helpers.

add_moduledirs(path.join(os.scriptdir(), "../modules"))

option("bluespec_backend_jobs")
    set_default(1)
    set_showmenu(true)
    set_description("Maximum concurrent Bluespec backend elaborations (0 inherits Xmake -j)")

option("bluespec_bsc_jobs")
    set_default(0)
    set_showmenu(true)
    set_description("Maximum concurrent BSC processes, including package compiles (0 inherits Xmake -j)")

option("bluespec_scan_jobs")
    set_default(0)
    set_showmenu(true)
    set_description("Maximum concurrent Bluetcl dependency scans (0 inherits Xmake -j)")

option("bluespec_trace_bsc")
    set_default(false)
    set_showmenu(true)
    set_description("Trace BSC job identity, argv, paths, PID capability and timing")

option("bluespec_trace_scan")
    set_default(false)
    set_showmenu(true)
    set_description("Trace Bluetcl process, shared owner, duplicate and finalize timing")

-- Xmake's custom description API turns these into target-scope helpers while
-- keeping the canonical low-level representation in target values.
local function single_value_api(name)
    return function(interp, ...)
        return interp:api_call("add_values", name, ...)
    end
end

local function declaration_absolute(interp, pathname)
    pathname = tostring(pathname)
    if path.is_absolute(pathname) then
        return path.normalize(pathname)
    end
    -- This callback runs in Xmake's description interpreter.  Its scriptdir
    -- is the xmake.lua that declared the target, including nested includes.
    return path.normalize(path.absolute(pathname, interp:scriptdir()))
end

local function path_single_value_api(name)
    return function(interp, ...)
        local arguments = {...}
        for _, value in ipairs(arguments) do
            interp:api_call("add_values", name, declaration_absolute(interp, value))
        end
    end
end

local function append_value(values, value)
    if type(value) == "table" and not table.is_dictionary(value) then
        for _, item in ipairs(value) do
            append_value(values, item)
        end
    else
        table.insert(values, value)
    end
end

local option_group_prefix = "__bluespec_option_group_v1__:"

local function encode_option_group(values)
    local encoded = option_group_prefix
    for _, value in ipairs(values) do
        value = tostring(value)
        encoded = encoded .. tostring(#value) .. ":" .. value
    end
    return encoded
end

local function add_visibility_api(name, path_valued, grouped)
    return function(interp, ...)
        local arguments = {...}
        local options = {}
        if type(arguments[#arguments]) == "table" and table.is_dictionary(arguments[#arguments]) then
            options = table.remove(arguments)
        end
        local values = {}
        for _, argument in ipairs(arguments) do
            append_value(values, argument)
        end
        local visibility = options.visibility or
            (options.public and "public") or (options.interface and "interface") or "private"
        visibility = tostring(visibility):lower()
        if visibility ~= "private" and visibility ~= "public" and visibility ~= "interface" then
            raise("invalid Bluespec visibility %s (expected private, public, or interface)", visibility)
        end
        local storage_name = name .. "." .. visibility
        if grouped then
            local group = {}
            for _, value in ipairs(values) do
                if path_valued then
                    value = declaration_absolute(interp, value)
                end
                table.insert(group, value)
            end
            -- Keep one add_bsc_options() invocation as one ordered group.
            -- This lets option/value pairs and RTS groups survive dependency
            -- propagation without exposing a manifest or parser runtime.
            interp:api_call("add_values", storage_name, encode_option_group(group))
        else
            for _, value in ipairs(values) do
                if path_valued then
                    value = declaration_absolute(interp, value)
                end
                -- Store helpers in the same canonical namespace accepted by
                -- set_values(), while retaining no separate public manifest.
                interp:api_call("add_values", storage_name, value)
            end
        end
    end
end

interp_add_scopeapis({
    values = {
        {"target.set_bsc_root", path_single_value_api("bluespec.root")},
        {"target.set_bsc_top", single_value_api("bluespec.top")},
        {"target.add_bsc_package_dirs", add_visibility_api("bluespec.package_dirs", true)},
        {"target.add_bsc_defines", add_visibility_api("bluespec.defines")},
        {"target.add_bsc_options", add_visibility_api("bluespec.options", false, true)},
        {"target.add_bsc_link_options", add_visibility_api("bluespec.link_options")},
    }
})

local function define_rule(name, backend, required_kind, needs_top)
    rule(name)
        set_extensions(".bsv")

        on_load(function(target)
            local util = import("bluespec.util")
            local config = import("core.project.config")
            target:data_set("bluespec.rule", backend)
            local root = util.canonical_root(target)
            if not target:data("bluespec.root_added") then
                target:add("files", root, {rules = name})
                target:data_set("bluespec.root_added", true)
            end
            target:set("kind", required_kind)
            if backend == "verilog" then
                -- A phony target has no targetfile() in Xmake.  Model the
                -- deterministic filelist as this custom-built target's
                -- primary artifact so ordinary dependency consumers can use
                -- dep:targetfile() without knowing the internal RTL layout.
                if not target:get("targetdir") then
                    local targetdir = path.join(config.builddir(), "Verilog")
                    local namespace = target:namespace()
                    if namespace then
                        namespace = namespace:gsub("::", "/")
                        targetdir = path.join(targetdir, namespace)
                    end
                    target:set("targetdir", targetdir)
                end
                if not target:get("filename") then
                    target:set("filename", target:name() .. ".f")
                end
            end
            if needs_top then
                util.top(target, true)
            end
            if backend == "bluesim" and not target:get("targetdir") then
                target:set("targetdir", path.join(config.builddir(), "bin"))
            end
            if backend == "systemc" then
                local include_dir = path.join(util.backend_dir(target, "systemc"), "include")
                target:add("includedirs", include_dir, {public = true})
                -- The generated archive contains SystemC model objects; its
                -- native consumers must inherit the SystemC link requirement.
                target:add("links", "systemc", {public = true})
            end
        end)

        after_load(function(target)
            if backend == "bluesim" then
                import("bluespec.native").configure_bluesim(target)
            end
        end)

        -- File-level prepare hooks are the same phase Xmake's C++ module
        -- scanner uses: generated/source files are ready before the package
        -- graph is consumed by build jobs.
        on_prepare_files(function(target, jobgraph, sourcebatch, opt)
            import("bluespec.graph").schedule_prepare(target, jobgraph)
        end, {jobgraph = true})
        -- Keep a target-level hook as well.  Phony artifact-set targets do
        -- not always enter Xmake's file-job runner, while the target hook is
        -- still part of the same prepare jobgraph and is idempotent.
        on_prepare(function(target, jobgraph, opt)
            import("bluespec.graph").schedule_prepare(target, jobgraph)
        end, {jobgraph = true})

        on_build(function(target, jobgraph)
            import("bluespec.jobs").schedule_build(target, jobgraph, backend)
        end, {jobgraph = true})

        before_build_files(function(target, jobgraph, sourcebatch, opt)
            import("bluespec.jobs").schedule_build(target, jobgraph, backend)
        end, {jobgraph = true, batch = true})

        on_clean(function(target)
            local util = import("bluespec.util")
            os.rm(util.state_dir(target))
            if backend == "verilog" and target:targetfile() then
                os.rm(util.verilog_filelist(target))
                os.rm(util.verilog_dir(target))
            end
        end)
end

define_rule("bluespec.library", "bluespec.library", "phony", false)
define_rule("bluespec.check", "bluespec.check", "phony", false)
define_rule("bluespec.bluesim", "bluesim", "binary", true)
define_rule("bluespec.verilog", "verilog", "binary", true)
define_rule("bluespec.systemc", "systemc", "static", true)
