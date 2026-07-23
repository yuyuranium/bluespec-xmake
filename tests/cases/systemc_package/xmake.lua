set_project("systemc-native-package")

option("local_systemc_variant")
    set_default("a")

local variant = get_config("local_systemc_variant") or "a"
local prefix = path.absolute(path.join(os.scriptdir(), "prefix-" .. variant))

package("local-systemc")
    set_kind("library")
    on_fetch(function(package, opt)
        return {
            version = "1.0.0",
            sysincludedirs = path.join(prefix, "system"),
            linkdirs = path.join(prefix, "lib"),
            links = "local_systemc_" .. variant,
            syslinks = "local_runtime_" .. variant,
            ldflags = "-Wl,--local-systemc-" .. variant,
        }
    end)
package_end()

add_requires("local-systemc")

includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("model")
    add_rules("bluespec.systemc")
    add_packages("local-systemc", {public = true})
    add_includedirs(path.join(prefix, "ordinary"))
    set_bsc_root("Top.bsv")
    set_bsc_top("mkTop")
