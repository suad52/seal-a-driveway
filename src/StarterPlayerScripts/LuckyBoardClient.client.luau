--!strict
--[[
	LuckyBoardClient -- the gold board on the lawn of a premium contract.

	The perk is worthless if you cannot see it. A driveway that quietly pays five
	times is indistinguishable from one that does not until the money lands, by
	which point the decision it should have informed -- work THAT one next -- is
	already made.

	Entirely client-side, and it has to be: which slabs are premium is a fact
	about THIS player (see Lucky), so a board parented into Workspace by the server
	would advertise one player's contract to everybody. Built here, it exists for
	this client only, which is the same arrangement TutorialClient's waypoint uses.

	No state and no remote: Lucky.contractOf is a pure function of (player, slab,
	lap), so this file simply asks it about every tagged slab and draws the answer.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Lucky = require(Pack:WaitForChild("Lucky"))
local UIPack = ReplicatedStorage:WaitForChild("SealerUI")
local Passes = require(UIPack:WaitForChild("Passes"))
local Rebirth = require(UIPack:WaitForChild("Rebirth"))

local plr = Players.LocalPlayer

local GOLD = Color3.fromRGB(255, 206, 56)
local INK = Color3.fromRGB(24, 22, 18)

local folder = Instance.new("Folder")
folder.Name = "LuckyBoards"
folder.Parent = workspace

local boards: { [BasePart]: Model } = {}

local function build(slab: BasePart, mult: number, label: string): Model
	local model = Instance.new("Model")
	model.Name = "LuckyBoard"

	--[[
		Stood at the slab's edge rather than on it.

		Anything standing ON a sealable slab is ground the player can never squeegee
		-- the rule the whole world is built around -- and a board that made its own
		job uncompletable would be a spectacular own goal. CanQuery is off for the
		same reason twice over: it keeps this out of the pour aim ray AND out of the
		coverage mask's blocker sweep.
	]]
	local function piece(name: string, size: Vector3, colour: Color3, cf: CFrame): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = colour
		p.Material = Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.CFrame = cf
		p.Parent = model
		return p
	end

	-- the near edge of the slab, facing the road side it is nearest to
	local top = slab.Position.Y + slab.Size.Y * 0.5
	local alongX = slab.Size.X > slab.Size.Z
	local out = if alongX then Vector3.new(0, 0, slab.Size.Z * 0.5 + 2.5)
		else Vector3.new(slab.Size.X * 0.5 + 2.5, 0, 0)
	local at = slab.CFrame * CFrame.new(out)
	local face = CFrame.lookAt(Vector3.new(at.Position.X, top, at.Position.Z),
		Vector3.new(slab.Position.X, top, slab.Position.Z))

	piece("Post", Vector3.new(0.4, 5, 0.4), Color3.fromRGB(92, 74, 40), face * CFrame.new(0, 2.5, 0))
	local board = piece("Board", Vector3.new(7.4, 2.6, 0.3), GOLD, face * CFrame.new(0, 5.4, 0))

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.Parent = board

	local top1 = Instance.new("TextLabel")
	top1.BackgroundTransparency = 1
	top1.Size = UDim2.fromScale(1, 0.52)
	top1.Font = Enum.Font.LuckiestGuy
	top1.Text = label
	top1.TextColor3 = INK
	top1.TextScaled = true
	top1.Parent = gui

	local bottom = Instance.new("TextLabel")
	bottom.BackgroundTransparency = 1
	bottom.Position = UDim2.fromScale(0, 0.5)
	bottom.Size = UDim2.fromScale(1, 0.46)
	bottom.Font = Enum.Font.LuckiestGuy
	bottom.Text = ("PAYS x%d"):format(mult)
	bottom.TextColor3 = INK
	bottom.TextScaled = true
	bottom.Parent = gui

	model.Parent = folder
	return model
end

local function refresh()
	local wanted: { [BasePart]: boolean } = {}
	if Passes.owns(plr, "VIP") then
		for _, slab in ipairs(CollectionService:GetTagged("SealableDriveway")) do
			if slab:IsA("BasePart") then
				local mult, label = Lucky.contractOf(plr, slab)
				if mult > 1 and label then
					wanted[slab] = true
					if not boards[slab] then boards[slab] = build(slab, mult, label) end
				end
			end
		end
	end
	-- a rebirth deals a new hand, so boards come down as well as up
	for slab, model in pairs(boards) do
		if not wanted[slab] or not slab.Parent then
			model:Destroy()
			boards[slab] = nil
		end
	end
end

-- The three things that change the answer: owning VIP, the lap turning over,
-- and the map's tagged slabs arriving in the first place.
plr:GetAttributeChangedSignal(Passes.attrName("VIP")):Connect(refresh)
plr:GetAttributeChangedSignal(Rebirth.Attr):Connect(refresh)
CollectionService:GetInstanceAddedSignal("SealableDriveway"):Connect(function() task.defer(refresh) end)

task.spawn(function()
	-- the profile carries the rebirth count, and the lap is in the seed
	local t0 = os.clock()
	while not plr:GetAttribute("ProfileLoaded") and os.clock() - t0 < 20 do task.wait(0.2) end
	refresh()
end)
