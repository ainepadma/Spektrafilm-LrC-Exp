-- Closing the WPF window may leave several ticks' worth of committed edits.
package.path="Spektrafilm.lrplugin/?.lua;"..package.path
local Json=require "Json"
local files={}
local sdk={
    LrDate={}, LrStringUtils={}, LrTasks={pcall=pcall},
    LrPathUtils={child=function(a,b)return a.."/"..b end,parent=function()return "project" end},
    LrFileUtils={
        exists=function(path)return files[path] and files[path].type or false end,
        readFile=function(path)return files[path].data end,
        delete=function(path)files[path]=nil end,
    },
}
function import(name)return sdk[name] end
_PLUGIN={path="project/Spektrafilm.lrplugin"}
local Workspace=require "WorkspaceSession"
local w={path="project/session",received=0,exited=true,exitCode="0",ready=true}
files[w.path.."/closed"]={type="directory"}
for id=1,67 do
    local path=string.format("%s/events/%08d.json",w.path,id)
    files[path]={type="file",data=Json.encode({id=id,action="edit",payload={value=id}})}
end
local calls=0
local function dispatch(action,payload,id)
    calls=calls+1
    assert(action=="edit" and id==calls and payload.value==id)
    if id==2 then error("Rejected edit") end
end
assert(Workspace.poll(w,dispatch) and calls==32)
assert(Workspace.poll(w,dispatch) and calls==64)
assert(not Workspace.poll(w,dispatch) and calls==67)
assert(not Workspace.poll(w,dispatch) and calls==67)
assert(not Workspace.status(w))
print("Workspace drains all committed edits after close, including events after a rejected edit.")
