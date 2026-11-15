local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Console = require(game:GetService("ReplicatedStorage"):WaitForChild("SealerUI"):WaitForChild("ConsoleControls"))

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Pack:WaitForChild("Config"))
local DrivewaySurface = require(Pack:WaitForChild("DrivewaySurface"))
local Detail = DrivewaySurface.Detail
local SurfaceFrame = require(Pack.SurfaceFrame)
local ScoreModel = require(Pack:WaitForChild("ScoreModel"))
local Interface = require(Pack:WaitForChild("Interface"))
local Effects = require(Pack:WaitForChild("Effects"))
local SoundKit = require(Pack:WaitForChild("SoundKit"))
local RigController = require(Pack:WaitForChild("RigController"))
local MissedHighlight = require(Pack:WaitForChild("MissedHighlight"))
local Depot = require(Pack:WaitForChild("Depot"))
local SqueegeePose = require(Pack:WaitForChild("SqueegeePose"))
local WandPose = require(Pack:WaitForChild("WandPose"))
local Sections = require(Pack:WaitForChild("Sections"))
local SlabTint = require(Pack:WaitForChild("SlabTint"))

local Afk = require(Pack:WaitForChild("Afk"))
local Passes = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Passes"))

local Boosts = require(ReplicatedStorage.SealerUI:WaitForChild("Boosts"))

local HudBus = (function()
	local ui = ReplicatedStorage:FindFirstChild("SealerUI")
	local m = ui and ui:FindFirstChild("HudBus")
	return m and require(m) or { push = function() end }
end)()

local HudActions = (function()
	local ui = ReplicatedStorage:FindFirstChild("SealerUI")
	local m = ui and ui:FindFirstChild("HudActions")
	return m and require(m) or { register = function() end, fire = function() return false end }
end)()

local CashFx = (function()
	local ui = ReplicatedStorage:FindFirstChild("SealerUI")
	local m = ui and ui:FindFirstChild("CashFx")
	return m and require(m) or { hintFrom = function() end }
end)()

local Remotes = Pack:WaitForChild("Remotes")

local ReportCoverage = Remotes:WaitForChild("ReportCoverage") :: RemoteEvent
local DrivewayComplete = Remotes:WaitForChild("DrivewayComplete") :: RemoteEvent
local TruckControl = Remotes:WaitForChild("TruckControl") :: RemoteEvent

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local BLADE_FORWARD = 2.9

local ENDLESS_ID = "Endless"
local ENDLESS_PER_STUD = 1.32
local ENDLESS_IDLE     = 3.60
local ENDLESS_LEAD     = 1.10

local ENDLESS_SPACING  = 0.72
local ENDLESS_MAX_PTS  = 16
local AIM_RANGE = 20

local POP_EVERY = 470

local POP_ENABLED = true

local WET_TOUCH_REF = 34

if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
	Config.CellSize = 0.45
	Config.MaxGridCells = 16000
	Config.SimHz = 24
	Config.MeshStep = 3
else

	Config.CellSize = 0.40
	Config.MaxGridCells = 48000
end

SoundKit.preload()

local surfaces: { any } = {}
local scores: { [any]: any } = {}
local bySlab: { [BasePart]: any } = {}

do
	local Tutorial = require(ReplicatedStorage.SealerUI:WaitForChild("Tutorial"))

	Tutorial.onChanged(player, function()
		local easy = Tutorial.inProgress(player)
		for _, s in ipairs(surfaces) do s:SetEasyFlow(easy) end
	end)
end

local hud = Interface.new(player:WaitForChild("PlayerGui"))

local fxPurged = false
local function fxFolder(): Folder
	local f = workspace:FindFirstChild("SealerVisuals")
	if not f then
		f = Instance.new("Folder")
		f.Name = "SealerVisuals"
		f.Parent = workspace
		fxPurged = true
	elseif not fxPurged then
		fxPurged = true
		for _, stale in ipairs(f:GetChildren()) do stale:Destroy() end
	end
	return f :: Folder
end

local comboLive = false

local function registerSlab(slab: Instance)
    local bonus = slab:GetAttribute("BonusZone")
    if bonus and player:GetAttribute("BonusClear_" .. bonus) ~= true then return nil end
	if not slab:IsA("BasePart") or bySlab[slab] then return nil end
	local surface = DrivewaySurface.new(slab)
	if not surface then return nil end
	local score = ScoreModel.new(surface)

	score:OnBonus(function(labelText, amount, combo)
		if comboLive then return end
		hud:Toast(labelText, amount, combo)
	end)
	surfaces[#surfaces + 1] = surface
	scores[surface] = score
	bySlab[slab] = surface

	surface.sectionKey = Sections.keyOf(slab)

	surface:SetEasyFlow(require(ReplicatedStorage.SealerUI.Tutorial).inProgress(player))
	return surface
end

local BUILD_RADIUS = 260
local pending: { BasePart } = {}
local queued: { [BasePart]: boolean } = {}
local buildingNow: any = nil

local wantSlab: BasePart? = nil

local buildDeadline = 0
local stalled: { any } = {}

local function queueSlab(slab: Instance)
	if not slab:IsA("BasePart") then return end
	if queued[slab] or bySlab[slab] then return end
	queued[slab] = true
	table.insert(pending, slab)
end

local function wantBuild(inst: Instance?)
	if inst and inst:IsA("BasePart") and not bySlab[inst]
		and CollectionService:HasTag(inst, Sections.Tag) then
		wantSlab = inst
	end
end

local function retryLater(slab: BasePart)
	queued[slab] = nil
	task.delay(5, function()
		if slab.Parent and CollectionService:HasTag(slab, Sections.Tag) then queueSlab(slab) end
	end)
end

for _, slab in ipairs(CollectionService:GetTagged("SealableDriveway")) do
	queueSlab(slab)
end
CollectionService:GetInstanceAddedSignal("SealableDriveway"):Connect(queueSlab)
for index = 1, 2 do
    player:GetAttributeChangedSignal("BonusClear_" .. index):Connect(function()
        if player:GetAttribute("BonusClear_" .. index) then
            local zone = workspace:FindFirstChild("BonusZone" .. index)
            if zone then for _, road in ipairs(zone.Road:GetDescendants()) do
                if CollectionService:HasTag(road, "SealableDriveway") then queueSlab(road) end
            end end
        end
    end)
end

local EVICT_RADIUS = BUILD_RADIUS + 140

local KEEP_CELL_BUDGET = 260000
local keptWork: { [string]: any } = {}
local keptOrder: { string } = {}
local keptCells = 0

local function forgetKept(key: string)
	local snap = keptWork[key]
	if not snap then return end
	keptWork[key] = nil
	keptCells -= snap.W * snap.H
	local i = table.find(keptOrder, key)
	if i then table.remove(keptOrder, i) end
end

local function forgetAllKept()
	keptWork = {}
	keptOrder = {}
	keptCells = 0
end

local function keepWork(surface)
	local key = surface.sectionKey
	if not key or not surface.ready or surface.completed then return end
	local g = surface.grid

	if g.sealedFrac <= 0 and g.stainCount <= 0 and surface:LooseVolume() <= 0.001 then
		return
	end
	forgetKept(key)
	local snap = g:Snapshot()
	local sc = scores[surface]
	snap.bonusTotal = (sc and sc.bonusTotal) or 0
	keptWork[key] = snap
	keptOrder[#keptOrder + 1] = key
	keptCells += snap.W * snap.H

	while keptCells > KEEP_CELL_BUDGET and #keptOrder > 1 do
		forgetKept(keptOrder[1])
	end
end

local function restoreWork(surface)
	local key = surface and surface.sectionKey
	if not key then return end
	local snap = keptWork[key]
	if not snap then return end

	forgetKept(key)
	if not surface.ready or surface.completed then return end
	if not surface.grid:Restore(snap) then return end

	local sc = scores[surface]
	if sc then sc.bonusTotal = snap.bonusTotal or 0 end
end

local function releaseSurface(surface)
	local i = table.find(surfaces, surface)
	if i then table.remove(surfaces, i) end
	scores[surface] = nil
	local slab = surface.slab
	if slab then
		bySlab[slab] = nil

		queued[slab] = nil

		if slab.Parent and CollectionService:HasTag(slab, Sections.Tag) then
			queueSlab(slab)
		end
	end
	if buildingNow == surface then buildingNow = nil end

	keepWork(surface)
	surface:Destroy()
end

local robotKeeps = require(Pack:WaitForChild("RobotPainter")).bind(function(slab) return bySlab[slab] end, wantBuild)
local function safeToRelease(s, hrp: BasePart): boolean
 if robotKeeps(s.slab) then return false end
	if not s.ready then return false end
	local slab = s.slab

	if not slab or not slab.Parent then return true end

	local l = s.topCF:PointToObjectSpace(hrp.Position)
	local dx = math.max(math.abs(l.X) - s.frameSize.X * 0.5, 0)
	local dz = math.max(math.abs(l.Z) - s.frameSize.Z * 0.5, 0)
	if dx * dx + dz * dz < EVICT_RADIUS * EVICT_RADIUS then return false end

	if s.completed then return true end

	if s.grid.sealedFrac > 0 then return false end

	if s.grid.stainCount > 0 then return false end

	if s._looseSeen == nil or s.grid:ActiveRegions() > 0 then
		s._looseSeen = s:LooseVolume() > 0.001
	end
	return not s._looseSeen
end

local function evictFar(hrp: BasePart?)
	if not hrp then return end

	for i = #surfaces, 1, -1 do
		local s = surfaces[i]
		if safeToRelease(s, hrp) then releaseSurface(s) end
	end
end

CollectionService:GetInstanceRemovedSignal("SealableDriveway"):Connect(function(slab)
	local s = bySlab[slab]
	if s then releaseSurface(s) end
	queued[slab] = nil
	local i = table.find(pending, slab)
	if i then table.remove(pending, i) end
end)

local function restoreSealed(s)
	if not s or not s.ready or s.completed then return end
	if not Sections.nowSetOf(player)[Sections.keyOf(s.slab)] then return end
	s:FillSealed()
	s.completed = true

	local sc = scores[s]
	if sc then sc:Reset() end
end

player:GetAttributeChangedSignal(Sections.NowAttr):Connect(function()
	for _, s in ipairs(surfaces) do restoreSealed(s) end
end)

SlabTint.bind(player)

local function pumpBuilds(hrp: BasePart?)
	if buildingNow then
		if buildingNow.ready then
			restoreSealed(buildingNow)
			restoreWork(buildingNow)
			buildingNow = nil
		elseif os.clock() >= buildDeadline then

			stalled[#stalled + 1] = buildingNow
			buildingNow = nil
		else
			return
		end
	end

	for i = #stalled, 1, -1 do
		if stalled[i].ready then
			restoreSealed(stalled[i])
			restoreWork(stalled[i])
			table.remove(stalled, i)
		end
	end
	if not hrp or #pending == 0 then return end

	local want = wantSlab
	wantSlab = nil
	if want and not bySlab[want] then
		local wi = table.find(pending, want)
		if wi then
			local slab = table.remove(pending, wi) :: BasePart
			buildingNow = registerSlab(slab)
			if buildingNow then buildDeadline = os.clock() + 20 else retryLater(slab) end
			return
		end
	end

	local bestI, bestSq
	for i, slab in ipairs(pending) do
		local slabCF, frameSize = SurfaceFrame.of(slab)
		local l = slabCF:PointToObjectSpace(hrp.Position)
		local dx = math.max(math.abs(l.X) - frameSize.X * 0.5, 0)
		local dz = math.max(math.abs(l.Z) - frameSize.Z * 0.5, 0)
		local sq = dx * dx + dz * dz
		if sq <= BUILD_RADIUS * BUILD_RADIUS and (not bestSq or sq < bestSq) then
			bestI, bestSq = i, sq
		end
	end
	if not bestI then return end
	local slab = table.remove(pending, bestI) :: BasePart
	buildingNow = registerSlab(slab)
	if buildingNow then buildDeadline = os.clock() + 20 else retryLater(slab) end
end

local MESH_BUDGET = 4
local MESH_KEEP = 5

local BARE_RADIUS = 160

local ranked: { { s: any, d: number } } = {}

local function wantsBare(e): boolean
	return e.d > BARE_RADIUS * BARE_RADIUS
		and e.s.completed
		and SlabTint.isSealed(e.s.slab)
end

local function updateDetail(hrp: BasePart?)
	if not hrp then return end
	table.clear(ranked)
	for _, s in ipairs(surfaces) do
		if s.ready then
			local l = s.topCF:PointToObjectSpace(hrp.Position)
			local dx = math.max(math.abs(l.X) - s.frameSize.X * 0.5, 0)
			local dz = math.max(math.abs(l.Z) - s.frameSize.Z * 0.5, 0)
			table.insert(ranked, { s = s, d = dx * dx + dz * dz })
		end
	end
	table.sort(ranked, function(a, b) return a.d < b.d end)

	local sheets = if player:GetAttribute("Set_Sheet") == true then MESH_BUDGET else 0

	for i = (if sheets > 0 then MESH_KEEP else 0) + 1, #ranked do
		local e = ranked[i]
		e.s:SetDetail(if wantsBare(e) then Detail.Bare else Detail.Flat)
	end

	for i = 1, math.min(sheets, #ranked) do
		local e = ranked[i]
		e.s:SetDetail(if wantsBare(e) then Detail.Bare else Detail.Sheet)
	end
end

task.spawn(function()
	while true do
		task.wait(0.5)
		local ch = player.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?

		evictFar(hrp)
		updateDetail(hrp)
	end
end)

local SEALER_SOLVE_MS = 2.4

local SEALER_PAINT_MS = 2.4
local SEALER_MAX_SKIP = 3
local SEALER_SMOOTH = 0.25

local SEALER_PAINT_MIN = 3000
local SEALER_PAINT_MAX = 18000

local SEALER_WORK_MAX = 16000

local SEALER_WORK_MS = 3.0

local SEALER_PAINT_CAP_MS = SEALER_PAINT_MS * 1.5

local SEALER_FRAME_REF = 1 / 60
local SEALER_FRAME_MAX = 1
local sealerStepMs, sealerPaintMs = 0, 0

local SEALER_PAINT_NS0 = 150
local sealerPaintNs = SEALER_PAINT_NS0
local solveFrame, repaintTurn = 0, 0
local solveCarry = 0

local held: Tool? = nil
local heldKind: string? = nil
local pressing = false
local engage = 0
local bucket = Config.BucketCapacity
local stream = Effects.newStream(fxFolder())

local restGrip: { [Tool]: CFrame } = {}
local function bucketRest(tool: Tool): CFrame
	local g = restGrip[tool]
	if not g then
		g = tool.Grip
		restGrip[tool] = g
	end
	return g
end
local pourTilt = 0
local pourYaw = 0

local pourHold = 0
local pourAim = 0

local PAIL_FULL_X, PAIL_EMPTY_X = 0.80, -0.70
local levelWeld: { [Tool]: Weld } = {}

local function pailLevel(tool: Tool): Weld?
	local existing = levelWeld[tool]
	if existing and existing.Parent then return existing end

	local handle = tool:FindFirstChild("Handle") :: BasePart?
	local disc = tool:FindFirstChild("Level") :: BasePart?
	if not handle or not disc then return nil end

	for _, d in ipairs(disc:GetChildren()) do
		if d:IsA("WeldConstraint") then d:Destroy() end
	end
	local weld = Instance.new("Weld")
	weld.Part0 = handle
	weld.Part1 = disc
	weld.C0 = CFrame.new(PAIL_FULL_X, 0, 0)
	weld.Parent = disc
	levelWeld[tool] = weld
	return weld
end

local function drawPailLevel(tool: Tool, frac: number)
	local weld = pailLevel(tool)
	if not weld then return end
	frac = math.clamp(frac, 0, 1)
	weld.C0 = CFrame.new(PAIL_EMPTY_X + (PAIL_FULL_X - PAIL_EMPTY_X) * frac, 0, 0)

	local disc = weld.Part1 :: BasePart
	disc.Transparency = if frac <= 0.015 then 1 else 0
end

local dumpOwed = 0
local dumpAt: Vector3? = nil
local dumpGap = 0

local dumpQueued = false

local bladeAnchor = Instance.new("Part")
bladeAnchor.Name = "SqueegeeAudio"
bladeAnchor.Anchored = true
bladeAnchor.CanCollide = false
bladeAnchor.CanQuery = false
bladeAnchor.CanTouch = false
bladeAnchor.Transparency = 1
bladeAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
bladeAnchor.Parent = fxFolder()

local scrape = SoundKit.create("ScrapeLoop", bladeAnchor)
local wetLoop = SoundKit.create("WetLoop", bladeAnchor)

local slush = SoundKit.create("SlushLoop", bladeAnchor)

local spread = SoundKit.create("WetSpread", bladeAnchor)
local squelchClock = 0
local wetAmount = 0

local missed = MissedHighlight.new(fxFolder())

local squeegeeRig: Model? = nil
local rigCF: CFrame? = nil

local standOver: number? = nil

local squeegeePose = SqueegeePose.new(player, fxFolder())

local rigCtl = RigController.new(player, fxFolder())
local wandStream = Effects.newWandStream(fxFolder())

local wandPose = WandPose.new(player, fxFolder())
local wandRig: Model? = nil
local wandCF: CFrame? = nil

local wandAim: Vector3? = nil
local wandImpact: Vector3? = nil

local function wandFallbackGrip(hrp: BasePart): Vector3
	return hrp.Position
		+ hrp.CFrame.RightVector * 0.85
		+ hrp.CFrame.LookVector * 0.55
		+ Vector3.new(0, 0.35, 0)
end
local relayDraw = 0

local USE_ACTION = "SealerUse"

local TOUCH_USE = UserInputService.TouchEnabled

local touchFallback = false

type UseMode = { title: string, on: string?, toggle: boolean }
local USE_TOOLS: { [string]: UseMode } = {
	Bucket = { title = "POUR", on = "STOP", toggle = true },
	Squeegee = { title = "SPREAD", on = "STOP", toggle = true },
	Wand = { title = "SPRAY", toggle = false },
}
local useMode: UseMode? = nil

local function refreshUseTitle()
	local m = useMode
	if not m then return end
	ContextActionService:SetTitle(USE_ACTION,
		if m.toggle and pressing and m.on then m.on else m.title)
end

local function dropLatch()
	if not TOUCH_USE or not pressing then return end
	local m = useMode
	if not m or not m.toggle then return end
	pressing = false
	refreshUseTitle()
end

local function applyUse(state: Enum.UserInputState)
    if player:GetAttribute("SkipRoadPicking") == true then
        pressing = false
        dumpQueued = false
        return
    end
	local m = useMode
	if not m then return end
	if m.toggle then

		if state == Enum.UserInputState.Begin then
			pressing = not pressing
			if pressing and heldKind == "Bucket" then dumpQueued = true end
			refreshUseTitle()
		end
	elseif state == Enum.UserInputState.Begin then
		pressing = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then

		pressing = false
	end
end

local function onUseAction(_, state: Enum.UserInputState)
	if not useMode then return Enum.ContextActionResult.Sink end
	applyUse(state)
	return Enum.ContextActionResult.Sink
end

local RAIL_CLEAR = 104 + 16
local POUR_PX = 120
local CTRL_GAP = 18
local CTRL_BOTTOM = 26

local function layoutPourButton()
	local btn = ContextActionService:GetButton(USE_ACTION)
	if not btn then return false end
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Size = UDim2.fromOffset(POUR_PX, POUR_PX)
	btn.Position = UDim2.new(1, -RAIL_CLEAR, 1, -CTRL_BOTTOM)
	return true
end

local function layoutJumpButton()

	local pg = player:FindFirstChildOfClass("PlayerGui")
	local touchGui = pg and pg:FindFirstChild("TouchGui")
	local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local jump = frame and frame:FindFirstChild("JumpButton")
	if not jump or not jump:IsA("GuiObject") then return false end

	local slot = if ContextActionService:GetButton(USE_ACTION)
		then RAIL_CLEAR + POUR_PX + CTRL_GAP else RAIL_CLEAR
	jump.AnchorPoint = Vector2.new(1, 1)
	jump.Position = UDim2.new(1, -slot, 1, -CTRL_BOTTOM)
	return true
end

local function layoutTouchControls()
	if not TOUCH_USE then return end

	task.spawn(function()
		for _ = 1, 30 do

			local want = useMode ~= nil
			local a = if want then layoutPourButton() else true
			local b = layoutJumpButton()

			if want and a then touchFallback = false end
			if a and b then return end
			task.wait(0.1)
		end

		if useMode ~= nil and not ContextActionService:GetButton(USE_ACTION) then
			touchFallback = true
			warn("[Sealer] no touch button for " .. USE_ACTION
				.. "; falling back to raw touch so the tools still work")
		end
	end)
end

local function bindUseButton(kind: string?)
	ContextActionService:UnbindAction(USE_ACTION)
	useMode = if kind then USE_TOOLS[kind] else nil
	if not TOUCH_USE then return end
	if useMode then

		ContextActionService:BindAction(USE_ACTION, onUseAction, true)

		refreshUseTitle()
	end

	layoutTouchControls()
end

if TOUCH_USE then

	camera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutTouchControls)
	player.CharacterAdded:Connect(layoutTouchControls)
	layoutTouchControls()
end

local function setHeld(tool: Tool?)
	held = tool
	heldKind = if tool then tool:GetAttribute("SealerTool") :: string? else nil
	pressing = false
	engage = 0

	dumpOwed, dumpAt, dumpGap, dumpQueued = 0, nil, 0, false
	bindUseButton(heldKind)

	pourTilt, pourYaw = 0, 0

	pourHold, pourAim = 0, 0
	rigCF = nil
	squeegeeRig = nil
	SqueegeePose.Clear(squeegeePose)
	stream:SetActive(false)
	if heldKind == "Bucket" and tool then
		local nozzle = tool:FindFirstChild("Nozzle")
		if nozzle and nozzle:IsA("BasePart") then stream:Attach(nozzle) end

		tool.Grip = bucketRest(tool)
		drawPailLevel(tool, bucket / Config.BucketCapacity)
	elseif heldKind == "Squeegee" and tool then
		squeegeeRig = tool:FindFirstChild("Rig") :: Model?
	elseif heldKind == "Wand" and tool then
		wandRig = tool:FindFirstChild("Rig") :: Model?
		local tip = if wandRig then wandRig:FindFirstChild("Tip") :: BasePart? else nil
		if tip then wandStream:Attach(tip) end

		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if wandRig and hrp then
			local grip = WandPose.Grip(wandPose) or wandFallbackGrip(hrp)

			wandAim = grip + hrp.CFrame.LookVector * 8
			wandCF = CFrame.lookAt(grip, wandAim :: Vector3)
			WandPose.Apply(wandPose, wandRig, wandCF :: CFrame)
		end
	end

	if heldKind ~= "Wand" then
		wandRig = nil
		wandCF = nil
		wandImpact = nil
		wandStream:SetActive(false)
		wandAim = nil
		WandPose.Clear(wandPose)
	end
	rigCtl:SetWand(if heldKind == "Wand" then wandRig else nil)
end

local function watchCharacter(character: Model)
	local function onChild(child: Instance)
		if child:IsA("Tool") and child:GetAttribute("SealerTool") then setHeld(child) end
	end
	character.ChildAdded:Connect(onChild)
	character.ChildRemoved:Connect(function(child)
		if child == held then setHeld(nil) end
	end)
	for _, child in ipairs(character:GetChildren()) do onChild(child) end
end

if player.Character then watchCharacter(player.Character) end
player.CharacterAdded:Connect(function(character)
	bucket = Config.BucketCapacity
	setHeld(nil)
	watchCharacter(character)
end)

Console.Changed:Connect(function()
	pressing = false
	dumpQueued = false
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or Console.blocked() then return end
	if not held then return end

	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.KeyCode == Enum.KeyCode.ButtonR2
		or (input.UserInputType == Enum.UserInputType.Touch and not TOUCH_USE) then
		pressing = true

		if heldKind == "Bucket" then dumpQueued = true end
	elseif input.UserInputType == Enum.UserInputType.Touch and touchFallback then

		applyUse(Enum.UserInputState.Begin)
	end
end)

UserInputService.InputEnded:Connect(function(input)

	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.KeyCode == Enum.KeyCode.ButtonR2
		or (input.UserInputType == Enum.UserInputType.Touch and not TOUCH_USE) then
		pressing = false
	elseif input.UserInputType == Enum.UserInputType.Touch and touchFallback then

		applyUse(Enum.UserInputState.End)
	end
end)

local function approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

local function flatten(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude < 1e-4 then Vector3.new(0, 0, -1) else f.Unit
end

local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude
aimParams.IgnoreWater = true

local mouse = player:GetMouse()

local TOUCH_AIM_AHEAD = 6

local function aimPoint(character: Model, hrp: BasePart): (Vector3?, Instance?)
	aimParams.FilterDescendantsInstances = { character, fxFolder() }
	local origin, direction
	if Console.active() then
		local size = camera.ViewportSize
		local ray = camera:ViewportPointToRay(size.X * 0.5, size.Y * 0.5)
		origin, direction = ray.Origin, ray.Direction * 250
	elseif TOUCH_USE then

		local ahead = hrp.Position + flatten(hrp.CFrame.LookVector) * TOUCH_AIM_AHEAD
		origin, direction = ahead + Vector3.new(0, 10, 0), Vector3.new(0, -250, 0)
	else
		local ray = mouse.UnitRay
		origin, direction = ray.Origin, ray.Direction * 250
	end
	local hit = workspace:Raycast(origin, direction, aimParams)
	local fallback = if TOUCH_USE then TOUCH_AIM_AHEAD else 8
	local target = if hit then hit.Position else hrp.Position + flatten(hrp.CFrame.LookVector) * fallback

	local delta = target - hrp.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local clamped = false
	if flat.Magnitude > AIM_RANGE then
		target = hrp.Position + flat.Unit * AIM_RANGE + Vector3.new(0, delta.Y, 0)
		clamped = true
	end

	return target, if clamped then nil else (hit and hit.Instance or nil)
end

local PLANE_ABOVE = 18.0
local PLANE_BELOW = 2.5

local function surfaceAt(pos: Vector3, reach: number?)
	local limit = (reach or 90) ^ 2
	local best, bestKey = nil, math.huge
	for _, s in ipairs(surfaces) do
		if s.ready then
			local l = s.topCF:PointToObjectSpace(pos)
			local dx = math.max(math.abs(l.X) - s.frameSize.X * 0.5, 0)
			local dz = math.max(math.abs(l.Z) - s.frameSize.Z * 0.5, 0)
			local flat = dx * dx + dz * dz
			local vert = math.abs(l.Y)
			if flat <= limit and l.Y <= PLANE_ABOVE and l.Y >= -PLANE_BELOW then

				local on = flat <= 1e-6 and s:Contains(pos)

				local area = s.frameSize.X * s.frameSize.Z
				local key = (if on then 0 else 1e6) + flat + vert * 4 + area * 1e-6
				if key < bestKey then best, bestKey = s, key end
			end
		end
	end
	return best
end

local function nearestSurface(pos: Vector3)
	return surfaceAt(pos)
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true

local function usable(s): boolean
	return s ~= nil and s.ready == true
end

local function notReadySlab(inst: Instance?): BasePart?
	if inst and inst:IsA("BasePart") and not usable(bySlab[inst])
		and CollectionService:HasTag(inst, Sections.Tag) then
		return inst
	end
	return nil
end

local function slabName(slab: BasePart): string
	return slab:GetAttribute("DrivewayName") or slab.Name
end

local function slabUnder(pos: Vector3, character: Model?)
	groundParams.FilterDescendantsInstances = { fxFolder(), character :: Instance }

	local hit = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -26, 0), groundParams)
	if not hit then return nil, nil end
	local s = bySlab[hit.Instance]

	return (if usable(s) then s else nil), hit.Instance
end

local fillHeld = false

local cachedNozzle: BasePart? = nil
local function fillPoint(): BasePart?
	if cachedNozzle and cachedNozzle.Parent then return cachedNozzle end
	local points = Depot.refuelPoints()
	local pick = points[1]
	for _, p in ipairs(points) do
		if p.Name == "ArmNozzle" then pick = p break end
	end
	cachedNozzle = pick
	return pick
end

local function isFillPrompt(p: ProximityPrompt): boolean
	return p:GetAttribute("DepotFill") == true
end

local function stopFill()
	if not fillHeld then return end
	fillHeld = false
	local at = fillPoint()
	if at then SoundKit.play("ValveThunk", at, 0.08, 0.45) end
end

local function startFill()
	if fillHeld then return end
	fillHeld = true
	local at = fillPoint()
	if at then SoundKit.play("ValveThunk", at, 0.08, 0.7) end
end

ProximityPromptService.PromptTriggered:Connect(function(p, plr)
	if plr ~= player or not isFillPrompt(p) then return end

	if Passes.owns(player, "InstantFill") then
		bucket = Config.BucketCapacity
		local at = fillPoint()
		if at then SoundKit.play("ValveThunk", at, 0.08, 0.7) end
		return
	end
	startFill()
end)

ProximityPromptService.PromptTriggerEnded:Connect(function(p, plr)
	if plr ~= player or not isFillPrompt(p) then return end
	stopFill()
end)

HudActions.register("RefillPail", function()
	bucket = Config.BucketCapacity

	local ch = player.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then SoundKit.play("ValveThunk", hrp, 0.08, 0.7) end
end)

local impactPos: Vector3? = nil
local lastBlade: Vector3? = nil

local pushSign = 1
local facingLocked = false
local strokeOpen = false

local strokeScore: any = nil
local popCounter = 0
local reportClock, relayClock = 0, 0

local lastBar = {
	blade = nil :: Vector3?,
	pour = nil :: Vector3?,

	pending = 0,
	sinceDrop = 0,
	dropClock = 0,

	load = 0,
}
local walkBase = 16
local resistance = 0

local bladeLoad = 0

local looseInfo: { every: number, floor: number, clock: number, now: number, at: Vector3?, on: any, solveAt: number, solveCarryBySurface: { [any]: number } } = {
	every = 0.25,

	floor = 0.12,
	clock = 0,
	now = 0,
	at = nil,
	on = nil,
	solveAt = 1,
	solveCarryBySurface = setmetatable({}, { __mode = "k" }) :: any,
}

RunService.Heartbeat:Connect(function(dt)
    if player:GetAttribute("SkipRoadPicking") == true then
        pressing = false
        dumpQueued = false
    end
	dt = math.min(dt, 0.1)

	if player:GetAttribute("DuelEndlessPail") == true then
		bucket = Config.BucketCapacity
	elseif bucket > Config.BucketCapacity then
		bucket = Config.BucketCapacity
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	local seated = humanoid ~= nil and (humanoid.SeatPart ~= nil or humanoid.Sit)
	pumpBuilds(hrp)

	local aimAt, aimHit = nil, nil
	if hrp and character then aimAt, aimHit = aimPoint(character, hrp) end

	local surface = nil

	local waitingOn: BasePart? = nil
	if hrp then
		if heldKind == "Squeegee" then
			local at = hrp.Position + flatten(hrp.CFrame.LookVector) * BLADE_FORWARD

			local under, hitPart = slabUnder(at, character)

			wantBuild(hitPart)
			waitingOn = notReadySlab(hitPart)
			surface = under or surfaceAt(at, 26)
		elseif aimAt and (heldKind == "Bucket" or heldKind == "Wand") then

			local aimed = if aimHit then bySlab[aimHit] else nil
			wantBuild(aimHit)
			waitingOn = notReadySlab(aimHit)

			if not waitingOn and not usable(aimed) then
				local underAim, aimPart = slabUnder(aimAt, character)
				if not underAim then
					wantBuild(aimPart)
					waitingOn = notReadySlab(aimPart)
				end
			end
			surface = (if usable(aimed) then aimed else nil) or surfaceAt(aimAt, 26)
		end
		if not surface then surface = nearestSurface(hrp.Position) end
	end
	local score = if surface then scores[surface] else nil

	if heldKind == "Squeegee" and squeegeeRig and hrp and character
		and not seated and not surface then
		local look = flatten(hrp.CFrame.LookVector)
		local at = hrp.Position + look * BLADE_FORWARD

		groundParams.FilterDescendantsInstances = { character :: Instance, fxFolder() }
		local hit = workspace:Raycast(at + Vector3.new(0, 5, 0), Vector3.new(0, -12, 0), groundParams)
		local y = if hit then hit.Position.Y else hrp.Position.Y - 2.6

		local origin = Vector3.new(at.X, y + 0.62, at.Z)
		local target = CFrame.lookAt(origin, origin + look) * CFrame.Angles(math.rad(3), 0, 0)
		rigCF = if rigCF then rigCF:Lerp(target, 1 - math.exp(-Config.RigEase * dt)) else target
		squeegeeRig:PivotTo((rigCF :: CFrame) * CFrame.new(0, 0.17, 0))

		SqueegeePose.Update(squeegeePose, squeegeeRig, 0)
	end

	if heldKind == "Squeegee" and squeegeeRig and hrp and seated and not surface then
		rigCF = hrp.CFrame * CFrame.new(0.95, -0.35, -0.55)
		squeegeeRig:PivotTo(rigCF :: CFrame)
	end

	if strokeOpen and strokeScore and strokeScore ~= score then
		strokeOpen = false
		strokeScore:EndStroke()
		strokeScore = nil
	end

	local highlighting = missed:Update(dt, surface,
		if surface and surface.ready then surface:Coverage() else 0,
		if hrp then hrp.Position else nil)

	if not (heldKind == "Bucket" and pressing) then impactPos = nil end

	local hint = ""
	local targetResistance = 0
	local targetTouched = 0
	local bucketPouring = false

	rigCtl:Update(dt)
	local rigState = rigCtl:State()

	if rigState.pouring and rigState.pourCF and rigState.tank > 0
        and player:GetAttribute("SkipRoadPicking") ~= true then
		local pcf = rigState.pourCF :: CFrame
		local slab = slabUnder(pcf.Position, character) or surfaceAt(pcf.Position, 30)

		if slab and slab.ready and not slab.completed then
			local center = slab:SurfacePoint(pcf.Position)
			local travel = 0
			if lastBar.pour then
				local moved = center - (lastBar.pour :: Vector3)
				travel = Vector3.new(moved.X, 0, moved.Z).Magnitude
			end
			lastBar.pour = center

			local width = Config.TruckPourWidth
			local pumpMul = 1 + ((rigState.pump or 1) - 1) * Config.TruckPourPumpShare
			local perStud = if rigState.bladeDown
				then Config.TruckPourPerStud else Config.TruckDropPerStud
			local amount = (perStud * travel + Config.TruckPourIdle * dt) * width * pumpMul
			amount = math.min(amount, Config.TruckPourMaxRate * pumpMul * dt, rigState.tank)

			local lay, pts, radius = 0, 0, 0
			if rigState.bladeDown then

				local feed = (1 - lastBar.load / Config.TruckBladeCapacity)
					* Config.TruckPourFeedGain
				if feed < 0 then feed = 0 elseif feed > 1 then feed = 1 end
				lay = (amount + lastBar.pending) * feed
				lastBar.pending, lastBar.sinceDrop, lastBar.dropClock = 0, 0, 0
				pts = math.clamp(math.floor(width * 0.5 / Config.TruckPourSpacing + 0.5),
					5, Config.TruckPourMaxPts)

				radius = math.max(Config.CellSize * 2, width * 0.5 / pts * 1.6)
			else

				lastBar.pending += amount
				lastBar.sinceDrop += travel
				lastBar.dropClock += dt
				if lastBar.pending > 0
					and (lastBar.sinceDrop >= Config.TruckDropEvery
						or lastBar.dropClock >= Config.TruckDropInterval) then
					lay = math.min(lastBar.pending, rigState.tank)
					lastBar.pending, lastBar.sinceDrop, lastBar.dropClock = 0, 0, 0
					pts = Config.TruckDropPoints
					radius = Config.TruckDropRadius
				end
			end

			if lay > 0 and pts > 0 then
				local half = width * 0.5
				local axis = pcf.RightVector
				local per = lay / pts
				local placed = 0
				for k = 1, pts do
					local t = if pts > 1 then (k - 1) / (pts - 1) * 2 - 1 else 0
					placed += slab:Pour(center + axis * (half * t), per, radius)
				end

				relayDraw += placed
			end
		else

			lastBar.pour = nil
			lastBar.pending, lastBar.sinceDrop, lastBar.dropClock = 0, 0, 0
		end
	else
		lastBar.pour = nil
		lastBar.pending, lastBar.sinceDrop, lastBar.dropClock = 0, 0, 0
	end

	if rigState.bladeDown and rigState.bladeCF then
		local cf = rigState.bladeCF :: CFrame
		local slab = slabUnder(cf.Position, character) or surfaceAt(cf.Position, 30)
		if slab and slab.ready then
			if rigState.driving then
				surface = slab
				score = scores[slab]
			end
			local center = slab:SurfacePoint(cf.Position)
			if lastBar.blade then
				local moved = center - (lastBar.blade :: Vector3)
				local flat = Vector3.new(moved.X, 0, moved.Z)
				local travel = flat.Magnitude
				local speed = travel / math.max(dt, 1e-3)

				if travel > 1e-3 and speed >= Config.TruckBladeMinSpeed then
					local fwd = flatten(cf.LookVector)

					local dir = if flat.Unit:Dot(fwd) >= 0 then fwd else -fwd
					local half = Config.TruckBladeWidth * 0.5

					local res = slab:Squeegee(center, cf.RightVector, dir,
						travel, speed, dt, 1, half, Config.TruckBladeCapacity)
					lastBar.load = if res then (res.pile or 0) else 0
				end
			end
			lastBar.blade = center
		else
			lastBar.blade = nil
		end
	else
		lastBar.blade = nil

		lastBar.load = 0
	end

	if heldKind ~= "Squeegee" then SqueegeePose.Clear(squeegeePose) end
	if heldKind ~= "Wand" then WandPose.Clear(wandPose) end

	local fillState = nil :: { caption: string, pail: number, drum: number? }?
	if fillHeld then
		local toPump = if hrp then Depot.distanceToRefuel(hrp.Position) else nil

		if not hrp or (toPump and toPump > Config.FillReach + Config.FillLeash) then
			stopFill()
		else
			bucket = math.min(Config.BucketCapacity, bucket + Config.BucketRefill * dt)

			local drum = if rigState.present and rigState.refilling
				then math.clamp(rigState.tankFrac, 0, 1) else nil
			fillState = {
				caption = if drum then "FILLING PAIL + DRUM" else "FILLING PAIL",
				pail = bucket / Config.BucketCapacity,
				drum = drum,
			}

			hint = if rigState.present and not drum
				then "Keep holding to fill -- back the rig up to the pump to fill its drum too"
				else "Keep holding to fill"
		end
	end
	if not fillHeld and bucket <= 0 and heldKind == "Bucket" then
		hint = "Pail empty -- hold E at the pump in the depot garage to fill it"
	end

	if not fillHeld and hint == "" and rigState.present and hrp then
		local toPump = Depot.distanceToRefuel(hrp.Position)
		if toPump and toPump <= Config.FillReach then
			hint = if rigState.atPump
				then "Hold E -- fills your pail and the rig's drum together"
				else "Hold E to fill your pail -- back the rig up to the pump for its drum too"
		end
	end

	if heldKind == "Wand" and wandRig and hrp and character then

		local aim = aimAt or (hrp.Position + flatten(hrp.CFrame.LookVector) * 10)

		local toAim = aim - hrp.Position
		local flatAim = Vector3.new(toAim.X, 0, toAim.Z)

		if humanoid and not seated and flatAim.Magnitude > 0.5 then
			humanoid.AutoRotate = false
			facingLocked = true
			local want = CFrame.lookAt(Vector3.zero, flatAim.Unit)
			local cur = hrp.CFrame - hrp.CFrame.Position
			hrp.CFrame = CFrame.new(hrp.Position) * cur:Lerp(want, 1 - math.exp(-16 * dt))
		end

		local grip = WandPose.Grip(wandPose) or wandFallbackGrip(hrp)
		local delta = aim - grip
		if delta.Magnitude > Config.WandReach then
			aim = grip + delta.Unit * Config.WandReach
		end

		wandAim = if wandAim then (wandAim :: Vector3):Lerp(aim, 1 - math.exp(-24 * dt)) else aim

		if ((wandAim :: Vector3) - grip).Magnitude < 0.05 then
			wandAim = grip + flatten(hrp.CFrame.LookVector)
		end
		wandCF = CFrame.lookAt(grip, wandAim :: Vector3)
		WandPose.Apply(wandPose, wandRig, wandCF :: CFrame)

		if rigState.wandFar then
			hint = "Too far from the rig -- the hose will not reach."
				.. " Walk back toward the truck"
		end

		local pouring = pressing and rigState.tank > 1
			and rigState.deployed
			and not (surface and surface.completed)

		if pouring then
			wandImpact = if wandImpact
				then wandImpact:Lerp(aim, 1 - math.exp(-dt / Config.WandLag))
				else aim
			local impact = wandImpact :: Vector3

			local rate = Config.WandRate * (rigState.pump or 1)
			local amount = math.min(rate * dt, rigState.tank)

			local placed = if surface and not waitingOn
				then surface:Pour(impact, amount, Config.WandRadius)
				else 0

			if placed > 0 then relayDraw += amount end

			local flow = math.clamp(rigState.tank / (rigState.tankMax * 0.12), 0.45, 1)
			wandStream:SetActive(true)
			wandStream:Update(impact, flow)
		else
			wandStream:SetActive(false)
			wandImpact = nil
		end
	else
		wandStream:SetActive(false)
		wandImpact = nil
	end

	if heldKind == "Bucket" and (bucket <= 0 or seated) then dropLatch() end

	if surface and hrp and character then

		local canPour = heldKind == "Bucket" and bucket > 0
			and not seated and not waitingOn and not surface.completed

		dumpGap = math.max(0, dumpGap - dt)

		if canPour and dumpQueued
			and dumpOwed <= 0 and dumpGap <= 0 and aimAt then
			dumpOwed = Config.PourDump
			dumpAt = aimAt
			dumpQueued = false
		end

		if dumpAt then
			local away = (dumpAt :: Vector3) - hrp.Position
			if Vector3.new(away.X, 0, away.Z).Magnitude > AIM_RANGE * 1.5 then
				dumpOwed, dumpAt = 0, nil
			end
		end

		local glug = canPour and dumpOwed > 0 and dumpAt ~= nil

		local streaming = canPour and pressing and not glug and aimAt ~= nil
		local pouring = glug or streaming
		bucketPouring = pouring
		if pouring then

			impactPos = if glug then dumpAt :: Vector3 else aimAt :: Vector3

			local amount = if glug then math.min(dumpOwed, bucket)
				else math.min(Config.PourHold * dt, bucket)
			local placed = surface:Pour(impactPos :: Vector3, amount)
			if placed > 0 then
				bucket -= amount
				if glug then
					dumpOwed -= amount

					if dumpOwed <= 1e-4 then
						dumpOwed = 0

						dumpGap = Config.PourDumpGap
					end
				end
			end

			local flow = math.clamp(bucket / (Config.BucketCapacity * 0.25), 0.4, 1)
			stream:SetActive(true)
			stream:Update(impactPos :: Vector3, flow)
		else
			stream:SetActive(false)
			impactPos = nil

			if not canPour then dumpOwed, dumpAt, dumpQueued = 0, nil, false end
		end

		if heldKind == "Squeegee" and not seated then

			local state = if humanoid then humanoid:GetState() else nil
			local airborne = state == Enum.HumanoidStateType.Freefall
				or state == Enum.HumanoidStateType.Jumping
				or state == Enum.HumanoidStateType.FallingDown

			if airborne or waitingOn then
				engage = 0
			else
				engage = approach(engage, if pressing then 1 else 0, 1 / Config.BladeDrop, dt)
			end

			if pressing and humanoid and not seated then
				humanoid.AutoRotate = false
				facingLocked = true
				local camLook = flatten(camera.CFrame.LookVector)
				if camLook.Magnitude > 0.01 then
					local want = CFrame.lookAt(Vector3.zero, camLook)
					local cur = hrp.CFrame - hrp.CFrame.Position
					hrp.CFrame = CFrame.new(hrp.Position)
						* cur:Lerp(want, 1 - math.exp(-16 * dt))
				end
			end

			local look = flatten(hrp.CFrame.LookVector)
			local center = surface:SurfacePoint(hrp.Position + look * BLADE_FORWARD)
			local axis = Vector3.new(-look.Z, 0, look.X)
			bladeAnchor.CFrame = CFrame.new(center)

			local overSlab = hrp.Position.Y - surface.topY
			if not airborne then standOver = overSlab end
			local rise = if standOver then math.max(0, overSlab - standOver) else 0

			if squeegeeRig then
				local lift = (1 - engage) * 0.62
				local origin = center + Vector3.new(0, lift + rise, 0)
				local tilt = math.rad(3 + 11 * resistance)
				local target = CFrame.lookAt(origin, origin + look) * CFrame.Angles(tilt, 0, 0)
				rigCF = if rigCF then rigCF:Lerp(target, 1 - math.exp(-Config.RigEase * dt)) else target
				squeegeeRig:PivotTo((rigCF :: CFrame) * CFrame.new(0, 0.17, 0))

				SqueegeePose.Update(squeegeePose, squeegeeRig, engage)
			end

			if engage > 0.03 then
				if pressing and not strokeOpen then
					strokeOpen = true
					strokeScore = score
					score:BeginStroke(center)
				end

				local along = if lastBlade then (center - lastBlade):Dot(look) else 0
				if along > 1e-3 then pushSign = 1
				elseif along < -1e-3 then pushSign = -1 end
				local pushDir = look * pushSign
				local travel = math.abs(along)

				local contact = math.min(1, engage * 2.5)

				if Boosts.active(player, ENDLESS_ID) then
					local halfLen = Config.BladeHalfLen
					local feed = 1 - bladeLoad / Config.BladeCapacity
					if feed < 0 then feed = 0 elseif feed > 1 then feed = 1 end
					local amount = (ENDLESS_PER_STUD * travel + ENDLESS_IDLE * dt)
						* (halfLen * 2) * feed * contact
					if amount > 0 then
						local n = math.clamp(
							math.floor(halfLen / ENDLESS_SPACING + 0.5), 5, ENDLESS_MAX_PTS)
						local per = amount / n

						local radius = math.max(Config.CellSize * 2, halfLen / n * 1.6)
						local lead = pushDir * ENDLESS_LEAD
						for k = 1, n do
							local t = (k - 1) / (n - 1) * 2 - 1
							surface:Pour(center + axis * (halfLen * t) + lead, per, radius)
						end
					end
				end

				local result = surface:Squeegee(center, axis, pushDir, travel, travel / dt, dt, contact)
				if result then
					targetResistance = result.resistance
					targetTouched = result.touched

					bladeLoad = result.pile or 0
					if strokeOpen then
						score:Accumulate(result, travel,
							{ result.x0, result.y0, result.x1, result.y1 })
					end
				end
			end

			if strokeOpen and not pressing then
				strokeOpen = false
				strokeScore = nil
				score:EndStroke()
			end
			lastBlade = center

			wetAmount = approach(wetAmount,
				math.clamp(targetTouched / WET_TOUCH_REF, 0, 1), 7, dt)

			local sp = math.clamp(targetResistance * 0.4
				+ math.clamp(hrp.AssemblyLinearVelocity.Magnitude / 14, 0, 1) * 0.6, 0, 1)

			scrape.Volume = 0.30 * sp * engage * (1 - 0.55 * wetAmount)
			scrape.PlaybackSpeed = 0.82 + 0.55 * sp

			spread.Volume = (0.46 + 0.24 * sp) * wetAmount * engage
			spread.PlaybackSpeed = 0.46 + 0.26 * sp
			wetLoop.Volume = (0.34 + 0.32 * targetResistance) * wetAmount * engage
			slush.Volume = (0.30 + 0.44 * targetResistance) * wetAmount * engage
			slush.PlaybackSpeed = 0.62 + 0.30 * targetResistance

			if engage > 0.03 then
				if not scrape.IsPlaying then scrape:Play() end
				if not wetLoop.IsPlaying then wetLoop:Play() end
				if not slush.IsPlaying then slush:Play() end
				if not spread.IsPlaying then spread:Play() end
			else
				scrape:Stop(); wetLoop:Stop(); slush:Stop(); spread:Stop()
			end

			squelchClock -= dt
			if engage > 0.3 and wetAmount > 0.22 and squelchClock <= 0 then
				squelchClock = 0.5 + math.random() * 0.45
				local pick = if targetResistance > 0.6 then "Goop"
					elseif math.random() < 0.5 then "Splat"
					else "Squelch"
				SoundKit.play(pick, bladeAnchor, 0.22, 0.4 + 0.5 * wetAmount)
			end
		else

			if seated and squeegeeRig and hrp and heldKind == "Squeegee" then
				local at = hrp.CFrame * CFrame.new(0.95, -0.35, -0.55)
				rigCF = at
				squeegeeRig:PivotTo(at)
			end
			if strokeOpen then
				strokeOpen = false
				strokeScore = nil
				if score then score:EndStroke() end
			end

			engage = 0
			lastBlade = nil
			wetAmount = 0
			scrape:Stop(); wetLoop:Stop(); slush:Stop(); spread:Stop()
		end

		if hint == "" then

			if surface.completed and (heldKind == "Bucket" or heldKind == "Wand") then
				hint = "This one is sealed -- there is nothing left to pour on"
			elseif heldKind == "Bucket" then

				hint = if TOUCH_USE
					then "Tap POUR to tip the pail -- then spread the puddle with the squeegee"
					else "Click to tip a puddle or hold to pour -- then spread it with the squeegee"
			elseif heldKind == "Squeegee" then
				hint = if TOUCH_USE
					then "Tap SPREAD to drop the blade -- walk forward to push, back to pull"
					else "Hold to spread -- walk forward to push, back up to pull"
			elseif heldKind == "Wand" then

				if rigState.tank <= 1 then
					hint = "Tank dry -- back the rig onto the depot's fill pad,"
						.. " then hold E at the pump"
				elseif rigState.tension > 0.6 then
					hint = "Hose is coming tight -- work back toward the rig"
				else
					hint = "Hold to pour -- then spread it with the squeegee"
				end
			else

				hint = if rigState.present
					then "Take the wand off the rig's reel, or equip the bucket"
					else "Equip the Sealer Bucket to start pouring"
			end

			if highlighting then
				hint = "Nearly there -- the marked patches are all that is left"
			end

		end
	end

	local wantsFacing = not seated
		and ((heldKind == "Squeegee" and pressing) or heldKind == "Wand")
	if facingLocked and not wantsFacing then
		facingLocked = false
		if humanoid then humanoid.AutoRotate = true end
	end

	if held and heldKind == "Bucket" and not Afk.plotOf(player) then

		if bucketPouring then
			pourHold = Config.PourPoseHold
		else
			pourHold = math.max(0, pourHold - dt)
		end
		local tipping = bucketPouring or pourHold > 0

		if bucketPouring and impactPos and hrp then
			local to = (impactPos :: Vector3) - hrp.Position
			local flat = Vector3.new(to.X, 0, to.Z)
			if flat.Magnitude > 1 then
				local fwd = flatten(hrp.CFrame.LookVector)
				local dir = flat.Unit
				local cap = math.rad(Config.PourTiltYawMax)
				pourAim = math.clamp(math.atan2(fwd:Cross(dir).Y, fwd:Dot(dir)), -cap, cap)
			end
		elseif not tipping then
			pourAim = 0
		end
		local wantYaw = if tipping then pourAim else 0

		pourTilt = approach(pourTilt, if tipping then 1 else 0, Config.PourTiltEase, dt)
		pourYaw = approach(pourYaw, wantYaw, Config.PourTiltEase, dt)

		drawPailLevel(held, bucket / Config.BucketCapacity)

		local tip = math.rad(Config.PourTilt) * pourTilt
		local swing = pourYaw * pourTilt
		held.Grip = bucketRest(held)
			* CFrame.Angles(tip, 0, 0)
			* CFrame.Angles(0, -swing, 0)
	end

	solveCarry += dt
	solveFrame += 1
	local solveEvery = math.clamp(math.ceil(sealerStepMs / SEALER_SOLVE_MS), 1, SEALER_MAX_SKIP)
	if solveFrame >= solveEvery then
		solveFrame = 0
		local stepT0 = os.clock()

		local cap = if solveEvery > 1 then solveEvery else nil
		local popAt: Vector3? = nil
		local stepped = 0
		local surfaceCount = #surfaces
		if surfaceCount > 0 then
			for _, s in ipairs(surfaces) do
				looseInfo.solveCarryBySurface[s] = (looseInfo.solveCarryBySurface[s] or 0) + solveCarry
			end

			for i = 1, surfaceCount do
				local s = surfaces[((looseInfo.solveAt + i - 2) % surfaceCount) + 1]
				local working = s == surface
				if working or stepped < 2 then
					if not working then
						stepped += 1
					end
					local sealedNew = s:Step(looseInfo.solveCarryBySurface[s] or solveCarry, cap, solveEvery > 1)
					looseInfo.solveCarryBySurface[s] = nil
					if working and sealedNew > 0 then
						popCounter += sealedNew
						if popCounter >= POP_EVERY then
							popCounter %= POP_EVERY
							popAt = lastBlade or s.slab.Position
						end
					end
				end
			end
			looseInfo.solveAt = (looseInfo.solveAt % surfaceCount) + 1
		end
		solveCarry = 0
		sealerStepMs += ((os.clock() - stepT0) * 1000 - sealerStepMs) * SEALER_SMOOTH

		if popAt and POP_ENABLED then Effects.sealPop(popAt, fxFolder()) end
	end

	local paintT0 = os.clock()

	local frameScale = math.clamp(dt / SEALER_FRAME_REF, 1, SEALER_FRAME_MAX)
	local paintCells = SEALER_PAINT_MS * frameScale * 1e6 / sealerPaintNs
	if paintCells < SEALER_PAINT_MIN then paintCells = SEALER_PAINT_MIN
	elseif paintCells > SEALER_PAINT_MAX * frameScale then
		paintCells = SEALER_PAINT_MAX * frameScale
	end
	local paintCapMs = SEALER_PAINT_CAP_MS * frameScale

	local painted = 0

	local laying = bucketPouring
		or (heldKind == "Squeegee" and engage > 0.03)
		or wandImpact ~= nil
		or (rigState.bladeDown == true and rigState.driving == true)
	local workCells = paintCells
	if surface and laying then
		local owed = surface:DirtyCells()
		if owed > workCells then

			local ceiling = math.min(SEALER_WORK_MAX, SEALER_WORK_MS * 1e6 / sealerPaintNs)

			workCells = math.max(paintCells, math.min(owed, ceiling))
		end
	end
	if surface then painted += surface:Render(workCells) end

	if painted > 2000 then
		local ns = (os.clock() - paintT0) * 1e9 / painted
		if ns > sealerPaintNs then
			sealerPaintNs += (ns - sealerPaintNs) * 0.6

			paintCells = SEALER_PAINT_MS * frameScale * 1e6 / sealerPaintNs
			if paintCells < SEALER_PAINT_MIN then paintCells = SEALER_PAINT_MIN end

		end
	end

	local count = #surfaces
	if count > 0 then
		repaintTurn = (repaintTurn % count) + 1
		for k = 0, count - 1 do
			local left = paintCells - painted
			if left <= 0 or (os.clock() - paintT0) * 1000 >= paintCapMs then break end
			local s = surfaces[(repaintTurn + k - 1) % count + 1]
			if s ~= surface then painted += s:Render(left) end
		end

		if surface and painted < paintCells
			and (os.clock() - paintT0) * 1000 < paintCapMs then
			painted += surface:Render(paintCells - painted)
		end
	end

	local paintMs = (os.clock() - paintT0) * 1000
	sealerPaintMs += (paintMs - sealerPaintMs) * SEALER_SMOOTH

	if painted > 2000 then
		local ns = paintMs * 1e6 / painted
		sealerPaintNs += (ns - sealerPaintNs) * (if ns > sealerPaintNs then 0.6 else 0.05)
	elseif sealerPaintNs > SEALER_PAINT_NS0 then

		sealerPaintNs += (SEALER_PAINT_NS0 - sealerPaintNs) * 0.05
		if sealerPaintNs < SEALER_PAINT_NS0 then sealerPaintNs = SEALER_PAINT_NS0 end
	end

	resistance = approach(resistance, targetResistance, Config.ResistanceEase, dt)

	if humanoid and not Afk.plotOf(player)
		and player:GetAttribute("BattleArena") == nil then
		if humanoid.WalkSpeed > walkBase then walkBase = humanoid.WalkSpeed end

		humanoid.WalkSpeed = walkBase
			* (1 - Config.MaxSlowdown * resistance * engage)
			* (1 - Config.HoseDragMax * rigState.tension)
	end

	if surface and score and not surface.completed and surface:Coverage() >= Config.CompleteAt then
		surface.completed = true

		score:AwardCompletion()

		surface:Settle()
		Effects.completionBurst(surface.topCF, surface.spanX, surface.spanZ, fxFolder())

		local screenPos, onScreen = camera:WorldToViewportPoint(surface.topCF.Position)
		if onScreen then
			local inset = game:GetService("GuiService"):GetGuiInset()
			CashFx.hintFrom(Vector2.new(screenPos.X - inset.X, screenPos.Y - inset.Y))
		end

		ReportCoverage:FireServer(surface.slab, surface:Coverage())
		DrivewayComplete:FireServer(surface.slab, score:Value())

	end

	relayClock += dt
	if relayClock >= 0.08 then
		relayClock = 0

		if relayDraw > 0 then
			TruckControl:FireServer("draw", relayDraw)
			relayDraw = 0
		end
	end

	reportClock += dt
	if reportClock >= 0.25 and surface then
		reportClock = 0
		ReportCoverage:FireServer(surface.slab, surface:Coverage())
	end

	looseInfo.clock += dt
	if looseInfo.clock >= looseInfo.every
		or (looseInfo.on ~= surface and (surface == nil or looseInfo.clock >= looseInfo.floor))
	then
		looseInfo.clock = 0
		looseInfo.on = surface
		if surface then
			looseInfo.now, looseInfo.at = surface:LooseVolume()
		else
			looseInfo.now, looseInfo.at = 0, nil
		end
	end

	if waitingOn then
		hint = "Getting this one ready -- one moment"
	end

	if score then score:Update(dt) end

	comboLive = strokeOpen or ((score and score.combo or 1) > 1)
	local hudState = {

		coverage = if waitingOn then 0
			elseif surface then (if surface.completed then 1 else surface:Coverage())
			else 0,
		value = if score then score:Value() else 0,
		combo = if score then score.combo else 1,

		stroking = strokeOpen,

		laying = laying,
		name = if waitingOn then slabName(waitingOn)
			elseif surface then surface.name
			else nil,

		bucket = bucket / Config.BucketCapacity,

		rig = if rigState.present then {
			tankFrac = rigState.tankFrac,
			refilling = rigState.refilling,
			deployed = rigState.deployed,

			distance = rigState.distance,
			hoseOut = rigState.hoseOut,

			hoseMax = rigState.hoseMax,
			rigName = rigState.rigName,
			tension = rigState.tension,

			wandFar = rigState.wandFar,
		} else nil,

		fill = fillState,
		hint = hint,

		loose = looseInfo.now,

		looseAt = looseInfo.at,
	}
	hud:Update(dt, hudState)
	HudBus.push(hudState, heldKind)
end)

player:GetAttributeChangedSignal("Rebirths"):Connect(function()

	if not player:GetAttribute("ProfileLoaded") then return end
	if player:GetAttribute("RebirthSkipping") == true then return end
	missed:Clear()
	bucket = Config.BucketCapacity
	popCounter = 0

	forgetAllKept()
	for _, s in ipairs(surfaces) do
		s:Reset()
		s.completed = false
		local sc = scores[s]
		if sc then sc:Reset() end
	end
end)
