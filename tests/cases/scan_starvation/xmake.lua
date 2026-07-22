set_project("bluespec-scan-starvation")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

-- Keep targets with the same root adjacent.  A coroutine-based single-flight
-- implementation turns each group into one owner plus three blocked waiters;
-- at -j8 that starves owners for later unique roots.
for root_index = 1, 16 do
    local root_name = string.format("Root%02d", root_index)
    for endpoint_index = 1, 4 do
        target(string.format("root%02d_endpoint%d", root_index, endpoint_index))
            add_rules("bluespec.verilog")
            set_bsc_root(path.join("src", root_name .. ".bsv"))
            set_bsc_top(string.format("mk%sEndpoint%d", root_name, endpoint_index))
    end
end
