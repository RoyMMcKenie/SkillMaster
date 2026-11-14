--[[==========================================================================
  FILE        : skillmaster/conflicts.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.4
  CHANGES     : 1.0.4  Version number only; no code change.
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
          conflicts.specBlocked(school) is asked by runner.lua before each
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

local mq        = require('mq')                     -- TLO
local utils     = require('skillmaster.utils')      -- now
local config    = require('skillmaster.config')     -- settings
local catalog   = require('skillmaster.catalog')    -- entries, schools
local skills    = require('skillmaster.skills')     -- values, available
local plugins   = require('skillmaster.plugins')    -- helper state
local spells    = require('skillmaster.spells')     -- chosen spells
local abilities = require('skillmaster.abilities')  -- requirements

local conflicts = {}

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
  WHERE : runner.lua before every cast.
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
    if by.begging and by.safefall then
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
    if by.safefall then add('info', 'Safe Fall ledge location comes from Skills2 and is not verified for current Plane of Knowledge.') end  -- location not verified
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

return conflicts  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/conflicts.lua

  PUBLIC
    specState(), specBlocked(school), list(force), hasErrors()

  DEPENDENCIES : mq, skillmaster.utils, config, catalog, skills, plugins,
                 spells, abilities

  HOW TO EDIT SAFELY
    - Each check in evaluate is independent; add new ones anywhere and use
      add(level, fmt, ...). Keep messages short; they wrap in the window.
    - Only use 'error' for things that are genuinely unsafe or mutually
      exclusive, because errors block Start.
==========================================================================]]--
