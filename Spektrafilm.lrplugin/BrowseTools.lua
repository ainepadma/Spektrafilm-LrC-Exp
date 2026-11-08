local LrFileUtils = import "LrFileUtils"
local LrTasks = import "LrTasks"
local Strip = {}
Strip.__index = Strip
local slots = 9

function Strip.new(workspace, transport, changed)
    return setmetatable({workspace=workspace,transport=transport,changed=changed,first=1,
        entries={},items={},sequence=0},Strip)
end

function Strip:load(photo, id)
    self.sequence=self.sequence+1
    local entry={sequence=self.sequence}
    self.entries[id]=entry
    LrTasks.startAsyncTask(function()
        if self.closed or self.entries[id]~=entry then return end
        local ok,request=LrTasks.pcall(function()
            return photo:requestJpegThumbnail(224,150,function(bytes)
                if self.closed or self.entries[id]~=entry or not bytes then return end
                LrTasks.startAsyncTask(function()
                    if self.closed or self.entries[id]~=entry then return end
                    local saved,path=LrTasks.pcall(self.transport.stage,self.workspace,
                        "thumb-"..entry.sequence..".jpg",bytes)
                    if saved and not self.closed and self.entries[id]==entry then
                        entry.path=path
                        self.changed()
                    end
                end)
            end)
        end)
        if ok then entry.request=request end
    end)
    return entry
end

function Strip:update(candidates,index,pageDelta,refresh)
    local count=#candidates
    if pageDelta then self.first=self.first+pageDelta*slots
    elseif self.index~=index or refresh or self.pool~=candidates then
        self.first=math.floor(math.max(0,index-1)/slots)*slots+1
    end
    self.index,self.pool=index,candidates
    self.first=math.max(1,math.min(self.first,math.floor(math.max(0,count-1)/slots)*slots+1))
    self.back,self.forward=self.first>1,self.first+slots<=count
    local visible,items={},{}
    for i=self.first,math.min(count,self.first+slots-1) do
        local photo=candidates[i]
        local id=tostring(photo.localIdentifier)
        local entry=self.entries[id]
        if refresh and entry and entry.path then LrFileUtils.delete(entry.path) end
        if refresh or not entry then entry=self:load(photo,id) end
        visible[id]=true
        items[#items+1]={id=id,index=i,label=tostring(i),selected=i==index}
    end
    for id,entry in pairs(self.entries) do
        if not visible[id] then
            self.entries[id]=nil
            if entry.path then LrFileUtils.delete(entry.path) end
        end
    end
    self.items=items
end

function Strip:snapshot()
    for _,row in ipairs(self.items) do row.path=self.entries[row.id].path end
    return self.items
end

return Strip
