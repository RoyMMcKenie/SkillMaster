--[[==========================================================================
  FILE        : skillmaster/travel.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.5
  CHANGES     : 1.0.5  Safe Fall uses a ledge and landing spot you record
                       (PoK no longer gives falling damage), faces the
                       landing spot, checks you actually fell, and does not
                       move you when already on the ledge. /nav locyxz
                       replaces /nav locxyz; the Begging fixed spot
                       (/nav locxy, not in the MQ2Nav reference) is gone.
                1.0.4  Version number only; no code change.
                1.0.3  No movement when already within beggingRange of the
                       NPC; otherwise /nav id straight to the NPC.
                1.0.2  Version number only; no code change.
                1.0.1  Sneak off and /makemevisible before each beg; the
                       "can't see you" reply stops the trip after 3 tries.
                1.0.0  First release: Skills2 trips rewritten step by step.

  WHAT  : Runs the two skills that need the character somewhere specific:
            Begging    travel to West Freeport (skipped when already there),
                       stay put if already beside Diggs, else walk straight
                       to Diggs, beg until Begging is mastered, travel back.
            Safe Fall  travel to the zone of the ledge you recorded, walk to
                       the ledge (not if already on it), face the landing
                       spot you recorded, hold forward to step off, walk
                       back up, repeat. The old Skills2 Plane of Knowledge
                       ledge was removed: PoK no longer gives falling
                       damage, so Safe Fall cannot rise there.

  WHY   : Skills2 did both with fixed waits and no checks, so a missing
          plugin or a slow zone left the character stranded half way. Here
          each step waits for a real condition (zone reached, path finished)
          with a time limit, and a failure stops the trip with a reason.

  WHERE : Called by runner.lua when a travel entry is ticked. Only one trip
          runs at a time; conflicts.lua warns when both are ticked.

  HOW   : A trip is a small state machine stored in travel.trip:
            phase 'zone'   /travelto <zone> (MQ2EasyFind) until there
            phase 'spot'   Begging: nothing if within beggingRange of the NPC,
                           else /nav id to the NPC. Safe Fall: nothing if
                           already on the recorded ledge, else /nav locyxz.
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
          /nomodkey, /doability, /makemevisible.

  WHEN  : While a travel skill is ticked and not mastered.

  READING GUIDE (for future you)
    - No fixed locations remain. Begging finds the NPC by name; Safe Fall
      uses the ledge and landing spot you record in Options.
    - Begging can anger the NPC. Diggs was Skills2's choice.
==========================================================================]]--

local mq      = require('mq')                   -- TLO, delay
local utils   = require('skillmaster.utils')    -- cmd, delay, lower
local config  = require('skillmaster.config')   -- settings
local plugins = require('skillmaster.plugins')  -- EasyFind, Nav
local skills  = require('skillmaster.skills')   -- abilityReady, mastered
local stats   = require('skillmaster.stats')    -- log, count

local travel = {}

--- Unseen begging -----------------------------------------------------------------
-- WHAT : unseenPending is set by the chat event when EverQuest answers a beg
--        with "How can you beg from someone when they can't see you?".
--        unseenTries counts /makemevisible attempts since Begging last rose.
-- WHY  : That line means the NPC cannot see you (invisible or hidden, often
--        from Hide being trained at the spot). Without handling it the trip
--        keeps begging and spams the Skills chat tab, as seen in 1.0.0.
-- WHERE: Set in onUnseen, read and cleared in begOnce.
travel.unseenPending = false
travel.unseenTries   = 0
-- True only between the Safe Fall forward press and its release, so
-- travel.cancel sends the release only when the key is really held.
travel.forwardHeld   = false
local UNSEEN_MAX     = 3          -- attempts before the trip gives up
local lastBegValue   = nil        -- Begging value when the tries were reset

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
    if not plugins.has('MQ2EasyFind') then return false end           -- /travelto needs MQ2EasyFind
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
    utils.cmd(cmd)                                                     -- e.g. /nav locyxz 100 200 5
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
  findNpc() / npcDistance(id)

  WHAT  : findNpc returns the spawn ID of the Begging NPC in this zone, or
          nil. npcDistance returns the live distance to that ID (999 when
          gone).
  WHY   : The trip must know whether you are already beside the NPC before
          it moves you anywhere.
  WHERE : walkToNpc and begOnce.
  HOW   : Spawn TLO with the search 'npc <name>' (same search /mqtarget
          uses), then Spawn('id N').Distance.
  WHEN  : In the spot and work phases.
----------------------------------------------------------------------------]]
local function findNpc()
    local id = mq.TLO.Spawn('npc ' .. config.settings.beggingNpc).ID()   -- nil or 0 when not up
    if id and id > 0 then return id end
    return nil  -- not in this zone right now
end

local function npcDistance(id)  -- see doc block above
    return tonumber(mq.TLO.Spawn('id ' .. id).Distance()) or 999         -- gone counts as far
end

--[[--------------------------------------------------------------------------
  walkToNpc()

  WHAT  : Gets you within beggingRange of the Begging NPC with as little
          movement as possible. Returns true when in range.
  WHY   : 1.0.2 always walked to the fixed Skills2 spot, so standing next to
          Diggs still ran you across the zone.
  WHERE : travel.tick phase 'spot', and begOnce when the NPC wandered off.
  HOW   : 1. NPC found and within beggingRange: do nothing at all.
          2. NPC found but further: /nav id <id> (MQ2Nav), wait until within
             range, /nav stop.
          3. NPC not found in the zone: returns false (the trip stops with
             the reason). The old fixed Skills2 spot used /nav locxy, which
             the MQ2Nav command reference does not list, so it was removed.
  WHEN  : When the trip reaches the zone, and before a beg if out of range.
----------------------------------------------------------------------------]]
local function walkToNpc()
    local s = config.settings
    local id = findNpc()                                                 -- NPC here?
    if id and npcDistance(id) <= s.beggingRange then return true end     -- already beside: no movement
    if not plugins.navReady() then return false end                      -- cannot walk anywhere
    if not id then return false end                                      -- NPC not in this zone
    stats.log('Walking to %s (%d away)', s.beggingNpc, math.floor(npcDistance(id)))
    utils.cmd('/nav id %d', id)                                          -- MQ2Nav straight to the NPC
    utils.delay(NAV_MS, function() return npcDistance(id) <= s.beggingRange end)  -- until in range
    utils.cmd('/nav stop')                                               -- stop beside the NPC
    return npcDistance(id) <= s.beggingRange
end

--[[--------------------------------------------------------------------------
  begOnce()

  WHAT  : One Begging attempt on the configured NPC.
  WHY   : The work phase of the Begging trip.
  WHERE : travel.tick.
  HOW   : Turn Sneak off if sneaking, drop Hide or invisibility with
          /makemevisible (also when the game said the NPC cannot see you),
          target with /mqtarget npc <name> if not targeted, then
          /doability Begging when ready.
  WHEN  : Each tick in the work phase.
----------------------------------------------------------------------------]]
local function begOnce()
    local npc = config.settings.beggingNpc                               -- e.g. Diggs
    -- Begging went up since the last reset: you are being seen again.
    local cur = tonumber(mq.TLO.Me.Skill('Begging')()) or 0              -- current Begging
    if lastBegValue == nil or cur > lastBegValue then travel.unseenTries, lastBegValue = 0, cur end
    -- Sneaking: press Sneak once to turn it off (Sneak is a toggle), so the
    -- NPC is begged from a normal, visible stance. Me.Sneaking is the
    -- documented spawn member.
    if mq.TLO.Me.Sneaking() == true then
        utils.cmd('/doability "Sneak"')                                  -- toggle Sneak off
        stats.log('Begging: turned Sneak off first')
        utils.delay(1500, function() return mq.TLO.Me.Sneaking() ~= true end)  -- wait for it to drop
        if mq.TLO.Me.Sneaking() == true then return false, 'could not turn Sneak off before begging' end
        return true                                                      -- beg on the next tick
    end
    -- Invisible or hidden (Me.Invis, any type), or the game just said the
    -- NPC cannot see you: become visible before the next beg.
    if mq.TLO.Me.Invis() == true or travel.unseenPending then
        travel.unseenPending = false                                     -- handled now
        travel.unseenTries = travel.unseenTries + 1                      -- count the attempt
        if travel.unseenTries > UNSEEN_MAX then                          -- it keeps happening
            return false, npc .. ' cannot see you (invisible or hidden) even after /makemevisible'
        end
        utils.cmd('/makemevisible')                                      -- MacroQuest: drop invis / hide
        stats.log('Begging: %s could not see you, sent /makemevisible (%d/%d)', npc, travel.unseenTries, UNSEEN_MAX)
        utils.delay(1500, function() return mq.TLO.Me.Invis() ~= true end)  -- give the game a moment
        return true                                                      -- beg on the next tick
    end
    -- NPC wandered out of range: walk to it. In range: no movement.
    local id = findNpc()                                                 -- NPC spawn ID
    if id and npcDistance(id) > config.settings.beggingRange then
        if not walkToNpc() then return false, npc .. ' is out of range' end
    end
    if utils.lower(mq.TLO.Target.CleanName()) ~= utils.lower(npc) then  -- not targeted yet
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
  distTo(p) / ledgeCmd()

  WHAT  : distTo returns your flat distance to a recorded { y, x, z } spot.
          ledgeCmd returns the MQ2Nav command that walks to the ledge.
  WHY   : Safe Fall must not move you when you are already on the ledge,
          and must walk back after each fall.
  WHERE : walkToLedge, fallOnce.
  HOW   : Me.Y / Me.X from the spawn TLO. /nav locyxz <Y> <X> <Z> from the
          MQ2Nav command reference
          (https://github-wiki-see.page/m/brainiac/MQ2Nav/wiki/Command-Reference).
  WHEN  : Each Safe Fall step.
----------------------------------------------------------------------------]]
local function distTo(p)
    local dy = (tonumber(mq.TLO.Me.Y()) or 0) - p[1]                     -- north / south
    local dx = (tonumber(mq.TLO.Me.X()) or 0) - p[2]                     -- east / west
    return math.sqrt(dy * dy + dx * dx)                                  -- flat distance
end

local function ledgeCmd()  -- see doc block above
    local l = config.settings.safeFallLedge                              -- { y, x, z }
    return string.format('/nav locyxz %.2f %.2f %.2f', l[1], l[2], l[3])  -- MQ2Nav, y x z order
end

local LEDGE_NEAR = 3       -- this close to the ledge counts as standing on it
local noDrops    = 0       -- falls in a row where you did not go down

--[[--------------------------------------------------------------------------
  walkToLedge()

  WHAT  : Gets you onto the recorded ledge. Returns true when there.
  WHY   : Same rule as Begging: no movement when already there.
  WHERE : travel.tick phase 'spot', fallOnce after landing.
  HOW   : Within LEDGE_NEAR: nothing. Else navTo(ledgeCmd()).
  WHEN  : Before each fall.
----------------------------------------------------------------------------]]
local function walkToLedge()
    if distTo(config.settings.safeFallLedge) <= LEDGE_NEAR then return true end  -- already on it
    return navTo(ledgeCmd())                                            -- walk up to the ledge
end

--[[--------------------------------------------------------------------------
  fallOnce()

  WHAT  : One step off the recorded ledge and the walk back. Returns ok and
          a reason when not ok.
  WHY   : The work phase of the Safe Fall trip. Safe Fall only rises from a
          fall that would hurt, so the place matters; you choose it.
  WHERE : travel.tick.
  HOW   : 1. Be on the ledge (walkToLedge).
          2. /face fast loc <y>,<x> toward the landing spot (no spaces, as
             the /face docs require:
             https://docs.macroquest.org/reference/commands/face/).
          3. The Skills2 key sequence: /nomodkey /keypress forward hold,
             wait safeFallHoldMs, /nomodkey /keypress forward (release).
          4. Wait up to three seconds to come down (Me.Z drops by more
             than 2). Three steps in a row with no drop stop the trip.
          5. Walk back with walkToLedge.
  WHEN  : Each tick in the work phase.
----------------------------------------------------------------------------]]
local function fallOnce()
    local s = config.settings
    if not walkToLedge() then return false, 'could not walk back to the ledge' end  -- step 1
    local g = s.safeFallLanding                                          -- { y, x, z }
    utils.cmd('/face fast loc %.2f,%.2f', g[1], g[2])                    -- step 2: face the drop
    local topZ = tonumber(mq.TLO.Me.Z()) or 0                            -- height before the step
    utils.cmd('/nomodkey /keypress forward hold')                        -- step 3: walk off
    travel.forwardHeld = true                                            -- travel.cancel must release it
    mq.delay(s.safeFallHoldMs)                                           -- fixed hold, never cut short
    utils.cmd('/nomodkey /keypress forward')                             -- release, always sent
    travel.forwardHeld = false                                           -- key is up
    local fell = utils.delay(3000, function()                            -- step 4: came down?
        return (tonumber(mq.TLO.Me.Z()) or topZ) < topZ - 2
    end)
    if fell then
        noDrops = 0                                                      -- good step
        stats.count('abilities')
    else
        noDrops = noDrops + 1                                            -- still up top
        if noDrops >= 3 then
            noDrops = 0                                                  -- fresh count next time
            return false, 'stepped forward three times without falling; set the ledge and landing spot again or raise Forward hold ms'
        end
    end
    utils.delay(1500)                                                    -- let the landing settle
    if not walkToLedge() then return false, 'could not walk back to the ledge' end  -- step 5
    return true
end

--[[--------------------------------------------------------------------------
  onUnseen()

  WHAT  : Chat event handler for the "can't see you" begging reply.
  WHY   : Lets begOnce react to the game's own answer instead of begging
          again blind.
  WHERE : Registered by travel.init.
  HOW   : Sets travel.unseenPending, but only while a Begging trip is in
          its work phase, so the line from manual begging is ignored.
  WHEN  : When the line appears in chat (mq.doevents in the main loop).
----------------------------------------------------------------------------]]
local function onUnseen()
    if travel.trip and travel.trip.key == 'begging' and travel.trip.phase == 'work' then
        travel.unseenPending = true                                      -- begOnce handles it
    end
end

--[[--------------------------------------------------------------------------
  travel.init() / travel.shutdown()

  WHAT  : Register and remove the "can't see you" chat event.
  WHY   : Events must be removed when the script ends.
  WHERE : init.lua startup and shutdown.
  HOW   : mq.event with #*# wildcards around the fixed words, so the
          apostrophe style in "can't" does not matter. Line seen in game:
          "How can you beg from someone when they can't see you?"
  WHEN  : Once at startup, once at shutdown.
----------------------------------------------------------------------------]]
function travel.init()
    mq.event('skm_begunseen', '#*#beg from someone when they can#*#see you#*#', onUnseen)  -- game line
end

function travel.shutdown()  -- see doc block above
    mq.unevent('skm_begunseen')  -- same name as in travel.init
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
        if not isBeg and not config.safeFallReady() then fail('Safe Fall ledge and landing spot are not set (Options)') return false end  -- nothing recorded: do not move
        if not isBeg and utils.lower(zone) == 'poknowledge' then fail('no falling damage in the Plane of Knowledge; record a ledge elsewhere') return false end  -- cannot rise there
        if not plugins.has('MQ2EasyFind') and not inZone(zone) then fail('MQ2EasyFind is not loaded') return false end  -- cannot zone without the plugin
        if not zoneTo(zone) then fail('could not reach ' .. zone) return false end  -- timed out or stopped
        t.phase = 'spot'  -- next: walk to the spot
    elseif t.phase == 'spot' then  -- walk to the begging spot or ledge
        t.status = 'walking to the spot'  -- for the window
        if isBeg then
            -- Begging: no movement when already beside the NPC.
            if not walkToNpc() then fail(s.beggingNpc .. ' not found in this zone or could not get within range') return false end
        else
            if not config.safeFallReady() then fail('Safe Fall ledge and landing spot are not set (Options)') return false end
            if not walkToLedge() then fail('no nav mesh or path to the ledge') return false end  -- no movement if already there
        end
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
            local ok, why = fallOnce()  -- one step off and back
            if not ok then fail(why) return false end  -- could not climb back or no drop
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
  HOW   : /nav stop only while MQ2Nav is moving, /travelto stop only in
          the zone or home phase, forward key released only for Safe Fall,
          then clear travel.trip.
  WHEN  : End of a run.
----------------------------------------------------------------------------]]
function travel.cancel()
    -- Nothing started, nothing to stop.
    if not travel.trip then return end
    local t = travel.trip                                                 -- trip being cancelled
    -- Only stop what is actually moving, so a run that never moved you
    -- sends no movement commands at all.
    if plugins.has('MQ2Nav') and mq.TLO.Navigation.Active() == true then utils.cmd('/nav stop') end  -- stop walking
    if plugins.has('MQ2EasyFind') and (t.phase == 'zone' or t.phase == 'home') then
        utils.cmd('/travelto stop')                                       -- stop zone travel
    end
    if travel.forwardHeld then utils.cmd('/nomodkey /keypress forward') travel.forwardHeld = false end  -- release forward only if held
    travel.trip = nil  -- next tick starts fresh
    travel.unseenPending, travel.unseenTries, lastBegValue = false, 0, nil  -- fresh count next trip
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
    trip, unseenPending, unseenTries, init(), shutdown(), tick(entry),
    cancel(), failed(key)

  DEPENDENCIES : mq, skillmaster.utils, config, plugins, skills, stats

  HOW TO EDIT SAFELY
    - Always pair /keypress forward hold with the release line; fallOnce
      uses mq.delay for the hold so Stop cannot skip the release.
    - The unseen event pattern uses #*# around "can" and "see you" on
      purpose; do not type the apostrophe into the pattern.
    - Keep failed trips in travel.trip (phase 'failed') so the window can
      show why; runner.stop clears it.
==========================================================================]]--
