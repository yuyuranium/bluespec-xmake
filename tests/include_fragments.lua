-- Real Bluetcl/BSC integration for a package and include with the same basename.
function main()
    local root = path.absolute(path.join(os.scriptdir(), ".."))
    local work = os.tmpfile() .. "-include-fragments"
    os.mkdir(path.join(work, "src/fragments"))
    local sources = {
        ["Helper.bsv"] = [[package Helper;
function Bit#(8) helperValue = 42;
`include "fragments/Helper.bsv"
endpackage
]],
        ["fragments/Helper.bsv"] = "typedef Bit#(8) Byte;\n",
        ["Top.bsv"] = [[package Top;
import Helper::*;
interface TopIfc;
    method Byte value;
endinterface
(* synthesize *)
module mkTop(TopIfc);
    rule test;
        $display("VALUE=%0d", helperValue);
        $finish(0);
    endrule
    method Byte value = zeroExtend(helperValue);
endmodule
endpackage
]],
    }
    for name, contents in pairs(sources) do io.writefile(path.join(work, "src", name), contents) end
    io.writefile(path.join(work, "xmake.lua"), [[
includes(path.join(os.getenv("BLUESPEC_XMAKE_ROOT"), "rules/bluespec.lua"))
target("check")
    add_rules("bluespec.check")
    set_bsc_root("src/Top.bsv")
target("rtl")
    add_rules("bluespec.verilog")
    set_bsc_root("src/Top.bsv")
    set_bsc_top("mkTop")
]])
    local sequence = 0
    local function run(program, arguments)
        sequence = sequence + 1
        local stdout, stderr = path.join(work, sequence .. ".out"), path.join(work, sequence .. ".err")
        local code = os.execv(program, arguments, {
            curdir = work, envs = {BLUESPEC_XMAKE_ROOT = root},
            stdout = stdout, stderr = stderr, try = true,
        })
        local output = (io.readfile(stdout) or "") .. (io.readfile(stderr) or "")
        assert(code == 0, "include fixture failed; logs in " .. work .. "\n" .. output)
        return output
    end
    local function xmake(arguments)
        local command = {arguments[1], "-P", work}
        for index = 2, #arguments do table.insert(command, arguments[index]) end
        return run(os.programfile(), command)
    end
    -- Establish that the input is valid with BSC's own update driver.
    os.mkdir(path.join(work, "official-bdir"))
    run("bsc", {"-u", "-bdir", "official-bdir", "-p", "+:src", "src/Top.bsv"})
    xmake({"config", "-c", "-y", "--bluespec_backend_jobs=1", "--bluespec_bsc_jobs=1",
        "--bluespec_scan_jobs=1"})
    xmake({"build", "-j1", "check"})
    xmake({"build", "-j1", "rtl"})

    local tools = import("bluespec.tools", {rootdir = path.join(root, "modules")})
    local parser = import("bluespec.parser", {rootdir = path.join(root, "modules")})
    local top, helper, fragment = path.join(work, "src/Top.bsv"), path.join(work, "src/Helper.bsv"),
        path.join(work, "src/fragments/Helper.bsv")
    local target = {name = function() return "include-fragments" end,
        fullname = function() return "include-fragments" end}
    local raw = tools.run_depend(target, top, {path.join(work, "src")}, {}, {})
    local package = parser.parse(raw, top).packages.Helper
    assert(package.source == helper and package.sources[fragment],
        "real Bluetcl scan lost the declaring source or include input: " .. raw)
    local function rtl_width(bits)
        local files = os.files(path.join(work, "build/Verilog/rtl/mkTop.v"))
        assert(#files == 1, "missing generated RTL; logs in " .. work)
        local contents = assert(io.readfile(files[1]))
        assert(contents:match("output%s+%[%s*" .. (bits - 1) .. "%s*:%s*0%s*%]%s+value"),
            "fragment type change did not reach RTL output width; logs in " .. work)
    end
    local function cache_hit()
        local output = xmake({"build", "-j1", "-a"})
        for _, message in ipairs({"scanning Bluespec", "compiling Bluespec", "building Bluespec"}) do
            assert(not output:find(message, 1, true), "unchanged include fixture: " .. output)
        end
    end
    rtl_width(8)
    cache_hit()
    os.sleep(1100)
    io.writefile(fragment, "typedef Bit#(16) Byte;\n")
    for _, name in ipairs({"check", "rtl"}) do
        local output = xmake({"build", "-j1", name})
        assert(output:find("compiling Bluespec package Helper", 1, true),
            name .. " did not invalidate the included fragment: " .. output)
    end
    rtl_width(16)
    cache_hit()
    os.rm(work)
    print("Bluespec same-basename include integration checks passed")
end
