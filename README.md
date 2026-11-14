<!--
  FILE    : skillmaster/README.md
  PACKAGE : SkillMaster Lua (MacroQuest / EverQuest)
  VERSION : 1.0.2
  WHAT    : What SkillMaster does, how to install it, how to use the window
            and commands, and what has not been verified in game yet.
  WHY     : First thing to read before running or editing the package.
  WHERE   : Package root. ARCHITECTURE.md covers the code; CHANGELOG.md
            covers versions.
  WHEN    : Read before first use; update when behaviour or commands change.
-->
# SkillMaster 1.0.2

SkillMaster trains EverQuest skills to their cap from one MacroQuest Lua window. It merges the two earlier scripts, Skills2 0.4.2 (Blasty) and skillup.lua 1.1, into one modular, fully documented package.

## Install

1. Copy the `skillmaster` folder into `<MacroQuest>/lua/` so you have `<MacroQuest>/lua/skillmaster/init.lua`.
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

Header (always visible): status line, Start / Pause (Resume) / Stop buttons, and the warning panel.

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
| `/skm help` | list commands |

## Warnings it checks

- Mutually exclusive specializations: more than one Specialize skill ticked without the Secondary Forte AA, or ticking one that differs from the primary already locked in. Red, blocks Start. Background: [EverQuest Fandom, spell school specialization](https://everquest.fandom.com/wiki/Spell_school_specialization_skills) and [Allakhazam, Secondary Forte](https://everquest.allakhazam.com/wiki/eq:Secondary_Forte).
- Specialization guard: while no primary is locked in, a school is held when its Specialize skill reaches 50 (setting), unless it is your intended primary.
- Begging together with Safe Fall (two different trips), Hide with casting (casting breaks Hide), Feign Death with combat abilities, Intimidation (fear risk; you asked to avoid fear because it causes trains, so it is never ticked by "Tick all").
- Harmful spell with no target, two schools sharing a gem, missing shield (Bash), bandages (Bind Wound), fishing pole and bait, full bags, no nav mesh, missing plugins, MQ2AutoForage loaded but not used, RGMercs running but not set to pause, invisibility that a cast would drop.

## Safety

- Begging: before each beg, Sneak is turned off and Hide or invisibility is dropped with `/makemevisible`, because the NPC must see you. If EverQuest still answers "can't see you" after three tries, the trip stops with that reason.

- Spells with charm, fear, bind affinity, gate, pet summon, shadowstep, teleport, evacuate or translocate effects are never picked automatically (SPA list in `catalog.lua`, from the [MacroQuest SPA list](https://docs.macroquest.org/reference/general/spa-list/)).
- Stops below the health percent you set, stops if you die, and waits while zoning or stunned.
- Temporary summoned items are destroyed only when they are NoRent and appeared right after a training cast; anything else goes to bags with `/autoinventory`.
- Each skill stops at its cap; the run stops and beeps when every ticked skill is mastered. A run with only Meditate left stops with an explanation, because Meditate only rises while mana is coming back.

## Not verified in game yet

These came from the original scripts or from documentation and need a live check with Debug on:

- Using your own mercenary as the combat target (Skills2's method). Off by default.
- Bind Wound at full health, and Fishing behaviour.
- Safe Fall ledge in the Plane of Knowledge at 803, -376, -96 and the Begging spot in West Freeport at 132, -120 (both from Skills2).
- Mesmerize as the enchanter default school spell.
- Hide and Sneak toggled with a double press.

## Testing on your PC

```
pip install lupa
python dev/smoke_test.py     # fake MacroQuest, nine scenarios, every tab drawn
python dev/doc_audit.py      # documentation standard
```

The smoke test checks logic only; it cannot prove in game names or plugin behaviour. lupa runs Lua 5.4 while MacroQuest uses LuaJIT, so the code avoids features that differ.

<!--
  END OF FILE : skillmaster/README.md
  HOW TO EDIT SAFELY: keep the command table identical to /skm help in
  init.lua and the Help tab in ui.lua. Move items out of "Not verified"
  only after a live test.
-->
