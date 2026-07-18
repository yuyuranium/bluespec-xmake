set_project("cxx-driver")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("sim")
    set_kind("binary")
    add_rules("bluespec.bluesim")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
    set_toolset("cxx", os.getenv("BSC_TEST_CXX"))
