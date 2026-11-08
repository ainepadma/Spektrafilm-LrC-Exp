-- Export intermediates may be reused only for the same physical file, edit and size.
package.path="Spektrafilm.lrplugin/?.lua;"..package.path
local files, count = {}, 0
local megabyte = 1024*1024
local outputSize = 100*megabyte
package.preload.Render = function() return {input=function()
    count=count+1
    local path="session/render-"..count
    files[path]={fileSize=outputSize,fileModificationDate=1}
    return path
end} end
local modules={
    LrTasks={pcall=pcall},
    LrDigest={SHA256={digest=function(s)return s end}},
    LrFileUtils={
        exists=function(path)return files[path] and "file" end,
        fileAttributes=function(path)return files[path] end,
        delete=function(path)
            assert(path:find("session/",1,true)==1,"only remove our rendition")
            files[path]=nil
        end,
    },
}
function import(name)return assert(modules[name],name)end
local cache=require("ExportInputs").new("session")
local a={localIdentifier=1, edit=10, source="test.raw"}
function a:getRawMetadata(key) return key=="path" and self.source or self.edit end
function a:getDevelopSettings() return {Exposure2012=self.exposure or 0} end
files[a.source]={fileModificationDate=12,fileSize=12345}
local item,reused=cache:acquire(a,2048)
assert(not reused)
cache:release(item)
local again,hit=cache:acquire(a,2048)
assert(hit and again.path==item.path and count==1)
cache:release(again)
a.exposure=1
local recrop,sharedTime=cache:acquire(a,2048)
assert(not sharedTime and recrop.path~=again.path)
cache:release(recrop)
a.edit=11
local edited,wasHit=cache:acquire(a,2048)
assert(not wasHit and edited.path~=item.path)
cache:release(edited)
files[a.source].fileModificationDate=13
local moved,old=cache:acquire(a,2048)
assert(not old)
cache:release(moved)
local resized,used=cache:acquire(a,4096)
assert(not used)
cache:invalidate()
assert(files[resized.path], "a leased input must survive invalidation")
cache:release(resized)
assert(not files[resized.path])
outputSize=420*megabyte
local tooBig=cache:acquire(a,nil)
cache:release(tooBig)
assert(not files[tooBig.path], "oversized file should be released after use")
files[a.source]=nil
local offline=cache:acquire(a,1024)
cache:release(offline)
assert(not files[offline.path])
print("Export TIFF reuse, edition/source/size invalidation, lease and disk cap passed.")
