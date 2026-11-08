local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"

return function(parent, prefix)
    local base = LrPathUtils.child(parent, prefix)
    while true do
        local path = LrFileUtils.chooseUniqueFileName(base)
        local ok, created = LrFileUtils.createAllDirectories(path)
        if not ok then error("无法创建工作目录：" .. tostring(created),0) end
        if created then return path end
    end
end
