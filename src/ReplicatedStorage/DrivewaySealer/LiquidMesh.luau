--!native
--!optimize 2
--[[
	LiquidMesh -- gives the sealer real thickness.

	A displaced EditableMesh laid over the slab, one vertex every MeshStep cells,
	textured with the very same EditableImage the flat renderer produces. So the
	shading, the alpha cutout and the coverage mask all still come from the
	texture; the mesh only adds height.

	Geometry is emitted only over cells that are actually on the driveway, so the
	sheet never hangs over the lawn, and the texture's alpha handles the fine
	edge inside that.

	Two things about MeshParts that shape this file:
	  * a deformed EditableMesh renders in true units -- it is NOT rescaled to
	    MeshPart.Size -- but Size is frozen at creation, so the build bakes in
	    full height headroom or the part gets culled when a bead rises.
	  * CreateMeshPartAsync centres the part on the mesh bounding box, so the
	    offset back onto the slab is computed from the emitted bounds.
]]

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local Config = require(script.Parent.Config)

local LiquidMesh = {}
LiquidMesh.__index = LiquidMesh

function LiquidMesh.new(grid, image, topCF: CFrame, parent: Instance)
	local step = Config.MeshStep
	local W, H, cell = grid.W, grid.H, grid.cellSize
	--[[
		Ceil, not floor: the last vertex has to reach the grid's final cell.

		With floor, the vertex grid stops at the last whole MeshStep and every cell
		past it is outside the sheet -- not merely coarse, absent, with no geometry
		over it at all. So a slab could report 100% coverage with every mask cell
		sealed and still wear a bare rim, because the thing carrying the colour did
		not extend that far.

		How wide that rim was came down to a modulo, which is why it differed per slab
		and looked arbitrary. Measured on a 382 x 225 grid at step 5: (382-1) % 5 = 1
		cell strapped in X, (225-1) % 5 = 4 cells in Z -- so the sheet came out
		60.80 x 35.20 over a 61.00 x 36.00 driveway, four fifths of a stud short down
		the long sides.

		Ceil adds one row and one column of vertices. The final quad is narrower than
		the rest -- it spans only the remainder -- which costs nothing: vertexAt
		already clamps the cell it samples to W-1 / H-1, and CellToWorld puts the
		vertex at that cell's true centre either way.

		The flat overlay never had this. It is built at the full grid span, which is
		why the rim only ever showed on the promoted slab -- the one underfoot.
	]]
	local MW = math.ceil((W - 1) / step) + 1
	local MH = math.ceil((H - 1) / step) + 1
	local maxH = Config.LiquidMaxHeight

	local em = AssetService:CreateEditableMesh()
	local vid = table.create(MW * MH, 0)   -- mesh grid index -> vertex id (0 = absent)
	local uvid = table.create(MW * MH, 0)
	local vx = table.create(MW * MH, 0)    -- cached X/Z so updates only write Y
	local vz = table.create(MW * MH, 0)

	local flipX, flipY = Config.TexFlipX, Config.TexFlipY
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	local function vertexAt(mx: number, my: number): number
		local k = my * MW + mx + 1
		local existing = vid[k]
		if existing ~= 0 then return existing end

		local cx = math.min(W - 1, mx * step)
		local cy = math.min(H - 1, my * step)
		local lx, lz = grid:CellToWorld(cx, cy)
		local id = em:AddVertex(Vector3.new(lx, 0, lz))
		vid[k] = id
		vx[k] = lx
		vz[k] = lz
		if lx < minX then minX = lx end
		if lx > maxX then maxX = lx end
		if lz < minZ then minZ = lz end
		if lz > maxZ then maxZ = lz end

		-- UVs follow the texture flips so the mesh samples the same image the
		-- flat decal path would have
		local u = (cx + 0.5) / W
		local v = (cy + 0.5) / H
		if flipX then u = 1 - u end
		if flipY then v = 1 - v end
		uvid[k] = em:AddUV(Vector2.new(u, v))
		return id
	end

	local mask = grid.mask
	local function quadHasSlab(mx: number, my: number): boolean
		local x0, y0 = mx * step, my * step
		for y = y0, math.min(H - 1, y0 + step) do
			for x = x0, math.min(W - 1, x0 + step) do
				if buffer.readu8(mask, y * W + x) == 1 then return true end
			end
		end
		return false
	end

	--[[
		The emit loop yields, and it is safe here specifically.

		AddVertex/AddTriangle/SetFaceUVs over a whole sheet measured 18 ms average and
		25 ms worst on the big lots -- a dropped frame every time the level-of-detail
		pass promoted a slab, which is every time the player walks along a row of
		driveways. CreateMeshPartAsync below already yields, so every caller is
		already on a coroutine that tolerates it: DrivewayClient's detail pass is a
		task.spawn loop and the AFK yard promotes from a task.delay. DrivewaySurface
		holds `_busy` across the whole call, so a later pass cannot start a second
		sheet for this slab while this one is mid-yield.

		The mask this reads is fixed once the surface is ready, so pausing partway
		through cannot emit geometry against a footprint that has moved under it.
	]]
	local tris = 0
	-- Budgeted in mesh-grid columns rather than rows, for the same reason the relief
	-- loop is: these sheets are anywhere from 10 to 205 vertices wide. 900 is about
	-- 3 ms of vertex and face emission.
	local budget = 0
	for my = 0, MH - 2 do
		budget += MW
		if budget >= 900 then
			budget = 0
			RunService.Heartbeat:Wait()
		end
		for mx = 0, MW - 2 do
			if not quadHasSlab(mx, my) then continue end
			local ka = my * MW + mx + 1
			local kb = my * MW + mx + 2
			local kc = (my + 1) * MW + mx + 2
			local kd = (my + 1) * MW + mx + 1
			local a, b = vertexAt(mx, my), vertexAt(mx + 1, my)
			local c, d = vertexAt(mx + 1, my + 1), vertexAt(mx, my + 1)
			-- wound a-c-b / a-d-c so the face normals point up; the obvious
			-- a-b-c ordering builds the sheet inside-out and it vanishes to
			-- backface culling
			local f1 = em:AddTriangle(a, c, b)
			local f2 = em:AddTriangle(a, d, c)
			em:SetFaceUVs(f1, { uvid[ka], uvid[kc], uvid[kb] })
			em:SetFaceUVs(f2, { uvid[ka], uvid[kd], uvid[kc] })
			tris += 2
		end
	end

	--[[
		Every failure path from here down has to hand the EditableMesh back.

		`em` is created before anything can go wrong, and Destroy's note below says
		why walking away from it is the expensive half: the live EditableMesh is what
		holds the experience-wide editable budget, not the MeshPart. Leaking one is
		not a one-off either -- self.detail stays Flat on failure and updateDetail
		re-attempts the promotion for the nearest MESH_BUDGET slabs twice a second
		for the rest of the session, so a slab that always fails leaks at up to 8/s
		until the budget is gone and CreateEditableImage starts failing too, at which
		point DrivewaySurface.new returns nil and the slab cannot be sealed at all.
	]]
	if tris == 0 then
		em:Destroy()
		return nil
	end

	-- Bake the full height range into the bounding box before the part is made:
	-- Size is frozen at creation, and anything outside it gets culled.
	local sink = Config.MeshSink
	local a1, a2 = nil, nil
	for k = 1, MW * MH do
		if vid[k] ~= 0 then
			if not a1 then a1 = k elseif not a2 then a2 = k; break end
		end
	end
	-- tris > 0 guarantees four vertices were emitted, but the scan above is the only
	-- thing that says so and a nil index here would throw inside DrivewaySurface's
	-- pcall -- which unwinds past every reference to `em` and leaks it silently.
	if not a1 or not a2 then
		em:Destroy()
		return nil
	end

	-- CreateMeshPartAsync is the realistic thrower: it is what fails when the
	-- editable budget is full. Caught here rather than left to DrivewaySurface's
	-- pcall so `em` is still in scope to be released.
	local built, part = pcall(function()
		em:SetPosition(vid[a1], Vector3.new(vx[a1], maxH, vz[a1]))
		em:SetPosition(vid[a2], Vector3.new(vx[a2], -sink, vz[a2]))
		local p = AssetService:CreateMeshPartAsync(Content.fromObject(em), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
		})
		em:SetPosition(vid[a1], Vector3.new(vx[a1], -sink, vz[a1]))
		em:SetPosition(vid[a2], Vector3.new(vx[a2], -sink, vz[a2]))
		return p
	end)
	if not built or not part then
		em:Destroy()
		return nil
	end

	part.Name = "SealerLiquidMesh"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	-- Engine-side gloss, because the renderer's own highlight terms are authored
	-- to zero for performance. See Config.SheetGloss.
	part.Reflectance = Config.SheetGloss
	part.Color = Color3.new(1, 1, 1)
	part.TextureContent = Content.fromObject(image)
	-- mesh y=0 has to land on the slab; the part is centred on its own bounds,
	-- which now run from -sink to maxH
	part.CFrame = topCF * CFrame.new((minX + maxX) * 0.5, (maxH - sink) * 0.5, (minZ + maxZ) * 0.5)
	part.Parent = parent

	return setmetatable({
		grid = grid, em = em, part = part,
		MW = MW, MH = MH, step = step,
		vid = vid, vx = vx, vz = vz,
		triangles = tris,
		deformGeneration = 0,
		deformVisited = table.create(MW * MH, 0),
		vertexHeights = table.create(MW * MH),
	}, LiquidMesh)
end

-- Raise the vertices covering one cell rect. Called with the same rect the
-- texture repaint uses, so height and shading never disagree.
function LiquidMesh:Deform(x0: number, y0: number, x1: number, y1: number, generation: number?): number
	local grid = self.grid
	local step, MW, MH = self.step, self.MW, self.MH
	local vid, vx, vz = self.vid, self.vx, self.vz
	local em = self.em
	local liq, film, mask, sealedB = grid.liquid, grid.film, grid.mask, grid.sealed
	-- The same floor the texture applies, so the sheet keeps breaking the surface
	-- wherever the texture is still drawing sealer. Without it a wetted cell would
	-- draw black on a sheet that had sunk back into the slab underneath it.
	local stainB = grid.stain
	local useStain = Config.WetOutSeal > 0
	local W, H = grid.W, grid.H
	local scale, maxH = Config.LiquidHeight, Config.LiquidMaxHeight
	-- Sealer past what a cell still wants is priced separately; see the two-slope
	-- block below and Config.LiquidHeightExtra.
	local extraScale, coat = Config.LiquidHeightExtra, Config.CoatDepth
	local sink, emerge = Config.MeshSink, Config.MeshEmerge
	-- what is left above the emerge plane for thickness to use
	local headroom = maxH - emerge
	local invEdge = 1 / Config.EdgeAlphaDepth
	-- Cured coat is scaled separately from loose sealer; see Config.MeshSealShow.
	local invSeal = 1 / math.max(Config.MeshSealShow or 1, 1e-3)

	local mx0 = math.max(0, (x0 // step) - 1)
	local my0 = math.max(0, (y0 // step) - 1)
	local mx1 = math.min(MW - 1, (x1 // step) + 1)
	local my1 = math.min(MH - 1, (y1 // step) + 1)
	local moved = 0

	for my = my0, my1 do
		for mx = mx0, mx1 do
			local k = my * MW + mx + 1
			local id = vid[k]
			if id == 0 then continue end
			-- Dirty rectangles overlap; sample each vertex only once per render batch.
			if generation then
				if self.deformVisited[k] == generation then continue end
				self.deformVisited[k] = generation
			end

			-- Average a block one cell wider than the vertex's own, so adjacent
			-- vertices share samples. Without the overlap a pool rim thinner
			-- than one mesh step lands on alternating vertices and the skirt
			-- saw-tooths into dark streaks down the sink slope.
			local cx0 = math.max(0, mx * step - 1)
			local cy0 = math.max(0, my * step - 1)
			-- filmSum and curedSum are the two the thickness split needs: how much of
			-- the depth is coat the blade laid, and how much of the ground is already
			-- finished. curedSum is the RAW seal -- stain is a shading floor on cells
			-- loose sealer merely washed over, and wetted ground still wants its coat.
			local depthSum, filmSum, sealSum, curedSum, n = 0, 0, 0, 0, 0
			for cy = cy0, math.min(H - 1, my * step + step) do
				local row = cy * W
				for cx = cx0, math.min(W - 1, mx * step + step) do
					local i = row + cx
					if buffer.readu8(mask, i) == 1 then
						local i4 = i * 4
						local fm = buffer.readf32(film, i4)
						filmSum += fm
						depthSum += buffer.readf32(liq, i4) + fm
						local sv = buffer.readf32(sealedB, i4)
						curedSum += sv
						if useStain then
							local st = buffer.readf32(stainB, i4)
							if st > sv then sv = st end
						end
						sealSum += sv
					end
					n += 1
				end
			end

			local h = -sink
			if n > 0 then
				local d = depthSum / n
				local s = sealSum / n
				local laid = filmSum / n
				local cured = curedSum / n
				-- Same presence curve the texture uses for alpha, so the sheet
				-- breaks the surface exactly where the sealer starts.
				local la = d * invEdge
				if la > 1 then la = 1 end
				la = la * la * (3 - 2 * la)
				-- Cured coat reaches full presence far sooner than loose sealer does;
				-- see Config.MeshSealShow for why the two are scaled differently.
				local st = s * invSeal
				if st > 1 then st = 1 end
				local sa = st * st * (3 - 2 * st)
				local presence = if la > sa then la else sa

				--[[
					Thickness is TWO saturating slopes, and the kink at the wanted coat is
					the whole point of it.

					One rate could not do both jobs. A finished coat is deliberately
					squashed to a sheen -- 0.024 studs at CoatDepth, see Config.LiquidHeight
					-- because a taller one reads as a separate black slab laid on the
					concrete with a lip all the way round. But that same gentle rate is what
					made EXTRA sealer invisible: sealer standing on ground that is already
					sealed drew 0.034 studs against the finished coat's 0.010 beside it, and
					a fortieth of a stud of relief on a surface with every lighting term
					authored to zero is not a bulge, it is flat. There was no telling a
					doubled-up patch from a clean one.

					So the gentle rate is spent only on the coat this ground still WANTS,
					and everything past that is charged at extraScale, three times steeper.
					Over sealed ground the allowance is zero, so the first extra coat is
					already on the steep curve at 0.077 studs proud against 0.010 around it
					-- a ridge with a flank, which is also the only thing the grazing sheen
					term has left to catch.

					`want` is floored at the film already laid, or a normal pass would swell
					on its way to cured and then drop again. Seal reaches 1 after only 0.59
					coats of film have been drunk (SealPerPass / SealDepth is 1.69), leaving
					0.41 still setting: against a bare 1 - sealed allowance that tail counts
					as extra, and every strip the player finished would rise behind them.

					Measured, studs proud of the slab (emerge + thickness):

					                on bare ground   on sealed ground
					  1 coat          0.0340           0.0766
					  2 coats         0.1000           0.1289
					  4 coats         0.1898           0.2022
					  10 coats        0.2930             --

					Both halves saturate rather than clamp, for the reason the single curve
					did: d * scale ran out of headroom at 3.8 coats and a real pour is many
					times that, so every pour deep enough to matter pinned every vertex
					under it at exactly maxH -- a dumped bucket came out a flat-topped mesa
					with a vertical wall around it instead of a pool, the entire interior at
					the SAME height with the transition to nothing over one mesh step. Each
					half approaches its own ceiling without reaching it, so depth keeps
					reading as depth all the way up and the clamp below stays a guard rather
					than the normal case.
				]]
				local want = coat * (1 - cured)
				if laid > want then want = laid end
				local flat = if d < want then d else want
				local thick = headroom * (1 - math.exp(-flat * scale / headroom))
				local extra = d - flat
				if extra > 0 then
					-- what the gentle half did not spend; strictly positive, since the
					-- curve above only ever approaches headroom
					local room = headroom - thick
					thick += room * (1 - math.exp(-extra * extraScale / room))
				end
				h = -sink + presence * (sink + emerge) + thick
				if h > maxH then h = maxH end
			end
			-- Avoid invalidating the mesh for sub-millistud height changes.
			local previous = self.vertexHeights[k]
			if previous == nil or math.abs(previous - h) >= 0.001 then
				em:SetPosition(id, Vector3.new(vx[k], h, vz[k]))
				self.vertexHeights[k] = h
				moved += 1
			end
		end
	end
	return moved
end

function LiquidMesh:Destroy()
	self.part:Destroy()
	--[[
		The EditableMesh has to go too, and it is the important half.

		What holds the experience-wide editable budget is the live EditableMesh,
		not the MeshPart built from it -- destroying only the part frees nothing.
		Leave these referenced and the budget is never returned, so once enough
		slabs exist every later one silently falls back to the flat surface.
	]]
	if self.em then
		self.em:Destroy()
		self.em = nil
	end
end

return LiquidMesh
