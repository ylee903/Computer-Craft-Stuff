-- startup.lua (SLAVE) - NO HEARTBEAT, targeted master comms, signed messages
-- Adds manual local enable switch gate + default output=bottom
local CONFIG = "slave.cfg"

-- Defaults (still configurable on first run)
local RS_DEFAULT_OUTPUT_SIDE = "bottom"
local RS_DEFAULT_MANUAL_SIDE = "left"   -- manual control switch input

-- ===== util =====
local function openModem()
  for _, p in ipairs(peripheral.getNames()) do
    if peripheral.getType(p) == "modem" then
      if not rednet.isOpen(p) then rednet.open(p) end
      return true
    end
  end
  return false
end

local function save(cfg)
  local f = fs.open(CONFIG, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

local function load()
  if not fs.exists(CONFIG) then return nil end
  local f = fs.open(CONFIG, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  return t
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
  -- short, stable, avoids public rednet collisions
  return "sp_" .. sig(key, "proto"):sub(1, 8)
end

local function ensureLabel(name)
  if not os.getComputerLabel() or os.getComputerLabel() == "" then
    os.setComputerLabel(name)
  end
end

-- ===== config bootstrap =====
local cfg = load()
if not cfg then
  term.clear(); term.setCursorPos(1,1)
  print("=== Slave setup ===")
  write("Slave name (unique): ") local name = read()
  write("Shared key: ") local key = read("*")

  write("Redstone OUTPUT side ["..RS_DEFAULT_OUTPUT_SIDE.."]: ")
  local outSide = read()
  if outSide == "" then outSide = RS_DEFAULT_OUTPUT_SIDE end

  write("Manual ENABLE input side ["..RS_DEFAULT_MANUAL_SIDE.."]: ")
  local manSide = read()
  if manSide == "" then manSide = RS_DEFAULT_MANUAL_SIDE end

  cfg = { name=name, key=key, side=outSide, manualSide=manSide }
  save(cfg)
end

-- Backwards-compat upgrade if cfg existed from older version
cfg.side = cfg.side or RS_DEFAULT_OUTPUT_SIDE
cfg.manualSide = cfg.manualSide or RS_DEFAULT_MANUAL_SIDE

ensureLabel(cfg.name)

if not openModem() then error("No modem found. Attach ender modem.") end

local PROTOCOL = cfg.protocol or protoFromKey(cfg.key)
if cfg.protocol ~= PROTOCOL then
  cfg.protocol = PROTOCOL
  save(cfg)
end

-- ===== state =====
local masterId = nil

-- desired comes from master; actual output is gated by manual switch
local desiredOn = false
local actualOn  = false

local function manualAllowed()
  -- Treat non-bool as false safely
  return redstone.getInput(cfg.manualSide) == true
end

local function applyOutput()
  local allow = manualAllowed()
  actualOn = (desiredOn and allow) and true or false
  redstone.setOutput(cfg.side, actualOn)
end

local function setDesired(on)
  desiredOn = on and true or false
  applyOutput()
end

local function statusTable()
  local allow = manualAllowed()
  local note = nil
  if desiredOn and not allow then note = "MANUAL_SWITCH_OFF" end
  return {
    name = cfg.name,
    side = cfg.side,
    manualSide = cfg.manualSide,
    manual = allow,
    desired = desiredOn and "ON" or "OFF",
    enabled = actualOn,
    actual = actualOn and "ON" or "OFF",
    note = note,
  }
end

local function sendStatus(toId)
  local v = statusTable()
  local vstr = textutils.serialize(v)
  local payload = "STATUS_RSP|"..cfg.name.."|"..vstr
  local msg = { kind="STATUS_RSP", slave=cfg.name, value=v, valueStr=vstr, s=sig(cfg.key, payload) }
  rednet.send(toId, msg, PROTOCOL)
end

-- ===== master discovery + register =====
local function discoverMaster(timeout)
  rednet.broadcast({ kind="MASTER_DISCOVER" }, PROTOCOL)
  local t0 = os.clock()
  while true do
    local remain = timeout and (timeout - (os.clock() - t0)) or nil
    if timeout and remain <= 0 then return nil end
    local sender, msg = rednet.receive(PROTOCOL, remain)
    if sender and type(msg) == "table" and msg.kind == "MASTER_HERE" then
      return sender
    end
  end
end

local function registerWithMaster(id)
  local payload = "REGISTER|"..cfg.name.."|1"
  local msg = { kind="REGISTER", slave=cfg.name, value="1", s=sig(cfg.key, payload) }
  rednet.send(id, msg, PROTOCOL)
end

-- ===== boot safe default =====
redstone.setOutput(cfg.side, false)
desiredOn = false
actualOn = false

-- try to find master at boot (loop until found)
while not masterId do
  print(("Slave '%s' booted OFF (out=%s, manual=%s). Looking for master..."):format(cfg.name, cfg.side, cfg.manualSide))
  masterId = discoverMaster(2.0)
  if not masterId then sleep(1.0) end
end

print("Master found:", masterId, " registering...")
registerWithMaster(masterId)

print("Ready. Waiting for commands (no heartbeat). Manual gate active.")

-- Optional: detect manual switch changes so output updates instantly even without master traffic
local function manualWatchLoop()
  local last = manualAllowed()
  while true do
    os.pullEvent("redstone") -- wakes on any redstone change anywhere
    local nowAllow = manualAllowed()
    if nowAllow ~= last then
      last = nowAllow
      applyOutput()
      if masterId then sendStatus(masterId) end
      print(("Manual switch %s -> actual %s (desired %s)"):format(nowAllow and "ON" or "OFF", actualOn and "ON" or "OFF", desiredOn and "ON" or "OFF"))
    end
  end
end

local function commandLoop()
  while true do
    local sender, msg = rednet.receive(PROTOCOL)
    if sender == masterId and type(msg) == "table" and msg.slave == cfg.name and msg.kind then
      local payload = (msg.kind or "").."|"..(msg.slave or "").."|"..tostring(msg.value or "")
      if msg.s == sig(cfg.key, payload) then
        if msg.kind == "CMD" then
          if msg.value == "ON" then
            setDesired(true)
            print("CMD ON -> desired ON, actual " .. (actualOn and "ON" or "OFF"))
          elseif msg.value == "OFF" then
            setDesired(false)
            print("CMD OFF -> desired OFF, actual OFF")
          end
          sendStatus(masterId)

        elseif msg.kind == "STATUS_REQ" then
          sendStatus(masterId)

        elseif msg.kind == "MASTER_HERE" then
          -- master rebooted; update id + re-register
          masterId = sender
          registerWithMaster(masterId)
          sendStatus(masterId)
        end
      end
    end
  end
end

parallel.waitForAny(commandLoop, manualWatchLoop)
