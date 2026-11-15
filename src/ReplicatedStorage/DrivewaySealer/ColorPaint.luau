--!native
--!optimize 2
-- Test-only Paint adapter derived from this place. Leaves simulation buffers untouched.
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("DrivewaySealer"):WaitForChild("Config"))
return function(self, x0: number, y0: number, x1: number, y1: number, palette): number
	local grid = self.grid
	local W, H = grid.W, grid.H

	-- Guard, not the normal path: Prepare runs inside the mask sweep and `ready`
	-- gates every caller behind it. Building here keeps a surface that somehow got
	-- ahead of that on the old synchronous behaviour instead of a nil buffer.
	if not self.microX then
		self:Prepare()
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
	local specK, sheenK = palette.specStrength or Config.SpecStrength, Config.SheenStrength
	local skyWet, skyDry = palette.skyWet or Config.SkyWet, palette.skyDry or Config.SkyDry
	local lc, sc = palette.liquid, palette.sealed
	local spc, shc = palette.spec, palette.sheen
	local rainbow = palette.lut
	local rainbowScale = 255 / math.max(W - 1, 1)
	local lcr, lcg, lcb = lc.X, lc.Y, lc.Z
	local scr, scg, scb = sc.X, sc.Y, sc.Z
	local spr, spg, spb = spc.X, spc.Y, spc.Z
	local shr, shg, shb = shc.X, shc.Y, shc.Z

	
	
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

					-- Static LUT: no HSV conversion, animation, or additional texture writes.
					if rainbow then
						local c = rainbow[math.floor(x * rainbowScale) + 1]
						lcr, lcg, lcb = c.X, c.Y, c.Z
						scr, scg, scb = c.X * 0.94, c.Y * 0.94, c.Z * 0.94
					end
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

