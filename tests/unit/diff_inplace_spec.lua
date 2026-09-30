-- luacheck: globals expect
require("tests.busted_setup")

describe("In-place inline diff (layout = 'inline')", function()
  local inplace

  before_each(function()
    package.loaded["claudecode.diff_inplace"] = nil
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
    inplace = require("claudecode.diff_inplace")
  end)

  describe("split_lines", function()
    it("returns no lines for empty or nil text", function()
      assert.are.same({}, inplace.split_lines(""))
      assert.are.same({}, inplace.split_lines(nil))
    end)

    it("drops the empty entry from a trailing newline", function()
      assert.are.same({ "a", "b" }, inplace.split_lines("a\nb\n"))
      assert.are.same({ "a", "b" }, inplace.split_lines("a\nb"))
    end)
  end)

  describe("join_content", function()
    it("adds a trailing newline when the reference has one", function()
      assert.are.equal("a\nb\n", inplace.join_content({ "a", "b" }, "x\n"))
    end)

    it("omits the trailing newline when the reference has none", function()
      assert.are.equal("a\nb", inplace.join_content({ "a", "b" }, "x"))
    end)

    it("defaults to a trailing newline without a reference", function()
      assert.are.equal("a\n", inplace.join_content({ "a" }, nil))
    end)

    it("keeps empty content empty", function()
      assert.are.equal("", inplace.join_content({}, "x\n"))
    end)
  end)

  describe("compute_hunks", function()
    it("returns no hunks for identical text", function()
      assert.are.same({}, inplace.compute_hunks("a\nb\n", "a\nb\n"))
    end)

    it("positions a replacement at its row in the new text", function()
      local hunks = inplace.compute_hunks("a\nb\nc\n", "a\nB\nc\n")
      assert.are.equal(1, #hunks)
      assert.are.equal(1, hunks[1].new_start)
      assert.are.equal(1, hunks[1].new_count)
      assert.are.same({ "b" }, hunks[1].old_lines)
    end)

    it("represents a pure insertion with no old lines", function()
      local hunks = inplace.compute_hunks("a\nc\n", "a\nb\nc\n")
      assert.are.equal(1, #hunks)
      assert.are.equal(1, hunks[1].new_start)
      assert.are.equal(1, hunks[1].new_count)
      assert.are.same({}, hunks[1].old_lines)
    end)

    it("anchors a pure deletion before the row that follows it", function()
      local hunks = inplace.compute_hunks("a\nb\nc\n", "a\nc\n")
      assert.are.equal(1, #hunks)
      assert.are.equal(0, hunks[1].new_count)
      assert.are.equal(1, hunks[1].new_start)
      assert.are.same({ "b" }, hunks[1].old_lines)
    end)

    it("anchors a deletion at the start of the file at row 0", function()
      local hunks = inplace.compute_hunks("a\nb\nc\n", "c\n")
      assert.are.equal(1, #hunks)
      assert.are.equal(0, hunks[1].new_start)
      assert.are.same({ "a", "b" }, hunks[1].old_lines)
    end)

    it("anchors a deletion at the end of the file past the last row", function()
      local hunks = inplace.compute_hunks("a\nb\nc\n", "a\n")
      assert.are.equal(1, #hunks)
      assert.are.equal(1, hunks[1].new_start)
      assert.are.same({ "b", "c" }, hunks[1].old_lines)
    end)

    it("treats a new file as one hunk of added lines", function()
      local hunks = inplace.compute_hunks("", "x\ny\n")
      assert.are.equal(1, #hunks)
      assert.are.equal(0, hunks[1].new_start)
      assert.are.equal(2, hunks[1].new_count)
      assert.are.same({}, hunks[1].old_lines)
    end)

    it("reports several independent hunks in order", function()
      local hunks = inplace.compute_hunks("1\n2\n3\n4\n5\n", "1\nTWO\n3\n4\nFIVE\nSIX\n")
      assert.are.equal(2, #hunks)
      assert.are.same({ "2" }, hunks[1].old_lines)
      assert.are.same({ "5" }, hunks[2].old_lines)
      assert.are.equal(4, hunks[2].new_start)
      assert.are.equal(2, hunks[2].new_count)
    end)
  end)

  describe("config", function()
    local config

    before_each(function()
      package.loaded["claudecode.config"] = nil
      package.loaded["claudecode.terminal"] = nil
      config = require("claudecode.config")
    end)

    local function with_diff_opts(extra)
      local c = vim.deepcopy(config.defaults)
      for k, v in pairs(extra) do
        c.diff_opts[k] = v
      end
      return c
    end

    it("accepts layout = 'inline'", function()
      local ok = pcall(config.validate, with_diff_opts({ layout = "inline" }))
      expect(ok).to_be_true()
    end)

    it("accepts inline_keymaps with strings and false", function()
      local ok = pcall(
        config.validate,
        with_diff_opts({ layout = "inline", inline_keymaps = { next_hunk = "]h", accept_hunk = false } })
      )
      expect(ok).to_be_true()
    end)

    it("rejects unknown inline_keymaps entries", function()
      local ok = pcall(config.validate, with_diff_opts({ inline_keymaps = { explode = "x" } }))
      expect(ok).to_be_false()
    end)

    it("rejects non-string inline_keymaps values", function()
      local ok = pcall(config.validate, with_diff_opts({ inline_keymaps = { next_hunk = 42 } }))
      expect(ok).to_be_false()
    end)
  end)
end)
