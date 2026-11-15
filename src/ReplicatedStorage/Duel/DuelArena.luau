--!strict
--[[
	DuelArena -- the ground the two sealing modes are fought on.

	Builds one arena per running duel, a long way from the map, and destroys it at
	the flag. Squeegee Battle is not here: that mode borrows the arena the
	scheduled event already built, through ServerScriptService.DuelBus.

	WHY THIS BUILDS AND DESTROYS, WHERE THE OTHER THREE YARDS ARE BUILT ONCE

	The AFK yard, the battle arena and the race yard are put up at server start and
	stand for the life of the server, because exactly one of each can ever be in
	use. Duels are player-started and concurrent -- there is no "the" duel arena --
	so the choice is between parking Duel.MaxConcurrent of every mode permanently,
	or building the one that is needed when it is needed. The second is cheaper on
	a server where nobody duels, which is most servers most of the time.

	THE SLABS ARE REAL DRIVEWAYS, AND THAT IS THE WHOLE TRICK

	Every slab here is tagged Sections.Tag, which is the only thing DrivewayClient
	looks for. So it builds a surface over them, and the pour, the spread, the
	squeegee, the cure, the coverage readout and the finished-job flourish all
	arrive with no duel-specific client code whatsoever. The mode is a place to
	stand and a reason to hurry; the sealing is the game's own.

	What stops them paying out like a real driveway is Duel.SlabAttr -- see the long
	note on it in DuelConfig, which is the load-bearing paragraph of this feature.

	PERSISTENT, DELIBERATELY, AND IT IS THE EXPENSIVE CHOICE

	StreamingEnabled is on in this place. A duellist is teleported six thousand
	studs in one frame, and if the ground has not replicated when they land they
	fall through it -- which is the bug the AFK yard shipped (1,171 parts that did
	not make the frame) and the reason every teleport in this game is preceded by
	RequestStreamAroundAsync. That call is still made, but Persistent is what makes
	it a formality rather than a race.

	The cost is honest: a persistent model is sent to EVERY client, including the
	twenty-eight people not duelling. It is bounded by being torn down at the flag
	and by Duel.MaxConcurrent, and it is the same bargain the other three yards
	make permanently.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Sections = require(Pack:WaitForChild("Sections"))
local Depot = require(Pack:WaitForChild("Depot"))

local Duel = require(script.Parent.DuelConfig)

local DuelArena = {}

export type Slab = {
	part: BasePart,
	area: number,
	owner: number?,          -- userId, when the slab belongs to one side (Speed Run)
	name: string,
}

export type Arena = {
	model: Model,
	slabs: { Slab },
	spawns: { CFrame },      -- index IS the slot: 1 is the challenger, 2 the target
}

--==[ SMALL BUILDERS ]========================================================

local function part(name: string, parent: Instance, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function slab(parent: Instance, name: string, jobName: string, size: Vector3,
	cf: CFrame, duelId: number, owner: number?): Slab
	local p = part(name, parent, size, cf, Duel.SlabColor, Enum.Material.Concrete)
	local area = size.X * size.Z
	p:SetAttribute("DrivewayName", jobName)
	p:SetAttribute(Duel.SlabAttr, duelId)
	p:SetAttribute(Duel.SlabAreaAttr, area)
	if owner then p:SetAttribute(Duel.SlabOwnerAttr, owner) end
	CollectionService:AddTag(p, Sections.Tag)
	return { part = p, area = area, owner = owner, name = jobName }
end

local function kerb(parent: Instance, size: Vector3, cf: CFrame, colour: Color3)
	local p = part("Kerb", parent, size, cf, colour, Enum.Material.Concrete)
	p.CanCollide = false   -- it is a paint line, not a wall; tripping on it is nobody's idea of a race
	return p
end

local function walls(parent: Instance, centre: Vector3, w: number, l: number)
	local h = Duel.WallHeight
	local y = centre.Y + h * 0.5
	for _, s in ipairs({
		{ Vector3.new(w, h, 2), Vector3.new(0, 0, -l * 0.5) },
		{ Vector3.new(w, h, 2), Vector3.new(0, 0, l * 0.5) },
		{ Vector3.new(2, h, l), Vector3.new(-w * 0.5, 0, 0) },
		{ Vector3.new(2, h, l), Vector3.new(w * 0.5, 0, 0) },
	}) do
		local p = part("Rim", parent, s[1],
			CFrame.new(centre.X + s[2].X, y, centre.Z + s[2].Z), Duel.KerbColor)
		p.Transparency = 1
		p.CanCollide = true
	end
end

local function sign(parent: Instance, at: Vector3, text: string, tint: Color3)
	local post = part("SignPost", parent, Vector3.new(1, 8, 1),
		CFrame.new(at + Vector3.new(0, 4, 0)), Color3.fromRGB(70, 74, 84))
	post.CanCollide = false

	local board = Instance.new("BillboardGui")
	board.Name = "Sign"
	board.Size = UDim2.fromScale(16, 4.5)
	board.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	board.AlwaysOnTop = false
	-- Past this it is a smudge anyway, and the two Speed Run name signs are 100
	-- studs apart at most -- so this is comfortably beyond both of them.
	board.MaxDistance = 220
	board.Parent = post

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = tint
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(14, 16, 28)
	label.Parent = board
end

local function barrel(parent: Instance, at: Vector3)
	local drum = part("SealerBarrel", parent, Vector3.new(7, 9, 7),
		CFrame.new(at + Vector3.new(0, 4.5, 0)), Color3.fromRGB(38, 40, 46),
		Enum.Material.Metal)
	drum.Shape = Enum.PartType.Cylinder
	-- A cylinder part is built along its X axis, so it has to be tipped upright.
	drum.CFrame = CFrame.new(at + Vector3.new(0, 4.5, 0)) * CFrame.Angles(0, 0, math.pi * 0.5)

	local band = part("Band", parent, Vector3.new(7.4, 1.2, 7.4),
		CFrame.new(at + Vector3.new(0, 6.4, 0)), Color3.fromRGB(255, 196, 48),
		Enum.Material.Metal)
	band.Shape = Enum.PartType.Cylinder
	band.CFrame = CFrame.new(at + Vector3.new(0, 6.4, 0)) * CFrame.Angles(0, 0, math.pi * 0.5)
	band.CanCollide = false

	CollectionService:AddTag(drum, Depot.RefuelTag)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DuelFillPrompt"
	prompt.ActionText = "Fill Pail"
	prompt.ObjectText = "Sealer Barrel"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	-- Config.FillReach is the leash the client enforces; matching it here means the
	-- prompt disappears at the same distance the fill stops, rather than a step
	-- either side of it.
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("DepotFill", true)
	prompt.Parent = drum

	sign(parent, at + Vector3.new(0, 9, 0), "REFILL", Color3.fromRGB(255, 206, 56))
	return drum
end

--==[ SPEED RUN ]=============================================================

function DuelArena.buildSpeedRun(slot: number, duelId: number, a: Player, b: Player): Arena
	local S = Duel.SpeedRun
	local origin = Duel.originOf(slot)

	local model = Instance.new("Model")
	model.Name = "DuelArena_SpeedRun_" .. duelId
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	local padW = S.SlabW * 2 + S.Gap + S.Margin * 2
	local padL = S.SlabL + S.Margin * 2
	local groundY = origin.Y

	part("Apron", model, Vector3.new(padW, 2, padL),
		CFrame.new(origin.X, groundY - 1.25, origin.Z), Duel.RoadColor,
		Enum.Material.Asphalt)

	local players = { a, b }
	local tints = {
		Color3.fromRGB(255, 72, 86),    -- 1 red, the challenger
		Color3.fromRGB(70, 168, 255),   -- 2 blue, the one who accepted
	}
	local slabs: { Slab } = {}
	local spawns: { CFrame } = {}

	for i = 1, 2 do
		-- Lane centres either side of the arena's own centre line.
		local cx = origin.X + (if i == 1 then -(S.SlabW + S.Gap) * 0.5 else (S.SlabW + S.Gap) * 0.5)
		local cz = origin.Z
		local top = groundY

		slabs[i] = slab(model, "DuelDriveway" .. i,
			("%s's Driveway"):format(players[i].DisplayName),
			Vector3.new(S.SlabW, 0.5, S.SlabL),
			CFrame.new(cx, top - 0.25, cz), duelId, players[i].UserId)

		-- A kerb down both long edges, in this player's colour.
		for _, side in ipairs({ -1, 1 }) do
			kerb(model, Vector3.new(Duel.KerbThick, Duel.KerbHeight, S.SlabL),
				CFrame.new(cx + side * (S.SlabW * 0.5 + Duel.KerbThick * 0.5),
					top + Duel.KerbHeight * 0.5 - 0.25, cz), tints[i])
		end

		local headZ = cz - S.SlabL * 0.5 + 6
		spawns[i] = CFrame.lookAt(
			Vector3.new(cx, top + Duel.SpawnRise, headZ),
			Vector3.new(cx, top + Duel.SpawnRise, headZ + 20))

		sign(model, Vector3.new(cx, top, cz - S.SlabL * 0.5 - 5),
			players[i].DisplayName, tints[i])
	end

	walls(model, Vector3.new(origin.X, groundY, origin.Z), padW, padL)
	model.Parent = workspace

	return { model = model, slabs = slabs, spawns = spawns }
end

--==[ TURF WAR ]==============================================================

function DuelArena.buildTurfWar(slot: number, duelId: number): Arena
	local T = Duel.TurfWar
	local origin = Duel.originOf(slot)
	local groundY = origin.Y

	local model = Instance.new("Model")
	model.Name = "DuelArena_TurfWar_" .. duelId
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	local span = (T.Radius + T.SlabL * 0.5 + 40) * 2

	part("Ground", model, Vector3.new(span, 2, span),
		CFrame.new(origin.X, groundY - 1.25, origin.Z), Duel.GroundColor,
		Enum.Material.Grass)

	local circle = part("TurningCircle", model,
		Vector3.new(T.Circle * 2, 0.4, T.Circle * 2),
		CFrame.new(origin.X, groundY - 0.2, origin.Z), Duel.RoadColor,
		Enum.Material.Asphalt)
	circle.Shape = Enum.PartType.Cylinder
	circle.CFrame = CFrame.new(origin.X, groundY - 0.2, origin.Z)
		* CFrame.Angles(0, 0, math.pi * 0.5)
	circle.Size = Vector3.new(0.4, T.Circle * 2, T.Circle * 2)

	local slabs: { Slab } = {}
	local step = math.pi * 2 / T.Lots

	for i = 1, T.Lots do
		local ang = step * (i - 1)
		local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local centre = Vector3.new(origin.X, groundY, origin.Z) + dir * T.Radius

		local facing = CFrame.lookAt(centre, centre + dir)

		slabs[i] = slab(model, "DuelDriveway" .. i,
			("%d Duel Close"):format(100 + i * 2),
			Vector3.new(T.SlabW, 0.5, T.SlabL),
			facing * CFrame.new(0, -0.25, 0), duelId, nil)

		for _, side in ipairs({ -1, 1 }) do
			kerb(model, Vector3.new(Duel.KerbThick, Duel.KerbHeight, T.SlabL),
				facing * CFrame.new(side * (T.SlabW * 0.5 + Duel.KerbThick * 0.5),
					Duel.KerbHeight * 0.5 - 0.25, 0), Duel.KerbColor)
		end

		local backOff = -(T.SlabL * 0.5 + 12)
		local house = part("House", model, Vector3.new(T.SlabW + 14, 16, 18),
			facing * CFrame.new(0, 8, backOff),
			Color3.fromRGB(206, 190, 168))
		house.CanCollide = true
		part("Roof", model, Vector3.new(T.SlabW + 18, 3, 22),
			facing * CFrame.new(0, 17.5, backOff),
			Color3.fromRGB(122, 76, 62))
	end

	barrel(model, Vector3.new(origin.X, groundY, origin.Z))

	local spawns: { CFrame } = {}
	for i = 1, 2 do
		local ang = (if i == 1 then 0 else math.pi) + math.pi * 0.5
		local at = Vector3.new(origin.X, groundY, origin.Z)
			+ Vector3.new(math.cos(ang), 0, math.sin(ang)) * (T.Circle * 0.55)
		spawns[i] = CFrame.lookAt(at + Vector3.new(0, Duel.SpawnRise, 0),
			Vector3.new(origin.X, groundY + Duel.SpawnRise, origin.Z))
	end

	walls(model, Vector3.new(origin.X, groundY, origin.Z), span, span)
	model.Parent = workspace

	return { model = model, slabs = slabs, spawns = spawns }
end

--==[ TEARDOWN ]==============================================================

function DuelArena.destroy(arena: Arena?)
	if not arena then return end
	for _, s in ipairs(arena.slabs) do
		if s.part.Parent then
			CollectionService:RemoveTag(s.part, Sections.Tag)
		end
	end
	-- One frame for those signals to land on the clients before the geometry does.
	task.defer(function()
		if arena.model.Parent then arena.model:Destroy() end
	end)
end

function DuelArena.sweep()
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and string.sub(m.Name, 1, 10) == "DuelArena_" then
			m:Destroy()
		end
	end
end

return DuelArena
