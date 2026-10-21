-- Pure parser checks: no BSC compilation or parallel build jobs.
function main()
    local parser = import("bluespec.parser", {rootdir = path.join(os.scriptdir(), "../modules")})
    local directory = os.tmpfile() .. "-parser"
    os.mkdir(directory)
    local errors
    try {
        function()
            local function source(name, contents)
                local file = path.join(directory, name .. ".bsv")
                os.mkdir(path.directory(file))
                io.writefile(file, contents)
                return file
            end
            local top = source("Top", "package Top; import Helper::*; endpackage")
            local helper = source("Helper", "package Helper; import Leaf::*; endpackage")
            local leaf = source("Leaf", "/* declaration follows */ package Leaf; endpackage")
            local implicit = source("Implicit", "typedef Bit#(8) ImplicitByte;\n")
            local fragment = source("Fragment", "// package Fragment; is only a comment\n"
                .. "/*\npackage Ghost;\n*/\nString description = \"package Decoy;\";\n"
                .. "typedef Bit#(8) Byte;\n")
            local homonym = source("fragments/Helper", "typedef Bit#(8) Byte;\n")
            local prerequisites = fragment .. " " .. helper .. " " .. leaf .. " " .. implicit .. " Implicit.bo"
            -- Cover native Bluetcl Tcl records and the supported make fallback.
            for _, records in ipairs({
                "{Top.bo {" .. top .. " Helper.bo}} {Helper.bo {" .. prerequisites .. "}}",
                "Top.bo: " .. top .. " Helper.bo\nHelper.bo: " .. prerequisites,
            }) do
                local graph = parser.parse(records, top)
                assert(not graph.packages.Fragment, "include fragment became a compilable package")
                assert(graph.packages.Helper.source == helper, "include fragment replaced the package source")
                assert(graph.packages.Helper.sources[fragment] or graph.packages.Helper.inputs[fragment],
                    "include fragment was dropped from tracked inputs")
                assert(graph.packages.Leaf and graph.packages.Leaf.source == leaf,
                    "partial closure lost its source-only package")
                assert(graph.packages.Helper.deps.Leaf, "source-only package dependency was lost")
                assert(graph.packages.Implicit and graph.packages.Implicit.source == implicit,
                    "partial closure lost an imported implicit package")
            end
            -- A same-basename include follows its declaring file in real
            -- Bluetcl output. Cover both orders and both record formats.
            for _, order in ipairs({{helper, homonym}, {homonym, helper}}) do
                for _, records in ipairs({
                    "{Top.bo {" .. top .. " Helper.bo}} {Helper.bo {" .. table.concat(order, " ") .. "}}",
                    "Top.bo: " .. top .. " Helper.bo\nHelper.bo: " .. table.concat(order, " "),
                }) do
                    local graph = parser.parse(records, top)
                    assert(graph.packages.Helper.source == helper,
                        "same-basename include fragment replaced the declaring source")
                    assert(graph.packages.Helper.sources[homonym],
                        "same-basename fragment was dropped from tracked inputs")
                end
            end
            local graph = parser.parse("Top.bo: " .. top .. " Implicit.bo\nImplicit.bo: " .. implicit, top)
            assert(graph.packages.Implicit.source == implicit, "implicit package provider was lost")
        end,
        catch {function(err) errors = err end},
        finally {function() os.tryrm(directory) end},
    }
    assert(not errors, errors)
    print("Bluespec dependency parser checks passed")
end
