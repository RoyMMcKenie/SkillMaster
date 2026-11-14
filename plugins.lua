--[[==========================================================================
  FILE        : skillmaster/plugins.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.2
  CHANGES     : 1.0.2  Version number only; no code change.
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

  WHERE : Read by spells.lua (MQ2Cast), abilities.lua (MQ2AutoForage,
          MQ2Nav), travel.lua (MQ2EasyFind, MQ2Nav), runner.lua (RGMercs),
          conflicts.lua and ui.lua (status display).

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
      MQ2Nav        /nav target, /nav id N, /nav locxyz X Y Z, /nav locxy X Y,
                    /nav stop
                    https://github-wiki-see.page/m/brainiac/MQ2Nav/wiki/Command-Reference
      MQ2EasyFind   /travelto <zone>, /travelto stop
                    https://www.redguides.com/docs/projects/mq2easyfind/cmd-travelto/
      MQ2AutoForage /startforage, /stopforage
                    https://docs.macroquest.org/plugins/community-plugins/mq2autoforage/
      RGMercs (Lua) /rgl pause, /rgl unpause
==========================================================================]]--

local mq    = require('mq')                   -- TLO access
local utils = require('skillmaster.utils')    -- cmd, now, debug

local plugins = {}

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
  WHERE : abilities.lua, travel.lua, conflicts.lua.
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

return plugins  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/plugins.lua

  PUBLIC
    LIST, pausedRGMercs
    refresh(force), has(id), navReady(), pauseRGMercs(), unpauseRGMercs()

  DEPENDENCIES : mq, skillmaster.utils

  HOW TO EDIT SAFELY
    - Adding a helper: add it to LIST, then check plugins.has('<id>') where
      it is used, with a fallback when it is missing.
    - Only send commands that the plugin's own documentation lists.
==========================================================================]]--
