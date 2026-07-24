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
            ldflags = variant == "a" and "-Wl,-z,relro" or "-Wl,-z,now",
        }
    end)
package_end()

add_requires("local-systemc")

includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules", "bluespec.lua"))

target("local_systemc_package")
    set_kind("static")
    set_basename("local_systemc_" .. variant)
    set_targetdir(path.join(prefix, "lib"))
    add_files("local_systemc.cpp")

target("local_runtime_package")
    set_kind("static")
    set_basename("local_runtime_" .. variant)
    set_targetdir(path.join(prefix, "lib"))
    add_files("local_runtime.cpp")

target("model")
    add_rules("bluespec.systemc")
    add_packages("local-systemc", {public = true})
    add_includedirs(path.join(prefix, "ordinary"))
    add_deps("local_systemc_package", "local_runtime_package")
    set_bsc_root("Top.bsv")
    set_bsc_top("mkTop")

target("consumer")
    set_kind("binary")
    set_default(false)
    set_languages("c++17")
    add_files("consumer.cpp")
    add_deps("model")
