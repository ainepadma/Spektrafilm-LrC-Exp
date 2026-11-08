local LrApplication = import "LrApplication"
local LrDate = import "LrDate"
local LrDialogs = import "LrDialogs"
local LrFileUtils = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"
local child = LrPathUtils.child
local function module(name) return dofile(child(_PLUGIN.path,name..".lua")) end
local Json = require "Json"
local ExportInputs = require "ExportInputs"
local Settings = require "ExportSettings"
local Render, Printing, Panel = module("Render"),module("Printing"),module("RecipePanel")
local PhotoRecipes, Workspace = module("PhotoRecipes"),module("WorkspaceSession")
local Strip, Inspector = module("BrowseTools"),module("WorkspaceInspector")

local function preferred(items, value)
    for _, item in ipairs(items) do
        if item.value == value then return value end
    end
    return items[1].value
end

local function samePhoto(a, b)
    return a == b or (a and b and a.localIdentifier and a.localIdentifier == b.localIdentifier)
end

local function sameSelection(left, right)
    if #left ~= #right then return false end
    for i, photo in ipairs(left) do
        if not samePhoto(photo, right[i]) then return false end
    end
    return true
end

local function runEditor(context, ws)
    local catalog = LrApplication.activeCatalog()
    local p={photoName=""}
    local session = Render.newSession()
    local inputs = ExportInputs.new(session)
    local state = {revision=0,inputVersion=0,dirty=true,busy=false,closed=false,
        width=1600,height=1000,selection={},candidates={},index=0,previews={},options={},
        inspection={enabled=false,mode="after",zoom="fit",divider=50,x=50,y=50}}
    local function status(text)
        if not state.closed then p.status=text;state.dirty=true end
    end
    local strip=Strip.new(ws,Workspace,function() state.dirty=true end)
    local inspector=Inspector.new(session,Render)
    context:addCleanupHandler(function() strip.closed=true;state.closed=true;Render.closeSession(session) end)
    local lists = Render.profiles(session)
    local store = PhotoRecipes.open(catalog,status)
    local presets=Settings.presets()
    p.film = preferred(lists.film, "kodak_portra_400")
    p.paper = preferred(lists.paper, "kodak_portra_endura")
    local previous = Settings.load()
    p.folder, p.format, p.edge = previous.folder, previous.format, previous.edge
    p.mode = previous.mode or "full"
    p.status, p.selection = "", ""
    Printing.setup(p, previous)
    p.category = "all"
    Panel.match(p, lists, state.options, false)

    local function setPicture(path, photo, mate, histogram)
        p.picture, p.histogram = path,histogram
        state.picturePhoto, state.pictureMate, state.dirty = photo, mate, true
    end

    local function currentPhoto()
        return state.candidates[state.index]
    end
    local function alignPair()
        if p.pair and #state.selection > 1 and state.index > 0 then
            state.index = state.index - (state.index-1) % 2
        end
    end

    local function getRecipe()
        return {film=p.film, paper=p.paper, mode=p.mode, options=Json.clone(state.options),
                printing=Printing.snapshot(p)}
    end
    local function pairOptions(printing, mate, firstRecipe)
        local second = Panel.forRender(store:get(mate, firstRecipe), lists)
        printing.pairFilm, printing.pairPaper = second.film, second.paper
        printing.pairRecipe = second.options or {}
        printing.pairMode = second.mode
        printing.partnerSource = mate:getRawMetadata("path")
    end

    local function restorePhoto(force)
        local photo = currentPhoto()
        if not force and samePhoto(photo, state.controlsPhoto) then return end
        state.restoring = true
        if photo then
            local recipe = store:get(photo, getRecipe())
            p.category, p.film, p.paper = "all", recipe.film, recipe.paper
            p.mode, state.options = recipe.mode or "full", Json.clone(recipe.options or {})
            Printing.restore(p, recipe.printing or {})
            Panel.match(p, lists, state.options, false)
        end
        state.controlsPhoto, state.signature = photo, Json.encode(getRecipe())
        state.restoring = false
    end

    local function syncSelection(keepCursor)
        local active = catalog:getTargetPhoto()
        -- With no active photo, both list APIs can return the whole filmstrip.
        local selection = active and catalog:getTargetPhotos() or {}
        local candidates = selection
        if active and #selection <= 1 then
            candidates = catalog:getMultipleSelectedOrAllPhotos()
        end
        local keep = keepCursor and samePhoto(active, state.anchor) and sameSelection(selection, state.selection)
        local cursor = keep and currentPhoto()
        local activeIndex, cursorIndex
        for i, photo in ipairs(candidates) do
            if samePhoto(photo, active) then activeIndex = i end
            if cursor and samePhoto(photo, cursor) then cursorIndex = i end
        end
        if active and not activeIndex then
            -- A source/filter may still be changing. Show only the known target.
            candidates, activeIndex, cursorIndex = { active }, 1, nil
        end
        local changed = not samePhoto(active,state.anchor) or not sameSelection(selection,state.selection)
            or not sameSelection(candidates,state.candidates)
        state.anchor, state.selection = active, selection
        if changed then state.candidates=candidates end
        state.index = cursorIndex or activeIndex or 0
        alignPair()
        return changed
    end

    local function updateControls()
        if state.closed then return end
        local photo, total = currentPhoto(), #state.candidates
        p.selection = photo and string.format("已选 %d 张", #state.selection) or "请在 LrC 中选择照片"
        p.position = photo and string.format("%d / %d", state.index, total) or "0 / 0"
        if p.pair and photo and state.index < total then
            p.position = string.format("%d–%d / %d",state.index,state.index+1,total)
        end
        p.exportTitle = p.pair and "导出半格组合" or (#state.selection > 1 and "导出所选照片" or "导出当前照片")
        p.canEdit = state.busy ~= "export"
        p.canExport = photo ~= nil and not state.busy
        p.canRefresh = photo ~= nil and p.canEdit
        p.canPaper = p.canRefresh and not p.directScan
        p.canGrain = p.canRefresh and p.mode ~= "fast-color" and state.options.grain_on ~= false
        p.canScan = p.canRefresh and not p.forcedScan
        p.canStop = state.busy == "export" and not state.stop
        p.canPrevious = p.canEdit and state.index > 1
        local step = p.pair and #state.selection > 1 and 2 or 1
        p.canNext = p.canEdit and state.index+step <= total
        state.dirty=true
    end

    local function buildPreview(revision)
        local photo = currentPhoto()
        if not photo then status(""); return end
        local version, recipe = state.inputVersion, Panel.forRender(getRecipe(), lists)
        local film, paper = recipe.film, recipe.paper
        local mode=recipe.mode
        local width,height=state.width,state.height
        local inspection=Json.clone(state.inspection)
        if inspection.enabled then
            status(inspection.zoom=="roi" and "正在读取原尺寸局部…" or "正在生成对比图…")
            local function current() return not state.closed and revision==state.revision end
            local path,hist=inspector:view(photo,recipe,inspection,width,height,version,current)
            if path and current() then
                setPicture(path,photo,nil,hist)
                status(inspection.zoom=="roi" and "100% 局部 · RGB 直方图" or "适合窗口 · RGB 直方图")
            end
            return
        end
        local printing = Printing.options(p, photo, film, paper, true, recipe.printing)
        printing.displayProof = true
        local mate = p.pair and state.candidates[state.index+1] or nil
        if p.pair and p.format == "di" then setPicture(nil); status("Cineon 中间片不支持半格配对。"); return end
        if p.pair and not mate then setPicture(nil); status("半格配对需要下一张照片。"); return end
        if mate then pairOptions(printing, mate, recipe) end
        local mateEdit = mate and mate:getRawMetadata("lastEditTime")
        local signature = Json.encode({recipe=recipe, print=printing, format=p.format,width=width,height=height})
        local edited = photo:getRawMetadata("lastEditTime")
        if state.closed or revision ~= state.revision then return end
        local ready = mode == "fast-color" and "高清预览 · 快速色彩" or "高清预览 · 完整模拟"
        if p.format == "di" then ready = "Cineon 对数预览 · 负片扫描，不叠加相纸、片边和日期背" end
        for i, entry in ipairs(state.previews) do
            if edited and entry.edited == edited and samePhoto(entry.photo, photo) and entry.version == version
                    and entry.signature == signature and samePhoto(entry.mate, mate) and entry.mateEdit == mateEdit then
                table.remove(state.previews, i)
                table.insert(state.previews, 1, entry)
                setPicture(entry.path, photo, mate)
                state.measurements = entry.measurements
                status(ready)
                return
            end
        end
        status("正在生成预览…")
        if not samePhoto(state.cachedPhoto, photo) or state.cachedVersion ~= version
                or not edited or state.cachedEdit ~= edited or state.cachedWidth~=width or state.cachedHeight~=height then
            local input = Render.input(photo, session, width, height)
            if state.input then LrFileUtils.delete(state.input) end
            state.input, state.cachedPhoto, state.cachedVersion = input, photo, version
            state.cachedEdit,state.cachedWidth,state.cachedHeight = edited,width,height
        end
        if state.closed or revision ~= state.revision then return end
        local path = child(session, "preview-" .. revision .. ".png")
        local diagnostics = child(session, "measure-" .. revision .. ".tsv")
        if mate then
            printing.pairInput = Render.input(mate, session, width, height)
        end
        local success, reason = LrTasks.pcall(Render.film, session, state.input, path, film, paper,
                                             mode, recipe.options, printing, diagnostics)
        if printing.pairInput then LrFileUtils.delete(printing.pairInput) end
        if not success then error(reason, 0) end
        local measurements = Panel.readMeasurements(diagnostics)
        LrFileUtils.delete(diagnostics)
        local latestEdit = photo:getRawMetadata("lastEditTime")
        if not state.closed and revision == state.revision and samePhoto(currentPhoto(), photo) then
            if latestEdit ~= edited or (mate and mate:getRawMetadata("lastEditTime") ~= mateEdit) then
                LrFileUtils.delete(path)
                setPicture(nil)
                status("照片调整已变化，请刷新预览。")
                return
            end
            table.insert(state.previews, 1, { photo = photo, edited = edited, version = version,
                          mate = mate, mateEdit = mateEdit, signature = signature,
                          path = path, measurements = measurements })
            if #state.previews > 4 then LrFileUtils.delete(table.remove(state.previews).path) end
            setPicture(path, photo, mate)
            state.measurements = measurements
            status(ready)
        else
            LrFileUtils.delete(path)
        end
    end

    local function requestPreview(refreshInput)
        if state.closed then return end
        alignPair()
        if state.busy ~= "export" then restorePhoto(false) end
        state.revision = state.revision + 1
        local requested = state.revision
        if refreshInput then state.inputVersion = state.inputVersion + 1 end
        local photo = currentPhoto()
        local mate = p.pair and state.candidates[state.index+1] or nil
        -- Keep the same photo on screen while its sliders render. A new
        -- selection gets a neutral canvas immediately, never a stale image.
        if not photo or not samePhoto(photo,state.picturePhoto) or not samePhoto(mate,state.pictureMate) then
            setPicture(nil)
            p.photoName = ""
        end
        state.measurements = nil
        strip:update(state.candidates,state.index,nil,refreshInput)
        updateControls()
        if photo then
            LrTasks.startAsyncTask(function()
                local ok, name = LrTasks.pcall(function()
                    local name = photo:getFormattedMetadata("fileName")
                    return mate and (name.." + "..mate:getFormattedMetadata("fileName")) or name
                end)
                if ok and not state.closed and requested == state.revision then p.photoName = name; state.dirty=true end
            end)
        end
        if state.busy then return end
        state.busy = "preview"
        updateControls()
        LrTasks.startAsyncTask(function()
            local revision
            repeat
                revision = state.revision
                -- Collapse rapid navigation and popup changes before starting work.
                LrTasks.sleep(0.12)
                if not state.closed and revision == state.revision then
                    local ok, reason = LrTasks.pcall(buildPreview, revision)
                    if not ok and revision == state.revision then status(tostring(reason)) end
                end
            until state.closed or revision == state.revision
            state.busy = false
            updateControls()
        end)
    end


    local function navigate(delta)
        if state.closed or state.busy == "export" then return end
        -- The host poll updates the pool. Browsing never changes the host selection.
        if not samePhoto(catalog:getTargetPhoto(), state.anchor) then
            syncSelection(false)
            requestPreview(true)
            return
        end
        local step = p.pair and #state.selection > 1 and 2 or 1
        local index = state.index + delta*step
        if index >= 1 and index <= #state.candidates then
            state.index = index
            requestPreview(false)
        end
    end

    local function exportSelection()
        if state.busy or state.closed then return end
        local shown, shownSelection = currentPhoto(), state.selection
        syncSelection(true)
        local current = currentPhoto()
        if not samePhoto(shown, current) or not sameSelection(shownSelection, state.selection) then
            requestPreview(true)
            return
        end
        if not current then updateControls(); return end
        local photos = #state.selection > 1 and state.selection or { current }
        local pair = p.pair
        if pair and #state.selection == 1 then photos = {current, state.candidates[state.index+1]} end
        if pair and p.format == "di" then status("Cineon 中间片不支持半格配对。"); return end
        local defaultRecipe, folder = getRecipe(), p.folder
        local size = tonumber(p.edge)
        if not size or size < 0 or size > 65535 or size ~= math.floor(size) then
            status("请输入 0 至 65535 的整数长边，0 表示原始尺寸。"); return
        end
        p.edge = size
        local edge = size > 0 and size or nil
        local startRevision = state.revision
        state.busy, state.stop = "export", false
        updateControls()
        LrTasks.startAsyncTask(function()
            local completed, failed, skipped = 0, 0, 0
            local results, published = {}, {}
            local ok, reason = LrTasks.pcall(function()
                local accessible, problem = LrFileUtils.createAllDirectories(folder)
                if not accessible then error("无法创建导出目录：" .. tostring(problem), 0) end
                local step = pair and 2 or 1
                for index = 1, #photos, step do
                    if state.closed or state.stop then break end
                    local photo, mate = photos[index], pair and photos[index+1] or nil
                    local name = photo:getFormattedMetadata("fileName")
                    status(string.format("正在导出 %d / %d · %s",index,#photos,name))
                    local input, second
                    local success, failure = LrTasks.pcall(function()
                        if pair and not mate then
                            skipped = skipped+1
                            results[#results+1] = "跳过 · "..name.."（缺少第二张）"
                            return
                        end
                        local recipe = Panel.forRender(store:get(photo, defaultRecipe),lists)
                        local path, skip = Printing.target(p, photo, recipe.film, recipe.paper, pair)
                        if skip then
                            skipped = skipped+1
                            results[#results+1] = "跳过 · "..name.."（文件已存在）"
                            return
                        end
                        local outputKey = LrPathUtils.standardizePath(path):lower()
                        if published[outputKey] then
                            skipped = skipped+1
                            results[#results+1] = "跳过 · "..name.."（本批次已有同名输出）"
                            return
                        end
                        if p.collision == "overwrite" and LrFileUtils.exists(path) == "file"
                                and catalog:findPhotoByPath(path) then
                            error("目标文件属于当前 LrC 目录，无法覆盖："..path,0)
                        end
                        local printing = Printing.options(p, photo, recipe.film, recipe.paper, false, recipe.printing)
                        local start = LrDate.currentTime()
                        local reused, mateReused
                        status(string.format("%d / %d · 正在准备 LrC 图像 · %s",index,#photos,name))
                        input,reused = inputs:acquire(photo,edge)
                        if state.closed then return end
                        if mate then
                            pairOptions(printing, mate, recipe)
                            second,mateReused = inputs:acquire(mate,edge)
                            printing.pairInput = second.path
                        end
                        if state.closed then return end
                        local rendered = LrDate.currentTime()
                        status(string.format("%d / %d · 正在生成成片 · %s",index,#photos,name))
                        Render.film(session, input.path, path, recipe.film, recipe.paper, recipe.mode, recipe.options, printing)
                        completed = completed + 1
                        published[outputKey] = true
                        local cacheNote = reused and (not mate or mateReused) and "（复用）" or ""
                        results[#results+1] = string.format("完成 · %s  |  LrC %.1f 秒%s，渲染与写盘 %.1f 秒",
                            path,rendered-start,cacheNote,LrDate.currentTime()-rendered)
                    end)
                    inputs:release(input)
                    inputs:release(second)
                    if not success then
                        failed = failed + 1
                        results[#results+1] = "失败 · "..name.."："..tostring(failure)
                    end
                end
            end)
            state.busy = false
            updateControls()
            if state.closed then return end
            if not ok then results[#results+1] = tostring(reason) end
            state.results = table.concat(results, "\n")
            local summary = string.format("已导出 %d 张，失败 %d 张。", completed, failed)
            if skipped > 0 then summary = summary.." 跳过 "..skipped.." 项。" end
            if state.stop then summary = summary.." 队列已停止。" end
            status(summary)
            if state.revision ~= startRevision then requestPreview(false) end
        end)
    end

    local function savePhoto(preferPaper)
        Panel.match(p,lists,state.options,preferPaper)
        local recipe=getRecipe()
        local signature=Json.encode(recipe)
        if signature~=state.signature and currentPhoto() then
            store:set(currentPhoto(),recipe)
            state.signature=signature
        end
        requestPreview(false)
    end

    local function output()
        local keys={"folder","format","edge","pair","quality","space","bits","collision","nameTemplate"}
        local data={}
        for _,key in ipairs(keys) do data[key]=p[key] end
        return data
    end

    local function publish()
        if not state.dirty then return end
        state.dirty=false
        local names={}
        for name in pairs(presets) do names[#names+1]=name end
        table.sort(names)
        local photo=currentPhoto()
        Workspace.publish(ws,{photoId=photo and tostring(photo.localIdentifier) or "",fileName=p.photoName,
            index=state.index,total=#state.candidates,position=p.position,selection=p.selection,
            status=p.status,busy=state.busy,preview=p.picture,histogram=p.histogram,inspection=state.inspection,
            filmItems=lists.film,paperItems=p.paperItems[1] and p.paperItems,categories=Panel.categories(lists),
            recipe=getRecipe(),export=output(),presets=names[1] and names,diagnostics=state.measurements,
            results=state.results,thumbs=strip.items[1] and strip:snapshot(),stockHint=p.stockHint,forcedScan=p.forcedScan,
            directScan=p.directScan,canScan=p.canScan,canPaper=p.canPaper,canGrain=p.canGrain,canEdit=p.canEdit,
            canExport=p.canExport,canRefresh=p.canRefresh,canStop=p.canStop,canPrevious=p.canPrevious,
            canNext=p.canNext,canBackPage=strip.back,canNextPage=strip.forward,exportTitle=p.exportTitle})
    end

    local function applyEdit(a)
        local key,value=a.key,a.value
        if a.group=="export" then
            if output()[key]==nil then return end
            if key=="folder" and (type(value)~="string" or value:find("%c") or not LrPathUtils.isAbsolute(value)) then
                error("请输入完整的导出目录路径。",0)
            end
            p[key]=value
            if key=="pair" or key=="format" or (key=="space" and p.format=="di") then
                requestPreview(false)
            else
                state.dirty=true
            end
        elseif currentPhoto() then
            if a.group=="recipe" then
                if key~="film" and key~="paper" and key~="mode" then return end
                p[key]=value
            elseif a.group=="options" then
                if key=="scan" and p.forcedScan then return end
                if value==Json.null then value=nil end
                state.options[key]=value
            elseif a.group=="printing" and Printing.snapshot(p)[key]~=nil then
                if key=="paperColor" and (type(value)~="string" or not value:match("^#%x%x%x%x%x%x$")) then
                    error("请输入六位纸面色值，例如 #F7F3E9。",0)
                end
                p[key]=value
            else return end
            savePhoto(key=="film")
        end
    end

    local function paste(batch,groups)
        local current=currentPhoto()
        if not current then return end
        local source=batch and getRecipe() or store.clipboard
        if not source then status("请先复制照片设置。");return end
        if batch and #state.selection<2 then status("请先在 LrC 中选择至少两张照片。");return end
        local selected,count={},0
        for _,i in ipairs(groups or {}) do selected[i]=true end
        if not next(selected) then status("请选择要应用的设置组。");return end
        for _,photo in ipairs(batch and state.selection or {current}) do
            if not batch or not samePhoto(photo,current) then
                store:set(photo,PhotoRecipes.merge(store:get(photo,store.defaults or getRecipe()),source,selected))
                count=count+1
            end
        end
        restorePhoto(true)
        requestPreview(false)
        status(string.format("已更新 %d 张照片。",count))
    end

    local function preset(a)
        if a.operation=="save" then
            local values=Printing.settings(p)
            for _,key in ipairs({"format","edge","mode","folder"}) do values[key]=p[key] end
            Settings.savePreset(a.name,values)
            presets[a.name]=values
            status("已保存输出配方 · "..a.name)
        elseif a.operation=="load" and presets[a.name] then
            local values=presets[a.name]
            for k in pairs(Printing.settings(p)) do if values[k]~=nil then p[k]=values[k] end end
            for _,k in ipairs({"format","edge","mode","folder"}) do if values[k]~=nil then p[k]=values[k] end end
            savePhoto(false)
        end
    end

    local function dispatch(kind,a)
        a=a or {}
        if kind=="close" then state.closed=true;return end
        if kind=="viewport" then
            local width,height=tonumber(a.width),tonumber(a.height)
            if not width or not height or width<64 or height<64 then return end
            local scale=math.min(1,4096/math.max(width,height))
            width,height=math.max(64,math.floor(width*scale+.5)),math.max(64,math.floor(height*scale+.5))
            if width~=state.width or height~=state.height then
                state.width,state.height=width,height
                requestPreview(false)
            end
            return
        end
        if kind=="stop" then
            if state.busy=="export" then state.stop=true;updateControls();status("当前项完成后停止。") end
            return
        end
        if state.busy=="export" then return end
        local photo=currentPhoto()
        if a.photoId and a.photoId~="" and (not photo or tostring(a.photoId)~=tostring(photo.localIdentifier)) then
            state.dirty=true;return
        end
        if kind=="navigate" then
            if a.index and state.candidates[a.index] then state.index=a.index;requestPreview(false)
            elseif a.delta then navigate(a.delta) end
        elseif kind=="thumbPage" then
            strip:update(state.candidates,state.index,a.delta);state.dirty=true
        elseif kind=="refresh" then inputs:invalidate();syncSelection(true);requestPreview(true)
        elseif kind=="edit" then applyEdit(a)
        elseif kind=="instant" and photo then
            if p.format=="di" then status("请先切换到 JPEG、PNG 或 TIFF，再套用拍立得组合。");return end
            if a.stock=="color" then
                p.film,p.paper,p.paperBorder="kodak_portra_400","kodak_portra_endura","warm"
            elseif a.stock=="bw" then
                p.film,p.paper,p.paperBorder="ilford_hp5_plus_400","ilford_multigrade_iv_rc","white"
            else return end
            p.category,p.paperLayout,p.paperMargin,p.gate="all","instant",0.06,"none"
            state.options.scan=false
            savePhoto(false)
        elseif kind=="copy" and photo then store.clipboard=getRecipe();status("已复制当前照片的设置。")
        elseif kind=="paste" or kind=="sync" then paste(kind=="sync",a.groups)
        elseif kind=="export" then exportSelection()
        elseif kind=="preset" then preset(a)
        elseif kind=="inspect" then
            local nextView=Json.clone(state.inspection)
            nextView.enabled=a.enabled~=false
            for _,key in ipairs({"mode","zoom","divider","x","y"}) do
                if a[key]~=nil then nextView[key]=a[key] end
            end
            state.inspection=nextView
            if not nextView.enabled then p.histogram=nil end
            requestPreview(false)
        end
    end

    syncSelection(false)
    requestPreview(false)
    local nextHostCheck,nextPoolCheck=0,0
    while not state.closed do
        publish()
        if not Workspace.poll(ws,function(kind,payload)
            local ok,why=LrTasks.pcall(dispatch,kind,payload)
            if not ok then status(tostring(why));error(why,0) end
        end) then break end
        local now=LrDate.currentTime()
        if now>=nextHostCheck and state.busy~="export" then
            nextHostCheck=now+0.6
            local active=catalog:getTargetPhoto()
            local selection=active and catalog:getTargetPhotos() or {}
            if now>=nextPoolCheck or not samePhoto(active,state.anchor) or not sameSelection(selection,state.selection) then
                if syncSelection(true) then requestPreview(false) end
                nextPoolCheck=now+math.max(1.2,math.min(15,#state.candidates/1500))
            end
        end
        LrTasks.sleep(0.08)
    end
    strip.closed=true
    Render.stopSession(session)
    state.closed = true
    -- The worker owns intermediate files until its process exits.
    while state.busy do LrTasks.sleep(0.1) end
    local problem=Workspace.status(ws)
    store:flush()
    Settings.save(p.folder, p.format, p.edge, p.mode, Printing.settings(p))
    if problem then error(problem,0) end
end

local function show(context)
    local ws=Workspace.open()
    _G.spektrafilmWindow.toFront=function() Workspace.focus(ws) end
    context:addCleanupHandler(function() Workspace.close(ws) end)
    local ok,why=LrTasks.pcall(function()
        LrFunctionContext.callWithContext("Spektrafilm renderer",function(renderContext)
            runEditor(renderContext,ws)
        end)
    end)
    if not ok then
        if Workspace.status(ws) then error(why,0) end
        local message="工作区错误 · "..tostring(why)
        Workspace.publish(ws,{fileName="Spektrafilm",position="",status=message,results=message,
            recipe={options={},printing={}},export={},canEdit=false,canExport=false})
        local closed=false
        while not closed and Workspace.poll(ws,function(kind) closed=kind=="close" end) do
            LrTasks.sleep(0.1)
        end
    end
end

LrTasks.startAsyncTask(function()
    -- The SDK shares this plug-in environment between menu invocations.
    local existing = _G.spektrafilmWindow
    if existing then
        if existing.toFront then existing.toFront() end
        return
    end
    _G.spektrafilmWindow = {}
    local ok, reason = LrTasks.pcall(function()
        LrFunctionContext.callWithContext("Spektrafilm", show)
    end)
    _G.spektrafilmWindow = nil
    if not ok then LrDialogs.showBezel("Spektrafilm · "..tostring(reason),8) end
end)
