--[[==========================================================================
  FILE        : skillmaster/init.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.3
  CHANGES     : 1.0.3  Version 1.0.3.
                1.0.2  Version 1.0.2.
                1.0.1  Registers and removes the Begging "can't see you"
                       event (travel.init / travel.shutdown).
                1.0.0  First release. One entry point and one /skm command
                       replace the seven binds of Skills2 (/SPA /SAA /SS
                       /SBEG /SSAFE /SDA /StopS) and the start-and-go loop of
                       skillup.lua.

  WHAT  : Entry point of SkillMaster. Loads settings, opens the window,
          registers /skm, and runs the main loop until you quit.

  WHY   : MacroQuest runs init.lua when you type /lua run skillmaster. Keeping
          this file to start up, commands and the loop means every feature
          lives in its own module and can be read on its own.

  WHERE : <MacroQuest>/lua/skillmaster/init.lua

  HOW   : Startup: config.load, stats.init, mq.bind('/skm'),
          mq.imgui.init('SkillMaster', ui.render).
          Loop (about ten times a second): mq.doevents (skill up lines),
          runner.process (button and command requests), runner.tick (one
          step of training), ui.flush (debounced save), mq.delay(100).
          Shutdown: runner.stop (restores gems, unpauses RGMercs), save,
          remove the event and the command.

  WHEN  : From /lua run skillmaster until /skm quit or /lua stop skillmaster.

  READING GUIDE (for future you)
    - The window and the command only set runner.request; the loop acts on
      it. That keeps every game action on this one thread of control.
    - Out of game (character select) the loop idles and the run pauses
      itself through runner's safety check.
==========================================================================]]--

local mq      = require('mq')                   -- bind, imgui, delay, doevents
local utils   = require('skillmaster.utils')    -- echo
local config  = require('skillmaster.config')   -- load, save, selection
local catalog = require('skillmaster.catalog')  -- entries
local skills  = require('skillmaster.skills')   -- values for /skm status
local stats   = require('skillmaster.stats')    -- event, session
local runner  = require('skillmaster.runner')   -- the run
local ui      = require('skillmaster.ui')       -- the window
local travel  = require('skillmaster.travel')   -- begging chat event

--- Version ---------------------------------------------------------------------------
-- WHAT : Package version shown at start.
-- WHY  : Confirms which copy is running.
-- WHERE: startup message.
-- HOW  : Must match CHANGELOG.md.
-- WHEN : Once.
local VERSION = '1.0.3'

--[[--------------------------------------------------------------------------
  printHelp()

  WHAT  : Prints the /skm commands to chat.
  WHY   : /skm help and unknown arguments.
  WHERE : onCommand.
  HOW   : utils.echo per line.
  WHEN  : On request.
----------------------------------------------------------------------------]]
local function printHelp()
    -- Same list as the Help tab.
    utils.echo('/skm - show or hide the window')
    utils.echo('/skm start | pause | stop | quit')
    utils.echo('/skm all - tick every available skill (no specializations or trips)')
    utils.echo('/skm none - untick everything')  -- clear every tick
    utils.echo('/skm status - progress of ticked skills')  -- progress report
end

--[[--------------------------------------------------------------------------
  printStatus()

  WHAT  : Prints run state and each ticked skill's progress to chat.
  WHY   : Check another box without opening its window.
  WHERE : onCommand.
  HOW   : Walks catalog.SKILLS for ticked entries.
  WHEN  : /skm status.
----------------------------------------------------------------------------]]
local function printStatus()
    utils.echo('%s: %s', runner.state, runner.status)                   -- one line summary
    for _, e in ipairs(catalog.SKILLS) do  -- walk every known skill
        if config.isSelected(e.key) then
            local cur, cap = skills.value(e.name)
            utils.echo('  %s %d / %d%s', catalog.label(e), cur, cap, skills.mastered(e) and ' (mastered)' or '')  -- one line per ticked skill
        end
    end
end

--[[--------------------------------------------------------------------------
  onCommand(...)

  WHAT  : Handler for /skm.
  WHY   : Every window action is also available as a command, for hotkeys
          and for driving several boxes at once.
  WHERE : Registered with mq.bind in startup.
  HOW   : First argument picks the action. Run changes go through
          runner.request like the buttons.
  WHEN  : Whenever /skm is typed.
----------------------------------------------------------------------------]]
local function onCommand(...)
    local arg = utils.lower((...))                                        -- first word only
    if arg == '' then
        ui.open = not ui.open                                             -- toggle the window
    elseif arg == 'show' then ui.open = true
    elseif arg == 'start' then runner.request = 'start'
    elseif arg == 'pause' then runner.request = 'pause'
    elseif arg == 'stop' then runner.request = 'stop'  -- stop and restore
    elseif arg == 'quit' then runner.quitting = true  -- ends the main loop
    elseif arg == 'status' then printStatus()  -- chat report
    elseif arg == 'all' or arg == 'none' then  -- bulk tick changes
        if runner.state ~= 'idle' then utils.warn('Stop the run before changing ticks.') return end  -- gems are assigned at start, so no changes mid run
        if arg == 'none' then config.settings.selected = {} else  -- none empties the table, all fills it below
            for _, e in ipairs(catalog.SKILLS) do  -- walk every known skill
                -- Same rule as the Tick all button.
                if skills.available(e) and not skills.mastered(e) and e.group ~= 'specialize'
                   and not e.fearRisk and e.method ~= 'hint' and e.method ~= 'travel' then
                    config.setSelected(e.key, true)
                end
            end
        end
        ui.markDirty()  -- save shortly
        utils.echo('Ticks updated.')  -- confirm in chat
    else
        printHelp()  -- unknown or help argument
    end
end

--[[--------------------------------------------------------------------------
  startup()  -- load settings, register command and window

  WHAT  : One time setup before the loop.
  WHY   : Settings must exist before the window draws.
  WHERE : Bottom of this file.
  HOW   : See file header.
  WHEN  : Once at /lua run skillmaster.
----------------------------------------------------------------------------]]
local function startup()  -- load settings, register command and window
    config.load()                                     -- per character settings
    stats.init()                                      -- session and skill up event
    travel.init()                                     -- begging "can't see you" event
    ui.open = config.settings.windowOpen ~= false     -- remember hidden window
    mq.bind('/skm', onCommand)                        -- register the command
    mq.imgui.init('SkillMaster', ui.render)           -- register the window
    utils.good('SkillMaster %s loaded. /skm for the window, /skm help for commands.', VERSION)
end

--[[--------------------------------------------------------------------------
  shutdown()

  WHAT  : Tidies up when the loop ends.
  WHY   : Gems back, RGMercs unpaused, settings saved, command removed.
  WHERE : Bottom of this file.
  HOW   : runner.stop clears the quitting flag first so its waits run.
  WHEN  : Once, after the loop.
----------------------------------------------------------------------------]]
local function shutdown()
    runner.quitting = false                           -- let restore waits run
    runner.stop('SkillMaster closed')                 -- restores gems, unpauses RGMercs
    config.settings.windowOpen = ui.open
    ui.flush(true)
    config.save()
    stats.shutdown()                                  -- remove the event
    travel.shutdown()                                 -- remove the begging event
    mq.unbind('/skm')                                 -- remove the command
    utils.echo('SkillMaster closed.')
end

startup()  -- load settings, register command and window

-- Main loop. Each pass handles chat events, requests and one step of work,
-- then yields so the game and the window keep running.
while not runner.quitting do
    mq.doevents()        -- skill up lines
    runner.process()     -- button and command requests
    runner.tick()        -- one step of training
    ui.flush(false)      -- debounced save
    mq.delay(100)        -- yield 100 ms
end

shutdown()

--[[==========================================================================
  END OF FILE : skillmaster/init.lua

  PUBLIC : none (entry point). Command: /skm [show|start|pause|stop|all|none|status|quit|help]

  DEPENDENCIES : mq, skillmaster.utils, config, catalog, skills, stats,
                 runner, ui

  HOW TO EDIT SAFELY
    - Keep the main loop short; real work belongs in runner.tick.
    - A new command: add a branch to onCommand, a line to printHelp and to
      the Help tab in ui.lua, and to README.md.
==========================================================================]]--
