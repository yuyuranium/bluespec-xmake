set_project("duplicate-provider")
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("left")
    add_rules("bluespec.library")
    set_bsc_root("src/left/Dup.bsv")
    add_bsc_package_dirs("src/left", {public = true})

target("right")
    add_rules("bluespec.library")
    set_bsc_root("src/right/Dup.bsv")
    add_bsc_package_dirs("src/right", {public = true})

target("consumer")
    add_rules("bluespec.check")
    set_bsc_root("src/consumer/Consumer.bsv")
    add_deps("left", "right")
