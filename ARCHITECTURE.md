<!--
  FILE    : skillmaster/ARCHITECTURE.md
  PACKAGE : SkillMaster Lua (MacroQuest / EverQuest)
  VERSION : 1.0.4
  WHAT    : How the package is built: module map, data flow, the run loop,
            the documentation standard, settings, and every game / plugin
            command it sends with where it was checked.
  WHY     : So the next person can change one module without breaking the
            others, and so no command is ever added without a source.
  WHERE   : Package root, next to README.md and CHANGELOG.md.
  WHEN    : Read before editing code. Update when a module, setting or
            command is added or changed.
-->
# SkillMaster architecture

## Module map

| File | Job | Depends on |
|---|---|---|
| `init.lua` | Entry point: `/skm` binding, startup, main loop, shutdown | all below |
| `utils.lua` | Chat output, `utils.cmd` (single place every command goes through, traced with Debug on), abortable delay, small helpers | mq |
| `config.lua` | Defaults and the per character settings file `skillmaster_<server>_<name>.lua` in the MacroQuest config folder (`mq.pickle`) | mq, utils |
| `catalog.lua` | Static data: schools, every trainable skill (key, in game name, group, method, notes), class default spells, unsafe SPA list | none |
| `plugins.lua` | Which optional plugins / scripts are loaded (1 s cache), RGMercs pause and unpause | mq, utils |
| `skills.lua` | Current value, cap, available, mastered, ability ready (500 ms cache) | mq, catalog |
| `stats.lua` | Session numbers and log; the skill up chat event | mq |
| `spells.lua` | Spell book scan, safety check, spell choice per school, gem borrowing and restore, the cast itself, cursor cleanup | mq, utils, config, catalog, plugins, skills, stats |
| `abilities.lua` | Pressing abilities, toggles, Feign Death, Tracking, Forage, combat target and approach | mq, utils, config, catalog, plugins, skills, stats |
| `travel.lua` | Begging and Safe Fall trips as a small state machine (zone, spot, work, home) | mq, utils, config, plugins, skills |
| `conflicts.lua` | Every warning and error shown in the header; specialization state and guard | mq, config, catalog, plugins, skills, spells, abilities |
| `runner.lua` | Run state (idle / running / paused), Start / Pause / Resume / Stop, one tick of work | everything above |
| `ui.lua` | The ImGui window, six tabs, debounced settings save | everything above |

End SkillMaster: the button (or `/skm end`) sets `runner.endScript` and `runner.quitting`; the loop ends, `shutdown()` restores gems, unpauses RGMercs and saves, and only then `init.lua` sends `/lua stop skillmaster`.

Rule: lower modules never require higher ones. `ui` and `init` only set `runner.request`; the main loop applies it, so button presses never run game commands from inside the ImGui callback.

## Main loop (init.lua, every 100 ms)

`mq.doevents()` (skill up lines) then `runner.process()` (apply Start / Pause / Stop requests) then `runner.tick()` then `ui.flush()` (save settings if changed) then `mq.delay(100)`.

`runner.tick()` order, doing at most one cast per tick:

1. Safety: stop under the health limit or on death; wait while zoning or stunned (Safe Fall waits to heal instead of stopping).
2. Anything left? If every ticked skill is mastered: beep once and stop (settings). If only Meditate is left: stop with an explanation.
3. Trips (Begging, then Safe Fall), one at a time. At the Begging spot only non toggle utility skills are trained; Sneak and Hide are undone before each beg.
4. Meditation: sit below the start percent, stand at the stop percent.
5. Abilities: each ticked utility and combat skill whose ability is ready.
6. One cast, round robin over the schools that still need work and are not held by the guard or a fatal cast result.

Pause: `runner.state = 'paused'`, `tick()` returns at once, forage and trips are stopped. Every SkillMaster Lua must offer a Pause button (project rule); here it is in the window header and `/skm pause`.

## Documentation standard

Enforced by `dev/doc_audit.py`, which must PASS before a release:

- Header in the first 60 lines: FILE, PACKAGE, VERSION, CHANGES (lists the current version), WHAT, WHY, WHERE, HOW, WHEN, READING GUIDE.
- Every function: a WHAT / WHY / WHERE / HOW / WHEN block above it, or a comment directly above for a tiny helper documented in a shared block.
- Every line of code: a comment on the line or within the three lines above.
- Footer in the last 80 lines: END OF FILE, public summary, dependencies, HOW TO EDIT SAFELY.
- VERSION in every file matches the newest heading in CHANGELOG.md.
- Markdown files use an HTML comment header and footer.

## Settings (config.lua)

| Setting | Default | Meaning |
|---|---|---|
| selected | {} | ticked skill keys |
| spellOverride | {} | per school spell name typed in the Spells tab |
| firstGem | 1 | first gem SkillMaster may borrow |
| restoreGems | true | put original spells back at Stop |
| useMQ2Cast | true | use `/casting` when MQ2Cast is loaded |
| useAutoForage | true | use MQ2AutoForage when loaded |
| medStartPct / medStopPct | 15 / 95 | sit and stand mana percent |
| stopHpPct | 50 | safety stop health percent |
| pauseRGMercs | true | `/rgl pause` at Start, `/rgl unpause` at Stop, only if it was running |
| specGuard / specGuardValue / specPrimary | true / 50 / '' | specialization guard |
| destroySummoned | true | destroy NoRent items produced by a training cast |
| combatTargetSource | 'target' | 'target' or 'merc' (unverified) |
| meleeRange | 12 | navigate closer than this |
| beggingZone / beggingNpc / beggingLocXY / beggingReturn | freeportwest / Diggs / 132,-120 / blank | Begging trip (from Skills2); the loc is only a fallback when the NPC is not found; a blank return zone stays put |
| beggingRange | 15 | within this distance of the NPC you are not moved |
| safeFallZone / safeFallLocXYZ / safeFallHoldMs | poknowledge / 803,-376,-96 / 1200 | Safe Fall trip (from Skills2) |
| stopWhenDone / beepWhenDone | true / true | finish behaviour |
| blockOnErrors | true | red warnings block Start |
| debug | false | trace every command in chat |
| windowOpen | true | remember whether the window was shown |

## Commands sent and where they were checked

Every command goes through `utils.cmd`. Nothing outside this list is sent.

| Command | Module | Source |
|---|---|---|
| `/memspell <gem> "<spell>"` | spells | [MacroQuest docs](https://docs.macroquest.org/reference/commands/memspell/) |
| `/casting "<spell>\|gem<n>" -maxtries\|1 -targetid\|<id>` | spells | [MQ2Cast docs](https://docs.macroquest.org/plugins/community-plugins/mq2cast/) |
| `/cast <gem>`, `/interrupt`, `/sit`, `/stand` | spells, runner, abilities | EverQuest built in commands |
| `/mqtarget id <id>`, `/mqtarget npc <name>` | spells, abilities, travel | [MacroQuest /target (now /mqtarget)](https://docs.macroquest.org/reference/commands/target/) |
| `/face fast id <id>` | abilities | [MacroQuest /face](https://docs.macroquest.org/reference/commands/face/) |
| `/doability "<name>"` | abilities, travel | [MacroQuest /doability](https://docs.macroquest.org/reference/commands/doability/) |
| `/destroy`, `/autoinventory` | spells | [MacroQuest /destroy](https://docs.macroquest.org/reference/commands/destroy/); `/autoinventory` is built in |
| `/makemevisible` | travel | [MacroQuest /makemevisible](https://docs.macroquest.org/reference/commands/makemevisible/) |
| `/lua stop skillmaster` | init (End SkillMaster button, `/skm end`), sent after the tidy shutdown | [MacroQuest Lua docs](https://docs.macroquest.org/lua/) |
| `/beep` | runner | [MacroQuest /beep](https://docs.macroquest.org/reference/commands/beep/) |
| `/nomodkey /keypress forward hold` and `/nomodkey /keypress forward` | travel | [MacroQuest /keypress](https://docs.macroquest.org/reference/commands/keypress/), [/nomodkey](https://docs.macroquest.org/reference/commands/nomodkey/) |
| `/nav id <id>`, `/nav locxy`, `/nav locxyz`, `/nav stop` | abilities, travel, runner | [MQ2Nav command reference](https://github-wiki-see.page/m/brainiac/MQ2Nav/wiki/Command-Reference) |
| `/travelto <zone>`, `/travelto stop` | travel | [MQ2EasyFind /travelto](https://www.redguides.com/docs/projects/mq2easyfind/cmd-travelto/) |
| `/startforage`, `/stopforage` | abilities | [MQ2AutoForage docs](https://docs.macroquest.org/plugins/community-plugins/mq2autoforage/) |
| `/rgl pause`, `/rgl unpause` | plugins | [RedGuides RGMercs thread](https://www.redguides.com/community/threads/anniversary-tower-missions-full-automation.92165/) |

TLO members and ImGui calls were checked against [mq-definitions](https://github.com/macroquest/mq-definitions). Zone short names: [RedGuides zone list](https://www.redguides.com/docs/projects/everquest/general/zone-short-names/). Inventory slot names: [MacroQuest slot names](https://docs.macroquest.org/reference/general/slot-names/). Specialization rules: [EverQuest Fandom](https://everquest.fandom.com/wiki/Spell_school_specialization_skills), [Allakhazam Secondary Forte](https://everquest.allakhazam.com/wiki/eq:Secondary_Forte), [EverQuest 2022 update notes](https://www.everquest.com/update-notes/eq-update-notes-4-20-2022).

## Testing

- `dev/smoke_test.py` (needs `pip install lupa`): fake MacroQuest and ImGui. Scenarios: cleric (three schools and Specialize Alteration to cap with meditation, gems restored, Gate never cast, summoned items destroyed), pause (nothing sent while paused, Resume finishes), conflict (two specializations block Start), guard (school held at 50), monk (Mend, Sneak, Feign Death, Kick), beg (starts hidden and sneaking: both undone before any beg), begstuck (invisibility cannot be dropped: no beg sent, run stops with the reason), tracking_open and tracking_closed (Tracking pressed whenever ready to its cap, window never touched), begnear (beside Diggs: no movement command at all), begfar (Diggs across the zone: /nav id to Diggs, never the fixed spot), endbutton (runs init.lua, presses End SkillMaster: gems restored and settings saved before `/lua stop skillmaster`). Every tab is drawn idle, running, paused and at the end, checking argument types and Begin/End balance.
- `dev/doc_audit.py`: documentation standard.

<!--
  END OF FILE : skillmaster/ARCHITECTURE.md
  HOW TO EDIT SAFELY: add a command to the table, with its source URL,
  before sending it from code. Keep the module map in step with requires.
-->
