-- mdindex.lua
-- Genera un índice de headings Markdown (# ## ### ####) compatible con Obsidian.
-- Inserta el índice en la línea siguiente al cursor.
-- Binding sugerido: Alt-i  →  agregar en bindings.json:
--   "Alt-i": "command:mdindex"

local micro = import("micro")
local buffer = import("micro/buffer")
local config = import("micro/config")

function init()
    config.MakeCommand("mdindex", insertIndex, config.NoComplete)
end

-- Devuelve el nivel del heading (1-4) o nil si la línea no es heading.
local function headingLevel(line)
    local level, rest = line:match("^(#+)%s+(.+)$")
    if level and #level <= 4 then
        return #level, rest
    end
    return nil, nil
end

-- Construye el texto del índice como lista de strings.
local function buildIndex(buf)
    local lines = {}
    local numLines = buf:LinesNum()
    for i = 0, numLines - 1 do
        local line = buf:Line(i)
        local lvl, title = headingLevel(line)
        if lvl then
            -- Indentación: nivel 1 = sin tab, nivel 2 = 1 tab, etc.
            local indent = string.rep("\t", lvl - 1)
            -- Enlace interno Obsidian: [[#Título]]
            lines[#lines + 1] = indent .. "- [[#" .. title .. "]]"
        end
    end
    return lines
end

function insertIndex(bp)
    local buf = bp.Buf
    local indexLines = buildIndex(buf)

    if #indexLines == 0 then
        micro.InfoBar():Message("mdindex: no se encontraron headings")
        return
    end

    -- Línea de inserción: la siguiente a la del cursor
    local cursorLine = bp.Cursor.Loc.Y
    local insertLine = cursorLine + 1
    local totalLines = buf:LinesNum()

    -- Texto a insertar: cada línea del índice + newline final
    local text = table.concat(indexLines, "\n") .. "\n"

    local col = 0
    if insertLine >= totalLines then
        -- Estamos al final del buffer: insertar al final de la última línea
        local lastLine = buf:Line(totalLines - 1)
        col = #lastLine
        insertLine = totalLines - 1
        text = "\n" .. text
    end

    local loc = buffer.Loc(col, insertLine)
    buf:Insert(loc, text)

    micro.InfoBar():Message("mdindex: índice insertado (" .. #indexLines .. " entradas)")
end
