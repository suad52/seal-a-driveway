local Run=game:GetService("RunService")
local D={};local logs=setmetatable({},{__mode="k"});local warned=setmetatable({},{__mode="k"})
function D.record(p,system,code,detail,failure)
 local line=string.format("[%s] %s | %s | %s",system,p.Name,code,tostring(detail or ""))
 local rows=logs[p] or {};logs[p]=rows;rows[#rows+1]=line;if #rows>20 then table.remove(rows,1) end
 if p:GetAttribute("HalloweenDebug")==true or Run:IsStudio() then print(line)
 elseif failure and os.clock()-(warned[p] or -100)>10 then warned[p]=os.clock();warn(line) end
end
function D.history(p) return table.clone(logs[p] or {}) end
return D
