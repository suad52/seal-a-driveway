local Http=game:GetService("HttpService")
local M={}
local function decode(raw)
 local ok,v=pcall(Http.JSONDecode,Http,type(raw)=="string" and raw or "{}")
 return ok and type(v)=="table" and v or {}
end
local function restore(data)
 local w=data.WorldProgress and data.WorldProgress["3"]
 local saved=w and w.HalloweenShop
 if type(saved)=="table" then
  if type(data.HalloweenShopState)~="string" or data.HalloweenShopState=="{}" then data.HalloweenShopState=saved.state end
  data.PumpkinSpentTotal=math.max(tonumber(data.PumpkinSpentTotal) or 0,tonumber(saved.spent) or 0)
 end
 return data
end
function M.wrap(P)
 if P.HalloweenBridgeVersion==2 then return end
 P.HalloweenBridgeVersion=2
 local migrate,merge=P.migrate,P.merge
 P.migrate=function(raw) return restore(migrate(raw)) end
 P.merge=function(raw,snapshot,world,maxima,reset)
  local old=P.migrate(raw)
  local previous=decode(old.HalloweenShopState)
  local nextState=decode(snapshot.HalloweenShopState or old.HalloweenShopState)
  for _,key in ipairs({"owned","receipts"}) do
   nextState[key]=type(nextState[key])=="table" and nextState[key] or {}
   for id,value in pairs(type(previous[key])=="table" and previous[key] or {}) do if value==true then nextState[key][id]=true end end
  end
  local state=Http:JSONEncode(nextState)
  local oldSpent=math.max(0,tonumber(old.PumpkinSpentTotal) or 0)
  local spent=math.max(oldSpent,tonumber(snapshot.PumpkinSpentTotal) or oldSpent)
  local earned=math.max((tonumber(old.PumpkinCoins) or 0)+oldSpent,(tonumber(snapshot.PumpkinCoins) or tonumber(old.PumpkinCoins) or 0)+(tonumber(snapshot.PumpkinSpentTotal) or oldSpent))
  local result=merge(old,snapshot,world,maxima,reset)
  result.HalloweenShopState=state;result.PumpkinSpentTotal=spent;result.PumpkinCoins=math.max(0,earned-spent)
  result.WorldProgress["3"]=result.WorldProgress["3"] or {}
  result.WorldProgress["3"].HalloweenShop={state=state,spent=spent}
  return result
 end
end
return M
