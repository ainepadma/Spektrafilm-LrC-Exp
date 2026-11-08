local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"
local Data = require "ProjectData"

local Settings = {}
local root = LrPathUtils.parent(_PLUGIN.path)
local runtime = LrPathUtils.child(root, ".runtime")
local config = LrPathUtils.child(runtime, "export-settings.tsv")

local function valid(folder, format, edge, mode)
    return type(folder)=="string" and not folder:find("%c") and LrPathUtils.isAbsolute(folder)
        and (format == "jpg" or format == "tif" or format == "png" or format == "di")
        and type(edge)=="number" and edge>=0 and edge<=65535 and edge==math.floor(edge)
        and (mode == "full" or mode == "fast-color")
end

function Settings.load()
    local defaults = { folder = LrPathUtils.child(root, "exports"), format = "jpg", edge = 0, mode = "full" }
    local parsed, saved = LrTasks.pcall(Data.read, runtime, "export-settings")
    if parsed and type(saved)=="table" and valid(saved.folder,saved.format,saved.edge,saved.mode) then return saved end
    if LrFileUtils.exists(config) ~= "file" then return defaults end
    local ok, data = LrTasks.pcall(LrFileUtils.readFile, config)
    if ok and type(data) == "string" then
        local format, edge, mode, folder = data:match("^v2\t(%a+)\t(%d+)\t([%a-]+)\t([^\t\r\n]+)\r?\n?$")
        if not format then
            format, edge, folder = data:match("^v1\t(%a+)\t(%d+)\t([^\t\r\n]+)\r?\n?$")
            mode = "full"
        end
        edge = tonumber(edge)
        local parsed, usable = LrTasks.pcall(valid, folder, format, edge, mode)
        if parsed and usable then return { folder = folder, format = format, edge = edge, mode = mode } end
    end
    return defaults
end

function Settings.save(folder, format, edge, mode, printing)
    mode = mode or "full"
    if not valid(folder, format, edge, mode) then error("导出设置无效。", 0) end
    Data.write(runtime, {["export-settings"]={folder=folder,format=format,edge=edge,mode=mode,printing=printing or {}}})
end

function Settings.presets(film)
    local records=Data.read(runtime,film and "film-presets" or "print-recipes") or {}
    if type(records)~="table" then error("配方文件无效。",0) end
    return records
end

function Settings.savePreset(name, values, film)
    assert(type(name)=="string" and name:match("%S") and #name<=100, "请输入有效的配方名称。")
    local records=Settings.presets(film)
    records[name]=values
    Data.write(runtime,{[film and "film-presets" or "print-recipes"]=records})
end

return Settings
