VERSION = "1.0.0"
-- {
--     "Alt-C": "lua:mdcsv.MdToCsv"
-- }
local micro  = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

local function trimFields(s)
    return s:match("^%s*(.-)%s*$")
end

local function parseMdRow(line)
    -- Quitar pipes al inicio y fin, luego dividir por |
    line = line:match("^%s*|(.+)|%s*$")
    if not line then return nil end
    local fields = {}
    for field in (line .. "|"):gmatch("([^|]*)|") do
        table.insert(fields, trimFields(field))
    end
    return fields
end

local function isSeparatorRow(line)
    -- Fila tipo | :--- | --- | :---: |
    return line:match("^%s*|[%s|:%-]+|%s*$") ~= nil
end

local function isValidMdTable(lines)
    if #lines < 3 then return false end
    if not parseMdRow(lines[1]) then return false end
    if not isSeparatorRow(lines[2]) then return false end
    local ncols = #parseMdRow(lines[1])
    if ncols < 1 then return false end
    for i = 3, #lines do
        local row = parseMdRow(lines[i])
        if not row or #row ~= ncols then return false end
    end
    return true
end

local function buildCsv(lines)
    local result = {}
    for i, line in ipairs(lines) do
        if i == 2 then
            -- Saltar fila separadora
        else
            local fields = parseMdRow(line)
            -- Escapar campos que contengan comas
            local escaped = {}
            for _, f in ipairs(fields) do
                if f:find(",") then
                    table.insert(escaped, '"' .. f .. '"')
                else
                    table.insert(escaped, f)
                end
            end
            table.insert(result, table.concat(escaped, ","))
        end
    end
    return result
end

function MdToCsv(bp)
    local c = bp.Cursor
    local buf = bp.Buf

    local sel = c.CurSelection
    local hasSelection = sel[1].X ~= sel[2].X or sel[1].Y ~= sel[2].Y

    if not hasSelection then
        micro.InfoBar():Message("mdcsv: selecciona las líneas de la tabla primero")
        return
    end

    local a = sel[1]
    local b = sel[2]
    if b.X == 0 and b.Y > a.Y then
        b = buffer.Loc(b.X, b.Y - 1)
    end
    local first = math.min(a.Y, b.Y)
    local last  = math.max(a.Y, b.Y)

    local lines = {}
    for y = first, last do
        table.insert(lines, buf:Line(y))
    end

    if not isValidMdTable(lines) then
        micro.InfoBar():Message("mdcsv: selección no es tabla Markdown válida")
        return
    end

    local csvLines = buildCsv(lines)

    local startLoc = buffer.Loc(0, first)
    local endLoc   = buffer.Loc(#buf:Line(last), last)

    buf:Replace(startLoc, endLoc, table.concat(csvLines, "\n"))
end

function init()
    config.MakeCommand("mdcsv", MdToCsv, config.NoComplete)
end

-- Sugerencias de keybinding (inverso de csvmd que usa Alt-t):
-- "Alt-c":     c = csv, libre por defecto
-- "Alt-y":     libre, cerca de Alt-t en teclado
-- "F9":        libre en micro, pero tmux lo puede interceptar
-- Recomendación: "Alt-c"
