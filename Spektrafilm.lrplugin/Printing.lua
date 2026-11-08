local LrDate = import "LrDate"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

local P = {}
local finish = {paperBorder="auto",paperLayout="even",paperMargin=0.035,paperColor="#F7F3E9",gate="none",holes=true,markings=true,frameNumber=1,fog=0,leak=0,
    dateFace="none",datePosition="br",dateSize=0.043,dateMargin=0.04,dateBrightness=0.85,
    pairDirection="horizontal",pairGap=1,firstEv=0,secondEv=0,firstScale=1,secondScale=1,
    firstX=0,firstY=0,secondX=0,secondY=0}
local output = {pair=false,quality=90,space="srgb",bits=16,collision="unique",nameTemplate="{name}-film"}

local function assign(p, defaults, data)
    for key,value in pairs(defaults) do
        p[key]=type(data and data[key])==type(value) and data[key] or value
        if type(value)=="boolean" and data and type(data[key])=="boolean" then p[key]=data[key] end
    end
end
local function extract(p, defaults)
    local values={}
    for key in pairs(defaults) do values[key]=p[key] end
    return values
end
function P.snapshot(p) return extract(p,finish) end
function P.restore(p,values) assign(p,finish,values) end
function P.setup(p,previous)
    local data=previous and previous.printing or {}
    assign(p,finish,data); assign(p,output,data)
end
function P.settings(p)
    local values=P.snapshot(p)
    for key in pairs(output) do values[key]=p[key] end
    return values
end

local function meta(photo,key,raw)
    if not photo then return nil end
    local ok,value=LrTasks.pcall(function()
        if raw then return photo:getRawMetadata(key) end
        return photo:getFormattedMetadata(key)
    end)
    if ok then return value end
end
local function captureDate(photo)
    local date=meta(photo,"dateTimeOriginal",true)
    if type(date)=="number" then
        local year,month,day=LrDate.timestampToComponents(date)
        return string.format("%04d-%02d-%02d",year,month,day)
    end
    local text=tostring(date or meta(photo,"dateTimeOriginal") or "")
    local year,month,day=text:match("(%d%d%d%d)%D+(%d%d?)%D+(%d%d?)")
    return year and string.format("%04d-%02d-%02d",year,tonumber(month),tonumber(day)) or ""
end
function P.options(p,photo,film,paper,preview,perPhoto)
    local f={}
    assign(f,finish,perPhoto or P.snapshot(p))
    local text=""
    if f.dateFace=="date" then text=captureDate(photo)
    elseif f.dateFace=="data" then
        local fields={}
        for _,key in ipairs({"shutterSpeed","aperture","focalLength"}) do
            local value=meta(photo,key)
            if value and value~="" then fields[#fields+1]=value end
        end
        text=table.concat(fields,"  ")
    end
    f.date=text
    f.markings=f.markings and film:gsub("_"," "):upper() or ""
    f.inputSpace="prophoto"
    f.outputSpace=(preview and p.format~="di") and "srgb" or p.space
    f.quality=p.quality
    f.bitDepth=p.bits
    f.longEdge=preview and 0 or p.edge
    f.collision=preview and "unique" or p.collision
    f.cineon=p.format=="di"
    f.protectedSource=meta(photo,"path",true)
    return f
end

function P.target(p,photo,film,paper)
    local base=LrPathUtils.removeExtension(photo:getFormattedMetadata("fileName"))
    local fields={name=base,film=film,paper=paper,date=captureDate(photo)}
    local name=(p.nameTemplate or output.nameTemplate):gsub("{([^}]+)}",function(key)
        assert(fields[key]~=nil,"未知命名字段："..key)
        return fields[key]
    end)
    name=name:gsub('[<>:"/\\|?*%c]',"_"):gsub("[%. ]+$","")
    if name=="" or name:find("[{}]") then error("命名模板无效。",0) end
    if p.pair then name=name.."-pair" end
    local ext=p.format=="di" and "tif" or p.format
    local path=LrPathUtils.child(p.folder,name.."."..ext)
    if p.collision=="unique" then path=LrFileUtils.chooseUniqueFileName(path) end
    return path, p.collision=="skip" and LrFileUtils.exists(path)=="file"
end

return P
