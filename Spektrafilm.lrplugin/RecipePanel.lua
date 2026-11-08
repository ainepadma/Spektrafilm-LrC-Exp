local LrFileUtils = import "LrFileUtils"
local Json = require "Json"
local Panel = {}

local function item(id, title) return { value = id, title = title } end
local function find(rows, id)
    for _, row in ipairs(rows) do if row.value == id then return row end end
end

local categories = {
    item("all", "所有胶片"), item("color-negative", "彩色负片"), item("color-positive", "彩色正片"),
    item("bw-negative", "黑白负片"), item("bw-positive", "黑白正片"),
}

local function category(row) return (row.channel or "color") .. "-" .. (row.type or "negative") end

function Panel.categories(lists)
    local available, rows = {}, { categories[1] }
    for _, film in ipairs(lists.film) do available[category(film)] = true end
    for i = 2, #categories do
        if available[categories[i].value] then rows[#rows+1] = categories[i] end
    end
    return rows
end

-- Rebuild dependent popup lists under the caller's observer guard. A direct
-- scan still carries a valid print ID for the engine's parameter constructor.
function Panel.match(p, lists, options, preferPaper)
    local films = {}
    for _, row in ipairs(lists.film) do
        if p.category == "all" or category(row) == p.category then films[#films+1] = row end
    end
    if #films == 0 then films = lists.film; p.category = "all" end
    local previousFilm = find(films, p.film)
    local film = previousFilm or films[1]
    local papers = {}
    for _, paper in ipairs(lists.paper) do
        if (paper.channel or "color") == (film.channel or "color") then papers[#papers+1] = paper end
    end
    local recommended = find(papers, film.targetPrint or film.target_print)
    local paper = ((preferPaper or not previousFilm) and recommended) or find(papers, p.paper)
                  or recommended or papers[1] or lists.paper[1]
    p.filmItems, p.film, p.paperItems, p.paper = films, film.value, papers, paper.value
    p.forcedScan = film.type == "positive" or #papers == 0
    p.directScan = p.forcedScan or options.scan == true
    p.stockHint = p.forcedScan and (film.type == "positive" and "正片直接扫描" or "无兼容相纸，使用胶片直扫")
        or (recommended and ("推荐相纸 · " .. recommended.title) or "")
end

-- Also resolve saved recipes during a batch. A library update can remove a
-- recommended print, and a stock without compatible media must use direct scan.
function Panel.forRender(recipe, lists)
    local result = Json.clone(recipe)
    result.options = result.options or {}
    local match = {film=result.film, paper=result.paper, category="all"}
    Panel.match(match, lists, result.options, false)
    result.film, result.paper = match.film, match.paper
    if match.forcedScan then result.options.scan = true end
    return result
end

function Panel.readMeasurements(path)
    if LrFileUtils.exists(path) ~= "file" then return nil end
    local result = {}
    for line in LrFileUtils.readFile(path):gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)\t(.+)$")
        if key then result[key] = tonumber(value) end
    end
    return result
end

return Panel
