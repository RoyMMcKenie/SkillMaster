--[[==========================================================================
  FILE        : skillmaster/ui.lua
  PACKAGE     : SkillMaster Lua  (MacroQuest / EverQuest)
  VERSION     : 1.1.0
  CHANGES     : 1.1.0  Requires the four consolidated files (core, data,
                       actions, engine) instead of eleven modules. No
                       change to the window.
                1.0.5  Options, Trips: Set ledge here, Set landing spot here and
                       Clear spots for Safe Fall (drawSafeFallSpots).
                1.0.4  End SkillMaster button in the header, next to Stop.
                1.0.3  Options: Begging range box.
                1.0.2  Version number only; no code change.
                1.0.1  Version number only; no code change.
                1.0.0  First release. New window; Skills2 and skillup.lua
                       were driven only by slash commands.

  CREDITS     : The window is original to SkillMaster. Its options cover
                features first written in Skills2 0.4.2 by Blasty (RedGuides
                resource 2302) and Skill Skillup 1.1, skillup.lua, by
                GoldenFrog (RedGuides resource 2937). Full lineage in
                README, Credits and attribution.

  WHAT  : The SkillMaster window. Always visible at the top: run status,
          Start / Pause / Stop / End SkillMaster buttons and the warning
          panel. Below, tabs:
            Train       a "Master" checkbox per skill with a progress bar
                        (current of cap) and a live status
            Spells      the spell chosen per school, an override box, the
                        specialization state and the primary choice
            All Skills  every skill this character has, with how to raise
                        the ones SkillMaster does not train
            Session     time, gains, points per hour, casts, fizzles, log
            Options     every setting and which plugins are loaded
            Help        commands and a short guide

  WHY   : The request: the scripts worked but the interface was not ready,
          so a window with check boxes for the skills to master and a
          warning when mutually exclusive skills are ticked.

  WHERE : Registered by init.lua with mq.imgui.init, which calls ui.render
          every frame. ui.flush is called by the main loop to save settings.

  HOW   : Dear ImGui through MacroQuest's ImGui module. The window never acts
          in game: buttons set runner.request and the main loop acts. Setting
          changes mark the settings dirty and ui.flush saves them a second
          later, so dragging a number does not write the file every frame.
          All text goes through ImGui.TextUnformatted (or a coloured wrapper)
          because ImGui.Text treats '%' as a format code.

  WHEN  : Every frame while the script runs.

  READING GUIDE (for future you)
    - Every ImGui.BeginX that returned true needs its EndX. ImGui.Begin
      always needs ImGui.End, even when it returned false.
    - PushID / PopID make labels such as '##master' unique per row.
    - Checkboxes are locked while a run is active, because gems are
      assigned when a run starts.
==========================================================================]]--

local mq        = require('mq')                     -- TLO
local ImGui     = require('ImGui')                  -- MacroQuest ImGui binding
local core      = require('skillmaster.core')       -- foundation layer
local utils     = core.utils                        -- now, clamp, formatDuration
local config    = core.config                       -- settings
local plugins   = core.plugins                      -- plugin list
local data      = require('skillmaster.data')       -- knowledge layer
local catalog   = data.catalog                      -- entries
local skills    = data.skills                       -- values
local stats     = data.stats                        -- session
local actions   = require('skillmaster.actions')    -- action layer
local spells    = actions.spells                    -- chosen spells
local abilities = actions.abilities                 -- wait reasons
local travel    = actions.travel                    -- trip status
local engine    = require('skillmaster.engine')     -- decision layer
local conflicts = engine.conflicts                  -- warnings
local runner    = engine.runner                     -- state, request

local ui = {}

--- Window state ------------------------------------------------------------------
-- WHAT : open = window shown; dirty/dirtyAt = unsaved settings.
-- WHY  : Close hides the window (the run keeps going); saves are debounced.
-- WHERE: render, flush, init.lua commands.
-- HOW  : Plain fields.
-- WHEN : Every frame.
ui.open       = true    -- shown?
local dirty   = false   -- settings changed since last save?
local dirtyAt = 0       -- when they changed
local allList = nil     -- cached All Skills list, nil until first refresh

--- Colours ----------------------------------------------------------------------
-- WHAT : RGBA colours used in the window.
-- WHY  : Same meaning everywhere: red error, yellow warn, green good.
-- WHERE: Whole module.
-- HOW  : { r, g, b, a } from 0 to 1.
-- WHEN : Every frame.
local C = {
    error = { 1.00, 0.35, 0.35, 1 },   -- red
    warn  = { 1.00, 0.85, 0.30, 1 },   -- yellow
    info  = { 0.70, 0.70, 0.70, 1 },   -- grey
    good  = { 0.40, 0.90, 0.40, 1 },   -- green
    accent = { 0.45, 0.75, 1.00, 1 },  -- blue
}

--[[--------------------------------------------------------------------------
  markDirty()

  WHAT  : Notes that settings changed.
  WHY   : ui.flush saves a second later.
  WHERE : Every control that changes a setting.
  HOW   : Sets the flag and the time.
  WHEN  : On change.
----------------------------------------------------------------------------]]
local function markDirty()
    dirty, dirtyAt = true, utils.now()  -- save soon
end

--[[--------------------------------------------------------------------------
  ui.flush(force)

  WHAT  : Saves settings if they changed more than a second ago.
  WHY   : Debounced saving.
  WHERE : init.lua main loop; forced at shutdown.
  HOW   : config.save when dirty and old enough (or forced).
  WHEN  : Every main loop pass.
----------------------------------------------------------------------------]]
function ui.flush(force)
    -- Nothing pending.
    if not dirty then return end
    if force or utils.now() - dirtyAt > 1000 then
        config.save()        -- write the file
        dirty = false
    end
end

--[[--------------------------------------------------------------------------
  text(s) / colored(c, s) / wrapped(c, s)

  WHAT  : Draw plain, coloured, or coloured wrapped text safely.
  WHY   : ImGui.Text treats '%' as a format code; TextUnformatted does not.
  WHERE : Whole module.
  HOW   : PushStyleColor on ImGuiCol.Text around TextUnformatted, with
          PushTextWrapPos(0) for wrapping at the window edge.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function text(s)
    ImGui.TextUnformatted(tostring(s))    -- no format codes interpreted
end

local function colored(c, s)  -- see doc block above
    ImGui.PushStyleColor(ImGuiCol.Text, c[1], c[2], c[3], c[4])   -- set text colour
    ImGui.TextUnformatted(tostring(s))
    ImGui.PopStyleColor()                                         -- matches the push
end

local function wrapped(c, s)  -- see doc block above
    ImGui.PushTextWrapPos(0)                                      -- wrap at the window edge
    if c then colored(c, s) else text(s) end
    ImGui.PopTextWrapPos()                                        -- matches the push
end

--[[--------------------------------------------------------------------------
  tooltip(s)

  WHAT  : Shows s as a tooltip when the last item is hovered.
  WHY   : Notes and explanations without cluttering the window.
  WHERE : Whole module.
  HOW   : IsItemHovered then SetTooltip ('%' doubled so it shows as is).
  WHEN  : Right after the item it explains.
----------------------------------------------------------------------------]]
local function tooltip(s)
    if s and ImGui.IsItemHovered() then ImGui.SetTooltip((tostring(s):gsub('%%', '%%%%'))) end  -- escape percent signs
end

--[[--------------------------------------------------------------------------
  checkbox(label, key, tip) / intBox(label, key, lo, hi, tip)
  textBox(label, key, tip)

  WHAT  : Option controls bound to a settings key.
  WHY   : Same pattern for every option: draw, store, mark dirty.
  WHERE : ui.drawOptions.
  HOW   : ImGui.Checkbox / InputInt / InputText; numbers are clamped.
  WHEN  : Every frame on the Options tab.
----------------------------------------------------------------------------]]
local function checkbox(label, key, tip)
    local s = config.settings
    local v = ImGui.Checkbox(label, s[key] == true)              -- new value
    if v ~= (s[key] == true) then s[key] = v markDirty() end      -- changed
    tooltip(tip)
end

local function intBox(label, key, lo, hi, tip)  -- see doc block above
    local s = config.settings
    ImGui.SetNextItemWidth(120)                                   -- compact box
    local v = ImGui.InputInt(label, s[key], 1, 10)
    v = utils.clamp(v, lo, hi)                                    -- keep sane
    if v ~= s[key] then s[key] = v markDirty() end
    tooltip(tip)
end

local function textBox(label, key, tip)  -- see doc block above
    local s = config.settings
    ImGui.SetNextItemWidth(200)
    local v = ImGui.InputText(label, s[key] or '')                -- current text
    if v ~= s[key] then s[key] = v markDirty() end
    tooltip(tip)
end

--[[--------------------------------------------------------------------------
  entryStatus(e)

  WHAT  : Returns colour and text for an entry's status cell.
  WHY   : Tells the operator what is happening with each skill.
  WHERE : ui.drawTrain.
  HOW   : Checks, in order: unknown, unavailable, mastered, not ticked,
          blocked, guard, wait reason, trip status, training.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function entryStatus(e)
    if not skills.known(e) then return C.info, 'Unknown skill name' end         -- typo protection
    if not skills.available(e) then return C.info, 'Not available' end
    if skills.mastered(e) then return C.good, 'Mastered' end
    if e.method == 'hint' then return C.info, 'Manual only' end
    if not config.isSelected(e.key) then return C.info, '' end  -- unticked rows show nothing
    if e.method == 'cast' then  -- spell schools have extra states
        if spells.blocked[e.school] then return C.error, 'Blocked: ' .. spells.blocked[e.school] end  -- fatal cast result this run
        local held = conflicts.specBlocked(e.school)  -- specialization guard
        if held then return C.warn, 'Held by guard' end  -- waiting for a primary choice
        if spells.scanned and not spells.choose(e.school) then return C.warn, 'No spell' end  -- nothing safe scribed
    end
    local why = abilities.waiting[e.key]                                       -- set by abilities.train
    if why and why ~= 'not ready' then return C.warn, 'Waiting: ' .. why end
    if e.method == 'travel' and travel.trip and travel.trip.key == e.key then
        return C.accent, travel.trip.status
    end
    if runner.state == 'running' then return C.accent, 'Training' end  -- run active and nothing wrong
    return C.info, 'Ticked'  -- ticked, run not started
end

--[[--------------------------------------------------------------------------
  drawHeader()

  WHAT  : Status line, Start / Pause / Stop buttons, warning panel.
  WHY   : Always visible whatever tab is open.
  WHERE : ui.render.
  HOW   : Buttons set runner.request. Warnings come from conflicts.list.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawHeader()
    local stateColor = runner.state == 'running' and C.good or (runner.state == 'paused' and C.warn or C.info)  -- colour by state
    colored(stateColor, string.format('%s  |  %s', runner.state:upper(), runner.status))
    if spells.lastResult ~= '' then
        ImGui.SameLine()
        colored(C.info, '  last cast: ' .. spells.lastResult)  -- what MQ2Cast or /cast reported
    end

    -- Buttons. Start doubles as Resume when paused.
    if runner.state == 'running' then
        if ImGui.Button('Pause') then runner.request = 'pause' end
    else
        if ImGui.Button(runner.state == 'paused' and 'Resume' or 'Start') then runner.request = 'start' end  -- Start, or Resume when paused
    end
    ImGui.SameLine()  -- next button on the same row
    ImGui.BeginDisabled(runner.state == 'idle')                    -- nothing to stop
    if ImGui.Button('Stop') then runner.request = 'stop' end
    ImGui.EndDisabled()
    ImGui.SameLine()
    -- End SkillMaster: tidy shutdown (stop, gems back, RGMercs unpaused,
    -- settings saved), then init.lua sends /lua stop skillmaster.
    if ImGui.Button('End SkillMaster') then runner.endScript, runner.quitting = true, true end
    tooltip('Stops the run, restores your gems, unpauses RGMercs, saves settings, then ends the script with /lua stop skillmaster.')  -- explain the button
    ImGui.SameLine()
    colored(C.info, string.format('Session %s, %d skill ups',  -- quick session summary
        utils.formatDuration(stats.data.runMs), stats.data.total))  -- format arguments

    -- Warnings.
    local list = conflicts.list(false)
    if #list > 0 then
        ImGui.SeparatorText('Warnings')
        for _, c in ipairs(list) do  -- one line per warning
            local col = C[c.level] or C.info                       -- level to colour
            local tag = c.level == 'error' and '[!] ' or (c.level == 'warn' and '[*] ' or '[i] ')
            wrapped(col, tag .. c.text)
        end
    end
    ImGui.Separator()  -- divides header from tabs
end

--[[--------------------------------------------------------------------------
  ui.drawTrain()

  WHAT  : The Train tab: Master checkbox, progress and status per skill.
  WHY   : The main point of the window.
  WHERE : ui.render.
  HOW   : One collapsing section per catalog group, each a four column
          table. Checkboxes are disabled while a run is active and for
          skills this character cannot raise.
  WHEN  : Every frame while the tab is open.
----------------------------------------------------------------------------]]
function ui.drawTrain()
    local locked = runner.state ~= 'idle'                              -- no changes mid run
    ImGui.BeginDisabled(locked)
    if ImGui.Button('Tick all available') then
        for _, e in ipairs(catalog.SKILLS) do
            -- Skip specializations (mutually exclusive), fear risk, hints and trips.
            if skills.available(e) and not skills.mastered(e) and e.group ~= 'specialize'
               and not e.fearRisk and e.method ~= 'hint' and e.method ~= 'travel' then
                config.setSelected(e.key, true)
            end
        end
        markDirty()  -- save shortly
    end
    tooltip('Ticks every skill you can raise except specializations, trips and Intimidation, which need a deliberate choice.')  -- explain what is skipped
    ImGui.SameLine()  -- same row
    if ImGui.Button('Clear all') then config.settings.selected = {} markDirty() end  -- untick everything
    ImGui.EndDisabled()  -- matches BeginDisabled(locked)
    if locked then ImGui.SameLine() colored(C.info, 'Stop the run to change ticks.') end  -- why the buttons are grey

    local flags = ImGuiTableFlags.RowBg + ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.SizingStretchProp  -- distinct bits, so + is a safe OR
    for _, g in ipairs(catalog.GROUPS) do  -- one section per group
        if ImGui.CollapsingHeader(g.title, ImGuiTreeNodeFlags.DefaultOpen) then  -- open on first show
            if ImGui.BeginTable('##skm_' .. g.id, 4, flags) then  -- four columns
                ImGui.TableSetupColumn('Master', ImGuiTableColumnFlags.WidthFixed, 50)  -- checkbox column
                ImGui.TableSetupColumn('Skill', ImGuiTableColumnFlags.WidthStretch, 1.2)  -- skill name column
                ImGui.TableSetupColumn('Progress', ImGuiTableColumnFlags.WidthStretch, 1.4)  -- progress bar column
                ImGui.TableSetupColumn('Status', ImGuiTableColumnFlags.WidthStretch, 1.6)  -- status text column
                ImGui.TableHeadersRow()  -- draw the column titles
                for _, e in ipairs(catalog.SKILLS) do  -- rows for this group only
                    if e.group == g.id then  -- entry belongs to this section
                        ImGui.TableNextRow()  -- start a row
                        ImGui.PushID(e.key)                                -- unique labels per row
                        local avail = skills.available(e)
                        ImGui.TableNextColumn()
                        ImGui.BeginDisabled(locked or not avail or e.method == 'hint')
                        local was = config.isSelected(e.key)  -- current tick
                        local now = ImGui.Checkbox('##master', was)        -- the Master tick
                        if now ~= was then config.setSelected(e.key, now) markDirty() end
                        ImGui.EndDisabled()
                        tooltip('Tick to master ' .. catalog.label(e))
                        ImGui.TableNextColumn()  -- skill name cell
                        if avail then text(catalog.label(e)) else colored(C.info, catalog.label(e)) end  -- grey when not available
                        tooltip(e.notes)  -- hover for notes
                        ImGui.TableNextColumn()  -- progress cell
                        local cur, cap = skills.value(e.name)  -- live numbers
                        ImGui.ProgressBar(skills.fraction(e), -1, 0, string.format('%d / %d', cur, cap))  -- -1 fills the cell
                        ImGui.TableNextColumn()
                        local col, st = entryStatus(e)
                        colored(col, st)
                        ImGui.PopID()                                      -- matches PushID
                    end
                end
                ImGui.EndTable()
            end
        end
    end
end

--[[--------------------------------------------------------------------------
  ui.drawSpells()

  WHAT  : The Spells tab.
  WHY   : Shows exactly which spell each school will use, lets the operator
          override it, and shows specialization state and primary choice.
  WHERE : ui.render.
  HOW   : Rescan button (spells.scan), specialization summary from
          conflicts.specState, a primary Combo, and a table per school with
          an InputText override.
  WHEN  : Every frame while the tab is open.
----------------------------------------------------------------------------]]
function ui.drawSpells()
    local s = config.settings
    if ImGui.Button('Rescan spell book') then spells.scan() end
    tooltip('Reads your spell book again. Also done at every Start.')  -- explain the button
    if not spells.scanned then ImGui.SameLine() colored(C.warn, 'Not scanned yet.') end  -- book not read yet

    -- Specialization summary.
    ImGui.SeparatorText('Specialization')
    local st = conflicts.specState()
    if st.locked then
        colored(C.good, 'Primary locked in: ' .. tostring(st.primary))  -- caps differ: primary set
    else
        colored(C.warn, 'No primary yet. The first Specialize skill past 50 becomes primary.')  -- still undecided
    end
    colored(C.info, st.forte and 'Secondary Forte: owned (one more may pass the others).' or 'Secondary Forte: not owned.')  -- AA allows one more
    local items = { '(not set)' }                                       -- combo items
    local cur = 1
    for i, sc in ipairs(catalog.SCHOOLS) do
        items[#items + 1] = sc.school
        if sc.school == s.specPrimary then cur = i + 1 end  -- preselect the saved choice
    end
    ImGui.SetNextItemWidth(180)  -- compact combo
    local pick = ImGui.Combo('Intended primary', cur, items, #items)    -- 1 based
    if pick ~= cur then s.specPrimary = (pick == 1) and '' or items[pick] markDirty() end
    tooltip('The guard lets this school pass the guard value. Leave unset to use the single ticked Specialize skill.')

    -- Per school table.
    ImGui.SeparatorText('Training spell per school')
    local flags = ImGuiTableFlags.RowBg + ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.SizingStretchProp
    if ImGui.BeginTable('##skm_spells', 5, flags) then
        ImGui.TableSetupColumn('School', ImGuiTableColumnFlags.WidthFixed, 85)  -- school name
        ImGui.TableSetupColumn('Skill / Spec', ImGuiTableColumnFlags.WidthFixed, 110)  -- casting and specialize values
        ImGui.TableSetupColumn('Will cast', ImGuiTableColumnFlags.WidthStretch, 1.4)  -- spell the run will use
        ImGui.TableSetupColumn('Override', ImGuiTableColumnFlags.WidthStretch, 1.2)  -- operator override
        ImGui.TableSetupColumn('Gem', ImGuiTableColumnFlags.WidthFixed, 35)  -- borrowed gem
        ImGui.TableHeadersRow()  -- draw the column titles
        for _, sc in ipairs(catalog.SCHOOLS) do  -- one row per school
            ImGui.TableNextRow()  -- start a row
            ImGui.PushID(sc.school)                                       -- unique override box
            ImGui.TableNextColumn()
            text(sc.school)
            ImGui.TableNextColumn()
            local c1, k1 = skills.value(sc.school)  -- casting skill
            local c2, k2 = skills.value(sc.spec)  -- specialize skill
            text(string.format('%d/%d  %d/%d', c1, k1, c2, k2))  -- cur/cap  cur/cap
            tooltip(sc.school .. ' and ' .. sc.spec .. ', current of cap')  -- explain the numbers
            ImGui.TableNextColumn()  -- spell cell
            local name, how = spells.choose(sc.school)  -- what the run will cast
            if name then  -- a spell was found
                local info = spells.book[name]  -- scan details for the tooltip
                text(name)  -- spell name
                tooltip(string.format('%s. Mana %d, target %s.', how, info and info.mana or 0, info and info.targetType or '?'))  -- how chosen, cost, target
            else
                colored(C.warn, how)  -- why nothing was chosen
            end
            ImGui.TableNextColumn()  -- override cell
            ImGui.SetNextItemWidth(-1)                                    -- fill the cell
            local ov = s.spellOverride[sc.school] or ''
            local v = ImGui.InputText('##ov', ov)
            if v ~= ov then s.spellOverride[sc.school] = (v ~= '' and v or nil) markDirty() end
            tooltip('Exact spell name to use instead of the automatic choice. Leave blank for automatic.')  -- explain the box
            ImGui.TableNextColumn()  -- gem cell
            text(spells.gemFor[sc.school] and tostring(spells.gemFor[sc.school]) or '-')  -- dash before a run assigns gems
            ImGui.PopID()                                                 -- matches PushID
        end
        ImGui.EndTable()
    end
    wrapped(C.info, 'Automatic choice: your class default from Skills2 or skillup.lua if scribed, otherwise the cheapest safe spell of that school. Gates, teleports, binds, charm, fear, pet summons and area damage are never chosen automatically.')  -- how the automatic choice works
end

--- Hints for skills SkillMaster does not train ------------------------------------
-- WHAT : name -> how to raise it, for the All Skills tab.
-- WHY  : The whole picture in one place, even for skills raised by hand.
-- WHERE: ui.drawAllSkills.
-- HOW  : Plain table; anything not listed shows a general hint.
-- WHEN : Every frame on that tab.
local HINTS = {
    ['Alcohol Tolerance'] = 'Drink alcoholic drinks.',  -- not trained by SkillMaster
    ['Swimming']          = 'Swim in water.',  -- not trained by SkillMaster
    ['Channeling']        = 'Get hit while casting.',  -- not trained by SkillMaster
    ['Offense']           = 'Melee combat.',  -- not trained by SkillMaster
    ['Defense']           = 'Get hit in melee combat.',  -- not trained by SkillMaster
    ['Dodge']             = 'Get attacked in melee combat.',  -- not trained by SkillMaster
    ['Parry']             = 'Get attacked in melee combat.',  -- not trained by SkillMaster
    ['Riposte']           = 'Get attacked in melee combat.',  -- not trained by SkillMaster
    ['Block']             = 'Get attacked in melee combat.',  -- not trained by SkillMaster
    ['Double Attack']     = 'Melee combat.',  -- not trained by SkillMaster
    ['Dual Wield']        = 'Melee with a weapon in each hand.',  -- not trained by SkillMaster
    ['Archery']           = 'Shoot a bow at a target.',  -- not trained by SkillMaster
    ['Throwing']          = 'Throw weapons at a target.',  -- not trained by SkillMaster
    ['Baking']            = 'Tradeskill: combine in an oven or mixing bowl.',  -- not trained by SkillMaster
    ['Brewing']           = 'Tradeskill: combine in a brew barrel.',  -- not trained by SkillMaster
    ['Fletching']         = 'Tradeskill: combine in a fletching kit.',  -- not trained by SkillMaster
    ['Jewelry Making']    = 'Tradeskill: combine in a jewelry kit.',  -- not trained by SkillMaster
    ['Pottery']           = 'Tradeskill: combine on a pottery wheel, then a kiln.',  -- not trained by SkillMaster
    ['Smithing']          = 'Tradeskill: combine at a forge.',  -- not trained by SkillMaster
    ['Tailoring']         = 'Tradeskill: combine in a sewing kit or loom.',  -- not trained by SkillMaster
    ['Make Poison']       = 'Rogue tradeskill: combine in a mortar and pestle.',  -- not trained by SkillMaster
    ['Tinkering']         = 'Gnome tradeskill: combine in a toolbox.',  -- not trained by SkillMaster
    ['Research']          = 'Tradeskill: combine in a lexicon or quill.',  -- not trained by SkillMaster
    ['Alchemy']           = 'Shaman tradeskill: combine in a medicine bag.',  -- not trained by SkillMaster
}

--[[--------------------------------------------------------------------------
  ui.drawAllSkills()

  WHAT  : The All Skills tab: every skill with a cap above zero.
  WHY   : A full overview, and how to raise the ones not automated.
  WHERE : ui.render.
  HOW   : skills.allSkills() on the first open and on Refresh (it walks
          120 ids, too much for every frame). Table with value, cap,
          a SkillMaster column and a hint.
  WHEN  : Every frame while the tab is open.
----------------------------------------------------------------------------]]
function ui.drawAllSkills()
    if allList == nil or ImGui.Button('Refresh') then allList = skills.allSkills() end  -- first time or on request
    if allList then ImGui.SameLine() colored(C.info, string.format('%d skills', #allList)) end
    local flags = ImGuiTableFlags.RowBg + ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.SizingStretchProp + ImGuiTableFlags.ScrollY
    if ImGui.BeginTable('##skm_all', 4, flags, 0, 380) then
        ImGui.TableSetupColumn('Skill', ImGuiTableColumnFlags.WidthStretch, 1.2)  -- skill name
        ImGui.TableSetupColumn('Value', ImGuiTableColumnFlags.WidthFixed, 80)  -- current / cap
        ImGui.TableSetupColumn('SkillMaster', ImGuiTableColumnFlags.WidthFixed, 80)  -- trained here or by hand
        ImGui.TableSetupColumn('How to raise', ImGuiTableColumnFlags.WidthStretch, 2)  -- hint text
        ImGui.TableHeadersRow()  -- draw the column titles
        for _, row in ipairs(allList or {}) do  -- one row per skill
            ImGui.TableNextRow()  -- start a row
            ImGui.TableNextColumn()  -- name cell
            if row.cur >= row.cap then colored(C.good, row.name) else text(row.name) end  -- green when capped
            ImGui.TableNextColumn()
            text(string.format('%d / %d', row.cur, row.cap))
            ImGui.TableNextColumn()
            if row.tracked then colored(C.accent, 'Train tab') else colored(C.info, 'manual') end  -- automated or manual
            ImGui.TableNextColumn()  -- hint cell
            local hint = row.tracked and '' or (HINTS[row.name] or (row.name:find('^%d') and 'Melee with that weapon type.' or 'Use it in normal play.'))  -- weapon skills start with a digit (1H, 2H)
            colored(C.info, hint)  -- grey hint
        end
        ImGui.EndTable()  -- matches BeginTable
    end
end

--[[--------------------------------------------------------------------------
  ui.drawSession()

  WHAT  : The Session tab.
  WHY   : Shows progress and what the run has been doing.
  WHERE : ui.render.
  HOW   : Reads stats.data; Reset button calls stats.reset.
  WHEN  : Every frame while the tab is open.
----------------------------------------------------------------------------]]
function ui.drawSession()
    local d = stats.data
    text(string.format('Training time: %s', utils.formatDuration(d.runMs)))
    text(string.format('Skill ups: %d   (%.1f per hour)', d.total, stats.perHour()))  -- gains and rate
    text(string.format('Casts: %d   Fizzles: %d   Ability presses: %d', d.casts, d.fizzles, d.abilities))  -- activity counters
    if ImGui.Button('Reset session') then stats.reset() end  -- start a fresh session
    ImGui.SeparatorText('Gains this session')  -- per skill gains
    local any = false  -- any rows drawn?
    for name, n in pairs(d.gains) do  -- every skill that rose
        local cur, cap = skills.value(name)                            -- live numbers
        text(string.format('%-24s +%d   now %d / %d', name, n, cur, cap))
        any = true
    end
    if not any then colored(C.info, 'None yet.') end  -- empty session
    ImGui.SeparatorText('Log')  -- recent events
    if ImGui.BeginChild('##skm_log', 0, 220) then  -- scrolling child region
        for _, line in ipairs(d.log) do colored(C.info, line) end  -- newest first
    end
    ImGui.EndChild()                                                   -- always paired with BeginChild
end

--[[--------------------------------------------------------------------------
  ui.drawOptions()

  WHAT  : The Options tab.
  WHY   : Every setting in config.DEFAULTS has a control here.
  WHERE : ui.render.
  HOW   : checkbox / intBox / textBox helpers, grouped by topic, plus the
          plugin status list from plugins.LIST.
  WHEN  : Every frame while the tab is open.
----------------------------------------------------------------------------]]
function ui.drawOptions()
    local s = config.settings
    ImGui.SeparatorText('Plugins and scripts')
    for _, p in ipairs(plugins.LIST) do  -- every optional helper
        local on = plugins.has(p.id)  -- loaded or running?
        colored(on and C.good or C.info, string.format('%s %s', on and '[loaded] ' or '[missing]', p.id))  -- green when loaded
        tooltip(p.purpose)  -- what it is used for
    end
    if plugins.has('MQ2Nav') then  -- mesh only matters with MQ2Nav
        colored(plugins.navReady() and C.good or C.warn, plugins.navReady() and 'Nav mesh loaded for this zone.' or 'No nav mesh for this zone.')  -- mesh for this zone
    end
    if ImGui.Button('Recheck plugins') then plugins.refresh(true) end  -- force a fresh check

    ImGui.SeparatorText('Casting')  -- casting options
    checkbox('Use MQ2Cast when loaded', 'useMQ2Cast', 'Off uses plain /memspell and /cast.')  -- MQ2Cast or plain /cast
    intBox('First gem to borrow', 'firstGem', 1, 14, 'One gem per school from here upward.')  -- first borrowed gem
    checkbox('Restore original gems at the end', 'restoreGems')  -- put the bar back
    checkbox('Destroy temporary summoned items', 'destroySummoned', 'Only NoRent items, only right after a training cast. Everything else goes to your bags.')  -- NoRent items only
    intBox('Sit below mana %', 'medStartPct', 0, 99)  -- meditation start
    intBox('Stand at mana %', 'medStopPct', 1, 100)  -- meditation stop
    if s.medStopPct <= s.medStartPct then s.medStopPct = s.medStartPct + 1 markDirty() end  -- stop must be above start

    ImGui.SeparatorText('Specialization guard')
    checkbox('Guard specialization', 'specGuard', 'Until a primary is locked, hold every school except the intended primary at the value below.')
    intBox('Guard value', 'specGuardValue', 1, 400, 'The game makes the first specialization past 50 your primary.')  -- guard threshold

    ImGui.SeparatorText('Abilities')  -- ability options
    checkbox('Use MQ2AutoForage when loaded', 'useAutoForage', 'Needs Forage on an Abilities page. Its ini decides what is kept.')  -- plugin forage
    local merc = s.combatTargetSource == 'merc'  -- current mode
    local m = ImGui.Checkbox('Use my mercenary as the combat target', merc)  -- merc or own target
    if m ~= merc then s.combatTargetSource = m and 'merc' or 'target' markDirty() end  -- store as text
    tooltip('The Skills2 method. Not verified. Off: your own NPC target is used.')  -- not verified
    intBox('Melee range', 'meleeRange', 5, 50, 'Walk closer with MQ2Nav when further than this.')  -- nav closer than this

    ImGui.SeparatorText('Trips')  -- trip options
    textBox('Begging zone', 'beggingZone', 'Zone short name for /travelto.')  -- Begging destination
    textBox('Begging NPC', 'beggingNpc')  -- NPC to beg
    intBox('Begging range', 'beggingRange', 5, 50, 'Already this close to the NPC: you are not moved. Further away: you walk straight to the NPC.')  -- no move inside this
    textBox('Return zone', 'beggingReturn', 'Blank stays in the begging zone.')  -- travel home afterwards
    ui.drawSafeFallSpots()  -- record the ledge and landing spot
    intBox('Forward hold ms', 'safeFallHoldMs', 200, 5000, 'How long forward is held to step off the ledge.')  -- forward hold time

    ImGui.SeparatorText('Safety and finish')  -- safety options
    intBox('Stop below health %', 'stopHpPct', 0, 95)  -- health stop
    checkbox('Pause RGMercs during a run', 'pauseRGMercs', 'Sends /rgl pause at Start and /rgl unpause at Stop, only if it is running.')  -- RGMercs handling
    checkbox('Refuse to start with red warnings', 'blockOnErrors')  -- red warnings block Start
    checkbox('Stop when everything is mastered', 'stopWhenDone')  -- finish behaviour
    checkbox('Beep when everything is mastered', 'beepWhenDone')  -- audible finish
    checkbox('Debug trace in chat', 'debug', 'Shows every command sent.')  -- trace every command
    colored(C.info, 'Settings file: ' .. tostring(config.path))  -- where settings live
end

--[[--------------------------------------------------------------------------
  ui.drawSafeFallSpots()

  WHAT  : Shows the recorded Safe Fall ledge and landing spot, with buttons
          to record them where you stand and to clear them.
  WHY   : The Skills2 Plane of Knowledge ledge no longer works (no falling
          damage in PoK), and a ledge that hurts differs per character and
          level, so you pick it yourself.
  WHERE : ui.drawOptions, Trips section.
  HOW   : Set ledge here stores Zone.ShortName and { Me.Y, Me.X, Me.Z }.
          Set landing spot here stores { Me.Y, Me.X, Me.Z } and must be in
          the same zone. Clear empties all three. Buttons are disabled
          (hidden) while a run is active so the trip is not changed mid way.
  WHEN  : Every frame while the Options tab is open.
----------------------------------------------------------------------------]]
function ui.drawSafeFallSpots()
    local s = config.settings
    local function here()  -- your position as { y, x, z }
        return { tonumber(mq.TLO.Me.Y()) or 0, tonumber(mq.TLO.Me.X()) or 0, tonumber(mq.TLO.Me.Z()) or 0 }
    end
    local function show(p)  -- '{y, x, z}' or 'not set'
        if #p ~= 3 then return 'not set' end
        return string.format('%.1f, %.1f, %.1f', p[1], p[2], p[3])  -- y, x, z
    end
    colored(C.info, string.format('Safe Fall zone: %s', s.safeFallZone ~= '' and s.safeFallZone or 'not set'))  -- zone
    colored(C.info, 'Ledge (y, x, z): ' .. show(s.safeFallLedge))  -- step off point
    colored(C.info, 'Landing (y, x, z): ' .. show(s.safeFallLanding))  -- bottom
    if runner.state ~= 'idle' then  -- do not move the spot mid run
        colored(C.info, 'Stop the run to change the Safe Fall spots.')  -- why no buttons
        return  -- nothing else while running
    end
    local zone = utils.lower(mq.TLO.Zone.ShortName() or '')  -- current zone
    if ImGui.Button('Set ledge here') then  -- stand on the very edge
        s.safeFallZone = zone  -- zone of the ledge
        s.safeFallLedge = here()  -- where you step off
        s.safeFallLanding = {}  -- a new ledge needs a new landing spot
        markDirty()  -- save soon
    end
    tooltip('Stand on the very edge, facing the drop. The fall must hurt: no damage means no skill.')  -- how to use
    ImGui.SameLine()  -- buttons on one row
    if ImGui.Button('Set landing spot here') then  -- after dropping
        if #s.safeFallLedge ~= 3 or zone ~= s.safeFallZone then  -- wrong order or zone
            utils.warn('Set the ledge first, in the same zone, then drop and set the landing spot.')  -- tell the player
        else
            s.safeFallLanding = here()  -- where you came down
            markDirty()  -- save soon
        end
    end
    tooltip('After stepping off, stand where you landed. SkillMaster faces this spot before each step.')  -- how to use
    ImGui.SameLine()  -- same row
    if ImGui.Button('Clear spots') then  -- start over
        s.safeFallZone, s.safeFallLedge, s.safeFallLanding = '', {}, {}  -- all three empty
        markDirty()  -- save soon
    end
    if zone == 'poknowledge' then  -- PoK gives no falling damage
        colored(C.warn, 'The Plane of Knowledge gives no falling damage; Safe Fall will not rise here.')  -- warn before recording
    end
end

--[[--------------------------------------------------------------------------
  ui.drawHelp()

  WHAT  : The Help tab.
  WHY   : The commands and the basic flow without opening the README.
  WHERE : ui.render.
  HOW   : Static wrapped text.
  WHEN  : Every frame while the tab is open.
----------------------------------------------------------------------------]]
function ui.drawHelp()
    ImGui.SeparatorText('Quick start')
    wrapped(nil, '1. Tick Master next to each skill you want on the Train tab.')
    wrapped(nil, '2. Read the warnings at the top. Red ones must be fixed before Start.')  -- quick start step
    wrapped(nil, '3. For harmful spells and combat abilities, target an NPC you can handle.')  -- quick start step
    wrapped(nil, '4. Press Start. Each skill stops by itself when it reaches its cap.')  -- quick start step
    ImGui.SeparatorText('Commands')  -- command list
    for _, line in ipairs({  -- same list as /skm help
        '/skm            show or hide this window',  -- toggle
        '/skm start      start or resume',  -- start
        '/skm pause      pause (gems stay borrowed)',  -- pause
        '/skm stop       stop and restore gems',  -- stop
        '/skm all        tick every available skill (no specializations or trips)',  -- bulk tick
        '/skm none       untick everything',  -- bulk untick
        '/skm status     print progress of ticked skills',  -- chat report
        '/skm quit       stop and close SkillMaster',  -- exit
        '/skm end        same as the End SkillMaster button (/lua stop skillmaster)',  -- end the script
    }) do colored(C.accent, line) end  -- blue command lines
end

--[[--------------------------------------------------------------------------
  ui.render()

  WHAT  : Draws the whole window. Registered with mq.imgui.init.
  WHY   : Entry point for ImGui every frame.
  WHERE : init.lua registers it.
  HOW   : Begin (End always), header, tab bar with one tab per draw
          function. pcall around the contents so a drawing error shows in
          chat instead of killing the script.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
function ui.render()
    -- Hidden: draw nothing.
    if not ui.open then return end
    ImGui.SetNextWindowSize(620, 680, ImGuiCond.FirstUseEver)          -- first run size only
    local open, show = ImGui.Begin('SkillMaster##skm', ui.open)
    ui.open = open                                                      -- the X hides the window
    if show then
        local ok, err = pcall(function()
            drawHeader()
            if ImGui.BeginTabBar('##skm_tabs') then  -- tab strip
                if ImGui.BeginTabItem('Train') then ui.drawTrain() ImGui.EndTabItem() end  -- main tab
                if ImGui.BeginTabItem('Spells') then ui.drawSpells() ImGui.EndTabItem() end  -- spell choices
                if ImGui.BeginTabItem('All Skills') then ui.drawAllSkills() ImGui.EndTabItem() end  -- overview
                if ImGui.BeginTabItem('Session') then ui.drawSession() ImGui.EndTabItem() end  -- statistics
                if ImGui.BeginTabItem('Options') then ui.drawOptions() ImGui.EndTabItem() end  -- settings
                if ImGui.BeginTabItem('Help') then ui.drawHelp() ImGui.EndTabItem() end  -- commands
                ImGui.EndTabBar()  -- matches BeginTabBar
            end
        end)
        if not ok then utils.err('Window error: %s', tostring(err)) ui.open = false end  -- hide rather than spam
    end
    ImGui.End()                                                         -- always, even when not shown
end

--[[--------------------------------------------------------------------------
  ui.markDirty()

  WHAT  : Public access to markDirty for init.lua commands.
  WHY   : /skm all and /skm none change ticks too.
  WHERE : init.lua.
  HOW   : Calls the local.
  WHEN  : After a command changes settings.
----------------------------------------------------------------------------]]
function ui.markDirty()
    markDirty()  -- same debounce as the window
end

return ui  -- hand the module table to whoever requires it

--[[==========================================================================
  END OF FILE : skillmaster/ui.lua

  PUBLIC
    open, flush(force), render(), markDirty()
    drawTrain(), drawSpells(), drawAllSkills(), drawSession(),
    drawOptions(), drawSafeFallSpots(), drawHelp()

  DEPENDENCIES : mq, ImGui, skillmaster.core (utils, config, plugins),
                 skillmaster.data (catalog, skills, stats),
                 skillmaster.actions (spells, abilities, travel),
                 skillmaster.engine (conflicts, runner)

  HOW TO EDIT SAFELY
    - Never send game commands from here; set runner.request.
    - Use text()/colored()/wrapped(), not ImGui.Text, for anything that may
      contain a percent sign.
    - A new option needs a key in config.DEFAULTS too.
    - If an error occurs inside the pcall, a stray Begin without End is
      possible in ImGui; the window is hidden so the next frame starts clean.
==========================================================================]]--
