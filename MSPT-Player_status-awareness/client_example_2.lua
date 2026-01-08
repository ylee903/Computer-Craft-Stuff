-- startup.lua (Client)
-- CC:Tweaked + Ender modem
--
-- Sleeps until HUB wakes us (PROTO-filtered) on:
--  - redstone enter/exit level 15
--  - any player join/leave
-- Then queries hub state and sets redstone output on BACK:
--  ON  if (hub level == 15) AND ("Samuel12345678" is online)
--  OFF otherwise
--
-- Requires hub using PROTO = "sam_hub_v1" for ALL send/broadcast/receive.

-- ===== CONFIG =====
local PROTO         = "sam_hub_v1"
local HUB_NAME      = "MainHub"          -- set nil to accept any hub name
local TARGET_USER   = "Samuel12345678"
local OUTPUT_SIDE   = "back"

local DISCOVER_EVERY_SECONDS = 3         -- retry discover interval
local QUERY_TIMEOUT_SECONDS  = 3         -- wait for state response

-- ===== UTIL =====
local function ts()
  return textutils.formatTime(os.time(), true)
end

local function log(msg)
  print(("[%s] %s"):format(ts(), msg))
end

local function listHas(t, wanted)
  if type(t) ~= "table" then return false end
  for _, v in ipairs(t) do
    if v == wanted then return true end
  end
  return false
end

local function setOutput(on)
  redstone.setOutput(OUTPUT_SIDE, on and true or false)
  log(("Set redstone %s = %s"):format(OUTPUT_SIDE, on and "ON" or "OFF"))
end

-- ===== REDNET SETUP =====
local function ensureRednet()
  if rednet.isOpen() then return end
  local modem = peripheral.find("modem")
  if not modem then error("No modem found. Attach an ender modem.") end
  local side = peripheral.getName(modem)
  rednet.open(side)
  log(("rednet opened on %s"):format(side))
end

-- ===== HUB DISCOVERY =====
local function discoverHub()
  while true do
    log("Broadcasting hub_discover...")
    rednet.broadcast({ type = "hub_discover" }, PROTO)

    local deadline = os.clock() + DISCOVER_EVERY_SECONDS
    while os.clock() < deadline do
      local remaining = math.max(0, deadline - os.clock())
      local sender, msg, protocol = rednet.receive(PROTO, remaining)
      if sender and type(msg) == "table" then
        if (msg.type == "hub_here" or msg.type == "hub_announce") then
          local nameOk = (HUB_NAME == nil) or (msg.name == HUB_NAME)
          if nameOk then
            log(("Discovered hub '%s' id=%d via %s"):format(tostring(msg.name), sender, msg.type))
            return sender, msg.name
          else
            log(("Heard hub '%s' but ignoring (want '%s')"):format(tostring(msg.name), tostring(HUB_NAME)))
          end
        end
      end
    end

    log("No hub found yet. Retrying discover...")
  end
end

-- ===== SUBSCRIBE =====
local function registerSubs(hubId)
  local payload = {
    type = "register",
    subs = {
      redstone = { enter = {15}, exit = {15} },
      players  = { anyJoin = true, anyLeave = true }
    }
  }

  log("Sending register (subs) to hub...")
  rednet.send(hubId, payload, PROTO)

  local deadline = os.clock() + 3
  while os.clock() < deadline do
    local remaining = math.max(0, deadline - os.clock())
    local sender, msg = rednet.receive(PROTO, remaining)
    if sender == hubId and type(msg) == "table" then
      if msg.type == "ok" then
        log("Register ACK: " .. tostring(msg.msg))
        return true
      elseif msg.type == "error" then
        log("Register ERROR: " .. tostring(msg.msg))
        return false
      end
    end
  end

  log("No register ACK received (continuing anyway).")
  return true
end

-- ===== QUERY STATE =====
local function queryState(hubId)
  log("Querying hub state...")
  rednet.send(hubId, { type = "query", q = "state" }, PROTO)

  local deadline = os.clock() + QUERY_TIMEOUT_SECONDS
  while os.clock() < deadline do
    local remaining = math.max(0, deadline - os.clock())
    local sender, msg = rednet.receive(PROTO, remaining)
    if sender == hubId and type(msg) == "table" then
      if msg.type == "state" then
        return msg.level, msg.players
      elseif msg.type == "error" then
        log("State query ERROR: " .. tostring(msg.msg))
        return nil, nil
      end
      -- ignore other hub messages while waiting for state
    end
  end

  log("State query timed out.")
  return nil, nil
end

local function decideAndAct(level, players)
  local okPlayer = listHas(players, TARGET_USER)
  local okLevel  = (level == 15)

  log(("Decision: level=%s (need 15), %s online=%s"):format(
    tostring(level),
    TARGET_USER,
    tostring(okPlayer)
  ))

  setOutput(okPlayer and okLevel)
end

-- ===== MAIN =====
ensureRednet()

local hubId, hubName = discoverHub()
registerSubs(hubId)

-- Initial sync so output is correct immediately
do
  local level, players = queryState(hubId)
  if level ~= nil and players ~= nil then
    log(("Initial state: level=%d, players=%d"):format(level, #players))
    decideAndAct(level, players)
  else
    log("Initial sync failed; output unchanged until next hub event.")
  end
end

log("Sleeping for PROTO-filtered hub events...")

while true do
  log("Sleeping on rednet.receive(PROTO)...")
  local sender, msg = rednet.receive(PROTO) -- blocks; ignores other protocol traffic

  if sender ~= hubId then
    -- With PROTO filtering, this is usually another "sam_hub_v1" speaker.
    log(("Wake: message from non-hub id=%d ignored."):format(sender))

  elseif type(msg) ~= "table" then
    log("Wake: non-table message from hub ignored.")

  else
    if msg.type == "event" then
      -- Wake trigger
      if msg.event == "redstone" then
        log(("Wake EVENT: redstone prev=%s -> level=%s (side=%s)"):format(
          tostring(msg.prev), tostring(msg.level), tostring(msg.side)
        ))
      elseif msg.event == "playerJoin" or msg.event == "playerLeave" then
        log(("Wake EVENT: %s username=%s"):format(tostring(msg.event), tostring(msg.username)))
      else
        log(("Wake EVENT: %s"):format(tostring(msg.event)))
      end

      -- Pull authoritative state and act
      local level, players = queryState(hubId)
      if level ~= nil and players ~= nil then
        log(("State after wake: level=%d, players=%d"):format(level, #players))
        decideAndAct(level, players)
      else
        log("Could not get state after wake; not changing output.")
      end

    elseif msg.type == "hub_announce" or msg.type == "hub_here" then
      -- Hub reboot/announce; re-register and resync
      log(("Hub announced again (%s). Re-registering + resyncing."):format(tostring(msg.type)))
      registerSubs(hubId)
      local level, players = queryState(hubId)
      if level ~= nil and players ~= nil then
        decideAndAct(level, players)
      end

    elseif msg.type == "ok" or msg.type == "error" then
      -- occasional acks/errors might arrive
      log(("Hub reply: %s %s"):format(tostring(msg.type), tostring(msg.msg)))

    else
      log(("Wake: hub message type=%s ignored."):format(tostring(msg.type)))
    end
  end
end
