--!strict
--[[
	RaceSurface -- this player's own lane, as a live paintable driveway.

	The client's half of the event, and there is exactly one of these on a machine:
	your lane. Nobody else can paint it and you cannot paint theirs, so unlike the
	arena there is no relayed stroke to replay and no second buffer saying whose
	colour a cell is wearing. It is the neighbourhood's model, not the arena's --
	see the note at the top of DrivewayClient on why sealing went private.

	WHAT IT IS BUILT OUT OF

	  * a SurfaceGrid -- the SHIPPING one, unmodified. All of the sealcoat physics
	    is here: the bead in front of the rubber, the coat levelling to one
	    thickness, the cure, the flow.
	  * SurfaceRenderer -- also the shipping one, so a race lane is shaded by the
	    same code as the driveway outside the player's house and looks like it.
	    BattleSurface had to fork the renderer to get eight colours onto one
	    canvas; there is one colour here, and it is black, because it is sealer.

	It is a much smaller thing than DrivewaySurface, and all of the difference is
	that a lane is a clean rectangle: no blocker sweep, no road marking stencil, no
	edging absorption, no level-of-detail swap and no 3D liquid sheet. The mask is
	simply "all of it".

	THE FLAT DECAL, NOT THE SHEET

	Config.Use3DLiquid is true and the neighbourhood promotes its driveways to a
	displaced EditableMesh up close. A lane stays on the flat overlay, for the
	reason BattleSurface gives and one of its own: the sheet is a MeshPart texture
	and MeshPart textures IGNORE ALPHA, so it has to composite the coat over an
	opaque concrete term -- and a lane can be 155 studs long, so the whole of it is
	on screen at once from the start line and every stud of it would be a deforming
	mesh. A race is sixty seconds of continuous sweeping; the frame budget is worth
	more than the relief.

	IT DOES NOT KEEP THE SCORE. The percentage on the HUD is the server's, off
	RaceGrid -- see the header there for why a race cannot be ranked on Coverage.
	This file draws.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Pack:WaitForChild("Config"))
local SurfaceGrid = require(Pack:WaitForChild("SurfaceGrid"))
local SurfaceRenderer = require(Pack:WaitForChild("SurfaceRenderer"))

local Race = require(script.Parent.RaceConfig)

local RaceSurface = {}
RaceSurface.__index = RaceSurface

export type Geom = {
	topCF: CFrame,
	cell: number,
	cw: number,
	ch: number,
	halfLen: number,
}

local function editableAvailable(): boolean
	local ok, res = pcall(function()
		return AssetService.CreateEditableImage ~= nil
	end)
	return ok and res == true
end

function RaceSurface.new(geom: Geom)
	if not editableAvailable() then
		warn("[DrivewayRace] EditableImage is unavailable on this client -- the lane "
			.. "will not draw, but strokes still score")
		return nil
	end

	local cw, ch, cell = geom.cw, geom.ch, geom.cell
	local ok, image = pcall(AssetService.CreateEditableImage, AssetService,
		{ Size = Vector2.new(cw, ch) })
	if not ok or not image then
		warn(("[DrivewayRace] could not create a %d x %d lane image (%s)")
			:format(cw, ch, tostring(image)))
		return nil
	end

	local ox, oz = Race.gridOrigin(cw, ch, cell)
	local grid = SurfaceGrid.new(cw, ch, cell, ox, oz)

	buffer.fill(grid.mask, 0, 1)
	grid.maskCount = grid.N
	grid.paintCount = 0

	local spanX, spanZ = cw * cell, ch * cell

	local visuals = Instance.new("Folder")
	visuals.Name = "DrivewayRace_Paint"
	visuals.Parent = workspace:FindFirstChild("SealerVisuals") or workspace

	local overlay = Instance.new("Part")
	overlay.Name = "LanePaint"
	overlay.Anchored = true
	overlay.CanCollide = false
	overlay.CanQuery = false
	overlay.CanTouch = false
	overlay.CastShadow = false
	overlay.Transparency = 1
	overlay.Size = Vector3.new(spanX, 0.05, spanZ)
	overlay.CFrame = geom.topCF * CFrame.new(0, 0.035, 0)
	overlay.Parent = visuals

	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Top
	decal.TextureContent = Content.fromObject(image)
	decal.Parent = overlay

	local renderer = SurfaceRenderer.new(grid, image, Race.LaneColor)
	renderer.opaque = false

	local self = setmetatable({
		topCF = geom.topCF,
		grid = grid,
		image = image,
		visuals = visuals,
		overlay = overlay,
		decal = decal,
		renderer = renderer,
		cell = cell,
		halfLen = geom.halfLen,

		holds = Race.BladeCapacityPerStud * geom.halfLen * 2,
		_accum = 0,
		-- what the blade came out of its last pass carrying, which is the only thing
		-- that gates its next top-up; see ApplyStroke
		_pile = 0,
	}, RaceSurface)
	
	renderer:Prepare()
	grid:MarkAllDirty()
	return self
end

--==[ TRANSFORMS ]============================================================

function RaceSurface:ToLocal(p: Vector3): (number, number)
	local l = self.topCF:PointToObjectSpace(p)
	return l.X, l.Z
end

function RaceSurface:DirToLocal(v: Vector3): (number, number)
	local l = self.topCF:VectorToObjectSpace(v)
	local len = math.sqrt(l.X * l.X + l.Z * l.Z)
	if len < 1e-5 then return 0, 0 end
	return l.X / len, l.Z / len
end

function RaceSurface:SurfacePoint(p: Vector3): Vector3
	local l = self.topCF:PointToObjectSpace(p)
	return self.topCF:PointToWorldSpace(Vector3.new(l.X, 0, l.Z))
end

--==[ THE STROKE ]============================================================
function RaceSurface:ApplyStroke(sx: number, sz: number, ex: number, ez: number,
		ax: number, az: number, lx: number, lz: number, dt: number)

	local grid = self.grid
	dt = math.clamp(dt, 1 / 240, 0.25)

	local dx, dz = ex - sx, ez - sz
	local along = dx * lx + dz * lz
	local sign = if along < 0 then -1 else 1
	local px, pz = lx * sign, lz * sign
	local travel = math.abs(along)

	local halfLen = self.halfLen
	local wide = halfLen * 2

	local feed = 1 - self._pile / self.holds
	if feed < 0 then feed = 0 elseif feed > 1 then feed = 1 end
	local amount = (Race.PourPerStud * wide * travel + Race.PourIdle * wide * dt) * feed
	if amount > 0 then
		local n = math.clamp(math.ceil(wide / Race.PourSpacing), 1, Race.PourMaxPoints)
		local per = amount / n
		local lead = Race.PourLead
		local radius = math.max(self.cell * 2, Race.PourSpacing * 0.8)
		for k = 1, n do
			local t = if n > 1 then (k - 1) / (n - 1) * 2 - 1 else 0
			grid:Pour(ex + ax * halfLen * t + px * lead,
				ez + az * halfLen * t + pz * lead, per, radius)
		end
	end

	local res = grid:Squeegee(ex, ez, ax, az, px, pz, travel, travel / dt, dt, 1,
		halfLen, self.holds)
	-- `res` is SurfaceGrid's own reused _result table, so it is read here and not
	-- held.
	self._pile = if res then res.pile else 0
end

--==[ TICK ]==================================================================

function RaceSurface:Step(dt: number, maxCatchUp: number?, longStep: boolean?): number
	local grid = self.grid
	local fixed = 1 / Config.SimHz

	if longStep then
		local want = self._accum + dt
		local maxStep = Config.MaxStepSeconds
		local cap = maxCatchUp or Config.MaxCatchUp
		local sealedNew, ran = 0, 0
		while want >= fixed and ran < cap do
			local step = if want > maxStep then maxStep else want
			want -= step
			ran += 1
			sealedNew += (grid:Step(step) or 0)
		end
		self._accum = if want < fixed then want else 0
		return sealedNew
	end

	self._accum = math.min(self._accum + dt, fixed * (maxCatchUp or Config.MaxCatchUp))
	local sealedNew = 0
	while self._accum >= fixed do
		self._accum -= fixed
		sealedNew += (grid:Step(fixed) or 0)
	end
	return sealedNew
end

function RaceSurface:Render(maxCells: number?): number
	local n, rects = self.grid:DirtyRegions(maxCells)
	if n == 0 then return 0 end
	local painted = 0
	for r = 1, n do
		local q = rects[r]
		painted += self.renderer:Paint(q[1], q[2], q[3], q[4])
	end
	return painted
end

function RaceSurface:Coverage(): number
	return self.grid:Coverage()
end

function RaceSurface:Destroy()
	self.visuals:Destroy()
	self.overlay, self.decal = nil, nil
	self.image:Destroy()
end

return RaceSurface
