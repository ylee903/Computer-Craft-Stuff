-- startup.lua (SLAVE) - secure + heartbeat failsafe + STATUS replies (event-driven-ish)
local CONFIG = "slave.cfg"
local PROTOCOL = "spawner_ctrl_v3"

local HEARTBEAT_TIMEOUT = 5.0 -- seconds since last valid HB -> OFF
local RS_DEFAULT_SIDE = "back"

-- how long to block when idle (disabled). Keep responsive but low overhead.
local IDLE_POLL_MAX = 2.0 -- seconds

-- ===== utils =====
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

-- simple signature: blocks casual spoofing
local function sig(key, payload)
  local s = payload .. "|" .. key
  local h = 0
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 2147483647
  end
  return tostring(h)
end

local function ensureLabel(name)
  if not os.getComputerLabel() or os.getComputerLabel() == "" then
    os.setComputerLabel(name)
  end
end

-- ===== setup =====
local cfg = load()
if not cfg then
  term.clear(); term.setCursorPos(1,1)
  print("=== Slave setup ===")
  write("Slave name (unique): ") local name = read()
  write("Shared key: ") local key = read("*") -- hide
  write("Redstone output side (back/top/etc) ["..RS_DEFAULT_SIDE.."]: ")
  local side = read()
  if side == "" then side = RS_DEFAULT_SIDE end
  cfg = { name=name, key=key, side=side }
  save(cfg)
end

ensureLabel(cfg.name)

if not openModem() then error("No modem found. Attach ender modem.") end

-- safe default
redstone.setOutput(cfg.side, false)

local enabled = false
local lastHB = 0

local function setSpawner(on)
  enabled = on
  redstone.setOutput(cfg.side, on)
end

local function printStatus()
  print(("Name: %s  Side: %s  Enabled: %s"):format(cfg.name, cfg.side, tostring(enabled)))
  if enabled then
    local age = os.clock() - lastHB
    print(("Last HB age: %.2fs (timeout %.1fs)"):format(age, HEARTBEAT_TIMEOUT))
  end
end

local function sendStatus(toId)
  -- We reply only when requested (STATUS_REQ)
  local v = {
    name = cfg.name,
    side = cfg.side,
    enabled = enabled,
    actual = enabled and "ON" or "OFF",
  }
  local payload = "STATUS_RSP|"..cfg.name.."|"..textutils.serialize(v)
  local msg = { kind="STATUS_RSP", slave=cfg.name, value=v, s=sig(cfg.key, "STATUS_RSP|"..cfg.name.."|"..tostring(v)) }

  -- NOTE: For signature, we must sign the same payload scheme as master:
  -- master verifies payload = kind|slave|value (value tostring for tables is unstable),
  -- so we will sign using a stable serialized value string and also send that string in valueStr.
end

-- ===== IMPORTANT: stable signing for STATUS replies =====
local function sendStatusStable(toId)
  local v = {
    name = cfg.name,
    side = cfg.side,
    enabled = enabled,
    actual = enabled and "ON" or "OFF",
  }
  -- Stable string for signing + optionally for debug
  local vstr = textutils.serialize(v)
  local payload = "STATUS_RSP|"..cfg.name.."|"..vstr
  local msg = { kind="STATUS_RSP", slave=cfg.name, value=v, valueStr=vstr, s=sig(cfg.key, payload) }

  if toId then
    rednet.send(toId, msg, PROTOCOL)
  else
    rednet.broadcast(msg, PROTOCOL)
  end
end

-- ===== control loop (rednet) =====
local function controlLoop()
  print(("Slave ready '%s' (side %s). Default OFF."):format(cfg.name, cfg.side))
  print("Commands in terminal: status | rename | key | side")

  while true do
    -- dynamic wait: if enabled, wake up before timeout; else sleep longer
    local timeout
    if enabled then
      local age = os.clock() - lastHB
      timeout = math.max(0.1, HEARTBEAT_TIMEOUT - age)
      -- we don't need to wait the full remaining time; half is enough to be responsive
      timeout = math.min(0.5, timeout)
    else
      timeout = IDLE_POLL_MAX
    end

    local sender, msg = rednet.receive(PROTOCOL, timeout)

    if sender and type(msg) == "table" and msg.slave == cfg.name and msg.kind then
      -- signature check: master signs payload kind|slave|value
      -- For STATUS_REQ, value is string "1" so stable.
      local payload = (msg.kind or "").."|"..(msg.slave or "").."|"..tostring(msg.value or "")
      if msg.s == sig(cfg.key, payload) then
        if msg.kind == "CMD" then
          if msg.value == "ON" then
            setSpawner(true)
            lastHB = os.clock() -- grace window starts now
            print("CMD ON -> ON")
          elseif msg.value == "OFF" then
            setSpawner(false)
            print("CMD OFF -> OFF")
          end

        elseif msg.kind == "HB" then
          if enabled then lastHB = os.clock() end

        elseif msg.kind == "STATUS_REQ" then
          -- reply only when asked; send directly back to requester for less spam
          sendStatusStable(sender)
        end
      end
    end

    -- failsafe: ON requires heartbeat
    if enabled and (os.clock() - lastHB > HEARTBEAT_TIMEOUT) then
      print("Failsafe OFF (no heartbeat)")
      setSpawner(false)
    end
  end
end

-- ===== terminal command loop =====
local function commandLoop()
  while true do
    write("> ")
    local line = read()
    line = (line or ""):lower()

    if line == "status" then
      printStatus()

    elseif line == "rename" then
      write("New slave name: ")
      local newName = read()
      if newName and newName ~= "" then
        setSpawner(false)
        cfg.name = newName
        save(cfg)
        ensureLabel(cfg.name)
        print("Renamed. New name:", cfg.name)
      end

    elseif line == "key" then
      write("New shared key: ")
      local k = read("*")
      if k and k ~= "" then
        setSpawner(false)
        cfg.key = k
        save(cfg)
        print("Key updated.")
      end

    elseif line == "side" then
      write("New redstone side (back/top/etc): ")
      local s = read()
      if s and s ~= "" then
        setSpawner(false)
        redstone.setOutput(cfg.side, false)
        cfg.side = s
        save(cfg)
        print("Side updated:", cfg.side)
      end

    else
      print("Commands: status | rename | key | side")
    end
  end
end

parallel.waitForAny(controlLoop, commandLoop)
