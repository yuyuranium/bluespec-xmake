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
    return visibility_values(target, "bluespec.options", "bsc_options")
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
