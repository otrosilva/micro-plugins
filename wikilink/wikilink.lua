-- wikilink.lua
-- Cicla candidatos [[wiki]] con selección persistente.
--
-- Comandos:
--   :wikilink      → cicla archivos .md que coincidan con el texto en [[...]]
--   :wikilinkopen  → abre el archivo referenciado en [[...]] en nueva pestaña
--                    (lo crea si no existe)
--
-- Bindear en ~/.config/micro/bindings.json:
--   {
--       "Alt-w": "lua:wikilink.WikilinkCycle",
--       "Alt-e": "lua:wikilink.WikilinkOpen"
--   }

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
-- FIND [[...]] UNDER CURSOR
-- =========================

local function find_wikilink_at_cursor(bp)
    local c    = bp.Cursor
    local cx   = c.Loc.X
    local cy   = c.Loc.Y
    local line = bp.Buf:Line(cy)

    local search_from = 1
    while true do
        local s, e = line:find("%[%[.-%]%]", search_from)
        if not s then break end
        if cx >= (s - 1) and cx <= e then
            return s - 1, cy, e, cy
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
-- RESOLVE LINK → PATH ABSOLUTO
-- Añade .md si no tiene extensión, resuelve relativo al vault dir.
-- =========================

local function resolve_path(bp, link)
    local dir  = get_dir(bp)
    -- Si el link no tiene extensión, asume .md
    local path = link
    if not path:match("%.[^/]+$") then
        path = path .. ".md"
    end
    -- Si no es absoluto, lo hace relativo al vault dir
    if path:sub(1, 1) ~= "/" then
        path = dir .. "/" .. path
    end
    return path
end

-- =========================
-- COMMAND: WikilinkCycle (Alt-W)
-- =========================

function WikilinkCycle(bp)

    local sel, sx, sy, ex, ey = get_selection(bp)

    if not sel then
        local fsx, fsy, fex, fey = find_wikilink_at_cursor(bp)
        if fsx == nil then
            micro.InfoBar():Message("wikilink: cursor no está dentro de [[...]]")
            return
        end
        sx, sy, ex, ey = fsx, fsy, fex, fey
        local c = bp.Cursor
        c.CurSelection[1] = buffer.Loc(sx, sy)
        c.CurSelection[2] = buffer.Loc(ex, ey)
        c.Loc = buffer.Loc(ex, ey)
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
        -- Si el enlace está vacío [[]], inserta la fecha de hoy como primera opción
        if inner == "" then
            local f = io.popen("date +%Y-%m-%d 2>/dev/null")
            if f then
                local today = f:read("*l")
                f:close()
                if today and today ~= "" then
                    table.insert(state.candidates, 1, today)
                end
            end
        end
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
-- COMMAND: WikilinkOpen (Alt-E)
-- Abre en nueva pestaña el archivo referenciado por [[...]] bajo cursor
-- o selección. Lo crea si no existe.
-- =========================

function WikilinkOpen(bp)

    -- Obtiene el texto del enlace: primero selección, luego bajo cursor
    local sel, _, _, _, _ = get_selection(bp)

    if not sel then
        local fsx, fsy, fex, fey = find_wikilink_at_cursor(bp)
        if fsx == nil then
            micro.InfoBar():Message("wikilink: cursor no está dentro de [[...]]")
            return
        end
        local line = bp.Buf:Line(fsy)
        sel = line:sub(fsx + 1, fex)
    end

    local inner = extract_inner(sel)

    if inner == "" then
        micro.InfoBar():Message("wikilink: el enlace está vacío")
        return
    end

    local full_path = resolve_path(bp, inner)

    -- Crea el archivo si no existe (touch equivalente)
    local f = io.open(full_path, "r")
    if f then
        f:close()
    else
        local nf = io.open(full_path, "w")
        if nf then
            nf:close()
        else
            micro.InfoBar():Message("wikilink: no se pudo crear " .. full_path)
            return
        end
    end

    -- Abre en nueva pestaña usando el comando interno :tab
    bp:NewTabCmd({full_path})

    micro.InfoBar():Message("wikilink: abierto → " .. full_path)
end

-- =========================
-- INIT
-- =========================

function init()
    config.MakeCommand("wikilink", WikilinkCycle, config.NoComplete)
    config.MakeCommand("wikilinkopen", WikilinkOpen, config.NoComplete)
end
