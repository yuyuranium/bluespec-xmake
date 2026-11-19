-- Exercise the database through consumer builds, including a broken source
-- which must remain editable before the scanner or compiler can accept it.
function main()
    local json = import("core.base.json")
    local root = path.absolute(path.join(os.scriptdir(), ".."))
    local work = os.tmpfile() .. "-compile commands"
    os.mkdir(path.join(work, "lib/private"))
    os.mkdir(path.join(work, "app"))
    io.writefile(path.join(work, "lib/private/Helper.bsv"), "package Helper; endpackage\n")
    io.writefile(path.join(work, "lib/Base.bsv"), "package Base; import Helper::*; endpackage\n")
    io.writefile(path.join(work, "app/Top.bsv"), "package Top; import Base::*; endpackage\n")
    io.writefile(path.join(work, "app/Broken.bsv"), "not valid BSV\n")
    io.writefile(path.join(work, "lib/xmake.lua"), [[
target("base")
    add_rules("bluespec.library")
    set_bsc_root("Base.bsv")
    add_bsc_package_dirs("private")
    add_bsc_defines("WIDTH=8", {public = true})
    add_bsc_defines("BASE_ONLY")
    add_bsc_options("-suppress-warnings", "S0001", {public = true})
    add_bsc_options("-suppress-warnings", "S0080", {interface = true})
]])
    local recipe = [[
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules/bluespec.lua"))
includes("lib/xmake.lua")
target("consumer")
    add_rules("bluespec.check")
    set_bsc_root("app/Top.bsv")
    add_bsc_defines("TOP_ONLY")
    add_bsc_options("+RTS", "-K128M", "-RTS")
    add_deps("base")
target("alternative")
    set_default(false)
    add_rules("bluespec.check")
    set_bsc_root("lib/Base.bsv")
    add_bsc_defines("ALTERNATIVE")
]]
    io.writefile(path.join(work, "xmake.lua"), recipe)
    local sequence = 0
    local function run(arguments, cwd)
        sequence = sequence + 1
        local stdout, stderr = path.join(work, sequence .. ".out"), path.join(work, sequence .. ".err")
        local command = {arguments[1], "-P", work}
        for index = 2, #arguments do table.insert(command, arguments[index]) end
        local code = os.execv(os.programfile(), command, {
            curdir = cwd or work, envs = {BLUESPEC_XMAKE_ROOT = root},
            stdout = stdout, stderr = stderr, try = true,
        })
        local output = (io.readfile(stdout) or "") .. (io.readfile(stderr) or "")
        assert(code == 0, "compilation database fixture failed; logs in " .. work .. "\n" .. output)
        return output
    end
    local database = path.join(work, "build/bsc_compile_commands.json")
    local function entries()
        local result = {}
        local previous = ""
        for _, entry in ipairs(json.loadfile(database)) do
            assert(path.is_absolute(entry.file) and path.is_absolute(entry.directory))
            assert(entry.file > previous, "database must contain sorted, unique files")
            previous = entry.file
            result[path.relative(entry.file, work)] = entry
            assert(not entry.command and type(entry.arguments) == "table")
            for _, flag in ipairs({"-bdir", "-info-dir", "-sim", "-verilog", "-g", "-o", "-elab"}) do
                assert(not table.contains(entry.arguments, flag), "unexpected output/backend flag " .. flag)
            end
        end
        return result
    end
    run({"config", "-c", "-y"})
    assert(not os.isfile(database), "configure should not export the database")
    local exported = run({"build", "bsc_compile_commands"})
    assert(not exported:find("scanning Bluespec", 1, true), "export invoked dependency scanning")
    assert(#os.files(path.join(work, "build/**.bo")) == 0, "export compiled a package")
    assert(not os.isfile(path.join(work, "bsc_compile_commands.json")))
    local data = entries()
    local base, top = assert(data["lib/Base.bsv"]), assert(data["app/Top.bsv"])
    assert(data["lib/private/Helper.bsv"] and data["app/Broken.bsv"], "search-directory sources missing")
    assert(table.contains(base.arguments, "BASE_ONLY") and not table.contains(top.arguments, "BASE_ONLY"))
    assert(table.contains(base.arguments, "WIDTH=8") and table.contains(top.arguments, "WIDTH=8"))
    assert(table.contains(top.arguments, "TOP_ONLY") and not table.contains(base.arguments, "TOP_ONLY"))
    assert(not table.contains(base.arguments, "ALTERNATIVE"), "endpoint replaced the library context")
    local flags = table.concat(top.arguments, " ")
    assert(flags:find("-suppress-warnings S0001 -suppress-warnings S0080", 1, true))
    assert(flags:find("+RTS -K128M -RTS", 1, true), "option groups were split")
    local search
    for index, argument in ipairs(top.arguments) do
        if argument == "-p" then search = top.arguments[index + 1] end
    end
    for _, directory in ipairs({"%/Libraries", path.join(work, "lib"), path.join(work, "lib/private"),
        path.join(work, "app")}) do
        assert(table.contains(search:split(path.envsep(), {plain = true}), directory),
            "missing source search directory " .. directory)
    end
    -- Replay the exported context with the flags supplied by a diagnostics
    -- client. Imports must work with no prebuilt package database.
    local diagnostic = path.join(work, "diagnostic")
    os.mkdir(diagnostic)
    local argv = table.slice(top.arguments, 2)
    table.join2(argv, {"-u", "-bdir", diagnostic, "-info-dir", diagnostic, top.file})
    os.vrunv(top.arguments[1], argv, {curdir = top.directory})

    local contents, timestamp = io.readfile(database), os.mtime(database)
    os.sleep(1100)
    run({"build", "bsc_compile_commands"})
    assert(io.readfile(database) == contents and os.mtime(database) == timestamp,
        "unchanged export rewrote the database")
    os.rm(database)
    run({"build", "-j2", "consumer"})
    assert(io.readfile(database) == contents, "targeted build did not export the whole project")
    run({"clean", "-a"})
    assert(not os.isfile(database), "clean retained the database")
    run({"build", "-j2"})
    assert(io.readfile(database) == contents, "default build did not recreate the database")
    timestamp = os.mtime(database)
    os.sleep(1100)
    run({"build", "-j2"})
    assert(os.mtime(database) == timestamp, "unchanged build rewrote the database")

    -- Export without scanning even when a root is invalid or not generated yet.
    io.writefile(path.join(work, "xmake.lua"), recipe .. [[
target("broken")
    set_default(false)
    add_rules("bluespec.check")
    set_bsc_root("app/Broken.bsv")
    add_bsc_defines('LABEL="hello world"')
target("generated")
    set_default(false)
    add_rules("bluespec.library")
    set_bsc_root("build/generated/Generated.bsv")
]])
    run({"build", "bsc_compile_commands"})
    data = entries()
    assert(table.contains(data["app/Broken.bsv"].arguments, 'LABEL="hello world"'),
        "explicit root lost its context to a neighboring target")
    assert(data["build/generated/Generated.bsv"], "missing generated root entry")
    io.writefile(path.join(work, "xmake.lua"), assert(io.readfile(path.join(work, "xmake.lua"))) .. [[
target("generator")
    set_kind("phony")
    on_prepare(function()
        os.mkdir("build/generated")
        io.writefile("build/generated/Generated.bsv", "package Generated; endpackage\n")
        io.writefile("build/generated/Late.bsv", "package Late; endpackage\n")
    end)
target("generated")
    add_deps("generator")
]])
    run({"build", "-j2", "generated"})
    assert(entries()["build/generated/Late.bsv"], "export ran before prepare-time generation")
    os.rm(path.join(work, "app/Broken.bsv"))
    io.writefile(path.join(work, "xmake.lua"), recipe)
    run({"build", "bsc_compile_commands"})
    data = entries()
    assert(not data["app/Broken.bsv"] and not data["build/generated/Generated.bsv"], "stale entries survived")

    local outside = path.join(work, "outside")
    os.mkdir(outside)
    run({"config", "-c", "-y", "-o", "relocated build"}, outside)
    run({"build", "bsc_compile_commands"}, outside)
    database = path.join(outside, "relocated build/bsc_compile_commands.json")
    data = entries()
    assert(data["app/Top.bsv"].directory == work, "diagnostics cwd differs from the compiler cwd")
    io.writefile(path.join(work, "xmake.lua"),
        'includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules/bluespec.lua"))\n')
    run({"build", "bsc_compile_commands"}, outside)
    assert(table.empty(entries()), "removing all Bluespec targets left stale entries")
    os.rm(work)
    print("Bluespec compilation database integration checks passed")
end
