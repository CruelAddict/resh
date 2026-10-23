-- Optional server-side sources. Load with dofile(...) in this host's Rex init.lua.
-- No resh executable, extra daemon, shell input, or GUI client is required.
local home = assert(os.getenv("HOME"), "resh: HOME is not set")
local config = (...) or os.getenv("RESH_TOOLS") or (os.getenv("XDG_CONFIG_HOME") or home .. "/.config") .. "/resh/tools.lua"
local tools = {}
local file = io.open(config, "r")
if file then
  file:close()
  tools = assert(assert(loadfile(config))())
  if type(tools) ~= "table" then error("resh: tools.lua must return a table", 0) end
else
  local exists = rex.exec({ "/bin/sh", "-c", 'test -e "$1" || test -L "$1"', "sh", config }, { timeout = 1 })
  if exists and exists.ok then error("resh: cannot read " .. config, 0) end
end
for name, path in pairs(tools) do
  if name ~= "zoxide" and name ~= "fd" and name ~= "git" then
    error("resh: unknown tool " .. tostring(name), 0)
  end
  if path ~= false then
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then
      error("resh: " .. name .. " must be an absolute executable path or false", 0)
    end
  end
end

local directories, seen = {}, {}
local search = (os.getenv("PATH") or "") .. ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
for directory in search:gmatch("[^:]+") do
  if directory:sub(1, 1) == "/" and not seen[directory] then
    directories[#directories + 1] = directory
    seen[directory] = true
  end
end
local available = {}
for _, name in ipairs({ "zoxide", "fd", "git" }) do
  local candidates = {}
  if tools[name] ~= nil then
    if tools[name] ~= false then candidates[1] = tools[name] end
  else
    for _, directory in ipairs(directories) do
      for _, executable in ipairs(name == "fd" and { "fd", "fdfind" } or { name }) do
        candidates[#candidates + 1] = directory .. "/" .. executable
      end
    end
  end
  for _, path in ipairs(candidates) do
    local check = true
    if path == "/usr/bin/git" then
      local xcode = io.open("/usr/bin/xcode-select", "r")
      if xcode then
        xcode:close()
        local selected = rex.exec({ "/usr/bin/xcode-select", "-p" }, { timeout = 1, stdout = false, stderr = false })
        check = selected and selected.ok -- Do not trigger Apple's CLT installation dialog.
      end
    end
    -- Only config loading probes executables; resh_info itself starts no processes.
    local result = check and rex.exec({ path, "--version" }, { timeout = 1, stdout = false, stderr = false })
    if result and result.ok then available[name] = path; break end
  end
end

local function run(argv, options)
  options = options or {}
  options.timeout = options.timeout or 3
  local result, err = rex.exec(argv, options)
  if not result then error(tostring(err), 0) end
  if not result.ok then
    error(result.timed_out and "Source timed out" or result.stderr, 0)
  end
  return result.stdout
end

local function lines(text)
  if #text > 2097152 then error("Source exceeded 2 MiB", 0) end
  local results, seen = {}, {}
  for path in text:gmatch("[^\n]+") do
    if path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then
      error("Source returned an invalid absolute path", 0)
    end
    if not seen[path] then
      seen[path] = true
      results[#results + 1] = path
      if #results > 20000 then error("Source exceeded 20,000 results", 0) end
    end
  end
  -- Rex encodes an empty Lua table as an object. An omitted results array is empty.
  return #results > 0 and { results = results } or {}
end

rex.action{
  name = "resh_info",
  title = "resh: source capabilities",
  args = { type = "object", additionalProperties = false },
  run = function()
    local functions = { "resolve" }
    if available.zoxide then functions[#functions + 1] = "zoxide" end
    if available.fd then functions[#functions + 1] = "find" end
    return { version = 1, functions = functions }
  end,
}

rex.action{
  name = "resh_query",
  title = "resh: query source",
  args = { type = "object", properties = {
    fn = { type = "string", enum = { "zoxide", "find", "resolve" } },
    path = { type = "string" },
  }, required = { "fn" }, additionalProperties = false },
  run = function(_, args)
    if args.fn == "zoxide" then
      if not available.zoxide then error("zoxide is unavailable; update tools.lua and reload the Rex config", 0) end
      return lines(run({ available.zoxide, "query", "-l" }))
    elseif args.fn == "find" then
      if not available.fd then error("fd is unavailable; update tools.lua and reload the Rex config", 0) end
      return lines(run({ available.fd, "-H", "-d", "2", "-t", "d", "-E", ".Trash", ".", home }))
    end
    local path = args.path
    if not path or path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then
      error("resolve requires an absolute directory path", 0)
    end
    -- cwd is passed as an argument to process creation, never interpolated in shell code.
    path = run({ "/bin/pwd", "-P" }, { cwd = path, timeout = 1 }):gsub("\n$", "")
    local result = { path = path }
    local git = available.git and rex.exec({ available.git, "rev-parse", "--show-toplevel" }, { cwd = path, timeout = 1 })
    if git and git.ok then result.git_root = git.stdout:gsub("\n$", "") end
    return { results = result }
  end,
}
