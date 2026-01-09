-- startup.lua (SLAVE) - NO HEARTBEAT, targeted master comms, signed messages
local CONFIG = "slave.cfg"
local RS_DEFAULT_SIDE = "back"

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
  write("Redstone output side ["..RS_DEFAULT_SIDE.."]: ")
  local side = read()
  if side == "" then side = RS_DEFAULT_SIDE end
  cfg = { name=name, key=key, side=side }
  save(cfg)
end

ensureLabel(cfg.name)

if not openModem() then error("No modem found. Attach ender modem.") end

local PROTOCOL = cfg.protocol or protoFromKey(cfg.key)
if cfg.protocol ~= PROTOCOL then
  cfg.protocol = PROTOCOL
  save(cfg)
end

-- safe default
redstone.setOutput(cfg.side, false)
local enabled = false
local masterId = nil

local function setSpawner(on)
  enabled = on and true or false
  redstone.setOutput(cfg.side, enabled)
end

local function statusTable()
  return {
    name = cfg.name,
    side = cfg.side,
    enabled = enabled,
    actual = enabled and "ON" or "OFF",
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

-- try to find master at boot (loop until found)
while not masterId do
  print(("Slave '%s' booted OFF (side=%s). Looking for master..."):format(cfg.name, cfg.side))
  masterId = discoverMaster(2.0)
  if not masterId then
    sleep(1.0)
  end
end

print("Master found:", masterId, " registering...")
registerWithMaster(masterId)

-- ===== main loop =====
print("Ready. Waiting for commands (no heartbeat).")
while true do
  local sender, msg = rednet.receive(PROTOCOL)
  if sender == masterId and type(msg) == "table" and msg.slave == cfg.name and msg.kind then
    local payload = (msg.kind or "").."|"..(msg.slave or "").."|"..tostring(msg.value or "")
    if msg.s == sig(cfg.key, payload) then
      if msg.kind == "CMD" then
        if msg.value == "ON" then
          setSpawner(true)
          print("CMD ON -> ON")
        elseif msg.value == "OFF" then
          setSpawner(false)
          print("CMD OFF -> OFF")
        end
        -- optional: report status after command
        sendStatus(masterId)

      elseif msg.kind == "STATUS_REQ" then
        sendStatus(masterId)

      elseif msg.kind == "MASTER_HERE" then
        -- master rebooted; update id + re-register
        masterId = sender
        registerWithMaster(masterId)
      end
    end
  end
end
