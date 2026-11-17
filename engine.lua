--[[==========================================================================
  FILE        : skillmaster/engine.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.1.0
  CHANGES     : 1.1.0  Consolidation. conflicts.lua and runner.lua were
                       merged into this one file as sections. Code is
                       unchanged; each section keeps its own doc block,
                       history and private locals (do ... end scope).
                1.0.0 to 1.0.5  See the HISTORY line of each section and
                       CHANGELOG.md.

  CREDITS     : runner section: the start and go training loop of Skill
                Skillup 1.1, skillup.lua, by GoldenFrog (RedGuides resource
                2937), and the per skill stop at cap of Skills2 0.4.2 by
                Blasty (RedGuides resource 2302). conflicts section is
                original to SkillMaster. Full lineage in README, Credits and
                attribution.

  WHAT  : The decision layer. Two sections:
            conflicts  every warning and error shown in the header, the
                       specialization state and guard
            runner     run state (idle / running / paused), Start, Pause,
                       Resume, Stop, End, and one tick of work

  WHY   : runner asks conflicts "may I start, and which schools are held?"
          on every Start and every tick. Keeping the rules and the loop that
          obeys them side by side makes it obvious why a run refused to
          start or skipped a school.

  WHERE : <MacroQuest>/lua/skillmaster/engine.lua
          Required by ui.lua and init.lua.

  HOW   : local engine = require('skillmaster.engine')
          local conflicts, runner = engine.conflicts, engine.runner
          ui and init only set runner.request; init's loop calls
          runner.process and runner.tick, so no game action ever runs
          inside the ImGui callback.

  WHEN  : Every main loop pass (about ten times a second).

  READING GUIDE (for future you)
    - Pause is a project rule: every SkillMaster Lua must offer one. It is
      runner.state = 'paused'; tick returns at once and nothing is sent.
==========================================================================]]--

local mq        = require('mq')                  -- TLO
local core      = require('skillmaster.core')    -- foundation layer
local utils     = core.utils                     -- cmd, now, abort binding
local config    = core.config                    -- settings
local plugins   = core.plugins                   -- helper state, RGMercs
local data      = require('skillmaster.data')    -- knowledge layer
local catalog   = data.catalog                   -- entries, schools
local skills    = data.skills                    -- values, available, mastered
local stats     = data.stats                     -- counters, log
local actions   = require('skillmaster.actions') -- action layer
local spells    = actions.spells                 -- casting, chosen spells
local abilities = actions.abilities              -- abilities, requirements
local travel    = actions.travel                 -- trips

-- Section tables, declared up front so every section below (and the
-- return at the bottom) can see them. Each is filled inside its own
-- do ... end block, which keeps that section's private locals private.
local conflicts = {}   -- conflicts section, see its block below
local runner    = {}   -- runner section, see its block below

--[[==========================================================================
  SECTION     : conflicts   (was skillmaster/conflicts.lua up to 1.0.5)
  HISTORY     : 1.0.5  Safe Fall: warning when no ledge is recorded, error when
                       the ledge is in PoK (no falling damage).
                1.0.4  Version number only; no code change.
                1.0.3  Version number only; no code change.
                1.0.2  Version number only; no code change.
                1.0.1  Notes when Begging is ticked with Hide, Sneak or Feign
                       Death, or while invisible.
                1.0.0  First release. New module; neither source script
                       warned about anything.

  WHAT  : Looks at the ticked skills, the character and the loaded plugins,
          and produces a list of warnings shown at the top of the window:
            error  (red)    mutually exclusive or unsafe; Start is refused
                            while the Block option is on
            warn   (yellow) will work badly or partly
            info   (grey)   worth knowing
          Also contains the specialization guard used by the runner.

  WHY   : The request asked for a warning when mutually exclusive skills are
          ticked. The big one is specialization: only one Specialize skill
          can pass 50 and the first to do so becomes permanent primary, so
          training two at once can lock in the wrong one. Other pairs fight
          each other in practice (Hide and casting, Feign Death and combat,
          two trips in different zones).

  WHERE : conflicts.list() is drawn by ui.lua every frame (cached).
          conflicts.specBlocked(school) is asked by engine.lua/runner before each
          cast. conflicts.hasErrors() is asked by runner.start.

  HOW   : evaluate() builds the list from scratch each second.
          Specialization rules used (EverQuest, not EverQuest Legends):
            - The first specialization to pass 50 becomes primary; the
              others are capped lower.
              https://everquest.fandom.com/wiki/Spell_school_specialization_skills
            - The Secondary Forte AA (level 55, CLR DRU ENC MAG NEC SHM)
              allows one more specialization above the others.
              https://everquest.allakhazam.com/wiki/eq:Secondary_Forte
            - Since the April 2022 update the secondary cap is 50 below the
              primary and the rest 100 below.
              https://www.everquest.com/update-notes/eq-update-notes-4-20-2022
          "Locked" is detected from the caps: when the five Specialize caps
          are not all equal, a primary has been set.

  WHEN  : Every second while the window is open, and at Start.

  READING GUIDE (for future you)
    - A conflict entry is { level = 'error'|'warn'|'info', text = '...' }.
    - "Ticked" means selected in the settings; "active" means ticked,
      available and not yet mastered.
==========================================================================]]--
do  -- conflicts section scope: locals declared here stay inside it
    --- Cache --------------------------------------------------------------------------
    -- WHAT : Last list built and when.
    -- WHY  : Building the list reads many TLOs; once a second is enough.
    -- WHERE: conflicts.list.
    -- HOW  : cached = list, stamp = ms.
    -- WHEN : Rebuilt each second or when forced.
    local cached, stamp = {}, -1

    --[[--------------------------------------------------------------------------
      conflicts.specState()

      WHAT  : Returns a table describing specialization for this character:
              { locked, primary (school or nil), forte (bool),
                caps[school], values[school] }.
      WHY   : Needed by the guard, the warnings and the Spells tab.
      WHERE : This module, ui.drawSpells.
      HOW   : Reads the five Specialize skills. Locked when caps differ; the
              school with the highest cap is primary. Forte from
              Me.AltAbility('Secondary Forte').
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function conflicts.specState()
        local st = { caps = {}, values = {}, locked = false, primary = nil }   -- result
        st.forte = mq.TLO.Me.AltAbility('Secondary Forte')() ~= nil           -- AA owned?
        local hi, lo = -1, 100000                                             -- highest and lowest cap seen
        for _, s in ipairs(catalog.SCHOOLS) do
            local cur, cap = skills.value(s.spec)                             -- live numbers
            st.caps[s.school], st.values[s.school] = cap, cur
            if cap > hi then hi, st.primary = cap, s.school end               -- highest cap so far
            if cap < lo then lo = cap end
        end
        st.locked = hi > 0 and hi ~= lo                                       -- caps differ: primary set
        if not st.locked then st.primary = nil end                            -- no primary yet
        return st
    end

    --[[--------------------------------------------------------------------------
      intendedPrimary(st)

      WHAT  : The school the operator wants as primary, or nil.
      WHY   : The guard lets this school pass the guard value.
      WHERE : conflicts.specBlocked, evaluate.
      HOW   : The Spells tab choice if set; else, when exactly one Specialize
              skill is ticked, that one's school.
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    local function intendedPrimary()
        -- An explicit choice wins.
        if config.settings.specPrimary ~= '' then return config.settings.specPrimary end
        local found = nil                                                     -- the single ticked spec
        for _, e in ipairs(catalog.SKILLS) do
            if e.group == 'specialize' and config.isSelected(e.key) then
                if found then return nil end                                  -- more than one: undecided
                found = e.school
            end
        end
        return found  -- exactly one ticked
    end

    --[[--------------------------------------------------------------------------
      conflicts.specBlocked(school)

      WHAT  : Returns a reason when casting this school would risk making it the
              wrong primary specialization, else nil.
      WHY   : Casting any school spell also raises its Specialize skill, even
              when only the casting skill is ticked. Without this guard,
              training Evocation to cap could make Specialize Evocation primary
              on a cleric who wanted Alteration.
      WHERE : engine.lua/runner before every cast.
      HOW   : Only while the guard is on, primary is not locked and the
              Specialize skill exists (cap above 0): block when its value has
              reached specGuardValue and the school is not the intended primary.
      WHEN  : Before each cast.
    ----------------------------------------------------------------------------]]
    function conflicts.specBlocked(school)
        -- Guard off or nothing to protect.
        if not config.settings.specGuard then return nil end
        local st = conflicts.specState()
        if st.locked or (st.caps[school] or 0) <= 0 then return nil end          -- already decided or too low level
        if school == intendedPrimary() then return nil end                        -- this is the one we want
        if (st.values[school] or 0) >= config.settings.specGuardValue then
            return string.format('%s held at %d by the specialization guard',
                catalog.specFor(school), config.settings.specGuardValue)
        end
        return nil  -- below the guard value
    end

    --[[--------------------------------------------------------------------------
      activeEntries()

      WHAT  : Ticked entries that are available and not mastered.
      WHY   : Most checks only care about work that will actually happen.
      WHERE : evaluate.
      HOW   : Filters catalog.SKILLS.
      WHEN  : Each evaluate.
    ----------------------------------------------------------------------------]]
    local function activeEntries()
        local out = {}                                                        -- result list
        for _, e in ipairs(catalog.SKILLS) do
            if config.isSelected(e.key) and skills.available(e) and not skills.mastered(e) then
                out[#out + 1] = e
            end
        end
        return out  -- work that will happen
    end

    --[[--------------------------------------------------------------------------
      evaluate()

      WHAT  : Builds the full warning list.
      WHY   : See file header.
      WHERE : conflicts.list.
      HOW   : A series of independent checks, each adding entries with add().
      WHEN  : Once a second.
    ----------------------------------------------------------------------------]]
    local function evaluate()
        local out = {}                                                        -- result list
        local function add(level, fmt, ...) out[#out + 1] = { level = level, text = string.format(fmt, ...) } end  -- helper
        local s = config.settings
        local active = activeEntries()
        local by = {}                                                         -- active key -> entry
        for _, e in ipairs(active) do by[e.key] = e end
        local castSchools, specTicked, combatCount = {}, {}, 0                -- tallies
        for _, e in ipairs(active) do
            if e.method == 'cast' then castSchools[e.school] = true end
            if e.group == 'specialize' then specTicked[#specTicked + 1] = e end
            if e.method == 'combat' then combatCount = combatCount + 1 end  -- count combat abilities
        end

        -- Specialization: the mutually exclusive set.
        local st = conflicts.specState()
        if not st.locked and #specTicked > 1 then
            local names = {}                                                  -- for the message
            for _, e in ipairs(specTicked) do names[#names + 1] = e.name end
            local limit = st.forte and 2 or 1                                 -- how many may pass 50
            if #specTicked > limit then
                add('error', 'Mutually exclusive: %s. Only %d specialization%s can pass 50 and the first to do so becomes permanent primary. Untick all but %s.',
                    table.concat(names, ', '), limit, limit > 1 and 's' or '', limit > 1 and 'two' or 'one')
            elseif s.specPrimary == '' then  -- two allowed but primary not chosen
                add('warn', 'Two specializations ticked with Secondary Forte. Choose the primary on the Spells tab so the right one passes 50 first.')  -- advice only
            end
        end
        if not st.locked and s.specGuard then  -- guard on and nothing locked yet
            local p = intendedPrimary()  -- school allowed past the guard
            for school in pairs(castSchools) do  -- every school that will be cast
                if school ~= p and (st.caps[school] or 0) > 0 then  -- will be held at the guard value
                    add('info', '%s casting also raises %s; the guard holds it at %d until a primary is set.',  -- tell the operator
                        school, catalog.specFor(school), s.specGuardValue)  -- message arguments
                end
            end
        elseif not st.locked and not s.specGuard and next(castSchools) then  -- guard off and schools ticked
            add('warn', 'Specialization guard is off: whichever school passes 50 first becomes your permanent primary.')  -- the risky case
        end

        -- Trips in two different zones.
        if by.begging and by.safefall and s.safeFallZone ~= '' and s.safeFallZone ~= s.beggingZone then  -- two zones
            add('warn', 'Mutually exclusive: Begging (%s) and Safe Fall (%s) need different zones. They will run one after the other, Begging first.',
                s.beggingZone, s.safeFallZone)
        end
        if by.begging and (by.hide or by.sneak or by.feign) then  -- would make the NPC unable to see you
            add('info', 'Hide, Sneak and Feign Death are skipped while begging: the NPC must be able to see you.')  -- explain the skip
        end
        if by.begging and (mq.TLO.Me.Invis() == true or mq.TLO.Me.Sneaking() == true) then  -- unseen right now
            add('info', 'You are sneaking, hidden or invisible; the Begging trip turns Sneak off and sends /makemevisible before begging.')  -- what will happen
        end
        if (by.begging or by.safefall) and combatCount > 0 then  -- trips leave the zone
            add('warn', 'Trips leave the zone, so combat abilities pause while a trip runs.')  -- combat waits during a trip
        end

        -- Abilities that undo each other.
        if by.hide and next(castSchools) then
            add('warn', 'Hide is broken by casting. Hide still rises, but you will rarely stay hidden.')
        end
        if by.feign and combatCount > 0 then  -- the two undo each other
            add('warn', 'Feign Death and combat abilities conflict: feigning drops your target, combat pulls it back. Feign Death waits while in combat.')  -- explain
        end
        if by.intimidation then  -- fear like effect
            add('warn', 'Intimidation can make the target flee, which can cause a train.')  -- trains are dangerous
        end

        -- Spell choices.
        for school in pairs(castSchools) do
            local name, how = spells.choose(school)
            if not name then
                add('warn', '%s: %s.', school, how)  -- no spell for this school
            else
                local info = spells.book[name]  -- scan details
                if info and info.fear then add('error', '%s override "%s" has a fear effect. Fear causes trains; choose another.', school, name) end  -- fear never allowed
                if info and not info.safe and not info.fear then add('warn', '%s override "%s" is unsafe for training: %s.', school, name, info.unsafeWhy) end  -- other unsafe override
                if spells.needsEnemy(name) and not abilities.combatTarget() then  -- harmful spell without a target
                    add('warn', '%s spell "%s" is harmful and needs a target. It waits until you target an NPC.', school, name)  -- explain the wait
                end
            end
            if spells.blocked[school] then add('error', '%s blocked this run: %s.', school, spells.blocked[school]) end  -- fatal cast result this run
        end
        local nSchools = 0  -- count schools
        for _ in pairs(castSchools) do nSchools = nSchools + 1 end  -- pairs has no length operator
        local gems = (tonumber(mq.TLO.Me.NumGems()) or 8) - s.firstGem + 1      -- gems available to borrow
        if nSchools > gems then add('info', '%d schools share %d gems, so spells will be swapped often.', nSchools, gems) end

        -- Per entry requirements.
        for _, e in ipairs(active) do
            if e.method ~= 'cast' and e.method ~= 'passive' and e.method ~= 'hint' then
                local why = abilities.requirement(e)
                if why then add('warn', '%s: %s.', catalog.label(e), why) end  -- missing gear, plugin or target
            end
        end
        if by.bash and not abilities.hasShield() and skills.available(catalog.byKey('slam')) then  -- no shield but Slam exists
            add('info', 'No shield: tick "Bash (via Slam)" instead to raise Bash.')  -- suggest Slam
        end
        if (by.begging or by.safefall) and not plugins.navReady() and plugins.has('MQ2Nav') then  -- mesh missing here
            add('info', 'MQ2Nav has no mesh for this zone; trips need a mesh in the destination zone.')  -- mesh is per zone
        end
        if by.begging then add('info', 'Begging can anger the NPC. Stay ready to stop.') end  -- begging risk
        if by.safefall and not config.safeFallReady() then  -- nothing recorded yet
            add('warn', 'Safe Fall ledge and landing spot are not set. Stand on the edge and press Set ledge here in Options, drop, then press Set landing spot here.')
        end
        -- Plane of Knowledge: no falling damage since about Omens of War, so
        -- the skill cannot rise there. Player report:
        -- https://everquest.allakhazam.com/db/zones.html?zstrat=158
        if by.safefall and utils.lower(s.safeFallZone) == 'poknowledge' then
            add('error', 'Safe Fall ledge is in the Plane of Knowledge, which no longer gives falling damage, so Safe Fall will not rise. Record a ledge in another zone.')
        end
        if s.combatTargetSource == 'merc' and combatCount > 0 then  -- Skills2 merc method
            add('info', 'Mercenary as combat target is the Skills2 method; whether abilities land on your own mercenary is not verified.')  -- not verified
        end

        -- Plugins and other scripts.
        if not plugins.has('MQ2Cast') and next(castSchools) then
            add('info', 'MQ2Cast not loaded: casting uses plain /cast and fizzles are not counted.')
        end
        if by.forage and plugins.has('MQ2AutoForage') and not s.useAutoForage then  -- plugin present but disabled
            add('info', 'MQ2AutoForage is loaded but turned off in Options; plain Forage is used.')  -- explain
        end
        if plugins.has('rgmercs') and not s.pauseRGMercs then  -- RGMercs will keep acting
            add('warn', 'RGMercs is running and will not be paused; it may fight the training run.')  -- explain
        end
        if mq.TLO.Me.Invis() == true and next(castSchools) then  -- invisible caster
            add('info', 'You are invisible; casting will break it.')  -- casting breaks invis
        end

        -- Ticked but nothing to do.
        for _, e in ipairs(catalog.SKILLS) do
            if config.isSelected(e.key) and not skills.available(e) then
                add('info', '%s is ticked but this character cannot raise it now.', catalog.label(e))
            end
        end
        if #active == 0 and next(s.selected) then add('info', 'Every ticked skill is mastered or unavailable.') end  -- ticks exist but nothing to do
        return out  -- finished list
    end

    --[[--------------------------------------------------------------------------
      conflicts.list(force)

      WHAT  : Returns the warning list, rebuilt at most once a second.
      WHY   : Drawn every frame.
      WHERE : ui.lua, runner.start.
      HOW   : Rebuild when stale or forced, protected by pcall so a TLO hiccup
              shows as one warning instead of breaking the window.
      WHEN  : Every frame.
    ----------------------------------------------------------------------------]]
    function conflicts.list(force)
        -- Fresh enough: reuse.
        if not force and stamp >= 0 and utils.now() - stamp < 1000 then return cached end
        stamp = utils.now()
        local ok, res = pcall(evaluate)                                       -- never break the window
        cached = ok and res or { { level = 'warn', text = 'Could not check warnings: ' .. tostring(res) } }
        return cached
    end

    --[[--------------------------------------------------------------------------
      conflicts.hasErrors()

      WHAT  : True when the current list contains an error.
      WHY   : Start is refused while errors show and the Block option is on.
      WHERE : runner.start.
      HOW   : Forced rebuild, then scan for level 'error'.
      WHEN  : At Start.
    ----------------------------------------------------------------------------]]
    function conflicts.hasErrors()
        -- Forced so a just ticked box counts.
        for _, c in ipairs(conflicts.list(true)) do
            if c.level == 'error' then return true end
        end
        return false  -- no errors found
    end
end  -- of the conflicts section

--[[==========================================================================
  END OF SECTION : conflicts

  PUBLIC
    specState(), specBlocked(school), list(force), hasErrors()

  DEPENDENCIES : mq, core.lua/utils, config, catalog, skills, plugins,
                 spells, abilities

  HOW TO EDIT SAFELY
    - Each check in evaluate is independent; add new ones anywhere and use
      add(level, fmt, ...). Keep messages short; they wrap in the window.
    - Only use 'error' for things that are genuinely unsafe or mutually
      exclusive, because errors block Start.
==========================================================================]]--

--[[==========================================================================
  SECTION     : runner   (was skillmaster/runner.lua up to 1.0.5)
  CREDITS     : Start and go loop (GoldenFrog, Skill Skillup 1.1); stop at
                cap (Blasty, Skills2 0.4.2).
  HISTORY     : 1.0.5  Version number only; no code change.
                1.0.4  runner.endScript flag for the End SkillMaster button.
                1.0.3  A trip whose skill reaches its cap now finishes its
                       way home (Begging return zone) before the run ends.
                1.0.2  Version number only; no code change.
                1.0.1  The run stops with the trip's reason when a failed
                       trip is all that is left. Hide, Sneak and Feign
                       Death are no longer trained at the Begging spot
                       (they made the NPC unable to see you).
                1.0.0  First release. Replaces the separate loops of Skills2
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
do  -- runner section scope: locals declared here stay inside it
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
    runner.endScript  = false      -- set by the End SkillMaster button and /skm end:
                                   -- after the tidy shutdown, init.lua sends
                                   -- /lua stop skillmaster

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

        -- 1b. A trip whose skill just reached its cap still finishes: Begging
        --     travels home to beggingReturn (blank = stay), Safe Fall just ends.
        if travel.trip and (travel.trip.phase == 'work' or travel.trip.phase == 'home') then
            local e = catalog.byKey(travel.trip.key)                          -- the trip's entry
            if e and skills.mastered(e) and travel.tick(e) then               -- still on its way
                runner.status = 'Trip: ' .. (travel.trip and travel.trip.status or '')  -- show the step
                return
            end
        end

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
        --     Same for a trip that failed: it will not restart this run, so
        --     when nothing else is left, stop and show the trip's reason.
        local onlyPassive, failedTrip, other = false, nil, false  -- what is left
        for _, e in ipairs(active) do
            if e.method == 'passive' then onlyPassive = true                 -- Meditate
            elseif e.method == 'travel' and travel.failed(e.key) then failedTrip = e  -- dead trip
            else other = true break end                                      -- real work remains
        end
        if not other and failedTrip then
            runner.stop(string.format('%s trip stopped: %s', failedTrip.name, travel.trip and travel.trip.status or 'failed'))
            return
        end
        if not other and onlyPassive then  -- Meditate cannot be trained alone
            -- Explain why instead of sitting at full mana forever.
            runner.stop('Only Meditate is left; it rises while mana regenerates, so keep it ticked alongside a casting school')
            return
        end

        -- 3. Trips run one at a time, Begging first.
        for _, e in ipairs(active) do
            if e.method == 'travel' and not travel.failed(e.key) then
                if travel.tick(e) then
                    runner.status = 'Trip: ' .. (travel.trip and travel.trip.status or '')  -- show the trip step
                    if travel.trip and travel.trip.phase == 'work' then        -- at the spot: utility too
                        local begging = travel.trip.key == 'begging'           -- NPC must see you
                        for _, u in ipairs(active) do
                            -- While begging skip Hide / Sneak (toggles) and Feign
                            -- Death: they make you unseen or lying down, and the
                            -- game answers every beg with "can't see you".
                            local blocks = begging and (u.method == 'toggle' or u.method == 'feign')
                            if u.group == 'utility' and not blocks then abilities.train(u) end
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
end  -- of the runner section

--[[==========================================================================
  END OF SECTION : runner

  PUBLIC
    state, status, request, meditating, quitting, endScript
    activeEntries(), start(), stop(reason), pause(), resume(), process(),
    tick()

  DEPENDENCIES : mq, core.lua/utils, config, catalog, skills, plugins,
                 spells, abilities, travel, conflicts, stats

  HOW TO EDIT SAFELY
    - Keep the tick order. Safety must stay first and meditation must stay
      before abilities, or the character stands up every tick.
    - Never call runner.start or runner.stop from the window; set
      runner.request instead.
==========================================================================]]--

-- Hand the section tables to whoever requires this file.
return { conflicts = conflicts, runner = runner }

--[[==========================================================================
  END OF FILE : skillmaster/engine.lua

  PUBLIC  (returned table)
    conflicts  list, hasErrors, specState, specBlocked
    runner     state, status, request, process, tick, start, pause, resume,
               stop, activeEntries, meditating, endScript, quitting

  DEPENDENCIES : mq, skillmaster.core, skillmaster.data, skillmaster.actions

  HOW TO EDIT SAFELY
    - conflicts must stay above runner in this file.
    - Never send a game command from conflicts; it only judges.
==========================================================================]]--
