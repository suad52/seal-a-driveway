--!strict
--[[
	RaceYard -- the plaza, eight lanes, a start line and eight name boards.

	Built by the SERVER at startup and replicated, so there is exactly one yard
	and every client is standing on the same instances. The client only ever reads
	it -- and, unusually, barely even does that: RaceSurface takes its geometry
	off the RaceState payload rather than off these parts. See the note on `layout`.

	BUILT AT MAX SIZE AND RESIZED PER MATCH, WHICH IS NOT AN OPTIMISATION

	The obvious build is to make each lane when the race starts, at the size that
	player needs. StreamingEnabled is on in this place and the yard is six thousand
	studs from anything, so a part created two seconds before a teleport is a part
	that may not have arrived when the player lands on it -- the AFK yard shipped
	exactly that bug (AfkClient bailed with "no slab for plot N" because 1,171 parts
	did not make the frame) and BattleArena's header is a page about avoiding it.

	So the geometry exists from server start, is marked Persistent, and a match only
	moves and resizes what is already on every client. A Size write on a replicated
	part is one property; a Part created on a streamed-out chunk is a race.

	RaceConfig.maxSize is what "max" means, and it is derived from the cap on lane
	area rather than typed -- so raising MaxAreaMult builds a bigger yard on the
	next server start with no second edit here.
]]

local Race = require(script.Parent.RaceConfig)

local RaceYard = {}

RaceYard.ModelName = "DrivewayRaceYard"
RaceYard.LaneFolder = "Lanes"
RaceYard.LaneName = "Lane"          -- Lane1 .. Lane8
RaceYard.SlabName = "Slab"

--==[ LOOKUP ]================================================================

function RaceYard.find(): Model?
	local model = workspace:FindFirstChild(RaceYard.ModelName)
	if model and model:IsA("Model") then return model end
	return nil
end

-- Yields. The client's only entry point, and it has to yield: Persistent models
-- still arrive after the first frame of a join.
function RaceYard.await(timeout: number?): Model?
	local model = workspace:WaitForChild(RaceYard.ModelName, timeout or 30)
	if model and model:IsA("Model") then return model :: Model end
	return nil
end

function RaceYard.laneOf(model: Model, slot: number): Model?
	local folder = model:FindFirstChild(RaceYard.LaneFolder)
	if not folder then return nil end
	local lane = folder:FindFirstChild(RaceYard.LaneName .. slot)
	if lane and lane:IsA("Model") then return lane :: Model end
	return nil
end

function RaceYard.slabOf(model: Model, slot: number): BasePart?
	local lane = RaceYard.laneOf(model, slot)
	if not lane then return nil end
	local slab = lane:FindFirstChild(RaceYard.SlabName)
	if slab and slab:IsA("BasePart") then return slab :: BasePart end
	return nil
end

function RaceYard.boardOf(model: Model, slot: number): (TextLabel?, TextLabel?)
	local lane = RaceYard.laneOf(model, slot)
	if not lane then return nil, nil end
	local post = lane:FindFirstChild("Post")
	local gui = post and post:FindFirstChild("Board")
	if not gui then return nil, nil end
	local name = gui:FindFirstChild("Who")
	local pct = gui:FindFirstChild("Pct")
	return (if name and name:IsA("TextLabel") then name else nil),
		(if pct and pct:IsA("TextLabel") then pct else nil)
end

--==[ GEOMETRY THE SIMULATION NEEDS ]=========================================
function RaceYard.topCF(slab: BasePart): CFrame
	return slab.CFrame * CFrame.new(0, slab.Size.Y * 0.5, 0)
end

function RaceYard.laneX(slot: number, n: number): number
	local maxW = select(1, Race.maxSize())
	local pitch = maxW + Race.LaneGap
	return (slot - (n + 1) * 0.5) * pitch
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

local SLAB_THICK = 1.2

local function buildLane(parent: Instance, slot: number, maxW: number, maxL: number)
	local lane = Instance.new("Model")
	lane.Name = RaceYard.LaneName .. slot

	-- The slab's TOP sits on y = 0 of the lane's own frame; `layout` places the
	-- whole model, so everything here is built about the origin and moved once.
	local slab = part(RaceYard.SlabName, lane,
		Vector3.new(maxW, SLAB_THICK, maxL),
		CFrame.new(0, -SLAB_THICK * 0.5, 0),
		Race.LaneColor, Enum.Material.Concrete)

	slab:SetAttribute("DrivewayRaceLane", slot)

	for _, k in ipairs({ "KerbLeft", "KerbRight", "KerbFar" }) do
		local kerb = part(k, lane, Vector3.new(1, Race.KerbHeight, 1),
			CFrame.new(), Race.KerbColor, Enum.Material.Concrete)
		kerb.CanCollide = false
		kerb.CanQuery = false
		kerb.CanTouch = false
		kerb.CastShadow = false
	end

	local post = part("Post", lane, Vector3.new(0.7, 7, 0.7),
		CFrame.new(0, 3.5, 0), Race.colorOf(slot), Enum.Material.Neon)
	post.CanCollide = false
	post.CanQuery = false
	post.CanTouch = false

	local board = Instance.new("BillboardGui")
	board.Name = "Board"
	board.Size = UDim2.fromOffset(230, 74)
	board.StudsOffsetWorldSpace = Vector3.new(0, 5.4, 0)
	-- Far enough to read from the other end of the yard, which is the whole point
	-- of it; 700 studs clears a 564-stud rank of lanes corner to corner.
	board.MaxDistance = 700
	board.AlwaysOnTop = false
	board.LightInfluence = 0
	board.Parent = post

	local who = Instance.new("TextLabel")
	who.Name = "Who"
	who.BackgroundTransparency = 1
	who.Size = UDim2.new(1, 0, 0, 30)
	who.Font = Enum.Font.GothamBold
	who.TextScaled = true
	who.TextColor3 = Color3.fromRGB(255, 255, 255)
	who.TextStrokeTransparency = 0.2
	who.Text = ""
	who.Parent = board

	local pct = Instance.new("TextLabel")
	pct.Name = "Pct"
	pct.BackgroundTransparency = 1
	pct.Position = UDim2.fromOffset(0, 30)
	pct.Size = UDim2.new(1, 0, 0, 44)
	pct.Font = Enum.Font.GothamBlack
	pct.TextScaled = true
	pct.TextColor3 = Race.colorOf(slot)
	pct.TextStrokeTransparency = 0.2
	pct.Text = ""
	pct.Parent = board

	lane.PrimaryPart = slab
	lane.Parent = parent
	return lane
end

function RaceYard.build(): Model
	local existing = workspace:FindFirstChild(RaceYard.ModelName)
	if existing then existing:Destroy() end

	local origin = Race.Origin
	local maxW, maxL = Race.maxSize()
	local pitch = maxW + Race.LaneGap
	local spanX = pitch * Race.MaxPlayers - Race.LaneGap

	local model = Instance.new("Model")
	model.Name = RaceYard.ModelName

	local plazaW = spanX + Race.PlazaMargin * 2
	local plazaL = maxL + Race.LaneApron + Race.PlazaMargin * 2
	local plazaThick = 4
	-- Lanes run along +Z from the start line at z = 0, so the ground in use is
	-- -LaneApron .. maxL and the plaza is that plus a margin at each end.
	local plazaZ = (maxL - Race.LaneApron) * 0.5
	part("Plaza", model, Vector3.new(plazaW, plazaThick, plazaL),
		CFrame.new(origin + Vector3.new(0, -0.05 - plazaThick * 0.5, plazaZ)),
		Race.PlazaColor, Enum.Material.Asphalt)

	-- The start line, across the front of every lane. Purely a mark: the count-in
	-- is what holds players still, not geometry.
	local line = part("StartLine", model,
		Vector3.new(spanX + 16, 0.06, 1.6),
		CFrame.new(origin + Vector3.new(0, 0.02, -1.2)),
		Color3.fromRGB(250, 232, 120), Enum.Material.Neon)
	line.CanCollide = false
	line.CanQuery = false
	line.CanTouch = false

	local lanes = Instance.new("Folder")
	lanes.Name = RaceYard.LaneFolder
	lanes.Parent = model
	for i = 1, Race.MaxPlayers do
		buildLane(lanes, i, maxW, maxL)
	end

	model.Parent = workspace
	-- Placed once at build so a yard nobody has raced in yet is not a heap of
	-- lanes at the world origin of its own model.
	RaceYard.layout(model, {})

	local ok, err = pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	if not ok then
		warn("[DrivewayRace] could not mark the yard Persistent (" .. tostring(err)
			.. ") -- players may arrive before it streams in")
	end

	return model
end

--==[ ONE MATCH'S LAYOUT ]====================================================

export type Geom = {
	w: number,
	l: number,
	cell: number,
	cw: number,
	ch: number,
}

export type Lane = {
	slot: number,
	w: number,
	l: number,
	cell: number,
	cw: number,
	ch: number,
	topCF: CFrame,
	spawnCF: CFrame,
}

function RaceYard.layout(model: Model, sizes: { Geom }): { Lane }
	local origin = Race.Origin
	local n = #sizes
	local out: { Lane } = {}

	for slot = 1, Race.MaxPlayers do
		local lane = RaceYard.laneOf(model, slot)
		if lane then
			local want = sizes[slot]
			local slab = lane:FindFirstChild(RaceYard.SlabName) :: BasePart?
			local post = lane:FindFirstChild("Post") :: BasePart?

			if not want then
				-- Parked well under the plaza. Transparency alone would leave a lane
				-- nobody can see but everybody can walk into.
				for _, p in ipairs(lane:GetDescendants()) do
					if p:IsA("BasePart") then p.Transparency = 1 end
				end
				lane:PivotTo(CFrame.new(origin + Vector3.new(0, -400, 0)))
			elseif slab then
				local w, l = want.w, want.l
				local x = RaceYard.laneX(slot, n)
				-- The lane's near edge is on the start line, so it grows away from the
				-- player rather than around them: every racer starts the same distance
				-- from their own first square stud whatever size their lane is.
				local centre = origin + Vector3.new(x, 0, l * 0.5)
				lane:PivotTo(CFrame.new(centre))

				for _, p in ipairs(lane:GetDescendants()) do
					if p:IsA("BasePart") then p.Transparency = 0 end
				end

				slab.Size = Vector3.new(w, SLAB_THICK, l)
				slab.CFrame = CFrame.new(centre - Vector3.new(0, SLAB_THICK * 0.5, 0))

				local kt, kh = Race.KerbThick, Race.KerbHeight
				local function place(name: string, size: Vector3, off: Vector3)
					local k = lane:FindFirstChild(name) :: BasePart?
					if not k then return end
					k.Size = size
					k.CFrame = CFrame.new(centre + off + Vector3.new(0, kh * 0.5, 0))
				end
				place("KerbLeft", Vector3.new(kt, kh, l),
					Vector3.new(-w * 0.5 - kt * 0.5, 0, 0))
				place("KerbRight", Vector3.new(kt, kh, l),
					Vector3.new(w * 0.5 + kt * 0.5, 0, 0))
				place("KerbFar", Vector3.new(w + kt * 2, kh, kt),
					Vector3.new(0, 0, l * 0.5 + kt * 0.5))

				if post then
					-- Beside the start of the lane, not on it: a post standing on the
					-- slab is a post the blade has to go round for 1% of the job.
					post.CFrame = CFrame.new(origin
						+ Vector3.new(x - w * 0.5 - 3.2, 3.5, -2))
				end

				out[slot] = {
					slot = slot, w = w, l = l,
					cell = want.cell, cw = want.cw, ch = want.ch,
					topCF = CFrame.new(origin + Vector3.new(x, 0, l * 0.5)),
					-- On the apron, a couple of studs short of their own start line and
					-- facing down the lane, so the count-in is spent looking at the job.
					spawnCF = CFrame.lookAt(
						origin + Vector3.new(x, Race.SpawnRise, -Race.LaneApron * 0.5),
						origin + Vector3.new(x, Race.SpawnRise, l * 0.5)),
				}
			end
		end
	end

	return out
end

return RaceYard
