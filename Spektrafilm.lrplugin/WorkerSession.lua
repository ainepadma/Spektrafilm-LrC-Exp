local LrDate = import "LrDate"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrStringUtils = import "LrStringUtils"
local LrTasks = import "LrTasks"
local runPowerShell = require "WindowsProcess"

local child = LrPathUtils.child
local sessions = {}
local Worker = {}

local function directory(path)
    local ok, reason = LrFileUtils.createAllDirectories(path)
    if not ok then error("无法创建渲染工作目录：" .. tostring(reason), 0) end
end

local function heartbeat(session)
    -- Creating/removing the child updates the directory's mtime on Windows.
    local tick = child(child(session, "heartbeat.txt"), "tick")
    directory(tick)
    LrFileUtils.delete(tick)
end

function Worker.open(session, root, python, worker, log)
    local state = { sequence = 0, log = log }
    local ok, reason = LrTasks.pcall(heartbeat, session)
    if not ok then
        LrFileUtils.delete(session)
        error(reason, 0)
    end
    sessions[session] = state
    LrTasks.startAsyncTask(function()
        -- The supervisor waits for this specific child. If Lightroom stops updating the
        -- heartbeat, the supervisor also reaps a child stalled inside a native render.
        local _, code = LrTasks.pcall(runPowerShell, { root, python, worker, session, log }, {
            "$ErrorActionPreference='Stop'",
            "$env:PYTHONUTF8='1'",
            "$env:TMP=[IO.Path]::Combine($v[0],'.runtime','tmp')",
            "$env:TEMP=$env:TMP",
            "$q=[char]34",
            "$a=$q+$v[2]+$q+' serve --session '+$q+$v[3]+$q",
            "$p=Start-Process -FilePath $v[1] -ArgumentList $a -WorkingDirectory $v[0] " ..
                "-WindowStyle Hidden -RedirectStandardError $v[4] " ..
                "-RedirectStandardOutput ($v[4]+'.out') -PassThru",
            -- Retaining the handle lets Windows PowerShell report the child's
            -- exit code even if it exits before the first WaitForExit call.
            "$handle=$p.Handle",
            "$stop=[IO.Path]::Combine($v[3],'stop.txt')",
            "$beat=[IO.Path]::Combine($v[3],'heartbeat.txt')",
            "$stopTime=$null",
            "try { while (-not $p.WaitForExit(1000)) { " ..
                "if ([IO.Directory]::Exists($stop) -and $null -eq $stopTime) { $stopTime=[DateTime]::UtcNow }; " ..
                "if (([DateTime]::UtcNow-[IO.Directory]::GetLastWriteTimeUtc($beat)).TotalSeconds -gt 150 " ..
                "-or ($stopTime -and ([DateTime]::UtcNow-$stopTime).TotalSeconds -gt 10)) { $p.Kill(); break } }; " ..
                "$p.WaitForExit(); exit $p.ExitCode } finally { if (-not $p.HasExited) { $p.Kill() }; $p.Dispose() }",
        })
        state.exited = true
        state.exitCode = tostring(code)
        if state.closed then LrFileUtils.delete(session) end
    end)
    LrTasks.startAsyncTask(function()
        while not state.closed and not state.exited do
            LrTasks.sleep(10)
            if not state.closed and not state.exited then heartbeat(session) end
        end
    end)
end

local function waitFor(state, path, timeout)
    local deadline = LrDate.currentTime() + timeout
    while LrFileUtils.exists(path) ~= "file" do
        if state.closed or state.broken then error("渲染会话已关闭，请重新打开浮窗。", 0) end
        if state.exited then
            error("渲染进程已退出 (" .. tostring(state.exitCode) .. ")。请重新打开浮窗。日志：" .. state.log, 0)
        end
        if LrDate.currentTime() >= deadline then return false end
        LrTasks.sleep(0.05)
    end
    return true
end

local function timedOut(session, state)
    state.broken = true
    directory(child(session, "stop.txt"))
    error("渲染进程响应超时，请重新打开浮窗。日志：" .. state.log, 0)
end

local function publish(inbox, bytes)
    -- Native Lua streams work on ASCII paths; move the complete payload atomically.
    if not inbox:find("[\128-\255]") then
        local staging = inbox .. ".tmp"
        local file = io.open(staging, "wb")
        if file then
            local wrote, writeError = file:write(bytes)
            local closed, closeError = file:close()
            if not wrote or not closed then
                LrFileUtils.delete(staging)
                error(tostring(writeError or closeError), 0)
            end
            local moved, moveError = LrFileUtils.move(staging, inbox)
            if not moved then
                LrFileUtils.delete(staging)
                error("无法提交渲染请求：" .. tostring(moveError), 0)
            end
            return
        end
    end
    -- LrC's folder APIs handle Unicode paths without the Windows ANSI code page.
    local payload = LrStringUtils.encodeBase64(bytes):gsub("%s", ""):gsub("%+", "-"):gsub("/", "_")
    local index = 1
    for pos = 1, #payload, 80 do
        directory(child(inbox, string.format("%04d_", index) .. payload:sub(pos, pos + 79)))
        index = index + 1
    end
    directory(child(inbox, "complete"))
end

function Worker.request(session, args, timeout)
    local state = sessions[session]
    if not state or state.closed or state.broken then error("请重新打开胶片模拟浮窗。", 0) end
    if not waitFor(state, child(session, "ready.txt"), 90) then timedOut(session, state) end
    if state.exited then error("渲染进程已退出，请重新打开浮窗。日志：" .. state.log, 0) end
    state.sequence = state.sequence + 1
    local id = string.format("%08d", state.sequence)
    local inbox = child(session, "request-" .. id .. ".job")
    local bytes = table.concat(args, "\0")
    if #bytes > 65536 then error("渲染请求过长。", 0) end
    publish(inbox, bytes)
    local response = child(session, "response-" .. id .. ".txt")
    if not waitFor(state, response, timeout) then timedOut(session, state) end
    local result = LrFileUtils.readFile(response)
    LrFileUtils.delete(response)
    if result:match("^ok%s*$") then return end
    local detail = result:match("^error\r?\n(.+)")
    if detail then error(detail .. "。日志：" .. state.log .. ".out", 0) end
    error("无效的渲染响应。日志：" .. state.log, 0)
end

function Worker.stop(session)
    local state = sessions[session]
    if state and not state.exited and not state.broken then
        state.broken = true
        directory(child(session, "stop.txt"))
    end
end

function Worker.close(session)
    local state = sessions[session]
    if not state then return end
    sessions[session] = nil
    state.closed = true
    if state.exited then LrFileUtils.delete(session)
    else directory(child(session, "stop.txt")) end
end

return Worker
