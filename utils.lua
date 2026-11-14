--[[==========================================================================
  FILE        : skillmaster/utils.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.2
  CHANGES     : 1.0.2  Version number only; no code change.
                1.0.1  Version number only; no code change.
                1.0.0  First release. Combines the best parts of Skills2 0.4.2
                       (Blasty) and skillup.lua 1.1 into one package.

  WHAT  : Low level helpers shared by every other module: prefixed chat
          output, debug tracing, traced slash command dispatch, abortable
          waits, and small number and string helpers.

  WHY   : Every module needs to print, wait and send commands. Doing those
          three things in one place guarantees that every line carries the
          same [SkillMaster] tag (so it can be told apart from RGMercs and
          MQ2Nav output on a six box screen), that every command can be traced
          in one spot when Debug is on, and that every wait in the package
          honours the Stop button the same way.

  WHERE : Required by every module. It requires nothing from the package, so
          it sits at the bottom of the dependency graph and can never cause a
          circular require.

  HOW   : Pure Lua plus the mq API. Every wait is built on mq.delay, which
          yields to MacroQuest so the window keeps drawing while a spell is
          being cast. Nothing here busy waits.

  WHEN  : Loaded first and used for the whole life of the script.

  READING GUIDE (for future you)
    - "Yield" means hand control back to MacroQuest for a moment so the game
      and the window keep running. mq.delay is what yields.
    - A "getter" is a small function stored in a variable that answers a
      question when called. utils stores two (debug and abort) so it can ask
      other modules questions without requiring them, which keeps the
      requires pointing one way only.
    - Every command this package sends goes through utils.cmd. If you ever
      need to know exactly what was sent, turn on Debug in Options.
==========================================================================]]--

-- The MacroQuest Lua API: mq.cmd (send a slash command), mq.delay (wait while
-- yielding), mq.TLO (read game data) and mq.gettime (milliseconds clock).
local mq = require('mq')

-- The module table. Fields added below are public; locals are private.
local utils = {}

--- Colour code shortcuts -----------------------------------------------------
-- WHAT : Named aliases for the MacroQuest chat colour codes.
-- WHY  : Raw \ag and \ar codes are unreadable at the call site.
-- WHERE: utils.good, utils.warn, utils.err, utils.debug.
-- HOW  : String constants. MacroQuest reads a backslash plus a letter inside
--        chat text as a colour change.
-- WHEN : Read at print time. Never changed.
utils.color = {
    reset  = '\aw', -- white, normal text
    info   = '\at', -- teal, general information
    good   = '\ag', -- green, something succeeded
    warn   = '\ay', -- yellow, needs attention but not fatal
    bad    = '\ar', -- red, something failed
    accent = '\ao', -- orange, used for the [dbg] tag
}

--- Package chat prefix -------------------------------------------------------
-- WHAT : The [SkillMaster] tag at the front of every chat line.
-- WHY  : Lets the operator pick this script's lines out of everything else.
-- WHERE: utils.echo only; every other print goes through echo.
-- HOW  : Constant with colour codes. \ax resets colour after the tag.
-- WHEN : Every printed line.
local PREFIX = '\aw[\agSkillMaster\aw]\ax '

--- Debug flag getter ---------------------------------------------------------
-- WHAT : Function that returns true when debug tracing is on.
-- WHY  : utils must not require config (config requires utils), so config
--        pushes a getter in through utils.bindDebugFlag instead.
-- WHERE: utils.debug and utils.cmd.
-- HOW  : Returns false until config binds a real getter.
-- WHEN : Bound once in config.load, read on every traced call.
local debugEnabled = function() return false end

--- Abort flag getter ---------------------------------------------------------
-- WHAT : Function that returns true when the operator pressed Stop.
-- WHY  : Every wait must be interruptible without every module knowing about
--        the runner.
-- WHERE: utils.delay and utils.aborted.
-- HOW  : runner.lua binds its own test through utils.bindAbortFlag.
-- WHEN : Bound once at load, read during every wait.
local abortRequested = function() return false end

--[[--------------------------------------------------------------------------
  utils.bindDebugFlag(getter)

  WHAT  : Installs the function utils uses to decide whether to trace.
  WHY   : Avoids a circular require between utils and config.
  WHERE : config.load.
  HOW   : Stores the function in the debugEnabled upvalue.
  WHEN  : Once, right after settings load.
----------------------------------------------------------------------------]]
function utils.bindDebugFlag(getter)
    -- Only accept a real function; anything else would crash later.
    if type(getter) == 'function' then debugEnabled = getter end
end

--[[--------------------------------------------------------------------------
  utils.bindAbortFlag(getter)

  WHAT  : Installs the function utils uses to decide whether to stop waiting.
  WHY   : Lets utils.delay end a wait the moment Stop is pressed.
  WHERE : runner.lua at load time.
  HOW   : Stores the function in the abortRequested upvalue.
  WHEN  : Once, at module load.
----------------------------------------------------------------------------]]
function utils.bindAbortFlag(getter)
    -- Same safety check as bindDebugFlag.
    if type(getter) == 'function' then abortRequested = getter end
end

--[[--------------------------------------------------------------------------
  utils.aborted()

  WHAT  : True when the operator asked the run to stop.
  WHY   : Long steps (travel, chain casting) check it between sub steps.
  WHERE : spells.lua, abilities.lua, travel.lua, runner.lua.
  HOW   : Calls the bound abort getter and compares to true.
  WHEN  : Between steps of any multi step operation.
----------------------------------------------------------------------------]]
function utils.aborted()
    -- Comparing to true makes a getter that returns nil mean "not aborted".
    return abortRequested() == true
end

--[[--------------------------------------------------------------------------
  utils.echo(fmt, ...)

  WHAT  : Prints one formatted, prefixed line to the MacroQuest console.
  WHY   : Single choke point for output so the tag is always present.
  WHERE : Every module, directly or through good/warn/err/debug.
  HOW   : string.format when arguments are given, then print. print in
          MacroQuest Lua writes to the MQ console window.
  WHEN  : Whenever the package reports something.
----------------------------------------------------------------------------]]
function utils.echo(fmt, ...)
    -- Only format when arguments exist, so a lone '%' in a message is safe.
    local text = (select('#', ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    print(PREFIX .. text)  -- MacroQuest routes Lua print to its console
end

--[[--------------------------------------------------------------------------
  utils.good / utils.warn / utils.err (fmt, ...)

  WHAT  : Coloured variants of echo: green, yellow, red.
  WHY   : Colour tells the operator at a glance whether to act.
  WHERE : Every module.
  HOW   : Prefixes a colour code and calls echo.
  WHEN  : On success, warning and failure messages respectively.
----------------------------------------------------------------------------]]
function utils.good(fmt, ...) utils.echo(utils.color.good .. fmt, ...) end  -- green line
function utils.warn(fmt, ...) utils.echo(utils.color.warn .. fmt, ...) end  -- yellow line
function utils.err(fmt, ...)  utils.echo(utils.color.bad .. fmt, ...) end   -- red line

--[[--------------------------------------------------------------------------
  utils.debug(fmt, ...)

  WHAT  : Prints a [dbg] line only when Debug is ticked in Options.
  WHY   : Detailed tracing for troubleshooting without spamming normal play.
  WHERE : Any module.
  HOW   : Checks the bound debug getter, then echoes with an orange tag.
  WHEN  : At trace points.
----------------------------------------------------------------------------]]
function utils.debug(fmt, ...)
    -- Skip quickly when tracing is off; this is called often.
    if not debugEnabled() then return end
    utils.echo(utils.color.accent .. '[dbg] ' .. utils.color.reset .. fmt, ...)  -- orange [dbg] tag
end

--[[--------------------------------------------------------------------------
  utils.cmd(fmt, ...)

  WHAT  : Sends one slash command to the game, formatted like string.format.
  WHY   : One place to trace every command, which is the first thing to look
          at when something does not behave in game.
  WHERE : Every module that acts in game.
  HOW   : Formats, traces when Debug is on, then mq.cmd.
  WHEN  : Every time the package acts.
----------------------------------------------------------------------------]]
function utils.cmd(fmt, ...)
    -- Same formatting rule as echo: only format when arguments exist.
    local line = (select('#', ...) > 0) and string.format(fmt, ...) or fmt
    utils.debug('cmd: %s', line)  -- shows the exact command when Debug is on
    mq.cmd(line)                  -- hand the command to MacroQuest
end

--[[--------------------------------------------------------------------------
  utils.delay(ms, condition)

  WHAT  : Waits up to ms milliseconds, yielding, until condition() is true.
          Returns true if the condition became true, false on timeout or
          when Stop was pressed.
  WHY   : Every wait in the package must end early on Stop. mq.delay alone
          cannot know about Stop.
  WHERE : Every module that waits.
  HOW   : mq.delay with a combined condition: the caller's condition OR the
          abort flag. Afterwards the caller's condition is checked again so
          the return value means "condition met", not "abort".
  WHEN  : Any wait longer than a frame.
----------------------------------------------------------------------------]]
function utils.delay(ms, condition)
    -- No condition: a plain abortable sleep.
    if condition == nil then
        mq.delay(ms, function() return utils.aborted() end)  -- ends early on Stop
        return not utils.aborted()                           -- false if stopped
    end
    -- Wait until the condition is met or Stop is pressed or time runs out.
    mq.delay(ms, function() return condition() == true or utils.aborted() end)
    return condition() == true  -- report whether the condition was really met
end

--[[--------------------------------------------------------------------------
  utils.clamp(n, lo, hi)

  WHAT  : Returns n limited to the range lo..hi.
  WHY   : Number boxes in the window must never produce silly values.
  WHERE : ui.lua option boxes, config.load sanity checks.
  HOW   : math.max and math.min.
  WHEN  : When a number is read from the operator.
----------------------------------------------------------------------------]]
function utils.clamp(n, lo, hi)
    -- tonumber guards against a string sneaking in from a hand edited file.
    return math.max(lo, math.min(hi, tonumber(n) or lo))
end

--[[--------------------------------------------------------------------------
  utils.now()

  WHAT  : Milliseconds since an arbitrary start point.
  WHY   : Session timing and save debounce need a clock.
  WHERE : stats.lua, ui.lua, runner.lua.
  HOW   : mq.gettime.
  WHEN  : Whenever elapsed time is needed.
----------------------------------------------------------------------------]]
function utils.now()
    return mq.gettime()  -- MacroQuest's millisecond clock
end

--[[--------------------------------------------------------------------------
  utils.formatDuration(ms)

  WHAT  : Turns milliseconds into "1h 02m 03s" text.
  WHY   : Session time in the window must be readable.
  WHERE : ui.lua session line and Session tab.
  HOW   : Integer division into hours, minutes, seconds.
  WHEN  : Every frame while a session exists.
----------------------------------------------------------------------------]]
function utils.formatDuration(ms)
    local total = math.floor((ms or 0) / 1000)        -- whole seconds
    local h = math.floor(total / 3600)                -- hours
    local m = math.floor((total % 3600) / 60)         -- minutes left over
    local s = total % 60                              -- seconds left over
    return string.format('%dh %02dm %02ds', h, m, s)  -- e.g. 0h 05m 12s
end

--[[--------------------------------------------------------------------------
  utils.lower(text)

  WHAT  : Lower case copy of text, treating nil as an empty string.
  WHY   : TLO strings are compared case insensitively in several places
          (spawn types, zone short names) and may be nil.
  WHERE : skills.lua, travel.lua, abilities.lua.
  HOW   : tostring then string.lower.
  WHEN  : Before a case insensitive comparison.
----------------------------------------------------------------------------]]
function utils.lower(text)
    -- nil becomes '' so callers never need their own nil check.
    if text == nil then return '' end
    return string.lower(tostring(text))  -- plain lower case copy
end

return utils  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/utils.lua

  PUBLIC FUNCTIONS
    bindDebugFlag(fn), bindAbortFlag(fn), aborted()
    echo, good, warn, err, debug   (fmt, ...)
    cmd(fmt, ...)                  send a traced slash command
    delay(ms, cond)                abortable wait, true if cond met
    clamp(n, lo, hi), now(), formatDuration(ms), lower(text)

  DEPENDENCIES : mq only.

  HOW TO EDIT SAFELY
    - Never require another skillmaster module from here. utils must stay at
      the bottom of the dependency graph.
    - Keep utils.delay's final condition() check: callers rely on "true means
      the condition was met", not "true means the wait ended".
==========================================================================]]--
