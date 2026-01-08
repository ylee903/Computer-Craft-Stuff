-- hub_client.lua (PROTO version)

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

local function queryState(hubId)
  rednet.send(hubId, { type = "query", q = "state" }, PROTO)
  while true do
    local sender, msg = rednet.receive(PROTO)
    if sender == hubId and type(msg) == "table" and msg.type == "state" then
      return msg
    end
  end
end

-- Boot
local hubId, hubName = discoverHub(10)
if not hubId then error("Could not find hub") end
print("Found hub:", hubName, "(id " .. hubId .. ")")

if SUBSCRIBE then
  register(hubId, REDSTONE_SUB, PLAYER_SUB)
  print("Subscribed.")
end

-- Optional initial query:
-- local state = queryState(hubId)
-- print(textutils.serialize(state, {compact=false}))

print("Sleeping for targeted events...")

while true do
  local sender, msg = rednet.receive(PROTO)
  if sender == hubId and type(msg) == "table" then
    if msg.type == "event" then
      print(textutils.serialize(msg, { compact = false }))
      if DO_PULSE then pulse(PULSE_SIDE, PULSE_SECONDS) end
    end
  end
end
