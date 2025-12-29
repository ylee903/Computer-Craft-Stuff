-- startup.lua (MASTER)
-- Dashboard + Slave Detail + Rules view + BASIC RULE ENGINE (AUTO)
-- Interlocks: ARM/DISARM + Screen STOP latch + ME power < 50% lockout
-- Comms: signed messages + STATUS requests + heartbeats to keep ON slaves alive
--
-- RULE MODEL (per slave):
--   cfg.slave_cfg[name].rules.on_any  = { {item="minecraft:stick", low=2000}, ... }   -- OR
--   cfg.slave_cfg[name].rules.off_all = { {item="minecraft:stick", high=8000}, ... }  -- AND
--
-- AUTO behaviour:
--   - If currently OFF, any on_any trigger (count < low) => desired ON
--   - If currently ON, all off_all satisfied (count > high for every entry) => desired OFF
--   - If on_any empty: never turns on (AUTO defaults OFF)
--   - If off_all empty: once turned ON by low trigger, stays ON until operator changes mode
--
-- FORCEON behaviour:
--   - desired ON (subject to global interlocks)
-- FORCEOFF behaviour:
--   - desired OFF always
--
local CONFIG   = "master.cfg"
local PROTOCOL = "spawner_ctrl_v3"

-- ===== Tunables =====
local UI_TEXT_SCALE = 0.5
local RULE_TICK_SEC = 1.0        -- how often to re-evaluate rules (keeps ME polling reasonable)
local HB_PERIOD_SEC = 4.8        -- send heartbeats slightly faster than slave timeout
local ME_LOCKOUT_RATIO = 0.50    -- < 50% stored/capacity => LOCKOUT

-- Where your ME Bridge is:
local ME_BRIDGE_SIDE = "right"   -- you said: peripheral.wrap("right")

-- ===== UTIL =====
local function openModem()
  for _, p in ipairs(peripheral.getNames()) do
    if peripheral.getType(p) == "modem" then
      if not rednet.isOpen(p) then rednet.open(p) end
      return true
    end
  end
  return false
end

local function load()
  if not fs.exists(CONFIG) then return nil end
  local f = fs.open(CONFIG, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  return t
end

local function save(cfg)
  local f = fs.open(CONFIG, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

local function sig(key, payload)
  local s = payload .. "|" .. key
  local h = 0
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 2147483647
  end
  return tostring(h)
end

local function padRight(s, n)
  s = tostring(s or "")
  if #s > n then return s:sub(1, n) end
  return s .. string.rep(" ", n - #s)
end

local function clamp(x,a,b)
  if x < a then return a end
  if x > b then return b end
  return x
end

-- ===== CONFIG BOOTSTRAP =====
local cfg = load()
if not cfg then
  term.clear(); term.setCursorPos(1,1)
  print("No " .. CONFIG .. " found.")
  print("Create it with your editor programs first (slaves.lua / rules.lua).")
  return
end

cfg.slaves = cfg.slaves or {}
cfg.key = cfg.key or ""
cfg.globalAllow = cfg.globalAllow ~= false
cfg.interlocks = cfg.interlocks or { screenStop = false }

-- per-slave config (mode + rules). Backwards compatible.
cfg.slave_cfg = cfg.slave_cfg or {}
for _,name in ipairs(cfg.slaves) do
  cfg.slave_cfg[name] = cfg.slave_cfg[name] or { mode = "AUTO", rules = { on_any = {}, off_all = {} } }
  cfg.slave_cfg[name].rules = cfg.slave_cfg[name].rules or { on_any = {}, off_all = {} }
  cfg.slave_cfg[name].rules.on_any = cfg.slave_cfg[name].rules.on_any or {}
  cfg.slave_cfg[name].rules.off_all = cfg.slave_cfg[name].rules.off_all or {}
end

if not cfg.key or cfg.key == "" then
  term.clear(); term.setCursorPos(1,1)
  print("=== Master setup ===")
  print("Shared key not set.")
  write("Enter shared key (must match slaves): ")
  cfg.key = read("*")
  save(cfg)
  print("Key saved to " .. CONFIG)
  sleep(0.8)
end

if not openModem() then error("No modem found.") end

local mon = peripheral.find("monitor")
if not mon then error("No monitor found.") end
mon.setTextScale(UI_TEXT_SCALE)

-- ===== ME BRIDGE =====
local bridge = peripheral.wrap(ME_BRIDGE_SIDE)
if not bridge then
  error("No ME Bridge found on side '"..ME_BRIDGE_SIDE.."'.")
end

-- robust count helper (handles count vs amount variations)
local function meCount(name)
  local it = bridge.getItem({ name = name })
  if not it then return 0 end
  return it.count or it.amount or 0
end

local function getStoredEnergy()
  -- You noted both sets exist; prefer the names you tested.
  local ok, v = pcall(function() return bridge.getStoredEnergy() end)
  if ok and type(v) == "number" then return v end
  -- fallback to documented name
  ok, v = pcall(function() return bridge.getEnergyStorage() end)
  if ok and type(v) == "number" then return v end
  return 0
end

local function getEnergyCapacity()
  local ok, v = pcall(function() return bridge.getEnergyCapacity() end)
  if ok and type(v) == "number" then return v end
  -- fallback to documented name
  ok, v = pcall(function() return bridge.getMaxEnergyStorage() end)
  if ok and type(v) == "number" then return v end
  return 0
end

-- ===== STATE =====
local state = {
  -- paging for dashboard slave table
  page = 1,
  perPage = 12,

  -- selection
  selectedIndex = nil,
  selectedName = nil,

  -- global controls
  armed = cfg.globalAllow,
  screenStop = cfg.interlocks.screenStop or false,

  lockoutReasons = {},

  -- last known statuses (from STATUS_RSP)
  status = {}, -- status[name] = { actual="ON/OFF", enabled=bool, side="back", reason="...", last=os.clock(), hbAge="0.4s" }

  -- rule engine memory
  autoLatch = {},     -- autoLatch[name] = bool (what AUTO currently wants, with hysteresis)
  desired = {},       -- desired[name] = bool (final desired before interlocks)
  lastSent = {},      -- lastSent[name] = bool (avoid spamming commands)

  -- page system
  pageName = "DASH", -- DASH | SLAVE | RULES
  rulesPage = 1,

  -- last computed ME power
  meStored = 0,
  meCap = 0,
  meRatio = 0,
}

-- ===== REDNET SEND =====
local function sendToSlave(slaveName, kind, value, valueStr)
  -- IMPORTANT: for signing, we must build a deterministic string.
  -- For table values, provide a stable valueStr as well.
  local vpart = valueStr or tostring(value or "")
  local payload = (kind or "").."|"..(slaveName or "").."|"..vpart
  local msg = { kind = kind, slave = slaveName, value = value, valueStr = vpart, s = sig(cfg.key, payload) }
  rednet.broadcast(msg, PROTOCOL)
end

local function requestStatusAll()
  for _, name in ipairs(cfg.slaves) do
    sendToSlave(name, "STATUS_REQ", "1")
  end
end

local function requestStatusOne(name)
  if not name or name == "" then return end
  sendToSlave(name, "STATUS_REQ", "1")
end

local function cmdOn(name)
  sendToSlave(name, "CMD", "ON")
end

local function cmdOff(name)
  sendToSlave(name, "CMD", "OFF")
end

local function sendHeartbeatAll()
  -- Heartbeat doesn’t need to include value; slaves ignore HB unless enabled.
  for _, name in ipairs(cfg.slaves) do
    sendToSlave(name, "HB", "1")
  end
end

-- ===== INTERLOCKS =====
local function computeMe()
  local cap = getEnergyCapacity()
  local st  = getStoredEnergy()
  state.meCap = cap
  state.meStored = st
  if cap > 0 then
    state.meRatio = st / cap
  else
    state.meRatio = 0
  end
end

local function computeLockoutReasons()
  computeMe()
  local reasons = {}

  if state.meCap <= 0 then
    table.insert(reasons, "ME CAP?")
  else
    if state.meRatio < ME_LOCKOUT_RATIO then
      table.insert(reasons, string.format("ME < %d%%", math.floor(ME_LOCKOUT_RATIO * 100 + 0.5)))
    end
  end

  if state.screenStop then table.insert(reasons, "SCREEN STOP") end
  state.lockoutReasons = reasons
end

local function isLockedOut()
  return #state.lockoutReasons > 0
end

-- ===== RULE ENGINE =====
local function getSlaveMode(name)
  local sc = cfg.slave_cfg[name]
  return (sc and sc.mode) or "AUTO"
end

local function getRules(name)
  local sc = cfg.slave_cfg[name]
  if not sc then return { on_any = {}, off_all = {} } end
  local r = sc.rules or { on_any = {}, off_all = {} }
  r.on_any = r.on_any or {}
  r.off_all = r.off_all or {}
  return r
end

local function buildWatchedItems()
  -- Collect unique items used in any rule across all slaves
  local set = {}
  for _, name in ipairs(cfg.slaves) do
    local rules = getRules(name)
    for _, r in ipairs(rules.on_any or {}) do
      if r and r.item then set[r.item] = true end
    end
    for _, r in ipairs(rules.off_all or {}) do
      if r and r.item then set[r.item] = true end
    end
  end

  local list = {}
  for k,_ in pairs(set) do table.insert(list, k) end
  table.sort(list)
  return list
end

local function sampleItemCounts(items)
  -- one getItem call per unique item; cached for this tick
  local counts = {}
  for _, itemName in ipairs(items) do
    counts[itemName] = meCount(itemName)
  end
  return counts
end

local function evalAutoDesired(name, counts)
  local rules = getRules(name)

  -- current latched state
  local cur = state.autoLatch[name] == true

  -- If OFF: check OR low triggers
  if not cur then
    for _, r in ipairs(rules.on_any or {}) do
      if r and r.item and r.low ~= nil then
        local c = counts[r.item] or 0
        if c < tonumber(r.low) then
          return true
        end
      end
    end
    return false
  end

  -- If ON: check AND high triggers
  local offList = rules.off_all or {}
  if #offList == 0 then
    -- no off conditions => stay ON once started
    return true
  end

  for _, r in ipairs(offList) do
    if r and r.item and r.high ~= nil then
      local c = counts[r.item] or 0
      if not (c > tonumber(r.high)) then
        return true -- not ready to turn off yet
      end
    else
      return true -- malformed rule => be conservative
    end
  end

  return false
end

local function computeDesiredAll(counts)
  for _, name in ipairs(cfg.slaves) do
    local mode = getSlaveMode(name)
    local want = false

    if mode == "FORCEOFF" then
      want = false
    elseif mode == "FORCEON" then
      want = true
    else
      -- AUTO or unknown
      want = evalAutoDesired(name, counts)
      state.autoLatch[name] = want
    end

    state.desired[name] = want
  end
end

local function applyInterlocksAndSend()
  computeLockoutReasons()

  for _, name in ipairs(cfg.slaves) do
    local want = state.desired[name] == true

    -- Apply global interlocks
    if not state.armed then want = false end
    if isLockedOut() then want = false end

    -- send only on change
    if state.lastSent[name] == nil then
      state.lastSent[name] = want
      if want then cmdOn(name) else cmdOff(name) end
    else
      if state.lastSent[name] ~= want then
        state.lastSent[name] = want
        if want then cmdOn(name) else cmdOff(name) end
      end
    end
  end
end

-- ===== UI PRIMITIVES =====
local function writeAt(x,y,text,fg,bg)
  if bg then mon.setBackgroundColor(bg) end
  if fg then mon.setTextColor(fg) end
  mon.setCursorPos(x,y); mon.write(text)
  mon.setTextColor(colors.white); mon.setBackgroundColor(colors.black)
end

local function fillLine(y,bg)
  local w,_ = mon.getSize()
  mon.setCursorPos(1,y)
  mon.setBackgroundColor(bg or colors.black)
  mon.clearLine()
  mon.setBackgroundColor(colors.black)
end

local function inRect(x,y, rx,ry, rw,rh)
  return x>=rx and x<=rx+rw-1 and y>=ry and y<=ry+rh-1
end

-- ===== LAYOUT =====
local ui = { buttons = {}, cols = {}, w=0,h=0, tableTopY=5, footerY=0 }

local function computeLayoutDashboard()
  local w,h = mon.getSize()
  ui.w, ui.h = w,h

  local tableTopY = 5
  local footerY = h
  local maxRows = math.max(1, footerY - tableTopY - 1)
  state.perPage = maxRows

  local buttons = {
    {id="ARM",   label= state.armed and "DISARM" or "ARM"},
    {id="STOP",  label= state.screenStop and "CLEAR STOP" or "STOP"},
    {id="RESET", label= "RESET/RESUME"},
    {id="QUERY", label= "QUERY STATUS"},
    {id="RULES", label= "RULES"},
    {id="PREV",  label= "<"},
    {id="NEXT",  label= ">"},
  }

  local bx = 2
  for _,b in ipairs(buttons) do
    local bw = math.max(#b.label + 2, 8)
    b.x,b.y,b.w,b.h = bx, 3, bw, 1
    bx = bx + bw + 1
  end

  local cols = {
    {key="name",    title="Name",    min=16},
    {key="mode",    title="Mode",    min=8},
    {key="actual",  title="State",   min=5},
    {key="desired", title="Want",    min=5},
    {key="reason",  title="Reason",  min=10},
    {key="hb",      title="HB",      min=5},
  }

  local sep = 1
  local function totalMin()
    local t = 2
    for _,c in ipairs(cols) do t = t + c.min + sep end
    return t
  end

  while totalMin() > w and #cols > 4 do
    table.remove(cols)
  end

  for _,c in ipairs(cols) do c.w = c.min end
  local extra = w - totalMin()
  if extra > 0 then
    for _,c in ipairs(cols) do
      if c.key == "name" then
        -- give name column some extra too
        c.w = c.w + math.floor(extra * 0.35)
      end
    end
    for _,c in ipairs(cols) do
      if c.key == "reason" then
        c.w = c.w + math.floor(extra * 0.65)
      end
    end
  end

  local x = 2
  for _,c in ipairs(cols) do
    c.x = x
    x = x + c.w + sep
  end

  ui.buttons = buttons
  ui.cols = cols
  ui.tableTopY = tableTopY
  ui.footerY = footerY
end

local function computeLayoutSlave()
  local w,h = mon.getSize()
  ui.w, ui.h = w,h

  local buttons = {
    {id="BACK",  label="BACK"},
    {id="QUERY", label="QUERY"},
    {id="AUTO",  label="AUTO"},
    {id="FON",   label="FORCE ON"},
    {id="FOFF",  label="FORCE OFF"},
    {id="ONCEON",label="ONCE ON"},
    {id="ONCEOFF",label="ONCE OFF"},
  }

  local bx = 2
  for _,b in ipairs(buttons) do
    local bw = math.max(#b.label + 2, 8)
    b.x,b.y,b.w,b.h = bx, 3, bw, 1
    bx = bx + bw + 1
  end

  ui.buttons = buttons
end

local function computeLayoutRules()
  local w,h = mon.getSize()
  ui.w, ui.h = w,h

  local buttons = {
    {id="BACK", label="BACK"},
    {id="PREV", label="<"},
    {id="NEXT", label=">"},
  }

  local bx = 2
  for _,b in ipairs(buttons) do
    local bw = math.max(#b.label + 2, 6)
    b.x,b.y,b.w,b.h = bx, 3, bw, 1
    bx = bx + bw + 1
  end

  ui.buttons = buttons
end

-- ===== RENDER COMMON =====
local function drawHeader()
  computeLockoutReasons()

  local w,h = mon.getSize()
  ui.w, ui.h = w,h

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.clear()

  fillLine(1, colors.gray)
  writeAt(2,1,"Spawner Master", colors.black, colors.gray)

  local ratioPct = (state.meCap > 0) and (state.meRatio * 100) or 0
  local headRight = string.format("ME: %d/%d (%.0f%%)", state.meStored, state.meCap, ratioPct)
  writeAt(math.max(2, w-#headRight-1), 1, headRight, colors.black, colors.gray)

  if isLockedOut() then
    fillLine(2, colors.red)
    writeAt(2,2,"LOCKOUT: " .. table.concat(state.lockoutReasons, " | "), colors.white, colors.red)
  else
    fillLine(2, colors.green)
    writeAt(2,2,"LOCKOUT: NONE", colors.black, colors.green)
  end
end

local function drawButtons()
  for _,b in ipairs(ui.buttons) do
    local bg, fg = colors.lightGray, colors.black
    if b.id == "ARM" then bg = state.armed and colors.orange or colors.lime end
    if b.id == "STOP" then bg = colors.red; fg = colors.white end
    if b.id == "RESET" then bg = colors.cyan; fg = colors.black end
    if b.id == "QUERY" then bg = colors.yellow; fg = colors.black end
    if b.id == "RULES" then bg = colors.lightBlue; fg = colors.black end
    if b.id == "PREV" or b.id == "NEXT" then bg = colors.gray; fg = colors.white end

    if b.id == "BACK" then bg = colors.gray; fg = colors.white end
    if b.id == "AUTO" then bg = colors.lime; fg = colors.black end
    if b.id == "FON" then bg = colors.orange; fg = colors.black end
    if b.id == "FOFF" then bg = colors.orange; fg = colors.black end
    if b.id == "ONCEON" then bg = colors.cyan; fg = colors.black end
    if b.id == "ONCEOFF" then bg = colors.cyan; fg = colors.black end

    writeAt(b.x,b.y, padRight(b.label, b.w), fg, bg)
  end
end

-- ===== DASH PAGE =====
local function drawDashboard()
  computeLayoutDashboard()
  drawHeader()
  drawButtons()

  for _,c in ipairs(ui.cols) do
    writeAt(c.x, 4, padRight(c.title, c.w), colors.cyan, colors.black)
  end

  local total = #cfg.slaves
  local pages = math.max(1, math.ceil(total / state.perPage))
  state.page = clamp(state.page, 1, pages)

  local startIdx = (state.page-1)*state.perPage + 1
  local endIdx = math.min(total, startIdx + state.perPage - 1)

  local y = ui.tableTopY
  for i = startIdx, endIdx do
    local name = cfg.slaves[i]
    local st = state.status[name] or {}

    local mode = getSlaveMode(name)
    local want = (state.desired[name] == true) and "ON" or "OFF"

    local row = {
      name = name,
      mode = mode,
      actual = st.actual or "--",
      desired = want,
      reason = st.reason or (isLockedOut() and "LOCKOUT" or "--"),
      hb = st.hbAge or "--"
    }

    local selected = (state.selectedIndex == i)
    local bg = selected and colors.gray or colors.black
    local fg = selected and colors.black or colors.white

    for _,c in ipairs(ui.cols) do
      writeAt(c.x, y, padRight(row[c.key] or "", c.w), fg, bg)
    end
    y = y + 1
  end

  local foot = ("Page %d/%d  (%d-%d of %d)"):format(state.page, pages, startIdx, endIdx, total)
  writeAt(2, ui.footerY, foot, colors.gray, colors.black)
end

-- ===== SLAVE DETAIL =====
local function drawSlaveDetail()
  computeLayoutSlave()
  drawHeader()
  drawButtons()

  local w,h = mon.getSize()
  local name = state.selectedName
  if not name then
    writeAt(2,5,"No slave selected. Tap a row first.", colors.red)
    return
  end

  local sc = cfg.slave_cfg[name] or { mode="AUTO", rules={on_any={}, off_all={}} }
  local st = state.status[name] or {}

  writeAt(2,5, ("Slave: %s"):format(name), colors.white)
  writeAt(2,6, ("Mode: %s"):format(sc.mode or "AUTO"), colors.white)
  writeAt(2,7, ("State: %s   HB: %s"):format(st.actual or "--", st.hbAge or "--"), colors.white)
  writeAt(2,8, ("Desired: %s"):format((state.desired[name] == true) and "ON" or "OFF"), colors.white)
  writeAt(2,9, ("Reason: %s"):format(st.reason or "--"), colors.white)

  writeAt(2,11,"ON triggers (OR):", colors.cyan)
  local y = 12
  local shown = 0
  for _,r in ipairs(sc.rules.on_any or {}) do
    if y >= h-1 then break end
    writeAt(2,y, ("- %s < %s"):format(tostring(r.item), tostring(r.low)), colors.white); y=y+1; shown=shown+1
  end
  if shown == 0 then writeAt(2,y,"(none)", colors.gray); y=y+1 end

  writeAt(2,y+1,"OFF triggers (AND):", colors.cyan); y=y+2
  shown = 0
  for _,r in ipairs(sc.rules.off_all or {}) do
    if y >= h-1 then break end
    writeAt(2,y, ("- %s > %s"):format(tostring(r.item), tostring(r.high)), colors.white); y=y+1; shown=shown+1
  end
  if shown == 0 then writeAt(2,y,"(none)", colors.gray) end
end

-- ===== RULES VIEW =====
local function drawRules()
  computeLayoutRules()
  drawHeader()
  drawButtons()

  local w,h = mon.getSize()
  writeAt(2,5,"RULES (view). Edit via terminal editor program.", colors.white)
  writeAt(2,6,("AUTO uses OR-low to start, AND-high to stop."), colors.white)

  local rowsTop = 8
  local per = math.max(1, h - rowsTop - 2)
  local total = #cfg.slaves
  local pages = math.max(1, math.ceil(total / per))
  state.rulesPage = clamp(state.rulesPage, 1, pages)

  local startIdx = (state.rulesPage-1)*per + 1
  local endIdx = math.min(total, startIdx + per - 1)

  writeAt(2,7,"Name                Mode      on_any  off_all", colors.cyan)
  local y = rowsTop
  for i = startIdx, endIdx do
    local name = cfg.slaves[i]
    local sc = cfg.slave_cfg[name] or { mode="AUTO", rules={on_any={}, off_all={}} }
    local onN = #(sc.rules.on_any or {})
    local offN = #(sc.rules.off_all or {})
    local line = padRight(name, 18) .. " " .. padRight(sc.mode or "AUTO", 8) .. "  " .. padRight(onN, 6) .. " " .. padRight(offN, 6)
    writeAt(2,y,line, colors.white); y=y+1
  end

  local foot = ("Rules page %d/%d  (%d-%d of %d)"):format(state.rulesPage, pages, startIdx, endIdx, total)
  writeAt(2, h, foot, colors.gray)
end

-- ===== ACTIONS =====
local function forceAllOff()
  for _,name in ipairs(cfg.slaves) do
    cmdOff(name)
    state.lastSent[name] = false
    state.desired[name] = false
    state.autoLatch[name] = false
  end
end

local function doArmToggle()
  state.armed = not state.armed
  cfg.globalAllow = state.armed
  save(cfg)
  if not state.armed then
    forceAllOff()
  end
end

local function doStopToggle()
  state.screenStop = not state.screenStop
  cfg.interlocks.screenStop = state.screenStop
  save(cfg)
  if state.screenStop then
    forceAllOff()
  end
end

local function doResetResume()
  -- Intention: after power restored + you want system to re-apply desired states
  -- Behaviour:
  --   - clears AUTO latch (so rules can re-trigger cleanly)
  --   - immediately runs one rule tick + applies
  if isLockedOut() then return end
  if not state.armed then return end

  for _,name in ipairs(cfg.slaves) do
    state.autoLatch[name] = false
  end

  requestStatusAll()
end

local function gotoPage(name)
  state.pageName = name
end

local function setSlaveMode(slaveName, mode)
  if not slaveName then return end
  cfg.slave_cfg[slaveName] = cfg.slave_cfg[slaveName] or { mode="AUTO", rules={on_any={}, off_all={}} }
  cfg.slave_cfg[slaveName].mode = mode
  save(cfg)

  -- If leaving AUTO, don’t keep old latch
  if mode ~= "AUTO" then
    state.autoLatch[slaveName] = false
  end
end

local function doOnce(slaveName, on)
  if not slaveName then return end
  if isLockedOut() then return end
  if not state.armed then return end

  -- ONCE sends an immediate command but does not change stored mode
  if on then
    cmdOn(slaveName)
    state.lastSent[slaveName] = true
  else
    cmdOff(slaveName)
    state.lastSent[slaveName] = false
  end

  -- refresh status soon
  requestStatusOne(slaveName)
end

-- ===== RECEIVER LOOP =====
local function receiverLoop()
  while true do
    local sender, msg = rednet.receive(PROTOCOL, 0.5)
    if sender and type(msg) == "table" and msg.slave and msg.kind then
      local vpart = msg.valueStr or tostring(msg.value or "")
      local payload = (msg.kind or "").."|"..(msg.slave or "").."|"..vpart
      if msg.s == sig(cfg.key, payload) then
        if msg.kind == "STATUS_RSP" then
          local name = msg.slave
          local v = msg.value
          state.status[name] = state.status[name] or {}
          if type(v) == "table" then
            state.status[name].actual  = v.actual  or state.status[name].actual
            state.status[name].reason  = v.reason  or state.status[name].reason
            state.status[name].enabled = v.enabled
            state.status[name].side    = v.side    or state.status[name].side
          else
            state.status[name].reason = tostring(v)
          end
          state.status[name].last = os.clock()
        end
      end
    end

    for _,name in ipairs(cfg.slaves) do
      local st = state.status[name]
      if st and st.last then
        st.hbAge = string.format("%.1fs", os.clock() - st.last)
      end
    end
  end
end

-- ===== TOUCH HANDLERS =====
local function handleButtons(x,y)
  for _,b in ipairs(ui.buttons) do
    if inRect(x,y, b.x,b.y,b.w,b.h) then
      if state.pageName == "DASH" then
        if b.id == "ARM" then doArmToggle()
        elseif b.id == "STOP" then doStopToggle()
        elseif b.id == "RESET" then doResetResume()
        elseif b.id == "QUERY" then requestStatusAll()
        elseif b.id == "RULES" then gotoPage("RULES")
        elseif b.id == "PREV" then state.page = math.max(1, state.page - 1)
        elseif b.id == "NEXT" then state.page = state.page + 1
        end
        return true

      elseif state.pageName == "SLAVE" then
        local name = state.selectedName
        if b.id == "BACK" then gotoPage("DASH")
        elseif b.id == "QUERY" then requestStatusOne(name)
        elseif b.id == "AUTO" then setSlaveMode(name, "AUTO")
        elseif b.id == "FON" then setSlaveMode(name, "FORCEON")
        elseif b.id == "FOFF" then setSlaveMode(name, "FORCEOFF")
        elseif b.id == "ONCEON" then doOnce(name, true)
        elseif b.id == "ONCEOFF" then doOnce(name, false)
        end
        return true

      elseif state.pageName == "RULES" then
        if b.id == "BACK" then gotoPage("DASH")
        elseif b.id == "PREV" then state.rulesPage = math.max(1, state.rulesPage - 1)
        elseif b.id == "NEXT" then state.rulesPage = state.rulesPage + 1
        end
        return true
      end
    end
  end
  return false
end

local function handleRowTapDashboard(x,y)
  local rowY0 = ui.tableTopY
  local idxOnPage = y - rowY0 + 1
  if idxOnPage < 1 or idxOnPage > state.perPage then return false end

  local total = #cfg.slaves
  local pages = math.max(1, math.ceil(total / state.perPage))
  state.page = clamp(state.page, 1, pages)

  local startIdx = (state.page-1)*state.perPage + 1
  local i = startIdx + (idxOnPage-1)
  if i < 1 or i > total then return false end

  state.selectedIndex = i
  state.selectedName = cfg.slaves[i]
  gotoPage("SLAVE")
  return true
end

-- ===== UI LOOP =====
local function uiLoop()
  while true do
    if state.pageName == "DASH" then
      drawDashboard()
    elseif state.pageName == "SLAVE" then
      drawSlaveDetail()
    elseif state.pageName == "RULES" then
      drawRules()
    end

    local _, _, x, y = os.pullEvent("monitor_touch")
    if handleButtons(x,y) then
      -- handled
    else
      if state.pageName == "DASH" then
        handleRowTapDashboard(x,y)
      end
    end
  end
end

-- ===== CONTROL LOOP =====
local function controlLoop()
  -- initial status request
  requestStatusAll()

  local lastRule = 0
  local lastHB = 0

  while true do
    local now = os.clock()

    -- Rule tick
    if (now - lastRule) >= RULE_TICK_SEC then
      lastRule = now

      -- 1) build item list from rules, 2) sample counts once, 3) compute desired, 4) apply interlocks & send
      local watched = buildWatchedItems()
      local counts = sampleItemCounts(watched)

      computeDesiredAll(counts)
      applyInterlocksAndSend()
    end

    -- Heartbeats
    if (now - lastHB) >= HB_PERIOD_SEC then
      lastHB = now
      sendHeartbeatAll()
    end

    -- keep loop light
    sleep(0.05)
  end
end

parallel.waitForAny(uiLoop, receiverLoop, controlLoop)
