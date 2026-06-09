-- barra.lua — Plugin para micro editor
-- Genera barras de progreso en tareas con subtareas al estilo del plugin Barra de Obsidian
-- VERSION = "1.0.0"
--
-- Instalación:
--   ~/.config/micro/plug/barra/barra.lua
--
-- Keybindings recomendadas (~/.config/micro/bindings.json):
--  {
--    "F9":  "lua:barra.UpdateBarsAll",
--    "F10": "lua:barra.UpdateBars",
--  }

local micro  = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

-- ── Configuración ──────────────────────────────────────────────
local BAR_WIDTH    = 24
local FILLED_CHAR  = "█"
local EMPTY_CHAR   = "░"
local SHOW_PERCENT = false  -- cambiar a true para mostrar "33% ████░░░"

-- ── Helpers de indentación ─────────────────────────────────────
-- Devuelve nivel de indentación (tabs = 1 nivel, 4 espacios = 1 nivel)
local function getIndent(line)
    local spaces = line:match("^(%s*)")
    if not spaces then return 0 end
    -- normalizar tabs a 4 espacios
    local normalized = spaces:gsub("\t", "    ")
    return math.floor(#normalized / 4)
end

local function isTaskLine(line)
    return line:match("^%s*%- %[[ xX]%]") ~= nil
end

local function isChecked(line)
    return line:match("^%s*%- %[[xX]%]") ~= nil
end

-- ── Eliminar barra existente ───────────────────────────────────
local function stripBar(line)
    -- Quitar "  33% ████░░░" al final
    local result = line:gsub("%s+%d+%%%s+[█░]+%s*$", "")
    -- Quitar "  ████░░░" al final
    result = result:gsub("%s+[█░]+%s*$", "")
    -- trimEnd
    result = result:gsub("%s+$", "")
    return result
end

-- ── Construir barra ────────────────────────────────────────────
local function buildBar(completed, total)
    if total == 0 then return "" end
    local ratio  = completed / total
    local filled = math.floor(ratio * BAR_WIDTH + 0.5)  -- round
    local empty  = BAR_WIDTH - filled
    local bar    = string.rep(FILLED_CHAR, filled) .. string.rep(EMPTY_CHAR, empty)
    if SHOW_PERCENT then
        return string.format("%d%% %s", math.floor(ratio * 100 + 0.5), bar)
    end
    return bar
end

-- ── Construir árbol de tareas ──────────────────────────────────
-- lines: tabla de strings (todas las líneas del buffer)
-- startIdx: índice donde empezar (1-based)
-- parentIndent: nivel del padre (-1 para raíz)
-- Devuelve: { tasks, nextIdx }
-- Cada task: { lineIdx, checked, children }
local function buildTaskTree(lines, startIdx, parentIndent)
    local tasks = {}
    local i = startIdx

    while i <= #lines do
        local line = lines[i]

        if not isTaskLine(line) then
            if parentIndent == -1 then
                i = i + 1
            else
                break
            end
        else
            local indent = getIndent(line)

            if indent < parentIndent + 1 then
                break
            elseif indent > parentIndent + 1 then
                i = i + 1
            else
                local task = {
                    lineIdx  = i,
                    checked  = isChecked(line),
                    children = {}
                }

                local result = buildTaskTree(lines, i + 1, indent)
                task.children = result.tasks
                i = result.nextIdx

                table.insert(tasks, task)
            end
        end
    end

    return { tasks = tasks, nextIdx = i }
end

-- ── Recolectar actualizaciones (bottom-up) ─────────────────────
-- Igual que collectUpdates en el plugin de Obsidian
local function collectUpdates(task, lines, updates)
    -- Primero los hijos
    for _, child in ipairs(task.children) do
        collectUpdates(child, lines, updates)
    end

    local original = lines[task.lineIdx]
    local clean    = stripBar(original)

    if #task.children > 0 then
        local total     = #task.children
        local completed = 0
        for _, c in ipairs(task.children) do
            if c.checked then completed = completed + 1 end
        end
        local allDone = completed == total

        -- Auto-marcar o desmarcar padre según hijos
        local currentlyChecked = isChecked(clean)
        local updatedClean = clean

        if allDone and not currentlyChecked then
            updatedClean = clean:gsub("^(%s*%- )%[ %]", "%1[x]", 1)
            task.checked = true
        elseif not allDone and currentlyChecked then
            updatedClean = clean:gsub("^(%s*%- )%[[xX]%]", "%1[ ]", 1)
            task.checked = false
        end

        -- Añadir barra
        local bar     = buildBar(completed, total)
        local newText = updatedClean .. "  " .. bar

        if newText ~= original then
            table.insert(updates, { lineIdx = task.lineIdx, newText = newText })
        end
    else
        -- Sin hijos: limpiar barra sobrante si la hay
        if clean ~= original then
            table.insert(updates, { lineIdx = task.lineIdx, newText = clean })
        end
    end
end

-- ── Función principal ──────────────────────────────────────────
function UpdateBars(bp)
    local buf = bp.Buf
    local c   = bp.Cursor

    -- Determinar rango de líneas a procesar
    local firstY = c.Y
    local lastY  = c.Y

    local sel = c.CurSelection
    local hasSelection = sel[1].X ~= sel[2].X or sel[1].Y ~= sel[2].Y

    if hasSelection then
        local a = sel[1]
        local b = sel[2]
        -- Si la selección termina al inicio de una línea, no incluirla
        if b.X == 0 and b.Y > a.Y then
            b = buffer.Loc(b.X, b.Y - 1)
        end
        firstY = math.min(a.Y, b.Y)
        lastY  = math.max(a.Y, b.Y)
    end

    -- Leer todas las líneas del buffer (micro usa índices 0-based)
    local totalLines = buf:LinesNum()
    local lines = {}
    for y = 0, totalLines - 1 do
        table.insert(lines, buf:Line(y))  -- lines[1] = línea 0, etc.
    end

    -- Para el árbol necesitamos identificar qué líneas raíz están
    -- dentro del rango seleccionado.
    -- Construimos el árbol completo y filtramos los roots que tocan el rango.
    -- (Los hijos fuera del rango también se procesan si el padre está dentro.)

    local result  = buildTaskTree(lines, 1, -1)
    local updates = {}

    -- Filtrar solo los árboles cuyas raíces están en el rango seleccionado
    -- (o que tienen descendientes en el rango)
    local function treeIntersectsRange(task, fY, lY)
        -- fY/lY son 0-based, lineIdx es 1-based
        local ly = task.lineIdx - 1
        if ly >= fY and ly <= lY then return true end
        for _, child in ipairs(task.children) do
            if treeIntersectsRange(child, fY, lY) then return true end
        end
        return false
    end

    for _, task in ipairs(result.tasks) do
        if treeIntersectsRange(task, firstY, lastY) then
            collectUpdates(task, lines, updates)
        end
    end

    if #updates == 0 then
        micro.InfoBar():Message("Barra: nada que actualizar")
        return
    end

    -- Aplicar cambios al buffer (en orden inverso para no desplazar índices)
    table.sort(updates, function(a, b) return a.lineIdx > b.lineIdx end)

    for _, u in ipairs(updates) do
        local y   = u.lineIdx - 1  -- convertir a 0-based
        local old = buf:Line(y)
        buf:Replace(
            buffer.Loc(0, y),
            buffer.Loc(#old, y),
            u.newText
        )
    end

    local n = #updates
    micro.InfoBar():Message("Barra: " .. n .. " línea" .. (n == 1 and "" or "s") .. " actualizadas")
end

-- ── Todo el archivo ───────────────────────────────────────────
function UpdateBarsAll(bp)
    local buf   = bp.Buf
    local total = buf:LinesNum()
    local lines = {}
    for y = 0, total - 1 do
        table.insert(lines, buf:Line(y))
    end

    local result  = buildTaskTree(lines, 1, -1)
    local updates = {}
    for _, task in ipairs(result.tasks) do
        collectUpdates(task, lines, updates)
    end

    if #updates == 0 then
        micro.InfoBar():Message("Barra: nada que actualizar")
        return
    end

    table.sort(updates, function(a, b) return a.lineIdx > b.lineIdx end)

    for _, u in ipairs(updates) do
        local y   = u.lineIdx - 1
        local old = buf:Line(y)
        buf:Replace(
            buffer.Loc(0, y),
            buffer.Loc(#old, y),
            u.newText
        )
    end

    local n = #updates
    micro.InfoBar():Message("Barra: " .. n .. " línea" .. (n == 1 and "" or "s") .. " actualizadas (archivo completo)")
end

function init()
    config.MakeCommand("barra",    UpdateBars, config.NoComplete)
    config.MakeCommand("barratodo", UpdateBarsAll, config.NoComplete)
end
