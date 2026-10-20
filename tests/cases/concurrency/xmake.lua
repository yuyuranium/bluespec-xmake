set_project("bluespec-concurrency")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

for index = 1, 4 do
    target("rtl" .. index)
        add_rules("bluespec.verilog")
        set_bsc_root(path.join("src", "Top" .. index .. ".bsv"))
        set_bsc_top("mkTop" .. index)
        -- Each endpoint owns an imported package job as well as its top job.
        add_bsc_package_dirs("src")
end

local function define_resource_probe(name)
    target("resource_" .. name .. "_probe")
        set_kind("phony")
        set_default(false)
        on_build(function()
            local resources = import("bluespec.resources")
            resources["with_" .. name](function() end)
        end)
end

for _, name in ipairs({"backend", "bsc", "scan"}) do
    define_resource_probe(name)
end

target("resource_option_metadata")
    set_kind("phony")
    set_default(false)
    on_build(function()
        local project = import("core.project.project")
        for _, name in ipairs({
            "bluespec_backend_jobs",
            "bluespec_bsc_jobs",
            "bluespec_scan_jobs",
        }) do
            local option = assert(project.option(name), "missing project option " .. name)
            local default = option:get("default")
            print("RESOURCE_OPTION name=%s type=%s default=%s", name, type(default), tostring(default))
        end
    end)

target("seed_boolean_resource_option")
    set_kind("phony")
    set_default(false)
    on_build(function()
        if os.getenv("BLUESPEC_FAKE_SEED_BOOLEAN") == "1" then
            local config = import("core.project.config")
            config.set("bluespec_bsc_jobs", true)
            config.save()
        end
    end)
