-- mdindex.lua
-- Genera un índice de headings Markdown (# ## ### ####) compatible con Obsidian.
-- Inserta el índice desde la línea actual del cursor, empujando su contenido hacia abajo.
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
        -- Recortar espacio final accidental (ej. "# contraseñas ")
        -- para que coincida exactamente con el texto que espera wikilink.lua
        rest = rest:gsub("%s+$", "")
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
    -- Insertar desde la línea actual del cursor, desplazando su contenido hacia abajo
    local insertLine = bp.Cursor.Loc.Y
    local text = table.concat(indexLines, "\n") .. "\n"
    local loc = buffer.Loc(0, insertLine)
    buf:Insert(loc, text)
    micro.InfoBar():Message("mdindex: índice insertado (" .. #indexLines .. " entradas)")
end
