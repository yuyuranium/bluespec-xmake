set_project("systemc-isolation")
set_languages("c++17")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

for _, model in ipairs({
    {name = "first", source = "First.bsv", top = "mkFirst", value = 7},
    {name = "second", source = "Second.bsv", top = "mkSecond", value = 41},
}) do
    target(model.name)
        add_rules("bluespec.systemc")
        set_bsc_root(model.source)
        set_bsc_top(model.top)
        add_bsc_defines("INITIAL_VALUE=" .. model.value)
end

target("consumer")
    set_kind("binary")
    add_files("consumer.cc")
    add_deps("first", "second")
