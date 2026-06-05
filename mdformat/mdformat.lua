-- mdformat: cicla el formato Markdown/Obsidian del texto seleccionado
-- Ciclo: normal → **negrita** → *itálica* → ~~tachado~~ → ==resaltado== → normal
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

-- Detecta el formato actual; devuelve (tipo, contenido_interno)
-- Orden importante: probar marcadores más largos primero (** antes que *)
local function detectFormat(text)
    -- Resaltado: ==texto==
    if text:sub(1, 2) == "==" and text:sub(-2) == "==" and #text > 4 then
        return "highlight", text:sub(3, -3)
    end
    -- Tachado: ~~texto~~
    if text:sub(1, 2) == "~~" and text:sub(-2) == "~~" and #text > 4 then
        return "strike", text:sub(3, -3)
    end
    -- Negrita: **texto**
    if text:sub(1, 2) == "**" and text:sub(-2) == "**" and #text > 4 then
        return "bold", text:sub(3, -3)
    end
    -- Itálica Obsidian: *texto*  (un solo asterisco; no debe ser **)
    if text:sub(1, 1) == "*" and text:sub(2, 2) ~= "*"
       and text:sub(-1) == "*" and text:sub(-2, -2) ~= "*"
       and #text > 2 then
        return "italic", text:sub(2, -2)
    end
    -- Itálica alternativa: _texto_
    if text:sub(1, 1) == "_" and text:sub(-1) == "_" and #text > 2 then
        return "italic", text:sub(2, -2)
    end
    return "none", text
end

-- Devuelve el texto con el siguiente formato en el ciclo
local function nextFormat(text)
    local fmt, inner = detectFormat(text)
    if fmt == "none" then
        return "**" .. text .. "**"       -- → negrita
    elseif fmt == "bold" then
        return "*" .. inner .. "*"        -- → itálica
    elseif fmt == "italic" then
        return "~~" .. inner .. "~~"      -- → tachado
    elseif fmt == "strike" then
        return "==" .. inner .. "=="      -- → resaltado
    else  -- highlight
        return inner                      -- → normal
    end
end

-- Ajusta los Locs para excluir espacios/newlines a los lados de la selección
local function trimLocs(a, b, rawText)
    local leadCount = 0
    for i = 1, #rawText do
        local ch = rawText:sub(i, i)
        if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
            leadCount = leadCount + 1
        else
            break
        end
    end

    local trailCount = 0
    for i = #rawText, 1, -1 do
        local ch = rawText:sub(i, i)
        if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
            trailCount = trailCount + 1
        else
            break
        end
    end

    local trimmed = rawText:sub(leadCount + 1, #rawText - trailCount)
    if trimmed == "" then
        return a, b, ""
    end

    local newAX, newAY = a.X, a.Y
    for i = 1, leadCount do
        local ch = rawText:sub(i, i)
        if ch == "\n" then
            newAY = newAY + 1
            newAX = 0
        else
            newAX = newAX + 1
        end
    end

    local buf = micro.CurPane().Buf
    local newBX, newBY = b.X, b.Y
    for i = #rawText, #rawText - trailCount + 1, -1 do
        local ch = rawText:sub(i, i)
        if ch == "\n" then
            newBY = newBY - 1
            newBX = #buf:Line(newBY)
        else
            newBX = newBX - 1
        end
    end

    return buffer.Loc(newAX, newAY), buffer.Loc(newBX, newBY), trimmed
end

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

    local trimA, trimB, trimmed = trimLocs(a, b, rawText)
    if trimmed == "" then
        micro.InfoBar():Message("mdformat: seleccion solo espacios")
        return
    end

    local newText = nextFormat(trimmed)
    micro.CurPane().Buf:Replace(trimA, trimB, newText)

    -- Restaurar selección sobre el texto nuevo
    local diff = #newText - #trimmed
    local newEnd = buffer.Loc(trimB.X + diff, trimB.Y)
    cursor:SetSelectionStart(trimA)
    cursor:SetSelectionEnd(newEnd)
    cursor.Loc.X = newEnd.X
    cursor.Loc.Y = newEnd.Y

    local fmt = detectFormat(newText)
    local nombres = {
        bold      = "negrita **",
        italic    = "italica *",
        strike    = "tachado ~~",
        highlight = "resaltado ==",
        none      = "normal",
    }
    micro.InfoBar():Message("mdformat -> " .. (nombres[fmt] or "ok"))
end

function init()
    config.MakeCommand("mdformat", mdformatCmd, config.NoComplete)
    config.TryBindKey("Alt-m", "lua:mdformat.mdformatCmd", false)
end
