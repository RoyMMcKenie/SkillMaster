--[[==========================================================================
  FILE        : skillmaster/core.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.1.0
  CHANGES     : 1.1.0  Consolidation. utils.lua, config.lua and plugins.lua were
                       merged into this one file as sections. Code is
                       unchanged; each section keeps its own doc block,
                       history and private locals (do ... end scope).
                1.0.0 to 1.0.5  See the HISTORY line of each section and
                       CHANGELOG.md.

  CREDITS     : config section: the saved per class spell choices replace
                Skills2.ini from Skills2 0.4.2 by Blasty (RedGuides resource
                2302) and the hard coded tables of Skill Skillup 1.1,
                skillup.lua, by GoldenFrog (RedGuides resource 2937). utils
                and plugins are original to SkillMaster. Full lineage in
                README, Credits and attribution.

  WHAT  : The foundation every other file stands on. Three sections:
            utils    chat output, the one traced command sender (utils.cmd),
                     the abortable delay and small helpers
            config   defaults and the per character settings file
            plugins  which optional plugins and scripts are loaded, and the
                     RGMercs pause / unpause hand off

  WHY   : These three were always loaded together, required by almost every
          module, and depend on nothing in the package except each other in
          one direction (utils <- config, utils <- plugins). One file means
          one require at the top of each consumer and one place to look
          for "how does SkillMaster talk to MacroQuest".

  WHERE : <MacroQuest>/lua/skillmaster/core.lua
          Required by data.lua, actions.lua, engine.lua, ui.lua, init.lua.

  HOW   : local core = require('skillmaster.core')
          local utils, config, plugins = core.utils, core.config, core.plugins
          Sections run top to bottom in dependency order, so utils exists
          before config and plugins use it.

  WHEN  : Loaded once, the first time anything requires it, at /lua run
          skillmaster.

  READING GUIDE (for future you)
    - Rule kept from 1.0.x: nothing in this file requires another
      SkillMaster file. core is the bottom of the dependency graph.
    - "core.lua/config" in comments means the config section of this file.
==========================================================================]]--

local mq = require('mq')   -- MacroQuest Lua API: cmd, delay, TLO, gettime, pickle

-- Section tables, declared up front so every section below (and the
-- return at the bottom) can see them. Each is filled inside its own
-- do ... end block, which keeps that section's private locals private.
local utils     = {}   -- utils section, see its block below
local config    = {}   -- config section, see its block below
local plugins   = {}   -- plugins section, see its block below

--[[==========================================================================
  SECTION     : utils   (was skillmaster/utils.lua up to 1.0.5)
  HISTORY     : 1.0.5  Version number only; no code change.
                1.0.4  Version number only; no code change.
                1.0.3  Version number only; no code change.
                1.0.2  Version number only; no code change.
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
do  -- utils section scope: locals declared here stay inside it
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
    -- HOW  : engine.lua/runner binds its own test through utils.bindAbortFlag.
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
      WHERE : engine.lua/runner at load time.
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
      WHERE : actions.lua/spells, actions.lua/abilities, actions.lua/travel, engine.lua/runner.
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
      WHERE : data.lua/stats, ui.lua, engine.lua/runner.
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
      WHERE : data.lua/skills, actions.lua/travel, actions.lua/abilities.
      HOW   : tostring then string.lower.
      WHEN  : Before a case insensitive comparison.
    ----------------------------------------------------------------------------]]
    function utils.lower(text)
        -- nil becomes '' so callers never need their own nil check.
        if text == nil then return '' end
        return string.lower(tostring(text))  -- plain lower case copy
    end
end  -- of the utils section

--[[==========================================================================
  END OF SECTION : utils

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

--[[==========================================================================
  SECTION     : config   (was skillmaster/config.lua up to 1.0.5)
  CREDITS     : Skills2.ini spell choices (Blasty, Skills2 0.4.2); class
                tables (GoldenFrog, Skill Skillup 1.1).
  HISTORY     : 1.0.5  Safe Fall: the Skills2 Plane of Knowledge ledge is
                       gone (no fall damage in PoK). New safeFallLedge and
                       safeFallLanding recorded from Options. Old
                       safeFallLocXYZ and beggingLocXY are removed on load.
                1.0.4  Version number only; no code change.
                1.0.3  New setting beggingRange (default 15): already this
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
do  -- config section scope: locals declared here stay inside it
    --[[==========================================================================
      DEFAULTS

      WHAT  : Every setting with its starting value.
      WHY   : One readable list of everything configurable.
      WHERE : config.load merges these into the saved file.
      HOW   : Plain nested table; comments explain each key.
      WHEN  : Read at load.
    ==========================================================================]]--
    config.DEFAULTS = {
        -- Skills ticked to master. Key is the skill key from data.lua/catalog, value
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
        -- in the zone: walk straight to the NPC (/nav id).
        beggingRange  = 15,
        beggingReturn = '',                -- zone to travel to when done; blank stays put

        -- Safe Fall trip. Recorded by you in Options: stand on the edge and
        -- press Set ledge here, drop, press Set landing spot here. Each is
        -- { y, x, z } from Me.Y, Me.X, Me.Z. Empty means not set; the trip
        -- will not run until both are set. The Skills2 Plane of Knowledge
        -- ledge was removed: PoK no longer gives falling damage.
        safeFallZone    = '',               -- zone short name the ledge is in
        safeFallLedge   = {},               -- { y, x, z } where you step off
        safeFallLanding = {},               -- { y, x, z } where you land
        safeFallHoldMs  = 1200,             -- how long to hold forward to step off

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

        -- Settings files from 1.0.4 and earlier carry the Skills2 PoK ledge
        -- (safeFallZone poknowledge, safeFallLocXYZ) and the Begging spot
        -- (beggingLocXY). Drop them; PoK no longer gives falling damage and
        -- the Begging spot used an undocumented /nav form.
        if s.safeFallLocXYZ ~= nil then
            s.safeFallLocXYZ = nil                                          -- old key
            if s.safeFallZone == 'poknowledge' then s.safeFallZone = '' end -- old default zone
        end
        s.beggingLocXY = nil                                                -- old key
        if type(s.safeFallLedge) ~= 'table' then s.safeFallLedge = {} end   -- always a table
        if type(s.safeFallLanding) ~= 'table' then s.safeFallLanding = {} end  -- always a table

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
      WHERE : ui.lua, init.lua, engine.lua/runner, engine.lua/conflicts.
      HOW   : true stores the key, false removes it (keeps the file small).
      WHEN  : Every frame (read) and on a checkbox click (write).
    ----------------------------------------------------------------------------]]
    function config.isSelected(key)
        return config.settings.selected[key] == true  -- nil counts as not ticked
    end

    function config.setSelected(key, on)  -- see doc block above
        config.settings.selected[key] = on and true or nil  -- nil removes the entry
    end

    --[[--------------------------------------------------------------------------
      config.safeFallReady()

      WHAT  : True when the Safe Fall zone, ledge and landing spot are recorded.
      WHY   : The trip, the Train tab and the warnings all need the same test.
      WHERE : abilities.requirement ('ledge' tag), engine.lua/conflicts, ui.lua.
      HOW   : Zone set and both tables hold three numbers.
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function config.safeFallReady()
        local s = config.settings
        return s.safeFallZone ~= '' and #s.safeFallLedge == 3 and #s.safeFallLanding == 3  -- all recorded
    end
end  -- of the config section

--[[==========================================================================
  END OF SECTION : config

  PUBLIC
    DEFAULTS, settings, path
    load(), save(), isSelected(key), setSelected(key, on), safeFallReady()

  DEPENDENCIES : mq, core.lua/utils

  HOW TO EDIT SAFELY
    - A new option needs: a key in DEFAULTS with a comment, a control in
      ui.drawOptions, and a line in the settings table of ARCHITECTURE.md.
    - If a new numeric option could break the run when silly, clamp it in
      config.load like the others.
==========================================================================]]--

--[[==========================================================================
  SECTION     : plugins   (was skillmaster/plugins.lua up to 1.0.5)
  HISTORY     : 1.0.5  Command list: /nav locyxz; /nav locxy removed.
                1.0.4  Version number only; no code change.
                1.0.3  Version number only; no code change.
                1.0.2  Version number only; no code change.
                1.0.1  Version number only; no code change.
                1.0.0  First release. New module; neither source script
                       checked which plugins were loaded.

  WHAT  : Answers "is this plugin or script available right now" for every
          helper the package can use: MQ2Cast, MQ2Nav (and its mesh),
          MQ2EasyFind, MQ2AutoForage, and the RGMercs Lua script. Also
          pauses and unpauses RGMercs.

  WHY   : The request was to use existing plugins as much as possible. Each
          plugin is optional; when one is missing the package falls back to
          plain EverQuest commands or disables the feature and says why,
          instead of sending a command nobody is listening for.

  WHERE : Read by actions.lua/spells (MQ2Cast), actions.lua/abilities (MQ2AutoForage,
          MQ2Nav), actions.lua/travel (MQ2EasyFind, MQ2Nav), engine.lua/runner (RGMercs),
          engine.lua/conflicts and ui.lua (status display).

  HOW   : mq.TLO.Plugin(name).IsLoaded() for plugins,
          mq.TLO.Lua.Script(name).Status() for Lua scripts,
          mq.TLO.Navigation.MeshLoaded() for the nav mesh.
          Results are cached for one second because the window asks every
          frame.

  WHEN  : Every frame (cached) and before each action that needs a plugin.

  READING GUIDE (for future you)
    Commands each plugin provides, all from their published docs:
      MQ2Cast       /casting "Spell|gemN" -maxtries|N -targetid|ID, /interrupt
                    https://docs.macroquest.org/plugins/community-plugins/mq2cast/
      MQ2Nav        /nav target, /nav id N, /nav locyxz Y X Z, /nav stop
                    (/nav locxy is not in the reference and is not used)
                    https://github-wiki-see.page/m/brainiac/MQ2Nav/wiki/Command-Reference
      MQ2EasyFind   /travelto <zone>, /travelto stop
                    https://www.redguides.com/docs/projects/mq2easyfind/cmd-travelto/
      MQ2AutoForage /startforage, /stopforage
                    https://docs.macroquest.org/plugins/community-plugins/mq2autoforage/
      RGMercs (Lua) /rgl pause, /rgl unpause
                    https://github.com/DerpleDude/rgmercs/blob/c94847de7dda44123d5b5693049547541df75d87/utils/binds.lua#L567-L589
                    (/rgl reaches the /rglua bind by MacroQuest's command prefix match)
==========================================================================]]--
do  -- plugins section scope: locals declared here stay inside it
    --- Plugin descriptions ----------------------------------------------------------
    -- WHAT : The helpers checked, with what the package uses each for.
    -- WHY  : The Options tab lists them so the operator knows what is missing.
    -- WHERE: plugins.refresh, ui.drawOptions.
    -- HOW  : Array of id, kind ('plugin' or 'lua') and purpose text.
    -- WHEN : Read on refresh and when drawing.
    plugins.LIST = {
        { id = 'MQ2Cast',       kind = 'plugin', purpose = 'Reliable casting with retries and result codes.' },   -- /casting
        { id = 'MQ2Nav',        kind = 'plugin', purpose = 'Walking to targets and to the Begging and Safe Fall spots.' }, -- /nav
        { id = 'MQ2EasyFind',   kind = 'plugin', purpose = 'Zone to zone travel for Begging and Safe Fall.' },    -- /travelto
        { id = 'MQ2AutoForage', kind = 'plugin', purpose = 'Forage with keep and destroy lists.' },                -- /startforage
        { id = 'rgmercs',       kind = 'lua',    purpose = 'Paused during training so it does not fight the script.' }, -- /rgl
    }

    --- Cache ------------------------------------------------------------------------
    -- WHAT : Last known state of each helper and when it was read.
    -- WHY  : TLO reads every frame for five helpers is wasteful.
    -- WHERE: plugins.refresh, plugins.has.
    -- HOW  : state[id] = true/false; stamp = time of the last refresh.
    -- WHEN : Refreshed at most once a second.
    local state = {}   -- id -> loaded?
    local stamp = -1   -- utils.now() of the last refresh, -1 means never
    local mesh  = false -- MQ2Nav mesh loaded for this zone?

    --- Paused-by-us flag ---------------------------------------------------------------
    -- WHAT : True when this package sent /rgl pause.
    -- WHY  : Only unpause RGMercs if we paused it, never one the operator paused.
    -- WHERE: plugins.pauseRGMercs, plugins.unpauseRGMercs.
    -- HOW  : Boolean.
    -- WHEN : Set on start, cleared on stop.
    plugins.pausedRGMercs = false

    --[[--------------------------------------------------------------------------
      plugins.refresh(force)

      WHAT  : Rereads every helper's loaded state and the nav mesh state.
      WHY   : Plugins can be loaded or unloaded while the script runs.
      WHERE : plugins.has (automatically), ui.lua Rescan button (forced).
      HOW   : Skips if less than a second has passed unless force is true.
              Plugin(name).IsLoaded() for plugins; Lua.Script(name).Status()
              equal to 'RUNNING' for Lua scripts (the same test the project's
              other packages use for RGMercs).
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function plugins.refresh(force)
        -- Debounce: once a second is plenty for something that rarely changes.
        if not force and stamp >= 0 and utils.now() - stamp < 1000 then return end
        stamp = utils.now()                                   -- remember when we looked
        for _, p in ipairs(plugins.LIST) do
            if p.kind == 'plugin' then
                state[p.id] = mq.TLO.Plugin(p.id).IsLoaded() == true          -- plugin check
            else
                state[p.id] = mq.TLO.Lua.Script(p.id).Status() == 'RUNNING'  -- Lua script check
            end
        end
        -- The mesh only matters when MQ2Nav itself is loaded.
        mesh = state['MQ2Nav'] and mq.TLO.Navigation.MeshLoaded() == true or false
    end

    --[[--------------------------------------------------------------------------
      plugins.has(id)

      WHAT  : True when the named helper is loaded (or running, for Lua).
      WHY   : Every optional feature asks this before acting.
      WHERE : Throughout the package.
      HOW   : refresh (debounced) then read the cache.
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function plugins.has(id)
        plugins.refresh(false)       -- cheap when called often
        return state[id] == true     -- unknown ids count as missing
    end

    --[[--------------------------------------------------------------------------
      plugins.navReady()

      WHAT  : True when MQ2Nav is loaded and has a mesh for this zone.
      WHY   : /nav does nothing without a mesh; the run must know before trying.
      WHERE : actions.lua/abilities, actions.lua/travel, engine.lua/conflicts.
      HOW   : refresh then read the cached mesh flag.
      WHEN  : Before any /nav command.
    ----------------------------------------------------------------------------]]
    function plugins.navReady()
        plugins.refresh(false)   -- keep the cache fresh
        return mesh == true      -- false when no MQ2Nav or no mesh
    end

    --[[--------------------------------------------------------------------------
      plugins.pauseRGMercs()

      WHAT  : Sends /rgl pause if RGMercs is running.
      WHY   : RGMercs would otherwise sit, stand, target and cast on its own,
              fighting the training run.
      WHERE : runner.start when the Pause RGMercs option is on.
      HOW   : Checks the running state, sends the command, sets the flag.
      WHEN  : At the start of a run.
    ----------------------------------------------------------------------------]]
    function plugins.pauseRGMercs()
        -- Nothing to do if it is not running.
        if not plugins.has('rgmercs') then return end
        utils.cmd('/rgl pause')        -- RGMercs pause command
        plugins.pausedRGMercs = true   -- remember that we did it
        utils.echo('RGMercs paused for training.')
    end

    --[[--------------------------------------------------------------------------
      plugins.unpauseRGMercs()

      WHAT  : Sends /rgl unpause, only if this package paused RGMercs.
      WHY   : Hands control back at the end of a run.
      WHERE : runner.stop and init.lua shutdown.
      HOW   : Checks the flag, sends the command if RGMercs is still running,
              clears the flag either way.
      WHEN  : At the end of a run.
    ----------------------------------------------------------------------------]]
    function plugins.unpauseRGMercs()
        -- Never unpause an RGMercs that the operator paused themselves.
        if not plugins.pausedRGMercs then return end
        plugins.pausedRGMercs = false                       -- clear first, so a failure cannot repeat
        if plugins.has('rgmercs') then
            utils.cmd('/rgl unpause')                       -- RGMercs unpause command
            utils.echo('RGMercs unpaused.')
        end
    end
end  -- of the plugins section

--[[==========================================================================
  END OF SECTION : plugins

  PUBLIC
    LIST, pausedRGMercs
    refresh(force), has(id), navReady(), pauseRGMercs(), unpauseRGMercs()

  DEPENDENCIES : mq, core.lua/utils

  HOW TO EDIT SAFELY
    - Adding a helper: add it to LIST, then check plugins.has('<id>') where
      it is used, with a fallback when it is missing.
    - Only send commands that the plugin's own documentation lists.
==========================================================================]]--

-- Hand the section tables to whoever requires this file.
return { utils = utils, config = config, plugins = plugins }

--[[==========================================================================
  END OF FILE : skillmaster/core.lua

  PUBLIC  (returned table)
    utils    bindDebugFlag, bindAbortFlag, aborted, color, echo, good,
             warn, err, debug, cmd, delay, clamp, now, formatDuration, lower
    config   DEFAULTS, settings, path, load, save, isSelected,
             setSelected, safeFallReady
    plugins  LIST, has, refresh, navReady, pauseRGMercs, unpauseRGMercs,
             pausedRGMercs

  DEPENDENCIES : mq only.

  HOW TO EDIT SAFELY
    - Never add a require of another skillmaster file here.
    - Keep the section order utils, config, plugins: later sections use
      earlier ones as plain locals.
    - Every slash command still goes through utils.cmd. Do not call mq.cmd
      directly anywhere else.
==========================================================================]]--
