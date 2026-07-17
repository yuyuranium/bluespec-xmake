set_project("path-relative-wrapper")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))
includes("../nested")
