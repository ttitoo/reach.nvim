local cache = require('reach.cache')
local cwd_util = require('reach.buffers.cwd')
local handles = require('reach.buffers.handles')
local helpers = require('reach.helpers')
local read = require('reach.buffers.read')
local sort = require('reach.buffers.sort')
local util = require('reach.util')
local buffer_util = require('reach.buffers.util')

local auto_handles = require('reach.buffers.constant').auto_handles

local assign_auto_handles = handles.assign_auto_handles
local assign_dynamic_handles = handles.assign_dynamic_handles
local read_many = read.read_many
local read_one = read.read_one
local notify = helpers.notify

local insert = table.insert
local f = string.format

local module = {}

module.options = require('reach.buffers.options')

local state_to_handle_hl = setmetatable({
  ['DELETING'] = 'ReachHandleDelete',
  ['SPLITTING'] = 'ReachHandleSplit',
}, {
  __index = function()
    return 'ReachHandleBuffer'
  end,
})

function module.component(state)
  local buffer = state.data
  local ctx = state.ctx
  local is_current = buffer.bufnr == vim.api.nvim_get_current_buf()

  local parts = {}

  if ctx.marker_present then
    local marker = buffer.previous_marker or { ' ', 'Normal' }

    insert(parts, { f(' %s', marker[1]), marker[2] })
  end

  local pad = string.rep(' ', ctx.max_handle_length - #buffer.handle + 1)

  insert(parts, { f(' %s%s', buffer.handle, pad), state_to_handle_hl[ctx.state] })

  if ctx.state == 'SETTING_PRIORITY' then
    insert(parts, { f('%s ', buffer.priority or ' '), 'ReachPriority' })
  end

  if ctx.options.show_icons and buffer.icon then
    insert(parts, { f('%s ', buffer.icon[1]), buffer.icon[2] })
  end

  local tail_hl = 'ReachTail'

  if state.exact then
    tail_hl = 'ReachMatchExact'
  elseif is_current then
    tail_hl = 'ReachCurrent'
  end

  insert(parts, { f('%s ', buffer.tail), tail_hl })

  if ctx.options.show_modified and buffer.modified then
    insert(parts, { f('%s ', ctx.options.modified_icon), 'ReachModifiedIndicator' })
  end

  if buffer.deduped > 0 then
    local sp = buffer.split_path
    local dir = table.concat(sp, '/', #sp - buffer.deduped, #sp - 1)

    insert(parts, { f(' · /%s ', dir), 'ReachDirectory' })
  end

  if state.grayout or (is_current and ctx.options.grayout_current and ctx.state == 'OPEN') then
    for _, part in pairs(parts) do
      part[2] = 'ReachGrayOut'
    end
  end

  return parts
end

local function target_state(input, options)
  local actions = options.actions
  local r = util.replace_termcodes

  if options.cwd.enable then
    local next_key = actions.cwd_next or actions.cwd
    local prev_key = actions.cwd_prev

    if (next_key and input == r(next_key)) or (prev_key and input == r(prev_key)) then
      return 'SWITCHING_CWD'
    end

    if type(actions.cwd_fast) == 'table' then
      for _, key in ipairs(actions.cwd_fast) do
        if key and input == r(key) then
          return 'SWITCHING_CWD'
        end
      end
    end
  end

  if input == r(actions.delete) then
    return 'DELETING'
  end

  if vim.tbl_contains({ r(actions.split), r(actions.vertsplit), r(actions.tabsplit) }, input) then
    return 'SPLITTING'
  end

  if input == r(actions.priority) then
    return 'SETTING_PRIORITY'
  end

  return 'SWITCHING'
end

local function set_grayout(entries, matches)
  matches = vim.tbl_map(function(entry)
    return entry.data.bufnr
  end, matches)

  util.for_each(function(entry)
    entry:set_state({ grayout = not vim.tbl_contains(matches, entry.data.bufnr) })
  end, entries)
end

local function entry_condition(self, include_current)
  return function(entry)
    return cwd_util.entry_visible(entry, self.ctx.cwd, {
      show_current = self.ctx.options.show_current,
      include_current = include_current,
    })
  end
end

local function visible_entries(self, include_current)
  return cwd_util.visible_entries(self.ctx.picker.entries, self.ctx.cwd, {
    show_current = self.ctx.options.show_current,
    include_current = include_current,
  })
end

local function ensure_visible_group(self, include_current)
  local entries = visible_entries(self, include_current)

  if #entries > 0 or not self.ctx.cwd then
    return entries
  end

  for _, group in ipairs(self.ctx.cwd.groups) do
    self.ctx.cwd.active = group.cwd
    entries = visible_entries(self, include_current)

    if #entries > 0 then
      return entries
    end
  end

  return entries
end

local function assign_visible_handles(self, entries)
  local options = self.ctx.options

  if not self.ctx.cwd or options.handle == 'bufnr' then
    return
  end

  local buffers = vim.tbl_map(function(entry)
    return entry.data
  end, entries)

  if options.handle == 'auto' then
    assign_auto_handles(
      buffers,
      { auto_handles = options.auto_handles, auto_exclude_handles = options.auto_exclude_handles }
    )
  elseif options.handle == 'dynamic' then
    for _, buffer in ipairs(buffers) do
      buffer.low_priority = nil
    end

    assign_dynamic_handles(buffers, options)
  end

  local max_handle_length = 0

  for _, buffer in ipairs(buffers) do
    if #buffer.handle > max_handle_length then
      max_handle_length = #buffer.handle
    end
  end

  self.ctx.picker:set_ctx({ max_handle_length = max_handle_length })
end

local function prepare_entries(self, include_current)
  local entries = ensure_visible_group(self, include_current)
  assign_visible_handles(self, entries)
  return entries
end

local function sync_ctx(self)
  self.ctx.picker:set_ctx({ state = self.current, cwd = self.ctx.cwd })
end

local function refresh_cwd(self)
  if self.ctx.cwd then
    cwd_util.refresh_state(self.ctx.cwd, self.ctx.picker.entries)
  end
end

function module.make_cwd_state(entries, options)
  if not options.cwd.enable then
    return nil
  end

  return cwd_util.make_state(entries)
end

function module.footer(picker)
  local ctx = picker.ctx

  if not ctx.options.cwd.enable then
    return nil
  end

  return cwd_util.footer(ctx.cwd, ctx.options.cwd, ctx.options.actions)
end

module.machine = {
  initial = 'OPEN',
  state = {
    CLOSED = {
      hooks = {
        on_enter = function(self)
          self.ctx.picker:close()
        end,
      },
    },
    OPEN = {
      hooks = {
        on_enter = function(self)
          local picker = self.ctx.picker

          prepare_entries(self, false)
          sync_ctx(self)
          picker:render(entry_condition(self, false))

          local input = util.pgetcharstr()

          if not input then
            return self:transition('CLOSED')
          end

          self.ctx.state = {
            input = input,
          }

          self:transition(target_state(self.ctx.state.input, self.ctx.options))
        end,
      },
      targets = { 'SWITCHING', 'SWITCHING_CWD', 'DELETING', 'SPLITTING', 'SETTING_PRIORITY', 'CLOSED' },
    },
    SWITCHING = {
      hooks = {
        on_enter = function(self)
          local picker = self.ctx.picker
          local entries = prepare_entries(self, false)

          local match = read_one(entries, {
            input = self.ctx.state.input,
            on_input = function(matches, exact)
              if exact then
                exact:set_state({ exact = true })
              end

              if self.ctx.options.grayout then
                set_grayout(entries, matches)
              end

              picker:render(entry_condition(self, false))
            end,
          })

          if match then
            buffer_util.switch_buf(match.data, {
              auto_chdir = self.ctx.options.cwd.auto_chdir,
              scope = self.ctx.options.cwd.scope,
            })
          end

          self:transition('CLOSED')
        end,
      },
      targets = { 'CLOSED' },
    },
    SWITCHING_CWD = {
      hooks = {
        on_enter = function(self)
          local cwd = self.ctx.cwd
          local actions = self.ctx.options.actions
          local input = self.ctx.state.input

          if not cwd or #cwd.groups < 2 then
            return self:transition('OPEN')
          end

          if actions.cwd_prev and input == util.replace_termcodes(actions.cwd_prev) then
            cwd_util.select_prev(cwd)
          elseif (actions.cwd_next and input == util.replace_termcodes(actions.cwd_next))
            or (actions.cwd and input == util.replace_termcodes(actions.cwd))
          then
            cwd_util.select_next(cwd)
          else
            cwd_util.select_by_shortcut(cwd, input, actions.cwd_fast)
          end

          self:transition('OPEN')
        end,
      },
      targets = { 'OPEN' },
    },
    DELETING = {
      hooks = {
        on_enter = function(self)
          local picker = self.ctx.picker
          local entries = prepare_entries(self, true)

          sync_ctx(self)
          picker:render(entry_condition(self, true))

          if self.ctx.options.handle == 'bufnr' then
            local matches = read_many(entries)

            if not matches then
              return self:transition('OPEN')
            end

            picker:close()

            local count = 0
            local unsaved

            for _, match in pairs(matches) do
              local status = pcall(vim.api.nvim_command, match.data.delete_command)

              if status then
                count = count + 1
                picker:remove('bufnr', match.data.bufnr)
                refresh_cwd(self)
              elseif not unsaved then
                unsaved = match.data
              end
            end

            vim.api.nvim_command('redraw')

            notify(string.format('%s buffer%s deleted', count, count > 1 and 's' or ''), vim.log.levels.INFO)

            if unsaved then
              notify('Save your changes first\n', vim.log.levels.ERROR, true)
              buffer_util.switch_buf(unsaved, {
                auto_chdir = self.ctx.options.cwd.auto_chdir,
                scope = self.ctx.options.cwd.scope,
              })
            else
              return self:transition('OPEN')
            end
          else
            local match

            repeat
              entries = prepare_entries(self, true)
              local input = util.pgetcharstr()

              if not input then
                return self:transition('CLOSED')
              end

              if input == util.replace_termcodes(self.ctx.options.actions.delete) and #entries > 1 then
                return self:transition('OPEN')
              end

              match = read_one(entries, { input = input })

              if match then
                if match.data.bufnr == vim.api.nvim_get_current_buf() then
                  picker:close()
                end

                local status = pcall(vim.api.nvim_command, match.data.delete_command)

                if status then
                  picker:remove('bufnr', match.data.bufnr)
                  refresh_cwd(self)
                else
                  notify('Save your changes first', vim.log.levels.ERROR, true)
                  break
                end

                if #visible_entries(self, true) == 0 then
                  break
                end

                picker:render(entry_condition(self, true))
              end

            until not match
          end

          self:transition('CLOSED')
        end,
      },
      targets = { 'CLOSED', 'OPEN' },
    },
    SPLITTING = {
      hooks = {
        on_enter = function(self)
          local picker = self.ctx.picker
          local entries = prepare_entries(self, true)

          sync_ctx(self)
          picker:render(entry_condition(self, true))

          local match = read_one(entries, {
            on_input = function(matches, exact)
              if exact then
                exact:set_state({ exact = true })
              end

              if self.ctx.options.grayout then
                set_grayout(entries, matches)
              end

              picker:render(entry_condition(self, true))
            end,
          })

          if match then
            local action_to_command = {
              split = 'sbuffer',
              vertsplit = 'vertical sbuffer',
              tabsplit = 'tab sbuffer',
            }

            local action = util.find_key(function(value)
              return self.ctx.state.input == util.replace_termcodes(value)
            end, self.ctx.options.actions)

            buffer_util.split_buf(match.data, action_to_command[action])
          end

          self:transition('CLOSED')
        end,
      },
      targets = { 'CLOSED' },
    },
    SETTING_PRIORITY = {
      hooks = {
        on_enter = function(self)
          local picker = self.ctx.picker
          local options = self.ctx.options

          if options.handle ~= 'auto' then
            notify(f('Not available for options.handle == "%s"', options.handle), vim.log.levels.WARN)
            return self:transition('CLOSED')
          end

          prepare_entries(self, true)
          sync_ctx(self)
          picker:render(entry_condition(self, true))

          local priorities = cache.get('auto_priority')

          local buffers = vim.tbl_map(function(entry)
            return entry.data
          end, picker.entries)

          while true do
            local match = read_one(prepare_entries(self, true))

            if not match then
              break
            end

            match:set_state({ exact = true })
            match.data.priority = nil
            picker:render(entry_condition(self, true))

            local input = util.pgetcharstr()

            if not input then
              return self:transition('CLOSED')
            end

            match:set_state({ exact = false })

            priorities = vim.tbl_filter(function(item)
              return item.name ~= match.data.name and item.priority ~= input
            end, priorities)

            if vim.tbl_contains(auto_handles, input) then
              table.insert(priorities, { name = match.data.name, priority = input })
            end

            cache.set('auto_priority', priorities)

            buffers = sort.sort_priority(buffers, { sort = options.sort })

            assign_auto_handles(
              buffers,
              { auto_handles = options.auto_handles, auto_exclude_handles = options.auto_exclude_handles }
            )

            local bufnr_to_index = {}

            for i, buffer in ipairs(buffers) do
              bufnr_to_index[buffer.bufnr] = i
            end

            table.sort(picker.entries, function(a, b)
              return (bufnr_to_index[a.data.bufnr] or math.huge) < (bufnr_to_index[b.data.bufnr] or math.huge)
            end)

            refresh_cwd(self)
            prepare_entries(self, true)
            picker:render(entry_condition(self, true))
          end

          self:transition('CLOSED')
        end,
      },
      targets = { 'CLOSED' },
    },
  },
}

return module
