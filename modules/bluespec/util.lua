local function append(dst, value)
    if value == nil then
        return
    end
    if type(value) == "table" then
        if table.is_dictionary(value) then
            if not table.empty(value) then
                table.insert(dst, value)
            end
        else
            for _, item in ipairs(value) do
                append(dst, item)
            end
        end
    else
        table.insert(dst, value)
    end
end

function list(value)
    local result = {}
    append(result, value)
    return result
end

function sorted(values)
    local result = list(values)
    table.sort(result, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return result
end

function unique_sorted(values)
    local result = {}
    local seen = {}
    for _, value in ipairs(list(values)) do
        value = tostring(value)
        if not seen[value] then
            seen[value] = true
            table.insert(result, value)
        end
    end
    table.sort(result)
    return result
end

function concat_path_list(paths)
    return table.concat(unique_sorted(paths), path.envsep())
end

function absolute(pathname)
    if not pathname then
        return nil
    end
    return path.absolute(pathname, os.projectdir())
end

function canonical_root(target)
    local values = {}
    append(values, target:values("bluespec.root"))
    append(values, target:values("bsc_root"))
    if #values > 1 then
        raise("target(%s) requires exactly one Bluespec root, got %d", target:name(), #values)
    end
    local value = values[1]
    if not value or value == "" then
        raise("target(%s) requires set_bsc_root(\"...\")", target:name())
    end
    return absolute(value)
end

function top(target, required)
    local values = {}
    append(values, target:values("bluespec.top"))
    append(values, target:values("bsc_top"))
    if #values > 1 then
        raise("target(%s) requires at most one Bluespec top module", target:name())
    end
    local value = values[1]
    if required and (not value or value == "") then
        raise("target(%s) requires set_bsc_top(\"...\")", target:name())
    end
    return value
end

local function custom_values(target, canonical, helper)
    local result = {}
    append(result, target:values(canonical))
    -- Keep the low-level set_values() representation useful even when the
    -- convenience API is not loaded.  The public contract uses one key per
    -- visibility, e.g. bluespec.defines.public.
    for _, visibility in ipairs({"private", "public", "interface"}) do
        for _, value in ipairs(list(target:values(canonical .. "." .. visibility))) do
            table.insert(result, {value = value, visibility = visibility})
        end
    end
    if helper then
        append(result, target:values(helper))
    end
    return result
end

function visibility_values(target, canonical, helper)
    local values = custom_values(target, canonical, helper)
    local result = {private = {}, public = {}, interface = {}}
    for _, value in ipairs(values) do
        if type(value) == "table" then
            local visibility = value.visibility or (value.public and "public") or
                (value.interface and "interface") or (value.private and "private") or "private"
            visibility = tostring(visibility):lower()
            if visibility ~= "private" and visibility ~= "public" and visibility ~= "interface" then
                raise("invalid Bluespec visibility %s (expected private, public, or interface)", visibility)
            end
            local entries = value.values or value.value or value.items
            if entries == nil then
                entries = value.path or value.define or value.option or value.link_option
            end
            for _, entry in ipairs(list(entries)) do
                table.insert(result[visibility], tostring(entry))
            end
        else
            table.insert(result.private, tostring(value))
        end
    end
    for _, visibility in ipairs({"private", "public", "interface"}) do
        result[visibility] = unique_sorted(result[visibility])
    end
    return result
end

local function raw_visibility_values(target, canonical, helper)
    local result = {private = {}, public = {}, interface = {}}
    local function append_entries(destination, values)
        if values == nil then
            return
        end
        if type(values) == "table" and not table.is_dictionary(values) then
            for _, value in ipairs(values) do
                table.insert(destination, value)
            end
        else
            table.insert(destination, values)
        end
    end
    append_entries(result.private, target:values(canonical))
    for _, visibility in ipairs({"private", "public", "interface"}) do
        append_entries(result[visibility], target:values(canonical .. "." .. visibility))
    end
    append_entries(result.private, target:values(helper))
    return result
end

local function option_group(value)
    local prefix = "__bluespec_option_group_v1__:"
    if type(value) == "string" and value:sub(1, #prefix) == prefix then
        local result = {}
        local offset = #prefix + 1
        while offset <= #value do
            local separator = value:find(":", offset, true)
            if not separator then
                raise("invalid encoded Bluespec option group")
            end
            local length = tonumber(value:sub(offset, separator - 1))
            if not length or length < 0 then
                raise("invalid encoded Bluespec option group length")
            end
            local first = separator + 1
            local last = first + length - 1
            if last > #value then
                raise("truncated encoded Bluespec option group")
            end
            table.insert(result, value:sub(first, last))
            offset = last + 1
        end
        return result
    end
    if type(value) == "table" then
        if table.is_dictionary(value) then
            local entries = value.values or value.items or value.options
            if entries == nil then
                entries = value.value or value.option
            end
            if entries ~= nil then
                return list(entries)
            end
        else
            return list(value)
        end
    end
    return {tostring(value)}
end

-- Return ordered option groups for each visibility class. Structured groups
-- come from add_bsc_options(); legacy scalar values remain one-token groups.
function option_groups(target)
    local raw = raw_visibility_values(target, "bluespec.options", "bsc_options")
    local result = {private = {}, public = {}, interface = {}}
    for _, visibility in ipairs({"private", "public", "interface"}) do
        for _, value in ipairs(raw[visibility]) do
            local group = option_group(value)
            local normalized = {}
            for _, option in ipairs(group) do
                table.insert(normalized, tostring(option))
            end
            if #normalized > 0 then
                table.insert(result[visibility], normalized)
            end
        end
    end
    return result
end

function flatten_option_groups(groups)
    local result = {}
    for _, group in ipairs(groups or {}) do
        for _, option in ipairs(group or {}) do
            table.insert(result, tostring(option))
        end
    end
    return result
end

-- Encode group boundaries and token values without ambiguous delimiters so
-- graph fingerprints track the exact structured option configuration.
function option_groups_identity(groups)
    local encoded = {}
    for _, group in ipairs(groups or {}) do
        local values = {}
        for _, option in ipairs(group or {}) do
            option = tostring(option)
            table.insert(values, tostring(#option) .. ":" .. option)
        end
        table.insert(encoded, "[" .. table.concat(values, ",") .. "]")
    end
    return table.concat(encoded, "|")
end

function package_dirs(target)
    local dirs = visibility_values(target, "bluespec.package_dirs", "bsc_package_dirs")
    local root = canonical_root(target)
    local rootdir = path.directory(root)
    local all = {rootdir}
    -- Normalize configured directories once.  Besides making the BSC search
    -- path deterministic this lets ownership diagnostics compare absolute
    -- scanner paths with dependency package directories.
    for _, visibility in ipairs({"private", "public", "interface"}) do
        local normalized = {}
        for _, directory in ipairs(dirs[visibility]) do
            table.insert(normalized, absolute(directory))
        end
        dirs[visibility] = unique_sorted(normalized)
        append(all, dirs[visibility])
    end
    dirs.all = unique_sorted(all)
    return dirs
end

function defines(target)
    return visibility_values(target, "bluespec.defines", "bsc_defines")
end

function options(target)
    local groups = option_groups(target)
    return {
        private = flatten_option_groups(groups.private),
        public = flatten_option_groups(groups.public),
        interface = flatten_option_groups(groups.interface),
    }
end

function link_options(target)
    return visibility_values(target, "bluespec.link_options", "bsc_link_options")
end

function state_dir(target)
    local dir = path.absolute(path.join(target:autogendir(), "bluespec"))
    os.mkdir(dir)
    return dir
end

function backend_dir(target, backend)
    local dir = path.join(state_dir(target), backend)
    os.mkdir(dir)
    return dir
end

function bdir(target)
    return backend_dir(target, "bdir")
end

function infodir(target)
    return backend_dir(target, "info")
end

function simdir(target)
    return backend_dir(target, "simdir")
end

function artifact_marker(artifact)
    return artifact .. ".bluespec-complete"
end

local function artifact_stamp(artifact)
    if not os.isfile(artifact) then
        return nil
    end
    return tostring(os.mtime(artifact) or 0) .. ":" .. tostring(os.filesize(artifact) or 0)
end

function artifact_complete(artifact)
    local stamp = artifact_stamp(artifact)
    if not stamp then
        return false
    end
    local marker = artifact_marker(artifact)
    if not os.isfile(marker) then
        return false
    end
    return (io.readfile(marker) or ""):gsub("[\r\n]+$", "") == stamp
end

function mark_artifact_complete(artifact)
    local stamp = artifact_stamp(artifact)
    if not stamp then
        raise("cannot mark missing Bluespec artifact complete: %s", artifact)
    end
    io.writefile(artifact_marker(artifact), stamp .. "\n")
end

function invalidate_artifact(artifact)
    os.rm(artifact_marker(artifact))
end

function verilog_filelist(target)
    local filelist = target:targetfile()
    if not filelist then
        raise("bluespec.verilog target(%s) has no public targetfile", target:name())
    end
    return path.absolute(filelist)
end

function verilog_dir(target)
    local filelist = verilog_filelist(target)
    local filename = path.filename(filelist)
    local extension = path.extension(filename)
    local dirname
    if extension ~= "" then
        dirname = filename:sub(1, #filename - #extension)
    else
        dirname = filename .. ".rtl"
    end
    return path.join(path.directory(filelist), dirname)
end

function bool(value)
    return value == true or value == "true" or value == "1" or value == 1
end
