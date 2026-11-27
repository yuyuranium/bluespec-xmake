local config = import("core.project.config")
local project = import("core.project.project")
local json = import("core.base.json")
local graph = import("bluespec.graph")
local util = import("bluespec.util")
local exported = false

function filename()
    return path.absolute(path.join(config.builddir(), "bsc_compile_commands.json"))
end

function generate()
    if exported then return end
    local targets = {}
    for _, target in pairs(project.targets()) do
        if target:data("bluespec.rule") then table.insert(targets, target) end
    end
    table.sort(targets, function(left, right)
        local left_library = left:data("bluespec.rule") == "bluespec.library"
        local right_library = right:data("bluespec.rule") == "bluespec.library"
        if left_library ~= right_library then return left_library end
        return left:fullname() < right:fullname()
    end)
    local contexts = {}
    local program = #targets > 0 and import("bluespec.tools").tools().bsc
    for _, target in ipairs(targets) do
        local context = graph.declared_config(target)
        local arguments = {program, "-p",
            table.concat(table.join({"%/Libraries"}, context.source_dirs), path.envsep())}
        for _, define in ipairs(context.effective_defines) do
            table.join2(arguments, {"-D", define})
        end
        table.join2(arguments, context.effective_options)
        table.insert(contexts, {
            target = target:fullname(), root = util.canonical_root(target),
            dirs = context.own_dirs, arguments = json.encode(arguments),
        })
    end
    local entries, owners = {}, {}
    local directory = json.encode(os.curdir())
    local function add(source, context)
        source = path.normalize(path.absolute(source))
        local entry = string.format('  {"directory": %s, "file": %s, "arguments": %s}',
            directory, json.encode(source), context.arguments)
        if entries[source] and entries[source] ~= entry then
            wprint("multiple Bluespec compilation contexts for %s; keeping target(%s) over target(%s)",
                source, owners[source], context.target)
        elseif not entries[source] then
            entries[source], owners[source] = entry, context.target
        end
    end
    -- Explicit roots own their context before directory discovery. Within
    -- either pass, libraries precede endpoints, then full target name decides.
    for _, context in ipairs(contexts) do add(context.root, context) end
    for _, context in ipairs(contexts) do
        for _, directory in ipairs(context.dirs) do
            for _, source in ipairs(os.files(path.join(directory, "*.bsv"))) do
                add(source, context)
            end
        end
    end
    local files = {}
    for file in pairs(entries) do table.insert(files, file) end
    table.sort(files)
    local lines = {}
    for _, file in ipairs(files) do table.insert(lines, entries[file]) end
    -- Fixed object key order and sorted files keep bytes stable across Lua
    -- processes; use the JSON encoder for every string and argv array.
    local contents = "[\n" .. table.concat(lines, ",\n") .. "\n]\n"
    local output = filename()
    if not os.isfile(output) or io.readfile(output) ~= contents then
        os.mkdir(path.directory(output))
        local temporary = path.join(path.directory(output), path.filename(os.tmpfile()) .. ".json")
        io.writefile(temporary, contents)
        os.mv(temporary, output)
    end
    exported = true
end
