--[[==========================================================================
  FILE        : skillmaster/stats.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.3
  CHANGES     : 1.0.3  Version number only; no code change.
                1.0.2  Version number only; no code change.
                1.0.1  Version number only; no code change.
                1.0.0  First release. Keeps the skill up message event of
                       skillup.lua and adds a session log, gains per skill,
                       points per hour, cast and fizzle counts.

  WHAT  : Session statistics: when the session started, every skill up seen
          in chat, gains per skill, casts and fizzles, and a short log of
          recent events for the Session tab.

  WHY   : Knowing the rate tells the operator whether a skill is worth more
          time today, and the log shows at a glance what the run has been
          doing while the operator was on another box.

  WHERE : Event registered by stats.init (called from init.lua). Counters
          bumped by spells.lua and abilities.lua. Read by ui.lua.

  HOW   : mq.event on the game's skill up line
            "You have become better at #1#! (#2#)"
          (the same pattern skillup.lua used). The handler records the gain
          and drops the cached skill value so the bar moves at once.
          mq.doevents is called from the main loop in init.lua.

  WHEN  : Event active for the life of the script; session reset by the
          Reset button or a new run if the operator chooses.

  READING GUIDE (for future you)
    - #1# and #2# in an event pattern capture text; MacroQuest passes the
      captured pieces to the handler after the whole line.
==========================================================================]]--

local mq     = require('mq')                   -- event
local utils  = require('skillmaster.utils')    -- now, good
local skills = require('skillmaster.skills')   -- invalidate

local stats = {}

--- Session data -----------------------------------------------------------------
-- WHAT : Everything counted this session.
-- WHY  : One table so reset is a single assignment.
-- WHERE: Whole module, ui.lua reads it.
-- HOW  : Fields: started (ms), runMs (time spent running), gains[name] = n,
--        total, casts, fizzles, abilities, log (newest first).
-- WHEN : Reset by stats.reset.
stats.data = nil

--- Log length ---------------------------------------------------------------------
-- WHAT : How many log lines to keep.
-- WHY  : Enough to see the last few minutes without growing forever.
-- WHERE: stats.log.
-- HOW  : Older lines are dropped from the end.
-- WHEN : Every log write.
local LOG_MAX = 60

--[[--------------------------------------------------------------------------
  stats.reset()

  WHAT  : Starts a fresh session.
  WHY   : The Session tab's Reset button and first load.
  WHERE : stats.init, ui.drawSession.
  HOW   : Replaces stats.data with a new empty table.
  WHEN  : At load and on request.
----------------------------------------------------------------------------]]
function stats.reset()
    -- New table; the old one is simply dropped.
    stats.data = { started = utils.now(), runMs = 0, gains = {}, total = 0,
                   casts = 0, fizzles = 0, abilities = 0, log = {} }
end

--[[--------------------------------------------------------------------------
  stats.log(fmt, ...)

  WHAT  : Adds a time stamped line to the session log.
  WHY   : The Session tab shows what happened while you were away.
  WHERE : stats.lua handlers, runner.lua, travel.lua.
  HOW   : Formats, prepends with an os.date stamp, trims to LOG_MAX.
  WHEN  : On notable events.
----------------------------------------------------------------------------]]
function stats.log(fmt, ...)
    -- Same formatting rule as utils.echo.
    local text = (select('#', ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    table.insert(stats.data.log, 1, os.date('%H:%M:%S') .. '  ' .. text)  -- newest first
    while #stats.data.log > LOG_MAX do table.remove(stats.data.log) end   -- trim the oldest
end

--[[--------------------------------------------------------------------------
  stats.count(field)

  WHAT  : Adds one to a counter (casts, fizzles, abilities).
  WHY   : Keeps counter names in one place.
  WHERE : spells.lua, abilities.lua.
  HOW   : Increments stats.data[field].
  WHEN  : After each action.
----------------------------------------------------------------------------]]
function stats.count(field)
    stats.data[field] = (stats.data[field] or 0) + 1  -- unknown fields start at zero
end

--[[--------------------------------------------------------------------------
  onSkillUp(line, skill, value)

  WHAT  : Handler for the game's skill up line.
  WHY   : This is the only reliable signal that a point was gained.
  WHERE : Registered by stats.init with mq.event.
  HOW   : Records the gain, refreshes the cached value, logs it.
  WHEN  : Whenever the line appears in chat (via mq.doevents).
----------------------------------------------------------------------------]]
local function onSkillUp(line, skill, value)
    -- skill and value are the #1# and #2# captures.
    skill = tostring(skill or '')
    stats.data.gains[skill] = (stats.data.gains[skill] or 0) + 1  -- per skill count
    stats.data.total = stats.data.total + 1                       -- overall count
    skills.invalidate(skill)                                      -- bar moves at once
    stats.log('%s is now %s', skill, tostring(value))            -- session log line
end

--[[--------------------------------------------------------------------------
  stats.init()

  WHAT  : Starts a session and registers the skill up event.
  WHY   : Must happen once before the main loop.
  WHERE : init.lua startup.
  HOW   : stats.reset, then mq.event with the pattern from skillup.lua.
  WHEN  : Once.
----------------------------------------------------------------------------]]
function stats.init()
    stats.reset()                                                        -- empty session
    mq.event('skm_skillup', 'You have become better at #1#! (#2#)', onSkillUp)  -- game line
end

--[[--------------------------------------------------------------------------
  stats.shutdown()

  WHAT  : Removes the event.
  WHY   : Clean exit; events would otherwise linger until the script ends.
  WHERE : init.lua shutdown.
  HOW   : mq.unevent.
  WHEN  : Once, on exit.
----------------------------------------------------------------------------]]
function stats.shutdown()
    mq.unevent('skm_skillup')  -- same name used in init
end

--[[--------------------------------------------------------------------------
  stats.perHour()

  WHAT  : Skill points gained per hour of running time.
  WHY   : Shown on the Session tab.
  WHERE : ui.drawSession.
  HOW   : total / running hours, 0 for under a minute of running.
  WHEN  : Every frame on that tab.
----------------------------------------------------------------------------]]
function stats.perHour()
    local hours = stats.data.runMs / 3600000                 -- milliseconds to hours
    if hours < (1 / 60) then return 0 end                    -- too early to mean anything
    return stats.data.total / hours
end

return stats  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/stats.lua

  PUBLIC
    data, reset(), log(fmt, ...), count(field), init(), shutdown(), perHour()

  DEPENDENCIES : mq, skillmaster.utils, skillmaster.skills

  HOW TO EDIT SAFELY
    - runMs is added to by runner.tick only while running, so the rate is
      per hour of training, not per hour of the window being open.
    - If the skill up line ever changes in game, update the pattern in
      stats.init; nothing else depends on its wording.
==========================================================================]]--
