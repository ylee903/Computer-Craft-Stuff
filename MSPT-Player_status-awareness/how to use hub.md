Got it — here is a **clean, corrected, protocol-aware API contract** you can hand to **other AI / programmers / future-you**.
This version exactly matches the **fixed unified-loop hub + protocol-filtered rednet design** you’re now running.

---

# 📡 Central Hub API Contract

*(CC:Tweaked + Advanced Peripherals + Ender Wireless Modem)*

## Purpose

The **Hub** is a single authoritative computer that:

* Reads **analog redstone level** (0–15) from a fixed side
* Tracks **online players** via a Player Detector
* Emits **targeted wake-up events** to subscribed clients
* Responds to **on-demand queries**
* Prevents client wakeups from unrelated rednet traffic using a **protocol filter**

Clients:

* Do **not** need player detectors
* Do **not** need redstone input wiring
* Can stay asleep until the hub explicitly contacts them
* Can query state at any time

---

## 🔒 Protocol (CRITICAL)

All hub communication **must use the same protocol string**.

```lua
PROTO = "sam_hub_v1"
```

### Why this matters

* Prevents clients from waking on random rednet broadcasts
* Filters traffic at the rednet API level
* Eliminates spam from unrelated computers

🚨 **Every `send`, `broadcast`, and `receive` MUST include `PROTO`.**

---

## 🛰 Hub Discovery

### Client → Network (broadcast)

```lua
rednet.broadcast({ type = "hub_discover" }, PROTO)
```

### Hub → Client (direct reply)

```lua
{ type = "hub_here", name = "MainHub" }
```

### Hub → Network (on startup)

```lua
{ type = "hub_announce", name = "MainHub" }
```

### Client behavior

* Accept either `hub_here` or `hub_announce`
* Store the **sender computer ID** as `hubId`
* Optionally verify `name`

---

## 🧾 Subscription (Targeted Wakeups)

### Client → Hub

```lua
rednet.send(hubId, {
  type = "register",
  subs = {
    redstone = {
      anyChange = true,      -- OPTIONAL: wake on any change
      enter = { 15, 7 },     -- OPTIONAL: wake when signal becomes these levels
      exit  = { 15 },        -- OPTIONAL: wake when signal leaves these levels
    },
    players = {
      anyJoin  = true,       -- OPTIONAL: wake on any player join
      anyLeave = true,       -- OPTIONAL: wake on any player leave
      join  = { "Samuel12345678" }, -- OPTIONAL: specific join
      leave = { "Amball2000" }      -- OPTIONAL: specific leave
    }
  }
}, PROTO)
```

### Semantics

* **Enter** triggers when `prev ≠ level` and `level ∈ enter`
* **Exit** triggers when `prev ∈ exit` and `prev ≠ level`
* `enter` and `exit` sets may differ
* Lists are normalized by the hub into fast lookup maps

### Hub → Client (ack)

```lua
{ type = "ok", msg = "registered" }
```

---

## ❌ Unsubscribe

### Client → Hub

```lua
rednet.send(hubId, { type = "unregister" }, PROTO)
```

### Hub → Client

```lua
{ type = "ok", msg = "unregistered" }
```

---

## 🔔 Event Messages (Wakeups)

These messages **wake the client** from `rednet.receive(PROTO)`.

### 🔴 Redstone Event

```lua
{
  type  = "event",
  event = "redstone",
  side  = "back",
  prev  = 7,
  level = 15
}
```

### 👤 Player Events

```lua
{ type = "event", event = "playerJoin",  username = "PlayerName" }
{ type = "event", event = "playerLeave", username = "PlayerName" }
```

### Client expectation

* Clients should assume **this is a wake trigger**
* Act immediately (pulse redstone, start machine, break block, etc.)
* Then return to sleep

---

## 🔍 Queries (On-Demand / Pull)

Clients may query the hub **at any time**, even without subscribing.

### Query: Full State

**Client → Hub**

```lua
rednet.send(hubId, { type = "query", q = "state" }, PROTO)
```

**Hub → Client**

```lua
{ type = "state", level = 12, players = { "A", "B", "C" } }
```

---

### Query: Redstone Level Only

```lua
rednet.send(hubId, { type = "query", q = "level" }, PROTO)
```

Response:

```lua
{ type = "level", level = 12 }
```

---

### Query: Player List Only

```lua
rednet.send(hubId, { type = "query", q = "players" }, PROTO)
```

Response:

```lua
{ type = "players", players = { "A", "B", "C" } }
```

---

## 💤 Client Sleep Pattern (Recommended)

```lua
while true do
  local sender, msg = rednet.receive(PROTO)
  if sender == hubId and msg.type == "event" then
    -- act (pulse redstone, wake machine, etc.)
  end
end
```

* Client consumes **zero CPU** while sleeping
* Only wakes on **protocol-matched messages**

---

## 🧠 Design Guarantees

✔ Clients only wake when **hub directly targets them**
✔ Random rednet broadcasts are ignored
✔ Hub is single authoritative source
✔ Event-driven (no polling loops)
✔ Persistent subscriptions survive hub reboot
✔ Safe unified event loop (no event stealing)

---

## 🔐 Optional Security (Future Extension)

To prevent spoofing:

* Add a shared secret field (e.g. `token`)
* Hub ignores messages without correct token
* Token included in all hub replies

---

## 📌 Summary

If you remember **one rule**, remember this:

> **All hub traffic must use the same `PROTO`, and clients must `receive(PROTO)`**

This is the difference between:

* clean, silent, targeted wakeups
* and chaotic rednet noise waking everything

---

If you want next:

* a tiny reusable `hub_api.lua` wrapper
* heartbeat / client expiry
* multi-hub priority election
* raw modem channel isolation (no rednet at all)

Just say the word.




















No need to paste `hub_client.lua` — I can give you **both updated files** here, and you can just copy/paste.
You *do* need to apply the same `PROTO` string on **both hub and client**, otherwise they won’t find each other.

Below are the **updated versions** with protocol filtering added.

---

# ✅ Updated HUB `startup` (with protocol)

Changes made:

* Added `local PROTO = "sam_hub_v1"`
* Added `PROTO` to **every** `rednet.send(...)` and `rednet.broadcast(...)`
* Added a guard so the hub only handles `rednet_message` events that match the protocol (`p3 == PROTO`)

```lua
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
    local payload = { type = "event", event = ev, username = username }

    sendToMatchingClients(payload, function(s)
      return playerMatches(s.players, ev, username)
    end)
  end
end
```

---

# ✅ Updated `hub_client.lua` (with protocol)

You should make these changes in *any* client program:

* Add `PROTO`
* Use `rednet.receive(PROTO, ...)` and `rednet.broadcast(..., PROTO)` and `rednet.send(..., PROTO)`

Here’s a full updated client (same behavior as before, but quiet):

```lua
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
```

---

## Do you *need* to give me `hub_client.lua`?

No — not if you just want the protocol fix. The rule is simple:

✅ **Every** send/broadcast/receive on both sides must include the **same `PROTO` string**.

If you have other custom client programs, change:

* `rednet.receive()` → `rednet.receive(PROTO)`
* `rednet.send(...)` → `rednet.send(..., PROTO)`
* `rednet.broadcast(...)` → `rednet.broadcast(..., PROTO)`

…and the random wake spam stops.

If you want, paste your *actual* client file that’s spamming and I’ll patch it line-for-line.
