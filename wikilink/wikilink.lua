-- wikilink.lua (modo selección + rotación + anchor query fijo)

local micro  = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

-- =========================
-- STATE GLOBAL
-- =========================

local state = {
    candidates = {},
    index = 0,
    last_dir = ".",
    anchor_query = nil,
    anchor_range = nil,
}

-- =========================
-- FILE CACHE
-- =========================

local function trim_md(path)
    return path:gsub("%.md$", "")
end

local function build_candidates(dir, query)
    local results = {}

    local cmd = 'find "' .. dir .. '" -type f -name "*.md" -not -path "*/.*" 2>/dev/null'
    local p = io.popen(cmd)
    if not p then return results end

    local q = query:lower()

    for line in p:lines() do
        if line and line ~= "" then
            local rel = line

            if rel:sub(1, #dir) == dir then
                rel = rel:sub(#dir + 2)
            end

            rel = trim_md(rel)

            if q == "" or rel:lower():sub(1, #q) == q then
                table.insert(results, rel)
            end
        end
    end

    p:close()
    table.sort(results)
    return results
end

-- =========================
-- SELECTION
-- =========================

local function get_selection(bp)
    local c = bp.Cursor
    local sel = c.CurSelection

    local a = sel[1]
    local b = sel[2]

    if a.X == b.X and a.Y == b.Y then
        return nil, nil, nil
    end

    local buf = bp.Buf

    local first = math.min(a.Y, b.Y)
    local last  = math.max(a.Y, b.Y)

    local lines = {}
    for y = first, last do
        table.insert(lines, buf:Line(y))
    end

    return table.concat(lines, "\n"), first, last
end

-- =========================
-- CLEAN QUERY
-- =========================

local function extract_query(text)
    text = text:gsub("^%[%[", "")
    text = text:gsub("%]%]$", "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

-- =========================
-- REPLACE
-- =========================

local function select_wikilink(bp, line)
    local text = bp.Buf:Line(line)

    local s, e = text:find("%[%[[^%]]*%]%]")

    if not s or not e then
        return
    end

    local start = buffer.Loc(s - 1, line)
    local fin   = buffer.Loc(e, line)

    bp.Cursor.CurSelection = {start, fin}
    bp.Cursor.Loc = fin
end

local function replace_selection(bp, first, last, value)
    local buf = bp.Buf

    local start = buffer.Loc(0, first)
    local endl  = buffer.Loc(#buf:Line(last), last)

    buf:Replace(start, endl, value)

    select_wikilink(bp, first)
end

-- =========================
-- MAIN
-- =========================

function WikilinkCycle(bp)

    local dir = "."
    local sel, first, last = get_selection(bp)

    if not sel then
        micro.InfoBar():Message("Selecciona [[texto]] primero")
        return
    end

    local query = extract_query(sel)

    local range_key = first .. ":" .. last

    if state.anchor_query == nil or state.anchor_range ~= range_key then
        state.anchor_query = query
        state.anchor_range = range_key

        state.candidates = {}
        state.index = 0
    end

    local active_query = state.anchor_query

    -- rebuild candidates si necesario
    if state.last_dir ~= dir or #state.candidates == 0 then
        state.candidates = build_candidates(dir, active_query)
        state.index = 0
        state.last_dir = dir
    end

    if #state.candidates == 0 then
        micro.InfoBar():Message("Sin coincidencias: " .. active_query)
        return
    end

    -- cycle
    state.index = state.index + 1
    if state.index > #state.candidates then
        state.index = 1
    end

    local replacement = "[[" .. state.candidates[state.index] .. "]]"

    replace_selection(bp, first, last, replacement)

    micro.InfoBar():Message(
        "Wiki → " .. state.index .. "/" .. #state.candidates ..
        " : " .. state.candidates[state.index]
    )
end

-- =========================
-- INIT
-- =========================

function init()
    config.MakeCommand("wikilink", WikilinkCycle, config.NoComplete)
end
