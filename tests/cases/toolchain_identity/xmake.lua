set_project("bsc-toolchain-identity")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("toolchain_native")
    set_kind("static")
    set_default(false)
    add_files("src/native/toolchain.cpp")

target("toolchain_sim")
    set_default(false)
    add_rules("bluespec.bluesim")
    set_bsc_root("src/ToolchainTop.bsv")
    set_bsc_top("mkToolchainTop")
    add_bsc_options("-v")
    add_deps("toolchain_native")
    on_config(function(target)
        if os.getenv("BLUESPEC_XMAKE_REPORT_TOOLS") == "1" then
            for _, name in ipairs({"cc", "cxx", "sh"}) do
                cprint("BSC_TARGET_TOOL_%s=%s", name, tostring(target:tool(name)))
            end
        end
    end)
