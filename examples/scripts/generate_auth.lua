-- External pre-request script: generates a dynamic auth token.
-- This file is referenced via: < ./scripts/generate_auth.lua
local ts = os.time()
local token = "ext-" .. ts .. "-" .. math.random(1000, 9999)
request.variables.set("auth_token", token)
client.log("Generated external token: " .. token)
