set_project("bluespec-concurrency")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

for index = 1, 4 do
    target("rtl" .. index)
        add_rules("bluespec.verilog")
        set_bsc_root(path.join("src", "Top" .. index .. ".bsv"))
        set_bsc_top("mkTop" .. index)
end
