-- mdcode: encierra/desencierra líneas seleccionadas en bloque de código Markdown
-- Expande la selección a líneas completas automáticamente
-- Primera pulsación:  añade ```code arriba y ``` abajo, mantiene selección
-- Segunda pulsación:  detecta el bloque y lo elimina, mantiene selección
-- Versión: 1.2.0

local micro  = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local util   = import("micro/util")

local function getSelectionLocs()
    local c = micro.CurPane().Cursor
    if not c:HasSelection() then
        return nil, nil
    end
    local s1 = c.CurSelection[1]
    local s2 = c.CurSelection[2]
    local a, b
    if s2.Y > s1.Y or (s2.Y == s1.Y and s2.X > s1.X) then
        a, b = s1, s2
    else
        a, b = s2, s1
    end
    return buffer.Loc(a.X, a.Y), buffer.Loc(b.X, b.Y)
end

-- Expande los Locs a líneas completas:
-- a.X = 0, b = fin de su línea (si b.X==0 y b.Y>a.Y, retrocede una línea)
local function expandToFullLines(a, b, buf)
    local firstY = a.Y
    local lastY  = b.Y
    if b.X == 0 and b.Y > a.Y then
        lastY = b.Y - 1
    end
    local startLoc = buffer.Loc(0, firstY)
    local endLoc   = buffer.Loc(#buf:Line(lastY), lastY)
    return startLoc, endLoc, firstY, lastY
end

-- Restaura la selección cubriendo líneas completas firstY..lastY
local function restoreSelection(cursor, buf, firstY, lastY)
    local startLoc = buffer.Loc(0, firstY)
    local endLoc   = buffer.Loc(#buf:Line(lastY), lastY)
    cursor:SetSelectionStart(startLoc)
    cursor:SetSelectionEnd(endLoc)
    cursor.Loc.X = endLoc.X
    cursor.Loc.Y = endLoc.Y
end

local function isOpenFence(line)
    return line:match("^```") ~= nil
end

local function isCloseFence(line)
    return line:match("^```%s*$") ~= nil
end

function mdcodeCmd(bp)
    local cursor = micro.CurPane().Cursor

    if not cursor:HasSelection() then
        micro.InfoBar():Message("mdcode: selecciona lineas primero")
        return
    end

    local a, b = getSelectionLocs()
    if a == nil then return end

    local buf = micro.CurPane().Buf

    -- Expandir siempre a líneas completas
    local fullA, fullB, firstY, lastY = expandToFullLines(a, b, buf)

    -- ¿Hay cercas justo alrededor de las líneas completas?
    local prevY = firstY - 1
    local nextY = lastY + 1
    local hasFences = false
    if prevY >= 0 and nextY <= buf:LinesNum() - 1 then
        if isOpenFence(buf:Line(prevY)) and isCloseFence(buf:Line(nextY)) then
            hasFences = true
        end
    end

    if hasFences then
        -- QUITAR cercas: primero la de cierre (índice mayor), luego la de apertura
        local closeFrom = buffer.Loc(#buf:Line(nextY - 1), nextY - 1)
        local closeTo   = buffer.Loc(#buf:Line(nextY), nextY)
        buf.EventHandler:Remove(closeFrom, closeTo)

        local openFrom = buffer.Loc(0, prevY)
        local openTo   = buffer.Loc(0, prevY + 1)
        buf.EventHandler:Remove(openFrom, openTo)

        -- El contenido quedó en prevY .. prevY+(lastY-firstY)
        restoreSelection(cursor, buf, prevY, prevY + (lastY - firstY))
        micro.InfoBar():Message("mdcode -> bloque eliminado")
    else
        -- AÑADIR cercas

        -- Cierre al final de lastY
        local closeLoc = buffer.Loc(#buf:Line(lastY), lastY)
        buf.EventHandler:Insert(closeLoc, "\n```")

        -- Apertura al inicio de firstY
        local openLoc = buffer.Loc(0, firstY)
        buf.EventHandler:Insert(openLoc, "```code\n")

        -- El contenido quedó en firstY+1 .. lastY+1
        restoreSelection(cursor, buf, firstY + 1, lastY + 1)
        micro.InfoBar():Message("mdcode -> bloque insertado")
    end
end

function init()
    config.MakeCommand("mdcode", mdcodeCmd, config.NoComplete)
    config.TryBindKey("Alt-k", "lua:mdcode.mdcodeCmd", false)
end
