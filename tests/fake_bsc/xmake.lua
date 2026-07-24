set_project("bluespec-xmake-fake-bsc")
set_languages("c11")

target("bsc")
    set_kind("binary")
    add_files("fake_bsc.c")
    set_targetdir(path.join(get_config("builddir"), "bin"))

target("bluetcl")
    set_kind("binary")
    add_files("fake_bluetcl.c")
    set_targetdir(path.join(get_config("builddir"), "bin"))

local bluesimdir = path.join(get_config("builddir"), "lib", "Bluesim")

target("bskernel")
    set_kind("static")
    add_files("fake_bskernel.c")
    set_targetdir(bluesimdir)

target("bsprim")
    set_kind("static")
    add_files("fake_bsprim.c")
    set_targetdir(bluesimdir)

target("systemc")
    set_kind("static")
    add_files("fake_systemc.c")
    set_targetdir(bluesimdir)

target("runtime_headers")
    set_kind("phony")
    on_build(function()
        os.mkdir(bluesimdir)
        os.cp(path.join(os.scriptdir(), "bluesim_kernel_api.h"), bluesimdir)
    end)
