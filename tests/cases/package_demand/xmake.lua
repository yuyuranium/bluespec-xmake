set_project("package-demand")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

for _, context in ipairs({{name = "a", value = 7}, {name = "b", value = 41}}) do
    target("leaf_" .. context.name)
        set_default(false)
        add_rules("bluespec.library")
        set_bsc_root("leaf/Leaf.bsv")
        add_bsc_defines("VALUE=" .. context.value, {public = true})
        add_bsc_options("-steps-warn-interval", tostring(100000 + context.value), {public = true})
    target("lib_" .. context.name)
        set_default(false)
        add_rules("bluespec.library")
        set_bsc_root("lib/Lib.bsv")
        add_deps("leaf_" .. context.name)
end

for _, endpoint in ipairs({
    {"sim_a", "a", "bluespec.bluesim"},
    {"sim_a2", "a", "bluespec.bluesim"},
    {"sim_b", "b", "bluespec.bluesim"},
    {"rtl", "a", "bluespec.verilog"},
    {"model", "a", "bluespec.systemc"},
}) do
    target(endpoint[1])
        set_default(false)
        set_group("endpoints")
        add_rules(endpoint[3])
        set_bsc_root("consumer/Top.bsv")
        set_bsc_top("mkTop")
        add_deps("lib_" .. endpoint[2])
end

target("check")
    set_default(false)
    add_rules("bluespec.check")
    set_bsc_root("consumer/Check.bsv")
    add_deps("lib_a")

target("sims")
    set_kind("phony")
    add_deps("sim_a", "sim_a2", "sim_b")

target("mixed")
    set_default(false)
    set_kind("phony")
    add_deps("sims", "rtl", "model", "check")
