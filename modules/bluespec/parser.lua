local function is_escaped(text, index)
    local count = 0
    index = index - 1
    while index > 0 and text:sub(index, index) == "\\" do
        count = count + 1
        index = index - 1
    end
    return count % 2 == 1
end

local function join_continuations(text)
    local result = {}
    local pending = ""
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local endpos = #line
        while endpos > 0 and line:sub(endpos, endpos) == "\r" do
            endpos = endpos - 1
        end
        line = line:sub(1, endpos)
        local trimmed = line:gsub("%s+$", "")
        if #trimmed > 0 and trimmed:sub(-1) == "\\" and not is_escaped(trimmed, #trimmed) then
            pending = pending .. trimmed:sub(1, -2) .. " "
        else
            table.insert(result, pending .. line)
            pending = ""
        end
    end
    if pending ~= "" then
        table.insert(result, pending)
    end
    return result
end

local function tokens(text)
    local result = {}
    local current = {}
    local quote
    local escaped = false
    local function flush()
        if #current > 0 then
            table.insert(result, table.concat(current))
            current = {}
        end
    end
    for i = 1, #text do
        local char = text:sub(i, i)
        if escaped then
            table.insert(current, char)
            escaped = false
        elseif char == "\\" then
            escaped = true
        elseif quote then
            if char == quote then
                quote = nil
            else
                table.insert(current, char)
            end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char:match("%s") then
            flush()
        else
            table.insert(current, char)
        end
    end
    if escaped then
        table.insert(current, "\\")
    end
    flush()
    return result
end

local function split_rule(line)
    local quote
    for i = 1, #line do
        local char = line:sub(i, i)
        if char == "\\" and not is_escaped(line, i) then
            -- The next character is escaped; the tokenizer will decode it.
        elseif quote then
            if char == quote and not is_escaped(line, i) then
                quote = nil
            end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char == ":" and not (i == 2 and line:sub(3, 3) == "/") then
            return line:sub(1, i - 1), line:sub(i + 1)
        end
    end
    return nil
end

-- Bluetcl::depend make returns a Tcl list of records, not a shell command
-- stream.  Keep the reader in Lua so paths with spaces and nested braced
-- words remain lossless.
local function tcl_words(text)
    local result = {}
    local index = 1
    local length = #text
    local function skip_space()
        while index <= length and text:sub(index, index):match("%s") do
            index = index + 1
        end
    end
    while true do
        skip_space()
        if index > length then
            break
        end
        local first = text:sub(index, index)
        if first == "{" then
            local start = index + 1
            local depth = 1
            index = index + 1
            while index <= length and depth > 0 do
                local char = text:sub(index, index)
                if char == "{" then
                    depth = depth + 1
                elseif char == "}" then
                    depth = depth - 1
                end
                index = index + 1
            end
            if depth ~= 0 then
                raise("malformed Bluetcl Tcl list: unmatched brace")
            end
            table.insert(result, text:sub(start, index - 2))
        elseif first == '"' then
            index = index + 1
            local current = {}
            while index <= length do
                local char = text:sub(index, index)
                if char == '"' then
                    index = index + 1
                    break
                elseif char == "\\" and index < length then
                    index = index + 1
                    table.insert(current, text:sub(index, index))
                    index = index + 1
                else
                    table.insert(current, char)
                    index = index + 1
                end
            end
            table.insert(result, table.concat(current))
        else
            local current = {}
            while index <= length do
                local char = text:sub(index, index)
                if char:match("%s") then
                    break
                elseif char == "\\" and index < length then
                    index = index + 1
                    table.insert(current, text:sub(index, index))
                    index = index + 1
                else
                    table.insert(current, char)
                    index = index + 1
                end
            end
            table.insert(result, table.concat(current))
        end
    end
    return result
end

local function tcl_records(text)
    local result = {}
    for _, record_text in ipairs(tcl_words(text or "")) do
        local fields = tcl_words(record_text)
        if #fields >= 2 then
            local prerequisites = {}
            for index = 2, #fields do
                local nested = tcl_words(fields[index])
                if #nested > 0 then
                    for _, value in ipairs(nested) do
                        table.insert(prerequisites, value)
                    end
                else
                    table.insert(prerequisites, fields[index])
                end
            end
            table.insert(result, {target = fields[1], prerequisites = prerequisites})
        end
    end
    return result
end

local function make_records(text)
    local result = {}
    for _, line in ipairs(join_continuations(text or "")) do
        local lhs, rhs = split_rule(line)
        if lhs and rhs then
            local targets = tokens(lhs)
            if #targets == 0 then
                targets = {lhs}
            end
            table.insert(result, {targets = targets, prerequisites = tokens(rhs)})
        end
    end
    return result
end

local function package_name(pathname)
    local name = path.basename(pathname)
    local extension = path.extension(name)
    if extension ~= "" then
        name = name:sub(1, #name - #extension)
    end
    return name
end

local function declared_package(source)
    local contents = io.readfile(source)
    if not contents then
        return nil
    end
    -- A .bsv prerequisite may be a textual include rather than a package.
    -- Ignore commented-out declarations and require a declaration statement,
    -- including when preprocessor directives precede the package.
    contents = contents:gsub("/%*.-%*/", " "):gsub("//[^\r\n]*", " ")
    return ("\n" .. contents):match("[\r\n]%s*package%s+([%a_][%w_]*)%s*;")
end

local function source_path(token, root)
    if not token:match("%.[bB][sS][vV]$") then
        return nil
    end
    if token:sub(1, 1) == "/" then
        return path.normalize(token)
    end
    return path.absolute(token, os.projectdir())
end

local function input_path(token)
    token = tostring(token)
    -- Builtin variables are resolved by BSC and are represented separately
    -- as builtin package providers; they are not project files to stat.
    if token:find("%$%(", 1, false) then
        return nil
    end
    if token == "" or token:sub(1, 1) == "-" then
        return nil
    end
    return path.normalize(path.absolute(token, os.projectdir()))
end

local function output_path(token)
    if token:match("%.[bB][oO]$") or token:match("%.[bB][aA]$") then
        return path.normalize(path.absolute(token, os.projectdir()))
    end
    return nil
end

local function ensure_package(packages, name)
    if not packages[name] then
        packages[name] = {
            name = name,
            deps = {},
            dep_paths = {},
            sources = {},
            inputs = {},
            outputs = {},
        }
    end
    return packages[name]
end

function parse(text, root)
    local packages = {}
    local records = 0
    local raw_records = tcl_records(text)
    if #raw_records == 0 then
        raw_records = make_records(text)
    end
    for _, record in ipairs(raw_records) do
        local targets = record.targets or {record.target}
        local prerequisites = record.prerequisites
        for _, target_token in ipairs(targets) do
            local output = output_path(target_token)
            if output then
                local name = package_name(output)
                local package = ensure_package(packages, name)
                if package.output and package.output ~= output then
                    raise("duplicate Bluespec package provider %s in Bluetcl output: %s and %s",
                        name, package.output, output)
                end
                package.output = output
                package.outputs[output] = true
                records = records + 1
                for _, prerequisite in ipairs(prerequisites) do
                    local source = source_path(prerequisite, root)
                    local dep_output = output_path(prerequisite)
                    if source then
                        package.sources[source] = true
                        -- Prefer the declaring source over same-basename
                        -- includes. Keep the first candidate as the fallback
                        -- for BSC's implicit packages (no package statement).
                        if package_name(source) == name and
                            (not package.source or declared_package(source) == name) then
                            package.source = source
                        end
                    elseif dep_output then
                        local depname = package_name(dep_output)
                        if depname ~= name then
                            package.deps[depname] = true
                            package.dep_paths[depname] = prerequisite
                        end
                    end
                    if not source and not dep_output then
                        local input = input_path(prerequisite)
                        if input then
                            package.inputs[input] = true
                        end
                    end
                end
            end
        end
    end

    if records == 0 then
        raise("Bluetcl dependency scan returned no package records for %s", root)
    end

    local root = path.normalize(path.absolute(root, os.projectdir()))
    local root_name
    local root_package
    for name, package in pairs(packages) do
        if package.source == root then
            if root_package and root_name ~= name then
                raise("root source %s declares multiple package providers: %s and %s",
                    root, root_name, name)
            end
            root_name = name
            root_package = package
        end
    end
    if not root_package then
        root_name = package_name(root)
        root_package = ensure_package(packages, root_name)
    end
    root_package.source = root
    root_package.sources[root] = true
    root_package.inputs[root] = true

    -- Bluetcl can omit a .bo rule for a source in a partially compiled
    -- closure. Keep genuine source-only packages, but leave textual includes
    -- as tracked inputs of their importing package rather than compile jobs.
    for _, package in pairs(packages) do
        for source in pairs(package.sources) do
            if source ~= package.source then
                local source_name = package_name(source)
                -- BSV also permits implicit packages. A matching .bo import
                -- proves ownership even when its source has no declaration.
                local name = package.deps[source_name] and source_name or declared_package(source)
                if name and name ~= package.name then
                    local source_package = ensure_package(packages, name)
                    source_package.source = source_package.source or source
                    source_package.sources[source] = true
                    source_package.inputs[source] = true
                    package.deps[name] = true
                end
            end
        end
    end

    local order = {}
    local visiting = {}
    local visited = {}
    local function visit(name, chain)
        if visiting[name] then
            local cycle = {}
            for _, item in ipairs(chain) do
                table.insert(cycle, item)
            end
            table.insert(cycle, name)
            raise("circular Bluespec package dependency detected:\n  %s", table.concat(cycle, " -> "))
        end
        if visited[name] then
            return
        end
        local package = packages[name]
        if not package then
            return
        end
        visiting[name] = true
        local next_chain = {}
        for _, item in ipairs(chain) do
            table.insert(next_chain, item)
        end
        table.insert(next_chain, name)
        local deps = {}
        for dep in pairs(package.deps) do
            table.insert(deps, dep)
        end
        table.sort(deps)
        for _, dep in ipairs(deps) do
            visit(dep, next_chain)
        end
        visiting[name] = nil
        visited[name] = true
        table.insert(order, name)
    end
    visit(root_name, {})
    local reachable = {}
    for _, name in ipairs(order) do
        reachable[name] = packages[name]
    end

    return {
        root = root,
        root_name = root_name,
        packages = reachable,
        order = order,
        records = records,
    }
end
