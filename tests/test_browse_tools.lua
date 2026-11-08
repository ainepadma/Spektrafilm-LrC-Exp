-- The WPF filmstrip requests Lightroom thumbnails only for the visible page.
package.path="Spektrafilm.lrplugin/?.lua;"..package.path
local deleted={}
function import(name)
    if name=="LrFileUtils" then return {delete=function(p) deleted[p]=true end} end
    return {startAsyncTask=function(f) f() end,pcall=pcall}
end
local Strip=require "BrowseTools"
local photos,pending={},{}
for i=1,20 do
    photos[i]={localIdentifier=i,requestJpegThumbnail=function(_,w,h,cb)
        assert(w>=200 and h>=100);pending[i]=cb;return {}
    end}
end
local files,changed=0,0
local strip=Strip.new({}, {stage=function(_,leaf,bytes)
    files=files+1;assert(bytes=="JPEG");return leaf
end},function() changed=changed+1 end)
strip:update(photos,1)
local rows=strip:snapshot()
assert(#rows==9 and rows[1].selected and not strip.back and strip.forward)
pending[1]("JPEG")
assert(strip:snapshot()[1].path and changed==1)
strip:update(photos,1,1)
assert(strip:snapshot()[1].index==10 and strip.back and strip.forward)
pending[2]("JPEG")
assert(files==1,"an obsolete page must not publish pending assets")
strip:update(photos,20)
rows=strip:snapshot()
assert(#rows==2 and rows[2].selected and not strip.forward)
strip:update({},0)
assert(#strip:snapshot()==0 and not strip.back)
strip.closed=true
pending[20]("JPEG");assert(files==1)
print("Passed visible-page thumbnail loading, late callbacks, paging, and empty selection.")
