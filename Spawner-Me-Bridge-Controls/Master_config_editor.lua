-- slaves.lua - simple slave list editor for master.cfg
local CONFIG = "master.cfg"

local function loadCfg()
  if not fs.exists(CONFIG) then
    return { slaves = {}, globalAllow = true }
  end
  local f = fs.open(CONFIG, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  if type(t) ~= "table" then t = {} end
  t.slaves = t.slaves or {}
  if t.globalAllow == nil then t.globalAllow = true end
  return t
end

local function saveCfg(cfg)
  local f = fs.open(CONFIG, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

local function pause(msg)
  if msg then print(msg) end
  print("Press Enter...")
  read()
end

local function listSlaves(cfg)
  print("=== Slave List ===")
  if #cfg.slaves == 0 then
    print("(empty)")
  else
    for i, name in ipairs(cfg.slaves) do
      print(("%2d) %s"):format(i, name))
    end
  end
  print("")
end

local function inputNonEmpty(prompt)
  while true do
    write(prompt)
    local s = read()
    if s and s:gsub("%s+", "") ~= "" then
      return s
    end
    print("Please enter something (not blank).")
  end
end

local function inputIndex(max, prompt)
  while true do
    write(prompt)
    local s = read()
    local n = tonumber(s)
    if n and n >= 1 and n <= max then return n end
    print(("Enter a number 1..%d"):format(max))
  end
end

local function existsName(cfg, name)
  for _, v in ipairs(cfg.slaves) do
    if v == name then return true end
  end
  return false
end

-- ===== main menu =====
local cfg = loadCfg()

while true do
  term.clear()
  term.setCursorPos(1,1)

  print("=== Slave Manager ===")
  print("Config file: " .. CONFIG)
  print("Global Allow: " .. tostring(cfg.globalAllow))
  print("")

  listSlaves(cfg)

  print("[1] Add slave")
  print("[2] Rename slave")
  print("[3] Remove slave")
  print("[4] Toggle Global Allow")
  print("[5] Save & exit")
  print("[6] Exit without saving")
  print("")

  write("Choose: ")
  local choice = read()

  if choice == "1" then
    local name = inputNonEmpty("New slave name: ")
    if existsName(cfg, name) then
      pause("That name already exists.")
    else
      table.insert(cfg.slaves, name)
      pause("Added.")
    end

  elseif choice == "2" then
    if #cfg.slaves == 0 then
      pause("No slaves to rename.")
    else
      local i = inputIndex(#cfg.slaves, "Which number to rename? ")
      local old = cfg.slaves[i]
      local name = inputNonEmpty("New name for '" .. old .. "': ")
      if existsName(cfg, name) then
        pause("That name already exists.")
      else
        cfg.slaves[i] = name
        pause("Renamed.")
      end
    end

  elseif choice == "3" then
    if #cfg.slaves == 0 then
      pause("No slaves to remove.")
    else
      local i = inputIndex(#cfg.slaves, "Which number to remove? ")
      local removed = table.remove(cfg.slaves, i)
      pause("Removed: " .. tostring(removed))
    end

  elseif choice == "4" then
    cfg.globalAllow = not cfg.globalAllow
    pause("Global Allow is now " .. tostring(cfg.globalAllow))

  elseif choice == "5" then
    saveCfg(cfg)
    print("Saved to " .. CONFIG)
    print("Now re-run your master program (or reboot).")
    return

  elseif choice == "6" then
    print("Exiting without saving.")
    return

  else
    pause("Unknown option.")
  end
end
