-- mdcode: encierra/desencierra líneas seleccionadas en bloque de código Markdown
-- Primera pulsación:  añade ```code arriba y ``` abajo, mantiene selección
-- Segunda pulsación:  detecta el bloque y lo elimina, mantiene selección
-- Versión: 1.1.0

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

-- Restaura la selección entre dos líneas completas (de col 0 a fin de línea)
local function restoreSelection(cursor, buf, startY, endY)
    local startLoc = buffer.Loc(0, startY)
    local endLoc   = buffer.Loc(#buf:Line(endY), endY)
    cursor:SetSelectionStart(startLoc)
    cursor:SetSelectionEnd(endLoc)
    cursor.Loc.X = endLoc.X
    cursor.Loc.Y = endLoc.Y
end

-- Detecta si la línea es apertura de bloque (```algo o ``` sola)
local function isOpenFence(line)
    return line:match("^```") ~= nil
end

-- Detecta si la línea es cierre de bloque (``` exacto, sin nada más)
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

    -- Ajustar lastY igual que antes
    local lastY = b.Y
    if b.X == 0 and b.Y > a.Y then
        lastY = b.Y - 1
    end

    -- ¿La línea justo antes es apertura y la de después es cierre?
    local prevY = a.Y - 1
    local nextY = lastY + 1
    local hasFences = false
    if prevY >= 0 and nextY <= buf:LinesNum() - 1 then
        local prevLine = buf:Line(prevY)
        local nextLine = buf:Line(nextY)
        if isOpenFence(prevLine) and isCloseFence(nextLine) then
            hasFences = true
        end
    end

    if hasFences then
        -- QUITAR el bloque: eliminar línea de cierre primero (índice mayor),
        -- luego la de apertura (para no desplazar índices)
        local closeStart = buffer.Loc(0, nextY)
        local closeEnd   = buffer.Loc(#buf:Line(nextY), nextY)
        -- Borrar línea de cierre: desde el \n al final de la línea anterior
        -- hasta el final de la línea de cierre
        local closeFrom = buffer.Loc(#buf:Line(nextY - 1), nextY - 1)
        local closeTo   = buffer.Loc(#buf:Line(nextY), nextY)
        buf.EventHandler:Remove(closeFrom, closeTo)

        -- Ahora borrar línea de apertura (prevY sigue igual, nextY ya no existe)
        local openFrom = buffer.Loc(0, prevY)
        local openTo   = buffer.Loc(#buf:Line(prevY) + 1, prevY)  -- +1 captura el \n
        -- Remove desde inicio de prevY hasta inicio de a.Y (que ahora es prevY+1)
        local openStart2 = buffer.Loc(0, prevY)
        local openEnd2   = buffer.Loc(0, prevY + 1)
        buf.EventHandler:Remove(openStart2, openEnd2)

        -- Las líneas del contenido ahora empiezan en prevY
        restoreSelection(cursor, buf, prevY, prevY + (lastY - a.Y))
        micro.InfoBar():Message("mdcode -> bloque eliminado")
    else
        -- AÑADIR el bloque

        -- Insertar ``` al final de la última línea (cierre)
        local closeLoc = buffer.Loc(#buf:Line(lastY), lastY)
        buf.EventHandler:Insert(closeLoc, "\n```")

        -- Insertar ```code al inicio de la primera línea (apertura)
        local openLoc = buffer.Loc(0, a.Y)
        buf.EventHandler:Insert(openLoc, "```code\n")

        -- El contenido ahora está en a.Y+1 .. lastY+1
        restoreSelection(cursor, buf, a.Y + 1, lastY + 1)
        micro.InfoBar():Message("mdcode -> bloque insertado")
    end
end

function init()
    config.MakeCommand("mdcode", mdcodeCmd, config.NoComplete)
    config.TryBindKey("Alt-k", "lua:mdcode.mdcodeCmd", false)
end
