-- Lua 5.1 regression: two photos and two catalogs, independent per-photo recipes,
-- grouped sync, cached defaults and preserving unsaved changes after a write failure.
package.path = "Spektrafilm.lrplugin/?.lua;" .. package.path
local Json = require "Json"
local persisted, tasks, fail = {}, {}, false
local modules={
    LrPathUtils={child=function(a,b)return a.."/"..b end,parent=function()return "root" end},
    LrDigest={SHA256={digest=function(path)return path end}},
    LrDialogs={message=function()end},
    LrTasks={pcall=pcall,sleep=function()end,startAsyncTask=function(f)tasks[#tasks+1]=f end},
    LrView={},
}
_PLUGIN={path="project/plugin"}
function import(name) return assert(modules[name],name) end
package.preload.ProjectData=function() return {
    read=function(folder,key) return persisted[folder.."/"..key] end,
    write=function(folder,records)
        if fail then error("disk unavailable") end
        for k,v in pairs(records) do persisted[folder.."/"..k]=Json.clone(v) end
    end,
} end
local Recipes=require "PhotoRecipes"
local catalog={getPath=function()return "catalog-A" end}
local a,b={localIdentifier=1},{localIdentifier=2}
local defaults={film="Portra",paper="Endura",mode="full",options={}}
local store=Recipes.open(catalog)
local own=store:get(a,defaults)
own.film="Tri-X"; own.paper="MG"; own.options.grain=1.6
store:set(a,own)
local second=store:get(b,defaults)
second.options.film_ev=1
store:set(b,Recipes.merge(second,own,{[3]=true}))
fail=true
assert(not pcall(function()store:flush()end))
fail=false
store:flush()
local reopened=Recipes.open(catalog)
assert(reopened:get(a,defaults).film=="Tri-X")
local independent=reopened:get(b,defaults)
assert(independent.film=="Portra" and independent.options.film_ev==1 and independent.options.grain==1.6)
local other=Recipes.open({getPath=function()return "catalog-B" end})
assert(other:get(a,defaults).film=="Portra")
assert(Json.decode('{"label":"\\u80f6\\u7247","choice":false}').label=="胶片")
print("Per-photo round-trip, retry, selective sync and catalog isolation passed.")
