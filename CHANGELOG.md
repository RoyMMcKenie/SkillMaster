<!--
  FILE    : skillmaster/CHANGELOG.md
  PACKAGE : SkillMaster Lua (MacroQuest / EverQuest)
  WHAT    : Version history, newest first. dev/doc_audit.py reads the first
            "## x.y.z" heading and checks every Lua file's VERSION against it.
-->
# SkillMaster changelog

## 1.0.0 (2026-11-14)

First release. Merges Skills2 0.4.2 (Blasty) and skillup.lua 1.1 into one modular package.

- Window with a Master checkbox, progress bar and live status per skill.
- Warning panel: mutually exclusive specializations (red, blocks Start), Begging with Safe Fall, Hide with casting, Feign Death with combat, fear overrides, missing plugins, missing shield, bandages, fishing gear, full bags, missing target.
- Specialization guard so the wrong school cannot become permanent primary by accident.
- Spell book scan with safe automatic spell choice, class defaults from both scripts, per school overrides.
- MQ2Cast, MQ2Nav, MQ2EasyFind and MQ2AutoForage used when loaded; RGMercs paused and unpaused.
- Each skill stops at its cap; the run stops (and beeps) when everything ticked is mastered.
- Original spell gems restored; temporary summoned items destroyed only after a training cast.
- Session tab with gains, points per hour, casts, fizzles and a log. All Skills tab with hints.
- Per character settings file.
- Pause / Resume button in the window header and /skm pause: nothing is sent while paused, MQ2AutoForage and travel are stopped, and Resume carries on where it left off.
- A run with only Meditate left stops with an explanation instead of sitting at full mana.
- dev/smoke_test.py (fake MacroQuest, five scenarios, every tab drawn) and dev/doc_audit.py.

<!-- END OF FILE : skillmaster/CHANGELOG.md -->
