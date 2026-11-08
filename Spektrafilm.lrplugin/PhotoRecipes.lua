local LrDigest = import "LrDigest"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"
local Data = require "ProjectData"
local Json = require "Json"
local Recipes = {}
Recipes.__index = Recipes

function Recipes.open(catalog, onError)
    local root = LrPathUtils.child(LrPathUtils.parent(_PLUGIN.path), ".runtime")
    local digest = LrDigest.SHA256.digest(catalog:getPath())
    local folder = LrPathUtils.child(LrPathUtils.child(root, "photo-recipes"), digest)
    return setmetatable({folder=folder, onError=onError, saved={}, dirty={}}, Recipes)
end

local function id(photo)
    return tostring(assert(photo.localIdentifier, "照片缺少目录标识"))
end

function Recipes:get(photo, defaults)
    self.defaults = self.defaults or Json.clone(defaults)
    local key = id(photo)
    if self.saved[key] == nil then
        local ok,value = LrTasks.pcall(Data.read,self.folder,key)
        local valid = value == nil or type(value)=="table" and type(value.film)=="string"
            and type(value.paper)=="string" and (value.options==nil or type(value.options)=="table")
            and (value.printing==nil or type(value.printing)=="table")
        self.saved[key] = ok and valid and value or false
        if self.onError and (not ok or not valid) then
            self.onError("无法读取照片 "..key.." 的配方，已使用当前默认值。")
        end
    end
    return Json.clone(self.saved[key] or defaults)
end

function Recipes:flush()
    while self.writing do LrTasks.sleep(0.05) end
    while next(self.dirty) do
        local pending = self.dirty
        self.dirty = {}
        self.writing = true
        local ok, why = LrTasks.pcall(Data.write,self.folder,pending)
        self.writing = false
        if not ok then
            for k,v in pairs(pending) do if self.dirty[k] == nil then self.dirty[k] = v end end
            error(why,0)
        end
    end
end

function Recipes:set(photo, value)
    local key = id(photo)
    self.saved[key] = Json.clone(value)
    self.dirty[key] = self.saved[key]
    if self.scheduled then return end
    self.scheduled = true
    LrTasks.startAsyncTask(function()
        LrTasks.sleep(0.45)
        self.scheduled = false
        local ok, why = LrTasks.pcall(function() self:flush() end)
        if not ok and self.onError then self.onError("逐张设置保存失败："..tostring(why)) end
    end)
end

local groups = {
    {label="胶片、相纸与扫描", top={"film","paper"}, opts={"scan"}},
    {label="胶片曝光与放大机", opts={"film_ev","print_ev","yellow","magenta","preflash"}},
    {label="画幅与胶片效果", opts={"format_mm","grain_on","grain","halation_on","antihalation",
        "halation","scatter","boost","couplers_on","couplers","glare_on","glare"}},
    {label="冲印后调色与场景定位", opts={"exposure","contrast","brightness","saturation","highlights",
        "shadows","black","white","curves","zones","highlight_pull","shadow_pull"}},
    {label="成片外观与模拟模式", top={"printing","mode"}},
}

function Recipes.merge(target, source, selected)
    local result = Json.clone(target)
    result.options = result.options or {}
    for i,g in ipairs(groups) do
        if selected[i] then
            for _,k in ipairs(g.top or {}) do result[k] = Json.clone(source[k]) end
            for _,k in ipairs(g.opts or {}) do result.options[k] = Json.clone((source.options or {})[k]) end
        end
    end
    return result
end

return Recipes
