-- Publish changed JSON records together in one helper process. A record becomes
-- visible to readers only after its complete UTF-8 file has been written.
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrStringUtils = import "LrStringUtils"
local LrTasks = import "LrTasks"
local workFolder = require "WorkFolder"
local Json = require "Json"
local run = require "WindowsProcess"
local child = LrPathUtils.child
local Data = {}

local function mkdir(path)
    local ok, why = LrFileUtils.createAllDirectories(path)
    if not ok then error(tostring(why), 0) end
end

function Data.write(folder, records)
    mkdir(folder)
    local staging = workFolder(folder, "write")
    local ok, reason = LrTasks.pcall(function()
        local bytes = Json.encode(records)
        local stream = not staging:find("[\128-\255]") and io.open(child(staging, "records"), "wb")
        if stream then
            local wrote, why = stream:write(bytes)
            assert(stream:close())
            assert(wrote, why)
        else
            -- SDK filesystem functions handle Unicode on Windows; Lua 5.1 io
            -- depends on the system code page. The helper reads the same bytes.
            local b64 = LrStringUtils.encodeBase64(bytes):gsub("%s",""):gsub("%+","-"):gsub("/","_")
            for pos=1,#b64,80 do
                mkdir(child(staging,string.format("%08d_",pos)..b64:sub(pos,pos+79)))
            end
        end
        local python = child(child(child(LrPathUtils.parent(_PLUGIN.path), ".venv"), "Scripts"), "python.exe")
        local helper = child(child(LrPathUtils.parent(_PLUGIN.path), "bridge"), "project_data.py")
        local code = run({python, helper, folder, staging}, {
            "$exe=$v[0]", "$args2=$v[1..3]", "& $exe -B @args2", "exit $LASTEXITCODE",
        })
        if code ~= 0 then error("无法保存项目设置：" .. folder, 0) end
    end)
    LrFileUtils.delete(staging)
    if not ok then error(reason,0) end
end

function Data.read(folder,key)
    local file = child(folder,key .. ".json")
    if LrFileUtils.exists(file) ~= "file" then return nil end
    return Json.decode(LrFileUtils.readFile(file))
end

return Data
