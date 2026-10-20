-- Real Bluetcl process checks; no package/backend compilation or parallel jobs.
function main()
    local modules = path.join(os.scriptdir(), "../modules")
    local tools = import("bluespec.tools", {rootdir = modules})
    local parser = import("bluespec.parser", {rootdir = modules})
    local scan = import("bluespec.scan", {rootdir = modules})
    local cache = import("bluespec.cache", {rootdir = modules})
    local directory = os.tmpfile() .. "-scanner {inputs}"
    local scanner_identity = tools.scanner_identity
    local target = {
        fullname = function() return "conditional-scan" end,
        name = function() return "conditional-scan" end,
        plat = function() return os.host() end,
        arch = function() return os.arch() end,
        get = function(_, key) return key == "mode" and "release" or nil end,
        autogendir = function() return directory end,
        targetdir = function() return directory end,
        tool = function() return os.programfile(), "test" end,
    }
    os.mkdir(directory)
    local errors
    try {
        function()
            local top = path.join(directory, "Top.bsv")
            io.writefile(top, "package Top;\n`ifdef ENABLE_EXTRA\nimport Extra::*;\n`endif\nendpackage\n")
            io.writefile(path.join(directory, "Extra.bsv"), "package Extra; endpackage\n")
            local options = {"-check-assert", "+RTS", "-K128M", "-RTS", "-suppress-warnings", "G0020"}
            local raw = tools.run_depend(target, top, {directory}, {"ENABLE_EXTRA"}, options)
            local graph = parser.parse(raw, top)
            assert(graph.packages.Extra and graph.packages.Top.deps.Extra,
                "runtime options caused the conditional import to disappear")
            local _, args = tools.package_args(target, {
                output_dir = directory, effective_options = options,
            }, {source = top})
            assert(table.concat(args, " "):find("+RTS -K128M -RTS", 1, true),
                "BSC compilation lost its runtime options")

            local function must_fail(source, flags, expected)
                local failure
                try {
                    function() tools.run_depend(target, source, {directory}, {}, flags) end,
                    catch {function(err) failure = tostring(err) end},
                }
                assert(failure and failure:find(expected, 1, true),
                    "scanner accepted a Tcl failure or lost its diagnostic: " .. tostring(failure))
            end
            must_fail(top, {"-invalid-scanner-option"}, "invalid-scanner-option")
            must_fail(path.join(directory, "Missing.bsv"), {}, "Missing.bsv")

            local old_key = scan.identity(top, {directory}, {}, options, {})
            local old_fingerprint = cache.fingerprint(target, {top}, {})
            tools.scanner_identity = function() return scanner_identity() .. "|changed scanner contract" end
            assert(scan.identity(top, {directory}, {}, options, {}) ~= old_key,
                "raw scan identity ignored scanner changes")
            assert(cache.fingerprint(target, {top}, {}) ~= old_fingerprint,
                "parsed graph cache ignored scanner changes")
        end,
        catch {function(err) errors = err end},
        finally {function()
            tools.scanner_identity = scanner_identity
            os.tryrm(directory)
        end},
    }
    assert(not errors, errors)
    print("Bluespec scanner process checks passed")
end
