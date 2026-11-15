local Http=game:GetService("HttpService")
local S={}
function S.read(p)
 local ok,s=pcall(Http.JSONDecode,Http,p:GetAttribute("HalloweenShopState") or "{}")
 if not ok or type(s)~="table" then s={} end
 s.owned=type(s.owned)=="table" and s.owned or {}
 s.receipts=type(s.receipts)=="table" and s.receipts or {}
 s.helpers=math.max(0,math.floor(tonumber(s.helpers) or 0))
 s.coats=math.max(0,math.floor(tonumber(s.coats) or 0))
 s.pendingHelpers=type(s.pendingHelpers)=="table" and s.pendingHelpers or {}
 return s
end
function S.write(p,s)
 p:SetAttribute("HalloweenShopState",Http:JSONEncode(s))
 for _,id in ipairs({"Spell","PumpkinRescue","Nightmares","Sweet"}) do p:SetAttribute("HalloweenOwned_"..id,s.owned[id]==true) end
 local count=s.helpers
 for _ in pairs(s.pendingHelpers or {}) do count+=1 end
 p:SetAttribute("HalloweenHelperCredits",count)
 p:SetAttribute("HalloweenCoatCredits",s.coats)
 local function publish(attr,ids)
  local raw=p:GetAttribute(attr) or ""
  local found={};for id in raw:gmatch("[^,]+") do found[id]=true end
  local list={};for id in raw:gmatch("[^,]+") do list[#list+1]=id end
  for _,entry in ipairs(ids) do if s.owned[entry[1]] and not found[entry[2]] then list[#list+1]=entry[2];found[entry[2]]=true end end
  p:SetAttribute(attr,table.concat(list,","))
 end
 publish("SkinsOwned",{{"Sweet","Sweet"},{"Spell","Spell"}})
 publish("AsphaltColorsOwned",{{"PumpkinRescue","pumpkinrescue"},{"Nightmares","nightmares"}})
end
function S.restore(p,data)
 p:SetAttribute("HalloweenShopState",type(data.HalloweenShopState)=="string" and data.HalloweenShopState or "{}")
 p:SetAttribute("PumpkinSpentTotal",math.max(0,math.floor(tonumber(data.PumpkinSpentTotal) or 0)))
 local state=S.read(p)
 for id in tostring(data.SkinsOwned or ""):gmatch("[^,]+") do if id=="Sweet" or id=="Spell" then state.owned[id]=true end end
 for id in tostring(data.AsphaltColorsOwned or ""):gmatch("[^,]+") do
  if id=="pumpkinrescue" then state.owned.PumpkinRescue=true elseif id=="nightmares" then state.owned.Nightmares=true end
 end
 S.write(p,state)
end
function S.capture(p,data)
 data.HalloweenShopState=p:GetAttribute("HalloweenShopState") or "{}"
 data.PumpkinSpentTotal=p:GetAttribute("PumpkinSpentTotal") or 0
end
return S
