local LrStringUtils = import "LrStringUtils"
local LrTasks = import "LrTasks"

-- Only base64 crosses cmd.exe, including for paths containing %, ! and &.
-- Fixed PowerShell code receives UTF-8 fields as the array $v.
return function(fields, statements)
    local payload = LrStringUtils.encodeBase64(table.concat(fields, "\0")):gsub("%s", "")
    local decode = "$v=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" ..
                   payload .. "')).Split([char]0)"
    local script = decode .. "; " .. table.concat(statements, "; ")
    local command = 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command "' .. script .. '"'
    if #command >= 8191 then error("命令过长，请缩短项目或导出目录路径。", 0) end
    return LrTasks.execute(command)
end
