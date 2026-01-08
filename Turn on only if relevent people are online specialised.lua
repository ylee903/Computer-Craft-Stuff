-- client.lua (FAIL-SAFE)
-- If hub can't be reached: assume BLOCKED, force output OFF.
-- Keeps checking periodically for hub to appear.

local PROTO    = "sam_hub_v1"
local HUB_NAME = "MainHub"   -- nil = accept any

local LEVER_SIDE  = "left"
local OUTPUT_SIDE = "bottom"

-- retry timings
local DISCOVER_RETRY_SEC = 10   -- try to find hub every 10s if missing
local QUERY_TIMEOUT_SEC  = 2    -- wait up to 2s for hub replies

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

-- ===== Hub state =====
local hubId = nil
local hubLevel = nil     -- last known hub level
local hubBlocked = true  -- FAIL-SAFE DEFAULT: blocked until proven otherwise

-- ===== Hub helpers =====
local function discoverHub(timeoutSec)
  rednet.broadcast({ type = "hub_discover" }, PROTO)

  local deadline = os.clock() + (timeoutSec or 0)
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then return false end

    local sender, msg = rednet.receive(PROTO, remaining)
    if sender and type(msg) == "table" and (msg.type == "hub_here" or msg.type == "hub_announce") then
      if HUB_NAME == nil or msg.name == HUB_NAME then
        hubId = sender
        return true
      end
    end
  end
end

local function registerRedstoneOnly()
  if not hubId then return end
  rednet.send(hubId, { type = "register", subs = { redstone = { anyChange = true } } }, PROTO)
  -- ack optional
  local sender, msg = rednet.receive(PROTO, 2)
  if sender == hubId and type(msg) == "table" and msg.type == "ok" then
    print("Hub ack:", msg.msg or "(ok)")
  end
end

local function queryHubLevel(timeoutSec)
  if not hubId then return nil end
  rednet.send(hubId, { type = "query", q = "level" }, PROTO)

  local sender, msg = rednet.receive(PROTO, timeoutSec or QUERY_TIMEOUT_SEC)
  if sender == hubId and type(msg) == "table" and msg.type == "level" then
    return msg.level
  end
  return nil
end

local function bindHubIfPossible(reason)
  -- try find hub quickly; if found, register and fetch level
  if not hubId then
    local ok = discoverHub(QUERY_TIMEOUT_SEC)
    if not ok then
      return false
    end
    print(("Hub found (reason=%s) id=%d"):format(reason or "?", hubId))
    registerRedstoneOnly()
  end

  local lvl = queryHubLevel(QUERY_TIMEOUT_SEC)
  if lvl == nil then
    -- hub exists but didn't answer query (could be unloading); remain fail-safe
    return false
  end

  hubLevel = lvl
  hubBlocked = (hubLevel > 14)  -- if 15, blocked; otherwise not blocked
  print(("Hub level now %d => %s"):format(hubLevel, hubBlocked and "BLOCKED" or "allowed"))
  return true
end

-- ===== Output logic =====
local function decideOutput()
  local leverOn  = redstone.getInput(LEVER_SIDE)
  local okPlayer = allowedPlayerOnline()

  -- FAIL-SAFE GATE:
  -- If hub unreachable OR hub says >14 => force OFF.
  if hubBlocked then
    return false, (hubLevel == nil)
      and "BLOCKED (hub unreachable/unknown => fail-safe OFF)"
      or ("BLOCKED (hub level "..hubLevel.." > 14)")
  end

  local out = leverOn and okPlayer
  if out then
    return true, "ON (lever ON + allowed player online + hub allows)"
  else
    return false, "OFF (lever OFF or no allowed player online)"
  end
end

local function applyOutput(tag)
  local out, reason = decideOutput()
  redstone.setOutput(OUTPUT_SIDE, out)
  print(("[%s] Output %s - %s"):format(tag or "update", out and "ON" or "OFF", reason))
end

-- ===== Startup behaviour =====
print("Startup: fail-safe default = BLOCKED until hub responds.")
redstone.setOutput(OUTPUT_SIDE, false)

-- Try once on startup, but DO NOT hang if hub isn't loaded.
if bindHubIfPossible("startup") then
  -- we now have a real hub state
else
  -- remain fail-safe blocked
  hubBlocked = true
  hubLevel = nil
  print("Hub not reachable at startup => staying BLOCKED (fail-safe).")
end

applyOutput("startup")

-- ===== Main loop =====
local retryTimer = os.startTimer(DISCOVER_RETRY_SEC)

while true do
  local event, p1, p2, p3 = os.pullEvent()

  if event == "timer" and p1 == retryTimer then
    -- periodically try to (re)bind the hub if blocked/unknown
    if hubId == nil or hubLevel == nil then
      if bindHubIfPossible("periodic") then
        applyOutput("hub_recovered")
      end
    end
    retryTimer = os.startTimer(DISCOVER_RETRY_SEC)

  elseif event == "rednet_message" then
    local sender, msg, proto = p1, p2, p3
    if proto == PROTO and type(msg) == "table" then
      -- hub announce/here can (re)bind after reboot
      if (msg.type == "hub_here" or msg.type == "hub_announce") and (HUB_NAME == nil or msg.name == HUB_NAME) then
        if hubId ~= sender then
          hubId = sender
          print(("Hub (re)bound via announce: id=%d"):format(hubId))
          registerRedstoneOnly()
          -- fetch latest level; if fails, stay fail-safe
          if not bindHubIfPossible("announce") then
            hubBlocked = true
            hubLevel = nil
          end
          applyOutput("hub_rebind")
        end
      end

      -- redstone event from hub updates gating immediately
      if sender == hubId and msg.type == "event" and msg.event == "redstone" then
        hubLevel = msg.level
        hubBlocked = (hubLevel > 14)
        print(("Wake: hub redstone prev=%s level=%s => %s"):format(
          tostring(msg.prev), tostring(msg.level), hubBlocked and "BLOCKED" or "allowed"
        ))
        applyOutput("hub_redstone")
      end
    end

  elseif event == "redstone" then
    -- local lever
    applyOutput("local_redstone")

  elseif event == "playerJoin" or event == "playerLeave" then
    -- local player detector events
    applyOutput("local_" .. event)
  end
end
