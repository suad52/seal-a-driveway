--!strict
--!native
--!optimize 2
--[[
	RaceGrid -- which cells of one lane the blade has been over.

	One byte per cell, 0 or 1, and one lane per instance. That is the whole of the
	score, and it is deliberately a SEPARATE buffer from the sealcoat simulation's
	`sealed` ledger for the same reason BattleGrid is separate from it:

	  * SurfaceGrid says how much COAT is on a cell. That is physics -- it flows,
	    it cures, it thins under the rubber, and it takes about five seconds to
	    come up after the blade has gone past.
	  * This says the rubber has been there. That is the job, and it is true the
	    instant the pass is made.

	THE DIFFERENCE IS WHY THE PERCENTAGE IS OFF THIS AND NOT OFF COVERAGE.
	SurfaceGrid:Coverage trails the blade by CureRate's worth of seconds -- its own
	header measures it at 4.83 s and calls out the "the bar sits at 0% even though I
	am clearly working on it" report that came of it. On a driveway that is a
	cosmetic lag on a number nobody is racing. In a race it is the result: two
	players finishing three seconds apart would be ranked by whose sealer cured
	first, which is not a thing either of them did.

	RUN ON THE SERVER ONLY, WHICH IS THE OTHER DIFFERENCE FROM BattleGrid.

	The arena keeps one of these on every client as well, because the ownership
	buffer is what its renderer draws from. Nothing here is drawn -- the picture is
	the sealcoat -- so the client has no reason to keep a mirror, and giving it one
	would be a second number on screen that can disagree with the one that pays.
	The HUD draws the server's figure off RaceState.
]]

local RaceGrid = {}
RaceGrid.__index = RaceGrid

export type Class = typeof(setmetatable({} :: {
	W: number, H: number, N: number,
	cellSize: number,
	originX: number, originZ: number,
	hit: buffer,
	count: number,
}, RaceGrid))

function RaceGrid.new(w: number, h: number, cellSize: number,
		originX: number, originZ: number): Class
	local n = w * h
	return (setmetatable({
		W = w, H = h, N = n,
		cellSize = cellSize,
		originX = originX, originZ = originZ,
		hit = buffer.create(n),
		count = 0,
	}, RaceGrid) :: any) :: Class
end

function RaceGrid.toCell(self: Class, wx: number, wz: number): (number, number)
	local inv = 1 / self.cellSize
	return (wx - self.originX) * inv - 0.5, (wz - self.originZ) * inv - 0.5
end

function RaceGrid.StampSweep(self: Class,
		x0: number, z0: number, x1: number, z1: number,
		ax: number, az: number, halfLen: number, halfBand: number): number

	local alen = math.sqrt(ax * ax + az * az)
	if alen < 1e-4 then return 0 end
	ax, az = ax / alen, az / alen
	local vx, vz = -az, ax

	local mx, mz = (x0 + x1) * 0.5, (z0 + z1) * 0.5
	local dx, dz = x1 - x0, z1 - z0

	local hu = halfLen + math.abs(dx * ax + dz * az) * 0.5
	local hv = halfBand + math.abs(dx * vx + dz * vz) * 0.5

	-- The oriented box's own bounding box, in studs, then in cells.
	local spanX = hu * math.abs(ax) + hv * math.abs(vx)
	local spanZ = hu * math.abs(az) + hv * math.abs(vz)

	local W, H = self.W, self.H
	local fx0, fy0 = RaceGrid.toCell(self, mx - spanX, mz - spanZ)
	local fx1, fy1 = RaceGrid.toCell(self, mx + spanX, mz + spanZ)
	local cx0 = math.max(0, math.floor(fx0))
	local cy0 = math.max(0, math.floor(fy0))
	local cx1 = math.min(W - 1, math.ceil(fx1))
	local cy1 = math.min(H - 1, math.ceil(fy1))
	if cx1 < cx0 or cy1 < cy0 then return 0 end

	local hit = self.hit
	local cell = self.cellSize
	local ox, oz = self.originX, self.originZ
	local gained = 0

	for cy = cy0, cy1 do
		local wz = oz + (cy + 0.5) * cell
		local rz = wz - mz
		local row = cy * W
		for cx = cx0, cx1 do
			local rx = ox + (cx + 0.5) * cell - mx
			-- inside the oriented box?
			local du = rx * ax + rz * az
			if du <= hu and du >= -hu then
				local dv = rx * vx + rz * vz
				if dv <= hv and dv >= -hv then
					local i = row + cx
					if buffer.readu8(hit, i) == 0 then
						buffer.writeu8(hit, i, 1)
						gained += 1
					end
				end
			end
		end
	end

	self.count += gained
	return gained
end

-- How much of the lane is done, 0..1. Against the WHOLE grid, which is the only
-- denominator a race can use: the lane is the job, and every cell of it is work.
function RaceGrid.progress(self: Class): number
	if self.N <= 0 then return 0 end
	local p = self.count / self.N
	return if p > 1 then 1 else p
end

function RaceGrid.Reset(self: Class)
	buffer.fill(self.hit, 0, 0)
	self.count = 0
end

return RaceGrid
