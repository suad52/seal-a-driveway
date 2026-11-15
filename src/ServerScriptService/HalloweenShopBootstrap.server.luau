local RS=game:GetService("ReplicatedStorage")
local SSS=game:GetService("ServerScriptService")
local C=require(RS:WaitForChild("HalloweenShopConfig"))
local Diagnostics=require(RS:WaitForChild("HalloweenDiagnostics"))
require(SSS:WaitForChild("HalloweenShopService")).start()
local allowed={[140010128837133]=true,[130455840259328]=true,[120014184236770]=true,[126526085744847]=true,[138676726700999]=true}
if not allowed[game.PlaceId] then return end
local prompts=setmetatable({},{__mode="k"})
local function bind(model)
 if not model then return end
 local prompt=model:FindFirstChild("HalloweenShopPrompt",true)
 if not prompt then
  local host=model:FindFirstChild("InteractionPart",true)
  if not host or not host:IsA("BasePart") then
   host=model:IsA("BasePart") and model or model:IsA("Model") and model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart",true)
  end
  if not host or not host:IsA("BasePart") then return end
  prompt=Instance.new("ProximityPrompt")
  prompt.Name="HalloweenShopPrompt";prompt.ActionText="Open Event Shop";prompt.ObjectText="Halloween Shop"
  prompt.KeyboardKeyCode=Enum.KeyCode.E;prompt.GamepadKeyCode=Enum.KeyCode.ButtonX
  prompt.MaxActivationDistance=12;prompt.RequiresLineOfSight=false;prompt.HoldDuration=0
  prompt.Parent=host
 end
 if not prompts[prompt] then
  prompt.Triggered:Connect(function(p)
   local root=p.Character and p.Character:FindFirstChild("HumanoidRootPart")
   local host=prompt.Parent
   if not root or not host or not host:IsA("BasePart") then Diagnostics.record(p,"HalloweenShop","OpenDenied","Missing character/host",true);return end
   local distance=(root.Position-host.Position).Magnitude
   if distance>prompt.MaxActivationDistance+5 or os.time()>=C.EndsAt then Diagnostics.record(p,"HalloweenShop","OpenDenied","distance="..distance,true);return end
   Diagnostics.record(p,"HalloweenShop","Open",prompt:GetFullName())
   RS.HalloweenShopRemote:FireClient(p,"OpenShop")
  end)
 end
 prompts[prompt]=true
 prompt.Enabled=os.time()<C.EndsAt
end
local function scan()
 local root=workspace:FindFirstChild("HalloweenShop")
 bind(root and root:FindFirstChild("chushiguo2"))
	if game.PlaceId==138676726700999 then
  local hood=workspace:FindFirstChild("Neighbourhood")
  local shop=hood and hood:FindFirstChild("Shop")
  bind(shop and shop:FindFirstChild("chushiguo2"))
 end
 for prompt in pairs(prompts) do if prompt.Parent then prompt.Enabled=os.time()<C.EndsAt else prompts[prompt]=nil end end
end
scan()
while task.wait(5) do scan() end
