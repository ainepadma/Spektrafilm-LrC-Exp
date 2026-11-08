local LrFileUtils = import "LrFileUtils"
local LrDigest = import "LrDigest"
local LrTasks = import "LrTasks"
local Json = require "Json"
local Render = require "Render"

local Inputs = {}
Inputs.__index = Inputs

function Inputs.new(session)
    return setmetatable({session=session, entries={}, generation=0}, Inputs)
end

-- A window can export the same adjusted photo several times with different
-- stocks or output settings. Do not reuse a rendition of an offline original.
local function fingerprint(photo, edge)
    local edited = photo:getRawMetadata("lastEditTime")
    local path = photo:getRawMetadata("path")
    if not edited or not path or not photo.localIdentifier then return nil end
    local ok, attrs = LrTasks.pcall(LrFileUtils.fileAttributes,path)
    if not ok or not attrs or not attrs.fileModificationDate then return nil end
    -- Two edits may share a timestamp. Include the actual Develop settings,
    -- so a change to crop, colour or masks always forces a fresh Lightroom TIFF.
    local read, settings = LrTasks.pcall(function()
        local develop = photo:getDevelopSettings()
        if type(develop) == "table" then return LrDigest.SHA256.digest(Json.encode(develop)) end
    end)
    if not read or not settings then return nil end
    return table.concat({photo.localIdentifier,path,edited,settings,attrs.fileModificationDate,
                         attrs.fileSize or 0,edge or 0}, "\0")
end

function Inputs:trim()
    local bytes = 0
    for i=#self.entries,1,-1 do
        local item = self.entries[i]
        bytes = bytes + item.bytes
        if item.users == 0 and (not item.key or #self.entries-i >= 4 or bytes > 384*1024*1024) then
            LrFileUtils.delete(item.path)
            table.remove(self.entries,i)
            bytes = bytes-item.bytes
        end
    end
end

function Inputs:invalidate()
    self.generation = self.generation + 1
    for _,item in ipairs(self.entries) do item.key = nil end
    self:trim()
end

function Inputs:acquire(photo, edge)
    local key = fingerprint(photo,edge)
    if key then
        for i,item in ipairs(self.entries) do
            if key == item.key and LrFileUtils.exists(item.path) == "file" then
                table.remove(self.entries,i)
                self.entries[#self.entries+1]=item
                item.users=item.users+1
                return item,true
            end
        end
    end
    local generation = self.generation
    local path = Render.input(photo,self.session,edge,edge)
    local ok,attrs = LrTasks.pcall(LrFileUtils.fileAttributes,path)
    if not ok or not attrs or not attrs.fileSize or generation ~= self.generation
            or key ~= fingerprint(photo,edge) then key=nil end
    local item = {key=key,path=path,bytes=ok and attrs and attrs.fileSize or 0,users=1}
    self.entries[#self.entries+1]=item
    self:trim()
    return item,false
end

function Inputs:release(item)
    if not item then return end
    item.users=item.users-1
    self:trim()
end

return Inputs
