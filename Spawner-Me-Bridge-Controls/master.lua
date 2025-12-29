-- startup.lua (MASTER) - Dashboard + Slave Detail + Rules (read-only)
-- Completed: ME % lockout (<50%), screen STOP latch, ARM/DISARM, FORCEON/FORCEOFF logic, master heartbeats (HB)
-- AUTO currently does nothing (defaults to OFF), but is the placeholder for future rule engine.

local CONFIG   = "master.cfg"
local PROTOCOL = "spawner_ctrl_v3"

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

-- ====== CONFIG BOOTSTRAP ======
local cfg = load()
if not cfg then
  term.clear(); term.setCursorPos(1,1)
  print("No " .. CONFIG .. " found.")
  print("Create it with your editor programs first (slaves.lua / rules.lua).")
  return
end

cfg.slaves = cfg.slaves or {}        -- list of names
cfg.key = cfg.key or ""
cfg.globalAllow = cfg.globalAllow ~= false

-- ME policy:
-- - cutoffPct: lockout if stored/capacity < cutoffPct (default 0.50)
-- - cutoffAbs: optional extra lockout if stored < cutoffAbs (0 disables)
cfg.me = cfg.me or { cutoffPct = 0.50, cutoffAbs = 0 }

cfg.interlocks = cfg.interlocks or { screenStop = false }

-- per-slave config (mode + rules summary). Backwards compatible.
cfg.slave_cfg = cfg.slave_cfg or {}
for _,name in ipairs(cfg.slaves) do
  cfg.slave_cfg[name] = cfg.slave_cfg[name] or { mode = "AUTO", rules = { on_any = {}, off_all = {} } }
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

-- ME Bridge: user confirmed it is on the RIGHT.
local bridge = nil
local function initBridge()
  bridge = nil
  local ok, b = pcall(peripheral.wrap, "right")
  if ok and b then bridge = b end
end
initBridge()

-- ====== STATE ======
local state = {
  -- paging for dashboard slave table
  page = 1,
  perPage = 12,

  -- selection
  selectedIndex = nil,  -- index in cfg.slaves
  selectedName = nil,   -- name string

  -- global controls
  armed = cfg.globalAllow,
  screenStop = cfg.interlocks.screenStop or false,

  -- computed lockouts
  lockoutReasons = {},
  lockedOut = false,

  -- last known statuses (from STATUS_RSP)
  status = {}, -- status[name] = { actual="ON/OFF", enabled=bool, side="back", reason="...", last=os.clock(), hbAge="0.4s" }

  -- desired control computed by master
  desired = {}, -- desired[name] = "ON"|"OFF"
  lastCmd = {}, -- lastCmd[name] = "ON"|"OFF" (what master last sent)

  -- for edge-triggered forceAllOff on entering lockout
  wasLockedOut = false,

  -- simple page system
  pageName = "DASH", -- DASH | SLAVE | RULES
  rulesPage = 1,

  -- ME telemetry
  me = { ok=false, stored=0, cap=0, pct=0, err=nil },
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

-- ====== ME POWER READ ======
local function readMePower()
  if not bridge then
    initBridge()
    if not bridge then
      state.me = { ok=false, stored=0, cap=0, pct=0, err="No meBridge on right" }
      return
    end
  end

  -- Try user-confirmed methods first, then fall back to Advanced Peripherals documented names.
  local stored, cap

  local ok1, r1 = pcall(function() return bridge.getStoredEnergy and bridge.getStoredEnergy() or nil end)
  local ok2, r2 = pcall(function() return bridge.getEnergyCapacity and bridge.getEnergyCapacity() or nil end)

  if ok1 and type(r1) == "number" then stored = r1 end
  if ok2 and type(r2) == "number" then cap = r2 end

  if (not stored) or (not cap) then
    local ok3, r3 = pcall(function() return bridge.getEnergyStorage and bridge.getEnergyStorage() or nil end)
    local ok4, r4 = pcall(function() return bridge.getMaxEnergyStorage and bridge.getMaxEnergyStorage() or nil end)
    if not stored and ok3 and type(r3) == "number" then stored = r3 end
    if not cap and ok4 and type(r4) == "number" then cap = r4 end
  end

  if type(stored) ~= "number" or type(cap) ~= "number" or cap <= 0 then
    state.me = { ok=false, stored=tonumber(stored) or 0, cap=tonumber(cap) or 0, pct=0, err="ME read failed" }
    return
  end

  local pct = stored / cap
  state.me = { ok=true, stored=stored, cap=cap, pct=pct, err=nil }
end

-- ====== INTERLOCKS ======
local function computeLockoutReasons()
  local reasons = {}

  -- Always update ME telemetry before evaluating lockout.
  readMePower()

  -- Treat ME read failure as lockout (safe default).
  if not state.me.ok then
    table.insert(reasons, "ME ERR")
  else
    if (cfg.me.cutoffPct or 0) > 0 and state.me.pct < (cfg.me.cutoffPct or 0) then
      table.insert(reasons, ("ME < %d%%"):format(math.floor((cfg.me.cutoffPct or 0)*100 + 0.5)))
    end
    if (cfg.me.cutoffAbs or 0) > 0 and state.me.stored < (cfg.me.cutoffAbs or 0) then
      table.insert(reasons, "ME LOW")
    end
  end

  if state.screenStop then
    table.insert(reasons, "SCREEN STOP")
  end

  -- You can choose whether DISARM is a “lockout reason” or just a global gate.
  -- We keep it as a gate only (not a lockout banner reason), because you asked lockout to be based on conditions like STOP/power.

  state.lockoutReasons = reasons
  state.lockedOut = (#reasons > 0)
end

local function isLockedOut()
  return state.lockedOut
end

-- ====== UI PRIMITIVES ======
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

  local right
  if state.me.ok then
    right = ("ME: %d%% (%d/%d)"):format(math.floor(state.me.pct*100 + 0.5), state.me.stored, state.me.cap)
  else
    right = "ME: ERR"
  end
  writeAt(math.max(2, w-#right-1), 1, right, colors.black, colors.gray)

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

    writeAt(b.x,b.y, padRight(b.label, b.w), fg, bg)
  end
end

-- ====== DESIRED STATE ENGINE ======
-- Rules not implemented yet. AUTO defaults to OFF.
local function computeDesiredForSlave(name)
  local sc = cfg.slave_cfg[name] or { mode="AUTO", rules={on_any={}, off_all={}} }
  local mode = sc.mode or "AUTO"

  -- Global gates: lockout or disarmed always forces OFF.
  if isLockedOut() or (not state.armed) then
    return "OFF", "GLOBAL"
  end

  if mode == "FORCEOFF" then
    return "OFF", "FORCEOFF"
  elseif mode == "FORCEON" then
    return "ON", "FORCEON"
  else
    -- AUTO placeholder: do nothing yet => keep OFF.
    -- Later: rule evaluation sets ON/OFF.
    return "OFF", "AUTO"
  end
end

local function applyDesiredAll()
  -- Compute desired and send CMD only when it changes.
  for _,name in ipairs(cfg.slaves) do
    local want, why = computeDesiredForSlave(name)
    state.desired[name] = want

    -- show something meaningful in Reason column even without slave status
    local st = state.status[name]
    if not st then
      state.status[name] = { }
      st = state.status[name]
    end

    if isLockedOut() then
      st.reason = "LOCKOUT"
    elseif not state.armed then
      st.reason = "DISARM"
    else
      -- keep any slave-reported reason if present, otherwise show mode
      if not st.reason or st.reason == "" or st.reason == "LOCKOUT" or st.reason == "DISARM" then
        st.reason = why
      end
    end

    if state.lastCmd[name] ~= want then
      sendToSlave(name, "CMD", want)
      state.lastCmd[name] = want
    end
  end
end

-- Heartbeat sender: keep ON slaves alive.
-- Slaves fail-safe OFF if heartbeat stops.
local HB_PERIOD = 4.8
local function heartbeatLoop()
  while true do
    -- Only send HB when globally allowed (armed and not locked out and STOP not latched)
    computeLockoutReasons()

    if (not isLockedOut()) and state.armed then
      for _,name in ipairs(cfg.slaves) do
        if state.lastCmd[name] == "ON" then
          sendToSlave(name, "HB", "1")
        end
      end
    end

    sleep(HB_PERIOD)
  end
end

-- ====== DASHBOARD PAGE ======
local function drawDashboard()
  computeLayoutDashboard()
  drawHeader()
  drawButtons()

  -- table header
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
      desired = state.desired[name] or "--",
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

  writeAt(2,5, ("Slave: %s"):format(name), colors.white)
  writeAt(2,6, ("Mode: %s"):format(sc.mode or "AUTO"), colors.white)
  writeAt(2,7, ("State: %s   Want: %s"):format(st.actual or "--", state.desired[name] or "--"), colors.white)
  writeAt(2,8, ("Reason: %s"):format(st.reason or "--"), colors.white)

  -- Rules summary (read-only here)
  writeAt(2,10,"ON triggers (OR):", colors.cyan)
  local y = 11
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

-- ====== RULES PAGE (READ-ONLY VIEW) ======
local function drawRules()
  computeLayoutRules()
  drawHeader()
  drawButtons()

  local w,h = mon.getSize()
  writeAt(2,5,"RULES (read-only). Edit via terminal editor program.", colors.white)
  writeAt(2,6,("ME cutoff: %d%%"):format(math.floor((cfg.me.cutoffPct or 0)*100 + 0.5)), colors.white)

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
local function forceAllOff()
  for _,name in ipairs(cfg.slaves) do
    sendToSlave(name, "CMD", "OFF")
    state.lastCmd[name] = "OFF"
  end
end

local function doArmToggle()
  state.armed = not state.armed
  cfg.globalAllow = state.armed
  save(cfg)
  if not state.armed then
    forceAllOff()
  else
    -- on re-arm, don’t automatically turn things back on; RESET/RESUME is the operator action
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
  -- This is the operator “I restored power / cleared issues, now apply modes/rules again”.
  if isLockedOut() then return end
  if not state.armed then return end
  requestStatusAll()
  applyDesiredAll()
end

local function gotoPage(name)
  state.pageName = name
end

local function setSlaveMode(slaveName, mode)
  if not slaveName then return end
  cfg.slave_cfg[slaveName] = cfg.slave_cfg[slaveName] or { mode="AUTO", rules={on_any={}, off_all={}} }
  cfg.slave_cfg[slaveName].mode = mode
  save(cfg)
  applyDesiredAll()
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

    -- hbAge formatting
    for _,name in ipairs(cfg.slaves) do
      local st = state.status[name]
      if st and st.last then
        st.hbAge = string.format("%.1fs", os.clock() - st.last)
      end
    end
  end
end

-- ====== CONTROL LOOP ======
local function controlLoop()
  -- Prime desired cache
  for _,name in ipairs(cfg.slaves) do
    state.lastCmd[name] = state.lastCmd[name] or "OFF"
    state.desired[name] = state.desired[name] or "OFF"
  end

  -- Initial status query
  requestStatusAll()

  while true do
    computeLockoutReasons()

    -- Edge-trigger: entering lockout => force all OFF once.
    if isLockedOut() and (not state.wasLockedOut) then
      forceAllOff()
    end
    state.wasLockedOut = isLockedOut()

    -- Continuously enforce desired (but changes are edge-triggered by lastCmd)
    applyDesiredAll()

    sleep(0.5)
  end
end

-- ====== TOUCH HANDLERS ======
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

parallel.waitForAny(uiLoop, receiverLoop, controlLoop, heartbeatLoop)
