--!strict
--[[
	BattleSurface -- the arena canvas as a live, paintable surface.

	The client's half of the event. It owns three things that have to stay in
	lockstep:

	  * a SurfaceGrid -- the SHIPPING one, unmodified. All of the sealcoat
	    physics is here: the bead in front of the rubber, the coat levelling to
	    one thickness, the cure, the flow. Nothing about the arena is a
	    reimplementation of it.
	  * a BattleGrid  -- one byte a cell saying whose colour that ground is.
	  * a BattleRenderer + EditableImage -- the two, drawn.

	It is a much smaller thing than DrivewaySurface, and all of the difference is
	that the canvas is a clean rectangle: there is no blocker sweep, no road
	marking stencil, no edging absorption, no level-of-detail swap and no 3D
	liquid sheet. The mask is simply "all of it", which is what lets this be 250
	lines instead of 1,200.

	THE FLAT DECAL, NOT THE SHEET

	Config.Use3DLiquid is true and the neighbourhood promotes its driveways to a
	displaced EditableMesh up close. The arena stays on the flat overlay, on
	purpose: the sheet is a MeshPart texture and MeshPart textures IGNORE ALPHA,
	so it has to composite the coat over an opaque concrete term. Eight
	overlapping colours on a hundred-stud canvas want real alpha -- unpainted
	ground has to be visibly unpainted from across the arena -- and one flat
	decal costs a fraction of what a 50,000-cell deforming mesh would.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Pack:WaitForChild("Config"))
local SurfaceGrid = require(Pack:WaitForChild("SurfaceGrid"))

local Battle = require(script.Parent.BattleConfig)
local BattleArena = require(script.Parent.BattleArena)
local BattleGrid = require(script.Parent.BattleGrid)
local BattleRenderer = require(script.Parent.BattleRenderer)

local BattleSurface = {}
BattleSurface.__index = BattleSurface

local function editableAvailable(): boolean
	local ok, res = pcall(function()
		return AssetService.CreateEditableImage ~= nil
	end)
	return ok and res == true
end

function BattleSurface.new(canvas: BasePart)
	if not editableAvailable() then
		warn("[SqueegeeBattle] EditableImage is unavailable on this client -- "
			.. "the arena will not draw, but strokes still score")
		return nil
	end

	local cells = Battle.GridCells
	local cell = Battle.CellSize
	local ox, oz = BattleArena.gridOrigin()

	local ok, image = pcall(AssetService.CreateEditableImage, AssetService,
		{ Size = Vector2.new(cells, cells) })
	if not ok or not image then
		warn(("[SqueegeeBattle] could not create a %d x %d arena image (%s)")
			:format(cells, cells, tostring(image)))
		return nil
	end

	local grid = SurfaceGrid.new(cells, cells, cell, ox, oz)

	buffer.fill(grid.mask, 0, 1)
	grid.maskCount = grid.N
	grid.paintCount = 0

	local ownerGrid = BattleGrid.new(cells, cell, ox, oz, Battle.MaxPlayers)

	local topCF = BattleArena.topCF(canvas)
	local span = cells * cell

	local visuals = Instance.new("Folder")
	visuals.Name = "SqueegeeBattle_Paint"
	visuals.Parent = workspace:FindFirstChild("SealerVisuals") or workspace

	local overlay = Instance.new("Part")
	overlay.Name = "ArenaPaint"
	overlay.Anchored = true
	overlay.CanCollide = false
	overlay.CanQuery = false
	overlay.CanTouch = false
	overlay.CastShadow = false
	overlay.Transparency = 1
	overlay.Size = Vector3.new(span, 0.05, span)
	overlay.CFrame = topCF * CFrame.new(0, 0.035, 0)
	overlay.Parent = visuals

	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Top
	decal.TextureContent = Content.fromObject(image)
	decal.Parent = overlay

	local self = setmetatable({
		canvas = canvas,
		topCF = topCF,
		grid = grid,
		owners = ownerGrid,
		image = image,
		visuals = visuals,
		overlay = overlay,
		decal = decal,
		renderer = BattleRenderer.new(grid, ownerGrid, image, Battle.CanvasColor),
		cell = cell,
		span = span,
		_accum = 0,
		-- what each slot's blade is carrying, so a top-up is only poured into a
		-- blade that has room for it; see ApplyStroke
		_pile = {},
	}, BattleSurface)

	grid:MarkAllDirty()
	return self
end

--==[ TRANSFORMS ]============================================================

function BattleSurface:ToLocal(p: Vector3): (number, number)
	local l = self.topCF:PointToObjectSpace(p)
	return l.X, l.Z
end

function BattleSurface:DirToLocal(v: Vector3): (number, number)
	local l = self.topCF:VectorToObjectSpace(v)
	local len = math.sqrt(l.X * l.X + l.Z * l.Z)
	if len < 1e-5 then return 0, 0 end
	return l.X / len, l.Z / len
end

function BattleSurface:SurfacePoint(p: Vector3): Vector3
	local l = self.topCF:PointToObjectSpace(p)
	return self.topCF:PointToWorldSpace(Vector3.new(l.X, 0, l.Z))
end

--==[ REPAINT BOOKKEEPING ]===================================================
function BattleSurface:MarkDirtyRect(x0: number, y0: number, x1: number, y1: number)
	if x1 < x0 or y1 < y0 then return end
	local grid = self.grid
	local cs = Config.ChunkCells
	-- math.floor rather than integer division: buffer offsets have to be whole
	-- numbers and `//` on floats hands back a float that happens to be integral
	local cx0 = math.max(0, math.floor(x0 / cs))
	local cy0 = math.max(0, math.floor(y0 / cs))
	local cx1 = math.min(grid.CW - 1, math.floor(x1 / cs))
	local cy1 = math.min(grid.CH - 1, math.floor(y1 / cs))
	local dirty, CW = grid.dirty, grid.CW
	for cy = cy0, cy1 do
		local base = cy * CW
		for cx = cx0, cx1 do
			buffer.writeu8(dirty, base + cx, 1)
		end
	end
	grid.anyDirty = true
end

--==[ THE STROKE ]============================================================
function BattleSurface:ApplyStroke(slot: number,
		sx: number, sz: number, ex: number, ez: number,
		ax: number, az: number, lx: number, lz: number, dt: number,
		halfLen: number?)

	local grid = self.grid
	dt = math.clamp(dt, 1 / 240, 0.25)

	local dx, dz = ex - sx, ez - sz
	local along = dx * lx + dz * lz
	local sign = if along < 0 then -1 else 1
	local px, pz = lx * sign, lz * sign
	local travel = math.abs(along)

	local halfLen = halfLen or Battle.BladeHalfLen
	local carried = self._pile[slot] or 0
	local feed = 1 - carried / Battle.BladeCapacity
	if feed < 0 then feed = 0 elseif feed > 1 then feed = 1 end
	local amount = (Battle.PourPerStud * travel + Battle.PourIdle * dt) * feed
	if amount > 0 then
		local lead = Battle.PourLead
		local n = Battle.PourPoints
		local per = amount / n
		-- across the rubber, so the ends of the blade get fed as well as the
		-- middle; one circle at the centre leaves a dry strip at each tip
		local radius = math.max(self.cell * 2, halfLen / n * 1.6)
		for k = 1, n do
			local t = if n > 1 then (k - 1) / (n - 1) * 2 - 1 else 0
			grid:Pour(ex + ax * halfLen * t + px * lead,
				ez + az * halfLen * t + pz * lead, per, radius)
		end
	end

	local res = grid:Squeegee(ex, ez, ax, az, px, pz, travel, travel / dt, dt, 1,
		halfLen, Battle.BladeCapacity)

	self._pile[slot] = if res then res.pile else 0


	local cx0, cy0, cx1, cy1, changed =
		self.owners:StampSweep(slot, sx, sz, ex, ez, ax, az, halfLen, Battle.StampHalfBand)
	if changed > 0 then
		self:MarkDirtyRect(cx0, cy0, cx1, cy1)
	end
end

function BattleSurface:ReleaseSlot(slot: number)
	self._pile[slot] = nil
	if self.owners:release(slot) > 0 then
		self.grid:MarkAllDirty()
	end
end

--==[ TICK ]==================================================================

function BattleSurface:Step(dt: number, maxCatchUp: number?, longStep: boolean?): number
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

function BattleSurface:Render(maxCells: number?): number
	local n, rects = self.grid:DirtyRegions(maxCells)
	if n == 0 then return 0 end
	local painted = 0
	for r = 1, n do
		local q = rects[r]
		painted += self.renderer:Paint(q[1], q[2], q[3], q[4])
	end
	return painted
end

function BattleSurface:DirtyCells(): number
	return self.grid:DirtyCells()
end

function BattleSurface:Clear()
	self.grid:Reset()
	self.owners:Reset()
	table.clear(self._pile)
	-- Reset already marks the whole grid dirty; this is for the ownership half,
	-- which the sealcoat grid knows nothing about.
	self.grid:MarkAllDirty()
end

function BattleSurface:Destroy()
	self.visuals:Destroy()
	self.overlay, self.decal = nil, nil
	self.image:Destroy()
end

return BattleSurface
