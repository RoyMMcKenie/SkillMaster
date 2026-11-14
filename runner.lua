--[[==========================================================================
  FILE        : skillmaster/runner.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.0
  CHANGES     : 1.0.0  First release. Replaces the separate loops of Skills2
                       (/SPA, /SAA, /SS, /SBEG, /SSAFE, /SDA) and the single
                       loop of skillup.lua with one runner that trains every
                       ticked skill together, meditates when needed, and
                       stops each skill when it reaches its cap.

  WHAT  : The training run. Start, pause, resume and stop it, and one tick of
          work each time the main loop calls runner.tick.

  WHY   : Skills2 needed a separate command per kind of skill and never
          stopped on its own; skillup.lua trained everything its tables
          listed whether wanted or not. The runner trains exactly the ticked
          skills, in parallel where the game allows, and finishes by itself.

  WHERE : init.lua main loop calls runner.process (handles requests from the
          window and commands) and runner.tick. ui.lua reads runner.state and
          runner.status and sets runner.request.

  HOW   : Each tick, in order:
            1. Safety: not in game, zoning, stunned, dead or below the HP
               limit pause or stop the run.
            2. Done check: nothing left to train ends the run.
            3. Trip: a ticked Begging or Safe Fall trip runs one step and
               the rest waits (utility abilities still run once the trip is
               at its spot).
            4. Meditation: sit below medStartPct mana, stand at medStopPct.
               Nothing else happens while sitting, so Meditate rises.
            5. Abilities: every ready utility and combat ability is pressed.
            6. One cast: the next school in turn that is not blocked, not
               held by the specialization guard, has a spell, can afford it
               and has a target if it needs one.

  WHEN  : Every pass of the main loop (about ten times a second; long steps
          such as casting yield inside them).

  READING GUIDE (for future you)
    - The window never acts directly. It sets runner.request and the main
      loop acts on it, so a button press can never run in the middle of a
      cast.
    - state is 'idle', 'running' or 'paused'.
==========================================================================]]--

local mq        = require('mq')                     -- TLO
local utils     = require('skillmaster.utils')      -- cmd, now, abort binding
local config    = require('skillmaster.config')     -- settings
local catalog   = require('skillmaster.catalog')    -- entries, schools
local skills    = require('skillmaster.skills')     -- available, mastered
local plugins   = require('skillmaster.plugins')    -- RGMercs
local spells    = require('skillmaster.spells')     -- casting
local abilities = require('skillmaster.abilities')  -- abilities
local travel    = require('skillmaster.travel')     -- trips
local conflicts = require('skillmaster.conflicts')  -- guard and errors
local stats     = require('skillmaster.stats')      -- counters, log

local runner = {}

--- Run state -----------------------------------------------------------------------
-- WHAT : state, status text, pending request, meditating flag.
-- WHY  : Read by the window; request is how the window asks for changes.
-- WHERE: Whole module, ui.lua, init.lua.
-- HOW  : Plain fields.
-- WHEN : Changed by process, tick, start, stop.
runner.state      = 'idle'     -- idle | running | paused
runner.status     = 'Idle'     -- one line for the window
runner.request    = nil        -- 'start' | 'stop' | 'pause' | 'resume' | nil
runner.meditating = false      -- true while sitting to recover mana
runner.quitting   = false      -- set by /skm quit and the window close

local lastTick   = 0           -- utils.now() of the previous tick, for run time
local castTurn   = 0           -- round robin position over schools

-- Waits end at once when the operator asks to stop, pause or quit.
utils.bindAbortFlag(function()
    return runner.request == 'stop' or runner.request == 'pause' or runner.quitting
end)

--[[--------------------------------------------------------------------------
  runner.activeEntries()

  WHAT  : Ticked entries that are available and not mastered.
  WHY   : The work list for this tick.
  WHERE : runner.tick, runner.start.
  HOW   : Filters catalog.SKILLS; hint entries are never work.
  WHEN  : Each tick.
----------------------------------------------------------------------------]]
function runner.activeEntries()
    local out = {}                                                       -- result list
    for _, e in ipairs(catalog.SKILLS) do
        if e.method ~= 'hint' and config.isSelected(e.key) and skills.available(e) and not skills.mastered(e) then
            out[#out + 1] = e
        end
    end
    return out  -- ticked, available, not mastered
end

--[[--------------------------------------------------------------------------
  neededSchools(active)

  WHAT  : Ordered list of schools that still need casting.
  WHY   : A casting skill and its Specialize skill share one school; cast
          once for both.
  WHERE : runner.tick, runner.start.
  HOW   : Walks catalog.SCHOOLS and keeps those with an active cast entry.
  WHEN  : Each tick.
----------------------------------------------------------------------------]]
local function neededSchools(active)
    local want = {}                                                      -- school -> true
    for _, e in ipairs(active) do
        if e.method == 'cast' then want[e.school] = true end
    end
    local out = {}  -- ordered result
    for _, s in ipairs(catalog.SCHOOLS) do  -- catalog order keeps gems stable
        if want[s.school] then out[#out + 1] = s.school end              -- stable order
    end
    return out
end

--[[--------------------------------------------------------------------------
  runner.start()

  WHAT  : Begins a run. Returns true when started.
  WHY   : Start button and /skm start.
  WHERE : runner.process.
  HOW   : Scans the spell book, refreshes plugins, refuses on errors when
          the Block option is on, borrows gems, pauses RGMercs.
  WHEN  : On request.
----------------------------------------------------------------------------]]
function runner.start()
    -- Already going.
    if runner.state == 'running' then return true end
    config.save()                                                         -- keep the ticks
    spells.scan()                                                         -- fresh book, clears blocks
    plugins.refresh(true)
    if config.settings.blockOnErrors and conflicts.hasErrors() then
        utils.err('Not started: fix the red warnings in the window first.')
        runner.status = 'Not started: red warnings'  -- shown in the window
        return false
    end
    local active = runner.activeEntries()  -- what still needs work
    if #active == 0 then  -- nothing ticked or all mastered
        utils.warn('Nothing to train: tick at least one skill that is not mastered.')  -- explain the refusal
        runner.status = 'Nothing to train'  -- shown in the window
        return false
    end
    spells.assignGems(neededSchools(active))                              -- one gem per school
    if config.settings.pauseRGMercs then plugins.pauseRGMercs() end
    runner.state, runner.meditating, lastTick = 'running', false, utils.now()
    runner.status = 'Running'
    utils.good('Training %d skill%s.', #active, #active == 1 and '' or 's')  -- confirm in chat
    stats.log('Run started: %d skills', #active)  -- session log
    return true
end

--[[--------------------------------------------------------------------------
  runner.stop(reason)

  WHAT  : Ends the run and tidies up.
  WHY   : Stop button, /skm stop, safety stops, all mastered, quit.
  WHERE : runner.process, runner.tick, init.lua shutdown.
  HOW   : Stops MQ2AutoForage (if we started it), cancels any trip, puts
          the original gems back, unpauses RGMercs (if we paused it).
  WHEN  : On request or when the run ends itself.
----------------------------------------------------------------------------]]
function runner.stop(reason)
    -- Idle with nothing borrowed: nothing to tidy.
    if runner.state == 'idle' then return end
    runner.state = 'idle'
    runner.status = reason or 'Stopped'
    abilities.stopForage()                                                -- only if we started it
    travel.cancel()                                                       -- stop any walking
    if mq.TLO.Navigation.Active() == true then utils.cmd('/nav stop') end -- combat approach walking
    spells.restoreGems()                                                  -- give the bar back
    plugins.unpauseRGMercs()                                              -- only if we paused it
    utils.echo('Stopped: %s', runner.status)
    stats.log('Run stopped: %s', runner.status)
end

--[[--------------------------------------------------------------------------
  runner.pause() / runner.resume()

  WHAT  : Pause keeps borrowed gems and RGMercs paused but does nothing;
          resume carries on.
  WHY   : Lets the operator take over for a moment without a full restore.
  WHERE : runner.process.
  HOW   : Pause cancels any trip (it restarts from its first step on resume)
          and stops MQ2AutoForage; resume sets state back to running.
  WHEN  : On request.
----------------------------------------------------------------------------]]
function runner.pause()
    -- Only a running run can pause.
    if runner.state ~= 'running' then return end
    runner.state, runner.status = 'paused', 'Paused'
    abilities.stopForage()                                                -- MQ2AutoForage would keep going
    travel.cancel()                                                       -- trip restarts on resume
    stats.log('Paused')
end

function runner.resume()  -- see doc block above
    if runner.state ~= 'paused' then return end                           -- only from paused
    runner.state, runner.status, lastTick = 'running', 'Running', utils.now()
    stats.log('Resumed')
end

--[[--------------------------------------------------------------------------
  runner.process()

  WHAT  : Acts on runner.request.
  WHY   : Button presses and commands are applied from the main loop only.
  WHERE : init.lua main loop.
  HOW   : Reads and clears the request, then calls the matching function.
  WHEN  : Every main loop pass.
----------------------------------------------------------------------------]]
function runner.process()
    local r = runner.request                                              -- take the request
    if not r then return end
    runner.request = nil                                                  -- clear first so waits are not aborted later
    if r == 'start' then
        if runner.state == 'paused' then runner.resume() else runner.start() end
    elseif r == 'stop' then runner.stop('Stopped by you')
    elseif r == 'pause' then runner.pause()  -- pause request
    elseif r == 'resume' then runner.resume()  -- resume request
    end
end

--[[--------------------------------------------------------------------------
  safety()

  WHAT  : Returns nil when it is safe to act, else 'wait' or 'stop' and a
          reason.
  WHY   : Never act while zoning, stunned, dead, or badly hurt.
  WHERE : runner.tick.
  HOW   : MacroQuest.GameState, Me.Zoning, Me.Stunned, Me.Dead, Me.PctHPs.
  WHEN  : Start of each tick.
----------------------------------------------------------------------------]]
local function safety()
    -- Character select or loading screen.
    if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then return 'wait', 'not in game' end
    if mq.TLO.Me.Zoning() == true then return 'wait', 'zoning' end
    if mq.TLO.Me.Dead() == true then return 'stop', 'you died' end
    local hp = tonumber(mq.TLO.Me.PctHPs()) or 100                        -- health percent
    local falling = travel.trip ~= nil and travel.trip.key == 'safefall'  -- Safe Fall hurts on purpose
    if hp < config.settings.stopHpPct and not falling then
        return 'stop', string.format('health %d%% is below the stop limit', hp)
    end
    if falling and hp < config.settings.stopHpPct then  -- hurt on purpose: wait instead of stopping
        return 'wait', 'healing before the next fall'                     -- let health come back
    end
    if mq.TLO.Me.Stunned() == true then return 'wait', 'stunned' end
    return nil
end

--[[--------------------------------------------------------------------------
  meditate(needCast)

  WHAT  : Handles sitting and standing for mana. Returns true while
          meditating (the tick should do nothing else).
  WHY   : Casting needs mana and sitting with missing mana raises Meditate.
  WHERE : runner.tick.
  HOW   : Sit (/sit) below medStartPct, stand (/stand) at medStopPct. Also
          sits when the next spell is unaffordable (forced by the caller).
  WHEN  : Each tick while schools need casting or Meditate is ticked.
----------------------------------------------------------------------------]]
local function meditate(force)
    local s = config.settings
    if (tonumber(mq.TLO.Me.MaxMana()) or 0) <= 0 then return false end     -- no mana pool
    local pct = tonumber(mq.TLO.Me.PctMana()) or 100                       -- mana percent
    if runner.meditating then
        if pct >= s.medStopPct then
            runner.meditating = false
            if mq.TLO.Me.Sitting() then utils.cmd('/stand') end            -- ready to cast again
            return false
        end
        if not mq.TLO.Me.Sitting() and mq.TLO.Me.CombatState() ~= 'COMBAT' then utils.cmd('/sit') end  -- stood up somehow
        runner.status = string.format('Meditating, mana %d%%', pct)
        return true
    end
    if force or pct < s.medStartPct then  -- low mana or next spell unaffordable
        runner.meditating = true  -- remember until medStopPct
        if not mq.TLO.Me.Sitting() then utils.cmd('/sit') end              -- start meditating
        stats.log('Meditating at %d%% mana', pct)
        return true
    end
    return false  -- mana is fine
end

--[[--------------------------------------------------------------------------
  castNext(schools)

  WHAT  : Casts for the next school in turn that can be cast now. Returns
          true when it cast, false when nothing could, and 'mana' when the
          next spell is not affordable.
  WHY   : One cast per tick keeps abilities pressed between casts.
  WHERE : runner.tick.
  HOW   : Round robin over schools, skipping blocked, guarded, no spell, or
          harmful with no target. Target: none for Self spells, yourself
          for beneficial spells, the combat target for harmful ones.
  WHEN  : Each tick that is not meditating.
----------------------------------------------------------------------------]]
local function castNext(schools)
    for i = 1, #schools do
        castTurn = castTurn % #schools + 1                                -- next school in turn
        local school = schools[castTurn]
        local name = spells.choose(school)                                -- spell to use
        if name and not spells.blocked[school] and not conflicts.specBlocked(school) then
            local target = nil                                            -- spawn id or nil
            local info = spells.book[name]
            if spells.needsEnemy(name) then
                target = abilities.combatTarget()                         -- nil when none
            elseif info and info.targetType ~= 'Self' then
                target = mq.TLO.Me.ID()                                   -- buffs and heals on yourself
            end
            if target or not spells.needsEnemy(name) then
                if (tonumber(mq.TLO.Me.CurrentMana()) or 0) < spells.mana(name) then return 'mana' end
                if spells.needsEnemy(name) then abilities.approach(target, false) end  -- target and face it
                runner.status = string.format('Casting %s (%s)', name, school)
                spells.cast(school, name, target)
                return true
            end
        end
    end
    return false  -- every school is waiting
end

--[[--------------------------------------------------------------------------
  runner.tick()

  WHAT  : One pass of training work.
  WHY   : Called from the main loop; see file header for the order.
  WHERE : init.lua main loop.
  HOW   : See file header.
  WHEN  : Every main loop pass while running.
----------------------------------------------------------------------------]]
function runner.tick()
    -- Only a running run does work.
    if runner.state ~= 'running' then return end
    local now = utils.now()
    stats.data.runMs = stats.data.runMs + math.max(0, now - lastTick)    -- training time
    lastTick = now

    -- 1. Safety.
    local act, why = safety()
    if act == 'stop' then runner.stop('Safety stop: ' .. why) return end
    if act == 'wait' then runner.status = 'Waiting: ' .. why return end

    -- 2. Anything left?
    local active = runner.activeEntries()  -- what still needs work
    if #active == 0 then  -- nothing ticked or all mastered
        if config.settings.beepWhenDone and runner.status ~= 'All ticked skills mastered' then
            utils.cmd('/beep')                                            -- MacroQuest /beep, once
        end
        if config.settings.stopWhenDone then runner.stop('Every ticked skill is mastered') return end
        runner.status = 'All ticked skills mastered'
        return
    end

    -- 2b. Only passive skills (Meditate) left: nothing can raise them on
    --     its own, because Meditate only rises while missing mana is coming
    --     back. Stop instead of sitting at full mana forever.
    local onlyPassive = true  -- assume so until a non passive entry shows up
    for _, e in ipairs(active) do
        if e.method ~= 'passive' then onlyPassive = false break end      -- real work remains
    end
    if onlyPassive then
        runner.stop('Only Meditate is left; it rises while mana regenerates, so keep it ticked alongside a casting school')
        return
    end

    -- 3. Trips run one at a time, Begging first.
    for _, e in ipairs(active) do
        if e.method == 'travel' and not travel.failed(e.key) then
            if travel.tick(e) then
                runner.status = 'Trip: ' .. (travel.trip and travel.trip.status or '')  -- show the trip step
                if travel.trip and travel.trip.phase == 'work' then        -- at the spot: utility too
                    for _, u in ipairs(active) do
                        if u.group == 'utility' then abilities.train(u) end
                    end
                end
                return
            end
        end
    end

    -- 4. Meditation.
    local schools = neededSchools(active)
    local wantsMed = #schools > 0 or config.isSelected('meditate')
    if wantsMed and meditate(false) then return end

    -- 5. Abilities.
    for _, e in ipairs(active) do
        if e.group == 'utility' or e.group == 'combat' then abilities.train(e) end
        if utils.aborted() then return end                               -- Stop pressed mid pass
    end

    -- 6. One cast.
    if #schools > 0 then
        local r = castNext(schools)
        if r == 'mana' then meditate(true) return end                    -- sit until mana is back
        if r == false then runner.status = 'Waiting: no school can be cast right now' end
    else
        runner.status = 'Running abilities'
    end
end

return runner  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/runner.lua

  PUBLIC
    state, status, request, meditating, quitting
    activeEntries(), start(), stop(reason), pause(), resume(), process(),
    tick()

  DEPENDENCIES : mq, skillmaster.utils, config, catalog, skills, plugins,
                 spells, abilities, travel, conflicts, stats

  HOW TO EDIT SAFELY
    - Keep the tick order. Safety must stay first and meditation must stay
      before abilities, or the character stands up every tick.
    - Never call runner.start or runner.stop from the window; set
      runner.request instead.
==========================================================================]]--
