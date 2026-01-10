-- controller.lua
local TARGET_ID = 12
local PROTOCOL  = "N/A_base_grinder__scram"

rednet.open("back")

print("Sending ON")
rednet.send(TARGET_ID, "on", PROTOCOL)

sleep(5)

print("Sending OFF")
rednet.send(TARGET_ID, "off", PROTOCOL)
