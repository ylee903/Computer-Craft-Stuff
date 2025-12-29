-- startup.lua (MASTER)
-- Dashboard + Slave Detail + Rules (read-only) + Rule Engine (AUTO / FORCEON / FORCEOFF)
--
-- Key features:
--   * Reads master.cfg (created/edited by your editor programs)
--   * Polls ME Bridge item counts on a configurable interval (RULE_TICK_SEC)
--   * AUTO: hysteresis using ON (OR) and OFF (AND) rule lists
--   * FORCEON / FORCEOFF: manual override (still subject to global interlocks)
--   * Global interlocks:
--       - ARM/DISARM (globalAllow)
--       - Screen STOP latch
--       - ME power low lockout (percent of capacity)
--   * Shows live cached item counts next to rules on the slave detail page
--   * Button to force an immediate rule scan (without changing RULE_TICK_SEC)

local CONFIG   = "master.cfg"
local PROTOCOL = "spawner_ctrl_v3"

-- ====== TUNABLES ======
local RULE_TICK_SEC = 1.0       -- set to 60 or 300 later; keep small while testing
local ME_MIN_PCT    = 0.50      -- lockout if stored/capacity < 50%

-- ====== UTIL ======
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

local function safeCall(fn, ...)
  local ok, a, b, c, d = pcall(fn, ...)
  if not ok then return nil end
  return a, b, c, d
end

-- ====== CONFIG BOOTSTRAP ======
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
cfg.me = cfg.me or {}
cfg.me.minPct = cfg.me.minPct or ME_MIN_PCT
cfg.interlocks = cfg.interlocks or { screenStop = false }

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
mon.setTextScale(0.5)

-- ====== ME BRIDGE ATTACH ======
-- Your ME Bridge peripheral type is "me_bridge" (Advanced Peripherals). It may be on the right.
local function tryAttachBridge()
  if peripheral.isPresent("right") then
    local t = peripheral.getType("right")
    if t == "me_bridge" or t == "meBridge" then
      return peripheral.wrap("right")
    end
  end
  -- fallback: scan for a matching type
  for _, p in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(p)
    if t == "me_bridge" or t == "meBridge" then
      return peripheral.wrap(p)
    end
  end
  return nil
end

local bridge = tryAttachBridge()

-- ====== STATE ======
local state = {
  page = 1,
  perPage = 12,

  selectedIndex = nil,
  selectedName = nil,

  armed = cfg.globalAllow,
  screenStop = cfg.interlocks.screenStop or false,

  lockoutReasons = {},

  status = {},

  pageName = "DASH", -- DASH | SLAVE | RULES
  rulesPage = 1,

  -- rule engine
  rule = {
    nextScanAt = 0,
    lastScanAt = nil,
    scanNow = true,
    counts = {},        -- counts[itemName] = number
    lastDesired = {},   -- lastDesired[slave] = "ON"|"OFF"
    lastSent = {},      -- lastSent[slave] = "ON"|"OFF" (to reduce spam)
  },
}

-- ====== REDNET SEND ======
local function sendToSlave(slaveName, kind, value)
  local payload = (kind or "").."|"..(slaveName or "").."|"..(value or "")
  local msg = { kind = kind, slave = slaveName, value = value, s = sig(cfg.key, payload) }
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

-- ====== INTERLOCKS (ME POWER) ======
local function getMeStoredAndCapacity()
  if not bridge then return nil end

  -- You demonstrated these exist:
  --   bridge.getStoredEnergy()
  --   bridge.getEnergyCapacity()
  local stored = safeCall(bridge.getStoredEnergy)
  local cap = safeCall(bridge.getEnergyCapacity)

  if type(stored) ~= "number" or type(cap) ~= "number" then
    -- fallback to alt API names if present
    stored = safeCall(bridge.getEnergyStorage)
    cap = safeCall(bridge.getMaxEnergyStorage)
  end

  if type(stored) ~= "number" or type(cap) ~= "number" then
    return nil
  end

  return stored, cap
end

local function computeMePct()
  local stored, cap = getMeStoredAndCapacity()
  if not stored or not cap or cap <= 0 then return nil end
  return stored / cap, stored, cap
end

local function computeLockoutReasons()
  local reasons = {}

  local pct, stored, cap = computeMePct()
  if pct ~= nil then
    local minPct = cfg.me.minPct or ME_MIN_PCT
    if pct < minPct then
      table.insert(reasons, ("ME LOW (%.0f%% < %.0f%%)"):format(pct*100, minPct*100))
    end
  else
    -- if we can't read ME power, do NOT lock out by default; just warn in UI
  end

  if state.screenStop then table.insert(reasons, "SCREEN STOP") end
  if not state.armed then table.insert(reasons, "DISARMED") end

  state.lockoutReasons = reasons
end

local function isLockedOut()
  return #state.lockoutReasons > 0
end

-- ====== ME ITEM COUNT CACHE ======
local function meCount(itemName)
  if not bridge then return nil end
  local it = safeCall(bridge.getItem, { name = itemName })
  if not it then return 0 end
  return it.count or it.amount or 0
end

local function buildTrackedItemSet()
  local set = {}
  for _, slave in ipairs(cfg.slaves) do
    local sc = cfg.slave_cfg[slave]
    if sc and sc.rules then
      for _, r in ipairs(sc.rules.on_any or {}) do
        if r.item then set[r.item] = true end
      end
      for _, r in ipairs(sc.rules.off_all or {}) do
        if r.item then set[r.item] = true end
      end
    end
  end
  return set
end

local function scanAllTrackedItems()
  if not bridge then
    state.rule.counts = {}
    state.rule.lastScanAt = os.clock()
    return
  end

  local set = buildTrackedItemSet()
  local counts = {}
  for itemName, _ in pairs(set) do
    local cnt = meCount(itemName)
    counts[itemName] = cnt or 0
  end

  state.rule.counts = counts
  state.rule.lastScanAt = os.clock()
end

local function countOf(itemName)
  return (state.rule.counts and state.rule.counts[itemName]) or 0
end

-- ====== RULE EVALUATION ======
local function anyBelow(on_any)
  if not on_any or #on_any == 0 then return false end
  for _, r in ipairs(on_any) do
    local item = r.item
    local low = tonumber(r.low)
    if item and low then
      if countOf(item) < low then
        return true
      end
    end
  end
  return false
end

local function allAbove(off_all)
  if not off_all or #off_all == 0 then return false end
  for _, r in ipairs(off_all) do
    local item = r.item
    local high = tonumber(r.high)
    if item and high then
      if not (countOf(item) > high) then
        return false
      end
    end
  end
  return true
end

local function computeDesiredForSlave(slave)
  local sc = cfg.slave_cfg[slave] or { mode = "AUTO", rules = { on_any = {}, off_all = {} } }
  local mode = sc.mode or "AUTO"

  if isLockedOut() then return "OFF", "LOCKOUT" end

  if mode == "FORCEOFF" then
    return "OFF", "FORCEOFF"
  elseif mode == "FORCEON" then
    return "ON", "FORCEON"
  end

  -- AUTO hysteresis:
  local last = state.rule.lastDesired[slave] or "OFF"
  local onCond = anyBelow(sc.rules.on_any)
  local offCond = allAbove(sc.rules.off_all)

  if last == "OFF" then
    if onCond then
      return "ON", "AUTO"
    else
      return "OFF", "AUTO"
    end
  else
    -- last ON
    if offCond then
      return "OFF", "AUTO"
    else
      return "ON", "AUTO"
    end
  end
end

local function applyDesired(slave, desired, why)
  state.rule.lastDesired[slave] = desired

  state.status[slave] = state.status[slave] or {}
  state.status[slave].desired = desired
  state.status[slave].reason = why or state.status[slave].reason

  -- Send only when it changes (reduce spam)
  if state.rule.lastSent[slave] ~= desired then
    sendToSlave(slave, "CMD", desired)
    state.rule.lastSent[slave] = desired
  end
end

local function forceAllOff()
  for _,name in ipairs(cfg.slaves) do
    sendToSlave(name, "CMD", "OFF")
    state.rule.lastSent[name] = "OFF"
    state.rule.lastDesired[name] = "OFF"
    state.status[name] = state.status[name] or {}
    state.status[name].desired = "OFF"
  end
end

-- ====== UI PRIMITIVES ======
local function writeAt(x,y,text,fg,bg)
  if bg then mon.setBackgroundColor(bg) end
  if fg then mon.setTextColor(fg) end
  mon.setCursorPos(x,y); mon.write(text)
  mon.setTextColor(colors.white); mon.setBackgroundColor(colors.black)
end

local function fillLine(y,bg)
  mon.setCursorPos(1,y)
  mon.setBackgroundColor(bg or colors.black)
  mon.clearLine()
  mon.setBackgroundColor(colors.black)
end

local function inRect(x,y, rx,ry, rw,rh)
  return x>=rx and x<=rx+rw-1 and y>=ry and y<=ry+rh-1
end

-- ====== LAYOUTS ======
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
    {id="SCAN",  label= "RULE SCAN"},
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
      if c.key == "reason" then c.w = c.w + extra end
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
    {id="SCAN",  label="RULE SCAN"},
    {id="AUTO",  label="AUTO"},
    {id="FON",   label="FORCE ON"},
    {id="FOFF",  label="FORCE OFF"},
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

-- ====== RENDER COMMON HEADER ======
local function drawHeader()
  computeLockoutReasons()

  local w,h = mon.getSize()
  ui.w, ui.h = w,h

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.clear()

  fillLine(1, colors.gray)
  writeAt(2,1,"Spawner Master", colors.black, colors.gray)

  local rightText
  local pct, stored, cap = computeMePct()
  if pct ~= nil then
    rightText = ("ME=%.0f%%  (%d/%d)"):format(pct*100, stored, cap)
  else
    rightText = "ME=?? (bridge?)"
  end
  writeAt(math.max(2, w-#rightText-1), 1, rightText, colors.black, colors.gray)

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
    if b.id == "SCAN" then bg = colors.cyan; fg = colors.black end
    if b.id == "QUERY" then bg = colors.yellow; fg = colors.black end
    if b.id == "RULES" then bg = colors.lightBlue; fg = colors.black end
    if b.id == "PREV" or b.id == "NEXT" then bg = colors.gray; fg = colors.white end

    if b.id == "BACK" then bg = colors.gray; fg = colors.white end
    if b.id == "AUTO" then bg = colors.lime; fg = colors.black end
    if b.id == "FON" then bg = colors.orange; fg = colors.black end
    if b.id == "FOFF" then bg = colors.orange; fg = colors.black end

    writeAt(b.x,b.y, padRight(b.label, b.w), fg, bg)
  end
end

-- ====== DASHBOARD PAGE ======
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

    local mode = (cfg.slave_cfg[name] and cfg.slave_cfg[name].mode) or "AUTO"

    local row = {
      name = name,
      mode = mode,
      actual = st.actual or "--",
      desired = st.desired or state.rule.lastDesired[name] or "--",
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

-- ====== SLAVE DETAIL PAGE ======
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

  local age = "--"
  if state.rule.lastScanAt then
    age = string.format("%.1fs", os.clock() - state.rule.lastScanAt)
  end

  writeAt(2,5, ("Slave: %s"):format(name), colors.white)
  writeAt(2,6, ("Mode: %s"):format(sc.mode or "AUTO"), colors.white)
  writeAt(2,7, ("State: %s   Want: %s"):format(st.actual or "--", st.desired or state.rule.lastDesired[name] or "--"), colors.white)
  writeAt(2,8, ("Reason: %s"):format(st.reason or "--"), colors.white)
  writeAt(2,9, ("Rule scan age: %s"):format(age), colors.gray)

  writeAt(2,11,"ON triggers (OR):  (ANY item < low)", colors.cyan)
  local y = 12
  local shown = 0
  for _,r in ipairs(sc.rules.on_any or {}) do
    if y >= h-1 then break end
    local cnt = countOf(r.item)
    local line = string.format("- %s  cnt=%d  < %s", tostring(r.item), tonumber(cnt) or 0, tostring(r.low))
    writeAt(2,y,line, colors.white); y=y+1; shown=shown+1
  end
  if shown == 0 then writeAt(2,y,"(none)", colors.gray); y=y+1 end

  y = y + 1
  writeAt(2,y,"OFF triggers (AND): (ALL items > high)", colors.cyan); y=y+1
  shown = 0
  for _,r in ipairs(sc.rules.off_all or {}) do
    if y >= h-1 then break end
    local cnt = countOf(r.item)
    local line = string.format("- %s  cnt=%d  > %s", tostring(r.item), tonumber(cnt) or 0, tostring(r.high))
    writeAt(2,y,line, colors.white); y=y+1; shown=shown+1
  end
  if shown == 0 then writeAt(2,y,"(none)", colors.gray) end
end

-- ====== RULES PAGE (READ-ONLY VIEW) ======
local function drawRules()
  computeLayoutRules()
  drawHeader()
  drawButtons()

  local w,h = mon.getSize()
  writeAt(2,5,"RULES (read-only). Edit via terminal rule configurator.", colors.white)
  writeAt(2,6,("ME min pct cutoff: %.0f%%"):format((cfg.me.minPct or ME_MIN_PCT)*100), colors.white)

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

-- ====== ACTIONS ======
local function doArmToggle()
  state.armed = not state.armed
  cfg.globalAllow = state.armed
  save(cfg)
  if not state.armed then forceAllOff() end
end

local function doStopToggle()
  state.screenStop = not state.screenStop
  cfg.interlocks.screenStop = state.screenStop
  save(cfg)
  if state.screenStop then forceAllOff() end
end

local function doRuleScanNow()
  state.rule.scanNow = true
  state.rule.nextScanAt = 0
end

local function gotoPage(name)
  state.pageName = name
end

local function setSlaveMode(slaveName, mode)
  if not slaveName then return end
  cfg.slave_cfg[slaveName] = cfg.slave_cfg[slaveName] or { mode = "AUTO", rules={on_any={}, off_all={}} }
  cfg.slave_cfg[slaveName].mode = mode
  save(cfg)
  -- force re-eval soon
  doRuleScanNow()
end

-- ====== RECEIVER LOOP ======
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

-- ====== RULE ENGINE LOOP ======
local function ruleLoop()
  -- initial scan immediately
  state.rule.scanNow = true
  state.rule.nextScanAt = 0

  while true do
    computeLockoutReasons()

    local now = os.clock()
    if state.rule.scanNow or now >= (state.rule.nextScanAt or 0) then
      state.rule.scanNow = false
      state.rule.nextScanAt = now + RULE_TICK_SEC

      -- 1) refresh ME item cache
      scanAllTrackedItems()

      -- 2) compute + apply desired for each slave
      for _, slave in ipairs(cfg.slaves) do
        local desired, why = computeDesiredForSlave(slave)
        applyDesired(slave, desired, why)
      end

      -- optional: request status after commanding, to refresh actual quickly
      requestStatusAll()
    end

    -- if lockout just became true, slam everything off
    if isLockedOut() then
      forceAllOff()
    end

    sleep(0.1)
  end
end

-- ====== TOUCH HANDLERS ======
local function handleButtons(x,y)
  for _,b in ipairs(ui.buttons) do
    if inRect(x,y, b.x,b.y,b.w,b.h) then
      if state.pageName == "DASH" then
        if b.id == "ARM" then doArmToggle()
        elseif b.id == "STOP" then doStopToggle()
        elseif b.id == "SCAN" then doRuleScanNow()
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
        elseif b.id == "SCAN" then doRuleScanNow()
        elseif b.id == "AUTO" then setSlaveMode(name, "AUTO")
        elseif b.id == "FON" then setSlaveMode(name, "FORCEON")
        elseif b.id == "FOFF" then setSlaveMode(name, "FORCEOFF")
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

-- ====== UI LOOP ======
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

-- ====== STARTUP ======
-- Prime desired states to OFF so AUTO doesn't start in a weird state
for _, name in ipairs(cfg.slaves) do
  state.rule.lastDesired[name] = "OFF"
  state.rule.lastSent[name] = nil
end

-- do one scan quickly
state.rule.scanNow = true

parallel.waitForAny(uiLoop, receiverLoop, ruleLoop)
