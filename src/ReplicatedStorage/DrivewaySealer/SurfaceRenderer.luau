--!native
--!optimize 2
--[[
	SurfaceRenderer -- paints a SurfaceGrid into an EditableImage.

	One pixel per simulation cell. The GPU's bilinear filter does the smoothing
	for free, which is why puddles come out with soft rounded edges instead of
	staircase voxels, and why a squeegee stroke still ends in a clean line.

	Shading is baked here rather than left to the engine: we build a normal from
	the sealer's own depth gradient plus the ripple field, then run a fixed
	sun/eye highlight over it. That is what reads as "thick and wet" -- a flat
	black decal never will, no matter how dark it is.
]]

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local SurfaceRenderer = {}
SurfaceRenderer.__index = SurfaceRenderer

--[[
	The static micro-relief, shared between surfaces of identical geometry.

	It is a pure function of (x, y, cellSize), it is never written again after it is
	built, and two grids of the same size and resolution therefore want the same
	three buffers byte for byte. They used to get their own copies, which cost both
	the memory and -- far worse -- the noise all over again: measured per slab, the
	first Megamart lot spent 60 ms in this loop and each of the five identical ones
	after it 25 ms, synchronously, inside DrivewaySurface.new. That is a visible
	hitch every time a player walks up to a new slab, and the six lots are all
	417x429 at 0.345 studs.

	Keyed on the three inputs rather than on the slab, so anything that happens to
	match shares -- the walkways come in matching pairs, and a slab rebuilt after
	being released pays nothing at all the second time.

	Bounded, and it has to be. The premise used to be that the number of distinct
	slab GEOMETRIES is small enough to just keep the lot -- but running the place's
	91 tagged slabs through DrivewaySurface.new's own cell-relaxation loop gives 44
	distinct ones, not the dozen-odd that reasoning assumed, and the full set is
	35.7 MB of client memory that is never handed back. It accrues as a session
	tours the districts, so the ceiling is reached by playing normally.

	The sharing that makes the cache worth having is real but concentrated: one
	318x327 geometry covers 18 slabs and one 96x705 covers 8, while 27 of the 44 are
	used by exactly ONE slab each. So the cache is an LRU with a small cap -- it
	keeps the geometries that actually repeat and lets the singletons fall out. A
	slab whose set was evicted pays the noise loop again on its next rebuild, which
	is the price it already paid the first time and no worse.

	Evicting is safe on top of that because a live surface holds its three buffers
	by reference (see SurfaceRenderer.new), so dropping the entry never pulls the
	relief out from under anything already drawing with it.
]]
-- 16 covers the 17 geometries that more than one slab shares, with the singletons
-- cycling through the remainder rather than piling up for the session.
local RELIEF_CACHE_MAX = 16
local reliefCache: { [string]: { mx: buffer, my: buffer, tint: buffer? } } = {}
-- Keys in use order, least-recently-used FIRST. A plain array is O(cap) to touch,
-- and at this cap against once-per-surface traffic that is nothing.
local reliefOrder: { string } = {}
-- Keys currently being filled, so two surfaces of matching geometry built at the
-- same time do not each grind out the same noise. See reliefFor's yield.
local reliefBuilding: { [string]: boolean } = {}

local function reliefKey(W: number, H: number, cellSize: number): string
	return ("%dx%d@%.6f"):format(W, H, cellSize)
end

-- Marks `key` as the most recently used. Every read of the cache goes through
-- this, not just the misses -- a geometry the player is standing among has to
-- keep its place in the order or the LRU ages out exactly the sets in use.
local function reliefTouch(key: string)
	for i = 1, #reliefOrder do
		if reliefOrder[i] == key then
			table.remove(reliefOrder, i)
			break
		end
	end
	table.insert(reliefOrder, key)
end

--[[
	`mayYield` is for the caller that can afford to wait, and the cache miss is the
	only thing it costs anything to be.

	The loop below is eight math.noise calls a cell, and the Megamart lots are
	178,893 cells: measured at 61 ms for the first one, in one frame, synchronously
	inside DrivewaySurface.new -- which runs from the client's Heartbeat. Four
	dropped frames every time the player walked up to a slab geometry nothing else
	had already paid for.

	Spreading it over Heartbeats costs nothing in practice because the surface is
	not drawn until its mask sweep finishes, and that sweep already yields for a
	second or more. So the caller that passes true here is the mask builder, and by
	the time `ready` goes up the relief is waiting.

	Paint still calls this without the flag, as a guard: a surface that somehow
	paints before its prepare has run builds the relief on the spot exactly as it
	used to, rather than reading a nil buffer.
]]
local function reliefFor(W: number, H: number, cellSize: number, mayYield: boolean?)
	local key = reliefKey(W, H, cellSize)
	local hit = reliefCache[key]
	if hit then
		reliefTouch(key)
		return hit
	end

	-- Somebody else is already grinding this exact geometry out and will publish it.
	-- Only worth waiting for if we are allowed to; a synchronous caller falls
	-- through and builds its own copy rather than blocking the frame.
	if reliefBuilding[key] and mayYield then
		repeat
			RunService.Heartbeat:Wait()
		until reliefCache[key] or not reliefBuilding[key]
		local late = reliefCache[key]
		if late then
			reliefTouch(key)
			return late
		end
	end

	if mayYield then reliefBuilding[key] = true end
	local n = W * H
	local mx, my = buffer.create(n * 4), buffer.create(n * 4)
	local amp = Config.MicroRelief
	local tintAmp = Config.ConcreteTint
	--[[
		ConcreteTint is authored to 0, and at zero amplitude every entry of the tint
		buffer is exactly 1.0 -- a constant that Paint multiplies the slab colour by,
		which is the identity. Same switch idiom as useStain/useRipple/useLobes down
		in Paint, pushed one step further: with it off we skip BUILDING the buffer,
		not merely reading it. That is a third of this cache -- 11.9 MB of the 35.7 MB
		measured above -- plus two math.noise calls a cell, spent on a term that cannot
		reach the picture. Author ConcreteTint non-zero again and the buffer and the
		per-texel read both come back exactly as they were.
	]]
	local useTint = tintAmp ~= 0
	local tintB: buffer? = if useTint then buffer.create(n * 4) else nil
	-- Noise is stepped per cell, but the frequencies are authored per stud, so
	-- they convert here. Left as raw per-cell constants the tooth grew with the
	-- grid: sharpening CellSize magnified the same blobs and the finish came out
	-- smoother the more resolution it was given, which is backwards.
	local fLo = Config.MicroFreqLow * cellSize
	local fHi = Config.MicroFreqHigh * cellSize
	local fTint = 0.41 * (cellSize / 0.21)
	-- Budgeted in CELLS, not rows: the slabs here run from 47 to 1024 cells wide,
	-- so a row budget would hand a 1024-wide apron twenty times the work per frame
	-- that it hands a walkway. 6,000 cells is about 2 ms of noise.
	local budget = 0
	for y = 0, H - 1 do
		if mayYield then
			budget += W
			if budget >= 6000 then
				budget = 0
				RunService.Heartbeat:Wait()
			end
		end
		for x = 0, W - 1 do
			local i4 = (y * W + x) * 4
			-- speckle for the composited bare concrete; without it the unsealed
			-- slab reads as a flat grey card. Gated on the buffer rather than on
			-- useTint directly -- same predicate, and it is what narrows the
			-- optional away for the type checker.
			if tintB then
				buffer.writef32(tintB, i4, 1
					+ math.noise(x * fTint, y * fTint, 31.7) * tintAmp
					+ math.noise(x * fTint * 3.2, y * fTint * 3.2, 43.1) * tintAmp * 0.5)
			end
			-- three octaves rather than two: the finer grid can now carry a tooth
			-- that used to fall below one texel and simply vanish
			buffer.writef32(mx, i4,
				(math.noise(x * fLo, y * fLo, 3.1) * 0.62
				+ math.noise(x * fHi, y * fHi, 7.7) * 0.26
				+ math.noise(x * fHi * 2.7, y * fHi * 2.7, 23.9) * 0.12) * amp)
			buffer.writef32(my, i4,
				(math.noise(x * fLo, y * fLo, 11.3) * 0.62
				+ math.noise(x * fHi, y * fHi, 19.5) * 0.26
				+ math.noise(x * fHi * 2.7, y * fHi * 2.7, 51.3) * 0.12) * amp)
		end
	end

	local set = { mx = mx, my = my, tint = tintB }
	reliefCache[key] = set
	reliefTouch(key)
	-- Past the cap, drop the coldest sets. Anything still on screen holds its own
	-- buffers by reference, so this only means that geometry grinds its noise out
	-- again the next time a slab of that exact size comes back into range.
	while #reliefOrder > RELIEF_CACHE_MAX do
		local coldest = reliefOrder[1]
		table.remove(reliefOrder, 1)
		reliefCache[coldest] = nil
	end
	reliefBuilding[key] = nil
	return set
end

--[[
	baseColor is the slab's own colour, and passing it in is what keeps the
	distance swap invisible.

	The flat overlay keeps real alpha, so at range the player is looking at the
	actual slab through it. The 3D sheet cannot -- MeshPart textures ignore alpha
	-- so it composites the sealer over an opaque concrete term and hides the slab
	entirely. While that term was a global constant, every slab whose colour was
	not that constant visibly changed shade the moment it promoted: the road, being
	asphalt, jumped from near-black to concrete grey as you walked up to it.
]]
function SurfaceRenderer.new(grid, image, baseColor: Color3?)
	local n = grid.N
	local cc = Config.ConcreteColor
	local base = baseColor or Color3.new(cc.X, cc.Y, cc.Z)
	-- Only taken here if some earlier slab of matching geometry already paid for
	-- it, which is free. A miss is left to Prepare, off the frame -- see reliefFor.
	local reliefK = reliefKey(grid.W, grid.H, grid.cellSize)
	local relief = reliefCache[reliefK]
	-- A hit counts as a use: it is what keeps a geometry the player is walking
	-- among from ageing out of the LRU behind their back.
	if relief then reliefTouch(reliefK) end
	local self = setmetatable({
		grid = grid,
		image = image,
		baseR = base.R, baseG = base.G, baseB = base.B,
		-- shared, and read-only from here on; see reliefFor
		microX = relief and relief.mx,
		microY = relief and relief.my,
		-- nil whenever ConcreteTint is 0, because the buffer is not built at all in
		-- that case -- so microX, not this, is what "the relief is ready" is tested
		-- on below. See reliefFor's useTint.
		tint = relief and relief.tint,
		-- set false if the 3D sheet could not be built, so the flat decal
		-- fallback goes back to real alpha instead of composited concrete
		opaque = Config.Use3DLiquid,
		-- WritePixelsBuffer demands a buffer of exactly rw*rh*4 bytes, so rects
		-- are snapped to chunk multiples and the handful of resulting sizes are
		-- cached instead of reallocated every frame
		_bufs = {},
		_bufCount = 0,
	}, SurfaceRenderer)

	-- Blinn half-vector, fixed. A camera-following highlight would make an
	-- otherwise uniform finished driveway shimmer unevenly as you walk.
	local hv = (Config.SunDirection + Config.EyeDirection).Unit
	self.hx, self.hy, self.hz = hv.X, hv.Y, hv.Z

	return self
end

--[[
	Build the micro-relief if this geometry is new, yielding as it goes.

	Called from the mask sweep, which already runs off the frame and holds `ready`
	down until it is done -- so this is invisible, and it is what keeps the 61 ms
	noise loop out of the Heartbeat that built the surface. Idempotent: a cache hit
	in the constructor makes it a no-op.
]]
function SurfaceRenderer:Prepare()
	-- microX, not tint: tint is nil whenever ConcreteTint is 0, so it can no longer
	-- stand for "the relief is built". mx/my are built unconditionally.
	if self.microX then return end
	local grid = self.grid
	local relief = reliefFor(grid.W, grid.H, grid.cellSize, true)
	self.microX, self.microY, self.tint = relief.mx, relief.my, relief.tint
end

function SurfaceRenderer:_buffer(bytes: number): buffer
	local b = self._bufs[bytes]
	if not b then
		if self._bufCount > 48 then
			self._bufs = {}
			self._bufCount = 0
		end
		b = buffer.create(bytes)
		self._bufs[bytes] = b
		self._bufCount += 1
	end
	return b
end

-- Repaints one cell rect. The caller owns the dirty rect because the 3D liquid
-- mesh has to deform over exactly the same region.
function SurfaceRenderer:Paint(x0: number, y0: number, x1: number, y1: number): number
	local grid = self.grid
	local W, H = grid.W, grid.H

	-- Guard, not the normal path: Prepare runs inside the mask sweep and `ready`
	-- gates every caller behind it. Building here keeps a surface that somehow got
	-- ahead of that on the old synchronous behaviour instead of a nil buffer.
	if not self.microX then
		local relief = reliefFor(W, H, grid.cellSize)
		self.microX, self.microY, self.tint = relief.mx, relief.my, relief.tint
	end

	local rw, rh = x1 - x0 + 1, y1 - y0 + 1
	local px = self:_buffer(rw * rh * 4)

	local liq, film, rip = grid.liquid, grid.film, grid.ripple
	local sealedB, wetB, glossB, mask = grid.sealed, grid.wet, grid.gloss, grid.mask
	local stainB = grid.stain
	local mx, my = self.microX, self.microY
	local hx, hy, hz = self.hx, self.hy, self.hz

	-- Config.NormalScale is a tilt per stud of slope, and the gradient taps below
	-- are in cells, so it is converted here. That is what keeps the surface
	-- looking identical when CellSize changes -- otherwise a finer grid, which is
	-- purely a texture-sharpness decision, would also flatten every highlight.
	local nScale = Config.NormalScale / grid.cellSize
	-- see the notes in Config: the gradient saturates with depth so a deep pool
	-- shades as the flat surface it is, and the hard cap catches pour transients
	local shadeRef = Config.ShadeDepthRef
	local gradMax = Config.ShadeGradMax
	local rScale = Config.RippleNormal
	local invEdge = 1 / Config.EdgeAlphaDepth
	local specK, sheenK = Config.SpecStrength, Config.SheenStrength
	local skyWet, skyDry = Config.SkyWet, Config.SkyDry
	local lc, sc = Config.LiquidColor, Config.SealedColor
	local spc, shc = Config.SpecColor, Config.SheenColor
	local lcr, lcg, lcb = lc.X, lc.Y, lc.Z
	local scr, scg, scb = sc.X, sc.Y, sc.Z
	local spr, spg, spb = spc.X, spc.Y, spc.Z
	local shr, shg, shb = shc.X, shc.Y, shc.Z

	--[[
		The terms that are switched off, hoisted out of the inner loop.

		This is the hottest loop in the game: a big pour pushed around a driveway
		repaints tens of thousands of texels every frame, and the whole cost is this
		arithmetic -- WritePixelsBuffer itself measured 0.19 ns a texel against 149
		ns for the loop that fills it, so the upload is not worth thinking about and
		every read in here is.

		Five of the terms below are currently authored to zero, and a term multiplied
		by zero still costs every buffer read that feeds it. RippleNormal alone was
		four reads per texel for a field that cannot reach the picture, and
		ConcreteTint -- the fifth, found after the other four -- was a read per texel
		of a buffer that is a constant 1.0 from end to end. Reading the switches once
		per rect instead of multiplying by zero per texel is the whole change -- flip
		any of them back up in Config and the code underneath comes back exactly as it
		was. Verified byte for byte against the old loop over a full 382x213 slab
		mid-push: 0 of 325,464 bytes differ.
	]]
	--[[
		The permanent wet-out, read as a floor under `sealed`.

		One extra buffer read, on the shaded branch only, and only while the feature
		is authored on -- switched off this is the same loop it always was, to the
		texel. What it buys is the thing the field exists for: ground that sealer has
		covered keeps drawing dark after the sealer itself has thinned, spread or
		been swept off it, instead of fading back through the alpha ramp to bare
		concrete and leaving the deep spots behind as separate islands.
	]]
	local useStain = Config.WetOutSeal > 0

	local useRipple = rScale ~= 0
	local useDryLobe = skyDry ~= 0
	local useWetLobe = specK ~= 0 or skyWet ~= 0
	local useLobes = useDryLobe or useWetLobe

	local flipX, flipY = Config.TexFlipX, Config.TexFlipY
	-- The 3D sheet is a MeshPart texture, and those ignore alpha, so the sealer
	-- is composited over the concrete here and shipped fully opaque. The flat
	-- decal path keeps real alpha instead.
	local opaque = self.opaque
	local tintB = self.tint
	--[[
		The fifth switched-off term, and the only one whose buffer is not built at all
		when it is off: reliefFor skips it when Config.ConcreteTint is 0, which is
		precisely what a nil `tintB` means here. Testing the buffer rather than the
		Config value is deliberate -- it is the same answer as Config.ConcreteTint ~= 0
		for any surface built under the current authoring, and it stays correct for a
		surface whose relief predates the change should ConcreteTint ever be edited
		live. At zero amplitude every entry of that buffer is exactly 1.0, so the
		multiply it feeds is the identity and skipping it is a no-op to the byte.
	]]
	local useTint = tintB ~= nil
	-- this surface's own slab colour, so the opaque sheet and the bare slab
	-- underneath it agree and the promotion cannot be seen
	local ccr, ccg, ccb = self.baseR, self.baseG, self.baseB
	local out = 0

	for ry = 0, rh - 1 do
		local y = if flipY then y1 - ry else y0 + ry
		local rowBase = y * W
		local up = if y > 0 then -W * 4 else 0
		local down = if y < H - 1 then W * 4 else 0

		for rx = 0, rw - 1 do
			local x = if flipX then x1 - rx else x0 + rx
			local i = rowBase + x
			local i4 = i * 4

			local value = 0  -- transparent by default

			if buffer.readu8(mask, i) == 1 then
				local d = buffer.readf32(liq, i4) + buffer.readf32(film, i4)
				local sealedV = buffer.readf32(sealedB, i4)
				-- Shading only. `sealed` itself is untouched, which is what keeps a
				-- stain worth nothing to the score; see SurfaceGrid's `stain`.
				if useStain then
					local st = buffer.readf32(stainB, i4)
					if st > sealedV then sealedV = st end
				end
				local br, bg, bb = ccr, ccg, ccb
				if useTint then
					local tint = buffer.readf32(tintB, i4)
					br, bg, bb = ccr * tint, ccg * tint, ccb * tint
				end

				if d > 0.0008 or sealedV > 0.002 then
					-- Gradient over a 2-cell span. The shallow-water field jitters
					-- at single-cell frequency, and shading that raw reads as white
					-- static; the wider tap is a free low-pass filter.
					local left = if x > 1 then -8 elseif x > 0 then -4 else 0
					local right = if x < W - 2 then 8 elseif x < W - 1 then 4 else 0
					local up2 = if y > 1 then -W * 8 else up
					local down2 = if y < H - 2 then W * 8 else down

					-- slope of the sealer surface, plus the live ripple field
					local dL = buffer.readf32(liq, i4 + left) + buffer.readf32(film, i4 + left)
					local dR = buffer.readf32(liq, i4 + right) + buffer.readf32(film, i4 + right)
					local dU = buffer.readf32(liq, i4 + up2) + buffer.readf32(film, i4 + up2)
					local dD = buffer.readf32(liq, i4 + down2) + buffer.readf32(film, i4 + down2)

					-- Depth stops counting as slope past ShadeDepthRef, so the inside of
					-- a pool is flat to the shader however deep it gets and only the rim,
					-- where it thins back through the band, catches the light. The alpha
					-- and wetness terms below saturate far under this and do not notice.
					if dL > shadeRef then dL = shadeRef end
					if dR > shadeRef then dR = shadeRef end
					if dU > shadeRef then dU = shadeRef end
					if dD > shadeRef then dD = shadeRef end

					local gx = (dR - dL) * nScale * 0.5 + buffer.readf32(mx, i4)
					local gy = (dD - dU) * nScale * 0.5 + buffer.readf32(my, i4)
					if useRipple then
						gx += (buffer.readf32(rip, i4 + right) - buffer.readf32(rip, i4 + left)) * rScale * 0.5
						gy += (buffer.readf32(rip, i4 + down2) - buffer.readf32(rip, i4 + up2)) * rScale * 0.5
					end

					if gx > gradMax then gx = gradMax elseif gx < -gradMax then gx = -gradMax end
					if gy > gradMax then gy = gradMax elseif gy < -gradMax then gy = -gradMax end

					-- `inv` is not optional: the sheen term below is a Fresnel edge off
					-- the same normal, and SheenStrength is the one lighting term that is
					-- not switched off.
					local inv = 1 / math.sqrt(gx * gx + gy * gy + 1)

					-- Two lobes: a wide one standing in for the sky, and a tight one
					-- for the sun. Flat sealer picks up only the wide term, so the
					-- cured finish reads as a low sheen while a rolling wave catches
					-- an actual glint.
					local sky, glint = 0, 0
					if useLobes then
						local nd = (hy - gx * hx - gy * hz) * inv
						if nd > 0 then
							local s2 = nd * nd
							sky = s2 * s2
							local s8 = sky * sky
							glint = s8 * s8
						end
					end
					local fres = 1 - inv
					fres = fres * fres

					local r, g, b = scr, scg, scb
					if useDryLobe then
						-- Reinhard rolloff. Without it, any slope that happens to line up
						-- with the half-vector clips to pure white and a puddle grows a
						-- blown-out hole in the middle of it.
						local dry = sky * buffer.readf32(glossB, i4) * skyDry
						dry = dry / (1 + dry)
						r += dry * spr
						g += dry * spg
						b += dry * spb
					end

					-- Loose sealer sitting on top of it. Presence comes from a
					-- neighbour-weighted depth, not the raw texel: a 1-texel rim
					-- step reads as a staircase, the feathered blend reads as a
					-- meniscus.
					local dSoft = d * 0.5 + (dL + dR + dU + dD) * 0.125
					local la = dSoft * invEdge
					if la > 1 then la = 1 end
					la = la * la * (3 - 2 * la)   -- rounds off the rim of a puddle
					if la > 0 then
						local lit = 0
						if useWetLobe then
							-- Loose sealer is wet by definition. Reflectance is a property of
							-- the surface, not of how deep the pool is, so this saturates
							-- almost immediately -- otherwise thick sealer renders lighter
							-- than thin, which is backwards.
							local w = d * 8
							if w > 1 then w = 1 end
							local wetV = buffer.readf32(wetB, i4)
							if wetV > w then w = wetV end
							local wetness = 0.45 + 0.55 * w
							lit = glint * specK * wetness + sky * skyWet * wetness
							lit = lit / (1 + lit)
						end
						local sh = fres * sheenK
						r += (lcr + lit * spr + sh * shr - r) * la
						g += (lcg + lit * spg + sh * shg - g) * la
						b += (lcb + lit * spb + sh * shb - b) * la
					end

					-- smoothstep keeps a half-cured patch from looking like a
					-- flat grey wash
					local sa = sealedV * sealedV * (3 - 2 * sealedV)
					local a = if la > sa then la else sa

					if opaque then
						r = br + (r - br) * a
						g = bg + (g - bg) * a
						b = bb + (b - bb) * a
						a = 1
					end

					local ri = r * 255; if ri > 255 then ri = 255 elseif ri < 0 then ri = 0 end
					local gi = g * 255; if gi > 255 then gi = 255 elseif gi < 0 then gi = 0 end
					local bi = b * 255; if bi > 255 then bi = 255 elseif bi < 0 then bi = 0 end
					local ai = a * 255; if ai > 255 then ai = 255 elseif ai < 0 then ai = 0 end

					value = (ri // 1) + (gi // 1) * 256 + (bi // 1) * 65536 + (ai // 1) * 16777216

				else
					--[[
						Bare slab -- and the COLOUR matters even when the alpha says the
						texel is invisible.

						This used to write nothing at all on the flat path, leaving those
						texels at 0,0,0,0. Correct for a Decal, which respects alpha and so
						draws nothing -- but the same image is what the 3D sheet is textured
						with, and a MeshPart texture IGNORES alpha. So the frame a driveway
						was promoted from decal to sheet, every bare cell in it drew as solid
						BLACK until the next repaint caught up: walk up to a driveway, watch
						it flash black, watch it come back. Measured mid-promotion --
						0,0,0,0 on the frame the sheet is parented, 121,119,110,255 one
						repaint later.

						Carrying the concrete colour under a zero alpha costs the decal path
						nothing -- at alpha 0 the RGB contributes nothing to the blend -- and
						it makes the sheet correct the instant it appears. It also stops the
						bilinear filter fringing coat edges toward black, since the texel it
						interpolates against is now concrete rather than nothing.
					]]
					local ri = br * 255; if ri > 255 then ri = 255 end
					local gi = bg * 255; if gi > 255 then gi = 255 end
					local bi = bb * 255; if bi > 255 then bi = 255 end
					value = (ri // 1) + (gi // 1) * 256 + (bi // 1) * 65536
						+ (if opaque then 255 else 0) * 16777216
				end
			end

			buffer.writeu32(px, out, value)
			out += 4
		end
	end

	-- A flip mirrors the destination rect too, not just the read order.
	local dx0 = if flipX then W - 1 - x1 else x0
	local dy0 = if flipY then H - 1 - y1 else y0
	self.image:WritePixelsBuffer(Vector2.new(dx0, dy0), Vector2.new(rw, rh), px)
	return rw * rh
end

-- Repaints every region that changed, rather than one rect drawn round all of
-- them. See SurfaceGrid.ActiveRegions for why that distinction is the whole
-- difference between a smooth pour and a stuttering one.
function SurfaceRenderer:Flush(): number
	local n, rects = self.grid:DirtyRegions()
	local painted = 0
	for r = 1, n do
		local q = rects[r]
		painted += self:Paint(q[1], q[2], q[3], q[4])
	end
	return painted
end

return SurfaceRenderer
