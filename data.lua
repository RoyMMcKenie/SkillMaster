--[[==========================================================================
  FILE        : skillmaster/data.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.1.0
  CHANGES     : 1.1.0  Consolidation. catalog.lua, skills.lua and stats.lua were
                       merged into this one file as sections. Code is
                       unchanged; each section keeps its own doc block,
                       history and private locals (do ... end scope).
                1.0.0 to 1.0.5  See the HISTORY line of each section and
                       CHANGELOG.md.

  CREDITS     : catalog section: skill list from Skills2 0.4.2 by Blasty
                (RedGuides resource 2302), class spell tables and the Dance
                of the Fireflies night rule from Skill Skillup 1.1,
                skillup.lua, by GoldenFrog (RedGuides resource 2937). skills
                section: ability detection idea from Skill Skillup. stats
                section: the skill up chat pattern from Skill Skillup. Full
                lineage in README, Credits and attribution.

  WHAT  : What SkillMaster knows. Three sections:
            catalog  static data: schools, every trainable skill, class
                     default spells, the unsafe SPA list
            skills   live values: current, cap, available, mastered,
                     ability ready (500 ms cache)
            stats    session numbers, the log, the skill up chat event

  WHY   : catalog says what can be trained, skills says where the character
          stands on it, and stats records how it changed this session. They
          read each other (skills reads catalog, stats invalidates skills)
          and send no game commands, so they form one read-only layer.

  WHERE : <MacroQuest>/lua/skillmaster/data.lua
          Required by actions.lua, engine.lua, ui.lua, init.lua.

  HOW   : local data = require('skillmaster.data')
          local catalog, skills, stats = data.catalog, data.skills, data.stats

  WHEN  : Loaded once at start. stats.init registers the chat event from
          init.lua; the cache in skills refreshes on demand.

  READING GUIDE (for future you)
    - Adding a new trainable skill is a catalog edit only; skills and the
      window pick it up from catalog.SKILLS.
==========================================================================]]--

local mq    = require('mq')                  -- TLO access and the chat event
local core  = require('skillmaster.core')    -- foundation layer
local utils = core.utils                     -- now, good

-- Section tables, declared up front so every section below (and the
-- return at the bottom) can see them. Each is filled inside its own
-- do ... end block, which keeps that section's private locals private.
local catalog   = {}   -- catalog section, see its block below
local skills    = {}   -- skills section, see its block below
local stats     = {}   -- stats section, see its block below

--[[==========================================================================
  SECTION     : catalog   (was skillmaster/catalog.lua up to 1.0.5)
  CREDITS     : Skill list (Blasty, Skills2 0.4.2); class spells and night
                rule (GoldenFrog, Skill Skillup 1.1).
  HISTORY     : 1.0.5  Safe Fall notes and needs: recorded ledge, not PoK.
                1.0.4  Version number only; no code change.
                1.0.3  Version number only; no code change.
                1.0.2  Tracking note: pressed whenever ready, window state
                       does not matter.
                1.0.1  Version number only; no code change.
                1.0.0  First release. Merges the skill lists of Skills2 0.4.2
                       and skillup.lua 1.1 into one data table, adds Eagle
                       Strike, Dragon Punch, Intimidation, Bind Wound,
                       Fishing and Meditate, and the per class default spells
                       from both scripts.

  WHAT  : Pure data. Describes every skill the package knows how to train:
          its EverQuest skill name, which group it belongs to, how it is
          trained, what it needs, and notes shown in the window tooltip.
          Also holds the per class default training spells.

  WHY   : Skills2 and skillup.lua each hard coded their own lists inside the
          training code, with different spells for the same class. Keeping
          all of it in one data file means a new skill or a better spell is a
          one line change and the training code never needs editing.

  WHERE : Read by data.lua/skills (current and cap values), engine.lua/conflicts
          (requirements), engine.lua/runner (what to do each tick), actions.lua/abilities,
          actions.lua/spells and ui.lua (labels, groups, tooltips).

  HOW   : catalog.SKILLS is an ordered array of entries. Each entry has:
            key      unique id used in the settings file
            name     exact EverQuest skill name for Me.Skill / Me.SkillCap
            group    'casting' | 'specialize' | 'utility' | 'combat'
                     | 'travel' | 'passive'
            method   how runner trains it (see METHOD below)
            school   for casting and specialize entries, the spell school
            ability  name passed to /doability when it differs from name
            needs    list of requirement tags checked by engine.lua/conflicts
            notes    one line shown as the tooltip in the window
          catalog.CLASS_SPELLS lists preferred spells per class and school,
          first entry is tried first.

  WHEN  : Loaded once. Never changes at run time.

  READING GUIDE (for future you)
    - METHOD values:
        'cast'      cast spells of entry.school (casting and specialize)
        'ability'   press the ability with /doability
        'toggle'    press twice with a pause (Sneak, Hide) so you end up
                    in the state you started in, as Skills2 did
        'feign'     /doability "Feign Death" then /stand, as Skills2 did
        'tracking'  /doability Tracking whenever ready; window left as is
        'forage'    MQ2AutoForage when loaded, else /doability Forage
        'combat'    /doability on a valid NPC target in melee range
        'travel'    a scripted trip in actions.lua/travel (Begging, Safe Fall)
        'passive'   no action; rises from something else (Meditate)
        'hint'      not automated; the window only shows how to raise it
    - Requirement tags in needs: 'shield', 'bandages', 'fishing',
      'npcTarget', 'nav', 'easyfind', 'freeSlot'. engine.lua/conflicts explains
      each one to the operator.
==========================================================================]]--
do  -- catalog section scope: locals declared here stay inside it
    --[[==========================================================================
      SCHOOLS

      WHAT  : The five spell schools with their matching Specialize skill names.
      WHY   : actions.lua/spells must map a spell's school (Spell.Skill) to the
              Specialize skill that casting it raises.
      WHERE : actions.lua/spells, engine.lua/conflicts, ui.lua.
      HOW   : Ordered array; the Specialize names are the in game skill names.
              Source: https://everquest.fandom.com/wiki/Spell_school_specialization_skills
      WHEN  : Read at load and when building the Spells tab.
    ==========================================================================]]--
    catalog.SCHOOLS = {
        { school = 'Abjuration',  spec = 'Specialize Abjure' },       -- note: Abjure, not Abjuration
        { school = 'Alteration',  spec = 'Specialize Alteration' },  -- spec name as shown in the Skills window
        { school = 'Conjuration', spec = 'Specialize Conjuration' },  -- spec name as shown in the Skills window
        { school = 'Divination',  spec = 'Specialize Divination' },  -- spec name as shown in the Skills window
        { school = 'Evocation',   spec = 'Specialize Evocation' },  -- spec name as shown in the Skills window
    }

    --[[==========================================================================
      SKILLS

      WHAT  : Every trainable skill, in the order shown in the window.
      WHY   : Single source of truth for labels, groups and methods.
      WHERE : See file header.
      HOW   : Array of entry tables; fields explained in the header.
      WHEN  : Read every frame by ui.lua, every tick by engine.lua/runner.
    ==========================================================================]]--
    catalog.SKILLS = {
        -- Spell casting schools. Casting any spell of the school raises it.
        -- 'abjuration': in game skill 'Abjuration', trained by method 'cast'.
        { key = 'abjuration',  name = 'Abjuration',  group = 'casting', method = 'cast', school = 'Abjuration',
          notes = 'Cast Abjuration spells (buffs such as Minor Shielding, Endure Cold).' },
        -- 'alteration': in game skill 'Alteration', trained by method 'cast'.
        { key = 'alteration',  name = 'Alteration',  group = 'casting', method = 'cast', school = 'Alteration',
          notes = 'Cast Alteration spells (heals, Strengthen, Lifetap).' },
        -- 'conjuration': in game skill 'Conjuration', trained by method 'cast'.
        { key = 'conjuration', name = 'Conjuration', group = 'casting', method = 'cast', school = 'Conjuration',
          notes = 'Cast Conjuration spells (summoned food, drink, light).' },
        -- 'divination': in game skill 'Divination', trained by method 'cast'.
        { key = 'divination',  name = 'Divination',  group = 'casting', method = 'cast', school = 'Divination',
          notes = 'Cast Divination spells (True North, Sense Animals, Glimpse).' },
        -- 'evocation': in game skill 'Evocation', trained by method 'cast'.
        { key = 'evocation',   name = 'Evocation',   group = 'casting', method = 'cast', school = 'Evocation',
          notes = 'Cast Evocation spells. Needs a target the spell can hit, usually your pet.' },

        -- Specialization. Raised by casting the same school; only one can pass 50
        -- unless you own Secondary Forte. See engine.lua/conflicts for the rules.
        -- 'spec_abjure': in game skill 'Specialize Abjure', trained by method 'cast'.
        { key = 'spec_abjure',      name = 'Specialize Abjure',      group = 'specialize', method = 'cast', school = 'Abjuration',
          notes = 'Raised by casting Abjuration spells. Mutually exclusive with other specializations.' },
        -- 'spec_alteration': in game skill 'Specialize Alteration', trained by method 'cast'.
        { key = 'spec_alteration',  name = 'Specialize Alteration',  group = 'specialize', method = 'cast', school = 'Alteration',
          notes = 'Raised by casting Alteration spells. Mutually exclusive with other specializations.' },
        -- 'spec_conjuration': in game skill 'Specialize Conjuration', trained by method 'cast'.
        { key = 'spec_conjuration', name = 'Specialize Conjuration', group = 'specialize', method = 'cast', school = 'Conjuration',
          notes = 'Raised by casting Conjuration spells. Mutually exclusive with other specializations.' },
        -- 'spec_divination': in game skill 'Specialize Divination', trained by method 'cast'.
        { key = 'spec_divination',  name = 'Specialize Divination',  group = 'specialize', method = 'cast', school = 'Divination',
          notes = 'Raised by casting Divination spells. Mutually exclusive with other specializations.' },
        -- 'spec_evocation': in game skill 'Specialize Evocation', trained by method 'cast'.
        { key = 'spec_evocation',   name = 'Specialize Evocation',   group = 'specialize', method = 'cast', school = 'Evocation',
          notes = 'Raised by casting Evocation spells. Mutually exclusive with other specializations.' },

        -- Utility abilities that work without a target.
        -- 'forage': in game skill 'Forage', trained by method 'forage'.
        { key = 'forage',      name = 'Forage',      group = 'utility', method = 'forage', needs = { 'freeSlot' },
          notes = 'Uses MQ2AutoForage when loaded (its ini decides keep or destroy), else /doability Forage.' },
        -- 'mend': in game skill 'Mend', trained by method 'ability'.
        { key = 'mend',        name = 'Mend',        group = 'utility', method = 'ability',
          notes = 'Monk self heal. Rises whether or not you are hurt.' },
        -- 'sneak': in game skill 'Sneak', trained by method 'toggle'.
        { key = 'sneak',       name = 'Sneak',       group = 'utility', method = 'toggle',
          notes = 'Pressed twice with a pause so you end up as you started.' },
        -- 'hide': in game skill 'Hide', trained by method 'toggle'.
        { key = 'hide',        name = 'Hide',        group = 'utility', method = 'toggle',
          notes = 'Pressed twice with a pause. Breaks if you move or cast.' },
        -- 'feign': in game skill 'Feign Death', trained by method 'feign'.
        { key = 'feign',       name = 'Feign Death', group = 'utility', method = 'feign',
          notes = 'Feigns then stands. Avoid while anything is aggro on you.' },
        -- 'tracking': in game skill 'Tracking', trained by method 'tracking'.
        { key = 'tracking',    name = 'Tracking',    group = 'utility', method = 'tracking',
          notes = 'Pressed whenever ready. Each press refreshes tracking and can raise the skill; the Tracking window can be open or closed.' },
        -- 'sensetraps': in game skill 'Sense Traps', trained by method 'ability'.
        { key = 'sensetraps',  name = 'Sense Traps', group = 'utility', method = 'ability',
          notes = 'Searches for traps nearby.' },
        -- 'bindwound': in game skill 'Bind Wound', trained by method 'ability'.
        { key = 'bindwound',   name = 'Bind Wound',  group = 'utility', method = 'ability', needs = { 'bandages' },
          notes = 'Needs Bandages in your bags. Uses one each attempt. Behaviour at full health not verified.' },
        -- 'fishing': in game skill 'Fishing', trained by method 'ability'.
        { key = 'fishing',     name = 'Fishing',     group = 'utility', method = 'ability', needs = { 'fishing', 'freeSlot' },
          notes = 'Needs a Fishing Pole equipped, Fishing Bait and water in front of you.' },

        -- Combat abilities. Need a target that can be hit.
        -- 'kick': in game skill 'Kick', trained by method 'combat'.
        { key = 'kick',        name = 'Kick',         group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Needs an attackable target in melee range.' },
        -- 'bash': in game skill 'Bash', trained by method 'combat'.
        { key = 'bash',        name = 'Bash',         group = 'combat', method = 'combat', needs = { 'npcTarget', 'shield' },
          notes = 'Needs a shield equipped, or Slam (some races) raises Bash instead.' },
        -- 'slam': in game skill 'Bash', trained by method 'combat'.
        { key = 'slam',        name = 'Bash',         group = 'combat', method = 'combat', ability = 'Slam', needs = { 'npcTarget' },
          label = 'Bash (via Slam)',
          notes = 'Large races: Slam raises the Bash skill without a shield.' },
        -- 'flyingkick': in game skill 'Flying Kick', trained by method 'combat'.
        { key = 'flyingkick',  name = 'Flying Kick',  group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Monk kick.' },
        -- 'roundkick': in game skill 'Round Kick', trained by method 'combat'.
        { key = 'roundkick',   name = 'Round Kick',   group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Monk kick.' },
        -- 'tigerclaw': in game skill 'Tiger Claw', trained by method 'combat'.
        { key = 'tigerclaw',   name = 'Tiger Claw',   group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Monk strike.' },
        -- 'eaglestrike': in game skill 'Eagle Strike', trained by method 'combat'.
        { key = 'eaglestrike', name = 'Eagle Strike', group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Monk strike.' },
        -- 'dragonpunch': in game skill 'Dragon Punch', trained by method 'combat'.
        { key = 'dragonpunch', name = 'Dragon Punch', group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Monk strike (Tail Rake for Iksar uses the same skill).' },
        -- 'frenzy': in game skill 'Frenzy', trained by method 'combat'.
        { key = 'frenzy',      name = 'Frenzy',       group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Berserker attack.' },
        -- 'backstab': in game skill 'Backstab', trained by method 'combat'.
        { key = 'backstab',    name = 'Backstab',     group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Needs a piercing weapon and to be behind the target.' },
        -- 'disarm': in game skill 'Disarm', trained by method 'combat'.
        { key = 'disarm',      name = 'Disarm',       group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Needs an attackable target.' },
        -- 'taunt': in game skill 'Taunt', trained by method 'combat'.
        { key = 'taunt',       name = 'Taunt',        group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Draws aggro. Only use on something you can handle.' },
        -- 'intimidation': in game skill 'Intimidation', trained by method 'combat'.
        { key = 'intimidation', name = 'Intimidation', group = 'combat', method = 'combat', needs = { 'npcTarget' },
          notes = 'Off by default in auto select. Intimidation can make the target flee, which causes trains.',
          fearRisk = true },

        -- Scripted trips. Only one at a time; see engine.lua/conflicts.
        -- 'begging': in game skill 'Begging', trained by method 'travel'.
        { key = 'begging',     name = 'Begging',      group = 'travel', method = 'travel', needs = { 'nav', 'easyfind' },
          notes = 'Travels to West Freeport and begs Diggs, as Skills2 did. Begging can anger the NPC.' },
        -- 'safefall': in game skill 'Safe Fall', trained by method 'travel'.
        { key = 'safefall',    name = 'Safe Fall',    group = 'travel', method = 'travel', needs = { 'nav', 'ledge' },
          notes = 'Steps off a ledge you record in Options, walks back, repeats. Not the Plane of Knowledge: PoK no longer gives falling damage. Needs MQ2EasyFind only when the ledge is in another zone.' },

        -- Passive. Nothing to press; rises from something else the run does.
        -- 'meditate': in game skill 'Meditate', trained by method 'passive'.
        { key = 'meditate',    name = 'Meditate',     group = 'passive', method = 'passive',
          notes = 'Rises while sitting with mana missing. The run sits to recover mana between casts.' },

        -- Hints only. Listed so the operator can tick them on the All Skills tab
        -- later if automation is added; they are never pressed today.
        -- 'picklock': in game skill 'Pick Lock', trained by method 'hint'.
        { key = 'picklock',    name = 'Pick Lock',     group = 'hint', method = 'hint',
          notes = 'Not automated: needs lockpicks and a locked door targeted with /doortarget.' },
        -- 'disarmtraps': in game skill 'Disarm Traps', trained by method 'hint'.
        { key = 'disarmtraps', name = 'Disarm Traps',  group = 'hint', method = 'hint',
          notes = 'Not automated: needs a real trap targeted.' },
    }

    --[[==========================================================================
      GROUPS

      WHAT  : Display order and headings for the groups.
      WHY   : The Train tab draws one collapsing section per group.
      WHERE : ui.drawTrain.
      HOW   : Ordered array of id and title.
      WHEN  : Every frame.
    ==========================================================================]]--
    catalog.GROUPS = {
        { id = 'casting',    title = 'Spell schools' },  -- group id used in SKILLS
        { id = 'specialize', title = 'Specialization' },  -- group id used in SKILLS
        { id = 'utility',    title = 'Utility abilities' },  -- group id used in SKILLS
        { id = 'combat',     title = 'Combat abilities' },  -- group id used in SKILLS
        { id = 'travel',     title = 'Trips (one at a time)' },  -- group id used in SKILLS
        { id = 'passive',    title = 'Passive' },  -- group id used in SKILLS
        { id = 'hint',       title = 'Manual only' },  -- group id used in SKILLS
    }

    --[[==========================================================================
      CLASS_SPELLS

      WHAT  : Preferred low level training spells per class and school.
      WHY   : Known cheap, safe, self or pet targeted spells skill up fastest.
              This is the union of the Skills2 INI defaults and the skillup.lua
              tables; where the two scripts disagreed both spells are listed.
      WHERE : spells.choose tries these first, in order, if in the spell book.
      HOW   : CLASS_SPELLS[class short name][school] = { 'Spell', ... }.
              Fear spells are never listed (fear causes trains).
      WHEN  : Read when the spell book is scanned.
    ==========================================================================]]--
    catalog.CLASS_SPELLS = {
        BST = { Abjuration = { 'Endure Cold' }, Alteration = { 'Salve' }, Conjuration = { 'Summon Drink' },  -- Beastlord
                Divination = { 'Sense Animals' }, Evocation = { 'Blast of Frost' } },
        CLR = { Abjuration = { 'Endure Poison' }, Alteration = { 'Minor Healing' }, Conjuration = { 'Halo of Light' },  -- Cleric
                Divination = { 'True North' }, Evocation = { 'Strike' } },
        DRU = { Abjuration = { 'Skin like Wood' }, Alteration = { 'Minor Healing' }, Conjuration = { 'Summon Food' },  -- Druid
                Divination = { 'Sense Animals', 'Camouflage' }, Evocation = { 'Burst of Fire' } },
        ENC = { Abjuration = { 'Minor Shielding' }, Alteration = { 'Strengthen' }, Conjuration = { 'Mesmerize' },  -- Enchanter
                Divination = { 'True North' }, Evocation = { 'Chaotic Feedback' } },
        NEC = { Abjuration = { 'Minor Shielding' }, Alteration = { 'Lifetap' }, Conjuration = { 'Coldlight' },  -- Necromancer
                Divination = { 'True North' }, Evocation = { 'Ward Undead', 'Word of Shadow' } },
        MAG = { Abjuration = { 'Minor Shielding' }, Alteration = { 'Renew Elements' }, Conjuration = { 'Summon Brass Choker' },  -- Magician
                Divination = { 'True North' }, Evocation = { 'Burst of Flame' } },
        PAL = { Abjuration = { 'Courage' }, Alteration = { 'Salve' }, Conjuration = { 'Hammer of Wrath' },  -- Paladin
                Divination = { 'True North' }, Evocation = { 'Cease' } },
        RNG = { Abjuration = { 'Endure Fire' }, Alteration = { 'Salve' }, Conjuration = { 'Dance of the Fireflies' },  -- Ranger
                Divination = { 'Glimpse' }, Evocation = { 'Burst of Fire', 'Ignite' } },
        SHD = { Abjuration = { 'Endure Cold' }, Alteration = { 'Siphon Strength' }, Conjuration = { 'Disease Cloud' },  -- Shadow Knight
                Divination = { 'Sense the Dead' }, Evocation = { 'Ward Undead' } },
        SHM = { Abjuration = { 'Endure Cold' }, Alteration = { 'Minor Healing' }, Conjuration = { 'Summon Drink' },  -- Shaman
                Divination = { 'True North' }, Evocation = { 'Burst of Flame' } },
        WIZ = { Abjuration = { 'Minor Shielding' }, Alteration = { 'Root' }, Conjuration = { 'Halo of Light' },  -- Wizard
                Divination = { 'True North' }, Evocation = { 'Blast of Cold' } },
    }

    --[[==========================================================================
      NIGHT_ONLY_SKIP

      WHAT  : Spells that do nothing useful at night and are skipped then.
      WHY   : skillup.lua skipped Dance of the Fireflies at night.
      WHERE : spells.choose.
      HOW   : Set of spell names.
      WHEN  : Checked at each choose.
    ==========================================================================]]--
    catalog.NIGHT_SKIP = { ['Dance of the Fireflies'] = true }

    --[[==========================================================================
      UNSAFE_SPA

      WHAT  : Spell effect numbers (SPA) the automatic picker must never use.
      WHY   : Gates, teleports, evacuations, binds, fear, charm and pet summons
              would move the character, cause trains, or spam pets.
      WHERE : spells.isSafe.
      HOW   : Set keyed by SPA number, value is a short reason. Numbers from
              https://docs.macroquest.org/reference/general/spa-list/
      WHEN  : Checked for every candidate spell during a book scan.
    ==========================================================================]]--
    catalog.UNSAFE_SPA = {
        [22]  = 'Charm',  -- would take control of an NPC
        [23]  = 'Fear',  -- makes the target run, causing trains
        [25]  = 'Bind Affinity',  -- changes your bind point
        [26]  = 'Gate',  -- sends you to your bind point
        [33]  = 'Summon Pet',  -- creates a pet
        [42]  = 'Shadowstep',  -- moves you a short distance
        [83]  = 'Teleport (portal)',  -- teleports you or the group
        [88]  = 'Evacuate',  -- moves the group to a safe spot
        [103] = 'Summon Pet',  -- creates a pet
        [104] = 'Translocate',  -- teleports another player
        [309] = 'Teleport to bind',  -- teleports to bind
        [438] = 'Translocate to anchor',  -- teleports to an anchor
    }

    --[[--------------------------------------------------------------------------
      catalog.byKey(key)

      WHAT  : Returns the SKILLS entry with this key, or nil.
      WHY   : Settings store keys; callers need the full entry.
      WHERE : engine.lua/runner, engine.lua/conflicts, init.lua.
      HOW   : Lookup in a key index built once at load.
      WHEN  : Whenever a key must become an entry.
    ----------------------------------------------------------------------------]]
    local index = {}                                              -- key -> entry
    for _, e in ipairs(catalog.SKILLS) do index[e.key] = e end    -- built once at load
    function catalog.byKey(key)
        return index[key]  -- nil when unknown (old settings file)
    end

    --[[--------------------------------------------------------------------------
      catalog.specFor(school)

      WHAT  : Returns the Specialize skill name for a school.
      WHY   : actions.lua/spells and engine.lua/conflicts link schools to specialization.
      WHERE : actions.lua/spells, engine.lua/conflicts, ui.lua.
      HOW   : Linear search of SCHOOLS (five entries).
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function catalog.specFor(school)
        -- Five entries, a loop is fine.
        for _, s in ipairs(catalog.SCHOOLS) do
            if s.school == school then return s.spec end  -- match found
        end
        return nil  -- not a school
    end

    --[[--------------------------------------------------------------------------
      catalog.label(entry)

      WHAT  : Text shown for an entry in the window.
      WHY   : Slam shares the Bash skill name, so it needs its own label.
      WHERE : ui.lua, engine.lua/conflicts.
      HOW   : entry.label if set, else entry.name.
      WHEN  : Every frame.
    ----------------------------------------------------------------------------]]
    function catalog.label(entry)
        return entry.label or entry.name  -- label overrides the skill name
    end
end  -- of the catalog section

--[[==========================================================================
  END OF SECTION : catalog

  PUBLIC
    SCHOOLS, SKILLS, GROUPS, CLASS_SPELLS, NIGHT_SKIP, UNSAFE_SPA
    byKey(key), specFor(school), label(entry)

  DEPENDENCIES : none.

  HOW TO EDIT SAFELY
    - A new skill: add an entry to SKILLS with a unique key and an existing
      method. If it needs a new method, add it to runner.trainEntry too.
    - name must be the exact in game skill name or Me.Skill returns nothing.
    - Never add a fear spell to CLASS_SPELLS.
==========================================================================]]--

--[[==========================================================================
  SECTION     : skills   (was skillmaster/skills.lua up to 1.0.5)
  CREDITS     : Race and class ability detection idea (GoldenFrog, Skill
                Skillup 1.1).
  HISTORY     : 1.0.5  Version number only; no code change.
                1.0.4  Version number only; no code change.
                1.0.3  Version number only; no code change.
                1.0.2  Version number only; no code change.
                1.0.1  Version number only; no code change.
                1.0.0  First release. Replaces the class and race tables of
                       skillup.lua with live checks of the character's own
                       skill caps, so any class, race and level works.

  WHAT  : Reads current skill values and caps from the game and answers
          "can this character train this", "is it mastered", and "how far
          along is it". Also lists every skill the character has for the
          All Skills tab.

  WHY   : skillup.lua decided availability from hand made class and race
          tables, which miss AA granted skills and level gates. The game
          already knows: Me.SkillCap is above zero only for skills this
          character can raise right now. Using it means the list is always
          right without upkeep.

  WHERE : Used by engine.lua/runner (what still needs work), engine.lua/conflicts,
          data.lua/stats (baseline values) and ui.lua (progress bars).

  HOW   : mq.TLO.Me.Skill(name) and mq.TLO.Me.SkillCap(name) per skill.
          mq.TLO.Skill(id).Name() to walk every skill id for the All Skills
          tab. Values are cached for half a second because the window
          redraws many times a second.

  WHEN  : Every frame (cached) and every runner tick.

  READING GUIDE (for future you)
    - "cap" is the most this character can have at its current level; it
      rises as you level. "mastered" means current equals cap, which is the
      most you can do today.
    - Specialize caps fall after a primary specialization is locked in, so
      the cap shown for the other four is the real limit.
==========================================================================]]--
do  -- skills section scope: locals declared here stay inside it
    --- Value cache ------------------------------------------------------------------
    -- WHAT : cache[skill name] = { cur, cap, at }.
    -- WHY  : The window asks for every skill every frame.
    -- WHERE: skills.value.
    -- HOW  : Entries older than CACHE_MS are reread.
    -- WHEN : Filled on demand.
    local cache    = {}    -- skill name -> { cur = n, cap = n, at = ms }
    local CACHE_MS = 500   -- half a second is fresh enough for a progress bar

    --[[--------------------------------------------------------------------------
      skills.value(name)

      WHAT  : Returns current value and cap for a skill name (both numbers,
              0 when the game has nothing).
      WHY   : Everything else in this module is built on these two numbers.
      WHERE : This module, data.lua/stats, engine.lua/conflicts, ui.lua.
      HOW   : Cache lookup, else Me.Skill(name)() and Me.SkillCap(name)().
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function skills.value(name)
        local now = utils.now()                      -- current time for the cache test
        local c = cache[name]                        -- cached entry, may be nil
        if c and now - c.at < CACHE_MS then return c.cur, c.cap end  -- still fresh
        local cur = tonumber(mq.TLO.Me.Skill(name)()) or 0           -- current value
        local cap = tonumber(mq.TLO.Me.SkillCap(name)()) or 0        -- cap at this level
        cache[name] = { cur = cur, cap = cap, at = now }             -- remember
        return cur, cap
    end

    --[[--------------------------------------------------------------------------
      skills.invalidate(name)

      WHAT  : Drops the cached value for one skill, or all when name is nil.
      WHY   : After a skill up message the bar should move at once.
      WHERE : data.lua/stats skill up event.
      HOW   : Clears the cache entry.
      WHEN  : On a skill up.
    ----------------------------------------------------------------------------]]
    function skills.invalidate(name)
        -- nil means everything, e.g. after leveling.
        if name == nil then cache = {} else cache[name] = nil end
    end

    --[[--------------------------------------------------------------------------
      skills.known(entry)

      WHAT  : True when the game recognises the entry's skill name.
      WHY   : A typo or a removed skill would otherwise show as "0 of 0".
      WHERE : skills.available, ui.lua.
      HOW   : mq.TLO.Skill(name).ID() is nil for unknown names.
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function skills.known(entry)
        return mq.TLO.Skill(entry.name).ID() ~= nil  -- nil means no such skill
    end

    --[[--------------------------------------------------------------------------
      skills.available(entry)

      WHAT  : True when this character can raise the skill right now.
      WHY   : Unavailable skills are greyed out in the window and skipped.
      WHERE : engine.lua/runner, engine.lua/conflicts, ui.lua.
      HOW   : Cap above zero. Slam additionally needs the Slam ability to exist
              (Me.Ability returns a slot number when it does).
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function skills.available(entry)
        -- Manual only entries can still be watched, so use the cap like others.
        local _, cap = skills.value(entry.name)                        -- cap at this level
        if cap <= 0 then return false end                              -- cannot raise it
        if entry.ability and entry.ability ~= entry.name then
            return mq.TLO.Me.Ability(entry.ability)() ~= nil           -- e.g. Slam must exist
        end
        return true
    end

    --[[--------------------------------------------------------------------------
      skills.mastered(entry)

      WHAT  : True when current value has reached the cap.
      WHY   : Mastered skills are skipped and ticked rows turn green.
      WHERE : engine.lua/runner, ui.lua.
      HOW   : cur >= cap with cap above zero.
      WHEN  : On demand.
    ----------------------------------------------------------------------------]]
    function skills.mastered(entry)
        local cur, cap = skills.value(entry.name)   -- live numbers
        return cap > 0 and cur >= cap               -- zero cap is "not available", not mastered
    end

    --[[--------------------------------------------------------------------------
      skills.fraction(entry)

      WHAT  : Progress from 0 to 1 for the progress bar.
      WHY   : ImGui.ProgressBar wants a fraction.
      WHERE : ui.drawTrain.
      HOW   : cur / cap, 0 when cap is 0.
      WHEN  : Every frame.
    ----------------------------------------------------------------------------]]
    function skills.fraction(entry)
        local cur, cap = skills.value(entry.name)    -- live numbers
        if cap <= 0 then return 0 end                -- avoid dividing by zero
        return math.min(1, cur / cap)                -- never more than full
    end

    --[[--------------------------------------------------------------------------
      skills.abilityReady(name)

      WHAT  : True when an ability's reuse timer is up.
      WHY   : Pressing an ability that is not ready does nothing and spams chat.
      WHERE : actions.lua/abilities.
      HOW   : mq.TLO.Me.AbilityReady(name)().
      WHEN  : Before each press.
    ----------------------------------------------------------------------------]]
    function skills.abilityReady(name)
        return mq.TLO.Me.AbilityReady(name)() == true  -- false when unknown too
    end

    --[[--------------------------------------------------------------------------
      skills.allSkills()

      WHAT  : Returns a sorted list of every skill this character has a cap in:
              { name, cur, cap, tracked } where tracked means the catalog knows
              how to train it.
      WHY   : The All Skills tab shows everything, including tradeskills and
              languages the package does not train, so the operator sees the
              whole picture.
      WHERE : ui.drawAllSkills (refreshed by its button, not every frame).
      HOW   : Walks Skill ids 0 to 120 with mq.TLO.Skill(id).Name(); keeps the
              ones whose Me.SkillCap is above zero.
      WHEN  : When the All Skills tab is opened or refreshed.
    ----------------------------------------------------------------------------]]
    function skills.allSkills()
        -- Names the catalog trains, so the tab can mark them.
        local tracked = {}
        for _, e in ipairs(catalog.SKILLS) do tracked[e.name] = true end
        local out = {}                                     -- result list
        for id = 0, 120 do                                 -- skill ids in use today sit well below 120
            local name = mq.TLO.Skill(id).Name()           -- nil for unused ids
            if name and name ~= '' then
                local cur = tonumber(mq.TLO.Me.Skill(id)()) or 0      -- current value
                local cap = tonumber(mq.TLO.Me.SkillCap(id)()) or 0   -- cap at this level
                if cap > 0 then
                    out[#out + 1] = { name = name, cur = cur, cap = cap, tracked = tracked[name] == true }
                end
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)  -- alphabetical
        return out
    end
end  -- of the skills section

--[[==========================================================================
  END OF SECTION : skills

  PUBLIC
    value(name), invalidate(name), known(entry), available(entry),
    mastered(entry), fraction(entry), abilityReady(name), allSkills()

  DEPENDENCIES : mq, core.lua/utils, data.lua/catalog

  HOW TO EDIT SAFELY
    - Keep the cache. Reading forty skills every frame from the game is the
      kind of thing that makes a window stutter.
    - If a skill shows 0 of 0 that should not, check its name with
      /echo ${Skill[<name>].ID} in game.
==========================================================================]]--

--[[==========================================================================
  SECTION     : stats   (was skillmaster/stats.lua up to 1.0.5)
  CREDITS     : Skill up chat pattern (GoldenFrog, Skill Skillup 1.1).
  HISTORY     : 1.0.5  Version number only; no code change.
                1.0.4  Version number only; no code change.
                1.0.3  Version number only; no code change.
                1.0.2  Version number only; no code change.
                1.0.1  Version number only; no code change.
                1.0.0  First release. Keeps the skill up message event of
                       skillup.lua and adds a session log, gains per skill,
                       points per hour, cast and fizzle counts.

  WHAT  : Session statistics: when the session started, every skill up seen
          in chat, gains per skill, casts and fizzles, and a short log of
          recent events for the Session tab.

  WHY   : Knowing the rate tells the operator whether a skill is worth more
          time today, and the log shows at a glance what the run has been
          doing while the operator was on another box.

  WHERE : Event registered by stats.init (called from init.lua). Counters
          bumped by actions.lua/spells and actions.lua/abilities. Read by ui.lua.

  HOW   : mq.event on the game's skill up line
            "You have become better at #1#! (#2#)"
          (the same pattern skillup.lua used). The handler records the gain
          and drops the cached skill value so the bar moves at once.
          mq.doevents is called from the main loop in init.lua.

  WHEN  : Event active for the life of the script; session reset by the
          Reset button or a new run if the operator chooses.

  READING GUIDE (for future you)
    - #1# and #2# in an event pattern capture text; MacroQuest passes the
      captured pieces to the handler after the whole line.
==========================================================================]]--
do  -- stats section scope: locals declared here stay inside it
    --- Session data -----------------------------------------------------------------
    -- WHAT : Everything counted this session.
    -- WHY  : One table so reset is a single assignment.
    -- WHERE: Whole module, ui.lua reads it.
    -- HOW  : Fields: started (ms), runMs (time spent running), gains[name] = n,
    --        total, casts, fizzles, abilities, log (newest first).
    -- WHEN : Reset by stats.reset.
    stats.data = nil

    --- Log length ---------------------------------------------------------------------
    -- WHAT : How many log lines to keep.
    -- WHY  : Enough to see the last few minutes without growing forever.
    -- WHERE: stats.log.
    -- HOW  : Older lines are dropped from the end.
    -- WHEN : Every log write.
    local LOG_MAX = 60

    --[[--------------------------------------------------------------------------
      stats.reset()

      WHAT  : Starts a fresh session.
      WHY   : The Session tab's Reset button and first load.
      WHERE : stats.init, ui.drawSession.
      HOW   : Replaces stats.data with a new empty table.
      WHEN  : At load and on request.
    ----------------------------------------------------------------------------]]
    function stats.reset()
        -- New table; the old one is simply dropped.
        stats.data = { started = utils.now(), runMs = 0, gains = {}, total = 0,
                       casts = 0, fizzles = 0, abilities = 0, log = {} }
    end

    --[[--------------------------------------------------------------------------
      stats.log(fmt, ...)

      WHAT  : Adds a time stamped line to the session log.
      WHY   : The Session tab shows what happened while you were away.
      WHERE : data.lua/stats handlers, engine.lua/runner, actions.lua/travel.
      HOW   : Formats, prepends with an os.date stamp, trims to LOG_MAX.
      WHEN  : On notable events.
    ----------------------------------------------------------------------------]]
    function stats.log(fmt, ...)
        -- Same formatting rule as utils.echo.
        local text = (select('#', ...) > 0) and string.format(fmt, ...) or tostring(fmt)
        table.insert(stats.data.log, 1, os.date('%H:%M:%S') .. '  ' .. text)  -- newest first
        while #stats.data.log > LOG_MAX do table.remove(stats.data.log) end   -- trim the oldest
    end

    --[[--------------------------------------------------------------------------
      stats.count(field)

      WHAT  : Adds one to a counter (casts, fizzles, abilities).
      WHY   : Keeps counter names in one place.
      WHERE : actions.lua/spells, actions.lua/abilities.
      HOW   : Increments stats.data[field].
      WHEN  : After each action.
    ----------------------------------------------------------------------------]]
    function stats.count(field)
        stats.data[field] = (stats.data[field] or 0) + 1  -- unknown fields start at zero
    end

    --[[--------------------------------------------------------------------------
      onSkillUp(line, skill, value)

      WHAT  : Handler for the game's skill up line.
      WHY   : This is the only reliable signal that a point was gained.
      WHERE : Registered by stats.init with mq.event.
      HOW   : Records the gain, refreshes the cached value, logs it.
      WHEN  : Whenever the line appears in chat (via mq.doevents).
    ----------------------------------------------------------------------------]]
    local function onSkillUp(line, skill, value)
        -- skill and value are the #1# and #2# captures.
        skill = tostring(skill or '')
        stats.data.gains[skill] = (stats.data.gains[skill] or 0) + 1  -- per skill count
        stats.data.total = stats.data.total + 1                       -- overall count
        skills.invalidate(skill)                                      -- bar moves at once
        stats.log('%s is now %s', skill, tostring(value))            -- session log line
    end

    --[[--------------------------------------------------------------------------
      stats.init()

      WHAT  : Starts a session and registers the skill up event.
      WHY   : Must happen once before the main loop.
      WHERE : init.lua startup.
      HOW   : stats.reset, then mq.event with the pattern from skillup.lua.
      WHEN  : Once.
    ----------------------------------------------------------------------------]]
    function stats.init()
        stats.reset()                                                        -- empty session
        mq.event('skm_skillup', 'You have become better at #1#! (#2#)', onSkillUp)  -- game line
    end

    --[[--------------------------------------------------------------------------
      stats.shutdown()

      WHAT  : Removes the event.
      WHY   : Clean exit; events would otherwise linger until the script ends.
      WHERE : init.lua shutdown.
      HOW   : mq.unevent.
      WHEN  : Once, on exit.
    ----------------------------------------------------------------------------]]
    function stats.shutdown()
        mq.unevent('skm_skillup')  -- same name used in init
    end

    --[[--------------------------------------------------------------------------
      stats.perHour()

      WHAT  : Skill points gained per hour of running time.
      WHY   : Shown on the Session tab.
      WHERE : ui.drawSession.
      HOW   : total / running hours, 0 for under a minute of running.
      WHEN  : Every frame on that tab.
    ----------------------------------------------------------------------------]]
    function stats.perHour()
        local hours = stats.data.runMs / 3600000                 -- milliseconds to hours
        if hours < (1 / 60) then return 0 end                    -- too early to mean anything
        return stats.data.total / hours
    end
end  -- of the stats section

--[[==========================================================================
  END OF SECTION : stats

  PUBLIC
    data, reset(), log(fmt, ...), count(field), init(), shutdown(), perHour()

  DEPENDENCIES : mq, core.lua/utils, data.lua/skills

  HOW TO EDIT SAFELY
    - runMs is added to by runner.tick only while running, so the rate is
      per hour of training, not per hour of the window being open.
    - If the skill up line ever changes in game, update the pattern in
      stats.init; nothing else depends on its wording.
==========================================================================]]--

-- Hand the section tables to whoever requires this file.
return { catalog = catalog, skills = skills, stats = stats }

--[[==========================================================================
  END OF FILE : skillmaster/data.lua

  PUBLIC  (returned table)
    catalog  SCHOOLS, GROUPS, SKILLS, CLASS_SPELLS, UNSAFE_SPA, NIGHT_SKIP,
             byKey, label, specFor
    skills   value, fraction, known, available, mastered, abilityReady,
             allSkills, invalidate
    stats    data, reset, log, count, init, shutdown, perHour

  DEPENDENCIES : mq, skillmaster.core (utils)

  HOW TO EDIT SAFELY
    - No game commands from this file. It reads; actions.lua acts.
    - Keep catalog first: skills builds on its entries.
==========================================================================]]--
