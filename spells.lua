--[[==========================================================================
  FILE        : skillmaster/spells.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.4
  CHANGES     : 1.0.4  Version number only; no code change.
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

  WHERE : Called by runner.lua (scan, assign gems, cast, restore), ui.lua
          (Spells tab), conflicts.lua (blocked schools, fear check).

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

local mq      = require('mq')                   -- TLO, delay
local utils   = require('skillmaster.utils')    -- cmd, delay, echo
local config  = require('skillmaster.config')   -- settings
local catalog = require('skillmaster.catalog')  -- schools, class spells, unsafe SPAs
local plugins = require('skillmaster.plugins')  -- MQ2Cast check
local stats   = require('skillmaster.stats')    -- counters and log

local spells = {}

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
-- WHERE: Set by spells.cast, read by runner.lua and ui.lua.
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
  WHERE : runner.lua, ui.drawSpells, conflicts.lua.
  HOW   : 1. Override from settings if it is in the book and of that school
             (overrides may be unsafe; conflicts.lua warns about fear).
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
  WHERE : runner.lua, conflicts.lua.
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
  WHERE : runner.lua.
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
  WHERE : spells.cast (before and after), abilities.lua after Forage and
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
  WHERE : runner.lua.
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

return spells  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/spells.lua

  PUBLIC
    book, bySchool, scanned, blocked, gemFor, lastResult
    scan(), choose(school), needsEnemy(name), mana(name),
    assignGems(schools), clearCursor(afterOwnCast), cast(school, name, id),
    restoreGems()

  DEPENDENCIES : mq, skillmaster.utils, config, catalog, plugins, stats

  HOW TO EDIT SAFELY
    - Never remove the safety check in spells.scan. A Gate spell picked as
      the Alteration trainer would send the character home mid run.
    - Overrides deliberately skip the safety check so an advanced operator
      can choose; conflicts.lua must keep warning about fear overrides.
    - /destroy only runs on NoRent items and only right after our own cast.
==========================================================================]]--
