-- startup.lua (MASTER)
-- Spawner Master + Hub lockout + redstone-based cap limiter
--
-- FIXES:
--  1) NO require("hub_client") (your hub_client.lua is a standalone program, not a module)
--  2) No UI freeze: hub + spawner traffic handled via one rednet_message dispatcher loop
--  3) Lockout mismatch fixed: "Reason" column comes from rule-engine reason, not stale slave status
--  4) RESTORED: RESET/RESUME button (resends desired states, re-queries hub state/players, requests slave status)
--
-- Behavior:
--  - Locks out unless at least one allowed player is online (from hub state/events)
--  - Cap limiter from hub redstone level:
--      lvl 15->1, 14->2, 13->3, 12->4, 11->5, 10->6, <=9 unlimited
--  - FORCEON bypasses limiter but consumes slots first (AUTO gets remaining slots)

local CONFIG = "master.cfg"

-- ====== TUNABLES ======
local RULE_TICK_SEC   = 1.0
local ME_POLL_SEC     = 0.5
local UI_REFRESH_SEC  = 0.25
local ME_MIN_PCT      = 0.50

-- Hub
local HUB_PROTO             = "sam_hub_v1"
local HUB_NAME              = "MainHub"    -- nil to accept any
local HUB_DISCOVER_EVERY_SEC = 3.0
local HUB_QUERY_TIMEOUT_SEC  = 2.5
local HUB_DEAD_AFTER_SEC     = 5.0

-- Allowed players gate (ANY online -> allowed)
local ALLOWED_PLAYERS = {
  Samuel12345678 = true,
  Amball2000     = true,
  josherage      = true,
}

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

local function safeCall(fn, ...)
  local ok, a, b, c, d = pcall(fn, ...)
  if not ok then return nil end
  return a, b, c, d
end

local function sig(key, payload)
  local s = tostring(payload) .. "|" .. tostring(key)
  local h = 0
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 2147483647
  end
  return tostring(h)
end

local function protoFromKey(key)
  return "sp_" .. sig(key, "proto"):sub(1, 8)
end

local function padRight(s, n)
  s = tostring(s or "")
  if #s > n then return s:sub(1, n) end
  return s .. string.rep(" ", n - #s)
end

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function now()
  return os.clock()
end

local function ts()
  return textutils.formatTime(os.time(), true)
end

local function log(msg)
  print(("[%s] %s"):format(ts(), msg))
end

-- ====== BOOTSTRAP CFG ======
local cfg = loadCfg()
if not cfg then
  term.clear(); term.setCursorPos(1,1)
  print("No " .. CONFIG .. " found.")
  print("Create it with your editor programs first (Master_config_editor.lua / rules_configurator.lua).")
  return
end

cfg.slaves = cfg.slaves or {}
cfg.key = cfg.key or ""
cfg.globalAllow = cfg.globalAllow ~= false
cfg.me = cfg.me or {}
cfg.me.minPct = cfg.me.minPct or ME_MIN_PCT
cfg.interlocks = cfg.interlocks or { screenStop = false }

cfg.slave_cfg = cfg.slave_cfg or {}
for _, name in ipairs(cfg.slaves) do
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
  saveCfg(cfg)
  print("Key saved to " .. CONFIG)
  sleep(0.8)
end

-- Private spawner protocol (must match slave.lua)
local PROTOCOL = cfg.protocol or protoFromKey(cfg.key)
if cfg.protocol ~= PROTOCOL then
  cfg.protocol = PROTOCOL
  saveCfg(cfg)
end

if not openModem() then error("No modem found.") end

local mon = peripheral.find("monitor")
if not mon then error("No monitor found.") end
mon.setTextScale(0.5)

-- ====== ME BRIDGE (Advanced Peripherals) ======
local function tryAttachBridge()
  if peripheral.isPresent("right") and peripheral.getType("right") == "me_bridge" then
    return peripheral.wrap("right")
  end
  for _, p in ipairs(peripheral.getNames()) do
    if peripheral.getType(p) == "me_bridge" then
      return peripheral.wrap(p)
    end
  end
  return nil
end
local bridge = tryAttachBridge()

-- ====== STATE ======
local state = {
  pageName = "DASH", -- DASH | SLAVE | RULES
  page = 1,
  perPage = 8,
  rulesPage = 1,

  selectedIndex = nil,
  selectedName  = nil,

  armed      = cfg.globalAllow,
  screenStop = cfg.interlocks.screenStop or false,

  -- slave runtime status + ids
  status = {},        -- [name] = { actual, last, side, enabled }
  slaveIds = {},      -- [name] = rednet sender id

  -- rule engine
  rule = {
    nextScanAt   = 0,
    lastScanAt   = nil,
    scanNow      = true,
    counts       = {},
    lastDesired  = {},  -- [name] = "ON"/"OFF"
    lastSent     = {},  -- [name] = "ON"/"OFF"
    reason       = {},  -- [name] = "AUTO"/"FORCEON"/"LOCKOUT"/"CAP"/etc (authoritative for UI)
  },

  -- cached ME + lockout strings
  me = {
    pct = nil,
    stored = nil,
    cap = nil,
    headerRight = "ME=?? (bridge?)",
    lockout = false,
    lockoutReasons = {},
    lockoutLine = "LOCKOUT: NONE",
    lockoutBg = colors.green,
    lockoutFg = colors.black,
  },

  -- hub gate + cap limiter
  hub = {
    id = nil,
    name = nil,
    level = nil,
    playersSet = {},      -- [username]=true
    playersKnown = false, -- true after state/players query OR event with msg.players snapshot
    allowedOnline = false,
    cap = nil,
    lastEventAt = nil,
    needQueryPlayers = false,
    needQueryState = false,
  },

  -- UI caching
  ui = {
    w = 0, h = 0,
    buttons = {},
    cols = {},
    tableTopY = 5,
    footerY = 0,
  },

  _lastHeaderLine1 = nil,
  _lastHeaderLine2 = nil,
}

-- ====== HUB HELPERS ======
local function markHubDead(reason)
  -- clear hub identity + truth so we fall back to safe lockout
  state.hub.id = nil
  state.hub.name = nil
  state.hub.level = nil
  state.hub.cap = nil

  state.hub.playersSet = {}
  state.hub.playersKnown = false
  state.hub.allowedOnline = false

  state.hub.lastEventAt = nil
  state.hub.needQueryState = false
  state.hub.needQueryPlayers = false

  log("Hub DEAD -> lockout (" .. tostring(reason or "timeout") .. ")")
  computeLockoutStrings()
  doRuleScanNow()
end

local function capFromLevel(level)
  if type(level) ~= "number" then return nil end
  if level <= 9 then return 999999 end -- unlimited
  local cap = 16 - level -- 15->1, 14->2, ..., 10->6
  if cap < 1 then cap = 1 end
  return cap
end

local function setPlayersFromList(list)
  state.hub.playersSet = {}
  if type(list) == "table" then
    for _, u in ipairs(list) do state.hub.playersSet[u] = true end
  end
  state.hub.playersKnown = true

  local ok = false
  for name, _ in pairs(ALLOWED_PLAYERS) do
    if state.hub.playersSet[name] then ok = true break end
  end
  state.hub.allowedOnline = ok
end

local function hubLineRight()
  local lvl = state.hub.level
  local cap = state.hub.cap
  local known = state.hub.playersKnown and "P:OK" or "P:??"
  local allow = state.hub.allowedOnline and "ALLOW" or "NOALLOW"
  local capStr
  if cap == nil then
    capStr = "cap=?"
  elseif cap >= 999999 then
    capStr = "cap=∞"
  else
    capStr = "cap=" .. tostring(cap)
  end
  return ("Hub=%s %s %s %s"):format(tostring(lvl), capStr, known, allow)
end

local function hubSendRegister()
  if not state.hub.id then return end
  rednet.send(state.hub.id, {
    type = "register",
    subs = {
      redstone = { anyChange = true },
      players  = { join = {"Samuel12345678","Amball2000","josherage"}, leave={"Samuel12345678","Amball2000","josherage"} },
    }
  }, HUB_PROTO)
end

local function hubSendDiscover()
  rednet.broadcast({ type = "hub_discover" }, HUB_PROTO)
end

local function hubSendQueryState()
  if not state.hub.id then return end
  rednet.send(state.hub.id, { type="query", q="state" }, HUB_PROTO)
end

local function hubSendQueryPlayers()
  if not state.hub.id then return end
  rednet.send(state.hub.id, { type="query", q="players" }, HUB_PROTO)
end

-- ====== REDNET SEND (spawner, targeted) ======
local function makeMsg(kind, slaveName, value, valueStr)
  local vstr = valueStr or ((type(value) == "string") and value or tostring(value or ""))
  local payload = (kind or "") .. "|" .. (slaveName or "") .. "|" .. vstr
  return { kind = kind, slave = slaveName, value = value, valueStr = vstr, s = sig(cfg.key, payload) }
end

local function sendToSlave(slaveName, kind, value)
  local id = state.slaveIds[slaveName]
  local msg = makeMsg(kind, slaveName, value)
  if id then
    rednet.send(id, msg, PROTOCOL)
  else
    rednet.broadcast(msg, PROTOCOL) -- rare: before registration
  end
end

local function requestStatusOne(name)
  if name and name ~= "" then
    sendToSlave(name, "STATUS_REQ", "1")
  end
end

local function requestStatusAll()
  for _, name in ipairs(cfg.slaves) do
    requestStatusOne(name)
  end
end

-- ====== LOCKOUT / ME CACHE ======
local function computeLockoutStrings()
  local reasons = {}

  if state.me.pct ~= nil then
    local minPct = cfg.me.minPct or ME_MIN_PCT
    if state.me.pct < minPct then
      table.insert(reasons, ("ME LOW (%.0f%% < %.0f%%)"):format(state.me.pct * 100, minPct * 100))
    end
  end

  if state.screenStop then table.insert(reasons, "SCREEN STOP") end
  if not state.armed then table.insert(reasons, "DISARMED") end

  -- Hub players gate:
  if not state.hub.playersKnown then
    table.insert(reasons, "PLAYERS UNKNOWN")
  elseif not state.hub.allowedOnline then
    table.insert(reasons, "NO ALLOWED PLAYER")
  end

  state.me.lockoutReasons = reasons
  state.me.lockout = (#reasons > 0)

  if state.me.lockout then
    state.me.lockoutLine = "LOCKOUT: " .. table.concat(reasons, " | ")
    state.me.lockoutBg = colors.red
    state.me.lockoutFg = colors.white
  else
    state.me.lockoutLine = "LOCKOUT: NONE"
    state.me.lockoutBg = colors.green
    state.me.lockoutFg = colors.black
  end
end

local function isLockedOut()
  return state.me.lockout
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
    state.rule.lastScanAt = now()
    return
  end

  local set = buildTrackedItemSet()
  local counts = {}
  for itemName, _ in pairs(set) do
    local cnt = meCount(itemName)
    counts[itemName] = cnt or 0
  end

  state.rule.counts = counts
  state.rule.lastScanAt = now()
end

local function countOf(itemName)
  return (state.rule.counts and state.rule.counts[itemName]) or 0
end

-- ====== RULE EVALUATION ======
local function anyBelow(on_any)
  if not on_any or #on_any == 0 then return false end
  for _, r in ipairs(on_any) do
    local item = r.item
    local low  = tonumber(r.low)
    if item and low then
      if countOf(item) < low then return true end
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
      if not (countOf(item) > high) then return false end
    end
  end
  return true
end

-- Computes base desire (ignores cap limiter)
local function computeBaseDesired(slave)
  local sc = cfg.slave_cfg[slave] or { mode = "AUTO", rules = { on_any = {}, off_all = {} } }
  local mode = sc.mode or "AUTO"

  if isLockedOut() then return "OFF", "LOCKOUT", mode end

  if mode == "FORCEOFF" then return "OFF", "FORCEOFF", mode end
  if mode == "FORCEON"  then return "ON",  "FORCEON",  mode end

  -- AUTO hysteresis
  local last = state.rule.lastDesired[slave] or "OFF"
  local onCond  = anyBelow(sc.rules.on_any)
  local offCond = allAbove(sc.rules.off_all)

  if last == "OFF" then
    if onCond then return "ON", "AUTO", mode end
    return "OFF", "AUTO", mode
  else
    if offCond then return "OFF", "AUTO", mode end
    return "ON", "AUTO", mode
  end
end

-- Cap limiter:
--  - FORCEON always allowed but consumes slots first
--  - remaining slots go to AUTO "ON" in cfg.slaves order
local function applyLimiter(baseDesired, baseWhy, modeMap)
  local finalDesired, finalWhy = {}, {}

  for name, d in pairs(baseDesired) do
    finalDesired[name] = d
    finalWhy[name] = baseWhy[name]
  end

  if isLockedOut() then return finalDesired, finalWhy end

  local cap = state.hub.cap
  if cap == nil or cap >= 999999 then
    return finalDesired, finalWhy
  end

  local forceOnCount = 0
  for _, name in ipairs(cfg.slaves) do
    if modeMap[name] == "FORCEON" and finalDesired[name] == "ON" then
      forceOnCount = forceOnCount + 1
    end
  end

  local remaining = cap - forceOnCount
  if remaining < 0 then remaining = 0 end

  local allowedAutoOn = 0
  for _, name in ipairs(cfg.slaves) do
    if modeMap[name] == "AUTO" and finalDesired[name] == "ON" then
      if allowedAutoOn < remaining then
        allowedAutoOn = allowedAutoOn + 1
      else
        finalDesired[name] = "OFF"
        finalWhy[name] = "CAP"
      end
    end
  end

  return finalDesired, finalWhy
end

local function applyDesired(slave, desired, why)
  state.rule.lastDesired[slave] = desired
  state.rule.reason[slave] = why or "--"

  -- send if changed
  if state.rule.lastSent[slave] ~= desired then
    sendToSlave(slave, "CMD", desired)
    state.rule.lastSent[slave] = desired
  end
end

local function forceAllOff()
  for _, name in ipairs(cfg.slaves) do
    sendToSlave(name, "CMD", "OFF")
    state.rule.lastSent[name] = "OFF"
    state.rule.lastDesired[name] = "OFF"
    state.rule.reason[name] = "LOCKOUT"
  end
end

-- ====== UI PRIMITIVES ======
local function writeAt(x, y, text, fg, bg)
  if bg then mon.setBackgroundColor(bg) end
  if fg then mon.setTextColor(fg) end
  mon.setCursorPos(x, y)
  mon.write(text)
end

local function paintLine(y, bg, fg, s)
  local w,_ = mon.getSize()
  s = padRight(s, w)
  mon.setCursorPos(1, y)
  mon.setBackgroundColor(bg)
  mon.setTextColor(fg)
  mon.write(s)
end

local function inRect(x, y, rx, ry, rw, rh)
  return x >= rx and x <= rx + rw - 1 and y >= ry and y <= ry + rh - 1
end

-- ====== LAYOUT ======
local function computeLayoutDashboard()
  local w,h = mon.getSize()
  state.ui.w, state.ui.h = w,h
  state.ui.tableTopY = 5
  state.ui.footerY = h

  local maxRows = math.max(1, state.ui.footerY - state.ui.tableTopY - 1)
  state.perPage = maxRows

  local buttons = {
    { id="ARM",    label = state.armed and "DISARM" or "ARM" },
    { id="STOP",   label = state.screenStop and "CLEAR STOP" or "STOP" },
    { id="SCAN",   label = "RULE SCAN" },
    { id="RESUME", label = "RESET/RESUME" },
    { id="QUERY",  label = "QUERY" },
    { id="RULES",  label = "RULES" },
    { id="PREV",   label = "<" },
    { id="NEXT",   label = ">" },
  }

  local bx = 2
  for _, b in ipairs(buttons) do
    local bw = math.max(#b.label + 2, 8)
    b.x, b.y, b.w, b.h = bx, 3, bw, 1
    bx = bx + bw + 1
  end

  local cols = {
    { key="name",    title="Name",   min=32 },
    { key="mode",    title="Mode",   min=8  },
    { key="actual",  title="State",  min=5  },
    { key="desired", title="Want",   min=5  },
    { key="reason",  title="Reason", min=10 },
    { key="age",     title="Age",    min=6  },
  }

  local sep = 1
  local function totalMin()
    local t = 2
    for _, c in ipairs(cols) do t = t + c.min + sep end
    return t
  end

  while totalMin() > w and #cols > 4 do table.remove(cols) end

  for _, c in ipairs(cols) do c.w = c.min end
  local extra = w - totalMin()
  if extra > 0 then
    for _, c in ipairs(cols) do
      if c.key == "reason" then c.w = c.w + extra end
    end
  end

  local x = 2
  for _, c in ipairs(cols) do
    c.x = x
    x = x + c.w + sep
  end

  state.ui.buttons = buttons
  state.ui.cols = cols
end

local function computeLayoutSlave()
  local w,h = mon.getSize()
  state.ui.w, state.ui.h = w,h

  local buttons = {
    { id="BACK",   label="BACK" },
    { id="QUERY",  label="QUERY" },
    { id="SCAN",   label="RULE SCAN" },
    { id="RESUME", label="RESET/RESUME" },
    { id="AUTO",   label="AUTO" },
    { id="FON",    label="FORCE ON" },
    { id="FOFF",   label="FORCE OFF" },
  }

  local bx = 2
  for _, b in ipairs(buttons) do
    local bw = math.max(#b.label + 2, 8)
    b.x, b.y, b.w, b.h = bx, 3, bw, 1
    bx = bx + bw + 1
  end

  state.ui.buttons = buttons
end

local function computeLayoutRules()
  local w,h = mon.getSize()
  state.ui.w, state.ui.h = w,h

  local buttons = {
    { id="BACK", label="BACK" },
    { id="PREV", label="<" },
    { id="NEXT", label=">" },
  }

  local bx = 2
  for _, b in ipairs(buttons) do
    local bw = math.max(#b.label + 2, 6)
    b.x, b.y, b.w, b.h = bx, 3, bw, 1
    bx = bx + bw + 1
  end

  state.ui.buttons = buttons
end

-- ====== HEADER PAINT (DIFF-BASED) ======
local function composeHeaderLine1()
  local w,_ = mon.getSize()
  local left = "Spawner Master"
  local right = (state.me.headerRight or "ME=??") .. "  " .. hubLineRight()
  local gap = w - (#left + #right)
  if gap < 1 then
    right = right:sub(1, math.max(0, w - #left - 1))
    gap = 1
  end
  return left .. string.rep(" ", gap) .. right
end

local function headerTickPaint()
  local w,_ = mon.getSize()

  local l1 = composeHeaderLine1()
  if l1 ~= state._lastHeaderLine1 then
    paintLine(1, colors.gray, colors.black, l1)
    state._lastHeaderLine1 = l1
  end

  local l2 = padRight(state.me.lockoutLine or "LOCKOUT: NONE", w)
  if l2 ~= state._lastHeaderLine2 then
    paintLine(2, state.me.lockoutBg, state.me.lockoutFg, l2)
    state._lastHeaderLine2 = l2
  end

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
end

-- ====== BUTTONS DRAW ======
local function drawButtons()
  for _, b in ipairs(state.ui.buttons) do
    local bg, fg = colors.lightGray, colors.black

    if b.id == "ARM" then bg = state.armed and colors.orange or colors.lime end
    if b.id == "STOP" then bg = colors.red; fg = colors.white end
    if b.id == "SCAN" then bg = colors.cyan; fg = colors.black end
    if b.id == "RESUME" then bg = colors.purple; fg = colors.white end
    if b.id == "QUERY" then bg = colors.yellow; fg = colors.black end
    if b.id == "RULES" then bg = colors.lightBlue; fg = colors.black end
    if b.id == "PREV" or b.id == "NEXT" then bg = colors.gray; fg = colors.white end
    if b.id == "BACK" then bg = colors.gray; fg = colors.white end
    if b.id == "AUTO" then bg = colors.lime; fg = colors.black end
    if b.id == "FON" or b.id == "FOFF" then bg = colors.orange; fg = colors.black end

    writeAt(b.x, b.y, padRight(b.label, b.w), fg, bg)
  end
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
end

-- ====== FULL PAGE DRAWS ======
local function fullClearOnce()
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.clear()
  state._lastHeaderLine1 = nil
  state._lastHeaderLine2 = nil
end

local function drawDashboardFull()
  computeLayoutDashboard()
  fullClearOnce()
  headerTickPaint()
  drawButtons()

  for _, c in ipairs(state.ui.cols) do
    writeAt(c.x, 4, padRight(c.title, c.w), colors.cyan, colors.black)
  end

  local total = #cfg.slaves
  local pages = math.max(1, math.ceil(total / state.perPage))
  state.page = clamp(state.page, 1, pages)

  local startIdx = (state.page - 1) * state.perPage + 1
  local endIdx = math.min(total, startIdx + state.perPage - 1)

  local y = state.ui.tableTopY
  for i = startIdx, endIdx do
    local name = cfg.slaves[i]
    local st = state.status[name] or {}
    local mode = (cfg.slave_cfg[name] and cfg.slave_cfg[name].mode) or "AUTO"

    local age = "--"
    if st.last then age = string.format("%.1fs", now() - st.last) end

    local row = {
      name = name,
      mode = mode,
      actual = st.actual or "--",
      desired = state.rule.lastDesired[name] or "--",
      reason = state.rule.reason[name] or "--",
      age = age,
    }

    local selected = (state.selectedIndex == i)
    local bg = selected and colors.gray or colors.black
    local fg = selected and colors.black or colors.white

    for _, c in ipairs(state.ui.cols) do
      writeAt(c.x, y, padRight(row[c.key] or "", c.w), fg, bg)
    end
    y = y + 1
  end

  local foot = ("Page %d/%d  (%d-%d of %d)"):format(state.page, pages, startIdx, endIdx, total)
  writeAt(2, state.ui.footerY, padRight(foot, state.ui.w), colors.gray, colors.black)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
end

local function drawSlaveFull()
  computeLayoutSlave()
  fullClearOnce()
  headerTickPaint()
  drawButtons()

  local w,h = mon.getSize()
  local name = state.selectedName
  if not name then
    writeAt(2, 5, "No slave selected. Tap a row first.", colors.red, colors.black)
    return
  end

  local sc = cfg.slave_cfg[name] or { mode="AUTO", rules={on_any={}, off_all={}} }
  local st = state.status[name] or {}

  local scanAge = "--"
  if state.rule.lastScanAt then scanAge = string.format("%.1fs", now() - state.rule.lastScanAt) end

  writeAt(2,5, ("Slave: %s"):format(name), colors.white, colors.black)
  writeAt(2,6, ("Mode: %s"):format(sc.mode or "AUTO"), colors.white, colors.black)
  writeAt(2,7, ("State: %s   Want: %s"):format(st.actual or "--", state.rule.lastDesired[name] or "--"), colors.white, colors.black)
  writeAt(2,8, ("Reason: %s"):format(state.rule.reason[name] or "--"), colors.white, colors.black)
  writeAt(2,9, ("Rule scan age: %s"):format(scanAge), colors.gray, colors.black)

  writeAt(2,11, "ON triggers (OR):  (ANY item < low)", colors.cyan, colors.black)
  local y = 12
  local shown = 0
  for _, r in ipairs(sc.rules.on_any or {}) do
    if y >= h-1 then break end
    local cnt = countOf(r.item)
    local line = string.format("- %s  cnt=%d  < %s", tostring(r.item), tonumber(cnt) or 0, tostring(r.low))
    writeAt(2,y, padRight(line, w-1), colors.white, colors.black)
    y=y+1; shown=shown+1
  end
  if shown == 0 then
    writeAt(2,y, "(none)", colors.gray, colors.black)
    y=y+1
  end

  y = y + 1
  writeAt(2,y, "OFF triggers (AND): (ALL items > high)", colors.cyan, colors.black)
  y=y+1
  shown = 0
  for _, r in ipairs(sc.rules.off_all or {}) do
    if y >= h-1 then break end
    local cnt = countOf(r.item)
    local line = string.format("- %s  cnt=%d  > %s", tostring(r.item), tonumber(cnt) or 0, tostring(r.high))
    writeAt(2,y, padRight(line, w-1), colors.white, colors.black)
    y=y+1; shown=shown+1
  end
  if shown == 0 then
    writeAt(2,y, "(none)", colors.gray, colors.black)
  end

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
end

local function drawRulesFull()
  computeLayoutRules()
  fullClearOnce()
  headerTickPaint()
  drawButtons()

  local w,h = mon.getSize()
  writeAt(2,5, "RULES (read-only). Edit via terminal rule configurator.", colors.white, colors.black)
  writeAt(2,6, ("ME min pct cutoff: %.0f%%"):format((cfg.me.minPct or ME_MIN_PCT)*100), colors.white, colors.black)

  local rowsTop = 8
  local per = math.max(1, h - rowsTop - 2)
  local total = #cfg.slaves
  local pages = math.max(1, math.ceil(total / per))
  state.rulesPage = clamp(state.rulesPage, 1, pages)

  local startIdx = (state.rulesPage - 1) * per + 1
  local endIdx = math.min(total, startIdx + per - 1)

  writeAt(2,7, "Name                Mode      on_any  off_all", colors.cyan, colors.black)
  local y = rowsTop
  for i = startIdx, endIdx do
    local name = cfg.slaves[i]
    local sc = cfg.slave_cfg[name] or { mode="AUTO", rules={on_any={}, off_all={}} }
    local onN = #(sc.rules.on_any or {})
    local offN = #(sc.rules.off_all or {})
    local line = padRight(name, 18) .. " " .. padRight(sc.mode or "AUTO", 8) .. "  " .. padRight(onN, 6) .. " " .. padRight(offN, 6)
    writeAt(2,y, padRight(line, w-1), colors.white, colors.black)
    y=y+1
  end

  local foot = ("Rules page %d/%d  (%d-%d of %d)"):format(state.rulesPage, pages, startIdx, endIdx, total)
  writeAt(2,h, padRight(foot, w-1), colors.gray, colors.black)

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
end

local function fullRedraw()
  if state.pageName == "DASH" then
    drawDashboardFull()
  elseif state.pageName == "SLAVE" then
    drawSlaveFull()
  else
    drawRulesFull()
  end
end

-- ====== ACTIONS ======
local function doArmToggle()
  state.armed = not state.armed
  cfg.globalAllow = state.armed
  saveCfg(cfg)
  computeLockoutStrings()
  state.rule.scanNow = true
  if not state.armed then forceAllOff() end
end

local function doStopToggle()
  state.screenStop = not state.screenStop
  cfg.interlocks.screenStop = state.screenStop
  saveCfg(cfg)
  computeLockoutStrings()
  state.rule.scanNow = true
  if state.screenStop then forceAllOff() end
end

local function doRuleScanNow()
  state.rule.scanNow = true
  state.rule.nextScanAt = 0
end

local function doResumeNow()
  -- Resend desired states even if lastSent matches (clear lastSent)
  for _, name in ipairs(cfg.slaves) do
    state.rule.lastSent[name] = nil
  end

  -- Force fresh hub truth (one-shot) + resubscribe
  if state.hub.id then
    hubSendRegister()
    state.hub.needQueryState = true
    state.hub.needQueryPlayers = true
  else
    hubSendDiscover()
  end

  -- Request slave status once + rescan rules
  requestStatusAll()
  doRuleScanNow()
end

local function gotoPage(name)
  state.pageName = name
end

local function setSlaveMode(slaveName, mode)
  if not slaveName then return end
  cfg.slave_cfg[slaveName] = cfg.slave_cfg[slaveName] or { mode = "AUTO", rules = { on_any = {}, off_all = {} } }
  cfg.slave_cfg[slaveName].mode = mode
  saveCfg(cfg)
  doRuleScanNow()
end

-- ====== COMMS DISPATCH LOOP (ONE place handles all rednet traffic) ======
local function commsLoop()
  -- discovery tickers
  local tHubDiscover = os.startTimer(0.1) -- quick initial discover
  local tHubQueryDeadline = nil
  local pendingHubQuery = nil
  local tHubHealth = os.startTimer(0.5) -- check twice a second

  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "timer" then
      local tid = a

      -- periodic hub discover until found
      if tid == tHubDiscover then
        if not state.hub.id then
          hubSendDiscover()
          tHubDiscover = os.startTimer(HUB_DISCOVER_EVERY_SEC)
        else
          -- if hub exists, just keep timer slow (still useful if hub reboots)
          tHubDiscover = os.startTimer(HUB_DISCOVER_EVERY_SEC)
        end
      end

      -- hub health check
      if tid == tHubHealth then
        tHubHealth = os.startTimer(0.5)

        if state.hub.id then
          local last = state.hub.lastEventAt
          if (not last) or (now() - last > HUB_DEAD_AFTER_SEC) then
            markHubDead("no reply > " .. HUB_DEAD_AFTER_SEC .. "s")
            -- immediately try rediscover
            hubSendDiscover()
          end
        end
      end

      -- query timeout handling
      if pendingHubQuery and tHubQueryDeadline and tid == tHubQueryDeadline then
        -- timed out
        pendingHubQuery = nil
        tHubQueryDeadline = nil
      end

    elseif ev == "rednet_message" then
      local sender = a
      local msg = b
      local proto = c

      -- ===== Spawner protocol =====
      if proto == PROTOCOL and type(msg) == "table" and msg.kind then
        if msg.kind == "MASTER_DISCOVER" then
          rednet.send(sender, { kind="MASTER_HERE" }, PROTOCOL)

        elseif msg.kind == "REGISTER" and msg.slave then
          local payload = "REGISTER|"..tostring(msg.slave).."|"..tostring(msg.value or "")
          if msg.s == sig(cfg.key, payload) then
            local name = msg.slave
            state.slaveIds[name] = sender

            local exists = false
            for _, n in ipairs(cfg.slaves) do if n == name then exists = true break end end
            if not exists then
              table.insert(cfg.slaves, name)
              cfg.slave_cfg[name] = cfg.slave_cfg[name] or { mode="AUTO", rules={on_any={}, off_all={}} }
              cfg.slave_cfg[name].rules = cfg.slave_cfg[name].rules or { on_any={}, off_all={} }
              cfg.slave_cfg[name].rules.on_any = cfg.slave_cfg[name].rules.on_any or {}
              cfg.slave_cfg[name].rules.off_all = cfg.slave_cfg[name].rules.off_all or {}
              saveCfg(cfg)
              log("Registered NEW slave: " .. name .. " (id " .. sender .. ")")
              fullRedraw()
            else
              log("Registered slave: " .. name .. " (id " .. sender .. ")")
            end

            requestStatusOne(name)
            doRuleScanNow()
          end

        elseif msg.kind == "STATUS_RSP" and msg.slave then
          local vpart = msg.valueStr or tostring(msg.value or "")
          local payload = "STATUS_RSP|"..tostring(msg.slave).."|"..tostring(vpart)
          if msg.s == sig(cfg.key, payload) then
            local name = msg.slave
            local v = msg.value
            state.status[name] = state.status[name] or {}
            if type(v) == "table" then
              state.status[name].actual  = v.actual  or state.status[name].actual
              state.status[name].enabled = v.enabled
              state.status[name].side    = v.side    or state.status[name].side
            end
            state.status[name].last = now()
          end
        end
      end

      -- ===== Hub protocol =====
      if proto == HUB_PROTO and type(msg) == "table" then
        -- any hub-proto message counts as "hub alive"
        -- (if it's actually from the chosen hub id, we’ll also count it below)
        -- discovery replies
        if msg.type == "hub_here" or msg.type == "hub_announce" then
          if (not HUB_NAME) or (msg.name == HUB_NAME) then
            state.hub.lastEventAt = now()
            if state.hub.id ~= sender then
              state.hub.id = sender
              state.hub.name = msg.name
              log("Hub discovered: " .. tostring(msg.name) .. " (id " .. tostring(sender) .. ")")
              hubSendRegister()
              state.hub.needQueryState = true
              state.hub.needQueryPlayers = true
              doRuleScanNow()
            end
          end

        elseif state.hub.id and sender == state.hub.id then
          state.hub.lastEventAt = now()
          if msg.type == "event" then
            if msg.event == "redstone" and type(msg.level) == "number" then
              state.hub.level = msg.level
              state.hub.cap = capFromLevel(msg.level)
              computeLockoutStrings()
              doRuleScanNow()

            elseif msg.event == "playerJoin" or msg.event == "playerLeave" then
              if msg.players ~= nil then
                setPlayersFromList(msg.players)
              else
                -- old hub (no snapshot): safest is mark unknown and do one players query
                state.hub.playersKnown = false
                state.hub.needQueryPlayers = true
              end
              computeLockoutStrings()
              doRuleScanNow()
            end

          elseif msg.type == "state" then
            if type(msg.level) == "number" then
              state.hub.level = msg.level
              state.hub.cap = capFromLevel(msg.level)
            end
            if msg.players ~= nil then
              setPlayersFromList(msg.players)
            end
            computeLockoutStrings()
            doRuleScanNow()

          elseif msg.type == "players" then
            if msg.players ~= nil then
              setPlayersFromList(msg.players)
            end
            computeLockoutStrings()
            doRuleScanNow()
          end
        end
      end
    end
  end
end

-- ====== HUB MAINTENANCE LOOP ======
local function hubMaintenanceLoop()
  while true do
    if state.hub.id then
      if state.hub.needQueryState then
        state.hub.needQueryState = false
        hubSendQueryState()
        -- if it never arrives, we stay in PLAYERS UNKNOWN (safe)
        sleep(0.05)
      end
      if state.hub.needQueryPlayers then
        state.hub.needQueryPlayers = false
        hubSendQueryPlayers()
        sleep(0.05)
      end
    end
    sleep(0.2)
  end
end

-- ====== ME POLL LOOP (CACHED) ======
local function mePollLoop()
  while true do
    if not bridge then bridge = tryAttachBridge() end

    if bridge then
      local stored = safeCall(bridge.getStoredEnergy)
      local cap    = safeCall(bridge.getEnergyCapacity)

      if type(stored) ~= "number" or type(cap) ~= "number" then
        stored = safeCall(bridge.getEnergyStorage)
        cap    = safeCall(bridge.getMaxEnergyStorage)
      end

      if type(stored) == "number" and type(cap) == "number" and cap > 0 then
        state.me.stored = stored
        state.me.cap = cap
        state.me.pct = stored / cap
        state.me.headerRight = ("ME=%.0f%%  (%d/%d)"):format(state.me.pct * 100, stored, cap)
      else
        state.me.pct = nil
        state.me.headerRight = "ME=?? (bridge?)"
      end
    else
      state.me.pct = nil
      state.me.headerRight = "ME=?? (bridge?)"
    end

    computeLockoutStrings()
    sleep(ME_POLL_SEC)
  end
end

-- ====== RULE ENGINE LOOP ======
local function ruleLoop()
  state.rule.scanNow = true
  state.rule.nextScanAt = 0

  while true do
    local t = now()

    if state.rule.scanNow or t >= (state.rule.nextScanAt or 0) then
      state.rule.scanNow = false
      state.rule.nextScanAt = t + RULE_TICK_SEC

      scanAllTrackedItems()

      local baseDesired, baseWhy, modeMap = {}, {}, {}

      for _, slave in ipairs(cfg.slaves) do
        local d, why, mode = computeBaseDesired(slave)
        baseDesired[slave] = d
        baseWhy[slave] = why
        modeMap[slave] = mode
      end

      local finalDesired, finalWhy = applyLimiter(baseDesired, baseWhy, modeMap)

      for _, slave in ipairs(cfg.slaves) do
        applyDesired(slave, finalDesired[slave], finalWhy[slave])
      end

      if isLockedOut() then
        forceAllOff()
      end
    end

    sleep(0.1)
  end
end

-- ====== UI LOOP (EVENT DRIVEN) ======
local function uiLoop()
  for _, name in ipairs(cfg.slaves) do
    state.rule.lastDesired[name] = state.rule.lastDesired[name] or "OFF"
    state.rule.lastSent[name] = nil
    state.rule.reason[name] = state.rule.reason[name] or "--"
  end

  fullRedraw()
  local tUI = os.startTimer(UI_REFRESH_SEC)

  while true do
    local ev, p1, p2, p3 = os.pullEvent()

    if ev == "timer" and p1 == tUI then
      tUI = os.startTimer(UI_REFRESH_SEC)
      headerTickPaint()

    elseif ev == "monitor_touch" then
      local x, y = p2, p3

      if state.pageName == "DASH" then
        computeLayoutDashboard()
      elseif state.pageName == "SLAVE" then
        computeLayoutSlave()
      else
        computeLayoutRules()
      end

      local changed = false

      for _, b in ipairs(state.ui.buttons) do
        if inRect(x, y, b.x, b.y, b.w, b.h) then
          if state.pageName == "DASH" then
            if b.id == "ARM" then doArmToggle(); changed = true
            elseif b.id == "STOP" then doStopToggle(); changed = true
            elseif b.id == "SCAN" then doRuleScanNow(); changed = false
            elseif b.id == "RESUME" then doResumeNow(); changed = false
            elseif b.id == "QUERY" then
              requestStatusAll()
              if state.hub.id then
                state.hub.needQueryState = true
                state.hub.needQueryPlayers = true
              else
                hubSendDiscover()
              end
              changed = false
            elseif b.id == "RULES" then gotoPage("RULES"); changed = true
            elseif b.id == "PREV" then state.page = math.max(1, state.page - 1); changed = true
            elseif b.id == "NEXT" then state.page = state.page + 1; changed = true
            end

          elseif state.pageName == "SLAVE" then
            local name = state.selectedName
            if b.id == "BACK" then gotoPage("DASH"); changed = true
            elseif b.id == "QUERY" then requestStatusOne(name); changed = false
            elseif b.id == "SCAN" then doRuleScanNow(); changed = false
            elseif b.id == "RESUME" then doResumeNow(); changed = false
            elseif b.id == "AUTO" then setSlaveMode(name, "AUTO"); changed = true
            elseif b.id == "FON" then setSlaveMode(name, "FORCEON"); changed = true
            elseif b.id == "FOFF" then setSlaveMode(name, "FORCEOFF"); changed = true
            end

            if name then requestStatusOne(name) end

          else
            if b.id == "BACK" then gotoPage("DASH"); changed = true
            elseif b.id == "PREV" then state.rulesPage = math.max(1, state.rulesPage - 1); changed = true
            elseif b.id == "NEXT" then state.rulesPage = state.rulesPage + 1; changed = true
            end
          end
          break
        end
      end

      if not changed and state.pageName == "DASH" then
        local rowY0 = state.ui.tableTopY
        local idxOnPage = y - rowY0 + 1
        if idxOnPage >= 1 and idxOnPage <= state.perPage then
          local total = #cfg.slaves
          local pages = math.max(1, math.ceil(total / state.perPage))
          state.page = clamp(state.page, 1, pages)
          local startIdx = (state.page - 1) * state.perPage + 1
          local i = startIdx + (idxOnPage - 1)
          if i >= 1 and i <= total then
            state.selectedIndex = i
            state.selectedName = cfg.slaves[i]
            gotoPage("SLAVE")
            changed = true
            requestStatusOne(state.selectedName)
          end
        end
      end

      if changed then
        fullRedraw()
      else
        headerTickPaint()
      end
    end
  end
end

-- ====== STARTUP ======
computeLockoutStrings()

-- Safe default: until hub confirms players snapshot, we remain locked out
state.hub.playersKnown = false
state.hub.allowedOnline = false
state.hub.cap = nil
state.hub.level = nil

-- Kick hub discovery immediately
hubSendDiscover()

-- Ask for status once at boot
requestStatusAll()

parallel.waitForAny(
  uiLoop,
  commsLoop,
  hubMaintenanceLoop,
  ruleLoop,
  mePollLoop
)
