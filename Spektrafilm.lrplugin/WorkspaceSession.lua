-- A single project-local WPF endpoint. Each window gets a new immutable inbox:
-- no network listener, inherited selection, or replay of a previous window's events.
local LrDate = import "LrDate"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrStringUtils = import "LrStringUtils"
local LrTasks = import "LrTasks"
local Json = require "Json"
local newFolder = require "WorkFolder"
local powershell = require "WindowsProcess"

local Workspace = {}
local child = LrPathUtils.child
local root = LrPathUtils.parent(_PLUGIN.path)

local function mkdir(path)
    local ok, reason = LrFileUtils.createAllDirectories(path)
    if not ok then error(tostring(reason),0) end
end

local function writePacket(path, bytes, directorySuffix)
    -- The SDK uses Unicode Windows paths; Lua 5.1 streams may use an ANSI code page.
    local temp = path..".tmp"
    local file = not path:find("[\128-\255]") and io.open(temp,"wb")
    if file then
        local ok, reason = file:write(bytes)
        local closed, closeReason = file:close()
        if not ok or not closed then
            LrFileUtils.delete(temp)
            error(tostring(reason or closeReason),0)
        end
        local moved, moveReason = LrFileUtils.move(temp,path)
        if not moved then LrFileUtils.delete(temp); error(tostring(moveReason),0) end
        return
    end
    if directorySuffix then path=path..directorySuffix end
    mkdir(path)
    local encoded = LrStringUtils.encodeBase64(bytes):gsub("%s",""):gsub("%+","-"):gsub("/","_")
    for pos=1,#encoded,112 do
        mkdir(child(path,string.format("%08d_",pos)..encoded:sub(pos,pos+111)))
    end
    mkdir(child(path,"complete"))
end

local function beat(w)
    local pulse=child(child(w.path,"heartbeat"),"tick")
    mkdir(pulse)
    LrFileUtils.delete(pulse)
end

function Workspace.open()
    local runtime=child(root,".runtime")
    local parent=child(runtime,"workspaces")
    local logs=child(runtime,"logs")
    local main=child(child(root,"workspace"),"Main.ps1")
    if LrFileUtils.exists(main)~="file" then error("缺少工作台程序："..main,0) end
    mkdir(parent); mkdir(logs)
    local path=newFolder(parent,string.format("window-%.0f",LrDate.currentTime()*1000))
    local w={path=path,sequence=0,received=0,assets=0}
    for _,name in ipairs({"state","events","replies","assets","heartbeat"}) do mkdir(child(path,name)) end
    w.log=LrFileUtils.chooseUniqueFileName(child(logs,LrPathUtils.leafName(path)..".log"))
    w.started=LrDate.currentTime()
    beat(w)
    LrTasks.startAsyncTask(function()
        local _,code=LrTasks.pcall(powershell,{main,path,w.log},{
            "$ErrorActionPreference='Stop'", "$q=[char]34",
            "$a='-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File '+$q+$v[0]+$q+' -Session '+$q+$v[1]+$q",
            "$p=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $a "..
                "-WindowStyle Hidden -RedirectStandardError $v[2] -RedirectStandardOutput ($v[2]+'.out') -PassThru",
            "$handle=$p.Handle", "$stop=[IO.Path]::Combine($v[1],'stop')",
            "$beat=[IO.Path]::Combine($v[1],'heartbeat')", "$stopTime=$null",
            "try { while (-not $p.WaitForExit(750)) { "..
                "if ([IO.Directory]::Exists($stop) -and $null -eq $stopTime) { $stopTime=[DateTime]::UtcNow }; "..
                "if (([DateTime]::UtcNow-[IO.Directory]::GetLastWriteTimeUtc($beat)).TotalSeconds -gt 120 "..
                "-or ($stopTime -and ([DateTime]::UtcNow-$stopTime).TotalSeconds -gt 8)) { $p.Kill(); break } }; "..
                "$p.WaitForExit(); exit $p.ExitCode } finally { if (-not $p.HasExited) { $p.Kill() }; $p.Dispose() }",
        })
        w.exited=true
        w.exitCode=tostring(code)
        if w.closed then LrFileUtils.delete(path) end
    end)
    LrTasks.startAsyncTask(function()
        while not w.closed and not w.exited do
            LrTasks.sleep(5)
            if not w.closed and not w.exited then beat(w) end
        end
    end)
    return w
end

function Workspace.stage(w, leaf, bytes)
    assert(type(bytes)=="string" and #bytes>0,"Invalid workspace image")
    assert(type(leaf)=="string" and leaf:match("%.[A-Za-z0-9]+$"),"Expected image extension")
    if w.closed or w.exited then return nil end
    w.assets=w.assets+1
    local ext=leaf:match("(%.[A-Za-z0-9]+)$"):lower()
    assert(ext==".jpg" or ext==".jpeg" or ext==".png","Unsupported workspace image")
    local file=child(child(w.path,"assets"),string.format("image-%08d",w.assets)..ext)
    writePacket(file,bytes,".payload")
    return file
end

function Workspace.publish(w,state)
    if w.closed or w.exited then return end
    local bytes=Json.encode(state)
    if bytes==w.pendingState or (not w.publishing and bytes==w.lastState) then return end
    w.pendingState=bytes
    if w.publishing then return end
    w.publishing=true
    local ok,reason=LrTasks.pcall(function()
        while w.pendingState and not w.closed and not w.exited do
            local latest=w.pendingState
            w.pendingState=nil
            if latest~=w.lastState then
                local seq=w.sequence+1
                writePacket(child(child(w.path,"state"),string.format("%08d.json",seq)),latest)
                w.sequence,w.lastState=seq,latest
            end
        end
    end)
    w.publishing=false
    if not ok then w.problem=tostring(reason).."。日志："..w.log; error(w.problem,0) end
end

function Workspace.focus(w)
    if w and not w.closed and not w.exited then mkdir(child(w.path,"focus")) end
end

local function errorMessage(err)
    return tostring(err):sub(1,4000)
end

function Workspace.status(w)
    if w.problem then return w.problem end
    if w.exited and not w.redirected and not LrFileUtils.exists(child(w.path,"redirected")) then
        if w.exitCode~="0" then return "工作台进程已退出 ("..w.exitCode..")。日志："..w.log end
        if not w.closed and not w.ready and not LrFileUtils.exists(child(w.path,"ready")) then
            return "工作台程序在窗口就绪前退出。日志："..tostring(w.log)
        end
    end
end

function Workspace.poll(w,dispatch)
    if w.closed then return false end
    if w.polling then return true end
    w.polling=true
    local ok,reason=LrTasks.pcall(function()
        -- Advance the cursor before calling user code: a yielding or failed handler
        -- cannot replay an export when the next menu/timer callback runs.
        for _=1,32 do
            local id=w.received+1
            local leaf=string.format("%08d.json",id)
            local eventFile=child(child(w.path,"events"),leaf)
            if LrFileUtils.exists(eventFile)~="file" then break end
            w.received=id
            local success,result=LrTasks.pcall(function()
                local event=Json.decode(LrFileUtils.readFile(eventFile))
                assert(type(event)=="table" and event.id==id and type(event.action)=="string",
                       "Invalid workspace event")
                return dispatch(event.action,event.payload or {},id)
            end)
            if w.closed then break end
            if not w.exited and not LrFileUtils.exists(child(w.path,"closed")) then
                local reply={id=id,ok=success}
                if success then reply.result=result else reply.error=errorMessage(result) end
                local encoded,response=pcall(Json.encode,reply)
                if not encoded then response=Json.encode({id=id,ok=false,error=errorMessage(response)}) end
                writePacket(child(child(w.path,"replies"),leaf),response)
            end
            LrFileUtils.delete(eventFile)
        end
    end)
    w.polling=false
    if not ok then w.problem=errorMessage(reason).."。日志："..w.log; return false end
    w.redirected=LrFileUtils.exists(child(w.path,"redirected")) and true
    if w.exited or LrFileUtils.exists(child(w.path,"closed")) or w.redirected then
        -- Closing flushes pending range/text edits before emitting the marker.
        -- Preserve the normal per-tick work bound while draining those events.
        local nextLeaf=string.format("%08d.json",w.received+1)
        return not w.closed and LrFileUtils.exists(child(child(w.path,"events"),nextLeaf))=="file"
    end
    if not w.ready then
        w.ready=LrFileUtils.exists(child(w.path,"ready")) and true
        if not w.ready and LrDate.currentTime()-w.started>90 then
            w.problem="工作台启动超时。日志："..w.log
            return false
        end
    end
    return true
end

function Workspace.close(w)
    if not w or w.closed then return end
    w.closed=true
    if w.exited then LrFileUtils.delete(w.path) else mkdir(child(w.path,"stop")) end
end

return Workspace
