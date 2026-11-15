--!strict
--!native
--!optimize 2
--[[
	BattleGrid -- who owns each cell of the canvas.

	One byte per cell: 0 for bare, 1-8 for a player's slot. That is the whole of
	the score, and it is deliberately a SEPARATE buffer from the sealcoat
	simulation's `sealed` ledger, for the same reason `stain` is separate from
	`sealed` in SurfaceGrid: the two answer different questions and must not be
	able to answer each other's.

	  * SurfaceGrid says how much COAT is on a cell. That is physics -- it flows,
	    it cures, it thins under the rubber.
	  * This says whose colour that cell is wearing. That is territory, and it
	    changes the instant a blade passes whether or not any new coat is laid.

	The distinction is what makes the game work. Config's spreading rule is
	`demand = keepDepth * (1 - sealed)`, so a cell already at a full coat takes no
	more film -- dragging a bead back over cured sealer is free. If ownership rode
	on the coat, a fully painted cell could never change hands and the first
	player to reach a patch would hold it for the rest of the match. It rides on
	the RUBBER instead: sweep it, and it is yours, coat or no coat.

	RUN ON BOTH SIDES, AND THAT IS THE POINT

	The server keeps one of these and it is the authoritative score. Every client
	keeps its own and it is the picture. Both are driven from the same stroke
	packets through the same StampSweep below, so they agree by construction
	rather than by reconciliation -- there is no "the server said you have 31%
	but your screen says 34%" to fix, because both numbers came out of the same
	function.

	Where they CAN differ is a dropped packet: the stroke channels are
	unreliable (see BattleNet), so a client can miss a sweep the server received.
	That costs a smear of colour on one screen for as long as nobody sweeps it
	again. It cannot cost a point, because the payout reads the server's buffer
	and never a client's claim.
]]

local BattleGrid = {}
BattleGrid.__index = BattleGrid

export type Class = typeof(setmetatable({} :: {
	W: number, H: number, N: number,
	cellSize: number,
	originX: number, originZ: number,
	owner: buffer,
	counts: { number },
	painted: number,
}, BattleGrid))

function BattleGrid.new(cells: number, cellSize: number,
		originX: number, originZ: number, slots: number): Class
	local n = cells * cells
	local counts = table.create(slots, 0)
	for i = 1, slots do counts[i] = 0 end
	return (setmetatable({
		W = cells, H = cells, N = n,
		cellSize = cellSize,
		originX = originX, originZ = originZ,
		owner = buffer.create(n),
		counts = counts,
		painted = 0,
	}, BattleGrid) :: any) :: Class
end

function BattleGrid.toCell(self: Class, wx: number, wz: number): (number, number)
	local inv = 1 / self.cellSize
	return (wx - self.originX) * inv - 0.5, (wz - self.originZ) * inv - 0.5
end

function BattleGrid.cellCentre(self: Class, cx: number, cy: number): (number, number)
	return self.originX + (cx + 0.5) * self.cellSize,
		self.originZ + (cy + 0.5) * self.cellSize
end

function BattleGrid.StampSweep(self: Class, slot: number,
		x0: number, z0: number, x1: number, z1: number,
		ax: number, az: number, halfLen: number, halfBand: number)
		: (number, number, number, number, number)

	-- Degenerate axis: the caller could not derive a facing this frame. Refusing
	-- is right -- a zero axis would make the box a line and stamp nothing useful,
	-- and guessing one paints in a direction the player never faced.
	local alen = math.sqrt(ax * ax + az * az)
	if alen < 1e-4 then return 0, 0, -1, -1, 0 end
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
	local fx0, fy0 = BattleGrid.toCell(self, mx - spanX, mz - spanZ)
	local fx1, fy1 = BattleGrid.toCell(self, mx + spanX, mz + spanZ)
	local cx0 = math.max(0, math.floor(fx0))
	local cy0 = math.max(0, math.floor(fy0))
	local cx1 = math.min(W - 1, math.ceil(fx1))
	local cy1 = math.min(H - 1, math.ceil(fy1))
	if cx1 < cx0 or cy1 < cy0 then return 0, 0, -1, -1, 0 end

	local owner = self.owner
	local counts = self.counts
	local cell = self.cellSize
	local ox, oz = self.originX, self.originZ
	local changed = 0
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
					local was = buffer.readu8(owner, i)
					if was ~= slot then
						if was ~= 0 then
							counts[was] -= 1
						else
							gained += 1
						end
						buffer.writeu8(owner, i, slot)
						counts[slot] += 1
						changed += 1
					end
				end
			end
		end
	end

	self.painted += gained
	return cx0, cy0, cx1, cy1, changed
end

function BattleGrid.shareOf(self: Class, slot: number): number
	if self.N <= 0 then return 0 end
	return (self.counts[slot] or 0) / self.N
end

function BattleGrid.release(self: Class, slot: number): number
	local owner = self.owner
	local freed = self.counts[slot] or 0
	if freed <= 0 then
		self.counts[slot] = 0
		return 0
	end
	for i = 0, self.N - 1 do
		if buffer.readu8(owner, i) == slot then
			buffer.writeu8(owner, i, 0)
		end
	end
	self.counts[slot] = 0
	self.painted -= freed
	if self.painted < 0 then self.painted = 0 end
	return freed
end

function BattleGrid.Reset(self: Class)
	buffer.fill(self.owner, 0, 0)
	for i = 1, #self.counts do self.counts[i] = 0 end
	self.painted = 0
end

function BattleGrid.standings(self: Class, live: { [number]: boolean }?)
	local out = {}
	for slot = 1, #self.counts do
		if not live or live[slot] then
			out[#out + 1] = { slot = slot, cells = self.counts[slot], share = BattleGrid.shareOf(self, slot) }
		end
	end
	table.sort(out, function(a, b)
		if a.cells ~= b.cells then return a.cells > b.cells end
		return a.slot < b.slot
	end)
	return out
end

return BattleGrid
