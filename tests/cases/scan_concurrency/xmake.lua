set_project("bluespec-scan-concurrency")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

local function endpoint(name, root, top)
    target(name)
        add_rules("bluespec.verilog")
        set_bsc_root(path.join("src", root .. ".bsv"))
        set_bsc_top(top)
end

for index = 1, 4 do
    endpoint("unique" .. index, "Unique" .. index, "mkUnique" .. index)
end

for index = 1, 4 do
    endpoint("shared_a" .. index, "SharedA", "mkSharedA" .. index)
    endpoint("shared_b" .. index, "SharedB", "mkSharedB" .. index)
end

target("provider")
    add_rules("bluespec.library")
    set_bsc_root(path.join("src", "Provider.bsv"))

for index = 1, 2 do
    target("consumer" .. index)
        add_rules("bluespec.verilog")
        set_bsc_root(path.join("src", "Consumer.bsv"))
        set_bsc_top("mkConsumer" .. index)
        add_deps("provider")
end
