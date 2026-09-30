--- In-place inline diff for Claude Code (diff_opts.layout = "inline").
--
-- Unlike the "unified" layout (a separate read-only pane), this renders Claude's
-- proposal directly in the file's own buffer, in the window you are already using:
--
--   * Proposed / added lines are REAL buffer lines, highlighted green with a `+` sign,
--     so they can be edited before accepting.
--   * Deleted lines are virtual lines (extmark `virt_lines`) shown in red above the
--     spot they were removed from. They are visible but never part of the content.
--   * Each hunk is tracked by a range extmark, so its position survives edits.
--     Hunks can be accepted or rejected one at a time; rejecting a hunk puts the
--     original lines back.
--
-- Accepting the whole diff (`:w`, :ClaudeCodeDiffAccept) sends the buffer's current
-- content to Claude, so any edits made during review are kept. Rejecting restores
-- the original text. No window is put in 'diff' mode, which sidesteps the class of
-- problems where Claude diffs interfere with diffview/fugitive tabs (#277).
local M = {}

local logger = require("claudecode.logger")

local ns_track = vim.api.nvim_create_namespace("claudecode_inplace_track")
local ns_render = vim.api.nvim_create_namespace("claudecode_inplace_render")

M.ns_track = ns_track
M.ns_render = ns_render

---Default buffer-local keymaps active only while an inline diff is under review.
---Any entry can be set to `false` in `diff_opts.inline_keymaps` to disable it.
M.default_keymaps = {
  next_hunk = "]c",
  prev_hunk = "[c",
  accept_hunk = "<leader>ay",
  reject_hunk = "<leader>an",
}

---@return function|nil
local function get_diff_fn()
  return (vim.text and vim.text.diff) or vim.diff
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "ClaudeCodeInlineDiffAdd", { bg = "#2a4a2a", default = true })
  vim.api.nvim_set_hl(0, "ClaudeCodeInlineDiffDelete", { bg = "#4a2a2a", strikethrough = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeCodeInlineDiffAddSign", { fg = "#98c379", default = true })
  vim.api.nvim_set_hl(0, "ClaudeCodeInlineDiffDeleteSign", { fg = "#e06c75", default = true })
end

-- ── Pure functions (testable without a UI) ────────────────────────

---Split text into lines, dropping the empty entry produced by a trailing newline.
---@param text string
---@return string[]
function M.split_lines(text)
  if text == nil or text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---@class ClaudeCodeInplaceHunk
---@field new_start integer 0-based row of the first proposed line (or, for a pure deletion, the row the deletion sits before)
---@field new_count integer Number of proposed lines in this hunk
---@field old_lines string[] Original lines this hunk replaces (shown as virtual text)

---Compute hunks between the original and proposed text, positioned in the NEW text.
---@param old_text string
---@param new_text string
---@return ClaudeCodeInplaceHunk[]
function M.compute_hunks(old_text, new_text)
  old_text = old_text or ""
  new_text = new_text or ""
  local old_lines = M.split_lines(old_text)
  local indices = get_diff_fn()(old_text, new_text, { result_type = "indices" }) or {}

  local hunks = {}
  for _, h in ipairs(indices) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    local removed = {}
    -- For count_a == 0 (pure insertion) start_a is the line *before* the insertion.
    for i = start_a, start_a + count_a - 1 do
      removed[#removed + 1] = old_lines[i]
    end
    local new_start
    if count_b > 0 then
      new_start = start_b - 1
    else
      -- Pure deletion: start_b is the last new line before the removed block,
      -- so the removed lines sit before 0-based row start_b.
      new_start = start_b
    end
    hunks[#hunks + 1] = { new_start = new_start, new_count = count_b, old_lines = removed }
  end
  return hunks
end

---Join buffer lines into file content, keeping the trailing newline convention of `reference`.
---@param lines string[]
---@param reference string|nil Text whose trailing newline decides ours (Claude's proposal)
---@return string
function M.join_content(lines, reference)
  local content = table.concat(lines, "\n")
  local wants_eol = reference == nil or reference:sub(-1) == "\n"
  if wants_eol and #lines > 0 and content:sub(-1) ~= "\n" then
    content = content .. "\n"
  end
  return content
end

---Close the current undo block so the next change becomes its own undo step
---(`:h undo-break`: setting 'undolevels' to itself ends the block).
---@param buf integer
local function break_undo(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
  end)
end

-- ── Hunk tracking ─────────────────────────────────────────────────

---Current 0-based [start, end) row range of a tracked hunk, or nil if its mark is gone.
---@param buf integer
---@param hunk table
---@return integer|nil start_row
---@return integer|nil end_row
local function hunk_range(buf, hunk)
  if not hunk.mark_id then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns_track, hunk.mark_id, { details = true })
  if not pos or #pos == 0 then
    return nil
  end
  local start_row = pos[1]
  local details = pos[3] or {}
  local end_row = details.end_row or start_row
  local end_col = details.end_col or 0
  if end_col > 0 then
    end_row = end_row + 1
  end
  if end_row < start_row then
    end_row = start_row
  end
  return start_row, end_row
end
M._hunk_range = hunk_range

---@param buf integer
---@param hunks table[]
local function place_tracking_marks(buf, hunks)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, hunk in ipairs(hunks) do
    local start_row = math.min(hunk.new_start, line_count)
    hunk.at_eof = hunk.new_count == 0 and start_row >= line_count
    local opts = {
      right_gravity = false,
      strict = false,
    }
    if hunk.new_count > 0 then
      opts.end_row = start_row + hunk.new_count
      opts.end_col = 0
      opts.end_right_gravity = false
    end
    if hunk.at_eof then
      start_row = math.max(line_count - 1, 0)
      opts.right_gravity = true
    end
    hunk.mark_id = vim.api.nvim_buf_set_extmark(buf, ns_track, start_row, 0, opts)
    hunk.status = "pending"
  end
end

---@param text string
---@param width integer
---@return string
local function pad(text, width)
  local w = vim.fn.strdisplaywidth(text)
  if w >= width then
    return text
  end
  return text .. string.rep(" ", width - w)
end

---Redraw all decorations from the tracked hunks.
---@param buf integer
---@param state table
function M.render(buf, state)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_render, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local width = math.max(vim.o.columns, 20)

  for _, hunk in ipairs(state.hunks) do
    if hunk.status == "pending" then
      local start_row, end_row = hunk_range(buf, hunk)
      if start_row then
        for row = start_row, math.min(end_row, line_count) - 1 do
          vim.api.nvim_buf_set_extmark(buf, ns_render, row, 0, {
            line_hl_group = "ClaudeCodeInlineDiffAdd",
            sign_text = "+",
            sign_hl_group = "ClaudeCodeInlineDiffAddSign",
            priority = 200,
          })
        end

        if #hunk.old_lines > 0 then
          local virt = {}
          for _, old in ipairs(hunk.old_lines) do
            virt[#virt + 1] = { { pad(old, width), "ClaudeCodeInlineDiffDelete" } }
          end
          local anchor = math.min(start_row, math.max(line_count - 1, 0))
          local above = not (hunk.at_eof or start_row >= line_count)
          vim.api.nvim_buf_set_extmark(buf, ns_render, anchor, 0, {
            virt_lines = virt,
            virt_lines_above = above,
            sign_text = (end_row == start_row) and "-" or nil,
            sign_hl_group = (end_row == start_row) and "ClaudeCodeInlineDiffDeleteSign" or nil,
            priority = 200,
          })
        end
      end
    end
  end
end

---Pending hunks sorted by their current start row.
---@param buf integer
---@param state table
---@return table[] list of { hunk, start_row, end_row }
local function pending_hunks(buf, state)
  local out = {}
  for _, hunk in ipairs(state.hunks) do
    if hunk.status == "pending" then
      local s, e = hunk_range(buf, hunk)
      if s then
        out[#out + 1] = { hunk = hunk, start_row = s, end_row = e }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.start_row < b.start_row
  end)
  return out
end
M._pending_hunks = pending_hunks

---Find the pending hunk under (or nearest after) the given 0-based row.
---@param buf integer
---@param state table
---@param row integer
---@return table|nil entry { hunk, start_row, end_row }
function M.hunk_at_row(buf, state, row)
  local list = pending_hunks(buf, state)
  for _, entry in ipairs(list) do
    local last = math.max(entry.end_row - 1, entry.start_row)
    if row >= entry.start_row and row <= last then
      return entry
    end
  end
  for _, entry in ipairs(list) do
    if entry.start_row >= row then
      return entry
    end
  end
  return list[#list]
end

-- ── State lookup ──────────────────────────────────────────────────

---@param buf integer
---@return string|nil tab_name
---@return table|nil diff_data
local function state_for_buffer(buf)
  local diff = require("claudecode.diff")
  local tab_name = vim.b[buf] and vim.b[buf].claudecode_diff_tab_name
  if not tab_name then
    return nil, nil
  end
  local diff_data = diff._get_active_diffs()[tab_name]
  if not diff_data or diff_data.layout ~= "inline" or diff_data.status ~= "pending" then
    return nil, nil
  end
  return tab_name, diff_data
end

---When every hunk has been decided one by one, finish the whole diff.
---@param tab_name string
---@param diff_data table
local function maybe_finish(tab_name, diff_data)
  local any_pending, any_accepted = false, false
  for _, hunk in ipairs(diff_data.hunks) do
    if hunk.status == "pending" then
      any_pending = true
    elseif hunk.status == "accepted" then
      any_accepted = true
    end
  end
  if any_pending then
    return
  end
  local diff = require("claudecode.diff")
  if any_accepted then
    diff._resolve_diff_as_saved(tab_name, diff_data.new_buffer)
  else
    diff._resolve_diff_as_rejected(tab_name)
  end
end

-- ── Hunk actions (public) ─────────────────────────────────────────

---Accept the hunk under the cursor: keep its proposed lines, drop its deleted-line preview.
---@param buf integer|nil defaults to current buffer
---@return boolean acted
function M.accept_hunk(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local tab_name, diff_data = state_for_buffer(buf)
  if not diff_data then
    vim.notify("No inline Claude diff in this buffer", vim.log.levels.WARN)
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local entry = M.hunk_at_row(buf, diff_data, row)
  if not entry then
    return false
  end
  entry.hunk.status = "accepted"
  pcall(vim.api.nvim_buf_del_extmark, buf, ns_track, entry.hunk.mark_id)
  M.render(buf, diff_data)
  maybe_finish(tab_name, diff_data)
  return true
end

---Reject the hunk under the cursor: put the original lines back in place of the proposal.
---@param buf integer|nil defaults to current buffer
---@return boolean acted
function M.reject_hunk(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local tab_name, diff_data = state_for_buffer(buf)
  if not diff_data then
    vim.notify("No inline Claude diff in this buffer", vim.log.levels.WARN)
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local entry = M.hunk_at_row(buf, diff_data, row)
  if not entry then
    return false
  end
  local hunk = entry.hunk
  local start_row, end_row = entry.start_row, entry.end_row
  if hunk.at_eof then
    start_row = vim.api.nvim_buf_line_count(buf)
    end_row = start_row
  end
  pcall(vim.api.nvim_buf_del_extmark, buf, ns_track, hunk.mark_id)
  hunk.status = "rejected"
  diff_data.applying = true
  break_undo(buf)
  vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, hunk.old_lines)
  break_undo(buf)
  diff_data.applying = false
  M.render(buf, diff_data)
  maybe_finish(tab_name, diff_data)
  return true
end

---Move the cursor to a hunk and make sure its deleted-line preview is on screen.
---Virtual lines above the first buffer line are "filler" that Neovim only shows when
---the view's `topfill` asks for it, so a hunk at the top needs an explicit scroll.
---@param win integer
---@param buf integer
---@param entry table { hunk, start_row, end_row }
local function reveal(win, buf, entry)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local row = math.min(entry.start_row + 1, line_count)
  pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
  local n_old = #entry.hunk.old_lines
  if n_old > 0 and entry.start_row == 0 and not entry.hunk.at_eof then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 1, topfill = n_old })
    end)
  end
end
M._reveal = reveal

---Jump to the next (direction = 1) or previous (-1) pending hunk.
---@param direction integer
---@param buf integer|nil
---@return boolean moved
function M.jump(direction, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local _, diff_data = state_for_buffer(buf)
  if not diff_data then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local list = pending_hunks(buf, diff_data)
  if #list == 0 then
    return false
  end
  local target
  if direction > 0 then
    for _, e in ipairs(list) do
      if e.start_row > row then
        target = e
        break
      end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      if list[i].start_row < row then
        target = list[i]
        break
      end
    end
    target = target or list[#list]
  end
  reveal(vim.api.nvim_get_current_win(), buf, target)
  return true
end

-- ── Keymaps ───────────────────────────────────────────────────────

---@param buf integer
---@param user_maps table|nil
---@return table saved list of { lhs, previous_map_or_false }
local function set_keymaps(buf, user_maps)
  local maps = vim.tbl_extend("force", M.default_keymaps, user_maps or {})
  local actions = {
    next_hunk = function()
      M.jump(1, buf)
    end,
    prev_hunk = function()
      M.jump(-1, buf)
    end,
    accept_hunk = function()
      M.accept_hunk(buf)
    end,
    reject_hunk = function()
      M.reject_hunk(buf)
    end,
  }
  local descs = {
    next_hunk = "Claude: next proposed change",
    prev_hunk = "Claude: previous proposed change",
    accept_hunk = "Claude: accept this change",
    reject_hunk = "Claude: reject this change",
  }
  local saved = {}
  for name, lhs in pairs(maps) do
    if lhs and actions[name] then
      local previous = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true)
      end)
      if type(previous) == "table" and previous.buffer == 1 then
        saved[#saved + 1] = { lhs = lhs, previous = previous }
      else
        saved[#saved + 1] = { lhs = lhs, previous = false }
      end
      vim.keymap.set("n", lhs, actions[name], { buffer = buf, desc = descs[name], nowait = true })
    end
  end
  return saved
end

---@param buf integer
---@param saved table|nil
local function restore_keymaps(buf, saved)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, item in ipairs(saved or {}) do
    pcall(vim.keymap.del, "n", item.lhs, { buffer = buf })
    if item.previous then
      pcall(vim.api.nvim_buf_call, buf, function()
        vim.fn.mapset("n", false, item.previous)
      end)
    end
  end
end

-- ── Buffer / window selection ─────────────────────────────────────

---@param path string
---@return integer|nil
local function find_loaded_buffer(path)
  local target = vim.fn.fnamemodify(path, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == target then
        return b
      end
    end
  end
  return nil
end

---@param buf integer
---@return integer|nil
local function window_showing(buf)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
  return nil
end

-- ── Undo guard ────────────────────────────────────────────────────

---Keep undo from walking past Claude's proposal.
---
---The proposal is applied as one change to the real buffer, so a plain `u` would
---silently swap back to the original text while the review (and its markers) stays
---open. When undo reaches below the proposal, re-apply it, reset every hunk to
---pending, and point the user at reject instead.
---@param buf integer
---@param diff_data table
---@return boolean restored true if the proposal was re-applied
function M.guard_undo(buf, diff_data)
  if not diff_data.base_seq then
    return false
  end
  local seq = vim.api.nvim_buf_call(buf, function()
    return vim.fn.undotree().seq_cur
  end)
  if seq >= diff_data.base_seq then
    return false
  end
  diff_data.applying = true
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent undo " .. diff_data.base_seq)
  end)
  diff_data.applying = false
  vim.api.nvim_buf_clear_namespace(buf, ns_track, 0, -1)
  place_tracking_marks(buf, diff_data.hunks)
  -- Deferred + redraw so the hint replaces undo's own message instead of stacking
  -- with it (which would raise a hit-enter prompt).
  vim.schedule(function()
    vim.cmd("redraw")
    vim.notify("Undo stops at Claude's proposal; reject it with :ClaudeCodeDiffDeny", vim.log.levels.INFO)
  end)
  return true
end

-- ── Setup ─────────────────────────────────────────────────────────

---Open an in-place inline diff.
---@param params table { old_file_path, new_file_path, new_file_contents, tab_name, client_id }
---@param resolution_callback function
---@param config table
function M.setup_inplace_diff(params, resolution_callback, config)
  local diff = require("claudecode.diff")
  if not get_diff_fn() then
    error({
      code = -32000,
      message = "Inline diff requires Neovim >= 0.9.0",
      data = "vim.text.diff()/vim.diff() is not available. Use layout = 'vertical' or upgrade Neovim.",
    })
  end
  setup_highlights()

  local tab_name = params.tab_name
  local path = params.old_file_path
  local is_new_file = vim.fn.filereadable(path) ~= 1

  -- Buffer: reuse the user's buffer for this file, or load one.
  local buf = find_loaded_buffer(path)
  local buffer_created = false
  if not buf then
    buf = vim.fn.bufadd(path)
    buffer_created = true
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  vim.bo[buf].buflisted = true

  if vim.bo[buf].modified then
    error({
      code = -32000,
      message = "Cannot create diff: file has unsaved changes",
      data = "Please save (:w) or discard (:e!) changes to " .. path .. " before creating diff",
    })
  end

  local original_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local old_text = is_new_file and "" or M.join_content(original_lines, nil)
  if #original_lines == 1 and original_lines[1] == "" then
    old_text = ""
  end

  -- Window: one already showing the buffer, else the main editor window, else a new split.
  local win = window_showing(buf)
  local fallback_window = nil
  if not win then
    win = diff._find_main_editor_window()
    if not win then
      vim.cmd("rightbelow vsplit")
      win = vim.api.nvim_get_current_win()
      fallback_window = win
    end
  end
  local previous_win_buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)

  -- Show the sign column in every window on this buffer, remembering each
  -- window's own setting so cleanup can put it back.
  local signcolumns = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      signcolumns[w] = vim.wo[w].signcolumn
      pcall(vim.api.nvim_set_option_value, "signcolumn", "yes", { win = w })
    end
  end

  -- Apply the proposal to the real buffer.
  local new_lines = M.split_lines(params.new_file_contents)
  local hunks = M.compute_hunks(old_text, params.new_file_contents)
  local state = { hunks = hunks, applying = true }
  break_undo(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  break_undo(buf)
  state.applying = false
  -- Undo sequence number of the applied proposal: undo must not go below it (see TextChanged).
  local base_seq = vim.api.nvim_buf_call(buf, function()
    return vim.fn.undotree().seq_cur
  end)
  place_tracking_marks(buf, hunks)
  M.render(buf, state)

  vim.b[buf].claudecode_diff_tab_name = tab_name
  vim.b[buf].claudecode_inline_diff = true

  -- Jump to the first change.
  local first = pending_hunks(buf, state)[1]
  if first then
    reveal(win, buf, first)
  end

  local keymaps = set_keymaps(buf, config and config.diff_opts and config.diff_opts.inline_keymaps)

  local aug = diff._get_autocmd_group()
  local autocmd_ids = {}
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = aug,
    buffer = buf,
    callback = function()
      diff._resolve_diff_as_saved(tab_name, buf)
      return true -- Claude writes the file; we only report the reviewed content
    end,
  })
  for _, ev in ipairs({ "BufDelete", "BufUnload", "BufWipeout" }) do
    autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd(ev, {
      group = aug,
      buffer = buf,
      callback = function()
        diff._resolve_diff_as_rejected(tab_name)
      end,
    })
  end
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = aug,
    buffer = buf,
    callback = function()
      local data = diff._get_active_diffs()[tab_name]
      if not (data and data.status == "pending" and not data.applying) then
        return
      end
      M.guard_undo(buf, data)
      M.render(buf, data)
    end,
  })

  if config and config.diff_opts and config.diff_opts.keep_terminal_focus then
    vim.schedule(function()
      local terminal_win = diff._find_claudecode_terminal_window()
      if terminal_win then
        vim.api.nvim_set_current_win(terminal_win)
        vim.cmd("startinsert")
      end
    end)
  else
    pcall(vim.api.nvim_set_current_win, win)
  end

  diff._register_diff_state(tab_name, {
    layout = "inline",
    old_file_path = path,
    new_file_path = params.new_file_path,
    new_file_contents = params.new_file_contents,
    new_buffer = buf, -- the real file buffer, reviewed in place
    new_window = win,
    target_window = win,
    fallback_window = fallback_window,
    previous_win_buf = previous_win_buf,
    buffer_created = buffer_created,
    original_lines = original_lines,
    hunks = hunks,
    applying = false,
    base_seq = base_seq,
    signcolumns = signcolumns,
    keymaps = keymaps,
    is_new_file = is_new_file,
    autocmd_ids = autocmd_ids,
    created_at = vim.fn.localtime(),
    status = "pending",
    resolution_callback = resolution_callback,
    result_content = nil,
    client_id = params.client_id,
    created_new_tab = false,
  })

  logger.debug("diff", "Opened in-place inline diff for", path, "with", #hunks, "hunk(s)")
end

-- ── Resolution ────────────────────────────────────────────────────

---Remove review UI (decorations, keymaps, buffer vars) but keep the buffer's text.
---@param diff_data table
local function clear_review_ui(diff_data)
  local buf = diff_data.new_buffer
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_render, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_track, 0, -1)
  restore_keymaps(buf, diff_data.keymaps)
  diff_data.keymaps = nil
  pcall(function()
    vim.b[buf].claudecode_inline_diff = nil
  end)
end

---Accept: send the buffer's current content (including edits made while reviewing).
---@param tab_name string
---@param diff_data table
function M.resolve_as_saved(tab_name, diff_data)
  local buf = diff_data.new_buffer
  local content
  if buf and vim.api.nvim_buf_is_valid(buf) then
    content = M.join_content(vim.api.nvim_buf_get_lines(buf, 0, -1, false), diff_data.new_file_contents)
  else
    content = diff_data.new_file_contents
  end
  diff_data.accepted_content = content
  clear_review_ui(diff_data)

  local result = {
    content = {
      { type = "text", text = "FILE_SAVED" },
      { type = "text", text = content },
    },
  }
  diff_data.status = "saved"
  diff_data.result_content = result
  if diff_data.resolution_callback then
    diff_data.resolution_callback(result)
  end
  logger.debug("diff", "Inline diff accepted for", tab_name)
end

---Reject: put the original text back.
---@param tab_name string
---@param diff_data table
function M.resolve_as_rejected(tab_name, diff_data)
  local buf = diff_data.new_buffer
  clear_review_ui(diff_data)
  if buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
    diff_data.applying = true
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, diff_data.original_lines or {})
    diff_data.applying = false
    pcall(function()
      vim.bo[buf].modified = false
    end)
  end

  local result = {
    content = {
      { type = "text", text = "DIFF_REJECTED" },
      { type = "text", text = tab_name },
    },
  }
  diff_data.status = "rejected"
  diff_data.result_content = result
  if diff_data.resolution_callback then
    diff_data.resolution_callback(result)
  end
  logger.debug("diff", "Inline diff rejected for", tab_name)
end

---Tear down all state. After an accept, the buffer holds exactly what Claude writes,
---so it is marked unmodified and the normal post-save reload picks up the file.
---@param tab_name string
---@param diff_data table
function M.cleanup(tab_name, diff_data)
  for _, id in ipairs(diff_data.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  diff_data.autocmd_ids = {}

  if diff_data.status == "pending" then
    -- Closed without a decision (e.g. Claude disconnected): restore like a reject.
    M.resolve_as_rejected(tab_name, diff_data)
  end
  clear_review_ui(diff_data)

  local buf = diff_data.new_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(function()
      vim.b[buf].claudecode_diff_tab_name = nil
    end)
    if diff_data.status == "saved" then
      pcall(function()
        vim.bo[buf].modified = false
      end)
    elseif diff_data.status == "rejected" and diff_data.is_new_file and diff_data.buffer_created then
      -- A new file that was never written: drop the placeholder buffer.
      local win = diff_data.new_window
      if
        win
        and vim.api.nvim_win_is_valid(win)
        and diff_data.previous_win_buf
        and diff_data.previous_win_buf ~= buf
        and vim.api.nvim_buf_is_valid(diff_data.previous_win_buf)
      then
        pcall(vim.api.nvim_win_set_buf, win, diff_data.previous_win_buf)
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  for w, value in pairs(diff_data.signcolumns or {}) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_set_option_value, "signcolumn", value, { win = w })
    end
  end
  diff_data.signcolumns = nil

  if diff_data.fallback_window and vim.api.nvim_win_is_valid(diff_data.fallback_window) then
    if diff_data.status == "rejected" then
      pcall(vim.api.nvim_win_close, diff_data.fallback_window, false)
    end
  end
  logger.debug("diff", "Cleaned up inline diff for", tab_name)
end

return M
