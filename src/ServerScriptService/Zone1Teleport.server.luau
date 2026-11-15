----!strict

--local Players = game:GetService("Players")
--local ReplicatedStorage = game:GetService("ReplicatedStorage")
--local RunService = game:GetService("RunService")

--local uiPack = ReplicatedStorage:WaitForChild("SealerUI")
--local sealerPack = ReplicatedStorage:WaitForChild("DrivewaySealer")
--local Sections = require(sealerPack:WaitForChild("Sections"))

--local remotes = uiPack:FindFirstChild("Remotes")
--if not remotes then
--	remotes = Instance.new("Folder")
--	remotes.Name = "Remotes"
--	remotes.Parent = uiPack
--end

--local remote = remotes:FindFirstChild("Zone1Teleport")
--if not remote then
--	remote = Instance.new("RemoteEvent")
--	remote.Name = "Zone1Teleport"
--	remote.Parent = remotes
--end

--if not remote:IsA("RemoteEvent") then
--	error("SealerUI.Remotes.Zone1Teleport must be a RemoteEvent")
--end

--local zone1Remote = remote :: RemoteEvent
--local COOLDOWN = 2
--local GROUND_SEARCH_UP = 30
--local GROUND_SEARCH_DOWN = 120
--local FLOOR_CLEARANCE = 0.35

--local lastUse: { [Player]: number } = {}

--local function zone2Unlocked(player: Player): boolean
--	local firstSection = Sections.List[1]
--	if not firstSection then
--		return false
--	end

--	return player:GetAttribute(Sections.openAttr(firstSection.id)) == true
--end

--local function teleportRoot(): Instance?
--	return workspace:FindFirstChild("TeleportPoint")
--end

--local function teleportAnchor(): BasePart?
--	local root = teleportRoot()
--	if not root then
--		return nil
--	end

--	local named = root:FindFirstChild("teleport", true)
--	if named and named:IsA("BasePart") then
--		return named
--	end

--	if root:IsA("BasePart") then
--		return root
--	end

--	return root:FindFirstChildWhichIsA("BasePart", true)
--end

--local function removeSeatWeld(character: Model, humanoid: Humanoid)
--	local seat = humanoid.SeatPart
--	humanoid.Sit = false
--	humanoid.PlatformStand = false

--	if not seat then
--		return
--	end

--	for _, child in ipairs(seat:GetChildren()) do
--		if child:IsA("Weld") and child.Name == "SeatWeld" then
--			local connected = child.Part0 and child.Part0:IsDescendantOf(character)
--				or child.Part1 and child.Part1:IsDescendantOf(character)
--			if connected then
--				child:Destroy()
--			end
--		end
--	end
--end

--local function groundPosition(character: Model, anchor: BasePart): Vector3
--	local rootObject = teleportRoot()

--	local params = RaycastParams.new()
--	params.FilterType = Enum.RaycastFilterType.Exclude
--	params.FilterDescendantsInstances = if rootObject
--		then { character, rootObject }
--		else { character }

--	local origin = anchor.Position + Vector3.new(0, GROUND_SEARCH_UP, 0)
--	local result = workspace:Raycast(
--		origin,
--		Vector3.new(0, -GROUND_SEARCH_DOWN, 0),
--		params
--	)

--	if result then
--		return result.Position
--	end

--	return anchor.Position
--end

--local function uprightFacing(anchor: BasePart): Vector3
--	local look = anchor.CFrame.LookVector
--	local flat = Vector3.new(look.X, 0, look.Z)

--	if flat.Magnitude < 0.01 then
--		return Vector3.new(0, 0, -1)
--	end

--	return flat.Unit
--end

--local function teleportPlayer(player: Player)
--	if not zone2Unlocked(player) then
--		return
--	end

--	local character = player.Character
--	if not character then
--		return
--	end

--	local humanoid = character:FindFirstChildOfClass("Humanoid")
--	local root = character:FindFirstChild("HumanoidRootPart")
--	local anchor = teleportAnchor()

--	if not humanoid or humanoid.Health <= 0 then
--		return
--	end
--	if not root or not root:IsA("BasePart") then
--		return
--	end
--	if not anchor then
--		return
--	end

--	removeSeatWeld(character, humanoid)
--	RunService.Heartbeat:Wait()
--	RunService.Heartbeat:Wait()

--	root.AssemblyLinearVelocity = Vector3.zero
--	root.AssemblyAngularVelocity = Vector3.zero

--	local ground = groundPosition(character, anchor)
--	local rootHeight = humanoid.HipHeight + root.Size.Y * 0.5 + FLOOR_CLEARANCE
--	local spawnPosition = Vector3.new(
--		anchor.Position.X,
--		ground.Y + rootHeight,
--		anchor.Position.Z
--	)

--	local facing = uprightFacing(anchor)
--	local destination = CFrame.lookAt(spawnPosition, spawnPosition + facing)

--	root.Anchored = true
--	character:PivotTo(destination)
--	root.AssemblyLinearVelocity = Vector3.zero
--	root.AssemblyAngularVelocity = Vector3.zero

--	RunService.Heartbeat:Wait()
--	RunService.Heartbeat:Wait()

--	root.Anchored = false
--	humanoid.Sit = false
--	humanoid.PlatformStand = false
--	humanoid.AutoRotate = true
--	humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)

--	root.AssemblyLinearVelocity = Vector3.zero
--	root.AssemblyAngularVelocity = Vector3.zero

--	zone1Remote:FireClient(player, "Arrived")
--end

--zone1Remote.OnServerEvent:Connect(function(player: Player)
--	local now = os.clock()
--	if now - (lastUse[player] or 0) < COOLDOWN then
--		return
--	end
--	lastUse[player] = now

--	teleportPlayer(player)
--end)

--Players.PlayerRemoving:Connect(function(player: Player)
--	lastUse[player] = nil
--end)
