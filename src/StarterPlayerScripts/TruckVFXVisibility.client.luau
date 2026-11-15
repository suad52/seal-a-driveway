local tracked={}
local function effect(v)
 return v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Beam") or v:IsA("Light")
end
local function watch(root)
 if root.Name~="HalloweenTruckVFX" or not root:IsA("BasePart") or tracked[root] then return end
 local rig=root.Parent
 if not rig or not rig:IsA("Model") then return end
 local state={effects={},connections={},base=nil,baseConnection=nil,hidden=nil}
 tracked[root]=state
 local function apply(v,saved,hidden)
  if not v.Parent then return end
  local enabled=not hidden and saved.enabled
  if v.Enabled~=enabled then v.Enabled=enabled end
  if hidden and (v:IsA("ParticleEmitter") or v:IsA("Trail")) then v:Clear() end
 end
 local update
 local function bindBase()
  local base=rig:FindFirstChild("Base",true) or rig.PrimaryPart
  if base and not base:IsA("BasePart") then base=nil end
  if base==state.base then return end
  if state.baseConnection then state.baseConnection:Disconnect();state.baseConnection=nil end
  state.base=base
  if base then state.baseConnection=base:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function() update() end) end
 end
 update=function()
  bindBase()
  local hidden=not state.base or state.base.LocalTransparencyModifier>=.99
  if hidden==state.hidden then return end
  state.hidden=hidden
  for v,saved in pairs(state.effects) do apply(v,saved,hidden) end
 end
 local function add(v)
  if not effect(v) or state.effects[v] then return end
  local saved={enabled=v.Enabled}
  state.effects[v]=saved
  apply(v,saved,state.hidden~=false)
 end
 update()
 for _,v in ipairs(root:GetDescendants()) do add(v) end
 table.insert(state.connections,root.DescendantAdded:Connect(add))
 table.insert(state.connections,rig.DescendantAdded:Connect(function(v)
  if v.Name=="Base" then update() end
 end))
 table.insert(state.connections,rig:GetPropertyChangedSignal("PrimaryPart"):Connect(update))
 table.insert(state.connections,root.AncestryChanged:Connect(function()
  if root:IsDescendantOf(workspace) then return end
  if state.baseConnection then state.baseConnection:Disconnect() end
  for _,connection in ipairs(state.connections) do connection:Disconnect() end
  for v,saved in pairs(state.effects) do if v.Parent then v.Enabled=saved.enabled end end
  tracked[root]=nil
 end))
end
for _,v in ipairs(workspace:GetDescendants()) do watch(v) end
workspace.DescendantAdded:Connect(watch)
