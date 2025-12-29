-- rules_configurator.lua
-- Terminal-based rule configurator for Spawner Master
--
-- What it does:
--   * Loads master.cfg
--   * Shows known slaves
--   * Lets you add/edit/delete per-slave rules:
--       - ON triggers  (OR):  when ANY item < low  => want ON
--       - OFF triggers (AND): when ALL items > high => want OFF
--   * Optionally shows current ME counts for items (using ME Bridge) to help confirm names
--   * Enforces basic sanity: high > low for same item; no duplicate item entries per list
--   * Writes changes back to master.cfg
--
-- NOTES:
--   * This tool does NOT require any changes to the master startup.lua.
--   * It uses cfg.slave_cfg[name].rules = { on_any = { {item, low}, ... }, off_all = { {item, high}, ... } }
--   * It does not attempt to validate item registry names beyond optionally showing the current count.
--
-- Usage:
--   1) Put this file on the MASTER computer.
--   2) Run:  rules
--      (or:  lua rules_configurator.lua)
--
-- Optional setup:
--   If your ME bridge is on the RIGHT side: it will auto-wrap peripheral.wrap("right").
--   If not found, it will try peripheral.find("me_bridge").

local CONFIG = "master.cfg"

-- ====== helpers ======
local function cls()
  term.clear(); term.setCursorPos(1,1)
end

local function readLine(prompt)
  if prompt then write(prompt) end
  return read() or ""
end

local function readNumber(prompt)
  while true do
    local s = readLine(prompt)
    local n = tonumber(s)
    if n then return n end
    print("Please enter a number.")
  end
end

local function pause(msg)
  print(msg or "(press Enter)")
  read()
end

local function loadCfg()
  if not fs.exists(CONFIG) then return nil end
  local f = fs.open(CONFIG, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  return t
end

local function saveCfg(cfg)
  local f = fs.open(CONFIG, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

local function ensureTables(cfg)
  cfg.slaves = cfg.slaves or {}
  cfg.slave_cfg = cfg.slave_cfg or {}
  for _, name in ipairs(cfg.slaves) do
    cfg.slave_cfg[name] = cfg.slave_cfg[name] or { mode = "AUTO", rules = { on_any = {}, off_all = {} } }
    cfg.slave_cfg[name].rules = cfg.slave_cfg[name].rules or { on_any = {}, off_all = {} }
    cfg.slave_cfg[name].rules.on_any = cfg.slave_cfg[name].rules.on_any or {}
    cfg.slave_cfg[name].rules.off_all = cfg.slave_cfg[name].rules.off_all or {}
  end
end

-- ====== selection helper (RESTORED) ======
local function pickFromList(title, items)
  print(title)
  for i, v in ipairs(items) do
    print(string.format("  %d) %s", i, tostring(v)))
  end
  print("  0) Cancel")
  while true do
    local n = tonumber(readLine("> "))
    if n and n >= 0 and n <= #items then
      if n == 0 then return nil end
      return n, items[n]
    end
    print("Pick a number 0.." .. #items)
  end
end

local function indexByItem(list, item)
  for i, r in ipairs(list) do
    if r.item == item then return i end
  end
  return nil
end

-- ====== ME Bridge optional (FIXED NAME) ======
local bridge
local function tryAttachBridge()
  if peripheral.isPresent("right") and peripheral.getType("right") == "me_bridge" then
    return peripheral.wrap("right")
  end
  return peripheral.find("me_bridge")
end

local function meCount(name)
  if not bridge then return nil end
  local it = bridge.getItem({ name = name })
  if not it then return 0 end
  return it.count or it.amount or 0
end

local function showMaybeCount(itemName)
  if not bridge then return end
  local ok, cnt = pcall(meCount, itemName)
  if ok then
    print(string.format("    Current ME count: %s", tostring(cnt)))
  end
end

-- ====== rule operations ======
local function printRulesForSlave(cfg, slave)
  local sc = cfg.slave_cfg[slave] or { rules = { on_any = {}, off_all = {} } }
  local rules = sc.rules or { on_any = {}, off_all = {} }

  print("\nON triggers (OR):")
  if #rules.on_any == 0 then
    print("  (none)")
  else
    for i, r in ipairs(rules.on_any) do
      print(string.format("  %d) %s < %s", i, tostring(r.item), tostring(r.low)))
    end
  end

  print("\nOFF triggers (AND):")
  if #rules.off_all == 0 then
    print("  (none)")
  else
    for i, r in ipairs(rules.off_all) do
      print(string.format("  %d) %s > %s", i, tostring(r.item), tostring(r.high)))
    end
  end
end

local function addOrEditOnRule(cfg, slave)
  local sc = cfg.slave_cfg[slave]
  local on_any = sc.rules.on_any

  cls()
  print("Add/Edit ON trigger (OR) for: " .. slave)
  print("Rule: if ANY item < low => want ON")

  local item = readLine("Item registry name (e.g. minecraft:stick): ")
  if item == "" then return end
  showMaybeCount(item)

  local low = readNumber("Low threshold (integer): ")

  -- conflict check preserved
  local off_idx = indexByItem(sc.rules.off_all, item)
  if off_idx then
    local high = sc.rules.off_all[off_idx].high
    if not (high and high > low) then
      print(string.format("WARNING: existing OFF threshold for %s is %s, not > low %s.", item, tostring(high), tostring(low)))
      print("You should adjust the OFF rule to avoid conflicts.")
      pause()
    end
  end

  local idx = indexByItem(on_any, item)
  if idx then
    on_any[idx].low = low
    print("Updated existing ON rule.")
  else
    table.insert(on_any, { item = item, low = low })
    print("Added new ON rule.")
  end
  saveCfg(cfg)
  pause("Saved. Press Enter")
end

local function addOrEditOffRule(cfg, slave)
  local sc = cfg.slave_cfg[slave]
  local off_all = sc.rules.off_all

  cls()
  print("Add/Edit OFF trigger (AND) for: " .. slave)
  print("Rule: if ALL items > high => want OFF")

  local item = readLine("Item registry name (e.g. minecraft:stick): ")
  if item == "" then return end
  showMaybeCount(item)

  local high = readNumber("High threshold (integer): ")

  local on_idx = indexByItem(sc.rules.on_any, item)
  if on_idx then
    local low = sc.rules.on_any[on_idx].low
    if not (high > low) then
      print(string.format("ERROR: high (%s) must be > low (%s) for %s.", tostring(high), tostring(low), item))
      pause("Not saved. Press Enter")
      return
    end
  end

  local idx = indexByItem(off_all, item)
  if idx then
    off_all[idx].high = high
    print("Updated existing OFF rule.")
  else
    table.insert(off_all, { item = item, high = high })
    print("Added new OFF rule.")
  end
  saveCfg(cfg)
  pause("Saved. Press Enter")
end

local function deleteRule(cfg, slave)
  local sc = cfg.slave_cfg[slave]

  cls()
  print("Delete rule for: " .. slave)
  print("Pick list: 1) ON (OR)  2) OFF (AND)")
  local which = readLine("> ")

  local list
  if which == "1" then list = sc.rules.on_any
  elseif which == "2" then list = sc.rules.off_all
  else return end

  if #list == 0 then
    print("No rules in selected list")
    pause()
    return
  end

  for i, r in ipairs(list) do
    if which == "1" then
      print(string.format("  %d) %s < %s", i, r.item, r.low))
    else
      print(string.format("  %d) %s > %s", i, r.item, r.high))
    end
  end

  local n = tonumber(readLine("Delete which # (0 cancel): "))
  if not n or n <= 0 or n > #list then return end

  table.remove(list, n)
  saveCfg(cfg)
  print("Deleted.")
  pause("Saved. Press Enter")
end

local function moveRulesToOtherSlave(cfg, fromSlave)
  cls()
  print("Move/Copy rules from: " .. fromSlave)
  local _, toSlave = pickFromList("Select destination slave:", cfg.slaves)
  if not toSlave or toSlave == fromSlave then return end

  print("1) COPY rules  2) MOVE rules")
  local mode = readLine("> ")
  if mode ~= "1" and mode ~= "2" then return end

  local function copyList(src)
    local out = {}
    for _, r in ipairs(src or {}) do
      local t = {}
      for k, v in pairs(r) do t[k] = v end
      table.insert(out, t)
    end
    return out
  end

  local from = cfg.slave_cfg[fromSlave]
  local to = cfg.slave_cfg[toSlave]

  to.rules.on_any = copyList(from.rules.on_any)
  to.rules.off_all = copyList(from.rules.off_all)

  if mode == "2" then
    from.rules.on_any = {}
    from.rules.off_all = {}
  end

  saveCfg(cfg)
  print("Done.")
  pause("Saved. Press Enter")
end

-- ====== menus ======
local function selectSlave(cfg)
  cls()
  if #cfg.slaves == 0 then
    print("No slaves in config.")
    pause()
    return nil
  end

  for i, name in ipairs(cfg.slaves) do
    local sc = cfg.slave_cfg[name]
    print(string.format("%2d) %s  (on=%d off=%d mode=%s)", i, name, #sc.rules.on_any, #sc.rules.off_all, sc.mode))
  end
  print("0) Cancel")

  while true do
    local n = tonumber(readLine("> "))
    if n == 0 then return nil end
    if n and n >= 1 and n <= #cfg.slaves then return cfg.slaves[n] end
  end
end

local function slaveMenu(cfg, slave)
  while true do
    cls()
    print("Rule Configurator")
    print("Slave: " .. slave)
    printRulesForSlave(cfg, slave)

    print("\n1) Add/Edit ON")
    print("2) Add/Edit OFF")
    print("3) Delete rule")
    print("4) Move/Copy rules")
    print("5) Change mode")
    print("0) Exit")

    local c = readLine("> ")
    if c == "1" then addOrEditOnRule(cfg, slave)
    elseif c == "2" then addOrEditOffRule(cfg, slave)
    elseif c == "3" then deleteRule(cfg, slave)
    elseif c == "4" then moveRulesToOtherSlave(cfg, slave)
    elseif c == "5" then
      cls(); print("1) AUTO  2) FORCEON  3) FORCEOFF")
      local m = readLine("> ")
      if m == "1" then cfg.slave_cfg[slave].mode = "AUTO"
      elseif m == "2" then cfg.slave_cfg[slave].mode = "FORCEON"
      elseif m == "3" then cfg.slave_cfg[slave].mode = "FORCEOFF" end
      saveCfg(cfg); pause("Saved")
    elseif c == "0" then return end
  end
end

-- ====== bootstrap ======
local cfg = loadCfg()
if not cfg then
  cls(); print("No master.cfg found."); return
end

ensureTables(cfg)
bridge = tryAttachBridge()

cls()
if bridge then print("ME Bridge detected.") else print("ME Bridge 'me_bridge' not found (optional).") end
pause()

while true do
  local s = selectSlave(cfg)
  if not s then break end
  slaveMenu(cfg, s)
end
