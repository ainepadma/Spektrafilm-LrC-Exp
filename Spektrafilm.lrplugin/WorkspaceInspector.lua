local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"
local WorkFolder = require "WorkFolder"
local Worker = require "WorkerSession"
local Json = require "Json"
local child = LrPathUtils.child
local Inspector = {}
Inspector.__index = Inspector

function Inspector.new(session, render)
    return setmetatable({session=session,render=render},Inspector)
end

-- Reuse the TIFF when adjusting the comparison divider or moving a native crop.
-- Keep the finished comparison separate from the single-photo rendering inputs.
function Inspector:view(photo, recipe, inspection, width, height, version, current)
    local zoom = inspection.zoom == "roi"
    local box = width.."x"..height
    local sourceKey = Json.encode({photo=tostring(photo.localIdentifier),edited=photo:getRawMetadata("lastEditTime"),
        version=version,size=zoom and "native" or box})
    if self.sourceKey ~= sourceKey then
        if self.folder then LrFileUtils.delete(self.folder) end
        self.folder = WorkFolder(self.session,"inspect-input")
        self.key, self.data, self.sourceKey = nil,nil,nil
        self.original = self.render.input(photo,self.folder,not zoom and width or nil,not zoom and height or nil,"srgb")
        self.sourceKey = sourceKey
    end
    if not current() then return end
    local key = Json.encode({recipe=recipe,size=box,x=zoom and inspection.x,y=zoom and inspection.y})
    if self.key ~= key then
        if self.data then LrFileUtils.delete(self.data.folder) end
        self.key=nil
        local data = {folder=WorkFolder(self.folder,"result"),original=self.original}
        self.data=data
        local fraction
        if zoom then
            data.original,data.info=child(data.folder,"roi.tif"),child(data.folder,"region.json")
            Worker.request(self.session,{"crop-input","--input",self.original,"--output",data.original,"--info",data.info,
                "--box",box,"--x",tostring(inspection.x/100),"--y",tostring(inspection.y/100)},150)
            fraction=Json.decode(LrFileUtils.readFile(data.info)).fraction
        end
        if not current() then return end
        data.after=child(data.folder,"after.png")
        self.render.film(self.session,data.original,data.after,recipe.film,recipe.paper,recipe.mode,recipe.options,
            {displayProof=true,inputSpace="srgb",outputSpace="srgb",frameFraction=fraction,paperBorder="none"})
        self.key=key
    end
    if not current() then return end
    local result=WorkFolder(self.session,"inspection")
    local output,hist=child(result,"view.png"),child(result,"histogram.png")
    local args={"inspect","--before",self.data.original,"--after",self.data.after,"--mode",inspection.mode,
        "--position",tostring(inspection.divider),"--box",box,"--output",output,"--histogram",hist}
    if self.data.info then args[#args+1]="--info";args[#args+1]=self.data.info end
    local ok,why=LrTasks.pcall(Worker.request,self.session,args,150)
    if not ok or not current() then
        LrFileUtils.delete(result)
        if not ok then error(why,0) end
        return
    end
    if self.outputFolder then LrFileUtils.delete(self.outputFolder) end
    self.outputFolder=result
    return output,hist
end

return Inspector
