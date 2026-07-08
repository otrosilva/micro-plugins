-- wikilink.lua
-- Cicla candidatos [[wiki]] con selección persistente.
--
-- Comandos:
--   :wikilink      → cicla archivos .md que coincidan con el texto en [[...]]
--                    Si el contenido empieza con #, busca headings en el archivo actual.
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

-- =========================
-- CONFIGURACIÓN
-- =========================

local EMPTY_LINK_DEFAULT = "%Y-%m-%d"

-- =========================
-- STATE
-- =========================

local state = {
    candidates   = {},
    index        = 0,
    anchor_query = nil,
    vault_dir    = nil,
}

-- =========================
-- UTF-8: bytes → runas
-- =========================

local function bytes_to_runes(s, byte_offset)
    local runes = 0
    local i = 1
    if byte_offset > #s then byte_offset = #s end
    while i <= byte_offset do
        local b = s:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b < 0xE0 then
            i = i + 2
        elseif b < 0xF0 then
            i = i + 3
        else
            i = i + 4
        end
        runes = runes + 1
    end
    return runes
end

local function rune_to_byte(s, rune_count)
    local i = 1
    local r = 0
    while r < rune_count and i <= #s do
        local b = s:byte(i)
        if b < 0x80 then i = i + 1
        elseif b < 0xE0 then i = i + 2
        elseif b < 0xF0 then i = i + 3
        else i = i + 4 end
        r = r + 1
    end
    return i - 1  -- byte offset 0-based del último byte leído
end

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
-- FILE SEARCH (externa)
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
-- HEADING SEARCH (interna)
-- Busca headings en el buffer actual que coincidan con el query.
-- Devuelve candidatos como "#Título" (sin espacios entre # y título).
-- =========================

local function heading_title(line)
    local _, title = line:match("^(#+)%s+(.+)$")
    if title then
        -- Recortar espacio final accidental (ej. "# contraseñas ")
        -- para que coincida exactamente con el texto generado en [[#...]]
        title = title:gsub("%s+$", "")
    end
    return title
end

local function build_internal_candidates(bp, query)
    local results = {}
    local buf     = bp.Buf
    local q       = query:lower()
    local numLines = buf:LinesNum()

    for i = 0, numLines - 1 do
        local line  = buf:Line(i)
        local title = heading_title(line)
        if title then
            if q == "" or title:lower():find(q, 1, true) then
                table.insert(results, "#" .. title)
            end
        end
    end
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

        local s_rune = bytes_to_runes(line, s - 1)
        local e_rune = bytes_to_runes(line, e + 1)

        if cx >= s_rune and cx <= e_rune then
            return s_rune, cy, e_rune, cy
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

    local line    = bp.Buf:Line(sy)
    local b_start = rune_to_byte(line, sx) + 1
    local b_end   = rune_to_byte(line, ex)
    local sel_text = line:sub(b_start, b_end)

    return sel_text, sx, sy, ex, ey
end

local function extract_inner(text)
    text = text:gsub("^%[+", "")
    text = text:gsub("%]+$", "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function is_expanded_candidate(text)
    -- Ignorar alias (|...) al comparar con candidatos
    local clean = text:match("^([^|]+)") or text
    for _, c in ipairs(state.candidates) do
        if c == clean then return true end
    end
    return false
end

-- =========================
-- REPLACE + RESELECT
-- =========================

local function replace_and_reselect(bp, sx, sy, ex, ey, value)
    local c = bp.Cursor
    bp.Buf:Replace(buffer.Loc(sx, sy), buffer.Loc(ex, ey), value)
    local value_runes = bytes_to_runes(value, #value)
    c.CurSelection[1] = buffer.Loc(sx, sy)
    c.CurSelection[2] = buffer.Loc(sx + value_runes, sy)
    c.Loc = buffer.Loc(sx + value_runes, sy)
end

-- =========================
-- RESOLVE LINK → PATH ABSOLUTO
-- =========================

local function resolve_path(bp, link)
    local dir  = get_dir(bp)
    local path = link
    if not path:match("%.[^/]+$") then
        path = path .. ".md"
    end
    if path:sub(1, 1) ~= "/" then
        path = dir .. "/" .. path
    end
    return path
end

-- =========================
-- COMMAND: WikilinkCycle
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
        local line    = bp.Buf:Line(sy)
        local b_start = rune_to_byte(line, sx) + 1
        local b_end   = rune_to_byte(line, ex - 1)
        sel = line:sub(b_start, b_end)
    end

    local inner = extract_inner(sel)

    if not is_expanded_candidate(inner) then
        state.anchor_query = inner
        state.index        = 0

        -- Bifurcación: # al inicio → búsqueda interna de headings
        if inner:sub(1, 1) == "#" then
            local query      = inner:sub(2)  -- query sin el # inicial
            state.candidates = build_internal_candidates(bp, query)
            state.vault_dir  = nil
        else
            local dir        = get_dir(bp)
            state.vault_dir  = dir
            state.candidates = build_candidates(dir, inner)

            -- Sugerencia de fecha/nombre para [[]] vacío
            if inner == "" and EMPTY_LINK_DEFAULT ~= nil then
                local suggestion
                if EMPTY_LINK_DEFAULT:find("%%") then
                    local f = io.popen("date +'" .. EMPTY_LINK_DEFAULT .. "' 2>/dev/null")
                    if f then
                        suggestion = f:read("*l")
                        f:close()
                    end
                else
                    suggestion = EMPTY_LINK_DEFAULT
                end
                if suggestion and suggestion ~= "" then
                    table.insert(state.candidates, 1, suggestion)
                end
            end
        end
    end

    if #state.candidates == 0 then
        local scope = state.anchor_query:sub(1,1) == "#" and "headings" or "archivos"
        micro.InfoBar():Message('wikilink: sin ' .. scope .. ' para "' .. state.anchor_query .. '"')
        return
    end

    state.index = (state.index % #state.candidates) + 1

    local candidate = state.candidates[state.index]
    local replacement
    -- Si el candidato tiene subdirectorio, agregar alias con solo el nombre final
    local basename = candidate:match("([^/]+)$")
    if basename and basename ~= candidate then
        replacement = "[[" .. candidate .. "|" .. basename .. "]]"
    else
        replacement = "[[" .. candidate .. "]]"
    end

    replace_and_reselect(bp, sx, sy, ex, ey, replacement)

    local scope = candidate:sub(1,1) == "#" and "heading" or "archivo"
    micro.InfoBar():Message(
        string.format("wikilink [%d/%d] %s: %s", state.index, #state.candidates, scope, candidate)
    )
end

-- =========================
-- COMMAND: WikilinkOpen
-- =========================

function WikilinkOpen(bp)

    local sel, _, _, _, _ = get_selection(bp)

    if not sel then
        local fsx, fsy, fex, fey = find_wikilink_at_cursor(bp)
        if fsx == nil then
            micro.InfoBar():Message("wikilink: cursor no está dentro de [[...]]")
            return
        end
        local line    = bp.Buf:Line(fsy)
        local b_start = rune_to_byte(line, fsx) + 1
        local b_end   = rune_to_byte(line, fex)
        sel = line:sub(b_start, b_end)
    end

    local inner = extract_inner(sel)

    if inner == "" then
        micro.InfoBar():Message("wikilink: el enlace está vacío")
        return
    end

    -- Enlace interno (#Título): saltar al heading en el buffer actual
    if inner:sub(1, 1) == "#" then
        local target   = inner:sub(2)  -- título sin el #
        local buf      = bp.Buf
        local numLines = buf:LinesNum()
        for i = 0, numLines - 1 do
            local line  = buf:Line(i)
            local title = heading_title(line)
            if title and title == target then
                bp.Cursor:GotoLoc(buffer.Loc(0, i))
                bp:Center()
                micro.InfoBar():Message("wikilink: → " .. target)
                return
            end
        end
        micro.InfoBar():Message('wikilink: heading no encontrado "' .. target .. '"')
        return
    end

    local full_path = resolve_path(bp, inner)

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
