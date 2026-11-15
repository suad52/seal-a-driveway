--!strict
--[[
	DrivewaySurface -- one sealable slab.

	Owns the grid, the renderer, and the invisible overlay part the sealer decal
	lives on. Everything the simulation sees is in the slab's own local frame, so
	a rotated or off-axis driveway works without any special-casing.

	This is a client-side object: each player builds their own copy and runs their
	own simulation. The server never touches a grid.
]]

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local SurfaceGrid = require(script.Parent.SurfaceGrid)
local SurfaceRenderer = require(script.Parent.SurfaceRenderer)
local LiquidMesh = require(script.Parent.LiquidMesh)
local SlabTint = require(script.Parent.SlabTint)

local SurfaceFrame = require(script.Parent.SurfaceFrame)
local DrivewaySurface = {}
DrivewaySurface.__index = DrivewaySurface

local Detail = {
	Bare  = 0,   -- nothing of ours; the tinted slab part carries the finished look
	Flat  = 1,   -- the invisible overlay plate and its decal
	Sheet = 2,   -- the displaced EditableMesh
}
DrivewaySurface.Detail = Detail

local apiChecked, apiOK = false, false
local function editableApiAvailable(): boolean
	if apiChecked then return apiOK end
	apiChecked = true
	apiOK = pcall(function()
		local probe = AssetService:CreateEditableImage({ Size = Vector2.new(4, 4) })
		probe:WritePixelsBuffer(Vector2.zero, Vector2.new(4, 4), buffer.create(4 * 4 * 4))
		probe:Destroy()
	end)
	if not apiOK then
		warn("[DrivewaySealer] Sealing is disabled: this place cannot use the"
			.. " Editable Image/Mesh APIs.\n  Fix: File > Game Settings > Security >"
			.. " turn on \"Allow Mesh & Image APIs\", then republish.")
	end
	return apiOK
end

local function effectsFolder(): Folder
	local f = workspace:FindFirstChild("SealerVisuals")
	if not f then
		f = Instance.new("Folder")
		f.Name = "SealerVisuals"
		f.Parent = workspace
	end
	return f :: Folder
end

-- A part's extent in the slab's own frame, taken from its eight corners so a
-- strip laid at an angle measures the shape it was built at rather than the box
-- around it. Y comes back relative to the slab's top face.
local function localAABB(topCF: CFrame, p: BasePart)
	local c = topCF:ToObjectSpace(p.CFrame)
	local s = p.Size * 0.5
	local minX, maxX = math.huge, -math.huge
	local maxY = -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local v = c * Vector3.new(s.X * sx, s.Y * sy, s.Z * sz)
				if v.X < minX then minX = v.X end
				if v.X > maxX then maxX = v.X end
				if v.Y > maxY then maxY = v.Y end
				if v.Z < minZ then minZ = v.Z end
				if v.Z > maxZ then maxZ = v.Z end
			end
		end
	end
	return minX, maxX, maxY, minZ, maxZ
end

local function edgeFootprint(slab: BasePart, topCF: CFrame, size: Vector3)
	local sx0, sx1 = -size.X * 0.5, size.X * 0.5
	local sz0, sz1 = -size.Z * 0.5, size.Z * 0.5
	local fx0, fx1, fz0, fz1 = sx0, sx1, sz0, sz1
	local parts: { BasePart } = {}
	local grow = Config.MaxEdgeGrow or 0
	if grow <= 0 then return fx0, fx1, fz0, fz1, parts end
	local flush, touch = Config.EdgeFlushTol, Config.EdgeTouchTol
	for _, p in ipairs(CollectionService:GetTagged(Config.EdgeTag)) do
		if p:IsA("BasePart") and p ~= slab then
			local ax0, ax1, ay1, az0, az1 = localAABB(topCF, p)
			-- flush with this slab's surface, and touching its footprint rather
			-- than merely somewhere near it
			if ay1 >= -flush and ay1 <= flush
				and ax0 <= sx1 + touch and ax1 >= sx0 - touch
				and az0 <= sz1 + touch and az1 >= sz0 - touch then
				parts[#parts + 1] = p

				local ex0 = math.max(ax0, sx0 - grow)
				local ex1 = math.min(ax1, sx1 + grow)
				local ez0 = math.max(az0, sz0 - grow)
				local ez1 = math.min(az1, sz1 + grow)
				if ex1 - ex0 > ez1 - ez0 then
					-- runs along X, so it borders in Z
					ex0 = math.max(ex0, sx0)
					ex1 = math.min(ex1, sx1)
				else
					-- runs along Z, so it borders in X
					ez0 = math.max(ez0, sz0)
					ez1 = math.min(ez1, sz1)
				end
				if ex0 < fx0 then fx0 = ex0 end
				if ex1 > fx1 then fx1 = ex1 end
				if ez0 < fz0 then fz0 = ez0 end
				if ez1 > fz1 then fz1 = ez1 end
			end
		end
	end
	return fx0, fx1, fz0, fz1, parts
end

function DrivewaySurface.new(slab: BasePart)
	if not editableApiAvailable() then return nil end
	local slabCF, size = SurfaceFrame.of(slab)
	local topCF = slabCF * CFrame.new(0, size.Y * 0.5, 0)

	-- The grid covers the slab AND its edging, so a kerb is ground on this job
	-- rather than a pale strip beside it that nothing can reach.
	local fx0, fx1, fz0, fz1, edgeParts = edgeFootprint(slab, topCF, size)
	local footX, footZ = fx1 - fx0, fz1 - fz0
	local centreX, centreZ = (fx0 + fx1) * 0.5, (fz0 + fz1) * 0.5

	local axis = Config.MaxGridAxis or 1024
	local cell = Config.CellSize
	local w = math.ceil(footX / cell)
	local h = math.ceil(footZ / cell)
	while w * h > Config.MaxGridCells or w > axis or h > axis do
		cell *= 1.08
		w = math.ceil(footX / cell)
		h = math.ceil(footZ / cell)
	end

	local spanX, spanZ = w * cell, h * cell

	-- Origin is the footprint's corner, not the slab's: absorbed edging is
	-- usually on one side only, so the grid is no longer centred on the slab.
	-- Everything downstream works in slab-local studs and goes through
	-- WorldToCell, so the offset is invisible to it.
	local grid = SurfaceGrid.new(w, h, cell, centreX - spanX * 0.5, centreZ - spanZ * 0.5)

	-- Belt and braces on the ceilings above: EditableImage also draws on a
	-- shared memory budget for the whole experience, so a create can fail for
	-- reasons that have nothing to do with this slab's size. Failing soft leaves
	-- one driveway unsealable instead of erroring out of the build loop and
	-- taking every slab behind it in the queue with it.
	local ok, image = pcall(AssetService.CreateEditableImage, AssetService, { Size = Vector2.new(w, h) })
	if not ok or not image then
		warn(("[Sealer] %s: could not create a %d x %d image for the surface (%s)")
			:format(slab:GetFullName(), w, h, tostring(image)))
		return nil
	end

	local visuals = Instance.new("Folder")
	visuals.Name = slab.Name .. "_Sealer"
	visuals.Parent = effectsFolder()

	local self = setmetatable({
		slab = slab,
		frameSize = size,
		visuals = visuals,
		name = slab:GetAttribute("DrivewayName") or slab.Name,
		baseValue = slab:GetAttribute("BaseValue") or 200,
		-- Scales what this slab is worth, read here so the client's running total and
		-- the server's payout come off the same number. The tutorial slab carries one
		-- (well above 1, to hold a small job at a driveway's price -- see
		-- Economy.scaleOf); without it the HUD would advertise a different reward from
		-- the one the server pays.
		payScale = slab:GetAttribute("PayScale") or 1,
		grid = grid,
		image = image,
		topCF = topCF,
		cell = cell,
		-- the 3D sheet and the flat decal would z-fight, so only one exists
		overlay = nil,
		decal = nil,
		-- nothing is built until the mask sweep finishes, and a slab this player
		-- already finished may never build an overlay at all
		detail = Detail.Bare,
		spanX = spanX,
		spanZ = spanZ,
		-- footprint centre in slab-local studs; zero unless edging was absorbed
		centreX = centreX,
		centreZ = centreZ,
		edgeParts = edgeParts,
		topY = (topCF.Position).Y,

		renderer = SurfaceRenderer.new(grid, image, SlabTint.baseColorOf(slab)),
		mesh = nil,
		ready = false,
		_accum = 0,
	}, DrivewaySurface)

	if not Config.Use3DLiquid then
		self:_buildFlatOverlay()
	end

	self:_buildMask()
	return self
end

-- Flat fallback: an invisible plate whose top-face decal carries the whole
-- look. Decals do respect image alpha, unlike MeshPart textures.
function DrivewaySurface:_buildFlatOverlay()
	-- Never alongside the 3D sheet: the decal sits 0.035 studs over the slab and
	-- the sheet crosses that same plane, so the two z-fight across the whole
	-- driveway. Guarding here rather than at each call site makes the bad state
	-- unreachable no matter what order detail changes arrive in.
	if self.overlay or self.mesh then return end
	local overlay = Instance.new("Part")
	overlay.Name = self.slab.Name .. "_SealerOverlay"
	overlay.Anchored = true
	overlay.CanCollide = false
	overlay.CanQuery = false
	overlay.CanTouch = false
	overlay.CastShadow = false
	overlay.Transparency = 1
	overlay.Size = Vector3.new(self.spanX, 0.05, self.spanZ)
	-- 0.035 over the slab clears the 0.02 an absorbed kerb stands proud by, so
	-- the decal draws over the edging instead of fighting it.
	overlay.CFrame = self.topCF * CFrame.new(self.centreX, 0.035, self.centreZ)
	overlay.Parent = self.visuals

	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Top
	decal.TextureContent = Content.fromObject(self.image)
	decal.Parent = overlay

	self.overlay = overlay
	self.decal = decal
	self.detail = Detail.Flat
	self.renderer.opaque = false
	self:_keepOnly(overlay)
end

-- At most one visual per surface, and at Bare there is none. Anything else in
-- this surface's folder is stale by definition, so drop it rather than let it
-- render.
function DrivewaySurface:_keepOnly(keep: Instance?)
	for _, c in ipairs(self.visuals:GetChildren()) do
		if c ~= keep then c:Destroy() end
	end
end

local BLOCK_LIP   = 0.06   -- studs above the slab that a blocker has to clear
local BLOCK_CLEAR = 2.50   -- studs of headroom that count as "in the way"

local BLOCK_FOOT = 0.5

local BLOCK_TAG = "SealBlocked"

function DrivewaySurface:_findBlockers(): { BasePart }
	local op = OverlapParams.new()
	op.MaxParts = 400
	local band = BLOCK_CLEAR - BLOCK_LIP
	local probe = self.topCF * CFrame.new(self.centreX, BLOCK_LIP + band * 0.5, self.centreZ)
	local ours = effectsFolder()
	-- Absorbed edging is ground, not an obstacle. It clears BLOCK_LIP by a wide
	-- margin so it would not register anyway, but saying so here means a thicker
	-- kerb can be tagged later without silently masking out the strip it adds.
	local isEdge = {}
	for _, p in ipairs(self.edgeParts) do isEdge[p] = true end

	-- The gap between the slab and the part's underside, in the slab's own frame.
	-- Same extent-along-up projection the tagged sweep below uses, so a rotated
	-- part answers honestly rather than by its axis-aligned bounding box.
	local up = self.topCF.UpVector
	local function clearance(p: BasePart): number
		local ey = 0.5 * (math.abs(p.CFrame.RightVector:Dot(up)) * p.Size.X
			+ math.abs(p.CFrame.UpVector:Dot(up)) * p.Size.Y
			+ math.abs(p.CFrame.LookVector:Dot(up)) * p.Size.Z)
		return self.topCF:PointToObjectSpace(p.Position).Y - ey
	end

	local found, seen = {}, {}
	for _, p in ipairs(workspace:GetPartBoundsInBox(probe,
		Vector3.new(self.spanX, band, self.spanZ), op)) do
		if p ~= self.slab and not isEdge[p] and p.Anchored and p.CanQuery
			and p.Transparency < 0.5 and not p:IsDescendantOf(ours)
			and clearance(p) <= BLOCK_FOOT then
			seen[p] = true
			found[#found + 1] = p
		end
	end

	for _, p in ipairs(CollectionService:GetTagged(BLOCK_TAG)) do
		if p:IsA("BasePart") and p ~= self.slab and not isEdge[p] and not seen[p]
			and not p:IsDescendantOf(ours) then
			local l = self.topCF:PointToObjectSpace(p.Position)
			
			local up = self.topCF.UpVector
			local ey = 0.5 * (math.abs(p.CFrame.RightVector:Dot(up)) * p.Size.X
				+ math.abs(p.CFrame.UpVector:Dot(up)) * p.Size.Y
				+ math.abs(p.CFrame.LookVector:Dot(up)) * p.Size.Z)
			if l.Y - ey < BLOCK_CLEAR and l.Y + ey > -BLOCK_CLEAR
				and math.abs(l.X - self.centreX) < self.spanX * 0.5 + p.Size.Magnitude
				and math.abs(l.Z - self.centreZ) < self.spanZ * 0.5 + p.Size.Magnitude then
				seen[p] = true
				found[#found + 1] = p
			end
		end
	end
	return found
end

function DrivewaySurface:_stencilBlockers(parts: { BasePart }): number
	if #parts == 0 then return 0 end
	local grid = self.grid
	local W, H = grid.W, grid.H
	local mask = grid.mask
	local cell = grid.cellSize
	local ox, oz = grid.originX, grid.originZ
	local cleared = 0
	for _, p in ipairs(parts) do
		local size = p.Size
		local rel = self.topCF:ToObjectSpace(p.CFrame)
		local l = rel.Position
		local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
		local xv, yv, zv = rel.XVector, rel.YVector, rel.ZVector
		local ey = hx * math.abs(xv.Y) + hy * math.abs(yv.Y) + hz * math.abs(zv.Y)
		-- it has to come down into reach; a beam overhead still does not count
		if l.Y - ey < BLOCK_CLEAR and l.Y + ey > -0.35 then
			local ex = hx * math.abs(xv.X) + hy * math.abs(yv.X) + hz * math.abs(zv.X)
			local ez = hx * math.abs(xv.Z) + hy * math.abs(yv.Z) + hz * math.abs(zv.Z)
			local fx0, fy0 = grid:WorldToCell(l.X - ex, l.Z - ez)
			local fx1, fy1 = grid:WorldToCell(l.X + ex, l.Z + ez)
			local x0 = math.max(0, math.floor(fx0))
			local y0 = math.max(0, math.floor(fy0))
			local x1 = math.min(W - 1, math.ceil(fx1))
			local y1 = math.min(H - 1, math.ceil(fy1))
			local cx = -(l.X * xv.X + l.Y * xv.Y + l.Z * xv.Z)
			local cz = -(l.X * zv.X + l.Y * zv.Y + l.Z * zv.Z)
			local xvX, xvZ = xv.X, xv.Z
			local zvX, zvZ = zv.X, zv.Z
			for y = y0, y1 do
				local rowBase = y * W
				local lz = oz + (y + 0.5) * cell
				local xBase = cx + lz * xvZ
				local zBase = cz + lz * zvZ
				for x = x0, x1 do
					local i = rowBase + x
					if buffer.readu8(mask, i) == 1 then
						local lx = ox + (x + 0.5) * cell
						local oX = xBase + lx * xvX
						if oX <= hx and oX >= -hx then
							local oZ = zBase + lx * zvX
							if oZ <= hz and oZ >= -hz then
								buffer.writeu8(mask, i, 0)
								cleared += 1
							end
						end
					end
				end
			end
		end
	end
	return cleared
end

function DrivewaySurface:_stencilPaint(): number
	local grid = self.grid
	local W = grid.W
	local mask = grid.mask
	local paint = grid.paint
	local cell = grid.cellSize
	local ox, oz = grid.originX, grid.originZ
	local cleared = 0
	for _, p in ipairs(CollectionService:GetTagged("RoadPaint")) do
		if p:IsA("BasePart") then
			local size = p.Size
			-- the part's own frame, in this slab's local space, resolved once
			local rel = self.topCF:ToObjectSpace(p.CFrame)
			local l = rel.Position
			-- on this slab's surface, not on the one across the road
			if l.Y > -0.35 and l.Y < BLOCK_CLEAR
				and math.abs(l.X - self.centreX) < self.spanX * 0.5 + size.Magnitude
				and math.abs(l.Z - self.centreZ) < self.spanZ * 0.5 + size.Magnitude then
				local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
				local xv, yv = rel.XVector, rel.YVector
				local zv = rel.ZVector

				-- half-extent of the oriented box along each of the slab's axes
				local ex = hx * math.abs(xv.X) + hy * math.abs(yv.X) + hz * math.abs(zv.X)
				local ez = hx * math.abs(xv.Z) + hy * math.abs(yv.Z) + hz * math.abs(zv.Z)

				local fx0, fy0 = grid:WorldToCell(l.X - ex, l.Z - ez)
				local fx1, fy1 = grid:WorldToCell(l.X + ex, l.Z + ez)
				local x0 = math.max(0, math.floor(fx0))
				local y0 = math.max(0, math.floor(fy0))
				local x1 = math.min(W - 1, math.ceil(fx1))
				local y1 = math.min(grid.H - 1, math.ceil(fy1))

				local cx = -(l.X * xv.X + l.Y * xv.Y + l.Z * xv.Z)
				local cz = -(l.X * zv.X + l.Y * zv.Y + l.Z * zv.Z)
				local xvX, xvZ = xv.X, xv.Z
				local zvX, zvZ = zv.X, zv.Z

				for y = y0, y1 do
					local rowBase = y * W
					local lz = oz + (y + 0.5) * cell
					local xBase = cx + lz * xvZ
					local zBase = cz + lz * zvZ
					for x = x0, x1 do
						local i = rowBase + x
						-- on the slab, and not already marked by an overlapping strip --
						-- the paint bit is the double-count guard the mask write used to be
						if buffer.readu8(mask, i) == 1 and buffer.readu8(paint, i) == 0 then
							local lx = ox + (x + 0.5) * cell
							local oX = xBase + lx * xvX
							if oX <= hx and oX >= -hx then
								local oZ = zBase + lx * zvX
								if oZ <= hz and oZ >= -hz then
									buffer.writeu8(paint, i, 1)
									cleared += 1
								end
							end
						end
					end
				end
			end
		end
	end
	return cleared
end

function DrivewaySurface:_buildMask()
	local grid = self.grid
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	-- The edging counts as slab: these are the cells the whole footprint grew to
	-- take in, and without them here the grid would cover the kerb but the mask
	-- would still stop at the asphalt.
	local ground = { self.slab :: Instance }
	for _, p in ipairs(self.edgeParts) do ground[#ground + 1] = p end
	params.FilterDescendantsInstances = ground
	params.IgnoreWater = true

	local down = self.topCF.UpVector * -6
	local lift = self.topCF.UpVector * 3

	local blockers = self:_findBlockers()
	-- Split by whether a ray can see them at all: CanQuery = false answers no
	-- raycast, so those are stamped geometrically instead. See _stencilBlockers.
	local rayable, stencilled = {}, {}
	for _, p in ipairs(blockers) do
		if p.CanQuery then rayable[#rayable + 1] = p else stencilled[#stencilled + 1] = p end
	end
	local blockParams: RaycastParams? = nil
	local blockLift, blockDown
	if #rayable > 0 then
		blockParams = RaycastParams.new()
		;(blockParams :: RaycastParams).FilterType = Enum.RaycastFilterType.Include
		;(blockParams :: RaycastParams).FilterDescendantsInstances = rayable
		;(blockParams :: RaycastParams).IgnoreWater = true
		blockLift = self.topCF.UpVector * BLOCK_CLEAR

		blockDown = self.topCF.UpVector * -(BLOCK_CLEAR + 0.15)
	end

	task.spawn(function()
		-- The static micro-relief, off the frame. It is eight noise calls a cell and
		-- was measured at 61 ms on a Megamart lot, synchronously inside the Heartbeat
		-- that built the surface; here it hides inside a sweep that was going to take
		-- a second anyway. Nothing paints before `ready` below.
		self.renderer:Prepare()

		local count = 0
		local blocked = 0
		local budget = 0
		for y = 0, grid.H - 1 do
			for x = 0, grid.W - 1 do
				local lx, lz = grid:CellToWorld(x, y)
				local at = self.topCF:PointToWorldSpace(Vector3.new(lx, 0, lz))
				if workspace:Raycast(at + lift, down, params) then
					if blockParams and workspace:Raycast(at + blockLift, blockDown, blockParams) then
						blocked += 1
					else
						buffer.writeu8(grid.mask, y * grid.W + x, 1)
						count += 1
					end
				end
			end
			-- two rays a cell once anything is standing on this slab, so the
			-- per-frame cost of the sweep stays where it was tuned
			budget += if blockParams then grid.W * 2 else grid.W
			if budget >= 2500 then
				budget = 0
				RunService.Heartbeat:Wait()
			end
		end
		-- Paint is marked after the sweep and before the counts are published, so
		-- coverage is measured against the ground that is actually the job. The
		-- mask keeps every cell the rays found -- marking included -- because that
		-- is the footprint the solver and the sheet work over; only the denominator
		-- nets the paint off. See the note on _stencilPaint.
		-- The ones no ray could see, taken out before the counts are published and
		-- before the paint stencil, which only considers cells still in the mask.
		local stencilBlocked = self:_stencilBlockers(stencilled)
		count -= stencilBlocked
		blocked += stencilBlocked

		local painted = self:_stencilPaint()
		grid.maskCount = count
		grid.paintCount = painted
		self.blockedCells = blocked
		self.paintedCells = painted

		-- Every surface starts on the cheap flat renderer. The client promotes
		-- whichever ones are nearest to the 3D sheet; see SetDetail.
		if Config.Use3DLiquid then
			self:_buildFlatOverlay()
		end

		self.ready = true
		-- A repaint, not a solve: the grid is empty, so waking the solver would only
		-- buy SleepDelay's worth of full-grid steps over a dead field. See
		-- SurfaceGrid.MarkAllDirty.
		grid:MarkAllDirty()
	end)
end

function DrivewaySurface:SetDetail(level: number): boolean
	if not self.ready or self._busy then return false end
	if level == self.detail then return true end

	if level == Detail.Sheet then

		if self._meshRetryAt and os.clock() < self._meshRetryAt then return false end

		self._busy = true
		local built, mesh = pcall(function()
			return LiquidMesh.new(self.grid, self.image, self.topCF, self.visuals)
		end)
		self._busy = false
		if built and mesh then
			self.mesh = mesh
			self.overlay, self.decal = nil, nil
			self:_keepOnly(mesh.part)   -- the sheet and the decal would z-fight

			mesh.part.Transparency = 1
			self.renderer.opaque = true
			self.renderer:Paint(0, 0, self.grid.W - 1, self.grid.H - 1)

			mesh:Deform(0, 0, self.grid.W - 1, self.grid.H - 1)
			mesh.part.Transparency = 0
			self._meshBackoff, self._meshRetryAt = nil, nil
			self.detail = Detail.Sheet
			return true
		else
			if not self._meshWarned then
				self._meshWarned = true
				-- Two very different causes land here and the fix for each is the
				-- opposite of the other, so say which one it was. Running out of
				-- EditableMesh budget is the one that shows up as you add slabs to a
				-- world: every earlier driveway keeps its mesh alive for deformation,
				-- so the Nth one is the first to fail while the rest look fine.
				local reason = tostring(mesh)
				if reason:find("budget") or reason:find("AddVertex") or reason:find("nil") then
					warn(("[DrivewaySealer] %s stayed on the flat surface: the editable"
						.. " budget is full.\n  Lower MESH_BUDGET in DrivewayClient or raise"
						.. " Config.MeshStep (currently %d).\n  (%s)")
						:format(self.name, Config.MeshStep, reason))
				else
					warn("[DrivewaySealer] 3D sealer mesh unavailable, falling back to the" ..
						" flat surface.\n  Enable File > Game Settings > Security >" ..
						" \"Allow Mesh & Image APIs\" for the 3D version.\n  (" ..
						reason .. ")")
				end
			end
			-- Doubling from 5 s to a 60 s ceiling: fast enough that a slab which failed
			-- only because the budget was momentarily full still promotes while the
			-- player is standing on it, slow enough that a permanently refused one costs
			-- one attempt a minute instead of eight a second.
			local backoff = math.min((self._meshBackoff or 2.5) * 2, 60)
			self._meshBackoff = backoff
			self._meshRetryAt = os.clock() + backoff

			-- A refused promotion must still leave something drawing the slab. It
			-- always did when the only other level was Flat; coming up from Bare it
			-- would otherwise strand a driveway with no visual at all.
			if self.detail == Detail.Bare then
				self:_buildFlatOverlay()
				self.grid:MarkAllDirty()
			end
			return false
		end
	else
		if self.mesh then
			self.mesh:Destroy()   -- returns this slab's share of the editable budget
			self.mesh = nil
		end
		if level == Detail.Flat then
			self:_buildFlatOverlay()
		else
			self:_keepOnly(nil)   -- takes the overlay, the decal and anything stale
			self.overlay, self.decal = nil, nil
			self.detail = Detail.Bare
		end
	end

	if self.detail ~= Detail.Bare then
		self.grid:MarkAllDirty()
	end
	return true
end

--==[ TRANSFORMS ]============================================================

function DrivewaySurface:ToLocal(p: Vector3): (number, number)
	local l = self.topCF:PointToObjectSpace(p)
	return l.X, l.Z
end

function DrivewaySurface:DirToLocal(v: Vector3): (number, number)
	local l = self.topCF:VectorToObjectSpace(v)
	local len = math.sqrt(l.X * l.X + l.Z * l.Z)
	if len < 1e-5 then return 0, 0 end
	return l.X / len, l.Z / len
end

function DrivewaySurface:Contains(p: Vector3): boolean
	local lx, lz = self:ToLocal(p)
	local grid = self.grid
	local cx, cy = grid:WorldToCell(lx, lz)
	cx, cy = math.round(cx), math.round(cy)
	if cx < 0 or cy < 0 or cx >= grid.W or cy >= grid.H then return false end
	return buffer.readu8(grid.mask, cy * grid.W + cx) == 1
end

function DrivewaySurface:LooseVolume(): (number, Vector3?)
	if not self.ready then return 0, nil end
	local total, lx, lz = self.grid:LooseVolume()
	if not lx or not lz then return total, nil end
	return total, self.topCF:PointToWorldSpace(Vector3.new(lx, 0, lz))
end

-- Nearest point on the slab surface, used to keep the pour stream and the
-- squeegee glued to the driveway plane.
function DrivewaySurface:SurfacePoint(p: Vector3): Vector3
	local l = self.topCF:PointToObjectSpace(p)
	return self.topCF:PointToWorldSpace(Vector3.new(l.X, 0, l.Z))
end

--==[ TOOL ACTIONS ]==========================================================

function DrivewaySurface:Pour(worldPos: Vector3, amount: number, radius: number?): number
	if not self.ready then return 0 end
	local lx, lz = self:ToLocal(worldPos)
	return self.grid:Pour(lx, lz, amount, radius)
end

function DrivewaySurface:Squeegee(
	worldCenter: Vector3, bladeAxis: Vector3, pushDir: Vector3,
	travel: number, speed: number, dt: number, strength: number,
	-- half-width and reservoir of the blade doing the sweeping; nil is the hand
	-- squeegee. See the note on SurfaceGrid:Squeegee.
	wide: number?, holds: number?
)
	if not self.ready then return nil end
	local cx, cz = self:ToLocal(worldCenter)
	local ax, az = self:DirToLocal(bladeAxis)
	local px, pz = self:DirToLocal(pushDir)
	if px == 0 and pz == 0 then return nil end
	return self.grid:Squeegee(cx, cz, ax, az, px, pz, travel, speed, dt, strength, wide, holds)
end

--==[ TICK ]==================================================================

function DrivewaySurface:Step(dt: number, maxCatchUp: number?, longStep: boolean?): number
	if not self.ready then return 0 end
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
			sealedNew += (self.grid:Step(step) or 0)
		end
		-- Carry a part-step forward; drop anything left after the cap, or a client
		-- that cannot keep up would accumulate an interval it never works off.
		self._accum = if want < fixed then want else 0
		return sealedNew
	end

	self._accum = math.min(self._accum + dt, fixed * (maxCatchUp or Config.MaxCatchUp))
	local sealedNew = 0
	while self._accum >= fixed do
		self._accum -= fixed
		sealedNew += (self.grid:Step(fixed) or 0)
	end
	return sealedNew
end

function DrivewaySurface:Render(maxCells: number?): number
	if not self.ready then return 0 end
	-- Nothing of ours is on screen at Bare, so a repaint is work no one can see.
	-- Leaving the flags set is deliberate: SetDetail's MarkAllDirty catches the
	-- whole grid up on the way back out.
	if self.detail == Detail.Bare then return 0 end
	local n, rects = self.grid:DirtyRegions(maxCells)
	if n == 0 then return 0 end

	local mesh = self.mesh
	if mesh then mesh.deformGeneration += 1 end
	local painted = 0
	for r = 1, n do
		local q = rects[r]
		local x0, y0, x1, y1 = q[1], q[2], q[3], q[4]
		painted += self.renderer:Paint(x0, y0, x1, y1)
		if mesh then
			mesh:Deform(x0, y0, x1, y1, mesh.deformGeneration)
		end
	end
	return painted
end

function DrivewaySurface:DirtyCells(): number
	if not self.ready or self.detail == Detail.Bare then return 0 end
	return self.grid:DirtyCells()
end

function DrivewaySurface:Coverage(): number
	return self.grid:Coverage()
end

function DrivewaySurface:MissedSpots(maxSpots: number?, near: Vector3?)
	if not self.ready then return {} end
	local nx, nz
	if near then nx, nz = self:ToLocal(near) end
	local out = {}
	for _, p in ipairs(self.grid:MissedPatches(maxSpots, nx, nz)) do
		out[#out + 1] = {
			-- carried through so a marker can stay on its own patch; see MissedPatches
			id = p.id,
			pos = self.topCF:PointToWorldSpace(Vector3.new(p.x, 0, p.z)),
			up = self.topCF.UpVector,
			cf = self.topCF,
			area = p.area,
			w = p.w,
			h = p.h,
		}
	end
	return out
end

function DrivewaySurface:Reset()
	self.grid:Reset()
end

-- Straight to finished. Only the rebirth-lap restore uses this -- see the note on
-- SurfaceGrid:FillSealed -- and it is a no-op before the mask sweep has run,
-- because there is nothing yet to say which cells are on the slab.
function DrivewaySurface:FillSealed()
	if not self.ready then return end
	self.grid:FillSealed()
	-- The same end state Settle arrives at, so it counts as settled: a restored
	-- slab has no loose sealer on it and nothing left to simulate.
	self.settled = true
end

function DrivewaySurface:Settle(): boolean
	if not self.ready or self.settled then return false end
	self.settled = true
	self.grid:FillSealed()
	return true
end

function DrivewaySurface:SetEasyFlow(on: boolean)
	self.grid.easyFlow = on and true or false
end

function DrivewaySurface:Destroy()
	if self.mesh then self.mesh:Destroy() end
	self.visuals:Destroy()
	self.overlay, self.decal = nil, nil
	self.image:Destroy()
end

function DrivewaySurface:HasMesh(): boolean
	return self.mesh ~= nil
end

return DrivewaySurface
