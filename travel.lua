--[[==========================================================================
  FILE        : skillmaster/travel.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.0
  CHANGES     : 1.0.0  First release. The Begging trip and the Safe Fall
                       ledge of Skills2, rewritten as step by step trips that
                       check MQ2EasyFind and MQ2Nav first, can be stopped at
                       any step, and travel home when finished.

  WHAT  : Runs the two skills that need the character somewhere specific:
            Begging    travel to West Freeport, walk to Diggs, beg him until
                       Begging is mastered, travel back.
            Safe Fall  travel to the Plane of Knowledge, walk to a ledge,
                       hold forward to step off, walk back up, repeat.

  WHY   : Skills2 did both with fixed waits and no checks, so a missing
          plugin or a slow zone left the character stranded half way. Here
          each step waits for a real condition (zone reached, path finished)
          with a time limit, and a failure stops the trip with a reason.

  WHERE : Called by runner.lua when a travel entry is ticked. Only one trip
          runs at a time; conflicts.lua warns when both are ticked.

  HOW   : A trip is a small state machine stored in travel.trip:
            phase 'zone'   /travelto <zone> (MQ2EasyFind) until there
            phase 'spot'   /nav locxy or /nav locxyz (MQ2Nav) to the spot
            phase 'work'   beg or fall, once per tick
            phase 'home'   /travelto <return zone> (Begging only)
            phase 'done'
          travel.tick advances one step per call so the runner and the
          window stay responsive between steps.
          Commands: /travelto
          (https://www.redguides.com/docs/projects/mq2easyfind/cmd-travelto/),
          /nav (https://github-wiki-see.page/m/brainiac/MQ2Nav/wiki/Command-Reference),
          /keypress forward hold
          (https://docs.macroquest.org/reference/commands/keypress/),
          /nomodkey, /doability.

  WHEN  : While a travel skill is ticked and not mastered.

  READING GUIDE (for future you)
    - The West Freeport spot (132, -120) and the PoK ledge (803, -376, -96)
      come from Skills2 and have not been checked against the current zone
      geometry. They are editable in Options.
    - Begging can anger the NPC. Diggs was Skills2's choice.
==========================================================================]]--

local mq      = require('mq')                   -- TLO, delay
local utils   = require('skillmaster.utils')    -- cmd, delay, lower
local config  = require('skillmaster.config')   -- settings
local plugins = require('skillmaster.plugins')  -- EasyFind, Nav
local skills  = require('skillmaster.skills')   -- abilityReady, mastered
local stats   = require('skillmaster.stats')    -- log, count

local travel = {}

--- Current trip -------------------------------------------------------------------
-- WHAT : { key, phase, status, started } for the trip in progress, or nil.
-- WHY  : Lets travel.tick pick up where it left off.
-- WHERE: travel.tick, travel.cancel, ui.lua status.
-- HOW  : Created when a trip starts, cleared when it ends.
-- WHEN : While a trip runs.
travel.trip = nil  -- next tick starts fresh

--- Time limits ----------------------------------------------------------------------
-- WHAT : How long each kind of wait may take before the trip gives up.
-- WHY  : A stuck path must not leave the run waiting forever.
-- WHERE: zoneTo, navTo.
-- HOW  : Milliseconds.
-- WHEN : During waits.
local ZONE_MS = 15 * 60 * 1000   -- cross country /travelto can be slow
local NAV_MS  = 2 * 60 * 1000    -- walking within one zone

--[[--------------------------------------------------------------------------
  inZone(short)

  WHAT  : True when the current zone's short name matches.
  WHY   : Every phase starts by checking where we are.
  WHERE : This module.
  HOW   : Zone.ShortName() compared case insensitively.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
local function inZone(short)
    return utils.lower(mq.TLO.Zone.ShortName()) == utils.lower(short)  -- e.g. 'poknowledge'
end

--[[--------------------------------------------------------------------------
  zoneTo(short)

  WHAT  : Travels to a zone with MQ2EasyFind. Returns true on arrival.
  WHY   : Begging and Safe Fall need specific zones.
  WHERE : travel.tick phases 'zone' and 'home'.
  HOW   : /travelto <short>, then wait until the zone matches and zoning has
          finished. On timeout or Stop sends /travelto stop.
  WHEN  : Once per trip leg.
----------------------------------------------------------------------------]]
local function zoneTo(short)
    -- Already there is the usual case on a second trip.
    if inZone(short) then return true end
    utils.cmd('/travelto %s', short)                                  -- MQ2EasyFind
    local ok = utils.delay(ZONE_MS, function()
        return inZone(short) and mq.TLO.Me.Zoning() ~= true           -- arrived and loaded
    end)
    if not ok then utils.cmd('/travelto stop') end                     -- give up cleanly
    return ok
end

--[[--------------------------------------------------------------------------
  navTo(cmd)

  WHAT  : Sends one /nav command and waits for the path to finish. Returns
          true when navigation ended on its own.
  WHY   : Walking to the begging spot and the ledge.
  WHERE : travel.tick phase 'spot', and Safe Fall after each fall.
  HOW   : Waits for Navigation.Active to become true, then false. On timeout
          or Stop sends /nav stop.
  WHEN  : Each walk.
----------------------------------------------------------------------------]]
local function navTo(cmd)
    -- No mesh means /nav would do nothing.
    if not plugins.navReady() then return false end
    utils.cmd(cmd)                                                     -- e.g. /nav locxy 132 -120
    utils.delay(3000, function() return mq.TLO.Navigation.Active() == true end)  -- path started
    local ok = utils.delay(NAV_MS, function() return mq.TLO.Navigation.Active() ~= true end)  -- path ended
    if not ok then utils.cmd('/nav stop') end                          -- stuck: stop walking
    return ok
end

--[[--------------------------------------------------------------------------
  fail(reason)

  WHAT  : Ends the current trip with a reason.
  WHY   : Consistent message and log line for every failure.
  WHERE : travel.tick.
  HOW   : Sets phase 'failed' and status, warns, logs.
  WHEN  : When a step cannot be completed.
----------------------------------------------------------------------------]]
local function fail(reason)
    travel.trip.phase  = 'failed'                       -- runner stops calling this trip
    travel.trip.status = reason
    utils.warn('Trip stopped: %s', reason)
    stats.log('Trip stopped: %s', reason)
end

--[[--------------------------------------------------------------------------
  begOnce()

  WHAT  : One Begging attempt on the configured NPC.
  WHY   : The work phase of the Begging trip.
  WHERE : travel.tick.
  HOW   : Target with /mqtarget npc <name> if not targeted, then
          /doability Begging when ready.
  WHEN  : Each tick in the work phase.
----------------------------------------------------------------------------]]
local function begOnce()
    local npc = config.settings.beggingNpc                               -- e.g. Diggs
    if utils.lower(mq.TLO.Target.CleanName()) ~= utils.lower(npc) then
        utils.cmd('/mqtarget npc %s', npc)                               -- spawn search
        if not utils.delay(1500, function() return mq.TLO.Target.ID() ~= nil end) then
            return false, npc .. ' not found'
        end
    end
    if not skills.abilityReady('Begging') then return true end           -- wait for the timer
    utils.cmd('/doability "Begging"')                                    -- beg
    stats.count('abilities')
    return true
end

--[[--------------------------------------------------------------------------
  fallOnce()

  WHAT  : One step off the Safe Fall ledge and the walk back.
  WHY   : The work phase of the Safe Fall trip.
  WHERE : travel.tick.
  HOW   : Exactly the Skills2 key sequence: /nomodkey /keypress forward
          hold, wait safeFallHoldMs, /nomodkey /keypress forward (release).
          Then wait three seconds to land and walk back with /nav locxyz.
  WHEN  : Each tick in the work phase.
----------------------------------------------------------------------------]]
local function fallOnce()
    local s = config.settings
    utils.cmd('/nomodkey /keypress forward hold')            -- start walking off the ledge
    mq.delay(s.safeFallHoldMs)                               -- fixed hold, never cut short
    utils.cmd('/nomodkey /keypress forward')                 -- release, always sent
    utils.delay(3000)                                        -- fall and land
    local l = s.safeFallLocXYZ                               -- ledge loc
    return navTo(string.format('/nav locxyz %s %s %s', l[1], l[2], l[3]))  -- back up
end

--[[--------------------------------------------------------------------------
  travel.tick(entry)

  WHAT  : Advances the trip for a travel entry by one step. Returns true
          while the trip is still going.
  WHY   : Called every runner tick; one step at a time keeps the run
          responsive.
  WHERE : runner.lua.
  HOW   : Starts a trip if none, then runs the step for the current phase
          (see file header). Finishes with 'done' once the skill is
          mastered and, for Begging, the return trip is complete.
  WHEN  : Each tick while a travel entry is the active job.
----------------------------------------------------------------------------]]
function travel.tick(entry)
    local s = config.settings
    if not travel.trip or travel.trip.key ~= entry.key then
        travel.trip = { key = entry.key, phase = 'zone', status = 'starting', started = utils.now() }  -- new trip
        stats.log('Trip started: %s', entry.name)
    end
    local t = travel.trip
    local isBeg = entry.key == 'begging'                                  -- which trip
    local zone = isBeg and s.beggingZone or s.safeFallZone                -- destination

    if t.phase == 'zone' then
        t.status = 'travelling to ' .. zone
        if not plugins.has('MQ2EasyFind') and not inZone(zone) then fail('MQ2EasyFind is not loaded') return false end  -- cannot zone without the plugin
        if not zoneTo(zone) then fail('could not reach ' .. zone) return false end  -- timed out or stopped
        t.phase = 'spot'  -- next: walk to the spot
    elseif t.phase == 'spot' then  -- walk to the begging spot or ledge
        t.status = 'walking to the spot'  -- for the window
        local cmd                                                         -- nav command for the spot
        if isBeg then
            cmd = string.format('/nav locxy %s %s', s.beggingLocXY[1], s.beggingLocXY[2])
        else
            local l = s.safeFallLocXYZ  -- ledge x y z
            cmd = string.format('/nav locxyz %s %s %s', l[1], l[2], l[3])  -- MQ2Nav to a 3D loc
        end
        if not navTo(cmd) then fail('no nav mesh or path to the spot') return false end  -- no mesh or path
        t.phase = 'work'  -- next: beg or fall
    elseif t.phase == 'work' then  -- the actual training
        if skills.mastered(entry) then  -- capped: finish the trip
            t.phase = isBeg and 'home' or 'done'                          -- Safe Fall stays put
            return true
        end
        if isBeg then
            t.status = 'begging ' .. s.beggingNpc  -- for the window
            local ok, why = begOnce()  -- one attempt
            if not ok then fail(why) return false end  -- NPC missing
        else
            t.status = 'stepping off the ledge'  -- for the window
            if not fallOnce() then fail('could not walk back to the ledge') return false end  -- could not climb back
        end
    elseif t.phase == 'home' then  -- Begging travels home afterwards
        t.status = 'travelling home to ' .. s.beggingReturn  -- for the window
        if s.beggingReturn ~= '' and not zoneTo(s.beggingReturn) then fail('could not travel home') return false end  -- blank return zone stays put
        t.phase = 'done'  -- trip complete
    end
    if t.phase == 'done' then  -- tidy up a finished trip
        t.status = 'finished'  -- for the window
        stats.log('Trip finished: %s', entry.name)  -- session log
        travel.trip = nil  -- next tick starts fresh
        return false
    end
    return t.phase ~= 'failed'  -- true while the trip continues
end

--[[--------------------------------------------------------------------------
  travel.cancel()

  WHAT  : Stops any movement the trip started and forgets the trip.
  WHY   : Stop must leave the character standing still.
  WHERE : runner.stop.
  HOW   : /nav stop and /travelto stop when a trip exists, release the
          forward key, clear travel.trip.
  WHEN  : End of a run.
----------------------------------------------------------------------------]]
function travel.cancel()
    -- Nothing started, nothing to stop.
    if not travel.trip then return end
    if plugins.has('MQ2Nav') then utils.cmd('/nav stop') end              -- stop walking
    if plugins.has('MQ2EasyFind') then utils.cmd('/travelto stop') end    -- stop zone travel
    utils.cmd('/nomodkey /keypress forward')                              -- release forward just in case
    travel.trip = nil  -- next tick starts fresh
end

--[[--------------------------------------------------------------------------
  travel.failed(key)

  WHAT  : True when the trip for this key failed this run.
  WHY   : The runner must not restart a failed trip every tick.
  WHERE : runner.lua.
  HOW   : Compares the trip key and phase.
  WHEN  : Each tick.
----------------------------------------------------------------------------]]
function travel.failed(key)
    return travel.trip ~= nil and travel.trip.key == key and travel.trip.phase == 'failed'  -- failed trip kept for display
end

return travel  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/travel.lua

  PUBLIC
    trip, tick(entry), cancel(), failed(key)

  DEPENDENCIES : mq, skillmaster.utils, config, plugins, skills, stats

  HOW TO EDIT SAFELY
    - Always pair /keypress forward hold with the release line; fallOnce
      uses mq.delay for the hold so Stop cannot skip the release.
    - Keep failed trips in travel.trip (phase 'failed') so the window can
      show why; runner.stop clears it.
==========================================================================]]--
