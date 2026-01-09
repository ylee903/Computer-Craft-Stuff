-- HUB STARTUP (FIXED + PROTOCOL) - Single unified event loop
-- CC:Tweaked + Advanced Peripherals

local HUB_NAME   = "MainHub"
local PROTO      = "sam_hub_v1"   -- <<< protocol filter (change if you want)
local SUBS_FILE  = "hub_subs.txt"
local INPUT_SIDE = "back"         -- analog redstone input side (0-15)
local RS_SIDE    = "back"         -- included in payload for clarity

-- ===== Persistent client subscriptions =====
local subs = {} -- [clientId] = { redstone=..., players=... }

local function loadSubs()
  if fs.exists(SUBS_FILE) then
    local h = fs.open(SUBS_FILE, "r")
    local txt = h.readAll()
    h.close()
    local t = textutils.unserialize(txt)
    if type(t) == "table" then subs = t end
  end
end

local function saveSubs()
  local h = fs.open(SUBS_FILE, "w")
  h.write(textutils.serialize(subs))
  h.close()
end

-- ===== Normalize subscription shapes =====
local function listToMap(t)
  if type(t) ~= "table" then return nil end
  if #t > 0 then
    local m = {}
    for _, v in ipairs(t) do m[v] = true end
    return m
  end
  return t -- already a map
end

local function normalizeSubs(s)
  if type(s) ~= "table" then return {} end

  if s.redstone then
    s.redstone.enter = listToMap(s.redstone.enter)
    s.redstone.exit  = listToMap(s.redstone.exit)
  end

  if s.players then
    s.players.join  = listToMap(s.players.join)
    s.players.leave = listToMap(s.players.leave)
  end

  return s
end

-- ===== Find peripherals =====
local modem = peripheral.find("modem")
if not modem then error("No modem found") end
rednet.open(peripheral.getName(modem))

local detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
if not detector then error('No player detector found (expected "player_detector" or "playerDetector")') end

-- ===== State =====
loadSubs()
local lastLevel = redstone.getAnalogInput(INPUT_SIDE)

local function getPlayers()
  return detector.getOnlinePlayers()
end

-- ===== Matching logic =====
local function redstoneMatches(rule, prev, curr)
  if not rule then return false end
  if rule.anyChange then return true end
  if rule.enter and rule.enter[curr] then return true end -- entering curr
  if rule.exit  and rule.exit[prev] then return true end -- leaving prev
  return false
end

local function playerMatches(rule, ev, username)
  if not rule then return false end
  if ev == "playerJoin" then
    if rule.anyJoin then return true end
    if rule.join and rule.join[username] then return true end
  elseif ev == "playerLeave" then
    if rule.anyLeave then return true end
    if rule.leave and rule.leave[username] then return true end
  end
  return false
end

local function sendToMatchingClients(payload, matchFn)
  for id, s in pairs(subs) do
    if matchFn(s) then
      rednet.send(id, payload, PROTO) -- <<< protocol
    end
  end
end

-- ===== Startup announce =====
rednet.broadcast({ type = "hub_announce", name = HUB_NAME }, PROTO) -- <<< protocol
print("Hub online:", HUB_NAME, "(proto:", PROTO .. ")")

-- ===== Unified event loop =====
while true do
  local ev, p1, p2, p3 = os.pullEvent()

  -- Rednet: ev = "rednet_message", p1=senderId, p2=msg, p3=protocol
  if ev == "rednet_message" then
    local senderId, msg, protocol = p1, p2, p3

    -- Only accept OUR protocol traffic
    if protocol == PROTO and type(msg) == "table" then
      if msg.type == "hub_discover" then
        rednet.send(senderId, { type = "hub_here", name = HUB_NAME }, PROTO)

      elseif msg.type == "register" then
        if type(msg.subs) == "table" then
          subs[senderId] = normalizeSubs(msg.subs)
          saveSubs()
          rednet.send(senderId, { type = "ok", msg = "registered" }, PROTO)
          print("Registered client", senderId)
        else
          rednet.send(senderId, { type = "error", msg = "register missing subs table" }, PROTO)
        end

      elseif msg.type == "unregister" then
        subs[senderId] = nil
        saveSubs()
        rednet.send(senderId, { type = "ok", msg = "unregistered" }, PROTO)
        print("Unregistered client", senderId)

      elseif msg.type == "query" then
        if msg.q == "state" then
          rednet.send(senderId, { type = "state", level = lastLevel, players = getPlayers() }, PROTO)
        elseif msg.q == "level" then
          rednet.send(senderId, { type = "level", level = lastLevel }, PROTO)
        elseif msg.q == "players" then
          rednet.send(senderId, { type = "players", players = getPlayers() }, PROTO)
        else
          rednet.send(senderId, { type = "error", msg = "unknown query" }, PROTO)
        end
      end
    end

  elseif ev == "redstone" then
    local level = redstone.getAnalogInput(INPUT_SIDE)
    if level ~= lastLevel then
      local prev = lastLevel
      local curr = level

      local payload = {
        type  = "event",
        event = "redstone",
        side  = RS_SIDE,
        prev  = prev,
        level = curr
      }

      sendToMatchingClients(payload, function(s)
        return redstoneMatches(s.redstone, prev, curr)
      end)

      lastLevel = level
    end

  elseif ev == "playerJoin" or ev == "playerLeave" then
    local username = p1

    -- NEW: include full players list after the change (backwards reminder: extra fields are fine)
    local payload = {
      type     = "event",
      event    = ev,
      username = username,
      players  = getPlayers()
    }

    sendToMatchingClients(payload, function(s)
      return playerMatches(s.players, ev, username)
    end)
  end
end
