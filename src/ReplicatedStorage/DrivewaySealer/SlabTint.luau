--!strict
--[[
	SlabTint -- what colour a driveway's own PART wears while it is sealed.

	The sealer only ever exists inside an EditableImage, and that image only
	exists once the slab's surface has been BUILT -- which happens on approach,
	one slab at a time, inside DrivewayClient's BUILD_RADIUS. Everything past it
	is the bare part, and the bare part was concrete grey whether or not this
	player had finished it.

	So a driveway finished before the last rejoin sat grey from across the
	neighbourhood and snapped to black the moment the build queue reached it. It
	read as an image popping in rather than as a driveway, which is exactly what
	it was.

	The part underneath carries the finished LOOK itself now -- colour and material
	both. The sheet that eventually lands on top paints almost precisely this value
	-- see curedColor, which measures it off the real renderer rather than guessing
	-- so by the time the image arrives there is nothing left to see.

	That equivalence is now load-bearing rather than merely tidy: DrivewaySurface's
	Bare detail level drops the overlay off a finished driveway outright and leaves
	this colour as the only thing drawing it. Captured both ways at 85 studs on
	Lot_110 and the two frames are indistinguishable, which is what makes the swap
	safe -- a fully sealed slab paints as flat black with no detail in it at all
	(every light-response term in Config is zero, so the micro-relief and the
	cracks under the coat have nothing to catch).

	Client-side and per player, like everything else about sealing: this is the
	local player's own progress drawn on their own copy of the world, and the
	server neither sends it nor sees it.

	The original colour is REMEMBERED rather than recomputed, for two reasons that
	both bite:

	  * a rebirth hands every driveway back, and the slabs are not all the same
	    colour to begin with -- the road and the turning bulb are asphalt;
	  * SurfaceRenderer composites its bare-concrete term in the SLAB's colour.
	    Reading that off a slab that is currently wearing the sealed colour would
	    make the canvas black -- and a rebirth empties the grid without rebuilding
	    it, so the next lap would start with a bare driveway still rendering as
	    finished.
]]

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Config)
local Sections = require(script.Parent.Sections)
local SurfaceGrid = require(script.Parent.SurfaceGrid)
local SurfaceRenderer = require(script.Parent.SurfaceRenderer)

local SlabTint = {}

--==[ THE COLOUR ]============================================================

local MEASURED = Color3.new(0.0755, 0.0749, 0.0768)

local cured: Color3? = nil

local function measure(): Color3
	local N = 32
	local grid: any = SurfaceGrid.new(N, N, Config.CellSize, 0, 0)
	-- every cell on the slab, then every cell finished: FillSealed only writes
	-- where the mask says there is ground
	buffer.fill(grid.mask, 0, 1)
	grid.maskCount = grid.N
	grid:FillSealed()

	local image = AssetService:CreateEditableImage({ Size = Vector2.new(N, N) })
	local renderer: any = SurfaceRenderer.new(grid, image, MEASURED)
	-- Pure sealer, nothing composited under it. With every cell finished the two
	-- come out identical anyway -- a fully sealed texel is opaque -- but this way
	-- the answer cannot quietly depend on whatever was handed in as the canvas.
	renderer.opaque = false
	renderer:Paint(0, 0, N - 1, N - 1)

	local px = image:ReadPixelsBuffer(Vector2.zero, Vector2.new(N, N))
	image:Destroy()

	local r, g, b = 0, 0, 0
	for i = 0, N * N - 1 do
		r += buffer.readu8(px, i * 4)
		g += buffer.readu8(px, i * 4 + 1)
		b += buffer.readu8(px, i * 4 + 2)
	end
	local inv = 1 / (N * N * 255)
	return Color3.new(r * inv, g * inv, b * inv)
end

function SlabTint.curedColor(): Color3
	if not cured then
		local ok, c = pcall(measure)
		cured = if ok and typeof(c) == "Color3" then c else MEASURED
	end
	return cured :: Color3
end

--==[ THE SLABS ]=============================================================

local SEALED_MATERIAL = Enum.Material.SmoothPlastic

-- Weak keys: the retail park builds its lot at runtime, and a slab that has
-- been destroyed must not be kept alive by a look remembered for it.
type Worn = { color: Color3, material: Enum.Material }
local remembered: { [BasePart]: Worn } = setmetatable({}, { __mode = "k" }) :: any

function SlabTint.baseColorOf(slab: BasePart): Color3
	local was = remembered[slab]
	return if was then was.color else slab.Color
end

function SlabTint.isSealed(slab: BasePart): boolean
	return remembered[slab] ~= nil
end

function SlabTint.set(slab: BasePart, sealed: boolean)
	if sealed then
		if remembered[slab] == nil then
			remembered[slab] = { color = slab.Color, material = slab.Material }
		end
		slab.Color = SlabTint.curedColor()
		slab.Material = SEALED_MATERIAL
	else
		local was = remembered[slab]
		if was then
			slab.Color = was.color
			slab.Material = was.material
			remembered[slab] = nil
		end
	end
end

function SlabTint.refresh(plr: Player)
	local now = Sections.nowSetOf(plr)
	for _, slab in ipairs(CollectionService:GetTagged(Sections.Tag)) do
		if slab:IsA("BasePart") then
			SlabTint.set(slab :: BasePart, now[Sections.keyOf(slab)] == true)
		end
	end
end

local bound = false

function SlabTint.bind(plr: Player)
	if bound then return end
	bound = true

	SlabTint.refresh(plr)
	plr:GetAttributeChangedSignal(Sections.NowAttr):Connect(function()
		SlabTint.refresh(plr)
	end)

	CollectionService:GetInstanceAddedSignal(Sections.Tag):Connect(function(slab)
		-- Deferred, because the key a slab is recorded under is its full path and a
		-- slab tagged while it is being built can still be on its way to its final
		-- parent. Asking early gets a key that matches nothing.
		task.defer(function()
			if slab:IsA("BasePart") and slab:IsDescendantOf(workspace) then
				local now = Sections.nowSetOf(plr)
				SlabTint.set(slab :: BasePart, now[Sections.keyOf(slab)] == true)
			end
		end)
	end)
end

return SlabTint
