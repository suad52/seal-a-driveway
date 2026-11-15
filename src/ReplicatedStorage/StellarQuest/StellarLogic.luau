local C=require(script.Parent.StellarConfig)
local M={}
function M.normalize(raw)
 local d=type(raw)=="table" and raw or {}
 d.events=type(d.events)=="table" and d.events or {}
 local e=d.events[C.EventId]
 if type(e)~="table" then e={} end
 e.days=type(e.days)=="table" and e.days or {}
 e.batches=type(e.batches)=="table" and e.batches or {}
 d.events[C.EventId]=e
 return d,e
end
function M.completed(e)
 local n=0
 for _,d in pairs(e.days) do if type(d)=="table" and d.complete==true then n+=1 end end
 return math.min(7,n)
end
function M.apply(raw,batch)
 local d,e=M.normalize(raw)
 if (tonumber(e.batches[batch.session]) or 0)<batch.seq then
  for key,delta in pairs(batch.days or {}) do
   local day=tonumber(key)
   if day and C.Pairs[day] then
    local r=type(e.days[key])=="table" and e.days[key] or {}
    for id,amount in pairs(delta) do
     if C.Tasks[id] then r[id]=math.min(C.Tasks[id].target,math.max(0,tonumber(r[id]) or 0)+math.max(0,tonumber(amount) or 0)) end
    end
    local done=true
    for _,id in ipairs(C.tasks(day)) do if (tonumber(r[id]) or 0)<C.Tasks[id].target then done=false end end
    if done then r.complete=true end
    e.days[key]=r
   end
  end
  e.batches[batch.session]=batch.seq
 end
 if M.completed(e)>=7 then e.earned=true end
 return d,e
end
return M
