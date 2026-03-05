local api = vim.api
local f = string.format
local fs_stat = vim.loop.fs_stat

local module = {}

local dir_to_root = {}

local function normalize(path)
  if not path or #path == 0 then
    return vim.fn.getcwd()
  end

  local abs = vim.fn.fnamemodify(path, ':p')

  if #abs > 1 and abs:sub(-1) == '/' then
    abs = abs:sub(1, -2)
  end

  return abs
end

local function is_dir(path)
  local stat = fs_stat(path)
  return stat and stat.type == 'directory'
end

local function parent(path)
  local p = vim.fn.fnamemodify(path, ':h')
  if p == path then
    return nil
  end
  return p
end

local function has_git_marker(path)
  return fs_stat(path .. '/.git') ~= nil
end

local function walk_to_root(dir)
  local visited = {}
  local current = dir
  local found = false

  while current do
    if dir_to_root[current] ~= nil then
      found = dir_to_root[current]
      break
    end

    table.insert(visited, current)

    if has_git_marker(current) then
      found = current
      break
    end

    current = parent(current)
  end

  for _, entry in pairs(visited) do
    dir_to_root[entry] = found
  end

  return found
end

function module.resolve(path)
  local abs = normalize(path)
  local dir = is_dir(abs) and abs or normalize(vim.fn.fnamemodify(abs, ':h'))
  local root = walk_to_root(dir)
  return root or dir
end

function module.label(cwd)
  local normalized = normalize(cwd)
  local tail = vim.fn.fnamemodify(normalized, ':t')
  return #tail > 0 and tail or normalized
end

local function make_grouped(entries)
  local ordered = {}
  local grouped = {}
  local label_count = {}

  for _, entry in pairs(entries) do
    local cwd = entry.data.cwd
    local group = grouped[cwd]

    if not group then
      group = {
        cwd = cwd,
        label = module.label(cwd),
      }
      grouped[cwd] = group
      table.insert(ordered, group)
    end
  end

  for _, group in pairs(ordered) do
    label_count[group.label] = (label_count[group.label] or 0) + 1
  end

  for _, group in ipairs(ordered) do
    if label_count[group.label] > 1 then
      group.label = vim.fn.fnamemodify(group.cwd, ':~')
    end
  end

  return ordered
end

local function group_from_current_buffer(groups, entries)
  local current = api.nvim_get_current_buf()
  local cwd

  for _, entry in pairs(entries) do
    if entry.data.bufnr == current then
      cwd = entry.data.cwd
      break
    end
  end

  if cwd then
    for _, group in pairs(groups) do
      if group.cwd == cwd then
        return group.cwd
      end
    end
  end
end

local function active_index(state)
  for i, group in ipairs(state.groups) do
    if group.cwd == state.active then
      return i
    end
  end

  return 1
end

local function termcode(input)
  return api.nvim_replace_termcodes(input, true, true, true)
end

local function shortcut_for(actions, index)
  local shortcuts = actions and actions.cwd_fast

  if type(shortcuts) ~= 'table' then
    return nil
  end

  return shortcuts[index]
end

local function shortcut_label(shortcut)
  if type(shortcut) ~= 'string' then
    return nil
  end

  return shortcut:gsub('^<', ''):gsub('>$', '')
end

function module.make_state(entries)
  local groups = make_grouped(entries)

  local state = {
    groups = groups,
    active = groups[1] and groups[1].cwd or nil,
  }

  state.active = group_from_current_buffer(groups, entries) or state.active

  return state
end

function module.refresh_state(state, entries)
  local previous = state.active
  state.groups = make_grouped(entries)
  state.active = nil

  if previous then
    for _, group in pairs(state.groups) do
      if group.cwd == previous then
        state.active = previous
        break
      end
    end
  end

  state.active = state.active or (state.groups[1] and state.groups[1].cwd or nil)
end

function module.select_next(state)
  if not state or #state.groups < 2 then
    return false
  end

  local index = active_index(state)
  local next_index = index + 1

  if next_index > #state.groups then
    next_index = 1
  end

  state.active = state.groups[next_index].cwd

  return true
end

function module.select_prev(state)
  if not state or #state.groups < 2 then
    return false
  end

  local index = active_index(state)
  local previous_index = index - 1

  if previous_index < 1 then
    previous_index = #state.groups
  end

  state.active = state.groups[previous_index].cwd

  return true
end

function module.select_by_shortcut(state, input, shortcuts)
  if not state or type(shortcuts) ~= 'table' then
    return false
  end

  for i, shortcut in ipairs(shortcuts) do
    if shortcut and input == termcode(shortcut) and state.groups[i] then
      state.active = state.groups[i].cwd
      return true
    end
  end

  return false
end

function module.entry_visible(entry, state, options)
  if state and state.active and entry.data.cwd ~= state.active then
    return false
  end

  if not options.include_current and not options.show_current and entry.data.bufnr == api.nvim_get_current_buf() then
    return false
  end

  return true
end

function module.visible_entries(entries, state, options)
  return vim.tbl_filter(function(entry)
    return module.entry_visible(entry, state, options)
  end, entries)
end

local function render_horizontal(groups, active, actions)
  local parts = { { ' ', 'Normal' } }

  for i, group in ipairs(groups) do
    if i > 1 then
      table.insert(parts, { ' | ', 'ReachGrayOut' })
    end

    local selected = group.cwd == active
    local shortcut = shortcut_label(shortcut_for(actions, i))

    if shortcut then
      table.insert(parts, { f('%s ', shortcut), selected and 'ReachCwdActive' or 'ReachCwdInactive' })
    end

    table.insert(parts, { f('%s', group.label), selected and 'ReachCwdActive' or 'ReachCwdInactive' })
  end

  table.insert(parts, { ' ', 'Normal' })

  return { { { ' ', 'Normal' } }, parts }
end

local function render_vertical(groups, active, actions)
  local lines = {}

  for i, group in ipairs(groups) do
    local selected = group.cwd == active
    local shortcut = shortcut_label(shortcut_for(actions, i))
    local parts = { { ' ', 'Normal' } }

    if shortcut then
      table.insert(parts, { f('%s ', shortcut), selected and 'ReachCwdActive' or 'ReachCwdInactive' })
    end

    table.insert(parts, { f('%s', group.label), selected and 'ReachCwdActive' or 'ReachCwdInactive' })
    table.insert(parts, { ' ', 'Normal' })

    table.insert(lines, parts)
  end

  return lines
end

function module.footer(state, options, actions)
  if not state or #state.groups < 2 then
    return nil
  end

  if options.layout == 'vertical' then
    return render_vertical(state.groups, state.active, actions)
  end

  return render_horizontal(state.groups, state.active, actions)
end

return module
