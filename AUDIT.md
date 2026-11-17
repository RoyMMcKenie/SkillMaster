<!--
  FILE    : skillmaster/AUDIT.md
  PACKAGE : SkillMaster Lua (MacroQuest / EverQuest)
  WHAT    : Line by line source audit of SkillMaster 1.1.0. Every game data
            call (TLO), MacroQuest Lua function, ImGui call, slash command,
            chat event and skill name in the six Lua files is matched to the
            official definition, documentation or plugin source that defines it.
  WHY     : To show that no command or interface in this package was made up.
  WHEN    : Performed 2026-11-17 against the commits pinned in "Reference
            sources" below. Repeat it whenever a command or TLO call is added.
-->
# SkillMaster source audit (1.1.0)

Result: nothing invented. Every interface the code touches is defined by MacroQuest, the MacroQuest Lua and ImGui definitions, or the source of the plugin that provides it. Two documentation links were improved (see "Changes made"); no code changed.

Code comments were stripped before every check, so only executable code was audited.

## Reference sources

| Source | Pinned at |
|---|---|
| [macroquest/mq-definitions](https://github.com/macroquest/mq-definitions) (Lua type definitions for TLOs, `mq.*`, ImGui) | `67f2248` |
| [macroquest/docs](https://github.com/macroquest/docs) (published at [docs.macroquest.org](https://docs.macroquest.org/)) | `d6b9550` |
| [macroquest/macroquest](https://github.com/macroquest/macroquest) `src/plugins/lua/MQ2Lua.cpp`, `src/main/MQCommandAPI.cpp` | master, 2026-11-17 |
| [brainiac/MQ2Nav](https://github.com/brainiac/MQ2Nav) `plugin/MQ2Navigation.cpp` | `ff507cd` |
| [brainiac/MQ2EasyFind](https://github.com/brainiac/MQ2EasyFind) `EasyFind.cpp` | `075519b` |
| [DerpleDude/rgmercs](https://github.com/DerpleDude/rgmercs) (RGMercs Lua) `utils/binds.lua`, `init.lua` | `c94847d` |

## 1. Game data (TLO) calls

A script resolved all 53 distinct `mq.TLO...` chains member by member against mq-definitions. 50 resolved automatically. The other 3 are plugin or Lua TLOs and were confirmed by hand:

| Chain | Defined in |
|---|---|
| `Cast.Status()`, `Cast.Result()` | mq-definitions `mq/plugins/Cast/_datatypes.lua` (MQ2Cast) |
| `Navigation.Active()`, `Navigation.MeshLoaded()` | mq-definitions `mq/tlo/_Navigation.lua` (MQ2Nav) |
| `Lua.Script('rgmercs').Status() == 'RUNNING'` | [MacroQuest Lua docs](https://docs.macroquest.org/lua/) list the statuses; `MQ2Lua.cpp` shows a text index is matched against script names without regard to case |

Members read through local variables were checked too:

| Local | Members used | Defined in |
|---|---|---|
| `sp = Me.Book(i)` (spell) | `Name`, `Skill`, `Mana`, `MyCastTime.Raw`, `TargetType`, `Beneficial`, `HasSPA(n)` | `mq/datatype/_spell.lua`; `Raw` in `_timestamp.lua` |
| `main = Me.Inventory('mainhand')` (item) | `Type`, `Name` | `mq/datatype/_item.lua`; `Inventory(name)` in `_character.lua`; slot name from [slot names](https://docs.macroquest.org/reference/general/slot-names/) |

## 2. MacroQuest Lua functions

All 12 are declared in mq-definitions `mq/mq.lua`: `mq.bind`, `mq.unbind`, `mq.event`, `mq.unevent`, `mq.doevents`, `mq.delay`, `mq.cmd`, `mq.gettime`, `mq.pickle`, `mq.unpickle`, `mq.configDir`, `mq.imgui.init`.

## 3. ImGui

- All 37 functions used exist in mq-definitions `imgui/imgui.lua`. The arguments and return values of each call were compared with its declared signatures, for example `Begin(name, open)` returns `open, draw`; `Checkbox` returns the new value; `Combo(label, current, items, count)`; `BeginTable(id, cols, flags, outerX, outerY)`; `SetNextWindowSize(x, y, cond)`; `ProgressBar(fraction, x, y, overlay)`; `PushStyleColor(idx, r, g, b, a)`.
- All 9 constants are present in `imgui/imgui_enums.lua`: `ImGuiCol.Text`, `ImGuiCond.FirstUseEver`, `ImGuiTableFlags.RowBg/BordersInnerV/ScrollY/SizingStretchProp`, `ImGuiTableColumnFlags.WidthFixed/WidthStretch`, `ImGuiTreeNodeFlags.DefaultOpen`.
- The window callback (`ui.render`) sends no commands and never calls `mq.delay`. The window only sets requests, and the main loop in `init.lua` acts on them, which is the pattern MacroQuest recommends.

## 4. Slash commands

These are all 27 command forms the code can send:

| Command as sent | Defined by |
|---|---|
| `/memspell <gem> "<name>"` | [MacroQuest /memspell](https://docs.macroquest.org/reference/commands/memspell/) |
| `/casting "<name>\|gem<n>" -maxtries\|1 [-targetid\|<id>]` | [MQ2Cast](https://docs.macroquest.org/plugins/community-plugins/mq2cast/) (pipe gem form, `-maxtries`, `-targetid` all documented with examples) |
| `/interrupt` | [MQ2Cast](https://docs.macroquest.org/plugins/community-plugins/mq2cast/) |
| `/cast <gem>` | [MacroQuest /cast](https://docs.macroquest.org/reference/commands/cast/) (`/cast 1` example) |
| `/mqtarget id <id>`, `/mqtarget npc <name>` | [MacroQuest /mqtarget](https://docs.macroquest.org/reference/commands/mqtarget/) (spawn search) |
| `/face fast id <id>`, `/face fast loc <y>,<x>` | [MacroQuest /face](https://docs.macroquest.org/reference/commands/face/) |
| `/doability "<name>"` | [MacroQuest /doability](https://docs.macroquest.org/reference/commands/doability/) |
| `/destroy` | [MacroQuest /destroy](https://docs.macroquest.org/reference/commands/destroy/) |
| `/makemevisible` | [MacroQuest /makemevisible](https://docs.macroquest.org/reference/commands/makemevisible/) |
| `/beep` | [MacroQuest /beep](https://docs.macroquest.org/reference/commands/beep/) |
| `/nomodkey /keypress forward hold`, `/nomodkey /keypress forward` | [/keypress](https://docs.macroquest.org/reference/commands/keypress/) (this exact pair is its example), [/nomodkey](https://docs.macroquest.org/reference/commands/nomodkey/) |
| `/lua stop skillmaster` | [MacroQuest Lua docs](https://docs.macroquest.org/lua/) ("will accept script name or PID") |
| `/nav id <id>`, `/nav locyxz <y> <x> <z>`, `/nav stop` | MQ2Nav source `MQ2Navigation.cpp` (`id`, `locyxz`, `stop` handlers) |
| `/travelto <zone>`, `/travelto stop` | [MQ2EasyFind /travelto](https://www.redguides.com/docs/projects/mq2easyfind/cmd-travelto/); `EasyFind.cpp` registers `/travelto` and handles `stop` |
| `/startforage`, `/stopforage` | [MQ2AutoForage](https://docs.macroquest.org/plugins/community-plugins/mq2autoforage/) |
| `/rgl pause`, `/rgl unpause` | [RGMercs `utils/binds.lua`](https://github.com/DerpleDude/rgmercs/blob/c94847de7dda44123d5b5693049547541df75d87/utils/binds.lua#L567-L589). RGMercs binds `/rglua` (`init.lua`); MacroQuest's `MQCommandAPI.cpp` matches a typed command by prefix, so `/rgl` reaches it, and RGMercs sends `/rgl ...` itself |
| `/sit`, `/stand`, `/autoinventory` | EverQuest built in commands (`/autoinventory` appears in the [Cursor TLO example](https://docs.macroquest.org/reference/top-level-objects/tlo-cursor/)) |

## 5. Chat events

| Pattern | Source |
|---|---|
| `You have become better at #1#! (#2#)` | Same pattern as the [Spell Skill Trainer macro](https://docs.macroquest.org/macros/gallery/spell-skill-trainer/) in the MacroQuest docs |
| `#*#beg from someone when they can#*#see you#*#` | In game line you reported for 1.0.5: "How can you beg from someone when they can't see you?" Wildcards cover the apostrophe |

## 6. Skill names

All 36 skill names in the catalog (`data.lua`) appear in the MacroQuest [skills list](https://docs.macroquest.org/reference/general/skills-list/).

## 7. RedGuides Lua conventions

- Folder package started with `/lua run skillmaster`; `init.lua` is the entry point.
- Window registered once with `mq.imgui.init`; every `Begin` has its `End`, every `Push` its `Pop` (the smoke test checks the balance for every tab and state).
- Settings stored in `mq.configDir`, one file per server and character, written with `mq.pickle`.
- Binds and events are removed at shutdown (`mq.unbind`, `mq.unevent`).
- The Pause button sends nothing while paused (smoke test scenario "pause").
- Optional plugins are detected first; a missing plugin skips its feature with a warning and never errors.

## Changes made by this audit

- `ARCHITECTURE.md`: the source for `/rgl pause` and `/rgl unpause` was a forum thread; it now links to the RGMercs source. The `/mqtarget` row now links to its own page, and the `/cast` and `/interrupt` row now links to the MacroQuest and MQ2Cast pages.
- `core.lua` (comment only): the RGMercs line in the plugins section now carries the source link.

## Still needs a live client

Code that exists and is used as documented can still behave differently in game. Those checks are open as issues #11 to #15 on the board.

<!-- END OF FILE: skillmaster/AUDIT.md -->
