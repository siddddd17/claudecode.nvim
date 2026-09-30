-- luacheck: ignore 311
-- Scenario suite for diff_opts.layout = "inline", covering the situations a real
-- LazyVim + Claude Code session runs into that the basic e2e script does not.
--
-- Claude's side is simulated through the same entry points the real protocol uses:
--   openDiff   -> diff._setup_blocking_diff(params, callback)
--   close_tab  -> diff.close_diff_by_tab_name(tab)
--   disconnect -> diff.close_diffs_for_client(client_id)   (Ctrl+C / closing Claude)
-- and "Claude writes the file after FILE_SAVED" is done by writing the accepted text to disk.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l tests/manual/inline_diff_scenarios.lua
-- Exit code is 0 when every check passes.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.columns = 120
vim.o.swapfile = false
vim.g.mapleader = " "

local diff = require("claudecode.diff")
local inplace = require("claudecode.diff_inplace")
diff.setup({ diff_opts = { layout = "inline" }, terminal = {} })

-- ── tiny harness ──────────────────────────────────────────────────
local results = {}
local current
local function scenario(name, fn)
  current = { name = name, passed = 0, failed = {} }
  results[#results + 1] = current
  local ok, err = xpcall(fn, function(e)
    return (type(e) == "table" and vim.inspect(e) or tostring(e)) .. "\n" .. debug.traceback()
  end)
  if not ok then
    table.insert(current.failed, "crashed: " .. err)
  end
  -- Leave nothing behind for the next scenario.
  pcall(diff._cleanup_all_active_diffs, "scenario teardown")
  pcall(vim.cmd, "silent! only")
  pcall(vim.cmd, "silent! %bwipeout!")
end
local function check(cond, msg)
  if cond then
    current.passed = current.passed + 1
  else
    table.insert(current.failed, msg)
  end
end

-- ── helpers ───────────────────────────────────────────────────────
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  return t
end
local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end
local function marks(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, inplace.ns_render, 0, -1, {})
end
local function propose(path, new_text, tab, client_id)
  local box = {}
  diff._setup_blocking_diff({
    old_file_path = path,
    new_file_path = path,
    new_file_contents = new_text,
    tab_name = tab,
    client_id = client_id,
  }, function(r)
    box.result = r
  end)
  return box
end
-- What Claude Code does after the user accepts: write the file, then close_tab.
local function claude_finishes(path, box, tab)
  if box.result and box.result.content[1].text == "FILE_SAVED" then
    write(path, box.result.content[2].text)
  end
  diff.close_diff_by_tab_name(tab)
  vim.wait(250) -- the plugin reloads saved buffers after a short delay
end
local function user_types_undo(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent undo")
  end)
  -- In a live session TextChanged fires when control returns to the user; do it explicitly.
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
end

-- ── 1. Format-on-save ─────────────────────────────────────────────
scenario("1. format-on-save (LazyVim/conform style) around an accept", function()
  local path = root .. "/messy.lua"
  local ORIGINAL = "local x=1\nreturn x\n"
  local PROPOSED = "local   x  =  1\nlocal y=2\nreturn x+y\n"
  write(path, ORIGINAL)

  -- A formatter on BufWritePre that collapses repeated spaces, like conform/stylua would.
  local formatter_runs = 0
  local fmt_id = vim.api.nvim_create_autocmd("BufWritePre", {
    pattern = "*.lua",
    callback = function(args)
      formatter_runs = formatter_runs + 1
      local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
      for i, l in ipairs(lines) do
        lines[i] = l:gsub("  +", " ")
      end
      vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, lines)
    end,
  })

  vim.cmd("edit " .. path)
  local buf = vim.api.nvim_get_current_buf()
  local box = propose(path, PROPOSED, "fmt")
  vim.cmd("write") -- the user accepts with :w
  check(box.result and box.result.content[1].text == "FILE_SAVED", ":w accepts the diff")
  check(formatter_runs == 0, "formatter does NOT run on the accepting :w (got " .. formatter_runs .. " runs)")
  check(
    box.result and box.result.content[2].text == PROPOSED,
    "Claude receives exactly the reviewed text, not a reformatted copy"
  )
  check(read(path) == ORIGINAL, "nothing is written to disk by the plugin itself")

  claude_finishes(path, box, "fmt")
  check(read(path) == PROPOSED, "disk holds exactly what was reviewed after Claude writes")
  check(not vim.bo[buf].modified, "buffer is clean after Claude's write")
  check(text(buf) == PROPOSED, "buffer shows the written file")

  -- After review, :w is a normal save again and the formatter runs.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- touched" })
  vim.cmd("write")
  check(formatter_runs == 1, "formatter runs again on the next normal :w")
  check(read(path) == "-- touched\nlocal x = 1\nlocal y=2\nreturn x+y\n", "normal :w writes formatted text to disk")
  vim.api.nvim_del_autocmd(fmt_id)
end)

-- ── 2. Two files at once ──────────────────────────────────────────
scenario("2. two files under review at the same time", function()
  local a, b = root .. "/notes.md", root .. "/CHANGELOG.md"
  write(a, "# Notes\nWidget is great.\n")
  write(b, "# Changelog\n- Added Widget\n")
  vim.cmd("edit " .. a)
  local abuf = vim.api.nvim_get_current_buf()
  vim.cmd("vsplit " .. b)
  local bbuf = vim.api.nvim_get_current_buf()

  local box_a = propose(a, "# Notes\nGadget is great.\n", "A")
  local box_b = propose(b, "# Changelog\n- Added Gadget\n", "B")
  check(text(abuf) == "# Notes\nGadget is great.\n", "file A shows its proposal")
  check(text(bbuf) == "# Changelog\n- Added Gadget\n", "file B shows its proposal")
  check(marks(abuf) > 0 and marks(bbuf) > 0, "both files have review markers")

  -- Accept A only.
  vim.api.nvim_set_current_buf(abuf)
  vim.cmd("write")
  check(box_a.result and box_a.result.content[1].text == "FILE_SAVED", "A accepted")
  check(box_b.result == nil, "deciding A does not resolve B")
  check(marks(bbuf) > 0, "B keeps its markers after A is accepted")
  check(text(bbuf) == "# Changelog\n- Added Gadget\n", "B's proposal untouched")
  claude_finishes(a, box_a, "A")

  -- Reject B.
  vim.api.nvim_set_current_buf(bbuf)
  diff.deny_current_diff()
  check(box_b.result and box_b.result.content[1].text == "DIFF_REJECTED", "B rejected")
  claude_finishes(b, box_b, "B")
  check(read(a) == "# Notes\nGadget is great.\n", "A's change reached disk")
  check(read(b) == "# Changelog\n- Added Widget\n", "B's file on disk unchanged")
  check(text(bbuf) == "# Changelog\n- Added Widget\n", "B's buffer back to original")
  check(text(abuf) == "# Notes\nGadget is great.\n", "A's buffer keeps accepted text")
  check(next(diff._get_active_diffs()) == nil, "no diffs left open")
end)

-- ── 3. Undo during review ─────────────────────────────────────────
scenario("3. undo during review", function()
  local path = root .. "/undo.txt"
  local ORIGINAL = "alpha\nbeta\ngamma\n"
  local PROPOSED = "alpha\nBETA\ngamma\ndelta\n"
  write(path, ORIGINAL)
  vim.cmd("edit " .. path)
  local buf = vim.api.nvim_get_current_buf()
  local box = propose(path, PROPOSED, "U")

  -- 3a. User edits, then undoes their own edit: normal undo, review intact.
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "ALPHA" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  user_types_undo(buf)
  check(text(buf) == PROPOSED, "undoing your own edit returns to Claude's proposal")
  check(marks(buf) > 0, "markers still shown after undoing your own edit")

  -- 3b. One more undo would erase the proposal itself: it must be blocked.
  user_types_undo(buf)
  check(text(buf) == PROPOSED, "undo cannot erase Claude's proposal while under review")
  check(box.result == nil, "review stays open after the blocked undo")
  local pending = inplace._pending_hunks(buf, diff._get_active_diffs()["U"])
  check(#pending == 2, "both hunks are pending and correctly placed after the blocked undo (got " .. #pending .. ")")
  if pending[1] then
    check(pending[1].start_row == 1 and pending[1].end_row == 2, "first hunk still covers line 2")
  end

  -- 3c. Undoing a hunk rejection keeps content consistent with what is accepted.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  inplace.reject_hunk()
  check(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "beta", "rejecting hunk 1 restores 'beta'")
  user_types_undo(buf)
  check(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "BETA", "undo of the reject brings back 'BETA'")

  -- Accept: whatever is in the buffer is what Claude gets.
  local expected = text(buf)
  vim.cmd("write")
  check(box.result and box.result.content[2].text == expected, "accepted text equals what the buffer showed")
  claude_finishes(path, box, "U")
  check(read(path) == expected, "disk matches the reviewed buffer")
  check(marks(buf) == 0, "no leftover markers after close")
end)

-- ── 4. Claude stopped mid-review ──────────────────────────────────
scenario("4. Claude stopped mid-review (Ctrl+C / closing Claude)", function()
  local path = root .. "/stopped.py"
  local ORIGINAL = "def f():\n    return 1\n"
  write(path, ORIGINAL)
  vim.cmd("edit " .. path)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local signcolumn_before = vim.wo[win].signcolumn
  local box = propose(path, "def f():\n    return 2\n\n\ndef g():\n    pass\n", "S", "client-1")
  check(marks(buf) > 0, "review is showing")
  check(vim.fn.maparg("]c", "n") ~= "", "review keys active")

  -- Claude's connection drops: this is what the server does on disconnect.
  diff.close_diffs_for_client("client-1", "client disconnected")
  check(box.result and box.result.content[1].text == "DIFF_REJECTED", "pending diff is resolved as rejected")
  check(text(buf) == ORIGINAL, "file text goes back to the original")
  check(not vim.bo[buf].modified, "buffer is left unmodified")
  check(read(path) == ORIGINAL, "file on disk untouched")
  check(marks(buf) == 0, "no leftover colors")
  check(#vim.api.nvim_buf_get_extmarks(buf, inplace.ns_track, 0, -1, {}) == 0, "no leftover tracking marks")
  check(vim.fn.maparg("]c", "n") == "", "review keys removed")
  check(vim.b[buf].claudecode_diff_tab_name == nil, "buffer no longer tagged as under review")
  check(vim.wo[win].signcolumn == signcolumn_before, "window's sign column setting restored")
  check(next(diff._get_active_diffs()) == nil, "diff registry empty")

  -- A second client's diff is not touched by the first client disconnecting.
  local other = root .. "/other.py"
  write(other, "x = 1\n")
  vim.cmd("edit " .. other)
  local obuf = vim.api.nvim_get_current_buf()
  local obox = propose(other, "x = 2\n", "O", "client-2")
  diff.close_diffs_for_client("client-1", "client disconnected")
  check(obox.result == nil and marks(obuf) > 0, "another client's review survives")
  diff.close_diffs_for_client("client-2", "client disconnected")
  check(text(obuf) == "x = 1\n", "second client's file restored on its own disconnect")
end)

-- ── 5. Same file in two splits ────────────────────────────────────
scenario("5. same file open in two splits", function()
  local path = root .. "/split.js"
  local ORIGINAL = "const a = 1;\nconst b = 2;\n"
  local PROPOSED = "const a = 1;\nconst b = 3;\nconst c = 4;\n"
  write(path, ORIGINAL)
  vim.cmd("edit " .. path)
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("vsplit")
  local wins = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      wins[#wins + 1] = w
    end
  end
  check(#wins == 2, "setup: two windows on the file")
  local before = {}
  for _, w in ipairs(wins) do
    before[w] = vim.wo[w].signcolumn
  end
  local win_count = #vim.api.nvim_tabpage_list_wins(0)

  local box = propose(path, PROPOSED, "V")
  check(#vim.api.nvim_tabpage_list_wins(0) == win_count, "no extra window opened")
  for i, w in ipairs(wins) do
    check(vim.api.nvim_win_get_buf(w) == buf, "window " .. i .. " still shows the file")
    check(vim.wo[w].signcolumn == "yes", "window " .. i .. " shows the +/- sign column")
  end
  check(text(buf) == PROPOSED, "both windows show the proposal (same buffer)")
  check(marks(buf) > 0, "markers present (drawn per buffer, so in both windows)")

  -- Edit through one window, accept from the other.
  vim.api.nvim_set_current_win(wins[1])
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "const c = 5;" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  vim.api.nvim_set_current_win(wins[2])
  vim.cmd("write")
  local expected = "const a = 1;\nconst b = 3;\nconst c = 5;\n"
  check(box.result and box.result.content[2].text == expected, "edit made in window 1 is in the accepted text")
  claude_finishes(path, box, "V")
  check(read(path) == expected, "disk matches")
  for i, w in ipairs(wins) do
    check(vim.wo[w].signcolumn == before[w], "window " .. i .. " sign column restored")
  end
end)

-- ── report ────────────────────────────────────────────────────────
local total_pass, total_fail = 0, 0
print("")
for _, r in ipairs(results) do
  total_pass = total_pass + r.passed
  total_fail = total_fail + #r.failed
  print(
    string.format("%s %s  (%d passed, %d failed)", #r.failed == 0 and "PASS" or "FAIL", r.name, r.passed, #r.failed)
  )
  for _, f in ipairs(r.failed) do
    print("     - " .. f)
  end
end
print(string.format("\ninline diff scenarios: %d passed, %d failed", total_pass, total_fail))
vim.cmd(total_fail == 0 and "qa!" or "cq!")
