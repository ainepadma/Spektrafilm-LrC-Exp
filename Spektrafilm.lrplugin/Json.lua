-- Small UTF-8 JSON codec for project settings and the Python worker protocol.
local Json = {}
local escaped = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
                  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
Json.null = {}

local function quote(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        return escaped[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

function Json.encode(value)
    local kind = type(value)
    if value == nil or value == Json.null then return "null" end
    if kind == "string" then return quote(value) end
    if kind == "boolean" then return tostring(value) end
    if kind == "number" then
        assert(value == value and math.abs(value) < math.huge, "Invalid JSON number")
        return string.format("%.17g", value)
    end
    assert(kind == "table", "Unsupported JSON value: " .. kind)
    local parts = {}
    if value[1] ~= nil then
        for i, item in ipairs(value) do parts[i] = Json.encode(item) end
        for k in pairs(value) do
            assert(type(k) == "number" and k >= 1 and k <= #parts and k % 1 == 0, "Invalid array key")
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, item in pairs(value) do
        assert(type(k) == "string", "Invalid JSON object key")
        parts[#parts + 1] = quote(k) .. ":" .. Json.encode(item)
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

local function utf8(n)
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192 + math.floor(n/64), 128 + n%64) end
    if n < 65536 then return string.char(224 + math.floor(n/4096), 128 + math.floor(n/64)%64, 128 + n%64) end
    return string.char(240 + math.floor(n/262144), 128 + math.floor(n/4096)%64, 128 + math.floor(n/64)%64, 128 + n%64)
end

function Json.decode(s)
    local pos = 1
    local function spaces()
        local _, last = s:find("^[ \t\r\n]*", pos)
        pos = last + 1
    end
    local function take(c)
        if s:sub(pos, pos) ~= c then return false end
        pos = pos + 1
        return true
    end
    local codes = { b="\b", f="\f", n="\n", r="\r", t="\t", ['"']='"', ['/']='/', ['\\']='\\' }
    local function hex4()
        local token = s:sub(pos,pos+3)
        assert(token:match("^%x%x%x%x$"), "Invalid Unicode escape")
        pos = pos + 4
        return tonumber(token, 16)
    end
    local function readString()
        assert(take('"'), "Expected JSON string")
        local parts = {}
        while true do
            local nextSpecial = assert(s:find('[%z\1-\31\\"]', pos), "Unterminated JSON string")
            parts[#parts+1] = s:sub(pos, nextSpecial-1)
            pos = nextSpecial
            if take('"') then return table.concat(parts) end
            assert(take('\\'), "Invalid control character")
            local c = s:sub(pos,pos)
            pos = pos + 1
            if c == "u" then
                local n = hex4()
                if n >= 0xd800 and n <= 0xdbff then
                    assert(take('\\') and take("u"), "Missing low surrogate")
                    local low = hex4()
                    assert(low >= 0xdc00 and low <= 0xdfff, "Invalid low surrogate")
                    n = 65536 + (n - 0xd800)*1024 + low - 0xdc00
                end
                assert(n < 0xd800 or n > 0xdfff, "Unpaired surrogate")
                parts[#parts+1] = utf8(n)
            else
                parts[#parts+1] = assert(codes[c], "Invalid JSON escape")
            end
        end
    end
    local function parse(depth)
        assert(depth <= 50, "JSON nested too deeply")
        spaces()
        local first = s:sub(pos,pos)
        if first == '"' then return readString() end
        if first == "{" or first == "[" then
            pos = pos + 1
            local object = first == "{"
            local close = object and "}" or "]"
            local result = {}
            spaces()
            if take(close) then return result end
            repeat
                spaces()
                local k = #result + 1
                if object then
                    k = readString()
                    spaces()
                    assert(take(":"), "Expected colon")
                end
                result[k] = parse(depth+1)
                spaces()
            until not take(",")
            assert(take(close), "Missing JSON delimiter")
            return result
        end
        for token, value in pairs({ ["true"]=true, ["false"]=false, ["null"]=Json.null }) do
            if s:sub(pos,pos+#token-1) == token then pos=pos+#token; return value end
        end
        local number = s:match("^(-?%d+%.?%d*[eE]?[+-]?%d*)",pos)
        assert(number and tonumber(number), "Expected JSON value")
        pos = pos + #number
        return tonumber(number)
    end
    local value = parse(0)
    spaces()
    assert(pos == #s+1, "Extra JSON input")
    return value
end

function Json.clone(value)
    if type(value) ~= "table" or value == Json.null then return value end
    local copy = {}
    for k,v in pairs(value) do copy[k] = Json.clone(v) end
    return copy
end

return Json
