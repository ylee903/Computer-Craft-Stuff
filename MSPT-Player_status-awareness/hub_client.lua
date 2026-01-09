-- hub_client.lua (PROTO version)
-- Updated to use player list from hub events (no ping required),
-- but still includes optional queryState() with timeout.

local PROTO = "sam_hub_v1" -- MUST match hub
local HUB_NAME_PREFERRED = nil -- optionally "MainHub"

local SUBSCRIBE = true

local REDSTONE_SUB = {
  enter = { 15 },
  exit  = { 15 },
  -- anyChange = true,
}

local PLAYER_SUB = {
  join = { "Samuel12345678", "Amball2000", "josherage" },
  -- anyJoin = true,
  -- anyLeave = true,
}

local DO_PULSE = true
local PULSE_SIDE = "bottom"
local PULSE_SECONDS = 0.10

local modem = peripheral.find("modem")
if not modem then error("No modem found") end
rednet.open(peripheral.getName(modem))

local function pulse(side, seconds)
  redstone.setOutput(side, true)
  sleep(seconds or 0.1)
  redstone.setOutput(side, false)
end

local function discoverHub(timeoutSeconds)
  rednet.broadcast({ type = "hub_discover" }, PROTO)

  local deadline = timeoutSeconds and (os.clock() + timeoutSeconds) or nil
  while true do
    local remaining = nil
    if deadline then
      remaining = deadline - os.clock()
      if remaining <= 0 then return nil, nil end
    end

    local sender, msg = rednet.receive(PROTO, remaining)
    if sender and type(msg) == "table" then
      if msg.type == "hub_here" or msg.type == "hub_announce" then
        if (not HUB_NAME_PREFERRED) or (msg.name == HUB_NAME_PREFERRED) then
          return sender, msg.name
        end
      end
    end
  end
end

local function register(hubId, redstoneSub, playerSub)
  rednet.send(hubId, {
    type = "register",
    subs = { redstone = redstoneSub, players = playerSub }
  }, PROTO)
end

-- Optional "ping" for current authoritative state (with timeout)
local function queryState(hubId, timeoutSeconds)
  timeoutSeconds = timeoutSeconds or 3
  rednet.send(hubId, { type = "query", q = "state" }, PROTO)

  local deadline = os.clock() + timeoutSeconds
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then return nil end

    local sender, msg = rednet.receive(PROTO, remaining)
    if sender == hubId and type(msg) == "table" then
      if msg.type == "state" then
        return msg -- { type="state", level=..., players={...} }
      end
      -- ignore events/other messages while waiting for state
    end
  end
end

-- ===== local cached players (set) =====
local playersSet = {} -- [username]=true

local function setFromList(list)
  playersSet = {}
  if type(list) == "table" then
    for _, u in ipairs(list) do playersSet[u] = true end
  end
end

local function hasPlayer(name)
  return playersSet[name] == true
end

-- Boot
local hubId, hubName = discoverHub(10)
if not hubId then error("Could not find hub") end
print("Found hub:", hubName, "(id " .. hubId .. ")")

if SUBSCRIBE then
  register(hubId, REDSTONE_SUB, PLAYER_SUB)
  print("Subscribed.")
end

-- Optional initial sync (if you want cache immediately, without waiting for next player event)
-- local st = queryState(hubId, 3)
-- if st and st.players then
--   setFromList(st.players)
--   print(("[players cache] initial sync: %d online; Samuel online=%s")
--     :format(#st.players, tostring(hasPlayer("Samuel12345678"))))
-- end

print("Sleeping for targeted events...")

while true do
  local sender, msg = rednet.receive(PROTO)
  if sender == hubId and type(msg) == "table" then
    if msg.type == "event" then
      -- If hub includes players snapshot on join/leave, update cache
      if msg.event == "playerJoin" or msg.event == "playerLeave" then
        if msg.players ~= nil then
          setFromList(msg.players)
          print(("[players cache] now %d online; Samuel online=%s")
            :format(#msg.players, tostring(hasPlayer("Samuel12345678"))))
        else
          print("[players cache] hub did not include msg.players (old hub?)")
        end
      end

      print(textutils.serialize(msg, { compact = false }))
      if DO_PULSE then pulse(PULSE_SIDE, PULSE_SECONDS) end
    end
  end
end
