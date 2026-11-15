--!strict
--[[
	BattleArena -- the 100 x 100 canvas, its rim, and eight spawn pads.

	Built by the SERVER at startup and replicated, so there is exactly one arena
	and every client is painting the same instance. The client only ever reads it,
	through `find` below.

	WHY IT IS Persistent RATHER THAN STREAMED

	StreamingEnabled is on in this place and the arena is six thousand studs from
	anything. A teleport is the one case the streaming radius cannot cover -- the
	whole district arrives underneath the player rather than in front of them --
	and the AFK yard already shipped that exact bug: AfkClient bailed with "no
	slab for plot N" because 1,171 parts did not make the frame between the
	teleport and the attribute landing.

	Marking the model Persistent hands it to every client at join and keeps it
	there. It costs eight hundred-odd studs of geometry permanently resident,
	which is cheap for never having to think about the race again. The players
	are still stream-requested around on the way in, as belt and braces.
]]

local CollectionService = game:GetService("CollectionService")

local Battle = require(script.Parent.BattleConfig)

local BattleArena = {}

BattleArena.ModelName = "SqueegeeArena"
BattleArena.CanvasName = "Canvas"
BattleArena.SpawnFolder = "Spawns"

--==[ LOOKUP ]================================================================

function BattleArena.find(): (Model?, BasePart?)
	local model = workspace:FindFirstChild(BattleArena.ModelName)
	if not model or not model:IsA("Model") then return nil, nil end
	local canvas = model:FindFirstChild(BattleArena.CanvasName)
	if not canvas or not canvas:IsA("BasePart") then return model, nil end
	return model, canvas
end

-- Yields. The client's only entry point, and it has to yield: Persistent models
-- still arrive after the first frame of a join.
function BattleArena.await(timeout: number?): (Model?, BasePart?)
	local model = workspace:WaitForChild(BattleArena.ModelName, timeout or 30)
	if not model or not model:IsA("Model") then return nil, nil end
	local canvas = model:WaitForChild(BattleArena.CanvasName, timeout or 30)
	if not canvas or not canvas:IsA("BasePart") then return model :: Model, nil end
	return model :: Model, canvas :: BasePart
end

function BattleArena.topCF(canvas: BasePart): CFrame
	return canvas.CFrame * CFrame.new(0, canvas.Size.Y * 0.5, 0)
end

function BattleArena.spawnsOf(model: Model): { SpawnLocation }
	local folder = model:FindFirstChild(BattleArena.SpawnFolder)
	local out: { SpawnLocation } = {}
	if not folder then return out end
	for i = 1, Battle.MaxPlayers do
		local pad = folder:FindFirstChild("Spawn" .. i)
		if pad and pad:IsA("SpawnLocation") then out[i] = pad end
	end
	return out
end

--==[ BUILD ]=================================================================

local function part(name: string, parent: Instance, size: Vector3, cf: CFrame,
		colour: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function BattleArena.build(): (Model, BasePart)
	local existing = workspace:FindFirstChild(BattleArena.ModelName)
	if existing then existing:Destroy() end

	local origin = Battle.Origin
	local half = Battle.HalfCanvas
	local size = Battle.CanvasSize

	local model = Instance.new("Model")
	model.Name = BattleArena.ModelName

	local canvas = part(BattleArena.CanvasName, model,
		Vector3.new(size, Battle.CanvasThick, size),
		CFrame.new(origin - Vector3.new(0, Battle.CanvasThick * 0.5, 0)),
		Battle.CanvasColor, Enum.Material.Asphalt)

	canvas:SetAttribute("SqueegeeBattleCanvas", true)

	local kerbT = 1.6
	for _, s in ipairs({
		{ Vector3.new(size + kerbT * 2, Battle.KerbHeight, kerbT), Vector3.new(0, 0, -half - kerbT * 0.5) },
		{ Vector3.new(size + kerbT * 2, Battle.KerbHeight, kerbT), Vector3.new(0, 0,  half + kerbT * 0.5) },
		{ Vector3.new(kerbT, Battle.KerbHeight, size), Vector3.new(-half - kerbT * 0.5, 0, 0) },
		{ Vector3.new(kerbT, Battle.KerbHeight, size), Vector3.new( half + kerbT * 0.5, 0, 0) },
	}) do
		local dim, off = s[1] :: Vector3, s[2] :: Vector3
		part("Kerb", model, dim,
			CFrame.new(origin + off + Vector3.new(0, Battle.KerbHeight * 0.5, 0)),
			Battle.KerbColor, Enum.Material.Concrete)
	end

	local wallT = 2
	for _, s in ipairs({
		{ Vector3.new(size + wallT * 2, Battle.WallHeight, wallT), Vector3.new(0, 0, -half - wallT * 0.5) },
		{ Vector3.new(size + wallT * 2, Battle.WallHeight, wallT), Vector3.new(0, 0,  half + wallT * 0.5) },
		{ Vector3.new(wallT, Battle.WallHeight, size), Vector3.new(-half - wallT * 0.5, 0, 0) },
		{ Vector3.new(wallT, Battle.WallHeight, size), Vector3.new( half + wallT * 0.5, 0, 0) },
	}) do
		local dim, off = s[1] :: Vector3, s[2] :: Vector3
		local w = part("Wall", model, dim,
			CFrame.new(origin + off + Vector3.new(0, Battle.WallHeight * 0.5, 0)),
			Battle.KerbColor, Enum.Material.SmoothPlastic)
		w.Transparency = 1
		w.CanQuery = false
		w.CanTouch = false
		w.CastShadow = false
	end

	local spawns = Instance.new("Folder")
	spawns.Name = BattleArena.SpawnFolder
	spawns.Parent = model

	local ring = half - Battle.SpawnInset
	for i = 1, Battle.MaxPlayers do
		local a = (i - 1) / Battle.MaxPlayers * math.pi * 2
		local at = origin + Vector3.new(math.sin(a) * ring, 0, math.cos(a) * ring)
		local pad = Instance.new("SpawnLocation")
		pad.Name = "Spawn" .. i
		pad.Anchored = true
		pad.Enabled = false          -- see above; nothing may respawn here by accident
		pad.Neutral = true
		pad.Duration = 0             -- no forcefield: it would block nothing and glow
		pad.CanCollide = false
		pad.CanQuery = false
		pad.Size = Vector3.new(7, 0.4, 7)
		pad.Transparency = 0.25
		pad.Color = Battle.colorOf(i)
		pad.Material = Enum.Material.Neon
		-- looking at the centre, so a player lands facing the canvas
		pad.CFrame = CFrame.lookAt(at + Vector3.new(0, 0.2, 0), origin + Vector3.new(0, 0.2, 0))
		pad.Parent = spawns
	end

	model.PrimaryPart = canvas
	model.Parent = workspace

	local ok, err = pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	if not ok then
		warn("[SqueegeeBattle] could not mark the arena Persistent (" .. tostring(err)
			.. ") -- players may arrive before it streams in")
	end

	return model, canvas
end

--==[ GEOMETRY THE SIMULATION NEEDS ]=========================================
function BattleArena.gridOrigin(): (number, number)
	local span = Battle.GridCells * Battle.CellSize
	return -span * 0.5, -span * 0.5
end

return BattleArena
