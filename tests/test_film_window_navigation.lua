-- Drive the normal menu entry point and the same messages as the WPF sidebar.
package.path="Spektrafilm.lrplugin/?.lua;"..package.path
local Json=require "Json"
local catalog, photos, active, selected, visible={},{}
local stored,presets,inputs,renders,events={}, {}, {}, {}, {}
local deleted,files={},{}
local state,saved,closed,callback=nil,nil,false,nil
local now=0
for i=1,4 do
    photos[i]={localIdentifier=i,edited=1,
        requestJpegThumbnail=function(_,w,h,f) f("jpeg") end,
        getRawMetadata=function(self,key)
            if key=="lastEditTime" then return self.edited end
            if key=="path" then return "/original/"..i..".tif" end
        end,
        getFormattedMetadata=function(_,key) if key=="fileName" then return i..".tif" end end}
end
active,selected,visible=nil,{},photos
catalog.getPath=function() return "/catalog" end
catalog.getTargetPhoto=function() return active end
catalog.getTargetPhotos=function() assert(active);return selected end
catalog.getMultipleSelectedOrAllPhotos=function() assert(#selected==1);return visible end
local modules={
    LrApplication={activeCatalog=function() return catalog end},
    LrDate={currentTime=function() return now end},
    LrPathUtils={child=function(a,b)return a.."/"..b end,parent=function()return "." end,
        standardizePath=function(s)return s end,removeExtension=function(s)return s:gsub("%.[^.]+$","")end,
        isAbsolute=function(s)return s:sub(1,1)=="/" end},
    LrFileUtils={delete=function(p)deleted[p]=true end,exists=function(p)return files[p] and "file" or false end,
        createAllDirectories=function()return true,true end,chooseUniqueFileName=function(p)return p end,
        readFile=function(p)return files[p] end},
    LrTasks={pcall=pcall,startAsyncTask=function(f)f()end,sleep=function()end},
    LrDialogs={showBezel=function(msg)error(msg,0)end},
    LrDigest={SHA256={digest=function(s)return s end}},
    LrFunctionContext={callWithContext=function(_,f)
        local cleanup={}
        f({addCleanupHandler=function(_,h)cleanup[#cleanup+1]=h end})
        for i=#cleanup,1,-1 do cleanup[i]() end
    end},
}
function import(name)return assert(modules[name],name) end
_PLUGIN={path="Spektrafilm.lrplugin"}
package.loaded.ProjectData={
    read=function(folder,key)return stored[folder..key]end,
    write=function(folder,records)for k,v in pairs(records) do stored[folder..k]=Json.clone(v) end end,
}
package.loaded.ExportSettings={
    load=function()return {folder="/export",format="tif",edge=0,mode="full"}end,
    save=function(...) saved={...} end,
    presets=function()return presets end,
    savePreset=function(name,r)presets[name]=r end,
}
local Render={
    newSession=function()return "/session"end,stopSession=function()end,closeSession=function()end,
    profiles=function()return {film={{value="neg",channel="color",type="negative",title="Negative",targetPrint="paper"},
        {value="slide",channel="color",type="positive",title="Slide"},
        {value="ilford_hp5_plus_400",channel="bw",type="negative",title="HP5 Plus"}},
        paper={{value="paper",channel="color",title="Paper"},
        {value="ilford_multigrade_iv_rc",channel="bw",title="Multigrade"}}}end,
    input=function(photo,_,w,h,space)
        local path="/session/input-"..(#inputs+1)..".tif"
        inputs[#inputs+1]={id=photo.localIdentifier,w=w,h=h,space=space,path=path}
        return path
    end,
    film=function(_,input,path,film,paper,mode,options,printing)
        renders[#renders+1]={input=input,path=path,film=film,mode=mode,options=options,printing=Json.clone(printing)}
        if callback then local fn=callback;callback=nil;fn() end
    end,
}
package.loaded.Render=Render
package.loaded.WorkerSession={request=function(_,args)
    events[#events+1]=args
    if args[1]=="crop-input" then
        for i,v in ipairs(args)do if v=="--info" then files[args[i+1]]='{"fraction":0.5}' end end
    end
end}
local steps={}
local function step(fn)steps[#steps+1]=fn end
local function send(kind,a) return function(dispatch)dispatch(kind,a or {})end end
step(function() assert(state.position=="0 / 0" and not state.canExport);active,selected=photos[2],{photos[2]}end)
step(function(d)
    assert(state.photoId=="2" and state.position=="2 / 4" and #state.thumbs==4)
    assert(renders[1].printing.paperBorder=="auto" and renders[1].printing.displayProof and renders[1].mode=="full")
    assert(state.preview:match("%.png$") and state.thumbs[2].selected)
    d("viewport",{width=2260,height=1350})
end)
step(function(d)
    assert(inputs[#inputs].w==2260 and inputs[#inputs].h==1350)
    d("edit",{group="printing",key="paperBorder",value="black",photoId="2"})
    d("edit",{group="printing",key="paperMargin",value=.1,photoId="2"})
    d("edit",{group="options",key="film_ev",value=.45,photoId="2"})
    d("copy",{photoId="2"})
end)
local cachedPath
step(function(d)
    cachedPath=state.preview
    assert(renders[#renders].printing.paperBorder=="black" and renders[#renders].printing.paperMargin==.1)
    d("navigate",{delta=1})
    d("edit",{group="recipe",key="film",value="slide",photoId="2"})
end)
step(function(d)
    assert(state.photoId=="3" and active==photos[2] and state.recipe.film=="neg")
    d("edit",{group="recipe",key="film",value="slide",photoId="3"})
    d("edit",{group="options",key="film_ev",value=-.4,photoId="3"})
end)
step(function(d)
    assert(state.directScan and not state.canPaper)
    d("paste",{groups={2},photoId="3"})
end)
step(function(d)
    assert(state.recipe.options.film_ev==.45, "paste must restore the copied exposure")
    d("navigate",{delta=-1})
end)
step(function(d)
    assert(state.photoId=="2" and state.preview==cachedPath)
    d("inspect",{enabled=true,mode="split",zoom="fit",divider=34})
end)
step(function(d)
    assert(state.histogram and state.preview:match("view.png$") and events[#events][1]=="inspect")
    local n=#renders;d("inspect",{enabled=true,mode="before",divider=51})
    assert(#renders==n,"moving the divider must reuse the inspected pixels")
    d("inspect",{enabled=true,mode="after",zoom="roi",x=37,y=45})
end)
step(function(d)
    assert(events[#events-1][1]=="crop-input" and renders[#renders].printing.frameFraction==.5)
    d("inspect",{enabled=false})
    d("edit",{group="export",key="nameTemplate",value="{name}-proof"})
    d("preset",{operation="save",name="proof"})
end)
step(function(d)
    assert(state.preview==cachedPath and not state.histogram and presets.proof.nameTemplate=="{name}-proof")
    d("export",{photoId="2"})
    local r=renders[#renders]
    assert(r.path=="/export/2-proof.tif" and r.printing.paperBorder=="black" and not r.printing.displayProof)
end)
step(function()
    assert(state.results:find("2%-proof.tif"))
end)
step(function(d)
    d("edit",{group="export",key="format",value="di"})
    d("edit",{group="export",key="space",value="p3"})
    assert(renders[#renders].printing.cineon and renders[#renders].printing.outputSpace=="p3")
    d("edit",{group="export",key="format",value="tif"})
    active,selected=photos[2],{photos[2],photos[3],photos[4]}
end)
step(function(d)
    assert(state.selection=="已选 3 张");d("edit",{group="export",key="pair",value=true})
    d("export",{})
    assert(renders[#renders].printing.pairInput and renders[#renders].printing.pairFilm=="slide")
end)
step(function(d)
    assert(state.results:find("缺少第二张",1,true))
    d("edit",{group="export",key="pair",value=false})
    callback=function()d("stop",{})end
    local before=#renders;d("export",{});assert(#renders==before+1)
end)
step(function(d)
    assert(state.status:find("队列已停止",1,true));d("sync",{groups={1,5}})
    d("instant",{stock="bw",photoId=state.photoId})
end)
step(function()
    assert(state.recipe.film=="ilford_hp5_plus_400" and state.recipe.paper=="ilford_multigrade_iv_rc")
    assert(state.recipe.printing.paperLayout=="instant" and state.recipe.printing.paperMargin==.06)
    active,selected=nil,{}
end)
step(function() assert(state.position=="0 / 0" and not state.canExport and not state.preview) end)
local ws={
    open=function()return {}end,close=function()closed=true end,focus=function()end,
    status=function()return nil end,stage=function(_,name)return "/session/"..name end,
    publish=function(_,s)
        assert(not (s.status or ""):find("工作区错误",1,true),s.status)
        state=Json.clone(s)
    end,
    poll=function(_,dispatch)
        local f=table.remove(steps,1);if not f then return false end
        now=now+2;f(dispatch);return true
    end,
}
local original=dofile
function dofile(path)
    if path:match("/WorkspaceSession%.lua$") then return ws end
    if path:match("/Render%.lua$") then return Render end
    return original(path)
end
dofile("Spektrafilm.lrplugin/FilmWindow.lua")
assert(closed and saved and not _G.spektrafilmWindow)
print("Passed single-window navigation, high-DPI previews, paper proof/export, inspector, presets, and batch controls.")
