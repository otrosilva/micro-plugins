-- hledgercheck.lua — Plugin para micro editor
-- Valida la sintaxis/balance de tu journal de hledger automáticamente
-- al guardar, y manualmente con F8. Solo corre sobre 2026.journal
-- (la ruta que usa tu función `hledger` de zsh).
-- VERSION = "1.0.0"
--
-- Instalación:
--   ~/.config/micro/plug/hledgercheck/hledgercheck.lua
--
-- Keybinding recomendada (~/.config/micro/bindings.json):
--  {
--    "F8": "lua:hledgercheck.CheckJournal"
--  }

local micro  = import("micro")
local config = import("micro/config")
local shell  = import("micro/shell")
local os     = import("os")

-- ── Configuración ──────────────────────────────────────────────
-- Ruta al journal principal, igual que en tu función zsh `hledger()`.
-- Se expande $HOME en tiempo de ejecución.
local JOURNAL_PATH = os.Getenv("HOME") .. "/Documentos/Filen/finanzas/2026.journal"

-- ── Helpers ─────────────────────────────────────────────────────

-- Normaliza una ruta de buffer y la compara contra JOURNAL_PATH.
-- Evita correr `hledger check` sobre archivos que no son el journal.
local function isJournalBuffer(buf)
    if not buf or not buf.Path then return false end
    return buf.Path == JOURNAL_PATH
end

-- Parsea la salida de `hledger check` y extrae:
--   ok        -> bool, si pasó la validación
--   lineInfo  -> string como "línea 1-3" o "línea 1" (vacío si ok)
--   message   -> primera línea de explicación del error (vacío si ok)
local function parseHledgerOutput(output, exitOk)
    if exitOk then
        return true, "", ""
    end

    -- Formatos reales de hledger:
    --   archivo:1-3:
    --   archivo:1:1:
    local lineRange = output:match(":(%d+%-%d+):")
    local lineSingle = nil
    if not lineRange then
        lineSingle = output:match(":(%d+):%d*:?")
    end

    local lineInfo = ""
    if lineRange then
        lineInfo = "línea " .. lineRange
    elseif lineSingle then
        lineInfo = "línea " .. lineSingle
    end

    -- Buscar la primera línea de mensaje "humano" después del bloque
    -- de contexto (que empieza con "N | " o "  | ").
    -- Tomamos la primera línea no vacía que no sea parte del contexto
    -- ni el "hledger: Error:" inicial.
    local message = ""
    for line in output:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= ""
            and not trimmed:match("^hledger:")
            and not trimmed:match("^%d+%s*|")
            and not trimmed:match("^|")
            and not trimmed:match("^%^+$")
            and not trimmed:match("^%S+:%d") -- la línea "archivo:N-M:" o "archivo:N:N:"
        then
            message = trimmed
            break
        end
    end

    if message == "" then
        message = "ver detalles con :hledgercheck en terminal"
    end

    return false, lineInfo, message
end

-- ── Ejecutar la validación ──────────────────────────────────────
local function runCheck(bp, silentOnSuccess)
    local buf = bp.Buf

    if not isJournalBuffer(buf) then
        if not silentOnSuccess then
            micro.InfoBar():Message("hledgercheck: este archivo no es " .. JOURNAL_PATH)
        end
        return
    end

    -- RunCommand usa el parser de argumentos de micro (no un shell real),
    -- así que no hace falta "2>&1" (ya combina stdout+stderr). Tampoco
    -- usamos comillas: JOURNAL_PATH no tiene espacios y no podemos
    -- garantizar cómo el parser de micro interpretaría comillas.
    local cmd = string.format("hledger -f %s check", JOURNAL_PATH)
    local output, err = shell.RunCommand(cmd)

    -- shell.RunCommand devuelve (output, err); err ~= nil si el
    -- proceso terminó con código de salida distinto de 0.
    local exitOk = (err == nil)

    local ok, lineInfo, message = parseHledgerOutput(output or "", exitOk)

    if ok then
        if not silentOnSuccess then
            micro.InfoBar():Message("✓ hledger check: journal OK")
        end
    else
        if lineInfo ~= "" then
            micro.InfoBar():Message("✗ hledger check (" .. lineInfo .. "): " .. message)
        else
            micro.InfoBar():Message("✗ hledger check: " .. message)
        end
    end
end

-- ── Comando manual (F8) ──────────────────────────────────────────
function CheckJournal(bp)
    runCheck(bp, false)
end

-- ── Hook automático al guardar ───────────────────────────────────
-- onSave se dispara con Ctrl-S / F2 tras un guardado exitoso.
function onSave(bp)
    -- silentOnSuccess = true: en éxito no spameamos el InfoBar en cada
    -- guardado normal de edición; solo avisamos si algo falla.
    runCheck(bp, true)
end

function init()
    config.MakeCommand("hledgercheck", CheckJournal, config.NoComplete)
end
