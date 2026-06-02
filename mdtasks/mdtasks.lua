VERSION = "1.0.0"
-- bindings.json
-- {
--     "F11": "lua:mdtasks.ToggleTasks"
-- }
local micro  = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

local function processLine(text)
    local indent, body
    -- Estado 1: "- [ ] texto" → "- [x] texto"
    indent, body = text:match("^(%s*)%- %[%s%] (.*)$")
    if indent then
        return indent .. "- [x] " .. body
    end
    -- Estado 2: "- [x] texto" o "- [X] texto" → texto plano
    indent, body = text:match("^(%s*)%- %[x%] (.*)$")
    if indent then
        return indent .. body
    end
    indent, body = text:match("^(%s*)%- %[X%] (.*)$")
    if indent then
        return indent .. body
    end
    -- Línea vacía → sin cambios
    if text:match("^%s*$") then
        return text
    end
    -- Estado 3: texto plano → "- [ ] texto"
    indent, body = text:match("^(%s*)(.*)$")
    return indent .. "- [ ] " .. body
end

function ToggleTasks(bp)
    local c = bp.Cursor
    local buf = bp.Buf
    local first = c.Y
    local last = c.Y

    local sel = c.CurSelection
    local hasSelection = sel[1].X ~= sel[2].X or sel[1].Y ~= sel[2].Y

    if hasSelection then
        local a = sel[1]
        local b = sel[2]
        -- Si la selección termina al inicio de una línea, excluirla
        if b.X == 0 and b.Y > a.Y then
            b = buffer.Loc(b.X, b.Y - 1)
        end
        first = math.min(a.Y, b.Y)
        last  = math.max(a.Y, b.Y)
    end

    for y = first, last do
        local old = buf:Line(y)
        local new = processLine(old)
        buf:Replace(
            buffer.Loc(0, y),
            buffer.Loc(#old, y),
            new
        )
    end
end

function init()
    config.MakeCommand("mdtasks", ToggleTasks, config.NoComplete)
end
