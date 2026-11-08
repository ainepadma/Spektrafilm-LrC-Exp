local LrDate = import "LrDate"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local Worker = require "WorkerSession"
local Json = require "Json"

local Render = {}
local child = LrPathUtils.child
local root = LrPathUtils.parent(_PLUGIN.path)
local runtime = child(root, ".runtime")
local jobs = child(runtime, "jobs")
local temp = child(runtime, "tmp")
local logs = child(runtime, "logs")
local python = child(child(child(root, ".venv"), "Scripts"), "python.exe")
local worker = child(child(root, "bridge"), "worker.py")

function Render.newSession()
    if LrFileUtils.exists(python) ~= "file" or LrFileUtils.exists(worker) ~= "file" then
        error("渲染环境未就绪。请先按项目 README 完成 Windows 环境安装。", 0)
    end
    for _, dir in ipairs { jobs, temp, logs } do
        local ok, reason = LrFileUtils.createAllDirectories(dir)
        if not ok then error("无法创建工作目录：" .. tostring(reason), 0) end
    end
    local base = child(jobs, string.format("session-%.0f", LrDate.currentTime() * 1000))
    while true do
        local session = LrFileUtils.chooseUniqueFileName(base)
        local ok, created = LrFileUtils.createAllDirectories(session)
        if not ok then error("无法创建工作目录：" .. tostring(created), 0) end
        if created then
            local log = LrFileUtils.chooseUniqueFileName(child(logs, LrPathUtils.leafName(session) .. ".log"))
            Worker.open(session, root, python, worker, log)
            return session
        end
    end
end

Render.closeSession = Worker.close
Render.stopSession = Worker.stop

function Render.profiles(session)
    local path = child(session, "profiles.tsv")
    Worker.request(session, { "profiles", "--output", path, "--details" }, 60)
    local lists = { film = {}, paper = {} }
    for line in LrFileUtils.readFile(path):gmatch("[^\r\n]+") do
        local kind,id,typ,channel,target,name,support=line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]+)\t([^\t]+)$")
        if lists[kind] then
            table.insert(lists[kind], {value=id,title=name,type=typ,channel=channel,targetPrint=target,support=support})
        end
    end
    if #lists.film == 0 or #lists.paper == 0 then error("引擎没有返回胶片或相纸列表。", 0) end
    return lists
end

function Render.input(photo, directory, width, height, space)
    if photo:getRawMetadata("fileFormat") == "VIDEO" then error("仅支持照片。", 0) end
    local settings = {
        LR_exportServiceProvider = "com.adobe.ag.export.file",
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = directory,
        LR_export_useSubfolder = false,
        LR_renamingTokensOn = false,
        LR_collisionHandling = "rename",
        LR_reimportExportedPhoto = false,
        LR_format = "TIFF",
        LR_export_bitDepth = 16,
        LR_export_colorSpace = space=="srgb" and "sRGB" or "ProPhotoRGB",
        LR_tiff_compressionMethod = "compressionMethod_None",
        LR_size_doConstrain = width ~= nil,
        LR_size_doNotEnlarge = true,
        LR_size_units = "pixels",
        LR_size_resizeType = "wh",
        LR_size_maxWidth = width,
        LR_size_maxHeight = height,
        LR_useWatermark = false,
        LR_outputSharpeningOn = false,
    }
    local export = LrExportSession { photosToExport = { photo }, exportSettings = settings }
    for _, rendition in export:renditions() do
        local ok, result = rendition:waitForRender()
        if not ok then error(tostring(result), 0) end
        -- Callers may delete this intermediate file after use.
        local actual = LrPathUtils.standardizePath(LrPathUtils.parent(result))
        if actual:lower() ~= LrPathUtils.standardizePath(directory):lower() then
            error("LrC 将中间图像写到了意外的位置：" .. result, 0)
        end
        return result
    end
    error("LrC 没有生成输入图像。", 0)
end

local optionFlags={
    inputSpace="input-space",outputSpace="output-space",quality="quality",bitDepth="bit-depth",
    longEdge="long-edge",collision="collision",gate="gate",markings="markings",frameNumber="frame-number",
    fog="fog",leak="leak",date="date",datePosition="date-position",dateSize="date-size",
    dateMargin="date-margin",dateBrightness="date-brightness",pairInput="pair-input",pairDirection="pair-direction",
    firstEv="first-ev",secondEv="second-ev",pairGap="pair-gap",firstScale="first-scale",secondScale="second-scale",
    firstX="first-x",firstY="first-y",secondX="second-x",secondY="second-y",protectedSource="protected-source",
    partnerSource="protected-source",
    pairFilm="pair-film",pairPaper="pair-paper",pairMode="pair-mode",frameFraction="frame-fraction",
    previewBox="preview-box",paperBorder="paper-border",paperLayout="paper-layout",paperMargin="paper-margin",paperColor="paper-color",
    instantFrame="instant-frame",instantPosition="instant-position",
    captionFont="caption-font",watermark="watermark",watermarkFont="watermark-font",
    watermarkColor="watermark-color",watermarkPosition="watermark-position",
    watermarkOpacity="watermark-opacity",watermarkSize="watermark-size",
}
function Render.film(session, input, output, film, paper, mode, recipe, printing, diagnosticsPath)
    local args = { "render", "--input", input, "--output", output, "--film", film, "--paper", paper }
    printing=printing or {inputSpace="prophoto"}
    if mode == "preview" or (printing.cineon and printing.displayProof) then args[#args + 1] = "--preview"
    elseif mode == "fast-color" then args[#args + 1] = "--fast-color"
    elseif mode and mode ~= "full" then error("未知渲染模式。", 0) end
    if recipe then
        args[#args+1]="--recipe"
        args[#args+1]=Json.encode(recipe)
    end
    if diagnosticsPath then
        args[#args+1]="--diagnostics"
        args[#args+1]=diagnosticsPath
    end
    if printing.pairRecipe then args[#args+1]="--pair-recipe"; args[#args+1]=Json.encode(printing.pairRecipe) end
    for key,flag in pairs(optionFlags) do
        if printing[key]~=nil then args[#args+1]="--"..flag; args[#args+1]=tostring(printing[key]) end
    end
    if printing.displayProof then args[#args+1]="--display-proof" end
    if printing.paperCaption and printing.paperCaption~="" then args[#args+1]="--paper-caption="..printing.paperCaption end
    if printing.watermark=="text" then args[#args+1]="--watermark-text="..printing.watermarkText end
    if printing.watermark=="png" then args[#args+1]="--watermark-png="..printing.watermarkPng end
    if printing.draft then args[#args+1]="--draft" end
    if printing.cineon then args[#args+1]="--cineon" end
    if printing.holes==false then args[#args+1]="--no-holes" end
    Worker.request(session, args, mode == "preview" and 300 or 1800)
    if LrFileUtils.exists(output) ~= "file" then error("引擎没有生成成片。", 0) end
end

return Render
