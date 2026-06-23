-- External assertion script: validates response basics
-- Referenced via: > ./scripts/assert_response.lua
client.test("External assertion: status is 200", function()
  client.assert(response.status == 200, "Expected 200 from external script, got " .. tostring(response.status))
end)
client.test("External assertion: has json body", function()
  client.assert(response.body ~= nil, "Response body should exist")
  client.assert(type(response.body) == "table" or type(response.body) == "string",
    "Body should be table or string")
end)
client.log("External assertion script executed successfully")
