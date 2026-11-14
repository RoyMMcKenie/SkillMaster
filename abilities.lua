--[[==========================================================================
  FILE        : skillmaster/abilities.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.5
  CHANGES     : 1.0.5  New 'ledge' requirement: Safe Fall waits until the ledge
                       and landing spot are recorded.
                1.0.4  Version number only; no code change.
                1.0.3  Version number only; no code change.
                1.0.2  Tracking is pressed whenever it is ready and no
                       longer waits for or closes the Tracking window.
                1.0.1  Version number only; no code change.
                1.0.0  First release. Brings together the ability handling of
                       Skills2 (Sneak and Hide pressed twice, Feign Death then
                       stand, Tracking, mercenary as a
                       combat target, Bash only with a shield) and adds
                       MQ2AutoForage, MQ2Nav walking to the target, and
                       equipment checks.

  WHAT  : Presses skill abilities: utility ones that need no target (Forage,
          Mend, Sneak, Hide, Feign Death, Tracking, Sense Traps, Bind Wound,
          Fishing) and combat ones that need something to hit (Kick, Bash,
          Slam, monk strikes, Frenzy, Backstab, Disarm, Taunt, Intimidation).
          Also finds and approaches the combat target.

  WHY   : Abilities are cheap to press and have their own reuse timers, so
          the runner presses every ready one each tick alongside casting.
          Keeping the per method details here keeps the runner short.

  WHERE : Called by runner.lua each tick. conflicts.lua and ui.lua use the
          requirement checks to explain why something is waiting.

  HOW   : Every press is /doability "<name>"
          (https://docs.macroquest.org/reference/commands/doability/),
          guarded by Me.AbilityReady. Methods:
            ability   press once
            toggle    press, wait 1 second, press again (Skills2 behaviour)
            feign     press, wait, /stand (Skills2 behaviour)
            tracking  press whenever ready; each press refreshes the list
                      and can raise the skill. The Tracking window is left
                      as it is, open or closed.
            forage    /startforage once when MQ2AutoForage is loaded and the
                      option is on, else press and put the item in bags
            combat    target, walk into range with MQ2Nav, /face, press

  WHEN  : Each runner tick while a run is active.

  READING GUIDE (for future you)
    - Slot names 'mainhand' and 'offhand' are MacroQuest inventory slot
      names: https://docs.macroquest.org/reference/general/slot-names/
    - The mercenary as a combat target is what Skills2 did. Whether the game
      lets abilities land on your own mercenary is not verified; the default
      is your own NPC target.
==========================================================================]]--

local mq      = require('mq')                   -- TLO
local utils   = require('skillmaster.utils')    -- cmd, delay, lower
local config  = require('skillmaster.config')   -- settings
local plugins = require('skillmaster.plugins')  -- MQ2AutoForage, MQ2Nav
local skills  = require('skillmaster.skills')   -- abilityReady
local stats   = require('skillmaster.stats')    -- counters
local spells  = require('skillmaster.spells')   -- clearCursor

local abilities = {}

--- MQ2AutoForage state ----------------------------------------------------------
-- WHAT : True after this package sent /startforage.
-- WHY  : Send /stopforage only if we started it.
-- WHERE: pressForage, abilities.stopForage.
-- HOW  : Boolean.
-- WHEN : Set on the first Forage tick of a run.
abilities.autoForageStarted = false

--- Last wait reason ----------------------------------------------------------------
-- WHAT : waiting[key] = text explaining why a ticked ability was skipped.
-- WHY  : The Train tab shows it next to the skill.
-- WHERE: Set by abilities.train, read by ui.lua.
-- HOW  : Cleared each time the ability is pressed.
-- WHEN : Every tick.
abilities.waiting = {}

--[[--------------------------------------------------------------------------
  abilities.hasShield()

  WHAT  : True when the off hand holds a shield.
  WHY   : Bash needs a shield (Skills2 checked this too).
  WHERE : abilities.requirement, conflicts.lua.
  HOW   : Me.Inventory('offhand').Type() equals 'Shield'.
  WHEN  : Before pressing Bash and when building warnings.
----------------------------------------------------------------------------]]
function abilities.hasShield()
    return mq.TLO.Me.Inventory('offhand').Type() == 'Shield'  -- item type of the off hand
end

--[[--------------------------------------------------------------------------
  abilities.hasFishingGear()

  WHAT  : True when a fishing pole is in the main hand and bait is carried.
  WHY   : Fishing does nothing without both.
  WHERE : abilities.requirement.
  HOW   : Main hand item Type 'Fishing Pole' (or name contains Fishing Pole)
          and FindItemCount('Fishing Bait') above zero.
  WHEN  : Before pressing Fishing.
----------------------------------------------------------------------------]]
function abilities.hasFishingGear()
    local main = mq.TLO.Me.Inventory('mainhand')                          -- held weapon
    local pole = main.Type() == 'Fishing Pole' or (main.Name() or ''):find('Fishing Pole') ~= nil
    local bait = (tonumber(mq.TLO.FindItemCount('Fishing Bait')()) or 0) > 0  -- any bait
    return pole and bait
end

--[[--------------------------------------------------------------------------
  abilities.combatTarget()

  WHAT  : Returns the spawn ID combat abilities and harmful spells should
          use, or nil and a reason.
  WHY   : Combat skills need something to hit. Two sources are offered:
          your own NPC target (default) or your mercenary (Skills2 method).
  WHERE : abilities.train, runner.lua (harmful spells), conflicts.lua.
  HOW   : 'target': Target exists, Type is NPC, not dead.
          'merc'  : Me.Mercenary() is 'ACTIVE' and Mercenary.ID() exists.
  WHEN  : Each tick.
----------------------------------------------------------------------------]]
function abilities.combatTarget()
    -- Mercenary mode, as Skills2 did.
    if config.settings.combatTargetSource == 'merc' then
        if mq.TLO.Me.Mercenary() ~= 'ACTIVE' then return nil, 'mercenary not active' end
        local id = mq.TLO.Mercenary.ID()                                  -- merc spawn id
        if not id or id == 0 then return nil, 'mercenary not found' end
        return id
    end
    -- Default: whatever NPC the operator targeted.
    local id = mq.TLO.Target.ID()                                         -- current target
    if not id or id == 0 then return nil, 'no target' end
    if mq.TLO.Target.Type() ~= 'NPC' then return nil, 'target is not an NPC' end
    if mq.TLO.Target.Dead() == true then return nil, 'target is dead' end
    return id  -- merc spawn id
end

--[[--------------------------------------------------------------------------
  abilities.approach(id)

  WHAT  : Targets the spawn, walks into melee range if needed and faces it.
          Returns true when in range.
  WHY   : Combat abilities fail out of range.
  WHERE : abilities.train (combat), runner.lua before a harmful spell
          (only targeting and facing are needed there).
  HOW   : /mqtarget id N, then if Spawn distance exceeds meleeRange and
          MQ2Nav has a mesh: /nav id N, wait up to 10 s, /nav stop.
          Finally /face fast id N
          (https://docs.macroquest.org/reference/commands/face/).
  WHEN  : Before each combat press.
----------------------------------------------------------------------------]]
function abilities.approach(id, needRange)
    -- Target it first; abilities act on the current target.
    if mq.TLO.Target.ID() ~= id then
        utils.cmd('/mqtarget id %d', id)                                     -- spawn search by id
        utils.delay(1000, function() return mq.TLO.Target.ID() == id end)
    end
    local range = config.settings.meleeRange                                -- allowed distance
    local dist = function() return tonumber(mq.TLO.Spawn('id ' .. id).Distance()) or 999 end  -- live distance
    if needRange and dist() > range then
        if not plugins.navReady() then return false end                     -- cannot walk there
        utils.cmd('/nav id %d', id)                                         -- MQ2Nav to the spawn
        utils.delay(10000, function() return dist() <= range end)
        utils.cmd('/nav stop')                                              -- stop beside it
    end
    utils.cmd('/face fast id %d', id)                                       -- turn to it
    return (not needRange) or dist() <= range
end

--[[--------------------------------------------------------------------------
  abilities.requirement(entry)

  WHAT  : Returns nil when the entry's needs are met, else a reason text.
  WHY   : One explanation used by the runner, the Train tab and warnings.
  WHERE : abilities.train, conflicts.lua.
  HOW   : Checks each tag in entry.needs.
  WHEN  : Each tick and each frame.
----------------------------------------------------------------------------]]
function abilities.requirement(entry)
    -- No needs at all is the common case.
    for _, need in ipairs(entry.needs or {}) do
        if need == 'shield' and not abilities.hasShield() then return 'needs a shield equipped' end
        if need == 'bandages' and (tonumber(mq.TLO.FindItemCount('Bandages')()) or 0) == 0 then
            return 'needs Bandages'  -- no bandages carried
        end
        if need == 'fishing' and not abilities.hasFishingGear() then return 'needs fishing pole and bait' end  -- pole in main hand and bait in bags
        if need == 'freeSlot' and (tonumber(mq.TLO.Me.FreeInventory()) or 0) == 0 then return 'bags are full' end  -- no room for a foraged or caught item
        if need == 'nav' and not plugins.has('MQ2Nav') then return 'needs MQ2Nav' end  -- trips walk with MQ2Nav
        if need == 'easyfind' and not plugins.has('MQ2EasyFind') then return 'needs MQ2EasyFind' end  -- trips zone with MQ2EasyFind
        if need == 'ledge' and not config.safeFallReady() then  -- Safe Fall spot not recorded
            return 'ledge not set: stand on a ledge and press Set ledge here in Options'
        end
        if need == 'npcTarget' then  -- combat skills need something to hit
            local id, why = abilities.combatTarget()                           -- someone to hit?
            if not id then return why end
        end
    end
    return nil  -- every need met
end

--[[--------------------------------------------------------------------------
  press(name)

  WHAT  : Sends /doability "<name>" and counts it.
  WHY   : Every method ends in this one command.
  WHERE : abilities.train.
  HOW   : utils.cmd then stats.count.
  WHEN  : When the ability is ready.
----------------------------------------------------------------------------]]
local function press(name)
    utils.cmd('/doability "%s"', name)   -- MacroQuest: activate ability by name
    stats.count('abilities')            -- session counter
end

--[[--------------------------------------------------------------------------
  pressForage(entry)

  WHAT  : Trains Forage.
  WHY   : MQ2AutoForage keeps or destroys items by its own ini and forages
          every time the skill is ready, so it is preferred when loaded.
  WHERE : abilities.train.
  HOW   : Plugin path: /startforage once per run (it keeps going on its
          own; it needs Forage on an Abilities page). Plain path: press,
          wait for the cursor, /autoinventory it.
  WHEN  : Each tick Forage is ticked.
----------------------------------------------------------------------------]]
local function pressForage(entry)
    -- Plugin path.
    if config.settings.useAutoForage and plugins.has('MQ2AutoForage') then
        if not abilities.autoForageStarted then
            utils.cmd('/startforage')                                   -- MQ2AutoForage takes over
            abilities.autoForageStarted = true
            stats.log('MQ2AutoForage started')
        end
        return true  -- MQ2AutoForage is handling it
    end
    -- Plain path.
    if not skills.abilityReady(entry.name) then return false end        -- reuse timer running
    press(entry.name)
    utils.delay(1500, function() return mq.TLO.Cursor.ID() ~= nil end) -- foraged item lands on the cursor
    spells.clearCursor(false)                                           -- keep it in bags
    return true
end

--[[--------------------------------------------------------------------------
  abilities.stopForage()

  WHAT  : Sends /stopforage if this run started MQ2AutoForage.
  WHY   : Leaves the plugin as it was found.
  WHERE : runner.stop.
  HOW   : Flag check then command.
  WHEN  : End of a run.
----------------------------------------------------------------------------]]
function abilities.stopForage()
    -- Only stop what we started.
    if abilities.autoForageStarted then
        utils.cmd('/stopforage')            -- MQ2AutoForage stop command
        abilities.autoForageStarted = false
    end
end

--[[--------------------------------------------------------------------------
  abilities.train(entry)

  WHAT  : Tries one press of a utility or combat entry. Returns true when
          something was pressed (or MQ2AutoForage is handling it).
  WHY   : The runner calls this for each ticked ability every tick.
  WHERE : runner.lua.
  HOW   : Requirement check, ready check, then the method's steps (see the
          file header). Records the wait reason in abilities.waiting.
  WHEN  : Each tick.
----------------------------------------------------------------------------]]
function abilities.train(entry)
    local why = abilities.requirement(entry)                       -- anything missing?
    if why then abilities.waiting[entry.key] = why return false end
    if entry.method == 'forage' then
        abilities.waiting[entry.key] = nil
        return pressForage(entry)  -- forage has its own path
    end
    local name = entry.ability or entry.name                       -- Slam presses Slam, raises Bash
    if not skills.abilityReady(name) then
        abilities.waiting[entry.key] = 'not ready'
        return false
    end
    abilities.waiting[entry.key] = nil                             -- ready and able

    if entry.method == 'toggle' then
        press(name)                                                 -- on (or off)
        utils.delay(1000)                                           -- Skills2 used a one second pause
        utils.cmd('/doability "%s"', name)                          -- back to how we started
    elseif entry.method == 'feign' then
        if mq.TLO.Me.CombatState() == 'COMBAT' then                 -- never fake death mid fight
            abilities.waiting[entry.key] = 'in combat'
            return false
        end
        press(name)  -- feign
        utils.delay(1500, function() return mq.TLO.Me.Feigning() == true end)  -- wait until the game shows us feigned
        utils.cmd('/stand')                                         -- get up again
    elseif entry.method == 'tracking' then
        -- Each press refreshes the tracking list and is a chance to raise
        -- Tracking. Whether the Tracking window is open or closed does not
        -- matter, so the window is never waited for or touched.
        press(name)  -- /doability Tracking
    elseif entry.method == 'combat' then
        local id = abilities.combatTarget()                         -- checked in requirement already
        if not abilities.approach(id, true) then
            abilities.waiting[entry.key] = 'cannot reach target'
            return false
        end
        press(name)  -- the combat ability
    else
        press(name)                                                 -- plain ability
        if entry.key == 'fishing' then
            utils.delay(2000, function() return mq.TLO.Cursor.ID() ~= nil end)  -- a catch lands on the cursor
            spells.clearCursor(false)                               -- keep the catch
        end
    end
    return true
end

return abilities  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/abilities.lua

  PUBLIC
    autoForageStarted, waiting
    hasShield(), hasFishingGear(), combatTarget(), approach(id, needRange),
    requirement(entry), stopForage(), train(entry)

  DEPENDENCIES : mq, skillmaster.utils, config, plugins, skills, stats, spells

  HOW TO EDIT SAFELY
    - Every press must stay behind skills.abilityReady, or chat fills with
      "You can not use this ability right now".
    - Feign Death checks CombatState so it never drops aggro onto a group.
==========================================================================]]--
