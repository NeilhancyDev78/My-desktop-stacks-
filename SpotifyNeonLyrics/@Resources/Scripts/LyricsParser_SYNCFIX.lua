-- IMPORTANT:
-- Save this file as UTF-8 (NOT UTF-16) so Rainmeter Lua can run it.
-- Japanese is supported via UTF-8 content + JP-capable fonts (Yu Gothic UI / Noto Sans JP).

lyrics = {}
currentIndex = 1

-- Track keying / fetch state
currentKey = ""
fetchInProgress = false
queuedKey = ""

-- ========= helpers =========
local function trim(s)
    if not s then return "" end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%s+", " ")
    return s
end

-- Keep Unicode bytes; only normalize spacing + ASCII case
local function normKey(s)
    s = trim(s)
    -- lower() only affects ASCII; safe for JP
    s = s:lower()
    return s
end

local function toMsFromSecondsMaybe(v)
    v = tonumber(v) or 0
    if v <= 0 then return 0 end
    -- If it already looks like ms, keep it
    if v > 100000 then return math.floor(v) end
    -- Most WebNowPlaying values are seconds (float)
    return math.floor(v * 1000 + 0.5)
end

local function parseTimeTagToMs(tag)
    if not tag or tag == "" then return 0 end
    local m, s, frac = tag:match("^(%d+):(%d+)%.?(%d*)$")
    if not m then return 0 end
    local ms = (tonumber(m) * 60 + tonumber(s)) * 1000
    if frac and frac ~= "" then
        if #frac == 1 then
            ms = ms + tonumber(frac) * 100
        elseif #frac == 2 then
            ms = ms + tonumber(frac) * 10
        else
            ms = ms + tonumber(frac:sub(1,3))
        end
    end
    return ms
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return "" end
    local s = f:read("*all") or ""
    f:close()
    return s
end

local function json_unescape(s)
    if not s or s == "" then return "" end
    s = s:gsub('\\"', '"')
    s = s:gsub("\\\\", "\\")
    s = s:gsub("\\/", "/")
    s = s:gsub("\\b", "\b")
    s = s:gsub("\\f", "\f")
    s = s:gsub("\\r", "\r")
    s = s:gsub("\\t", "\t")
    s = s:gsub("\\n", "\n")

    -- \uXXXX (BMP) — includes Japanese
    s = s:gsub("\\u(%x%x%x%x)", function(hex)
        local code = tonumber(hex, 16)
        if not code then return "" end
        if code <= 0x7F then
            return string.char(code)
        elseif code <= 0x7FF then
            return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
        else
            return string.char(
                0xE0 + math.floor(code / 0x1000),
                0x80 + (math.floor(code / 0x40) % 0x40),
                0x80 + (code % 0x40)
            )
        end
    end)
    return s
end

-- Robustly extract a JSON string value for a key (handles embedded quotes via escapes)
local function json_get_string(json, key)
    if not json or json == "" then return nil end
    local anchor = '"' .. key .. '"'
    local a = json:find(anchor, 1, true)
    if not a then return nil end
    local c = json:find(":", a + #anchor, true)
    if not c then return nil end
    local i = c + 1
    -- skip whitespace
    while i <= #json do
        local ch = json:sub(i,i)
        if ch ~= " " and ch ~= "\t" and ch ~= "\r" and ch ~= "\n" then break end
        i = i + 1
    end
    local first = json:sub(i,i)
    if first == "n" and json:sub(i,i+3) == "null" then return nil end
    if first ~= '"' then return nil end
    i = i + 1

    local out = {}
    while i <= #json do
        local ch = json:sub(i,i)
        if ch == '"' then
            break
        elseif ch == "\\" then
            -- keep escape sequence intact for json_unescape()
            out[#out+1] = "\\"
            i = i + 1
            if i <= #json then
                out[#out+1] = json:sub(i,i)
            end
        else
            out[#out+1] = ch
        end
        i = i + 1
    end
    return table.concat(out)
end

local function parseLrc(lrc)
    local out = {}
    if not lrc or lrc == "" then return out end

    for line in lrc:gmatch("[^\r\n]+") do
        -- ignore metadata tags like [ar:...]
        if not line:match("^%s*%[%a%a%a?:") then
            local text = trim((line:gsub("%b[]", "")))
            local found = false
            for tag in line:gmatch("%[(%d+:%d+%.?%d*)%]") do
                found = true
                table.insert(out, { t = parseTimeTagToMs(tag), text = text })
            end
            -- If there are no time tags, skip (synced parser)
        end
    end

    table.sort(out, function(a,b) return a.t < b.t end)
    return out
end

local function parsePlainApprox(plain, durationMs)
    -- Fallback: approximate progression for unsynced lyrics
    local out = {}
    if not plain or plain == "" then return out end
    local lines = {}
    for ln in plain:gmatch("[^\r\n]+") do
        ln = trim(ln)
        if ln ~= "" then lines[#lines+1] = ln end
    end
    if #lines == 0 then return out end
    durationMs = math.max(durationMs or 0, 1)
    for i, ln in ipairs(lines) do
        local t = math.floor((i-1) * (durationMs / #lines))
        out[#out+1] = { t = t, text = ln }
    end
    return out
end

local function findIndexByTime(ms)
    if #lyrics == 0 then return 1 end
    local idx = 1
    for i = 1, #lyrics do
        if lyrics[i].t <= ms then idx = i else break end
    end
    return idx
end

local function setLyricVars()
    local prev = (lyrics[currentIndex - 1] and lyrics[currentIndex - 1].text) or ""
    local cur  = (lyrics[currentIndex] and lyrics[currentIndex].text) or ""
    local next = (lyrics[currentIndex + 1] and lyrics[currentIndex + 1].text) or ""

    prev = prev:gsub('"', '\\"')
    cur  = cur:gsub('"', '\\"')
    next = next:gsub('"', '\\"')

    SKIN:Bang('!SetVariable LyricPrev "' .. prev .. '"')
    SKIN:Bang('!SetVariable LyricCur "'  .. cur  .. '"')
    SKIN:Bang('!SetVariable LyricNext "' .. next .. '"')
end

local function getNowPlaying()
    local titleM  = SKIN:GetMeasure("MeasureTitle")
    local artistM = SKIN:GetMeasure("MeasureArtist")
    local posM    = SKIN:GetMeasure("MeasurePosition")
    local durM    = SKIN:GetMeasure("MeasureDuration")

    local title  = titleM and titleM:GetStringValue() or ""
    local artist = artistM and artistM:GetStringValue() or ""

    -- Prefer numeric values for accuracy (usually seconds)
    local posMs = 0
    if posM then
        local v = posM:GetValue()
        if v and v > 0 then
            posMs = toMsFromSecondsMaybe(v)
        else
            posMs = parseTimeTagToMs(posM:GetStringValue() or "0:00")
        end
    end

    local durMs = 0
    if durM then
        local v = durM:GetValue()
        if v and v > 0 then
            durMs = toMsFromSecondsMaybe(v)
        else
            -- if duration comes as mm:ss string
            durMs = parseTimeTagToMs(durM:GetStringValue() or "0:00")
        end
    end

    local offset = tonumber(SKIN:GetVariable("LyricOffsetMs", "0")) or 0
    posMs = math.max(0, posMs + offset)

    return title, artist, posMs, durMs
end

local function startFetchForCurrentSong()
    fetchInProgress = true
    SKIN:Bang('!CommandMeasure MeasureLyricsFetch "Run"')
end

-- ========= Rainmeter hooks =========

function Initialize()
    lyrics = {}
    currentIndex = 1
    currentKey = ""
    fetchInProgress = false
    queuedKey = ""
    setLyricVars()
end

function Update()
    local title, artist, posMs, durMs = getNowPlaying()
    local key = normKey(artist) .. "|" .. normKey(title)

    -- Track changed?
    if key ~= currentKey then
        currentKey = key
        lyrics = {}
        currentIndex = 1
        setLyricVars()

        if normKey(title) ~= "" and normKey(artist) ~= "" then
            if fetchInProgress then
                -- queue newest key; we'll fetch once current finishes
                queuedKey = key
            else
                queuedKey = ""
                startFetchForCurrentSong()
            end
        end
        return 0
    end

    -- Normal sync step
    currentIndex = findIndexByTime(posMs)
    setLyricVars()
    return 0
end

-- Called from MeasureLyricsFetch FinishAction (race-proof)
function OnFetchDone()
    -- Fetch finished. Parse whatever is in the cache file.
    fetchInProgress = false

    local resources = SKIN:GetVariable("@") or ""
    local json = readFile(resources .. "Cache\\lrclib.json")

    -- Try synced first
    local syncedEsc = json_get_string(json, "syncedLyrics")
    local plainEsc  = json_get_string(json, "plainLyrics")

    local lrc = syncedEsc and json_unescape(syncedEsc) or ""
    if lrc ~= "" then
        lyrics = parseLrc(lrc)
    else
        local title, artist, posMs, durMs = getNowPlaying()
        local plain = plainEsc and json_unescape(plainEsc) or ""
        lyrics = parsePlainApprox(plain, durMs)
    end

    local _, _, posMs, _ = getNowPlaying()
    currentIndex = findIndexByTime(posMs)
    setLyricVars()

    -- If user switched tracks while we were fetching, fetch again now
    if queuedKey ~= "" and queuedKey ~= currentKey then
        -- currentKey already updated in Update; just start new fetch
        queuedKey = ""
        startFetchForCurrentSong()
    end
end
