-- luacheck: ignore 311
-- End-to-end check of diff_opts.layout = "inline" in a real (headless) Neovim.
-- Run: nvim --headless -u NONE -l tests/manual/inline_diff_e2e.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = " "

local diff = require("claudecode.diff")
local inplace = require("claudecode.diff_inplace")
diff.setup({ diff_opts = { layout = "inline" }, terminal = {} })

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then
    passes = passes + 1
  else
    failures = failures + 1
    print("FAIL: " .. msg)
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
local function open(path, new_text, tab)
  local result
  diff._setup_blocking_diff({
    old_file_path = path,
    new_file_path = path,
    new_file_contents = new_text,
    tab_name = tab,
  }, function(r)
    result = r
  end)
  return function()
    return result
  end
end
local function virt_line_count(buf)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, inplace.ns_render, 0, -1, { details = true })) do
    n = n + #(m[4].virt_lines or {})
  end
  return n
end

local ORIGINAL = "local a = 1\nlocal b = 2\nlocal c = 3\nreturn a + b\n"
local PROPOSED = "local a = 1\nlocal b = 20\nlocal c = 3\nlocal d = 4\nreturn a + b + d\n"

-- 1. Opening: proposal lands in the file's own buffer, no extra window, no diff mode.
local path = tmp .. "/sample.lua"
write(path, ORIGINAL)
vim.cmd("silent edit " .. path)
local buf = vim.api.nvim_get_current_buf()
local wins_before = #vim.api.nvim_tabpage_list_wins(0)
local result = open(path, PROPOSED, "t1")
check(vim.api.nvim_get_current_buf() == buf, "reviews in the user's own buffer")
check(#vim.api.nvim_tabpage_list_wins(0) == wins_before, "opens no extra window")
check(not vim.wo.diff, "window is not put in diff mode")
check(table.concat(lines(buf), "\n") .. "\n" == PROPOSED, "buffer shows the proposal as real lines")
local state = diff._get_active_diffs()["t1"]
check(state and state.layout == "inline", "state registered with layout=inline")
check(#state.hunks == 2, "two hunks detected (got " .. (state and #state.hunks or -1) .. ")")
check(virt_line_count(buf) == 2, "deleted lines shown as virtual text (got " .. virt_line_count(buf) .. ")")
check(vim.fn.maparg("]c", "n") ~= "", "]c mapped while reviewing")

-- 2. Edit during review, reject hunk 1, accept via :w — edits must be kept.
vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "local d = 42 -- tweaked" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check(inplace.jump(1), "jump to next hunk")
check(vim.api.nvim_win_get_cursor(0)[1] == 2, "cursor on first hunk (line 2)")
check(inplace.reject_hunk(), "reject first hunk")
check(lines(buf)[2] == "local b = 2", "rejected hunk restores original line")
check(diff._get_active_diffs()["t1"].status == "pending", "diff still pending with a hunk left")
vim.cmd("silent write")
local r = result()
check(r and r.content[1].text == "FILE_SAVED", ":w accepts the diff")
local expected = "local a = 1\nlocal b = 2\nlocal c = 3\nlocal d = 42 -- tweaked\nreturn a + b + d\n"
check(r and r.content[2].text == expected, "accepted content keeps review edits + hunk decisions")
check(virt_line_count(buf) == 0, "decorations cleared after accept")
check(vim.fn.maparg("]c", "n") == "", "review keymaps removed after accept")
-- Simulate Claude writing the file, then close_tab.
write(path, r.content[2].text)
diff.close_diff_by_tab_name("t1")
check(diff._get_active_diffs()["t1"] == nil, "state cleaned up after close_tab")
check(not vim.bo[buf].modified, "buffer left unmodified so the post-save reload applies")
vim.wait(300)
check(table.concat(lines(buf), "\n") .. "\n" == expected, "buffer matches file on disk after reload")
check(vim.b[buf].claudecode_diff_tab_name == nil, "buffer vars cleared")

-- 3. Reject whole diff restores the original text.
write(path, ORIGINAL)
vim.cmd("silent edit!")
result = open(path, PROPOSED, "t2")
diff.deny_current_diff()
r = result()
check(r and r.content[1].text == "DIFF_REJECTED", "deny rejects")
check(table.concat(lines(buf), "\n") .. "\n" == ORIGINAL, "reject restores original text")
check(not vim.bo[buf].modified, "buffer unmodified after reject")
diff.close_diff_by_tab_name("t2")

-- 4. Deciding every hunk individually finishes the diff.
result = open(path, PROPOSED, "t3")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
inplace.jump(1)
inplace.accept_hunk()
inplace.jump(1)
inplace.accept_hunk()
r = result()
check(r and r.content[1].text == "FILE_SAVED", "accepting all hunks auto-accepts the diff")
check(r and r.content[2].text == PROPOSED, "all-accepted content equals the proposal")
diff.close_diff_by_tab_name("t3")
write(path, ORIGINAL)
vim.cmd("silent edit!")

result = open(path, PROPOSED, "t4")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
inplace.jump(1)
inplace.reject_hunk()
inplace.jump(1)
inplace.reject_hunk()
r = result()
check(r and r.content[1].text == "DIFF_REJECTED", "rejecting all hunks auto-rejects the diff")
check(table.concat(lines(buf), "\n") .. "\n" == ORIGINAL, "all-rejected leaves original")
diff.close_diff_by_tab_name("t4")

-- 5. New file: accept creates content; reject drops the placeholder buffer.
local newpath = tmp .. "/brand_new.lua"
result = open(newpath, "print('hi')\nprint('there')\n", "t5")
local nbuf = vim.api.nvim_get_current_buf()
check(vim.api.nvim_buf_get_name(nbuf) == newpath, "new file opened in its own named buffer")
check(#lines(nbuf) == 2, "new file shows proposed lines")
diff.deny_current_diff()
diff.close_diff_by_tab_name("t5")
check(not vim.api.nvim_buf_is_valid(nbuf), "rejected new-file buffer is removed")
check(vim.fn.filereadable(newpath) == 0, "rejected new file never written")

result = open(newpath, "print('hi')\n", "t6")
nbuf = vim.api.nvim_get_current_buf()
diff.accept_current_diff()
r = result()
check(r and r.content[2].text == "print('hi')\n", "new file accept returns content")
diff.close_diff_by_tab_name("t6")

-- 6. Pure deletion at end of file and at start.
write(path, "one\ntwo\nthree\n")
vim.cmd("silent edit " .. path)
buf = vim.api.nvim_get_current_buf()
result = open(path, "one\n", "t7")
check(#lines(buf) == 1, "deletion at EOF applied")
check(virt_line_count(buf) == 2, "two deleted lines previewed at EOF (got " .. virt_line_count(buf) .. ")")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
inplace.reject_hunk()
check(table.concat(lines(buf), "\n") == "one\ntwo\nthree", "rejecting EOF deletion restores lines in order")
diff.close_diff_by_tab_name("t7")

write(path, "one\ntwo\nthree\n")
vim.cmd("silent edit!")
result = open(path, "three\n", "t8")
check(virt_line_count(buf) == 2, "deletion at start previewed")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
inplace.reject_hunk()
check(table.concat(lines(buf), "\n") == "one\ntwo\nthree", "rejecting start deletion restores lines in order")
diff.close_diff_by_tab_name("t8")

-- 7. Existing buffer-local mapping is restored after review.
write(path, ORIGINAL)
vim.cmd("silent edit!")
vim.keymap.set("n", "]c", "<cmd>echo 'gitsigns'<cr>", { buffer = buf })
local user_map = vim.fn.maparg("]c", "n")
result = open(path, PROPOSED, "t9")
check(vim.fn.maparg("]c", "n") ~= user_map, "review overrides ]c while active")
diff.deny_current_diff()
diff.close_diff_by_tab_name("t9")
check(vim.fn.maparg("]c", "n") == user_map, "user's buffer-local ]c restored")

-- 8. Wiping the buffer mid-review resolves as rejected.
result = open(path, PROPOSED, "t10")
vim.cmd("bwipeout!")
r = result()
check(r and r.content[1].text == "DIFF_REJECTED", "wiping the buffer rejects")
diff.close_diff_by_tab_name("t10")

print(string.format("inline diff e2e: %d passed, %d failed", passes, failures))
vim.cmd(failures == 0 and "qa!" or "cq!")
