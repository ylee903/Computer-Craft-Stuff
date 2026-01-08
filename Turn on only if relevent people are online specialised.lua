-- client.lua
-- Local: player detector decides "allowed player online"
-- Hub: only provides redstone level wakeups + level payload
-- Rule: if hub level > 14, output is forced OFF

local PROTO    = "sam_hub_v1"
local HUB_NAME = "MainHub"  -- set nil to accept any hub name

local LEVER_SIDE  = "left"
local OUTPUT_SIDE = "bottom"

-- Players allowed to enable output (LOCAL check)
local allowedPlayers = {
  Samuel12345678 = true,
  Amball2000     = true,
  josherage      = true
}

-- ===== Local player detector =====
local detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
if not detector then
  error('No player detector found (expected type "player_detector" or "playerDetector")')
end

local function allowedPlayerOnline()
  local players = detector.getOnlinePlayers()
  for _, name in ipairs(players) do
    if allowedPlayers[name] then return true end
  end
  return false
end

-- ===== Modem bring-up =====
local function openAllModems()
  local opened = false
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      opened = true
    end
  end
  if not opened then error("No modem found. Attach a (wireless/ender) modem.") end
end
openAllModems()

-- ===== Hub discovery / subscription =====
local hubId = nil
local hubLevel = nil -- last known hub analog level (0-15)

local function discoverHub()
  print("Discovering hub...")
  rednet.broadcast({ type = "hub_discover" }, PROTO)

  while true do
    local sender, msg = rednet.receive(PROTO)
    if type(msg) == "table" and (msg.type == "hub_here" or msg.type == "hub_announce") then
      if HUB_NAME == nil or msg.name == HUB_NAME then
        hubId = sender
        print(("Hub found: id=%d name=%s"):format(hubId, tostring(msg.name)))
        return
      end
    end
  end
end

local function registerRedstoneOnly()
  print("Registering: hub redstone wakeups only...")
  rednet.send(hubId, {
    type = "register",
    subs = {
      redstone = { anyChange = true }
      -- NOTE: no players subscription
    }
  }, PROTO)

  -- Optional ack (debug)
  local sender, msg = rednet.receive(PROTO, 3)
  if sender == hubId and type(msg) == "table" and msg.type == "ok" then
    print("Hub ack:", msg.msg or "(ok)")
  else
    print("No ack seen (continuing anyway).")
  end
end

local function queryHubLevel(timeout)
  rednet.send(hubId, { type = "query", q = "level" }, PROTO)

  local sender, msg = rednet.receive(PROTO, timeout or 2)
  if sender == hubId and type(msg) == "table" and msg.type == "level" then
    return msg.level
  end
  return nil
end

-- ===== Output logic =====
local function decideOutput()
  local leverOn  = redstone.getInput(LEVER_SIDE)
  local okPlayer = allowedPlayerOnline()

  -- Hub gate: >14 blocks output
  if hubLevel ~= nil and hubLevel > 14 then
    return false, ("BLOCKED (hub level %d > 14)"):format(hubLevel)
  end

  local out = leverOn and okPlayer
  if out then
    return true, "ON (lever ON + allowed player online + hub not >14)"
  else
    return false, "OFF (lever OFF or no allowed player online)"
  end
end

local function applyOutput(tag)
  -- If we don't know hubLevel yet, fetch once (so blocking works immediately)
  if hubLevel == nil and hubId then
    local lvl = queryHubLevel(2)
    if lvl ~= nil then
      hubLevel = lvl
      print(("Fetched hub level: %d"):format(hubLevel))
    else
      print("Warning: hub level unknown; treating as not blocked until received.")
    end
  end

  local out, reason = decideOutput()
  redstone.setOutput(OUTPUT_SIDE, out)
  print(("[%s] Output %s - %s"):format(tag or "update", out and "ON" or "OFF", reason))
end

-- ===== Startup =====
discoverHub()
registerRedstoneOnly()

hubLevel = queryHubLevel(2) or hubLevel
if hubLevel ~= nil then
  print(("Initial hub level: %d"):format(hubLevel))
else
  print("Initial hub level unknown.")
end

applyOutput("startup")

-- ===== Unified event loop =====
while true do
  local event, p1, p2, p3 = os.pullEvent()

  if event == "rednet_message" then
    local sender, msg, proto = p1, p2, p3
    if proto == PROTO and type(msg) == "table" then
      -- Rebind hub if it re-announces (hub reboot)
      if (msg.type == "hub_here" or msg.type == "hub_announce") and (HUB_NAME == nil or msg.name == HUB_NAME) then
        if hubId ~= sender then
          hubId = sender
          print(("Hub (re)bound: id=%d name=%s"):format(hubId, tostring(msg.name)))
          registerRedstoneOnly()
          hubLevel = queryHubLevel(2) or hubLevel
          applyOutput("hub_rebind")
        end
      end

      -- Redstone wake event from hub
      if sender == hubId and msg.type == "event" and msg.event == "redstone" then
        hubLevel = msg.level
        print(("Wake: hub redstone %s prev=%s level=%s"):format(
          tostring(msg.side), tostring(msg.prev), tostring(msg.level)
        ))
        applyOutput("hub_redstone")
      end
    end

  elseif event == "redstone" then
    -- Local lever change
    applyOutput("local_redstone")

  elseif event == "playerJoin" or event == "playerLeave" then
    -- Local player detector events
    applyOutput("local_" .. event)
  end
end
