--[[==========================================================================
  FILE        : skillmaster/catalog.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.2
  CHANGES     : 1.0.2  Tracking note: pressed whenever ready, window state
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

  WHERE : Read by skills.lua (current and cap values), conflicts.lua
          (requirements), runner.lua (what to do each tick), abilities.lua,
          spells.lua and ui.lua (labels, groups, tooltips).

  HOW   : catalog.SKILLS is an ordered array of entries. Each entry has:
            key      unique id used in the settings file
            name     exact EverQuest skill name for Me.Skill / Me.SkillCap
            group    'casting' | 'specialize' | 'utility' | 'combat'
                     | 'travel' | 'passive'
            method   how runner trains it (see METHOD below)
            school   for casting and specialize entries, the spell school
            ability  name passed to /doability when it differs from name
            needs    list of requirement tags checked by conflicts.lua
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
        'travel'    a scripted trip in travel.lua (Begging, Safe Fall)
        'passive'   no action; rises from something else (Meditate)
        'hint'      not automated; the window only shows how to raise it
    - Requirement tags in needs: 'shield', 'bandages', 'fishing',
      'npcTarget', 'nav', 'easyfind', 'freeSlot'. conflicts.lua explains
      each one to the operator.
==========================================================================]]--

local catalog = {}

--[[==========================================================================
  SCHOOLS

  WHAT  : The five spell schools with their matching Specialize skill names.
  WHY   : spells.lua must map a spell's school (Spell.Skill) to the
          Specialize skill that casting it raises.
  WHERE : spells.lua, conflicts.lua, ui.lua.
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
  WHEN  : Read every frame by ui.lua, every tick by runner.lua.
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
    -- unless you own Secondary Forte. See conflicts.lua for the rules.
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

    -- Scripted trips. Only one at a time; see conflicts.lua.
    -- 'begging': in game skill 'Begging', trained by method 'travel'.
    { key = 'begging',     name = 'Begging',      group = 'travel', method = 'travel', needs = { 'nav', 'easyfind' },
      notes = 'Travels to West Freeport and begs Diggs, as Skills2 did. Begging can anger the NPC.' },
    -- 'safefall': in game skill 'Safe Fall', trained by method 'travel'.
    { key = 'safefall',    name = 'Safe Fall',    group = 'travel', method = 'travel', needs = { 'nav', 'easyfind' },
      notes = 'Steps off a Plane of Knowledge ledge repeatedly, as Skills2 did. Location not verified for current PoK.' },

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
  WHERE : runner.lua, conflicts.lua, init.lua.
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
  WHY   : spells.lua and conflicts.lua link schools to specialization.
  WHERE : spells.lua, conflicts.lua, ui.lua.
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
  WHERE : ui.lua, conflicts.lua.
  HOW   : entry.label if set, else entry.name.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
function catalog.label(entry)
    return entry.label or entry.name  -- label overrides the skill name
end

return catalog  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/catalog.lua

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
