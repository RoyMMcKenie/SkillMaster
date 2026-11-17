--[[==========================================================================
  FILE        : skillmaster/actions.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.1.0
  CHANGES     : 1.1.0  Consolidation. spells.lua, abilities.lua and travel.lua were
                       merged into this one file as sections. Code is
                       unchanged; each section keeps its own doc block,
                       history and private locals (do ... end scope).
                1.0.0 to 1.0.5  See the HISTORY line of each section and
                       CHANGELOG.md.

  CREDITS     : spells section: class default spells from Skills2 0.4.2 by
                Blasty (RedGuides resource 2302) and Skill Skillup 1.1,
                skillup.lua, by GoldenFrog (RedGuides resource 2937).
                abilities section: passive and active ability loops and
                mercenary targeting from Skills2. travel section: the
                Begging trip to Diggs and the Safe Fall routine from
                Skills2. Full lineage in README, Credits and attribution.

  WHAT  : Everything that makes the character do something. Three sections:
            spells     spell book scan, safety check, spell choice per
                       school, gem borrowing and restore, the cast, cursor
                       cleanup
            abilities  pressing abilities, toggles, Feign Death, Tracking,
                       Forage, combat target and approach
            travel     the Begging and Safe Fall trips as a small state
                       machine (zone, spot, work, home)

  WHY   : These are the three ways a skill gets trained: cast, press, or go
          somewhere and repeat. They share the same helpers (cursor cleanup,
          ability ready, navigation) and are all driven by engine.lua/runner
          one step per tick.

  WHERE : <MacroQuest>/lua/skillmaster/actions.lua
          Required by engine.lua, ui.lua, init.lua.

  HOW   : local actions = require('skillmaster.actions')
          local spells, abilities, travel =
                actions.spells, actions.abilities, actions.travel
          Every command is sent through core.lua/utils.cmd and listed with
          its documentation source in ARCHITECTURE.md.

  WHEN  : Called by engine.lua/runner during a run; spells.restoreGems and
          travel.cancel also run at Stop and at End SkillMaster.

  READING GUIDE (for future you)
    - abilities uses spells.clearCursor, so spells comes first.
    - No command may be added without a source row in ARCHITECTURE.md.
==========================================================================]]--

local mq      = require('mq')                  -- TLO, delay, event
local core    = require('skillmaster.core')    -- foundation layer
local utils   = core.utils                     -- cmd, delay, echo, lower
local config  = core.config                    -- settings
local plugins = core.plugins                   -- MQ2Cast, MQ2Nav, EasyFind, AutoForage
local data    = require('skillmaster.data')    -- knowledge layer
local catalog = data.catalog                   -- schools, class spells, unsafe SPAs
local skills  = data.skills                    -- abilityReady, mastered
local stats   = data.stats                     -- counters and log

-- Section tables, declared up front so every section below (and the
-- return at the bottom) can see them. Each is filled inside its own
-- do ... end block, which keeps that section's private locals private.
local spells    = {}   -- spells section, see its block below
local abilities = {}   -- abilities section, see its block below
local travel    = {}   -- travel section, see its block below

--[[==========================================================================
  SECTION     : spells   (was skillmaster/spells.lua up to 1.0.5)
  CREDITS     : Class default spells (Blasty, Skills2 0.4.2; GoldenFrog,
                Skill Skillup 1.1).
  HISTORY     : 1.0.5  Version number only; no code change.
                1.0.4  Version number only; no code change.
                1.0.3  Version number only; no code change.
                1.0.2  Version number only; no code change.
                1.0.1  Version number only; no code change.
                1.0.0  First release. Combines the INI driven class spells of
                       Skills2 and the per class tables of skillup.lua, and
                       adds: spell book scan, automatic safe spell choice,
                       per school overrides, MQ2Cast result handling, gem
                       borrowing with restore, and temporary item cleanup.

  WHAT  : Everything to do with spells: reads the spell book, picks one
          training spell per school, memorises it into a borrowed gem, casts
          it (through MQ2Cast when loaded), deals with any summoned item on
          the cursor, and puts the original gems back afterwards.

  WHY   : Both source scripts hard coded a spell per class and school, so a
          character who had not scribed that spell, or had a better cheap one,
          got nothing. Reading the book means any class at any level gets a
          sensible spell, and the operator can still type an override.

  WHERE : Called by engine.lua/runner (scan, assign gems, cast, restore), ui.lua
          (Spells tab), engine.lua/conflicts (blocked schools, fear check).

  HOW   : 1. spells.scan walks Me.Book(1..1120) once and records each spell's
             school (Spell.Skill), mana, cast time, target type and whether
             it is beneficial.
          2. spells.choose(school) picks, in order: the operator's override;
             the first class default from catalog.CLASS_SPELLS found in the
             book; otherwise the cheapest safe spell of that school.
             "Safe" means none of the effects in catalog.UNSAFE_SPA and not a
             detrimental area spell.
          3. spells.assignGems gives each school a gem from firstGem upward
             and remembers what was there.
          4. spells.cast memorises if needed, casts through MQ2Cast
             (/casting "Name|gemN" -maxtries|1 -targetid|ID) or plain
             /memspell plus /cast, reads Cast.Result, then clears the cursor:
             temporary (NoRent) summoned items are destroyed when the option
             is on, anything else goes to the bags with /autoinventory.
          5. spells.restoreGems memorises the original spells back.

  WHEN  : scan at start of each run and on the Rescan button; cast once per
          runner tick for one school; restore at the end of a run.

  READING GUIDE (for future you)
    - "School" is the spell's casting skill: Abjuration, Alteration,
      Conjuration, Divination or Evocation. Spell.Skill returns it.
    - "SPA" is a spell effect number. Spell.HasSPA(n) is true when the spell
      has that effect. The unsafe list lives in catalog.UNSAFE_SPA.
    - -maxtries|1 is deliberate: for training, each attempt is the point, so
      the runner decides when to cast again rather than MQ2Cast retrying.
    - Detrimental spells (Evocation nukes, Lifetap, Root) need a target. The
      runner passes the same target used for combat abilities.
==========================================================================]]--
do  -- spells section scope: locals declared here stay inside it
    --- Spell book --------------------------------------------------------------------
    -- WHAT : book[name] = info, bySchool[school] = { info, ... }.
    -- WHY  : The picker and the Spells tab both need the book, read once.
    -- WHERE: spells.scan fills them; choose and ui read them.
    -- HOW  : info = { name, school, mana, castMs, targetType, beneficial,
    --        safe, unsafeWhy, fear }.
    -- WHEN : Refilled by every scan.
    spells.book     = {}   -- spell name -> info
    spells.bySchool = {}   -- school -> list of info
    spells.scanned  = false -- true after the first scan

    --- Blocked schools -----------------------------------------------------------------
    -- WHAT : blocked[school] = reason text, when casting it cannot succeed.
    -- WHY  : Missing components or an unknown spell will not fix themselves;
    --        the runner must stop trying that school and say why.
    -- WHERE: Set by spells.cast, read by engine.lua/runner and ui.lua.
    -- HOW  : Cleared on each scan and each new run.
    -- WHEN : After a fatal cast result.
    spells.blocked = {}

    --- Gem bookkeeping --------------------------------------------------------------------
    -- WHAT : gemFor[school] = gem number; original[gem] = spell name or false.
    -- WHY  : Restore the bar exactly as it was.
    -- WHERE: assignGems, cast, restoreGems.
    -- HOW  : false means the gem was empty.
    -- WHEN : Filled at the start of a run, emptied by restoreGems.
    spells.gemFor  = {}
    local original = {}

    --- Last result -------------------------------------------------------------------------
    -- WHAT : Text of the last cast outcome, for the status line.
    -- WHY  : Shows the operator what MQ2Cast said.
    -- WHERE: Written by cast, read by ui.lua.
    -- HOW  : Plain string.
    -- WHEN : After each cast.
    spells.lastResult = ''

    --[[==========================================================================
      FATAL_RESULTS

      WHAT  : MQ2Cast Cast.Result codes that block a school until the next run.
      WHY   : Recasting cannot fix a missing component or an unknown spell.
      WHERE : spells.cast.
      HOW   : code -> readable reason. Codes from the MQ2Cast documentation:
              https://docs.macroquest.org/plugins/community-plugins/mq2cast/
      WHEN  : After every MQ2Cast cast.
    ==========================================================================]]--
    local FATAL_RESULTS = {
        CAST_COMPONENTS = 'missing a reagent or component',
        CAST_UNKNOWN    = 'spell not recognised',
        CAST_NOTARGET   = 'spell needs a target and none was valid',  -- retried: target may come back
        CAST_CANNOTSEE  = 'target not in line of sight',  -- retried: target may move into view
    }

    --[[--------------------------------------------------------------------------
      checkSafety(spell)

      WHAT  : Decides whether a spell may be used for training. Returns
              safe (boolean), reason (text when not safe), fear (boolean).
      WHY   : Training must never gate, teleport, bind, charm, fear (trains) or
              summon pets, and must not hit everything around the character.
      WHERE : spells.scan.
      HOW   : Checks each SPA in catalog.UNSAFE_SPA with Spell.HasSPA, then
              rejects detrimental spells whose target type mentions AE.
      WHEN  : Once per spell per scan.
    ----------------------------------------------------------------------------]]
    local function checkSafety(spell)
        -- Look for any forbidden effect.
        for spa, why in pairs(catalog.UNSAFE_SPA) do
            if spell.HasSPA(spa)() == true then
                return false, why, spa == 23                 -- third value flags fear
            end
        end
        -- Area detrimental spells could pull a whole room.
        local tt = tostring(spell.TargetType() or '')        -- e.g. 'Single', 'PB AE'
        if spell.Beneficial() ~= true and tt:find('AE') then
            return false, 'area damage', false
        end
        return true, nil, false  -- nothing unsafe found
    end

    --[[--------------------------------------------------------------------------
      spells.scan()

      WHAT  : Reads the whole spell book into spells.book and spells.bySchool.
      WHY   : The picker needs to know what is scribed and how each spell acts.
      WHERE : runner.start, ui.lua Rescan button.
      HOW   : Me.Book(i) for i = 1..1120 (the book size used in current
              clients); each slot that holds a spell is recorded with its
              school and safety. Blocked schools are cleared.
      WHEN  : Start of each run and on request.
    ----------------------------------------------------------------------------]]
    function spells.scan()
        spells.book, spells.bySchool, spells.blocked = {}, {}, {}   -- start clean
        for _, s in ipairs(catalog.SCHOOLS) do spells.bySchool[s.school] = {} end  -- empty list per school
        local count = 0                                            -- spells found
        for i = 1, 1120 do
            local sp = mq.TLO.Me.Book(i)                           -- spell in this book slot
            local name = sp.Name()                                 -- nil when the slot is empty
            if name and name ~= '' then
                local school = sp.Skill()                          -- casting skill of the spell
                local safe, why, fear = checkSafety(sp)            -- allowed for training?
                local info = {
                    name       = name,
                    school     = school,
                    mana       = tonumber(sp.Mana()) or 0,         -- mana cost
                    castMs     = tonumber(sp.MyCastTime.Raw()) or 0, -- cast time in ms
                    targetType = tostring(sp.TargetType() or ''),  -- Self, Single, ...
                    beneficial = sp.Beneficial() == true,          -- buff/heal vs harmful
                    safe       = safe,
                    unsafeWhy  = why,
                    fear       = fear,
                }
                spells.book[name] = info                           -- index by name
                if spells.bySchool[school] then table.insert(spells.bySchool[school], info) end  -- only the five schools
                count = count + 1
            end
        end
        spells.scanned = true                                      -- remember that we looked
        utils.debug('Spell book scan: %d spells.', count)
    end

    --[[--------------------------------------------------------------------------
      usable(info)

      WHAT  : True when a spell can be cast right now for training.
      WHY   : Dance of the Fireflies is useless at night (skillup.lua skipped it).
      WHERE : spells.choose.
      HOW   : Checks safety and the night skip list against GameTime.Night.
      WHEN  : While choosing.
    ----------------------------------------------------------------------------]]
    local function usable(info)
        -- Unsafe spells are never picked automatically.
        if not info.safe then return false end
        if catalog.NIGHT_SKIP[info.name] and mq.TLO.GameTime.Night() == true then return false end  -- daylight only
        return true
    end

    --[[--------------------------------------------------------------------------
      spells.choose(school)

      WHAT  : Returns the spell name to train a school with, and how it was
              chosen ('override', 'class default', 'auto'), or nil and a reason.
      WHY   : One place decides, so the Spells tab shows exactly what the run
              will cast.
      WHERE : engine.lua/runner, ui.drawSpells, engine.lua/conflicts.
      HOW   : 1. Override from settings if it is in the book and of that school
                 (overrides may be unsafe; engine.lua/conflicts warns about fear).
              2. First class default in the book that is usable.
              3. Usable spell of the school preferring beneficial, then lowest
                 mana, then shortest cast time.
      WHEN  : Every frame for the Spells tab and every cast.
    ----------------------------------------------------------------------------]]
    function spells.choose(school)
        -- The book must have been read first.
        if not spells.scanned then return nil, 'spell book not scanned yet' end

        -- 1. Operator override.
        local ov = config.settings.spellOverride[school]
        if ov and ov ~= '' then
            local info = spells.book[ov]                                   -- must be scribed
            if not info then return nil, 'override "' .. ov .. '" is not in your spell book' end
            if info.school ~= school then return nil, 'override "' .. ov .. '" is ' .. tostring(info.school) end
            return ov, 'override'
        end

        -- 2. Class defaults from both source scripts.
        local cls = mq.TLO.Me.Class.ShortName() or ''                      -- e.g. 'CLR'
        local defaults = (catalog.CLASS_SPELLS[cls] or {})[school] or {}   -- may be empty
        for _, name in ipairs(defaults) do
            local info = spells.book[name]
            if info and info.school == school and usable(info) then return name, 'class default' end
        end

        -- 3. Automatic pick.
        local best = nil                                                   -- best candidate so far
        for _, info in ipairs(spells.bySchool[school] or {}) do
            if usable(info) then
                if best == nil
                   or (info.beneficial and not best.beneficial)            -- buffs need no enemy
                   or (info.beneficial == best.beneficial and (info.mana < best.mana
                       or (info.mana == best.mana and info.castMs < best.castMs))) then
                    best = info
                end
            end
        end
        if best then return best.name, 'auto' end  -- cheapest safe spell
        return nil, 'no safe ' .. school .. ' spell in your book'  -- nothing suitable scribed
    end

    --[[--------------------------------------------------------------------------
      spells.needsEnemy(name)

      WHAT  : True when a spell is detrimental and must be cast on an enemy.
      WHY   : The runner must supply a target or skip the school.
      WHERE : engine.lua/runner, engine.lua/conflicts.
      HOW   : Not beneficial and target type is not Self.
      WHEN  : Before each cast.
    ----------------------------------------------------------------------------]]
    function spells.needsEnemy(name)
        local info = spells.book[name]                                    -- from the scan
        if not info then return false end
        return (not info.beneficial) and info.targetType ~= 'Self'        -- harmful, aimed at something
    end

    --[[--------------------------------------------------------------------------
      spells.mana(name)

      WHAT  : Mana cost of a scanned spell, 0 if unknown.
      WHY   : The runner meditates when the next cast is not affordable.
      WHERE : engine.lua/runner.
      HOW   : Lookup in the book.
      WHEN  : Before each cast.
    ----------------------------------------------------------------------------]]
    function spells.mana(name)
        local info = spells.book[name]   -- may be nil
        return info and info.mana or 0
    end

    --[[--------------------------------------------------------------------------
      spells.assignGems(schools)

      WHAT  : Gives each school in the list its own gem and remembers what each
              borrowed gem held.
      WHY   : Training five schools by swapping one gem would spend most of the
              time memorising. One gem per school, as Skills2 used gems 1 to 5.
      WHERE : runner.start.
      HOW   : Gems firstGem, firstGem+1, ... up to Me.NumGems. Schools beyond
              the last gem share it (memorised in turn).
      WHEN  : Start of a run.
    ----------------------------------------------------------------------------]]
    function spells.assignGems(schools)
        spells.gemFor = {}                                                -- forget the last run
        local first = config.settings.firstGem                            -- first gem we may use
        local last  = tonumber(mq.TLO.Me.NumGems()) or 8                  -- gems this character has
        for i, school in ipairs(schools) do
            local gem = math.min(first + i - 1, last)                     -- never past the last gem
            spells.gemFor[school] = gem
            if original[gem] == nil then
                original[gem] = mq.TLO.Me.Gem(gem).Name() or false        -- false means empty gem
            end
        end
    end

    --[[--------------------------------------------------------------------------
      memorize(name, gem)

      WHAT  : Makes sure a spell is in a given gem and ready. Returns true when
              ready.
      WHY   : Plain /cast needs the spell memorised; MQ2Cast would memorise it
              too, but doing it here gives one behaviour for both paths.
      WHERE : spells.cast.
      HOW   : If the gem already holds it, wait for SpellReady. Otherwise
              /memspell gem "name" (MacroQuest command
              https://docs.macroquest.org/reference/commands/memspell/), wait up
              to 20 seconds for it to land, then for SpellReady.
      WHEN  : Before each cast.
    ----------------------------------------------------------------------------]]
    local function memorize(name, gem)
        -- Already there: only the refresh timer matters.
        if mq.TLO.Me.Gem(gem).Name() ~= name then
            utils.cmd('/memspell %d "%s"', gem, name)                     -- memorise into the gem
            if not utils.delay(20000, function() return mq.TLO.Me.Gem(gem).Name() == name end) then
                return false                                              -- did not land (or Stop)
            end
        end
        return utils.delay(15000, function() return mq.TLO.Me.SpellReady(gem)() == true end)  -- refresh timer
    end

    --[[--------------------------------------------------------------------------
      spells.clearCursor(afterOwnCast)

      WHAT  : Empties the cursor. Returns true when it is empty.
      WHY   : An item on the cursor blocks casting and summoned training items
              (food, drink, light) pile up fast.
      WHERE : spells.cast (before and after), actions.lua/abilities after Forage and
              Fishing when MQ2AutoForage is not used.
      HOW   : If afterOwnCast and the Destroy option is on and the item is
              NoRent (temporary), /destroy (destroys the cursor item without a
              prompt: https://docs.macroquest.org/reference/commands/destroy/).
              Anything else: /autoinventory. Waits up to 2 seconds.
      WHEN  : Around each cast or foraged item.
    ----------------------------------------------------------------------------]]
    function spells.clearCursor(afterOwnCast)
        -- Nothing held, nothing to do.
        if mq.TLO.Cursor.ID() == nil then return true end
        local name = mq.TLO.Cursor.Name() or '?'                          -- for the log
        if afterOwnCast and config.settings.destroySummoned and mq.TLO.Cursor.NoRent() == true then
            utils.cmd('/destroy')                                         -- temporary summoned item
            utils.debug('Destroyed summoned %s', name)
        else
            utils.cmd('/autoinventory')                                   -- keep it in the bags
        end
        return utils.delay(2000, function() return mq.TLO.Cursor.ID() == nil end)  -- confirm empty
    end

    --[[--------------------------------------------------------------------------
      castMQ2Cast(name, gem, targetId)

      WHAT  : One cast through MQ2Cast. Returns the Cast.Result code.
      WHY   : MQ2Cast reports exactly why a cast failed.
      WHERE : spells.cast.
      HOW   : /casting "name|gemN" -maxtries|1 and -targetid|ID when a target is
              given; wait for Cast.Status to leave and return to idle ('I').
      WHEN  : Each cast while MQ2Cast is in use.
    ----------------------------------------------------------------------------]]
    local function castMQ2Cast(name, gem, targetId)
        -- Optional target part of the command.
        local tgt = targetId and string.format(' -targetid|%d', targetId) or ''
        utils.cmd('/casting "%s|gem%d" -maxtries|1%s', name, gem, tgt)   -- e.g. /casting "True North|gem1" -maxtries|1
        utils.delay(2000, function() return mq.TLO.Cast.Status() ~= 'I' end)  -- MQ2Cast picked it up
        utils.delay(30000, function() return mq.TLO.Cast.Status() == 'I' end) -- finished
        if utils.aborted() then utils.cmd('/interrupt') return 'CAST_ABORTED' end  -- Stop pressed mid cast
        return mq.TLO.Cast.Result() or 'CAST_UNKNOWN'
    end

    --[[--------------------------------------------------------------------------
      castPlain(name, gem, targetId)

      WHAT  : One cast with plain commands. Returns 'CAST_SUCCESS' or a
              best guess code.
      WHY   : Fallback when MQ2Cast is not loaded or turned off.
      WHERE : spells.cast.
      HOW   : /mqtarget id N when a target is given (MacroQuest spawn search,
              https://docs.macroquest.org/reference/commands/target/), then
              /cast N on the gem number, wait for the cast bar to start and end.
              Cannot see fizzles; the skill up event still counts gains.
      WHEN  : Each cast while MQ2Cast is not used.
    ----------------------------------------------------------------------------]]
    local function castPlain(name, gem, targetId)
        -- Target first when the spell needs one.
        if targetId and mq.TLO.Target.ID() ~= targetId then
            utils.cmd('/mqtarget id %d', targetId)                         -- spawn search by id
            utils.delay(1000, function() return mq.TLO.Target.ID() == targetId end)
        end
        utils.cmd('/cast %d', gem)                                         -- EverQuest cast by gem number
        if not utils.delay(1500, function() return mq.TLO.Me.Casting.ID() ~= nil end) then
            return 'CAST_NOTREADY'                                         -- never started
        end
        utils.delay(30000, function() return mq.TLO.Me.Casting.ID() == nil end)  -- wait for the bar to end
        return 'CAST_SUCCESS'
    end

    --[[--------------------------------------------------------------------------
      spells.cast(school, name, targetId)

      WHAT  : Casts the school's training spell once. Returns the result code.
      WHY   : The unit of work the runner repeats for casting schools.
      WHERE : engine.lua/runner.
      HOW   : Clear cursor, memorise into the school's gem, cast by MQ2Cast or
              plain, count the cast and any fizzle, block the school on a fatal
              result, then clear the cursor (destroying temporary summons).
      WHEN  : Once per runner tick for one school.
    ----------------------------------------------------------------------------]]
    function spells.cast(school, name, targetId)
        local gem = spells.gemFor[school] or config.settings.firstGem      -- borrowed gem
        if not spells.clearCursor(false) then
            spells.lastResult = 'cursor stuck'
            return 'CAST_CURSOR'                                           -- cannot cast with a held item
        end
        if not memorize(name, gem) then
            spells.lastResult = 'could not memorise ' .. name
            return 'CAST_NOTREADY'  -- cast bar never appeared
        end
        local useCast = config.settings.useMQ2Cast and plugins.has('MQ2Cast')  -- preferred path
        local result = useCast and castMQ2Cast(name, gem, targetId) or castPlain(name, gem, targetId)
        spells.lastResult = name .. ': ' .. result                         -- for the status line
        stats.count('casts')                                               -- every attempt counts
        if result == 'CAST_FIZZLE' then stats.count('fizzles') end
        if FATAL_RESULTS[result] and result ~= 'CAST_NOTARGET' and result ~= 'CAST_CANNOTSEE' then
            spells.blocked[school] = FATAL_RESULTS[result]                 -- stop trying this school
            utils.err('%s blocked: %s (%s).', school, FATAL_RESULTS[result], name)
            stats.log('%s blocked: %s', school, FATAL_RESULTS[result])
        end
        utils.delay(1000, function() return mq.TLO.Cursor.ID() ~= nil end) -- summoned item appears shortly after
        spells.clearCursor(true)                                           -- destroy or keep it
        return result
    end

    --[[--------------------------------------------------------------------------
      spells.restoreGems()

      WHAT  : Puts the original spells back in every borrowed gem.
      WHY   : Leaves the spell bar as it was for normal play.
      WHERE : runner.stop.
      HOW   : /memspell each original, waiting up to 20 seconds each. Uses
              mq.delay, not utils.delay, so it still finishes after Stop.
              Empty gems are left with the training spell (EverQuest has no
              documented command to clear a single gem).
      WHEN  : End of a run when the Restore option is on.
    ----------------------------------------------------------------------------]]
    function spells.restoreGems()
        -- Only touch gems we borrowed.
        if config.settings.restoreGems then
            for gem, name in pairs(original) do
                if name and mq.TLO.Me.Gem(gem).Name() ~= name then
                    utils.cmd('/memspell %d "%s"', gem, name)              -- put it back
                    mq.delay(20000, function() return mq.TLO.Me.Gem(gem).Name() == name end)  -- wait even after Stop
                end
            end
        end
        original, spells.gemFor = {}, {}                                   -- nothing borrowed now
    end
end  -- of the spells section

--[[==========================================================================
  END OF SECTION : spells

  PUBLIC
    book, bySchool, scanned, blocked, gemFor, lastResult
    scan(), choose(school), needsEnemy(name), mana(name),
    assignGems(schools), clearCursor(afterOwnCast), cast(school, name, id),
    restoreGems()

  DEPENDENCIES : mq, core.lua/utils, config, catalog, plugins, stats

  HOW TO EDIT SAFELY
    - Never remove the safety check in spells.scan. A Gate spell picked as
      the Alteration trainer would send the character home mid run.
    - Overrides deliberately skip the safety check so an advanced operator
      can choose; engine.lua/conflicts must keep warning about fear overrides.
    - /destroy only runs on NoRent items and only right after our own cast.
==========================================================================]]--

--[[==========================================================================
  SECTION     : abilities   (was skillmaster/abilities.lua up to 1.0.5)
  CREDITS     : Passive and active ability loops, mercenary target (Blasty,
                Skills2 0.4.2).
  HISTORY     : 1.0.5  New 'ledge' requirement: Safe Fall waits until the ledge
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

  WHERE : Called by engine.lua/runner each tick. engine.lua/conflicts and ui.lua use the
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
do  -- abilities section scope: locals declared here stay inside it
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
      WHERE : abilities.requirement, engine.lua/conflicts.
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
      WHERE : abilities.train, engine.lua/runner (harmful spells), engine.lua/conflicts.
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
      WHERE : abilities.train (combat), engine.lua/runner before a harmful spell
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
      WHERE : abilities.train, engine.lua/conflicts.
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
      WHERE : engine.lua/runner.
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
end  -- of the abilities section

--[[==========================================================================
  END OF SECTION : abilities

  PUBLIC
    autoForageStarted, waiting
    hasShield(), hasFishingGear(), combatTarget(), approach(id, needRange),
    requirement(entry), stopForage(), train(entry)

  DEPENDENCIES : mq, core.lua/utils, config, plugins, skills, stats, spells

  HOW TO EDIT SAFELY
    - Every press must stay behind skills.abilityReady, or chat fills with
      "You can not use this ability right now".
    - Feign Death checks CombatState so it never drops aggro onto a group.
==========================================================================]]--

--[[==========================================================================
  SECTION     : travel   (was skillmaster/travel.lua up to 1.0.5)
  CREDITS     : Begging trip to Diggs and the Safe Fall routine (Blasty,
                Skills2 0.4.2).
  HISTORY     : 1.0.5  Safe Fall uses a ledge and landing spot you record
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

  WHERE : Called by engine.lua/runner when a travel entry is ticked. Only one trip
          runs at a time; engine.lua/conflicts warns when both are ticked.

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
do  -- travel section scope: locals declared here stay inside it
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
      WHERE : engine.lua/runner.
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
      WHERE : engine.lua/runner.
      HOW   : Compares the trip key and phase.
      WHEN  : Each tick.
    ----------------------------------------------------------------------------]]
    function travel.failed(key)
        return travel.trip ~= nil and travel.trip.key == key and travel.trip.phase == 'failed'  -- failed trip kept for display
    end
end  -- of the travel section

--[[==========================================================================
  END OF SECTION : travel

  PUBLIC
    trip, unseenPending, unseenTries, init(), shutdown(), tick(entry),
    cancel(), failed(key)

  DEPENDENCIES : mq, core.lua/utils, config, plugins, skills, stats

  HOW TO EDIT SAFELY
    - Always pair /keypress forward hold with the release line; fallOnce
      uses mq.delay for the hold so Stop cannot skip the release.
    - The unseen event pattern uses #*# around "can" and "see you" on
      purpose; do not type the apostrophe into the pattern.
    - Keep failed trips in travel.trip (phase 'failed') so the window can
      show why; runner.stop clears it.
==========================================================================]]--

-- Hand the section tables to whoever requires this file.
return { spells = spells, abilities = abilities, travel = travel }

--[[==========================================================================
  END OF FILE : skillmaster/actions.lua

  PUBLIC  (returned table)
    spells     scan, scanned, book, bySchool, choose, blocked, needsEnemy,
               gemFor, assignGems, restoreGems, cast, lastResult, mana,
               clearCursor
    abilities  requirement, waiting, train, approach, combatTarget,
               stopForage, autoForageStarted, hasShield, hasFishingGear
    travel     init, shutdown, tick, cancel, trip, failed, forwardHeld,
               unseenPending, unseenTries

  DEPENDENCIES : mq, skillmaster.core, skillmaster.data

  HOW TO EDIT SAFELY
    - Keep the section order spells, abilities, travel.
    - Stop paths (forage, nav, held forward key) must only send their stop
      command when that movement is actually in progress (1.0.3 rule).
==========================================================================]]--
