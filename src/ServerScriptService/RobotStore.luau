local DSS = game:GetService("DataStoreService")
local Http = game:GetService("HttpService")
local Config = require(game.ReplicatedStorage.DrivewaySealer.RobotConfig)
local Store = DSS:GetDataStore(Config.StoreName)
local M = {}
local token = game.JobId .. Http:GenerateGUID(false)
local locks = {}
function M.serial(id, fn)
 while locks[id] do task.wait(.05) end
 locks[id] = true
 local result = table.pack(pcall(fn))
 locks[id] = nil
 if not result[1] then warn("[RobotHelper] " .. tostring(result[2])); return nil end
 return table.unpack(result, 2, result.n)
end
function M.write(id, transform, claim, release)
 local result
 local ok, err = pcall(function()
  result = Store:UpdateAsync(tostring(id), function(old)
   local d = old or {credits=0, remaining=0, receipts={}}
   if d.owner and d.owner ~= token and (d.lease or 0) > os.time() then return nil end
   if not claim and d.owner ~= token then return nil end
   d = transform(d)
   if not d then return nil end
   d.owner = if release then nil else token
   d.lease = if release then 0 else os.time()+120
   return d
  end)
 end)
 if not ok then warn("[RobotHelper] Save failed: " .. tostring(err)); return nil end
 return result
end
return M
