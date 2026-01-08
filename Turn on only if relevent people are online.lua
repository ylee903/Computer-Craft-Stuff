-- Players allowed to enable output
local allowedPlayers = {
  Samuel12345678 = true,
  Amball2000     = true,
  josherage      = true
}

-- Find player detector (try both common type names)
local detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
if not detector then
  error('No player detector found (expected type "player_detector" or "playerDetector")')
end

-- Check if any allowed player is online
local function allowedPlayerOnline()
  local players = detector.getOnlinePlayers()
  for _, name in ipairs(players) do
    if allowedPlayers[name] then
      return true
    end
  end
  return false
end

-- Decide output state
local function updateOutput()
  local leverOn = redstone.getInput("left")

  local out = leverOn and allowedPlayerOnline()
  redstone.setOutput("bottom", out)

  if out then
    print("Output ON (lever ON + allowed player online)")
  else
    print("Output OFF")
  end
end

-- Initial run
updateOutput()

-- React to redstone + player join/leave events
while true do
  local event = os.pullEvent()
  if event == "redstone" or event == "playerJoin" or event == "playerLeave" then
    updateOutput()
  end
end
