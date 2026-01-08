-- startup.lua (Client) — improved
-- CC:Tweaked + Ender modem
--
-- Behavior:
--  - Subscribe to hub events (PROTO-filtered).
--  - Do ONE initial state query to sync caches.
--  - On REDSTONE wake: use event payload (msg.level) directly (NO ping) and decide using cached players.
--  - On PLAYER join/leave wake: ping hub for full authoritative state (players list + level), update caches, decide.
--  - On hub_announce/hub_here: re-register + resync (ping).
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
      local sender, msg = rednet.receive(PROTO, remaining)
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

-- ===== LOCAL CACHES =====
local cachedLevel   = nil
local cachedPlayers = nil

local function cacheAndDecide(level, players, reason)
  cachedLevel, cachedPlayers = level, players
  log(("Cache updated (%s): level=%s, players=%s"):format(
    tostring(reason),
    tostring(cachedLevel),
    (type(cachedPlayers) == "table") and tostring(#cachedPlayers) or "nil"
  ))
  decideAndAct(cachedLevel, cachedPlayers)
end

-- ===== MAIN =====
ensureRednet()

local hubId, hubName = discoverHub()
registerSubs(hubId)

-- Initial sync so output is correct immediately + caches are primed
do
  local level, players = queryState(hubId)
  if level ~= nil and players ~= nil then
    log(("Initial state: level=%d, players=%d"):format(level, #players))
    cacheAndDecide(level, players, "initial_sync")
  else
    log("Initial sync failed; output unchanged until next hub event.")
  end
end

log("Sleeping for PROTO-filtered hub events...")

while true do
  log("Sleeping on rednet.receive(PROTO)...")
  local sender, msg = rednet.receive(PROTO)

  if sender ~= hubId then
    log(("Wake: message from non-hub id=%d ignored."):format(sender))

  elseif type(msg) ~= "table" then
    log("Wake: non-table message from hub ignored.")

  else
    if msg.type == "event" then
      if msg.event == "redstone" then
        -- NO PING: redstone payload includes msg.level, so update cachedLevel directly
        log(("Wake EVENT: redstone prev=%s -> level=%s (side=%s)"):format(
          tostring(msg.prev), tostring(msg.level), tostring(msg.side)
        ))

        cachedLevel = msg.level
        log(("Cached level updated from redstone event: %s"):format(tostring(cachedLevel)))

        if cachedPlayers ~= nil then
          decideAndAct(cachedLevel, cachedPlayers)
        else
          -- Should only happen if initial sync failed; recover once
          log("No cached players yet; querying state once to recover...")
          local level, players = queryState(hubId)
          if level ~= nil and players ~= nil then
            cacheAndDecide(level, players, "recover_after_redstone")
          else
            log("Could not recover state; not changing output.")
          end
        end

      elseif msg.event == "playerJoin" or msg.event == "playerLeave" then
        -- PING: player event doesn't include full list, so refresh authoritative state
        log(("Wake EVENT: %s username=%s"):format(tostring(msg.event), tostring(msg.username)))
        local level, players = queryState(hubId)
        if level ~= nil and players ~= nil then
          cacheAndDecide(level, players, "player_event")
        else
          log("Could not get state after player event; not changing output.")
        end

      else
        -- Unknown event: safest to resync
        log(("Wake EVENT: %s (unknown) -> resyncing"):format(tostring(msg.event)))
        local level, players = queryState(hubId)
        if level ~= nil and players ~= nil then
          cacheAndDecide(level, players, "unknown_event")
        else
          log("Could not get state after unknown event; not changing output.")
        end
      end

    elseif msg.type == "hub_announce" or msg.type == "hub_here" then
      -- Hub reboot/announce; re-register and resync
      log(("Hub announced again (%s). Re-registering + resyncing."):format(tostring(msg.type)))
      registerSubs(hubId)
      local level, players = queryState(hubId)
      if level ~= nil and players ~= nil then
        cacheAndDecide(level, players, "hub_reannounce")
      else
        log("Resync after hub announce failed; not changing output.")
      end

    elseif msg.type == "ok" or msg.type == "error" then
      log(("Hub reply: %s %s"):format(tostring(msg.type), tostring(msg.msg)))

    else
      log(("Wake: hub message type=%s ignored."):format(tostring(msg.type)))
    end
  end
end
