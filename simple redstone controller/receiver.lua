-- receiver.lua
local OUTPUT_SIDE = "right"
local PROTOCOL    = "N/A_base_grinder__scram"

rednet.open("back")

print("Listening on protocol:", PROTOCOL)

while true do
  local senderId, message, protocol = rednet.receive(PROTOCOL)

  if message == "on" then
    redstone.setOutput(OUTPUT_SIDE, true)
    print("Redstone ON (from "..senderId..")")

  elseif message == "off" then
    redstone.setOutput(OUTPUT_SIDE, false)
    print("Redstone OFF (from "..senderId..")")
  end
end
