-- wikilink.lua
-- Cicla candidatos [[wiki]] con selección persistente.
-- Si no hay selección pero el cursor está dentro de [[...]], lo selecciona primero.

local micro  = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

local state = {
    candidates   = {},
    index        = 0,
    anchor_query = nil,
    vault_dir    = nil,
}

-- =========================
-- VAULT DIR
-- =========================

local function get_dir(bp)
    local path = bp.Buf.Path
    if path and path ~= "" then
        local dir = path:match("^(.*)/[^/]*$")
        if dir and dir ~= "" then return dir end
    end
    local f = io.popen("pwd 2>/dev/null")
    if f then
        local d = f:read("*l")
        f:close()
        if d and d ~= "" then return d end
    end
    return "."
end

-- =========================
-- FILE SEARCH
-- =========================

local function trim_md(s)
    return s:gsub("%.md$", "")
end

local function build_candidates(dir, query)
    local results = {}
    local cmd = string.format(
        'find %q -type f -name "*.md" -not -path "*/.*" 2>/dev/null | sort',
        dir
    )
    local p = io.popen(cmd)
    if not p then return results end

    local q      = query:lower()
    local prefix = dir:gsub("/$", "") .. "/"

    for line in p:lines() do
        if line ~= "" then
            local rel = line
            if rel:sub(1, #prefix) == prefix then
                rel = rel:sub(#prefix + 1)
            end
            rel = trim_md(rel)
            if q == "" or rel:lower():find(q, 1, true) then
                table.insert(results, rel)
            end
        end
    end
    p:close()
    return results
end

-- =========================
-- AUTO-SELECT [[...]] bajo el cursor
-- Devuelve (sx, sy, ex, ey) de todo el [[...]], o nil si no hay ninguno.
-- =========================

local function find_wikilink_at_cursor(bp)
    local c    = bp.Cursor
    local cx   = c.Loc.X
    local cy   = c.Loc.Y
    local line = bp.Buf:Line(cy)

    -- Busca todos los [[...]] en la línea y comprueba si el cursor cae dentro
    local search_from = 1
    while true do
        local s, e = line:find("%[%[.-%]%]", search_from)
        if not s then break end
        -- s-1 y e son índices Lua (1-based); cx es 0-based
        -- el cursor está "dentro" si cx >= s-1 y cx <= e
        if cx >= (s - 1) and cx <= e then
            return s - 1, cy, e, cy   -- 0-based para micro
        end
        search_from = e + 1
    end
    return nil
end

-- =========================
-- SELECTION
-- =========================

local function get_selection(bp)
    local c   = bp.Cursor
    local sel = c.CurSelection
    local a, b = sel[1], sel[2]

    local ax, ay = a.X, a.Y
    local bx, by = b.X, b.Y

    if ax == bx and ay == by then
        return nil, nil, nil, nil, nil
    end

    local sx, sy, ex, ey
    if ay < by or (ay == by and ax <= bx) then
        sx, sy, ex, ey = ax, ay, bx, by
    else
        sx, sy, ex, ey = bx, by, ax, ay
    end

    local buf   = bp.Buf
    local lines = {}
    for y = sy, ey do
        local l = buf:Line(y)
        if y == sy and y == ey then
            l = l:sub(sx + 1, ex)
        elseif y == sy then
            l = l:sub(sx + 1)
        elseif y == ey then
            l = l:sub(1, ex)
        end
        table.insert(lines, l)
    end

    return table.concat(lines, "\n"), sx, sy, ex, ey
end

local function extract_inner(text)
    text = text:gsub("^%[%[", "")
    text = text:gsub("%]%]$", "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function is_expanded_candidate(text)
    for _, c in ipairs(state.candidates) do
        if c == text then return true end
    end
    return false
end

-- =========================
-- REPLACE + RESELECT
-- =========================

local function replace_and_reselect(bp, sx, sy, ex, ey, value)
    local c = bp.Cursor
    bp.Buf:Replace(buffer.Loc(sx, sy), buffer.Loc(ex, ey), value)
    c.CurSelection[1] = buffer.Loc(sx, sy)
    c.CurSelection[2] = buffer.Loc(sx + #value, sy)
    c.Loc = buffer.Loc(sx + #value, sy)
end

-- =========================
-- COMMAND
-- =========================

function WikilinkCycle(bp)

    local sel, sx, sy, ex, ey = get_selection(bp)

    -- Sin selección: intenta seleccionar el [[...]] bajo el cursor
    if not sel then
        local fsx, fsy, fex, fey = find_wikilink_at_cursor(bp)
        if fsx == nil then
            micro.InfoBar():Message("wikilink: cursor no está dentro de [[...]]")
            return
        end
        sx, sy, ex, ey = fsx, fsy, fex, fey
        -- Construye la selección visualmente para que el usuario la vea
        local c = bp.Cursor
        c.CurSelection[1] = buffer.Loc(sx, sy)
        c.CurSelection[2] = buffer.Loc(ex, ey)
        c.Loc = buffer.Loc(ex, ey)
        -- Lee el texto ahora que tenemos las coordenadas
        local line = bp.Buf:Line(sy)
        sel = line:sub(sx + 1, ex)
    end

    local inner = extract_inner(sel)

    if not is_expanded_candidate(inner) then
        state.anchor_query = inner
        state.index        = 0
        local dir          = get_dir(bp)
        state.vault_dir    = dir
        state.candidates   = build_candidates(dir, inner)
    end

    if #state.candidates == 0 then
        micro.InfoBar():Message('wikilink: sin coincidencias para "' .. state.anchor_query .. '"')
        return
    end

    state.index = (state.index % #state.candidates) + 1

    local candidate   = state.candidates[state.index]
    local replacement = "[[" .. candidate .. "]]"

    replace_and_reselect(bp, sx, sy, ex, ey, replacement)

    micro.InfoBar():Message(
        string.format("wikilink [%d/%d]: %s", state.index, #state.candidates, candidate)
    )
end

-- =========================
-- INIT
-- =========================

function init()
    config.MakeCommand("wikilink", WikilinkCycle, config.NoComplete)
    -- ~/.config/micro/bindings.json:
    -- "Alt-w": "lua:wikilink.WikilinkCycle"
end
