local f = string.format

local module = {}

function module.deduped_path(buffer)
  return table.concat(buffer.split_path, '/', #buffer.split_path - buffer.deduped)
end

function module.change_cwd(cwd, scope)
  if not cwd or #cwd == 0 then
    return
  end

  local scoped = ({ tab = 'tcd', window = 'lcd', global = 'cd' })[scope or 'tab'] or 'tcd'
  local escaped = vim.fn.fnameescape(cwd)

  pcall(vim.api.nvim_command, f('%s %s', scoped, escaped))
end

function module.switch_buf(buffer, options)
  options = options or {}

  if options.auto_chdir then
    module.change_cwd(buffer.cwd, options.scope)
  end

  local status = pcall(vim.api.nvim_command, f('buffer %s', buffer.bufnr))

  if not status then
    vim.api.nvim_command(f('view %s', buffer.name))
  end
end

function module.split_buf(buffer, command)
  vim.api.nvim_command(f('%s %s', command, buffer.bufnr))
end

return module
