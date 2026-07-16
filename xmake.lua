set_project("bluespec-xmake")
set_version("0.1.0")

add_moduledirs("modules")
add_moduledirs("tests")
includes("rules/bluespec.lua")

-- Keep the repository itself buildable as a rule library.  Consumers can
-- include this file (or copy the rules directory) and then define their own
-- Bluespec targets.
target("bluespec-xmake")
    set_kind("phony")

task("regression")
    set_category("action")
    on_run(function()
        import("regression").main()
    end)
    set_menu {
        usage = "xmake regression",
        description = "Run the bluespec-xmake regression suite"
    }
