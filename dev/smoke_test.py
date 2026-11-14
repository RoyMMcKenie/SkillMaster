"""
=============================================================================
  FILE        : skillmaster/dev/smoke_test.py
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.0
  CHANGES     : 1.0.0  First version, built the same way as the ClericFood
                       smoke test.

  WHAT  : Runs the real SkillMaster Lua code against a fake MacroQuest and a
          fake character, then checks each run ended the way it should.

  WHY   : Lets you test a logic change on your PC without logging in. It does
          NOT prove that in game names, window names or plugin commands are
          right; only a live run with Debug on can do that.

  WHERE : Lives in skillmaster/dev/. Not used by the game.

  HOW   : Uses the lupa Python package to run Lua. FAKE_MQ below builds a
          fake mq module whose TLOs read a small table of game state (G), and
          a fake mq.cmd that reacts to the commands SkillMaster sends:
            /casting      raises the spell's school and Specialize skill by
                          one, spends mana, and summons a NoRent item for
                          Conjuration spells
            /doability    raises that skill by one (Slam raises Bash)
            /sit /stand   change Sitting; sitting regains mana over time
            /destroy and /autoinventory empty the cursor
            /memspell     changes the gem
          Scenarios (SCENARIO global):
            cleric     three schools plus Specialize Alteration to cap,
                       meditating on the way; gem restored, Gate never cast,
                       summoned items destroyed
            conflict   two Specialize skills without Secondary Forte: Start
                       must be refused and nothing cast
            pause      Pause pressed mid run: nothing is sent while paused,
                       Resume finishes the run
            guard      Divination with no primary chosen: held at 50
            monk       Mend, Sneak, Feign Death, Kick on an NPC target

  WHEN  : After any change to logic in runner, spells, abilities, conflicts.

  USAGE : pip install lupa
          python dev/smoke_test.py          (run from the skillmaster folder)

          Every scenario also draws the whole window (all six tabs) with a
          fake ImGui, idle, running, paused and at the end, and fails on a
          wrong argument type or an unbalanced Begin/End, Push/Pop pair.

  NOTE  : lupa runs standard Lua 5.4; MacroQuest runs LuaJIT (Lua 5.1). The
          package avoids features that differ.
=============================================================================
"""

import os    # locate the package folder
import sys   # exit code

from lupa import LuaRuntime   # pip install lupa

# Parent of dev/ is the package; its parent holds skillmaster/ as a folder.
PACKAGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT_DIR = os.path.dirname(PACKAGE_DIR)

# -----------------------------------------------------------------------------
# The fake MacroQuest, written in Lua. SCENARIO is set from Python first.
# -----------------------------------------------------------------------------
FAKE_MQ = r'''
package.path = './?.lua;./?/init.lua;' .. package.path   -- find skillmaster.x

-- val(v): callable that returns v; any field returns val(nil).
local function val(v)
  return setmetatable({}, { __call = function() return v end,
                            __index = function() return val(nil) end })
end

-- Game state.
local G = {
  cls = 'CLR', mana = 100, maxMana = 100, sitting = false, hp = 100,
  gems = { 'Courage', 'Yaulp' }, cursor = nil, feign = false, target = nil,
  targetType = 'NPC', forte = false, merc = nil, cmds = {}, casts = {},
  skills = {}, ids = {}, names = {}, book = {},
}
local function skill(name, cur, cap)                 -- define a skill
  G.skills[name] = { cur = cur, cap = cap }
  if not G.ids[name] then G.names[#G.names + 1] = name; G.ids[name] = #G.names end
end
-- Every skill name the catalog may ask for exists with cap 0 by default.
for _, n in ipairs({ 'Abjuration','Alteration','Conjuration','Divination','Evocation',
  'Specialize Abjure','Specialize Alteration','Specialize Conjuration','Specialize Divination',
  'Specialize Evocation','Forage','Mend','Sneak','Hide','Feign Death','Tracking','Sense Traps',
  'Bind Wound','Fishing','Kick','Bash','Flying Kick','Round Kick','Tiger Claw','Eagle Strike',
  'Dragon Punch','Frenzy','Backstab','Disarm','Taunt','Intimidation','Begging','Safe Fall',
  'Meditate','Pick Lock','Disarm Traps' }) do skill(n, 0, 0) end

-- Spell book entries: name, school, mana, target type, beneficial, SPA list.
local function spell(name, school, mana, tt, ben, spas)
  G.book[#G.book + 1] = { name = name, school = school, mana = mana, tt = tt, ben = ben, spas = spas or {} }
end
local function spellObj(s)
  if not s then return val(nil) end
  return setmetatable({ Name = val(s.name), Skill = val(s.school), Mana = val(s.mana),
    MyCastTime = { Raw = val(2000) }, TargetType = val(s.tt), Beneficial = val(s.ben),
    HasSPA = function(n) for _, x in ipairs(s.spas) do if x == n then return val(true) end end return val(false) end },
    { __call = function() return s.name end })
end
local function byName(n) for _, s in ipairs(G.book) do if s.name == n then return s end end end

-- Scenario setup.
if SCENARIO == 'cleric' or SCENARIO == 'pause' or SCENARIO == 'conflict' or SCENARIO == 'guard' then
  skill('Alteration', 10, 60); skill('Divination', 5, SCENARIO == 'guard' and 100 or 30)
  skill('Conjuration', 0, 30); skill('Evocation', 0, 50); skill('Abjuration', 0, 50)
  for _, s in ipairs({ 'Abjure','Alteration','Conjuration','Divination','Evocation' }) do
    skill('Specialize ' .. s, 0, 60)                  -- equal caps: no primary yet
  end
  skill('Meditate', 20, 25)
  spell('Minor Healing', 'Alteration', 10, 'Single', true)
  spell('Gate', 'Alteration', 5, 'Self', true, { 26 })      -- must never be chosen
  spell('True North', 'Divination', 5, 'Self', true)
  spell('Halo of Light', 'Conjuration', 10, 'Self', true)
  spell('Strike', 'Evocation', 5, 'Single', false)
end
if SCENARIO == 'monk' then
  G.cls, G.maxMana, G.mana = 'MNK', 0, 0
  skill('Mend', 3, 10); skill('Sneak', 0, 8); skill('Feign Death', 0, 6); skill('Kick', 2, 12)
  G.target = 500
end

local TLO = {}
local function sk(k) if type(k) == 'number' then return G.names[k] end return k end
TLO.Me = {
  CleanName = val('Tester'), ID = val(1), NumGems = val(8),
  Skill = function(k) local s = G.skills[sk(k)] return val(s and s.cur) end,
  SkillCap = function(k) local s = G.skills[sk(k)] return val(s and s.cap) end,
  Ability = function(n) return val(n == 'Slam' and nil or 1) end,
  AbilityReady = function() return val(true) end,
  AltAbility = function(n) return val(n == 'Secondary Forte' and G.forte and 1 or nil) end,
  Book = function(i) return spellObj(G.book[i]) end,
  Gem = function(g) return { Name = function() return G.gems[g] end } end,
  SpellReady = function() return val(true) end,
  PctMana = function() return G.maxMana > 0 and math.floor(G.mana * 100 / G.maxMana) or 0 end,
  MaxMana = function() return G.maxMana end,
  CurrentMana = function() return G.mana end,
  Sitting = function() return G.sitting end,
  Class = { ShortName = function() return G.cls end },
  Mercenary = val(nil), CombatState = val('ACTIVE'),
  Feigning = function() return G.feign end,
  Zoning = val(false), Dead = val(false), PctHPs = function() return G.hp end,
  Stunned = val(false), Invis = val(false), FreeInventory = val(10),
  Inventory = function() return { Type = val('Shield'), Name = val('Shield') } end,
  Casting = { ID = val(nil) },
}
TLO.Skill = function(k) local n = sk(k)
  return { ID = val(G.ids[n]), Name = val(G.ids[n] and n or nil) } end
TLO.Plugin = function(n) return { IsLoaded = val(n == 'MQ2Cast' or n == 'MQ2Nav') } end
TLO.Lua = { Script = function() return { Status = val('RUNNING') } end }   -- RGMercs running
TLO.Navigation = { MeshLoaded = val(true), Active = val(false) }
TLO.Mercenary = { ID = val(nil) }
TLO.Target = { ID = function() return G.target end, Type = function() return G.target and G.targetType end,
               Dead = val(false), CleanName = val('a rat') }
TLO.Spawn = function() return { Distance = val(5) } end
TLO.Cast = { Status = val('I'), Result = function() return G.result end }
TLO.Cursor = { ID = function() return G.cursor and 1 or nil end,
               Name = function() return G.cursor end, NoRent = function() return G.cursor ~= nil end }
TLO.FindItemCount = function() return val(0) end
TLO.GameTime = { Night = val(false) }
TLO.Window = function() return { Open = val(false), DoClose = function() end } end
TLO.MacroQuest = { GameState = val('INGAME') }
TLO.EverQuest = { Server = val('test') }
TLO.Zone = { ShortName = val('poknowledge') }

-- Clock, events.
local now, evs, pending = 0, {}, {}
local mq = { TLO = TLO, configDir = '/tmp',
  gettime = function() now = now + 50 return now end,
  pickle = function() end, unpickle = function() error('no file') end,
  bind = function() end, unbind = function() end, imgui = { init = function() end },
  event = function(n, _, cb) evs[n] = cb end, unevent = function(n) evs[n] = nil end,
  doevents = function()
    for _, p in ipairs(pending) do if evs.skm_skillup then evs.skm_skillup('line', p[1], p[2]) end end
    pending = {}
  end,
}
function mq.delay(ms, cond)
  local step = cond and 10 or ms
  now = now + step
  if G.sitting and G.mana < G.maxMana then                  -- regen while sitting
    G.mana = math.min(G.maxMana, G.mana + 5)
    local m = G.skills['Meditate']                           -- Meditate rises while medding
    if m and m.cur < m.cap and step >= 100 then m.cur = m.cur + 1; pending[#pending + 1] = { 'Meditate', m.cur } end
  end
end

local function raise(name)                                 -- +1 up to cap, queue the chat line
  local s = G.skills[name]
  if s and s.cur < s.cap then s.cur = s.cur + 1; pending[#pending + 1] = { name, s.cur } end
end
function mq.cmd(c)
  G.cmds[#G.cmds + 1] = c
  if os.getenv('SKM_VERBOSE') then io.write('CMD ', c, '\n') end   -- trace commands
  local name, gem = c:match('^/casting "([^|]+)|gem(%d+)"')
  if name then
    local s = byName(name)
    G.casts[#G.casts + 1] = name
    if G.mana < s.mana then G.result = 'CAST_OUTOFMANA' return end
    G.mana = G.mana - s.mana; G.sitting = false
    raise(s.school); raise('Specialize ' .. (s.school == 'Abjuration' and 'Abjure' or s.school))
    G.gems[tonumber(gem)] = name
    if s.school == 'Conjuration' then G.cursor = 'Halo of Light' end
    G.result = 'CAST_SUCCESS'
  end
  local mg, mn = c:match('^/memspell (%d+) "(.+)"'); if mg then G.gems[tonumber(mg)] = mn end
  local ab = c:match('^/doability "(.+)"')
  if ab then
    if ab == 'Slam' then ab = 'Bash' end
    raise(ab)
    if ab == 'Feign Death' then G.feign = true end
  end
  if c == '/sit' then G.sitting = true end
  if c == '/stand' then G.sitting = false; G.feign = false end
  if c == '/destroy' or c == '/autoinventory' then G.cursor = nil end
  local tid = c:match('^/mqtarget id (%d+)'); if tid then G.target = tonumber(tid) end
end
package.loaded['mq'] = mq
-- Fake ImGui: Begin* and headers open, buttons not pressed, inputs keep
-- their value. Counts Begin/End pairs so a missing End fails the test.
local depth = { push = 0, id = 0, wrap = 0, dis = 0, child = 0, tab = 0, item = 0, tbl = 0, win = 0 }
G.uiCalls = 0
local IM = {
  Begin = function() depth.win = depth.win + 1 return true, true end,
  End = function() depth.win = depth.win - 1 end,
  BeginChild = function() depth.child = depth.child + 1 return true end,
  EndChild = function() depth.child = depth.child - 1 end,
  BeginDisabled = function() depth.dis = depth.dis + 1 end,
  EndDisabled = function() depth.dis = depth.dis - 1 end,
  BeginTabBar = function() depth.tab = depth.tab + 1 return true end,
  EndTabBar = function() depth.tab = depth.tab - 1 end,
  BeginTabItem = function() depth.item = depth.item + 1 return true end,
  EndTabItem = function() depth.item = depth.item - 1 end,
  BeginTable = function() depth.tbl = depth.tbl + 1 return true end,
  EndTable = function() depth.tbl = depth.tbl - 1 end,
  PushID = function() depth.id = depth.id + 1 end, PopID = function() depth.id = depth.id - 1 end,
  PushStyleColor = function() depth.push = depth.push + 1 end,
  PopStyleColor = function(n) depth.push = depth.push - (n or 1) end,
  PushTextWrapPos = function() depth.wrap = depth.wrap + 1 end,
  PopTextWrapPos = function() depth.wrap = depth.wrap - 1 end,
  Button = function() return false end, IsItemHovered = function() return true end,
  CollapsingHeader = function() return true end,
  Checkbox = function(_, v) assert(type(v) == 'boolean', 'Checkbox needs a boolean') return v, false end,
  Combo = function(_, c) assert(type(c) == 'number', 'Combo needs a number') return c, false end,
  InputInt = function(_, v) assert(type(v) == 'number', 'InputInt needs a number') return v, false end,
  InputText = function(_, v) assert(type(v) == 'string', 'InputText needs a string') return v, false end,
  TextUnformatted = function(t) assert(type(t) == 'string', 'text must be a string') end,
  Text = function(t) assert(type(t) == 'string', 'text must be a string') end,
  ProgressBar = function(f) assert(type(f) == 'number', 'ProgressBar needs a number') end,
}
package.loaded['ImGui'] = setmetatable(IM, { __index = function() return function() G.uiCalls = G.uiCalls + 1 end end })
local enum = setmetatable({}, { __index = function() return 1 end })   -- any enum value
for _, n in ipairs({ 'ImGuiCol', 'ImGuiTableFlags', 'ImGuiTableColumnFlags', 'ImGuiTreeNodeFlags', 'ImGuiCond' }) do _G[n] = enum end
local function renderAll()                                  -- draw the whole window once
  local ui = require('skillmaster.ui'); ui.open = true; ui.render()
  for k, v in pairs(depth) do assert(v == 0, 'unbalanced ImGui ' .. k .. ' ' .. v) end
end
print = function(...) if os.getenv('SKM_VERBOSE') then io.write(table.concat({...},' '),'\n') end end  -- quiet unless SKM_VERBOSE

-- Run.
local config = require('skillmaster.config'); config.load()
local stats = require('skillmaster.stats'); stats.init()
local runner = require('skillmaster.runner'); require('skillmaster.ui')
local sel = {
  pause    = { 'alteration', 'divination', 'conjuration', 'spec_alteration' },
  cleric   = { 'alteration', 'divination', 'conjuration', 'spec_alteration', 'meditate' },
  conflict = { 'spec_alteration', 'spec_evocation' },
  guard    = { 'divination' },
  monk     = { 'mend', 'sneak', 'feign', 'kick' },
}
for _, k in ipairs(sel[SCENARIO]) do config.setSelected(k, true) end
renderAll()                                                -- idle window
runner.request = 'start'
local ticks, pausedCmds, renders = 0, nil, 1
for i = 1, 3000 do
  if SCENARIO == 'pause' and i == 5 then runner.request = 'pause' end     -- press Pause
  if SCENARIO == 'pause' and i == 6 then pausedCmds = #G.cmds end          -- commands so far
  if SCENARIO == 'pause' and i == 60 then
    G.pauseIdle = (#G.cmds == pausedCmds) and runner.state == 'paused'      -- nothing sent while paused
    runner.request = 'start'                                                -- press Resume
  end
  mq.doevents(); runner.process(); runner.tick(); mq.delay(100); ticks = i   -- same order as init.lua
  if i % 50 == 0 or i == 3 or i == 30 then renderAll(); renders = renders + 1 end  -- running / paused window
  if i > 1 and runner.state == 'idle' then break end
end
renderAll()                                                -- final window
local stillRunning = runner.state ~= 'idle'
if stillRunning then runner.stop('test end') end

local function has(pat) for _, c in ipairs(G.cmds) do if c:find(pat, 1, true) then return true end end return false end
local gateCast, divCasts = false, 0
for _, n in ipairs(G.casts) do
  if n == 'Gate' then gateCast = true end
  if n == 'True North' then divCasts = divCasts + 1 end
end
return {
  ticks = ticks, still = stillRunning, casts = #G.casts, gate = gateCast,
  alt = G.skills['Alteration'].cur, specAlt = G.skills['Specialize Alteration'].cur,
  div = G.skills['Divination'].cur, specDiv = G.skills['Specialize Divination'].cur,
  conj = G.skills['Conjuration'].cur, med = G.skills['Meditate'].cur,
  gem1 = G.gems[1], gem2 = G.gems[2], cursor = G.cursor,
  destroyed = has('/destroy'), sat = has('/sit'), paused = has('/rgl pause'), unpaused = has('/rgl unpause'),
  mend = G.skills['Mend'].cur, sneak = G.skills['Sneak'].cur, fd = G.skills['Feign Death'].cur,
  kick = G.skills['Kick'].cur, gains = stats.data.total,
  pauseIdle = G.pauseIdle, renders = renders,
}
'''


def check(scenario, o):
    """
    WHAT  : Returns a list of failed expectations for one scenario.
    WHY   : Each scenario has different success rules.
    WHERE : Called by run.
    HOW   : Plain comparisons on the table returned from Lua.
    WHEN  : After each scenario.
    """
    bad = []                                                       # failed checks
    if scenario == 'cleric':
        if o['still']: bad.append('run did not finish')
        if (o['alt'], o['div'], o['conj'], o['specAlt']) != (60, 30, 30, 60): bad.append('skills not at cap')
        if o['gate']: bad.append('Gate was cast')
        if o['gem1'] != 'Courage' or o['gem2'] != 'Yaulp': bad.append('gems not restored')
        if o.get('cursor') is not None or not o['destroyed']: bad.append('summoned item not destroyed')
        if not o['sat']: bad.append('never meditated')
        if not (o['paused'] and o['unpaused']): bad.append('RGMercs not paused and unpaused')
    elif scenario == 'pause':
        if not o.get('pauseIdle'): bad.append('commands were sent while paused')
        if o['still'] or o['alt'] != 60: bad.append('run did not finish after Resume')
        if o['gem1'] != 'Courage': bad.append('gems not restored')
    elif scenario == 'conflict':
        if o['casts'] != 0: bad.append('cast despite mutually exclusive specializations')
    elif scenario == 'guard':
        if o['specDiv'] != 50: bad.append('guard did not hold Specialize Divination at 50 (got %s)' % o['specDiv'])
        if not o['still']: bad.append('run should still be waiting on the held school')
    elif scenario == 'monk':
        if o['still']: bad.append('run did not finish')
        if (o['mend'], o['sneak'], o['fd'], o['kick']) != (10, 8, 6, 12): bad.append('abilities not at cap')
    return bad


def run(scenario):
    """
    WHAT  : Runs one scenario in a fresh Lua state and prints the outcome.
    WHY   : Modules must load cleanly for each scenario.
    WHERE : Called by main.
    HOW   : New LuaRuntime, SCENARIO set, FAKE_MQ executed from the folder
            above skillmaster so require works, then check().
    WHEN  : Once per scenario.
    """
    lua = LuaRuntime(unpack_returned_tuples=True)                  # fresh Lua
    lua.globals().SCENARIO = scenario                              # read by FAKE_MQ
    cwd = os.getcwd()
    os.chdir(ROOT_DIR)                                             # so require('skillmaster.x') works
    try:
        out = dict(lua.execute(FAKE_MQ).items())
    finally:
        os.chdir(cwd)                                              # always go back
    bad = check(scenario, out)
    summary = {k: out.get(k) for k in ('ticks', 'casts', 'gains', 'still', 'renders')}
    print('%-9s %s %s' % (scenario, 'PASS' if not bad else 'FAIL', summary))
    for b in bad:
        print('          -', b)
    return not bad


def main():
    """
    WHAT  : Runs every scenario and exits 0 when all pass.
    WHY   : Entry point.
    WHERE : Bottom of this file.
    HOW   : run() for each name, even after a failure.
    WHEN  : From the command line.
    """
    names = ('cleric', 'pause', 'conflict', 'guard', 'monk')                # every scenario
    only = os.getenv('SKM_ONLY')                                   # optional single scenario
    results = [run(s) for s in names if not only or s == only]
    print('ALL PASS' if all(results) else 'SOME FAILED')
    sys.exit(0 if all(results) else 1)                             # non zero on failure


if __name__ == '__main__':
    main()   # only when executed directly

# =============================================================================
#   END OF FILE : skillmaster/dev/smoke_test.py
#
#   HOW TO EDIT SAFELY
#     - If SkillMaster starts reading a new TLO, add it to TLO in FAKE_MQ or
#       the test fails with "attempt to index a nil value".
#     - Add a scenario: a setup block in FAKE_MQ, a selection in sel, and a
#       branch in check().
# =============================================================================
