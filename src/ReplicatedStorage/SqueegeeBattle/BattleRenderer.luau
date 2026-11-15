--!native
--!optimize 2
--[[
	BattleRenderer -- paints a SurfaceGrid into an EditableImage, in eight
	colours instead of one.

	This is SurfaceRenderer's inner loop with exactly one thing changed: the two
	tones a cell is shaded between are looked up per OWNER rather than read from
	Config.LiquidColor / Config.SealedColor. Everything else -- the depth
	gradient, the Blinn half-vector, the meniscus feather on the rim of a puddle,
	the smoothstep on the cure -- is the shipping recipe, because the paint in
	the arena is the shipping simulation and it should look like it.

	WHY IT IS A SEPARATE FILE AND NOT A FLAG ON THE REAL ONE

	SurfaceRenderer's loop is documented as the hottest in the game and the
	reason four lighting terms are hoisted out of it as switches. Threading a
	per-cell palette lookup through it would put a buffer read and a table index
	on every texel of every driveway in the neighbourhood to serve an event that
	runs for sixty seconds every quarter of an hour. The arena is also the only
	surface in the game with more than one painter, so there is nothing to share:
	this loop has an `owner` buffer and no `paint` buffer, no stain floor and no
	opaque-sheet branch, and the driveway loop has the mirror image of that.

	Kept deliberately close to the original in shape and naming so the two can be
	diffed. If SurfaceRenderer's shading is retuned, this is the file that has to
	be retuned with it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Pack:WaitForChild("Config"))
local Battle = require(script.Parent.BattleConfig)

local BattleRenderer = {}
BattleRenderer.__index = BattleRenderer


local curedR, curedG, curedB = {}, {}, {}
local wetR, wetG, wetB = {}, {}, {}
for i, c in ipairs(Battle.Palette) do
	curedR[i], curedG[i], curedB[i] = c.R * 0.82, c.G * 0.82, c.B * 0.82

	wetR[i] = c.R + (1 - c.R) * 0.10
	wetG[i] = c.G + (1 - c.G) * 0.10
	wetB[i] = c.B + (1 - c.B) * 0.10
end

function BattleRenderer.new(grid, ownerGrid, image, baseColor: Color3)
	local self = setmetatable({
		grid = grid,
		owners = ownerGrid.owner,
		image = image,
		baseR = baseColor.R, baseG = baseColor.G, baseB = baseColor.B,
		_bufs = {},
		_bufCount = 0,
	}, BattleRenderer)

	local hv = (Config.SunDirection + Config.EyeDirection).Unit
	self.hx, self.hy, self.hz = hv.X, hv.Y, hv.Z
	return self
end

function BattleRenderer:_buffer(bytes: number): buffer
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

function BattleRenderer:Paint(x0: number, y0: number, x1: number, y1: number): number
	local grid = self.grid
	local W, H = grid.W, grid.H

	local rw, rh = x1 - x0 + 1, y1 - y0 + 1
	if rw <= 0 or rh <= 0 then return 0 end
	local px = self:_buffer(rw * rh * 4)

	local liq, film = grid.liquid, grid.film
	local sealedB, wetnessB, mask = grid.sealed, grid.wet, grid.mask
	local owners = self.owners
	local hx, hy, hz = self.hx, self.hy, self.hz

	local nScale = Config.NormalScale / grid.cellSize
	local shadeRef = Config.ShadeDepthRef
	local gradMax = Config.ShadeGradMax
	local invEdge = 1 / Config.EdgeAlphaDepth
	local sheenK = Config.SheenStrength
	local shc = Config.SheenColor
	local shr, shg, shb = shc.X, shc.Y, shc.Z
	local spc = Config.SpecColor
	local spr, spg, spb = spc.X, spc.Y, spc.Z

	local specK = 0.55
	local skyWet = 0.16
	local floorA = Battle.OwnedFloor

	local flipX, flipY = Config.TexFlipX, Config.TexFlipY
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

			-- Concrete under a zero alpha, unless something below says otherwise.
			local ri, gi, bi, ai = ccr * 255, ccg * 255, ccb * 255, 0

			if buffer.readu8(mask, i) == 1 then
				local slot = buffer.readu8(owners, i)
				if slot > 0 then
					local d = buffer.readf32(liq, i4) + buffer.readf32(film, i4)
					local sealedV = buffer.readf32(sealedB, i4)

					local left = if x > 1 then -8 elseif x > 0 then -4 else 0
					local right = if x < W - 2 then 8 elseif x < W - 1 then 4 else 0
					local up2 = if y > 1 then -W * 8 else up
					local down2 = if y < H - 2 then W * 8 else down

					local dL = buffer.readf32(liq, i4 + left) + buffer.readf32(film, i4 + left)
					local dR = buffer.readf32(liq, i4 + right) + buffer.readf32(film, i4 + right)
					local dU = buffer.readf32(liq, i4 + up2) + buffer.readf32(film, i4 + up2)
					local dD = buffer.readf32(liq, i4 + down2) + buffer.readf32(film, i4 + down2)

					if dL > shadeRef then dL = shadeRef end
					if dR > shadeRef then dR = shadeRef end
					if dU > shadeRef then dU = shadeRef end
					if dD > shadeRef then dD = shadeRef end

					local gx = (dR - dL) * nScale * 0.5
					local gy = (dD - dU) * nScale * 0.5
					if gx > gradMax then gx = gradMax elseif gx < -gradMax then gx = -gradMax end
					if gy > gradMax then gy = gradMax elseif gy < -gradMax then gy = -gradMax end

					local inv = 1 / math.sqrt(gx * gx + gy * gy + 1)

					local sky, glint = 0, 0
					local nd = (hy - gx * hx - gy * hz) * inv
					if nd > 0 then
						local s2 = nd * nd
						sky = s2 * s2
						local s8 = sky * sky
						glint = s8 * s8
					end
					local fres = 1 - inv
					fres = fres * fres

					local r, g, b = curedR[slot], curedG[slot], curedB[slot]

					-- Loose paint sitting on top. Feathered off the neighbours for
					-- the reason the original gives: a raw one-texel depth step
					-- reads as a staircase, the blend reads as a meniscus.
					local dSoft = d * 0.5 + (dL + dR + dU + dD) * 0.125
					local la = dSoft * invEdge
					if la > 1 then la = 1 end
					la = la * la * (3 - 2 * la)
					if la > 0 then
						local w = d * 8
						if w > 1 then w = 1 end
						local wetV = buffer.readf32(wetnessB, i4)
						if wetV > w then w = wetV end
						local wetness = 0.45 + 0.55 * w
						local lit = glint * specK * wetness + sky * skyWet * wetness
						lit = lit / (1 + lit)
						local sh = fres * sheenK
						r += (wetR[slot] + lit * spr + sh * shr - r) * la
						g += (wetG[slot] + lit * spg + sh * shg - g) * la
						b += (wetB[slot] + lit * spb + sh * shb - b) * la
					end

					local sa = sealedV * sealedV * (3 - 2 * sealedV)
					local a = if la > sa then la else sa
					if a < floorA then a = floorA end

					ri = r * 255; if ri > 255 then ri = 255 elseif ri < 0 then ri = 0 end
					gi = g * 255; if gi > 255 then gi = 255 elseif gi < 0 then gi = 0 end
					bi = b * 255; if bi > 255 then bi = 255 elseif bi < 0 then bi = 0 end
					ai = a * 255; if ai > 255 then ai = 255 elseif ai < 0 then ai = 0 end
				end
			end

			buffer.writeu32(px, out,
				(ri // 1) + (gi // 1) * 256 + (bi // 1) * 65536 + (ai // 1) * 16777216)
			out += 4
		end
	end

	local dx0 = if flipX then W - 1 - x1 else x0
	local dy0 = if flipY then H - 1 - y1 else y0
	self.image:WritePixelsBuffer(Vector2.new(dx0, dy0), Vector2.new(rw, rh), px)
	return rw * rh
end

return BattleRenderer
