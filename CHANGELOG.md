<!--
  FILE    : skillmaster/CHANGELOG.md
  PACKAGE : SkillMaster Lua (MacroQuest / EverQuest)
  WHAT    : Version history, newest first. dev/doc_audit.py reads the first
            "## x.y.z" heading and checks every Lua file's VERSION against it.
-->
# SkillMaster changelog

## 1.0.3 (2026-11-14)

- Begging no longer runs you across the zone when you are already at Diggs. Within Begging range (new Options setting, default 15) there is no movement at all. Further away, you walk straight to Diggs with `/nav id`; the fixed Skills2 spot is only a fallback when Diggs is not found. If Diggs wanders out of range during the trip, you walk back to Diggs.
- When Begging reaches its cap the trip now really finishes its return leg; the Return zone setting defaults to blank, so you stay where you are. Type a zone short name (for example poknowledge) in Options to travel there afterwards.
- Stopping a run only sends /nav stop, /travelto stop or the forward key release when that movement is actually in progress.
- Smoke test: beside Diggs and far from Diggs.

## 1.0.2 (2026-11-14)

- Tracking: when your character can train it, ticking Tracking presses it every time it is ready. Each press refreshes tracking and can raise the skill. The Tracking window is no longer waited for or closed; open or closed does not matter.
- Smoke test: Tracking with the window open and with it closed.

## 1.0.1 (2026-11-14)

Fixes the Begging spam "How can you beg from someone when they can't see you?".

- Before each beg the trip turns Sneak off (one Sneak press when Me.Sneaking is true) and drops Hide or invisibility with [/makemevisible](https://docs.macroquest.org/reference/commands/makemevisible/).
- A chat event catches that reply; after three /makemevisible attempts without a Begging gain the trip stops with the reason, and the run stops when nothing else is left.
- Hide, Sneak and Feign Death are no longer trained at the Begging spot; they are trained after the trip.
- New note in the warning panel when Begging is ticked with Hide, Sneak or Feign Death, or while unseen.
- Smoke test: two Begging scenarios.

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
