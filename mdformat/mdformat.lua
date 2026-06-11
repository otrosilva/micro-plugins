-- mdformat: cicla el formato Markdown/Obsidian del texto seleccionado
-- Una línea:   rodea la selección con el marcador
-- Varias líneas: cada línea se rodea individualmente (inline),
--               o se envuelve en bloque ``` (código)
-- Ciclo: normal → **negrita** → *itálica* → ~~tachado~~ → ==resaltado== → `código` → normal
-- Versión: 2.0.0

local micro  = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local util   = import("micro/util")

-- ── Helpers de selección ─────────────────────────────────────────────────────

local function getSelectionLocs()
    local c = micro.CurPane().Cursor
    if not c:HasSelection() then return nil, nil end
    local s1, s2 = c.CurSelection[1], c.CurSelection[2]
    local a, b
    if s2.Y > s1.Y or (s2.Y == s1.Y and s2.X > s1.X) then
        a, b = s1, s2
    else
        a, b = s2, s1
    end
    return buffer.Loc(a.X, a.Y), buffer.Loc(b.X, b.Y)
end

-- Normaliza b: si X=0 y hay varias líneas, retrocede al fin de la línea anterior
local function normalizeEnd(a, b, buf)
    local lastY = b.Y
    if b.X == 0 and b.Y > a.Y then
        lastY = b.Y - 1
    end
    return a.Y, lastY
end

local function restoreSelection(cursor, buf, firstY, lastY)
    local s = buffer.Loc(0, firstY)
    local e = buffer.Loc(#buf:Line(lastY), lastY)
    cursor:SetSelectionStart(s)
    cursor:SetSelectionEnd(e)
    cursor.Loc.X = e.X
    cursor.Loc.Y = e.Y
end

-- Restaura selección tras reemplazo en una sola línea
local function restoreSingleSelection(cursor, trimA, trimB, oldLen, newLen)
    local diff = newLen - oldLen
    local newEnd = buffer.Loc(trimB.X + diff, trimB.Y)
    cursor:SetSelectionStart(trimA)
    cursor:SetSelectionEnd(newEnd)
    cursor.Loc.X = newEnd.X
    cursor.Loc.Y = newEnd.Y
end

-- ── Detección de formato ──────────────────────────────────────────────────────

local function detectFormat(text)
    if text:sub(1, 2) == "==" and text:sub(-2) == "==" and #text > 4 then
        return "highlight", text:sub(3, -3)
    end
    if text:sub(1, 2) == "~~" and text:sub(-2) == "~~" and #text > 4 then
        return "strike", text:sub(3, -3)
    end
    if text:sub(1, 2) == "**" and text:sub(-2) == "**" and #text > 4 then
        return "bold", text:sub(3, -3)
    end
    if text:sub(1, 1) == "*" and text:sub(2, 2) ~= "*"
       and text:sub(-1) == "*" and text:sub(-2, -2) ~= "*"
       and #text > 2 then
        return "italic", text:sub(2, -2)
    end
    if text:sub(1, 1) == "_" and text:sub(-1) == "_" and #text > 2 then
        return "italic", text:sub(2, -2)
    end
    if text:sub(1, 1) == "`" and text:sub(-1) == "`" and #text > 2 then
        return "code", text:sub(2, -2)
    end
    return "none", text
end

local MARKERS = {
    bold      = { "**", "**" },
    italic    = { "*",  "*"  },
    strike    = { "~~", "~~" },
    highlight = { "==", "==" },
    code      = { "`",  "`"  },
}

local CYCLE = { "none", "bold", "italic", "strike", "highlight", "code" }

local function nextFmt(fmt)
    for i, v in ipairs(CYCLE) do
        if v == fmt then
            return CYCLE[(i % #CYCLE) + 1]
        end
    end
    return "bold"
end

local function applyFmt(fmt, text)
    if fmt == "none" then return text end
    local m = MARKERS[fmt]
    return m[1] .. text .. m[2]
end

local function stripFmt(fmt, text)
    if fmt == "none" then return text end
    local m = MARKERS[fmt]
    local l, r = #m[1], #m[2]
    if text:sub(1, l) == m[1] and text:sub(-r) == m[2] and #text > l + r then
        return text:sub(l + 1, -(r + 1))
    end
    return text
end

-- ── Trim de espacios/newlines con ajuste de Locs ─────────────────────────────

local function trimLocs(a, b, rawText)
    local leadCount = 0
    for i = 1, #rawText do
        local ch = rawText:sub(i, i)
        if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
            leadCount = leadCount + 1
        else break end
    end
    local trailCount = 0
    for i = #rawText, 1, -1 do
        local ch = rawText:sub(i, i)
        if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
            trailCount = trailCount + 1
        else break end
    end
    local trimmed = rawText:sub(leadCount + 1, #rawText - trailCount)
    if trimmed == "" then return a, b, "" end

    local newAX, newAY = a.X, a.Y
    for i = 1, leadCount do
        if rawText:sub(i, i) == "\n" then newAY = newAY + 1; newAX = 0
        else newAX = newAX + 1 end
    end

    local buf = micro.CurPane().Buf
    local newBX, newBY = b.X, b.Y
    for i = #rawText, #rawText - trailCount + 1, -1 do
        if rawText:sub(i, i) == "\n" then
            newBY = newBY - 1; newBX = #buf:Line(newBY)
        else newBX = newBX - 1 end
    end

    return buffer.Loc(newAX, newAY), buffer.Loc(newBX, newBY), trimmed
end

-- ── Lógica multilínea ─────────────────────────────────────────────────────────

-- Detecta si la selección ya está envuelta con cercas inline:
-- primera línea empieza con ``` y última termina con ```
local function detectInlineFence(buf, firstY, lastY)
    local first = buf:Line(firstY)
    local last  = buf:Line(lastY)
    return first:sub(1, 3) == "```" and last:sub(-3) == "```"
end

-- Detecta si todas las líneas del rango tienen el mismo formato inline
local function detectMultilineFmt(buf, firstY, lastY)
    local fmt = nil
    for y = firstY, lastY do
        local line = buf:Line(y)
        local f, _ = detectFormat(line)
        if f == "none" then return "none" end
        if fmt == nil then fmt = f
        elseif fmt ~= f then return "none" end
    end
    return fmt or "none"
end

-- Aplica o quita formato inline en cada línea del rango
local function applyMultilineInline(buf, firstY, lastY, targetFmt, currentFmt)
    -- Recorrer de abajo hacia arriba para no desplazar índices
    for y = lastY, firstY, -1 do
        local line = buf:Line(y)
        local newLine
        if currentFmt ~= "none" then
            local inner = stripFmt(currentFmt, line)
            newLine = applyFmt(targetFmt, inner)
        else
            newLine = applyFmt(targetFmt, line)
        end
        local from = buffer.Loc(0, y)
        local to   = buffer.Loc(#line, y)
        buf.EventHandler:Remove(from, to)
        buf.EventHandler:Insert(from, newLine)
    end
end

-- ── Comando principal ─────────────────────────────────────────────────────────

function mdformatCmd(bp)
    local cursor = micro.CurPane().Cursor
    if not cursor:HasSelection() then
        micro.InfoBar():Message("mdformat: selecciona texto primero")
        return
    end

    local rawText = util.String(cursor:GetSelection())
    if rawText == "" then
        micro.InfoBar():Message("mdformat: seleccion vacia")
        return
    end

    local a, b = getSelectionLocs()
    if a == nil then return end

    local buf = micro.CurPane().Buf
    local firstY, lastY = normalizeEnd(a, b, buf)
    local multiline = (lastY > firstY)

    local nombres = {
        bold="negrita **", italic="italica *", strike="tachado ~~",
        highlight="resaltado ==", code="codigo `", none="normal",
    }

    -- ── MULTILÍNEA ────────────────────────────────────────────────────────────
    if multiline then
        -- ¿Ya tiene cercas inline? (```primera línea ... última línea```)
        if detectInlineFence(buf, firstY, lastY) then
            -- Quitar ``` del inicio de la primera línea y del final de la última
            -- Última primero para no desplazar firstY
            local lastLine = buf:Line(lastY)
            local lastInner = lastLine:sub(1, #lastLine - 3)  -- quitar ``` final
            local lastFrom = buffer.Loc(0, lastY)
            local lastTo   = buffer.Loc(#lastLine, lastY)
            buf.EventHandler:Remove(lastFrom, lastTo)
            buf.EventHandler:Insert(lastFrom, lastInner)

            local firstLine = buf:Line(firstY)
            local firstInner = firstLine:sub(4)  -- quitar ``` inicial
            local firstFrom = buffer.Loc(0, firstY)
            local firstTo   = buffer.Loc(#firstLine, firstY)
            buf.EventHandler:Remove(firstFrom, firstTo)
            buf.EventHandler:Insert(firstFrom, firstInner)

            restoreSelection(cursor, buf, firstY, lastY)
            micro.InfoBar():Message("mdformat -> normal")
            return
        end

        -- ¿Tienen formato inline todas las líneas?
        local currentFmt = detectMultilineFmt(buf, firstY, lastY)
        local targetFmt  = nextFmt(currentFmt)

        if targetFmt == "code" then
            -- Quitar formato inline si lo hay, luego añadir cercas inline
            if currentFmt ~= "none" then
                applyMultilineInline(buf, firstY, lastY, "none", currentFmt)
            end
            -- Añadir ``` al inicio de firstY y al final de lastY
            -- lastY primero para no desplazar índices
            local lastLine = buf:Line(lastY)
            local lastFrom = buffer.Loc(#lastLine, lastY)
            buf.EventHandler:Insert(lastFrom, "```")

            local firstFrom = buffer.Loc(0, firstY)
            buf.EventHandler:Insert(firstFrom, "```")

            restoreSelection(cursor, buf, firstY, lastY)
            micro.InfoBar():Message("mdformat -> codigo ```")
        else
            -- Formato inline línea a línea
            applyMultilineInline(buf, firstY, lastY, targetFmt, currentFmt)
            restoreSelection(cursor, buf, firstY, lastY)
            micro.InfoBar():Message("mdformat -> " .. (nombres[targetFmt] or "ok"))
        end
        return
    end

    -- ── UNA LÍNEA ─────────────────────────────────────────────────────────────
    local trimA, trimB, trimmed = trimLocs(a, b, rawText)
    if trimmed == "" then
        micro.InfoBar():Message("mdformat: seleccion solo espacios")
        return
    end

    local currentFmt, inner = detectFormat(trimmed)
    local targetFmt = nextFmt(currentFmt)
    local newText

    if targetFmt == "none" then
        newText = inner
    else
        local core = (currentFmt ~= "none") and inner or trimmed
        newText = applyFmt(targetFmt, core)
    end

    buf:Replace(trimA, trimB, newText)
    restoreSingleSelection(cursor, trimA, trimB, #trimmed, #newText)
    micro.InfoBar():Message("mdformat -> " .. (nombres[targetFmt] or "ok"))
end

function init()
    config.MakeCommand("mdformat", mdformatCmd, config.NoComplete)
    config.TryBindKey("Alt-m", "lua:mdformat.mdformatCmd", false)
end
