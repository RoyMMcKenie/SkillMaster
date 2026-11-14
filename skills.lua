--[[==========================================================================
  FILE        : skillmaster/skills.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.0
  CHANGES     : 1.0.0  First release. Replaces the class and race tables of
                       skillup.lua with live checks of the character's own
                       skill caps, so any class, race and level works.

  WHAT  : Reads current skill values and caps from the game and answers
          "can this character train this", "is it mastered", and "how far
          along is it". Also lists every skill the character has for the
          All Skills tab.

  WHY   : skillup.lua decided availability from hand made class and race
          tables, which miss AA granted skills and level gates. The game
          already knows: Me.SkillCap is above zero only for skills this
          character can raise right now. Using it means the list is always
          right without upkeep.

  WHERE : Used by runner.lua (what still needs work), conflicts.lua,
          stats.lua (baseline values) and ui.lua (progress bars).

  HOW   : mq.TLO.Me.Skill(name) and mq.TLO.Me.SkillCap(name) per skill.
          mq.TLO.Skill(id).Name() to walk every skill id for the All Skills
          tab. Values are cached for half a second because the window
          redraws many times a second.

  WHEN  : Every frame (cached) and every runner tick.

  READING GUIDE (for future you)
    - "cap" is the most this character can have at its current level; it
      rises as you level. "mastered" means current equals cap, which is the
      most you can do today.
    - Specialize caps fall after a primary specialization is locked in, so
      the cap shown for the other four is the real limit.
==========================================================================]]--

local mq      = require('mq')                   -- TLO access
local utils   = require('skillmaster.utils')    -- now
local catalog = require('skillmaster.catalog')  -- skill entries

local skills = {}

--- Value cache ------------------------------------------------------------------
-- WHAT : cache[skill name] = { cur, cap, at }.
-- WHY  : The window asks for every skill every frame.
-- WHERE: skills.value.
-- HOW  : Entries older than CACHE_MS are reread.
-- WHEN : Filled on demand.
local cache    = {}    -- skill name -> { cur = n, cap = n, at = ms }
local CACHE_MS = 500   -- half a second is fresh enough for a progress bar

--[[--------------------------------------------------------------------------
  skills.value(name)

  WHAT  : Returns current value and cap for a skill name (both numbers,
          0 when the game has nothing).
  WHY   : Everything else in this module is built on these two numbers.
  WHERE : This module, stats.lua, conflicts.lua, ui.lua.
  HOW   : Cache lookup, else Me.Skill(name)() and Me.SkillCap(name)().
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function skills.value(name)
    local now = utils.now()                      -- current time for the cache test
    local c = cache[name]                        -- cached entry, may be nil
    if c and now - c.at < CACHE_MS then return c.cur, c.cap end  -- still fresh
    local cur = tonumber(mq.TLO.Me.Skill(name)()) or 0           -- current value
    local cap = tonumber(mq.TLO.Me.SkillCap(name)()) or 0        -- cap at this level
    cache[name] = { cur = cur, cap = cap, at = now }             -- remember
    return cur, cap
end

--[[--------------------------------------------------------------------------
  skills.invalidate(name)

  WHAT  : Drops the cached value for one skill, or all when name is nil.
  WHY   : After a skill up message the bar should move at once.
  WHERE : stats.lua skill up event.
  HOW   : Clears the cache entry.
  WHEN  : On a skill up.
----------------------------------------------------------------------------]]
function skills.invalidate(name)
    -- nil means everything, e.g. after leveling.
    if name == nil then cache = {} else cache[name] = nil end
end

--[[--------------------------------------------------------------------------
  skills.known(entry)

  WHAT  : True when the game recognises the entry's skill name.
  WHY   : A typo or a removed skill would otherwise show as "0 of 0".
  WHERE : skills.available, ui.lua.
  HOW   : mq.TLO.Skill(name).ID() is nil for unknown names.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function skills.known(entry)
    return mq.TLO.Skill(entry.name).ID() ~= nil  -- nil means no such skill
end

--[[--------------------------------------------------------------------------
  skills.available(entry)

  WHAT  : True when this character can raise the skill right now.
  WHY   : Unavailable skills are greyed out in the window and skipped.
  WHERE : runner.lua, conflicts.lua, ui.lua.
  HOW   : Cap above zero. Slam additionally needs the Slam ability to exist
          (Me.Ability returns a slot number when it does).
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function skills.available(entry)
    -- Manual only entries can still be watched, so use the cap like others.
    local _, cap = skills.value(entry.name)                        -- cap at this level
    if cap <= 0 then return false end                              -- cannot raise it
    if entry.ability and entry.ability ~= entry.name then
        return mq.TLO.Me.Ability(entry.ability)() ~= nil           -- e.g. Slam must exist
    end
    return true
end

--[[--------------------------------------------------------------------------
  skills.mastered(entry)

  WHAT  : True when current value has reached the cap.
  WHY   : Mastered skills are skipped and ticked rows turn green.
  WHERE : runner.lua, ui.lua.
  HOW   : cur >= cap with cap above zero.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function skills.mastered(entry)
    local cur, cap = skills.value(entry.name)   -- live numbers
    return cap > 0 and cur >= cap               -- zero cap is "not available", not mastered
end

--[[--------------------------------------------------------------------------
  skills.fraction(entry)

  WHAT  : Progress from 0 to 1 for the progress bar.
  WHY   : ImGui.ProgressBar wants a fraction.
  WHERE : ui.drawTrain.
  HOW   : cur / cap, 0 when cap is 0.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
function skills.fraction(entry)
    local cur, cap = skills.value(entry.name)    -- live numbers
    if cap <= 0 then return 0 end                -- avoid dividing by zero
    return math.min(1, cur / cap)                -- never more than full
end

--[[--------------------------------------------------------------------------
  skills.abilityReady(name)

  WHAT  : True when an ability's reuse timer is up.
  WHY   : Pressing an ability that is not ready does nothing and spams chat.
  WHERE : abilities.lua.
  HOW   : mq.TLO.Me.AbilityReady(name)().
  WHEN  : Before each press.
----------------------------------------------------------------------------]]
function skills.abilityReady(name)
    return mq.TLO.Me.AbilityReady(name)() == true  -- false when unknown too
end

--[[--------------------------------------------------------------------------
  skills.allSkills()

  WHAT  : Returns a sorted list of every skill this character has a cap in:
          { name, cur, cap, tracked } where tracked means the catalog knows
          how to train it.
  WHY   : The All Skills tab shows everything, including tradeskills and
          languages the package does not train, so the operator sees the
          whole picture.
  WHERE : ui.drawAllSkills (refreshed by its button, not every frame).
  HOW   : Walks Skill ids 0 to 120 with mq.TLO.Skill(id).Name(); keeps the
          ones whose Me.SkillCap is above zero.
  WHEN  : When the All Skills tab is opened or refreshed.
----------------------------------------------------------------------------]]
function skills.allSkills()
    -- Names the catalog trains, so the tab can mark them.
    local tracked = {}
    for _, e in ipairs(catalog.SKILLS) do tracked[e.name] = true end
    local out = {}                                     -- result list
    for id = 0, 120 do                                 -- skill ids in use today sit well below 120
        local name = mq.TLO.Skill(id).Name()           -- nil for unused ids
        if name and name ~= '' then
            local cur = tonumber(mq.TLO.Me.Skill(id)()) or 0      -- current value
            local cap = tonumber(mq.TLO.Me.SkillCap(id)()) or 0   -- cap at this level
            if cap > 0 then
                out[#out + 1] = { name = name, cur = cur, cap = cap, tracked = tracked[name] == true }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)  -- alphabetical
    return out
end

return skills  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/skills.lua

  PUBLIC
    value(name), invalidate(name), known(entry), available(entry),
    mastered(entry), fraction(entry), abilityReady(name), allSkills()

  DEPENDENCIES : mq, skillmaster.utils, skillmaster.catalog

  HOW TO EDIT SAFELY
    - Keep the cache. Reading forty skills every frame from the game is the
      kind of thing that makes a window stutter.
    - If a skill shows 0 of 0 that should not, check its name with
      /echo ${Skill[<name>].ID} in game.
==========================================================================]]--
