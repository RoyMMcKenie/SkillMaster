--[[==========================================================================
  FILE        : skillmaster/config.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.3
  CHANGES     : 1.0.3  New setting beggingRange (default 15): already this
                       close to the Begging NPC means no movement.
                       beggingReturn now defaults to blank (stay put).
                1.0.2  Version number only; no code change.
                1.0.1  Version number only; no code change.
                1.0.0  First release. Replaces the Skills2.ini file and the
                       hard coded tables of skillup.lua with one saved
                       settings file per character.

  WHAT  : Holds every setting the package understands, loads them from a
          per character file at start, and saves them when they change.

  WHY   : Skills2 kept spell choices in Skills2.ini by class, and skillup.lua
          kept everything in code. Neither remembered which skills a given
          character wanted to master. A per character file means each box
          keeps its own ticks, spell overrides and options between sessions.

  WHERE : Required by almost every module. Saved file:
            <MacroQuest>/config/skillmaster_<server>_<character>.lua

  HOW   : config.DEFAULTS lists every key with its starting value. load reads
          the saved file with mq.unpickle (if it exists), copies any missing
          keys in from DEFAULTS, sanity checks numbers, then binds the debug
          getter into utils. save writes the table back with mq.pickle.

  WHEN  : load once at startup. save whenever the window or a command changes
          something (the window debounces saves), and at shutdown.

  READING GUIDE (for future you)
    - mq.pickle(path, table) writes a Lua table to a file; mq.unpickle(path)
      reads it back. Both are part of the MacroQuest Lua API.
    - mq.configDir is the "config" folder inside your MacroQuest install.
    - A "school" is one of the five spell casting skills: Abjuration,
      Alteration, Conjuration, Divination, Evocation.
==========================================================================]]--

local mq    = require('mq')                   -- configDir, pickle, unpickle, TLO
local utils = require('skillmaster.utils')    -- clamp, warn, bindDebugFlag

local config = {}

--[[==========================================================================
  DEFAULTS

  WHAT  : Every setting with its starting value.
  WHY   : One readable list of everything configurable.
  WHERE : config.load merges these into the saved file.
  HOW   : Plain nested table; comments explain each key.
  WHEN  : Read at load.
==========================================================================]]--
config.DEFAULTS = {
    -- Skills ticked to master. Key is the skill key from catalog.lua, value
    -- true. Edited by the Master checkboxes and /skm all, /skm none.
    selected = {},

    -- Spell overrides per school, e.g. { Evocation = 'Burst of Flame' }.
    -- Blank or missing means pick automatically (see spells.choose).
    spellOverride = {},

    -- First spell gem the package may borrow. Gems firstGem..firstGem+4 are
    -- used, one per school being trained, capped at the number of gems the
    -- character has.
    firstGem = 1,
    -- Put the original spells back into the borrowed gems when the run ends.
    restoreGems = true,

    -- Cast through MQ2Cast (/casting) when the plugin is loaded. Off, or
    -- plugin missing, falls back to plain /memspell and /cast.
    useMQ2Cast = true,

    -- Let the MQ2AutoForage plugin do Forage (/startforage, /stopforage)
    -- when it is loaded. Its own ini decides what is kept or destroyed.
    useAutoForage = true,

    -- Meditation. Sit when mana drops below medStartPct and stand again at
    -- medStopPct. Sitting with missing mana is also what raises Meditate.
    medStartPct = 15,
    medStopPct  = 95,

    -- Safety. Stop everything if health drops below this percent.
    stopHpPct = 50,

    -- Pause RGMercs while training (/rgl pause) and unpause at the end,
    -- only if RGMercs is running and only if this package paused it.
    pauseRGMercs = true,

    -- Specialization guard. While no primary specialization is locked in,
    -- stop casting a school whose Specialize skill reaches specGuardValue,
    -- unless that school is specPrimary. Protects against the wrong school
    -- becoming permanent primary by accident.
    specGuard      = true,
    specGuardValue = 50,
    specPrimary    = '',     -- '' means not chosen yet

    -- Summoned items. When a training spell puts a temporary (NoRent) item on
    -- the cursor, destroy it instead of filling bags. Non temporary items are
    -- always put in bags with /autoinventory.
    destroySummoned = true,

    -- Where combat abilities (Kick, Bash, Taunt...) get their target.
    -- 'target' = whatever NPC you have targeted.
    -- 'merc'   = your own mercenary, the method Skills2 used.
    combatTargetSource = 'target',
    -- Walk to the combat target with MQ2Nav when further than this.
    meleeRange = 12,

    -- Begging trip, from Skills2: travel to West Freeport and beg Diggs.
    beggingZone   = 'freeportwest',
    beggingNpc    = 'Diggs',
    -- Already this close to the NPC: do not move at all. Further away but
    -- in the zone: walk straight to the NPC (/nav id), not to the fixed spot.
    beggingRange  = 15,
    beggingLocXY  = { 132, -120 },     -- /nav locxy X Y used by Skills2
    beggingReturn = '',                -- zone to travel to when done; blank stays put

    -- Safe Fall trip, from Skills2: a ledge in the Plane of Knowledge.
    safeFallZone   = 'poknowledge',
    safeFallLocXYZ = { 803, -376, -96 }, -- /nav locxyz X Y Z used by Skills2
    safeFallHoldMs = 1200,               -- how long to hold forward to step off

    -- Stop the run when every ticked skill is mastered, and beep.
    stopWhenDone = true,
    beepWhenDone = true,

    -- Refuse to start while a red (error) conflict is showing.
    blockOnErrors = true,

    -- Extra chat tracing for troubleshooting.
    debug = false,

    -- Window position memory is handled by ImGui; this only remembers
    -- whether the window was open.
    windowOpen = true,
}

--- Live settings -----------------------------------------------------------------
-- WHAT : The settings in use right now.
-- WHY  : Every module reads config.settings.<key>.
-- WHERE: Everywhere.
-- HOW  : Filled by config.load, edited in place by ui.lua and init.lua.
-- WHEN : Valid after config.load.
config.settings = {}

--- Settings file path ----------------------------------------------------------------
-- WHAT : Full path of this character's settings file.
-- WHY  : Each box needs its own file.
-- WHERE: config.load and config.save.
-- HOW  : Built from mq.configDir, the server name and the character name.
-- WHEN : Built in config.load.
config.path = nil

--[[--------------------------------------------------------------------------
  deepCopy(value)

  WHAT  : Returns a copy of a value, copying nested tables too.
  WHY   : Defaults must never be shared with live settings, or editing a
          setting would change the default for the next load.
  WHERE : mergeDefaults.
  HOW   : Recursive copy of tables; other values are returned as is.
  WHEN  : During load.
----------------------------------------------------------------------------]]
local function deepCopy(value)
    -- Plain values (numbers, strings, booleans) need no copying.
    if type(value) ~= 'table' then return value end
    local out = {}                                       -- new table
    for k, v in pairs(value) do out[k] = deepCopy(v) end -- copy every entry
    return out
end

--[[--------------------------------------------------------------------------
  mergeDefaults(target, defaults)

  WHAT  : Copies every key missing from target in from defaults.
  WHY   : A settings file saved by an older version lacks newer keys.
  WHERE : config.load.
  HOW   : One level deep: missing or wrong type keys are replaced by a copy
          of the default. Tables the operator filled (selected, overrides)
          are kept as they are.
  WHEN  : During load.
----------------------------------------------------------------------------]]
local function mergeDefaults(target, defaults)
    -- Walk every known key.
    for k, v in pairs(defaults) do
        if target[k] == nil or type(target[k]) ~= type(v) then
            target[k] = deepCopy(v)  -- missing or wrong type: use the default
        end
    end
end

--[[--------------------------------------------------------------------------
  config.load()

  WHAT  : Loads this character's settings into config.settings.
  WHY   : Restores ticks and options from the last session.
  WHERE : init.lua startup.
  HOW   : Builds the path, mq.unpickle inside pcall (a missing or broken file
          just means defaults), merges defaults, clamps numbers, binds the
          debug getter.
  WHEN  : Once at startup.
----------------------------------------------------------------------------]]
function config.load()
    -- Server and character name make the file unique per box.
    local server = (mq.TLO.EverQuest.Server() or 'server'):gsub('%s', '_')  -- spaces are awkward in file names
    local name   = mq.TLO.Me.CleanName() or 'character'                     -- character first name
    config.path  = string.format('%s/skillmaster_%s_%s.lua', mq.configDir, server, name)

    -- pcall: a missing file is normal on first run and must not crash.
    local ok, loaded = pcall(mq.unpickle, config.path)
    if ok and type(loaded) == 'table' then
        config.settings = loaded             -- use what was saved
    else
        config.settings = {}                 -- first run, start empty
    end
    mergeDefaults(config.settings, config.DEFAULTS)  -- fill any gaps

    -- Sanity check numbers so a hand edited file cannot break the run.
    local s = config.settings
    s.firstGem       = utils.clamp(s.firstGem, 1, 14)        -- EQ has at most 14 gems today
    s.medStartPct    = utils.clamp(s.medStartPct, 0, 99)
    s.medStopPct     = utils.clamp(s.medStopPct, s.medStartPct + 1, 100)  -- stop must be above start
    s.stopHpPct      = utils.clamp(s.stopHpPct, 0, 95)
    s.specGuardValue = utils.clamp(s.specGuardValue, 1, 400)
    s.meleeRange     = utils.clamp(s.meleeRange, 5, 50)
    s.beggingRange   = utils.clamp(s.beggingRange, 5, 50)    -- begging distance
    s.safeFallHoldMs = utils.clamp(s.safeFallHoldMs, 200, 5000)  -- hold long enough to step off, never stuck

    -- Hand utils a getter for the debug flag (avoids a circular require).
    utils.bindDebugFlag(function() return config.settings.debug == true end)
    utils.debug('Settings loaded from %s', config.path)  -- trace the file used
end

--[[--------------------------------------------------------------------------
  config.save()

  WHAT  : Writes config.settings to this character's file.
  WHY   : Keeps ticks and options for next time.
  WHERE : ui.lua (debounced), init.lua commands and shutdown.
  HOW   : mq.pickle inside pcall so a locked file only warns.
  WHEN  : After changes and at shutdown.
----------------------------------------------------------------------------]]
function config.save()
    -- Nothing to save before load has built the path.
    if not config.path then return end
    local ok, err = pcall(mq.pickle, config.path, config.settings)  -- write the table
    if not ok then utils.warn('Could not save settings: %s', tostring(err)) end
end

--[[--------------------------------------------------------------------------
  config.isSelected(key) / config.setSelected(key, on)

  WHAT  : Read or change whether a skill is ticked to master.
  WHY   : Keeps the "selected" table details in one place.
  WHERE : ui.lua, init.lua, runner.lua, conflicts.lua.
  HOW   : true stores the key, false removes it (keeps the file small).
  WHEN  : Every frame (read) and on a checkbox click (write).
----------------------------------------------------------------------------]]
function config.isSelected(key)
    return config.settings.selected[key] == true  -- nil counts as not ticked
end

function config.setSelected(key, on)  -- see doc block above
    config.settings.selected[key] = on and true or nil  -- nil removes the entry
end

return config  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/config.lua

  PUBLIC
    DEFAULTS, settings, path
    load(), save(), isSelected(key), setSelected(key, on)

  DEPENDENCIES : mq, skillmaster.utils

  HOW TO EDIT SAFELY
    - A new option needs: a key in DEFAULTS with a comment, a control in
      ui.drawOptions, and a line in the settings table of ARCHITECTURE.md.
    - If a new numeric option could break the run when silly, clamp it in
      config.load like the others.
==========================================================================]]--
