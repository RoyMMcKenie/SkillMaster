<!--
  FILE    : skillmaster/README.md
  PACKAGE : SkillMaster Lua (MacroQuest / EverQuest)
  VERSION : 1.1.0
  WHAT    : What SkillMaster does, how to install it, how to use the window
            and commands, and what has not been verified in game yet.
  WHY     : First thing to read before running or editing the package.
  WHERE   : Package root. ARCHITECTURE.md covers the code; CHANGELOG.md
            covers versions.
  WHEN    : Read before first use; update when behaviour or commands change.
-->
# SkillMaster 1.1.0

SkillMaster trains EverQuest skills to their cap from one MacroQuest Lua window. It brings together the best of two RedGuides scripts, Skills2 0.4.2 by Blasty and Skill Skillup 1.1 (skillup.lua) by GoldenFrog, in one modular, fully documented package. See [Credits and attribution](#credits-and-attribution).

## At a glance

- One window, one command (`/skm`) in place of the seven binds of Skills2 and the start and go loop of skillup.lua.
- Casting schools, specializations, utility and combat abilities, Tracking, Forage, Begging and Safe Fall trips.
- Guard rails before speed: specialization lock protection, unsafe spell filter, health stop, fear avoidance, gem restore.
- Pause and Resume at any moment, and a tidy End SkillMaster that puts everything back.
- Every slash command it sends is listed in [ARCHITECTURE.md](ARCHITECTURE.md) with the documentation page it was checked against.
- Fifteen simulated scenarios run against the real code on LuaJIT 2.1, plus an automated documentation audit, before every release.

## Files

| File | What is in it |
|---|---|
| `init.lua` | Entry point: `/lua run skillmaster`, the `/skm` command, the main loop, shutdown |
| `core.lua` | Foundation: chat output and the single traced command sender, settings file, plugin detection and RGMercs hand off |
| `data.lua` | Knowledge: the skill catalog, live skill values and caps, session statistics |
| `actions.lua` | Action: spell casting, ability presses, Begging and Safe Fall trips |
| `engine.lua` | Decision: warnings and specialization guard, the run state and tick |
| `ui.lua` | The ImGui window and its six tabs |
| `dev/smoke_test.py` | Fake MacroQuest test harness (not used by the game) |
| `dev/doc_audit.py` | Documentation standard checker (not used by the game) |

Up to 1.0.5 the code was spread over thirteen Lua files. 1.1.0 groups modules that always load together into one file per layer; each keeps its own documented section. See [CHANGELOG.md](CHANGELOG.md).

## Install

1. Put the files in `<MacroQuest>/lua/skillmaster/` so you have `<MacroQuest>/lua/skillmaster/init.lua`. From GitHub: Code, Download ZIP, then rename the extracted folder to `skillmaster`; or `git clone <repo url> skillmaster` inside `<MacroQuest>/lua/`.
   Upgrading from 1.0.x: delete the old `skillmaster` folder first, because eleven of its files no longer exist. Your settings live in `<MacroQuest>/config/` and are kept.
2. In game: `/lua run skillmaster`
3. The window opens. `/skm` shows or hides it.

Optional plugins, used automatically when loaded (the Options tab shows which are found):

| Plugin | Used for | Without it |
|---|---|---|
| MQ2Cast | `/casting` with a real cast result (fizzle, interrupted, no target...) | plain `/cast <gem>`, result guessed from skill change |
| MQ2Nav | walking to a combat target, Begging and Safe Fall spots | no movement; you stand in range yourself |
| MQ2EasyFind | `/travelto` zone trips for Begging and Safe Fall | trips are skipped with a warning |
| MQ2AutoForage | `/startforage` and `/stopforage` | Forage pressed with `/doability` |
| RGMercs (Lua) | `/rgl pause` at Start, `/rgl unpause` at Stop | nothing to pause |

## Tracking

If your character can train Tracking (it has a Tracking cap above zero), it appears in the Train tab under Utility and "Tick all available" includes it. While ticked, SkillMaster presses Tracking every time it is ready. Each press refreshes tracking and is a chance to raise the skill. The Tracking window can be open or closed; SkillMaster never waits for it or closes it.

## Window

Header (always visible): status line, Start / Pause (Resume) / Stop / End SkillMaster buttons, and the warning panel.

- End SkillMaster: stops any run, restores your gems, unpauses RGMercs, saves settings, then ends the script with [`/lua stop skillmaster`](https://docs.macroquest.org/lua/).

- Pause: every action stops at once. Nothing is cast, pressed or sent while paused. MQ2AutoForage and any trip are stopped; borrowed spell gems stay borrowed. Resume carries on where it left off. Stop ends the run and puts the gems back.
- Warnings: red lines are errors and block Start (can be turned off in Options); yellow are advice.

Tabs:

- Train: one section per group (Casting, Specialize, Utility, Combat, Travel, Passive). Each row has the Master checkbox, the skill name, a progress bar (current / cap) and a live status. "Tick all available" ticks everything your character can train except specializations, trips and fear risks. Checkboxes are locked while a run is active.
- Spells: per school, the spell the run will cast, why it was chosen, an override box and the gem in use. Also the intended primary specialization.
- All Skills: every skill with current / cap, whether SkillMaster trains it, and a hint for the ones it does not.
- Session: gains, points per hour, casts, fizzles, recent log.
- Options: plugins found, casting, meditation, abilities, trips, safety, finish behaviour.
- Help: quick start and the command list.

## Commands

| Command | Does |
|---|---|
| `/skm` or `/skm show` | show or hide the window |
| `/skm start` | start, or resume when paused |
| `/skm pause` | pause |
| `/skm stop` | stop and restore gems |
| `/skm status` | print progress of ticked skills |
| `/skm all` / `/skm none` | tick every available skill / untick everything |
| `/skm quit` | stop and close SkillMaster |
| `/skm end` | same as the End SkillMaster button: tidy shutdown, then `/lua stop skillmaster` |
| `/skm help` | list commands |

## Warnings it checks

- Mutually exclusive specializations: more than one Specialize skill ticked without the Secondary Forte AA, or ticking one that differs from the primary already locked in. Red, blocks Start. Background: [EverQuest Fandom, spell school specialization](https://everquest.fandom.com/wiki/Spell_school_specialization_skills) and [Allakhazam, Secondary Forte](https://everquest.allakhazam.com/wiki/eq:Secondary_Forte).
- Specialization guard: while no primary is locked in, a school is held when its Specialize skill reaches 50 (setting), unless it is your intended primary.
- Begging together with Safe Fall (two different trips), Hide with casting (casting breaks Hide), Feign Death with combat abilities, Intimidation (fear risk; you asked to avoid fear because it causes trains, so it is never ticked by "Tick all").
- Harmful spell with no target, two schools sharing a gem, missing shield (Bash), bandages (Bind Wound), fishing pole and bait, full bags, no nav mesh, missing plugins, MQ2AutoForage loaded but not used, RGMercs running but not set to pause, invisibility that a cast would drop.

## Safety

- Begging movement: if you are already in West Freeport, there is no zone travel. If you are already within Begging range (Options, default 15) of Diggs, you are not moved at all. If Diggs is in the zone but further away, you walk straight to Diggs with `/nav id`. The fixed Skills2 spot is used only when Diggs cannot be found. When Begging is mastered you stay where you are unless you type a Return zone in Options.

- Begging: before each beg, Sneak is turned off and Hide or invisibility is dropped with `/makemevisible`, because the NPC must see you. If EverQuest still answers "can't see you" after three tries, the trip stops with that reason.

- Spells with charm, fear, bind affinity, gate, pet summon, shadowstep, teleport, evacuate or translocate effects are never picked automatically (SPA list in the catalog section of `data.lua`, from the [MacroQuest SPA list](https://docs.macroquest.org/reference/general/spa-list/)).
- Stops below the health percent you set, stops if you die, and waits while zoning or stunned.
- Temporary summoned items are destroyed only when they are NoRent and appeared right after a training cast; anything else goes to bags with `/autoinventory`.
- Each skill stops at its cap; the run stops and beeps when every ticked skill is mastered. A run with only Meditate left stops with an explanation, because Meditate only rises while mana is coming back.

## Safe Fall setup

The Plane of Knowledge no longer gives falling damage ([Allakhazam PoK comments](https://everquest.allakhazam.com/db/zones.html?zstrat=158)), and Safe Fall only rises from a fall that hurts, so you pick the ledge:

1. Go to a ledge that hurts when you drop. Stand on the very edge and press Options, Trips, Set ledge here.
2. Step off, stand where you landed and press Set landing spot here.
3. Tick Safe Fall and press Start. If you are already on the ledge you are not moved; otherwise MQ2Nav walks you there (and MQ2EasyFind takes you to the zone first if needed).

Ideas from players, not automated: the balcony above the Erudin zone in ([Allakhazam Monk guide](https://everquest.allakhazam.com/wiki/EQ:Monk)), the Gyrospire Relocation Device tower ([EverQuest forums](https://forums.everquest.com/index.php?threads/safe-fall-training.252721/)), and steep zone walls or wizard spires ([The Safehouse Rogue FAQ](https://thesafehouse.org/forums/forum/everquest-wing/library-read-only/2981-the-rogue-faq)). Keep your health up; the trip waits to heal between falls.

## Not verified in game yet

These came from the original scripts or from documentation and need a live check with Debug on:

- Using your own mercenary as the combat target (Skills2's method). Off by default.
- Bind Wound at full health, and Fishing behaviour.
- Whether Forward hold ms (1200) is right for every ledge; raise it if you stop short of the edge.
- Mesmerize as the enchanter default school spell.
- Hide and Sneak toggled with a double press.

## Testing on your PC

```
pip install lupa
python dev/smoke_test.py     # fake MacroQuest, fifteen scenarios, every tab drawn
python dev/doc_audit.py      # documentation standard
```

The smoke test checks logic only; it cannot prove in game names or plugin behaviour. It runs on LuaJIT 2.1, the same engine as MacroQuest, when lupa provides it (current wheels do) and says which engine it used.

## Credits and attribution

SkillMaster stands on the work of other RedGuides authors. Their scripts were studied and their ideas, skill lists, class spell choices and chat patterns were carried into this package; the code itself was rewritten module by module. Credit belongs to them for the parts listed here.

| Original work | Author | Where to find it | What SkillMaster uses from it |
|---|---|---|---|
| Skills2 0.4.2 (Lua) | Blasty | [RedGuides resource 2302](https://www.redguides.com/community/resources/skills2.2302/) | Skill list, passive and active ability loops, the Begging trip to Diggs in West Freeport, the Safe Fall idea, mercenary as combat target, the Skills2.ini class spell defaults, the seven slash binds that became /skm |
| Skill Skillup: Spells and Others 1.1 (skillup.lua) | GoldenFrog | [RedGuides resource 2937](https://www.redguides.com/community/resources/skill-skillup-spells-and-others.2937/) | Per class training spell tables, race and class ability detection, the skill up chat event pattern, the start and go training loop, skipping Dance of the Fireflies at night |
| cskillup.mac | maskoi | [RedGuides thread](https://www.redguides.com/community/threads/cskillup.87438/) | Indirectly: Skill Skillup is GoldenFrog's port of this macro |
| CastingSkillup.mac | Arneweise | credited in cskillup.mac | Indirectly: cskillup.mac is based on it |
| Skills auto skill raiser (macro) | Blasty | [RedGuides resource 229](https://www.redguides.com/community/resources/skills-auto-skill-raiser.229/) | Indirectly: the macro Skills2 replaced |

Where each borrowed idea lives in the code: every Lua file header has a CREDITS line, and each section's HISTORY line says what came from Skills2 or skillup.lua.

Also built with: [MacroQuest](https://docs.macroquest.org/) and its documentation, the [RedGuides](https://www.redguides.com/) plugin ecosystem (MQ2Cast, MQ2Nav, MQ2EasyFind, MQ2AutoForage, RGMercs), and [mq-definitions](https://github.com/macroquest/mq-definitions) for checking TLO members.

### Permission status

| Author | Asked | Answer |
|---|---|---|
| Blasty (Skills2) | not yet | |
| GoldenFrog (Skill Skillup) | not yet | |

Skill Skillup is a RedGuides Supporter (Level 2) resource. Please do not make this repository public, or post SkillMaster as a RedGuides resource, until both authors have said yes. Record each answer here with the date and a link to the message.

If you are one of these authors and want anything changed or removed, open an issue or message RoyMMcKenie on RedGuides and it will be done.

<!--
  END OF FILE : skillmaster/README.md
  HOW TO EDIT SAFELY: never remove or shorten the Credits section; add
  to it when an idea comes from another author. Keep the command table identical to /skm help in
  init.lua and the Help tab in ui.lua. Move items out of "Not verified"
  only after a live test.
-->
