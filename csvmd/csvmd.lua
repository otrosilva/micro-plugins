VERSION = "1.0.0"
-- {
--     "Alt-T": "lua:csvmd.CsvToMd",
-- }

local micro  = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

local function trimFields(line)
    local fields = {}
    for field in (line .. ","):gmatch("([^,]*),") do
        -- Trim espacios al inicio y fin
        field = field:match("^%s*(.-)%s*$")
        table.insert(fields, field)
    end
    return fields
end

local function isValidCsv(lines)
    if #lines < 2 then return false end
    local ncols = #trimFields(lines[1])
    if ncols < 2 then return false end
    for i = 2, #lines do
        if #trimFields(lines[i]) ~= ncols then
            return false
        end
    end
    return true
end

local function buildTable(lines)
    local rows = {}
    for _, line in ipairs(lines) do
        table.insert(rows, trimFields(line))
    end

    local ncols = #rows[1]

    -- Fila de encabezado
    local header = "| " .. table.concat(rows[1], " | ") .. " |"

    -- Fila separadora con alineación izquierda
    local sep_parts = {}
    for i = 1, ncols do
        table.insert(sep_parts, " :--- ")
    end
    local separator = "|" .. table.concat(sep_parts, "|") .. "|"

    -- Filas de datos
    local data_lines = {}
    for i = 2, #rows do
        table.insert(data_lines, "| " .. table.concat(rows[i], " | ") .. " |")
    end

    local result = { header, separator }
    for _, dl in ipairs(data_lines) do
        table.insert(result, dl)
    end
    return result
end

function CsvToMd(bp)
    local c = bp.Cursor
    local buf = bp.Buf

    local sel = c.CurSelection
    local hasSelection = sel[1].X ~= sel[2].X or sel[1].Y ~= sel[2].Y

    if not hasSelection then
        micro.InfoBar():Message("csvmd: selecciona las líneas CSV primero")
        return
    end

    local a = sel[1]
    local b = sel[2]
    if b.X == 0 and b.Y > a.Y then
        b = buffer.Loc(b.X, b.Y - 1)
    end
    local first = math.min(a.Y, b.Y)
    local last  = math.max(a.Y, b.Y)

    -- Recoger líneas seleccionadas
    local lines = {}
    for y = first, last do
        table.insert(lines, buf:Line(y))
    end

    if not isValidCsv(lines) then
        micro.InfoBar():Message("csvmd: selección no es CSV válido (columnas inconsistentes o menos de 2 líneas)")
        return
    end

    local mdLines = buildTable(lines)

    -- Reemplazar líneas seleccionadas con la tabla md
    -- Primero borrar todo el rango, luego insertar
    local startLoc = buffer.Loc(0, first)
    local endLoc   = buffer.Loc(#buf:Line(last), last)

    buf:Replace(startLoc, endLoc, table.concat(mdLines, "\n"))
end

function init()
    config.MakeCommand("csvmd", CsvToMd, config.NoComplete)
end
