set_project("bluespec-xmake-fake-bsc")
set_languages("c11")

target("bsc")
    set_kind("binary")
    add_files("fake_bsc.c")
    set_targetdir(path.join(get_config("builddir"), "bin"))
