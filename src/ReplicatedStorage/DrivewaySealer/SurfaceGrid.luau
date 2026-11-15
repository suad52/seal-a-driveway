--!native
--!optimize 2

local Config = require(script.Parent.Config)

local SurfaceGrid = {}
SurfaceGrid.__index = SurfaceGrid

local WET_FROM_FILM = 3.3

local function f32(n: number)
	return buffer.create(n * 4)
end

function SurfaceGrid.new(w: number, h: number, cellSize: number, originX: number, originZ: number)
	local n = w * h
	local cw, ch = math.ceil(w / Config.ChunkCells), math.ceil(h / Config.ChunkCells)

	return setmetatable({
		W = w, H = h, N = n,
		cellSize = cellSize,

		cellArea = cellSize * cellSize,
		invCellArea = 1 / (cellSize * cellSize),
		originX = originX, originZ = originZ,

		liquid = f32(n), film = f32(n), delta = f32(n),
		vx = f32(n), vy = f32(n),
		sealed = f32(n), wet = f32(n), gloss = f32(n),

		stain = f32(n),
		ripple = f32(n), rvel = f32(n),
		mask = buffer.create(n),

		inner = nil :: buffer?,
		counted = buffer.create(n),

		paint = buffer.create(n),

		CW = cw, CH = ch,
		awake = buffer.create(cw * ch),
		sleepT = f32(cw * ch),
		dirty = buffer.create(cw * ch),

		slowT = buffer.create(cw * ch),

		_energy = buffer.create(cw * ch * 8),
		_energyFast = buffer.create(cw * ch * 8),

		_lab = buffer.create(cw * ch),
		_stack = table.create(256),
		_activeRects = {},
		_dirtyRects = {},

		_bandY = 0,
		_bandX = 0,

		anyAwake = false,
		anyDirty = false,

		maskCount = 0,

		paintCount = 0,
		sealedCount = 0,

		sealedFrac = 0,

		stainCount = 0,
		loose = 0,
		pile = 0,

		easyFlow = false,

		_frontIdx = table.create(2048),
		_frontW = table.create(2048),
		_tipIdx = table.create(4096),
		_tipW = table.create(4096),
		_behindIdx = table.create(512),
		_behindW = table.create(512),
		_result = {
			touched = 0, pile = 0, resistance = 0, spreadQuality = 1,
			x0 = 0, y0 = 0, x1 = 0, y1 = 0,
		},
	}, SurfaceGrid)
end

function SurfaceGrid:WorldToCell(wx: number, wz: number): (number, number)
	local inv = 1 / self.cellSize
	return (wx - self.originX) * inv - 0.5, (wz - self.originZ) * inv - 0.5
end

function SurfaceGrid:CellToWorld(cx: number, cy: number): (number, number)
	return self.originX + (cx + 0.5) * self.cellSize, self.originZ + (cy + 0.5) * self.cellSize
end

function SurfaceGrid:WakeCellRect(x0: number, y0: number, x1: number, y1: number)
	local cs = Config.ChunkCells
	local cx0 = math.max(0, math.floor(x0 / cs))
	local cy0 = math.max(0, math.floor(y0 / cs))
	local cx1 = math.min(self.CW - 1, math.floor(x1 / cs))
	local cy1 = math.min(self.CH - 1, math.floor(y1 / cs))
	local awake, sleepT, dirty, CW = self.awake, self.sleepT, self.dirty, self.CW
	self.anyAwake = true
	self.anyDirty = true
	for cy = cy0, cy1 do
		local base = cy * CW
		for cx = cx0, cx1 do
			local c = base + cx
			buffer.writeu8(awake, c, 1)
			buffer.writeu8(dirty, c, 1)
			buffer.writef32(sleepT, c * 4, 0)
		end
	end
end

function SurfaceGrid:WakeAll()
	buffer.fill(self.awake, 0, 1)
	buffer.fill(self.dirty, 0, 1)
	buffer.fill(self.sleepT, 0, 0)
	self.anyAwake = true
	self.anyDirty = true
end

function SurfaceGrid:MarkAllDirty()
	buffer.fill(self.dirty, 0, 1)
	self.anyDirty = true
end

local MAX_ACTIVE_RECTS = 8
local MAX_DIRTY_RECTS  = 6

local PAINT_MARGIN = 2

local SLOW_REPAINT_EVERY = 5

local function rectArea(r): number
	return (r[3] - r[1] + 1) * (r[4] - r[2] + 1)
end

local function unionArea(a, b): number
	local x0 = if a[1] < b[1] then a[1] else b[1]
	local y0 = if a[2] < b[2] then a[2] else b[2]
	local x1 = if a[3] > b[3] then a[3] else b[3]
	local y1 = if a[4] > b[4] then a[4] else b[4]
	return (x1 - x0 + 1) * (y1 - y0 + 1)
end

local function absorb(a, b)
	if b[1] < a[1] then a[1] = b[1] end
	if b[2] < a[2] then a[2] = b[2] end
	if b[3] > a[3] then a[3] = b[3] end
	if b[4] > a[4] then a[4] = b[4] end

	if b[5] < a[5] then a[5] = b[5] end
	if b[6] < a[6] then a[6] = b[6] end
	if b[7] > a[7] then a[7] = b[7] end
	if b[8] > a[8] then a[8] = b[8] end
end

function SurfaceGrid:_decompose(flags: buffer, dilate: boolean, pool: { any }, maxRects: number): number
	local CW, CH, cs = self.CW, self.CH, Config.ChunkCells
	local W, H = self.W, self.H
	local lab, stack = self._lab, self._stack
	local nc = CW * CH
	buffer.fill(lab, 0, 0)

	local count = 0
	for seed = 0, nc - 1 do
		if buffer.readu8(flags, seed) == 1 and buffer.readu8(lab, seed) == 0 then
			local cx0, cy0 = seed % CW, seed // CW
			local cx1, cy1 = cx0, cy0
			buffer.writeu8(lab, seed, 1)
			local n = 1
			stack[1] = seed
			while n > 0 do
				local c = stack[n]; n -= 1
				local x, y = c % CW, c // CW
				if x < cx0 then cx0 = x elseif x > cx1 then cx1 = x end
				if y < cy0 then cy0 = y elseif y > cy1 then cy1 = y end

				for dy = -1, 1 do
					local ny = y + dy
					if ny >= 0 and ny < CH then
						local base = ny * CW
						for dx = -1, 1 do
							local nx = x + dx
							if nx >= 0 and nx < CW then
								local j = base + nx
								if buffer.readu8(flags, j) == 1 and buffer.readu8(lab, j) == 0 then
									buffer.writeu8(lab, j, 1)
									n += 1
									stack[n] = j
								end
							end
						end
					end
				end
			end

			count += 1
			local r = pool[count]
			if not r then r = table.create(8); pool[count] = r end
			r[5], r[6], r[7], r[8] = cx0, cy0, cx1, cy1
			if dilate then
				r[1] = math.max(0, cx0 * cs - PAINT_MARGIN)
				r[2] = math.max(0, cy0 * cs - PAINT_MARGIN)
				r[3] = math.min(W - 1, (cx1 + 1) * cs - 1 + PAINT_MARGIN)
				r[4] = math.min(H - 1, (cy1 + 1) * cs - 1 + PAINT_MARGIN)
			else
				r[1] = math.max(0, cx0 * cs - 1)
				r[2] = math.max(0, cy0 * cs - 1)
				r[3] = math.min(W - 1, (cx1 + 1) * cs)
				r[4] = math.min(H - 1, (cy1 + 1) * cs)
			end
		end
	end

	if count < 2 then return count end

	local changed = true
	while changed do
		changed = false
		local i = 1
		while i <= count do
			local a = pool[i]
			local j = i + 1
			while j <= count do
				local b = pool[j]
				if a[1] <= b[3] and b[1] <= a[3] and a[2] <= b[4] and b[2] <= a[4] then
					absorb(a, b)
					pool[j], pool[count] = pool[count], pool[j]
					count -= 1
					changed = true
				else
					j += 1
				end
			end
			i += 1
		end
	end

	while count > maxRects do
		local bi, bj, best = 1, 2, math.huge
		for i = 1, count - 1 do
			for j = i + 1, count do
				local cost = unionArea(pool[i], pool[j])
				if cost < best then best, bi, bj = cost, i, j end
			end
		end
		absorb(pool[bi], pool[bj])
		pool[bj], pool[count] = pool[count], pool[bj]
		count -= 1

		local a = pool[bi]
		local j = 1
		while j <= count do
			local b = pool[j]
			if b ~= a and a[1] <= b[3] and b[1] <= a[3] and a[2] <= b[4] and b[2] <= a[4] then
				absorb(a, b)
				pool[j], pool[count] = pool[count], pool[j]
				count -= 1
				j = 1
			else
				j += 1
			end
		end
	end

	local sum = 0
	for i = 1, count do sum += rectArea(pool[i]) end
	local a = pool[1]
	local bx0, by0, bx1, by1 = a[1], a[2], a[3], a[4]
	for i = 2, count do
		local r = pool[i]
		if r[1] < bx0 then bx0 = r[1] end
		if r[2] < by0 then by0 = r[2] end
		if r[3] > bx1 then bx1 = r[3] end
		if r[4] > by1 then by1 = r[4] end
	end
	if sum >= (bx1 - bx0 + 1) * (by1 - by0 + 1) then
		local cx0, cy0, cx1, cy1 = a[5], a[6], a[7], a[8]
		for i = 2, count do
			local r = pool[i]
			if r[5] < cx0 then cx0 = r[5] end
			if r[6] < cy0 then cy0 = r[6] end
			if r[7] > cx1 then cx1 = r[7] end
			if r[8] > cy1 then cy1 = r[8] end
		end
		a[1], a[2], a[3], a[4] = bx0, by0, bx1, by1
		a[5], a[6], a[7], a[8] = cx0, cy0, cx1, cy1
		return 1
	end
	return count
end

function SurfaceGrid:ActiveRegions(): (number, { any })
	local pool = self._activeRects
	if not self.anyAwake then return 0, pool end
	local n = self:_decompose(self.awake, false, pool, MAX_ACTIVE_RECTS)
	if n == 0 then self.anyAwake = false end
	return n, pool
end

function SurfaceGrid:DirtyCells(): number
	if not self.anyDirty then return 0 end
	local d = self.dirty
	local n = self.CW * self.CH
	local k = 0
	for c = 0, n - 1 do
		if buffer.readu8(d, c) == 1 then k += 1 end
	end
	return k * Config.ChunkCells * Config.ChunkCells
end

function SurfaceGrid:DirtyRegions(maxCells: number?): (number, { any })
	local pool = self._dirtyRects
	if not self.anyDirty then return 0, pool end
	local n = self:_decompose(self.dirty, true, pool, MAX_DIRTY_RECTS)

	if not maxCells or n == 0 then
		buffer.fill(self.dirty, 0, 0)
		self.anyDirty = false
		return n, pool
	end

	local cs, CW = Config.ChunkCells, self.CW
	local dirtyB = self.dirty

	local budget = maxCells
	local out = 0
	local left = false

	for i = 1, n do
		local r = pool[i]
		local area = rectArea(r)

		if area <= budget then
			budget -= area
			for cy = r[6], r[8] do
				buffer.fill(dirtyB, cy * CW + r[5], 0, r[7] - r[5] + 1)
			end
			out += 1
			if out ~= i then
				local d = pool[out]
				for k = 1, 8 do d[k], r[k] = r[k], d[k] end
			end
		else

			local cy0, cy1 = r[6], r[8]
			local cx0, cx1 = r[5], r[7]
			local rowCells = (r[3] - r[1] + 1) * cs
			local rows = budget // rowCells

			local narrowed = rows < 1
			local exC = cx1
			if narrowed then
				rows = 1

				local cols = budget // (cs * cs)
				if cols < 1 then cols = 1 end
				local qc = 1
				while qc * 2 <= cols do qc *= 2 end
				local bx = self._bandX
				if bx < cx0 or bx > cx1 then bx = cx0 end
				cx0 = bx
				exC = math.min(cx1, bx + qc - 1)
			end

			local q = 1
			while q * 2 <= rows do q *= 2 end
			rows = q

			local sy = self._bandY
			if sy < cy0 or sy > cy1 then sy = cy0 end
			local ey = sy + rows - 1
			if ey > cy1 then ey = cy1 end

			for cy = sy, ey do
				buffer.fill(dirtyB, cy * CW + cx0, 0, exC - cx0 + 1)
			end

			if exC >= cx1 then
				self._bandX = 0
				self._bandY = if ey >= cy1 then 0 else ey + 1
			else
				self._bandX = exC + 1
			end

			out += 1
			local d = pool[out]
			if d ~= r then
				for k = 1, 8 do d[k], r[k] = r[k], d[k] end
				r = d
			end

			if narrowed then
				r[1] = math.max(0, cx0 * cs - PAINT_MARGIN)
				r[3] = math.min(self.W - 1, (exC + 1) * cs - 1 + PAINT_MARGIN)
				r[5], r[7] = cx0, exC
			end
			r[2] = math.max(0, sy * cs - PAINT_MARGIN)
			r[4] = math.min(self.H - 1, (ey + 1) * cs - 1 + PAINT_MARGIN)
			r[6], r[8] = sy, ey

			budget = 0
			left = true
		end
		if budget <= 0 and i < n then
			left = true
			break
		end
	end

	if not left and out == n then
		buffer.fill(dirtyB, 0, 0)
		self.anyDirty = false
	end
	return out, pool
end

function SurfaceGrid:Step(dt: number)
	local n, rects = self:ActiveRegions()
	if n == 0 then return 0 end

	local loose, newlySealed, fracNew = 0, 0, 0
	for r = 1, n do
		local q = rects[r]
		local l, s, f = self:_stepRect(dt, q[1], q[2], q[3], q[4])
		loose += l
		newlySealed += s
		fracNew += f
	end

	self.loose = loose * self.cellArea
	self.sealedCount += newlySealed
	self.sealedFrac += fracNew

	self.anyDirty = true
	return newlySealed
end

function SurfaceGrid:_buildInterior(): buffer
	local W, H, mask = self.W, self.H, self.mask
	local inner = buffer.create(W * H)
	for y = 1, H - 2 do
		local rowBase = y * W
		for x = 1, W - 2 do
			local i = rowBase + x
			if buffer.readu8(mask, i) == 1
				and buffer.readu8(mask, i - 1) == 1 and buffer.readu8(mask, i + 1) == 1
				and buffer.readu8(mask, i - W) == 1 and buffer.readu8(mask, i + W) == 1 then
				buffer.writeu8(inner, i, 1)
			end
		end
	end
	self.inner = inner
	return inner
end

function SurfaceGrid:_stepRect(dt: number, x0: number, y0: number, x1: number, y1: number): (number, number, number)
	local W, H = self.W, self.H
	local liq, film, del = self.liquid, self.film, self.delta
	local vxb, vyb, mask = self.vx, self.vy, self.mask
	local rip, rvel = self.ripple, self.rvel
	local sealedB, wetB, glossB, counted = self.sealed, self.wet, self.gloss, self.counted
	local paintB = self.paint
	local stainB = self.stain

	for y = y0, y1 do
		buffer.fill(del, (y * W + x0) * 4, 0, (x1 - x0 + 1) * 4)
	end

	local yieldD = Config.YieldDepth
	local smoothGate = Config.SmoothGate
	local invRange = 1 / math.max(1e-4, Config.FlowThickRef - smoothGate)
	local rmin, rspan = Config.FlowRateMin, Config.FlowRateMax - Config.FlowRateMin
	local maxFrac = Config.MaxFluxFrac
	local quarterDt = dt * 0.25

	local invCell = 1 / self.cellSize
	local advClamp = Config.AdvectClamp
	local minVel2 = Config.MinVelocity * Config.MinVelocity

	local halfYield = yieldD * 0.8

	local pushYield = Config.PushDepth or halfYield
	if pushYield > halfYield then pushYield = halfYield end

	local inner = self.inner or self:_buildInterior()

	for y = y0, y1 do
		local rowBase = y * W
		for x = x0, x1 do
			local i = rowBase + x
			if buffer.readu8(mask, i) == 0 then continue end
			local i4 = i * 4
			local h = buffer.readf32(liq, i4)
			local isInner = buffer.readu8(inner, i) == 1

			if x < x1 then
				if isInner or buffer.readu8(mask, i + 1) == 1 then
					local j4 = i4 + 4
					local hn = buffer.readf32(liq, j4)
					local d = h - hn
					if d > 1e-5 or d < -1e-5 then
						local hi = if h > hn then h else hn
						local mob = hi - smoothGate
						if mob > 0 then
							local t = mob * invRange
							if t > 1 then t = 1 end
							local f = d * (rmin + rspan * t) * quarterDt
							local cap = (if d > 0 then h else hn) * maxFrac
							if f > cap then f = cap elseif f < -cap then f = -cap end
							buffer.writef32(del, i4, buffer.readf32(del, i4) - f)
							buffer.writef32(del, j4, buffer.readf32(del, j4) + f)
						end
					end
				end
			end

			if y < y1 then
				if isInner or buffer.readu8(mask, i + W) == 1 then
					local j4 = i4 + W * 4
					local hn = buffer.readf32(liq, j4)
					local d = h - hn
					if d > 1e-5 or d < -1e-5 then
						local hi = if h > hn then h else hn
						local mob = hi - smoothGate
						if mob > 0 then
							local t = mob * invRange
							if t > 1 then t = 1 end
							local f = d * (rmin + rspan * t) * quarterDt
							local cap = (if d > 0 then h else hn) * maxFrac
							if f > cap then f = cap elseif f < -cap then f = -cap end
							buffer.writef32(del, i4, buffer.readf32(del, i4) - f)
							buffer.writef32(del, j4, buffer.readf32(del, j4) + f)
						end
					end
				end
			end

			local vx = buffer.readf32(vxb, i4)
			local vy = buffer.readf32(vyb, i4)
			if vx * vx + vy * vy > minVel2 then
				local mob = h - pushYield
				if mob > 0 then
					local fx = vx * dt * invCell
					local fy = vy * dt * invCell
					if fx > advClamp then fx = advClamp elseif fx < -advClamp then fx = -advClamp end
					if fy > advClamp then fy = advClamp elseif fy < -advClamp then fy = -advClamp end

					local ox = mob * (if fx < 0 then -fx else fx)
					local oy = mob * (if fy < 0 then -fy else fy)

					local jx = if fx > 0 then i + 1 else i - 1
					local okx = (if fx > 0 then x < x1 else x > x0)
						and (isInner or buffer.readu8(mask, jx) == 1)
					local jy = if fy > 0 then i + W else i - W
					local oky = (if fy > 0 then y < y1 else y > y0)
						and (isInner or buffer.readu8(mask, jy) == 1)

					if not okx then ox = 0 end
					if not oky then oy = 0 end

					local out = ox + oy
					if out > 0 then
						buffer.writef32(del, i4, buffer.readf32(del, i4) - out)
						if ox > 0 then
							local j4 = jx * 4
							buffer.writef32(del, j4, buffer.readf32(del, j4) + ox)
						end
						if oy > 0 then
							local j4 = jy * 4
							buffer.writef32(del, j4, buffer.readf32(del, j4) + oy)
						end
					end
				end
			end
		end
	end

	local easy = self.easyFlow
	local damping = if easy then Config.TutorialVelDamping else Config.VelDamping
	local thinDrag = if easy then Config.TutorialThinDrag else Config.ThinDragBoost
	local baseDamp = math.exp(-damping * dt)
	local thinDamp = math.exp(-(damping + thinDrag) * dt)

	local invSpan = 1 / (2 * self.cellSize)
	local gravDt = Config.Gravity * dt
	local critSlope = Config.CriticalSlope
	local maxSpeed = Config.MaxFlowSpeed
	local maxSpeed2 = maxSpeed * maxSpeed
	local cure = Config.CureRate * dt
	local wetStep = Config.WetDecay * dt
	local glossStep = Config.GlossDecay * dt
	local glossSettle = Config.GlossSettle

	local sealPer = Config.SealPerPass / (if easy then Config.TutorialSealDepth else Config.SealDepth)
	local rippleGate, rippleClamp = Config.RippleGate, Config.RippleClamp
	local waveK = Config.RippleSpeed * dt
	local waveDamp = Config.RippleDamp
	local sealThresh = Config.SealedThreshold

	local invThresh = 1 / sealThresh

	local wetDepth, wetSeal = Config.WetOutDepth, Config.WetOutSeal
	local useWetOut = wetSeal > 0
	local stainNew = 0

	local useRipple = Config.RippleNormal ~= 0
	local useShine = Config.SpecStrength ~= 0 or Config.SkyWet ~= 0 or Config.SkyDry ~= 0
	local chunkCells, CW = Config.ChunkCells, self.CW
	local sleepEnergy, sleepDelay = Config.SleepEnergy, Config.SleepDelay
	local awake, sleepT, dirtyB = self.awake, self.sleepT, self.dirty

	local loose = 0
	local newlySealed = 0

	local fracNew = 0

	local cx0, cx1 = math.floor(x0 / chunkCells), math.floor(x1 / chunkCells)
	local cy0, cy1 = math.floor(y0 / chunkCells), math.floor(y1 / chunkCells)
	local energy = self._energy

	local energyFast = self._energyFast

	for cy = cy0, cy1 do
		local o = (cy * CW + cx0) * 8
		local n = (cx1 - cx0 + 1) * 8
		buffer.fill(energy, o, 0, n)
		buffer.fill(energyFast, o, 0, n)
	end

	for y = y0, y1 do
		local rowBase = y * W

		local eRow = (y // chunkCells) * CW
		local ecx = x0 // chunkCells
		local eNext = (ecx + 1) * chunkCells
		local ei8 = (eRow + ecx) * 8
		for x = x0, x1 do
			if x >= eNext then
				eNext += chunkCells
				ei8 += 8
			end
			local i = rowBase + x
			if buffer.readu8(mask, i) == 0 then continue end
			local i4 = i * 4
			local e = 0
			local ef = 0

			local d = buffer.readf32(del, i4)
			local h = buffer.readf32(liq, i4)
			if d ~= 0 then
				h += d
				if h < 0 then h = 0 end
				buffer.writef32(liq, i4, h)
				local ad = if d < 0 then -d else d
				e += ad; ef += ad
			end
			loose += h

			if useWetOut and h > wetDepth and buffer.readf32(stainB, i4) < wetSeal then
				buffer.writef32(stainB, i4, wetSeal)
				stainNew += 1
				e += wetSeal; ef += wetSeal
			end

			local fl = buffer.readf32(film, i4)
			if fl > 0 then
				local used = if fl < cure then fl else cure
				fl -= used
				if fl < 1e-4 then fl = 0 end
				buffer.writef32(film, i4, fl)

				local was = buffer.readf32(sealedB, i4)
				local s = was + used * sealPer
				if s > 1 then s = 1 end
				buffer.writef32(sealedB, i4, s)

				if buffer.readu8(paintB, i) == 0 then
					local a = if was >= sealThresh then 1 else was * invThresh
					local b = if s >= sealThresh then 1 else s * invThresh
					fracNew += b - a
				end
				if s >= sealThresh and buffer.readu8(counted, i) == 0 then

					buffer.writeu8(counted, i, 1)
					if buffer.readu8(paintB, i) == 0 then
						newlySealed += 1
					end
				end

				if useShine then
					local targetWet = fl * WET_FROM_FILM
					if targetWet > 1 then targetWet = 1 end
					if targetWet > buffer.readf32(wetB, i4) then
						buffer.writef32(wetB, i4, targetWet)
					end
				end

				e += used; ef += used
			end

			local vx = buffer.readf32(vxb, i4)
			local vy = buffer.readf32(vyb, i4)
			if h > halfYield then
				local hL, hR, hU, hD
				if buffer.readu8(inner, i) == 1 then

					hL = buffer.readf32(liq, i4 - 4)
					hR = buffer.readf32(liq, i4 + 4)
					hU = buffer.readf32(liq, i4 - W * 4)
					hD = buffer.readf32(liq, i4 + W * 4)
				else
					hL = if x > 0 and buffer.readu8(mask, i - 1) == 1
						then buffer.readf32(liq, i4 - 4) else h
					hR = if x < W - 1 and buffer.readu8(mask, i + 1) == 1
						then buffer.readf32(liq, i4 + 4) else h
					hU = if y > 0 and buffer.readu8(mask, i - W) == 1
						then buffer.readf32(liq, i4 - W * 4) else h
					hD = if y < H - 1 and buffer.readu8(mask, i + W) == 1
						then buffer.readf32(liq, i4 + W * 4) else h
				end

				local sx = (hL - hR) * invSpan
				if sx > critSlope then sx -= critSlope
				elseif sx < -critSlope then sx += critSlope else sx = 0 end
				local sy = (hU - hD) * invSpan
				if sy > critSlope then sy -= critSlope
				elseif sy < -critSlope then sy += critSlope else sy = 0 end
				vx += sx * gravDt
				vy += sy * gravDt
			end
			if vx ~= 0 or vy ~= 0 then
				local k = if h < yieldD then thinDamp else baseDamp
				vx *= k; vy *= k
				local sp2 = vx * vx + vy * vy
				if sp2 < minVel2 then
					vx = 0; vy = 0
				elseif sp2 > maxSpeed2 then
					local s = maxSpeed / math.sqrt(sp2)
					vx *= s; vy *= s
				end
				buffer.writef32(vxb, i4, vx)
				buffer.writef32(vyb, i4, vy)
				local av = (if vx < 0 then -vx else vx) * 0.05 + (if vy < 0 then -vy else vy) * 0.05
				e += av; ef += av
			end

			if useRipple then
				local r = buffer.readf32(rip, i4)
				local rv = buffer.readf32(rvel, i4)
				if r ~= 0 or rv ~= 0 then
					if h + fl <= rippleGate then
						r *= 0.86; rv *= 0.78
						if r < 1e-4 and r > -1e-4 then r = 0; rv = 0 end
					elseif x > 0 and x < W - 1 and y > 0 and y < H - 1 then
						local lap = buffer.readf32(rip, i4 - 4) + buffer.readf32(rip, i4 + 4)
							+ buffer.readf32(rip, i4 - W * 4) + buffer.readf32(rip, i4 + W * 4) - 4 * r
						rv = (rv + lap * waveK) * waveDamp
						r += rv * dt
						if r > rippleClamp then r = rippleClamp elseif r < -rippleClamp then r = -rippleClamp end
					end
					buffer.writef32(rip, i4, r)
					buffer.writef32(rvel, i4, rv)
					local ar = (if rv < 0 then -rv else rv) * 0.02
					e += ar; ef += ar
				end
			end

			if useShine then
				local wv = buffer.readf32(wetB, i4)
				if wv > 0 and fl <= 0 then
					wv -= wetStep
					if wv < 0 then wv = 0 end
					buffer.writef32(wetB, i4, wv)
					e += wetStep
				end

				local gv = buffer.readf32(glossB, i4)
				local gTarget = glossSettle + 0.40 * wv
				if gv < gTarget then
					gv += glossStep * 3
					if gv > gTarget then gv = gTarget end
					buffer.writef32(glossB, i4, gv)
					e += glossStep
				elseif gv > gTarget + 1e-4 then
					gv -= glossStep
					if gv < gTarget then gv = gTarget end
					buffer.writef32(glossB, i4, gv)
					e += glossStep
				end
			end

			if e > 0 then
				buffer.writef64(energy, ei8, buffer.readf64(energy, ei8) + e)
				if ef > 0 then
					buffer.writef64(energyFast, ei8, buffer.readf64(energyFast, ei8) + ef)
				end
			end
		end
	end

	local perChunk = chunkCells * chunkCells * sleepEnergy
	local slowT = self.slowT
	for cy = cy0, cy1 do
		for cx = cx0, cx1 do
			local c = cy * CW + cx
			local e = buffer.readf64(energy, c * 8)

			local retiring = false
			if e > perChunk then
				buffer.writeu8(awake, c, 1)
				buffer.writef32(sleepT, c * 4, 0)
			elseif buffer.readu8(awake, c) == 1 then
				local t = buffer.readf32(sleepT, c * 4) + dt
				if t >= sleepDelay then

					local stillCuring = false
					local yLo, yHi = cy * chunkCells, math.min(H, (cy + 1) * chunkCells) - 1
					local xLo, xHi = cx * chunkCells, math.min(W, (cx + 1) * chunkCells) - 1
					for yy = yLo, yHi do
						local scanBase = yy * W
						for xx = xLo, xHi do
							if buffer.readf32(film, (scanBase + xx) * 4) > 0 then
								stillCuring = true
								break
							end
						end
						if stillCuring then break end
					end
					if stillCuring then

						buffer.writef32(sleepT, c * 4, 0)
					else
						buffer.writeu8(awake, c, 0)
						retiring = true
					end
				else
					buffer.writef32(sleepT, c * 4, t)
				end
			else
				continue
			end

			if retiring or buffer.readf64(energyFast, c * 8) > 0 then
				buffer.writeu8(dirtyB, c, 1)
				buffer.writeu8(slowT, c, 0)
			elseif e > 0 then
				local k = buffer.readu8(slowT, c) + 1
				if k >= SLOW_REPAINT_EVERY then
					buffer.writeu8(slowT, c, 0)
					buffer.writeu8(dirtyB, c, 1)
				else
					buffer.writeu8(slowT, c, k)
				end
			end
		end
	end

	self.stainCount += stainNew
	return loose, newlySealed, fracNew
end

function SurfaceGrid:Pour(wx: number, wz: number, amount: number, radiusStuds: number?)
	local cellAmount = amount * self.invCellArea
	local radius = (radiusStuds or Config.PourRadius) / self.cellSize
	local fx, fy = self:WorldToCell(wx, wz)
	local W, H = self.W, self.H
	local x0 = math.max(0, math.floor(fx - radius))
	local x1 = math.min(W - 1, math.ceil(fx + radius))
	local y0 = math.max(0, math.floor(fy - radius))
	local y1 = math.min(H - 1, math.ceil(fy + radius))
	if x1 < x0 or y1 < y0 then return 0 end

	local liq, mask, rvelB = self.liquid, self.mask, self.rvel
	local vxb, vyb = self.vx, self.vy
	local invR2 = 1 / (radius * radius)
	local spread = Config.PourSpread
	local rippleKick = Config.PourRipple

	local total = 0
	for y = y0, y1 do
		local dy = y - fy
		for x = x0, x1 do
			local dx = x - fx
			local t = 1 - (dx * dx + dy * dy) * invR2
			if t > 0 and buffer.readu8(mask, y * W + x) == 1 then
				total += t
			end
		end
	end
	if total <= 0 then return 0 end

	local scale = cellAmount / total
	for y = y0, y1 do
		local dy = y - fy
		local rowBase = y * W
		for x = x0, x1 do
			local dx = x - fx
			local t = 1 - (dx * dx + dy * dy) * invR2
			if t > 0 then
				local i = rowBase + x
				if buffer.readu8(mask, i) == 1 then
					local i4 = i * 4
					local w = t
					buffer.writef32(liq, i4, buffer.readf32(liq, i4) + w * scale)

					local len = math.sqrt(dx * dx + dy * dy)
					if len > 0.5 then
						local k = spread * t * scale * 0.9 / len
						buffer.writef32(vxb, i4, buffer.readf32(vxb, i4) + dx * k)
						buffer.writef32(vyb, i4, buffer.readf32(vyb, i4) + dy * k)
					end
					buffer.writef32(rvelB, i4, buffer.readf32(rvelB, i4) - rippleKick * w * scale)
				end
			end
		end
	end

	self:WakeCellRect(x0 - 2, y0 - 2, x1 + 2, y1 + 2)
	return amount
end

function SurfaceGrid:Squeegee(
	cx: number, cz: number,
	ax: number, az: number,
	px: number, pz: number,
	travel: number, speed: number, dt: number, strength: number,
	wide: number?, holds: number?
)
	local res = self._result
	res.touched = 0; res.spreadQuality = 1

	local capacity = holds or Config.BladeCapacity
	local heavy = (self.pile - capacity) / Config.BladeLoadRef
	if heavy < 0 then heavy = 0 elseif heavy > 1 then heavy = 1 end

	local halfLen = wide or Config.BladeHalfLen
	local reach = Config.BladeReach * (1 + Config.BladeLoadReach * heavy)

	local gather, gatherBack = Config.BladeGather, Config.BladeGatherBack
	local cell = self.cellSize

	local halfAlong = halfLen + 0.35 + gather
	local halfAhead = travel + 0.40
	if reach > halfAhead then halfAhead = reach end
	if gatherBack > halfAhead then halfAhead = gatherBack end

	local absAx = if ax < 0 then -ax else ax
	local absAz = if az < 0 then -az else az
	local spanX = halfAlong * absAx + halfAhead * absAz + 0.8
	local spanZ = halfAlong * absAz + halfAhead * absAx + 0.8
	local fx, fy = self:WorldToCell(cx, cz)
	local spanCellsX = spanX / cell
	local spanCellsY = spanZ / cell
	local W, H = self.W, self.H
	local x0 = math.max(0, math.floor(fx - spanCellsX))
	local x1 = math.min(W - 1, math.ceil(fx + spanCellsX))
	local y0 = math.max(0, math.floor(fy - spanCellsY))
	local y1 = math.min(H - 1, math.ceil(fy + spanCellsY))
	if x1 < x0 or y1 < y0 then return res end

	local liq, film, mask = self.liquid, self.film, self.mask
	local vxb, vyb, rvelB = self.vx, self.vy, self.rvel
	local glossB, ripB = self.gloss, self.ripple
	local sealedB = self.sealed

	local keepDepth = Config.CoatDepth

	local frontIdx, frontW = self._frontIdx, self._frontW
	local tipIdx, tipW = self._tipIdx, self._tipW
	local behindIdx, behindW = self._behindIdx, self._behindW
	local nFront, nTip, nBehind = 0, 0, 0
	local frontTotalW, behindTotalW, tipTotalW = 0, 0, 0
	local carry = 0
	local frontVolume = 0
	local touched, inTolerance = 0, 0

	local behindLimit = -(travel + 0.40)
	local alongLimit = halfLen + 0.35
	local invTaper = 1 / 0.35
	local invReach = 1 / reach
	local gripTarget = speed * Config.BladeGrip

	local dam = 1 + Config.BladeLoadDam * heavy
	local inwardPull = Config.BladeInwardPull * dam / halfLen

	local edgeLay = Config.BladeEdgeLay or 0
	local lookX = math.round(px * edgeLay / cell)
	local lookY = math.round(pz * edgeLay / cell)
	local lookOff = edgeLay > 0 and (lookX ~= 0 or lookY ~= 0)
	local gatherPull = Config.BladeGatherPull
	local thinLift = Config.BladeThinLift or 0

	local useRipple = Config.RippleNormal ~= 0
	local loTol = Config.CoatDepth * Config.SpreadTolLo
	local hiTol = Config.CoatDepth * Config.SpreadTolHi

	for y = y0, y1 do
		local rowBase = y * W
		local wz = self.originZ + (y + 0.5) * cell - cz
		for x = x0, x1 do
			local i = rowBase + x
			if buffer.readu8(mask, i) == 0 then continue end
			local wx = self.originX + (x + 0.5) * cell - cx

			local along = wx * ax + wz * az
			local aabs = if along < 0 then -along else along
			if aabs > alongLimit + gather then continue end
			local ahead = wx * px + wz * pz

			local edgeW = (alongLimit - aabs) * invTaper
			if edgeW > 1 then edgeW = 1 end

			local i4 = i * 4

			local atRim = false
			if lookOff and edgeW > 0 and ahead > 0.05 and ahead <= reach then
				local sx, sy = x + lookX, y + lookY
				atRim = sx < 0 or sx >= W or sy < 0 or sy >= H
					or buffer.readu8(mask, sy * W + sx) == 0
			end

			if edgeW > 0 and (atRim or (ahead <= 0.05 and ahead >= behindLimit)) then

				local s = edgeW * strength
				local loose = buffer.readf32(liq, i4)
				local laid = buffer.readf32(film, i4)
				local available = loose + laid

				local demand = keepDepth * (1 - buffer.readf32(sealedB, i4))
				local fullKeep = if available < demand then available else demand

				if thinLift > 0 and not atRim and fullKeep < demand then
					local short = 1 - fullKeep / demand
					fullKeep -= fullKeep * thinLift * short * short
				end

				local newFilm = laid + (fullKeep - laid) * s
				local newLoose = loose * (1 - s)
				carry += s * (available - fullKeep)

				buffer.writef32(film, i4, newFilm)
				buffer.writef32(liq, i4, newLoose)

				buffer.writef32(vxb, i4, buffer.readf32(vxb, i4) * 0.15)
				buffer.writef32(vyb, i4, buffer.readf32(vyb, i4) * 0.15)
				if useRipple then
					buffer.writef32(ripB, i4, buffer.readf32(ripB, i4) * 0.30)
					buffer.writef32(rvelB, i4, 0)
				end

				local g = buffer.readf32(glossB, i4) + 0.35 * edgeW
				buffer.writef32(glossB, i4, if g > 1 then 1 else g)

				if edgeW > 0.5 and available > 0.15 then
					touched += 1
					if newFilm >= loTol and newFilm <= hiTol then inTolerance += 1 end
				end

				nBehind += 1
				behindIdx[nBehind] = i4
				behindW[nBehind] = edgeW
				behindTotalW += edgeW

			elseif edgeW > 0 and ahead > 0.05 and ahead <= reach then
				local t = 1 - ahead * invReach
				do

					local w = t * t * edgeW
					if w > 0.01 then
						nFront += 1
						frontIdx[nFront] = i4
						frontW[nFront] = w
						frontTotalW += w
						frontVolume += buffer.readf32(liq, i4)

						local inward = -along * inwardPull
						local grip = Config.BladeGrip * w
						local vx = buffer.readf32(vxb, i4)
						local vy = buffer.readf32(vyb, i4)
						buffer.writef32(vxb, i4, vx + (px * gripTarget + ax * inward - vx) * grip)
						buffer.writef32(vyb, i4, vy + (pz * gripTarget + az * inward - vy) * grip)
					end
				end

			elseif edgeW <= 0 and ahead > -gatherBack and ahead <= reach then

				local fall = 1 - (aabs - alongLimit) / gather
				if fall > 0 then
					local tt = if ahead > 0 then 1 - ahead * invReach else 1 + ahead / gatherBack
					if tt > 0 then
						local w2 = tt * fall
						local inward = if along > 0 then -1 else 1
						local tx = px * gripTarget * 0.55 + ax * inward * gatherPull
						local tz = pz * gripTarget * 0.55 + az * inward * gatherPull
						local k = Config.BladeGrip * w2
						local vx = buffer.readf32(vxb, i4)
						local vy = buffer.readf32(vyb, i4)
						buffer.writef32(vxb, i4, vx + (tx - vx) * k)
						buffer.writef32(vyb, i4, vy + (tz - vy) * k)

						nTip += 1
						tipIdx[nTip] = i4
						tipW[nTip] = w2
						tipTotalW += w2
					end
				end
			end
		end
	end

	if nTip > 0 then

		local rate = Config.BladeGatherRate * dt
		if rate > 1 then rate = 1 end
		for n = 1, nTip do
			local i4 = tipIdx[n]
			local v = buffer.readf32(liq, i4)
			if v > 0.01 then
				local take = v * rate * tipW[n]
				buffer.writef32(liq, i4, v - take)
				carry += take
			end
		end
	end

	if carry > 0 and frontTotalW > 0 then
		local k = carry / frontTotalW
		for n = 1, nFront do
			local i4 = frontIdx[n]
			local add = frontW[n] * k
			buffer.writef32(liq, i4, buffer.readf32(liq, i4) + add)
			if useRipple then
				buffer.writef32(rvelB, i4, buffer.readf32(rvelB, i4) - add * 0.25)
			end
		end
	elseif carry > 0 and behindTotalW > 0 then

		local k = carry / behindTotalW
		for n = 1, nBehind do
			local i4 = behindIdx[n]
			buffer.writef32(liq, i4, buffer.readf32(liq, i4) + behindW[n] * k)
		end
		carry = 0
	end

	self.pile = (frontVolume + carry) * self.cellArea
	res.pile = self.pile
	res.resistance = math.min(1, self.pile / Config.PileRef)
	res.touched = touched
	res.spreadQuality = if touched > 0 then inTolerance / touched else 1
	res.x0, res.y0, res.x1, res.y1 = x0, y0, x1, y1

	self:WakeCellRect(x0, y0, x1, y1)
	return res
end

function SurfaceGrid:Coverage(): number
	local total = self.maskCount - self.paintCount
	if total <= 0 then return 0 end
	local frac = self.sealedFrac

	return if frac >= total then 1 else frac / total
end

function SurfaceGrid:MissedPatches(maxPatches: number?, nearX: number?, nearZ: number?)
	local W, H = self.W, self.H
	local mask, counted, paint = self.mask, self.counted, self.paint
	local film, sealed = self.film, self.sealed

	local missBar = Config.SealedThreshold * Config.MissedClearFrac
	local cell = self.cellSize
	local bs = math.max(2, math.floor(3.0 / cell + 0.5))
	local bw, bh = math.ceil(W / bs), math.ceil(H / bs)
	local nb = bw * bh

	local cnt = table.create(nb, 0)
	local sx, sy = table.create(nb, 0), table.create(nb, 0)
	local lox, hix = table.create(nb, 0), table.create(nb, 0)
	local loy, hiy = table.create(nb, 0), table.create(nb, 0)

	for y = 0, H - 1 do
		local rowBase = y * W
		local byBase = math.floor(y / bs) * bw
		for x = 0, W - 1 do
			local i = rowBase + x

			if buffer.readu8(mask, i) == 1 and buffer.readu8(counted, i) == 0
				and buffer.readu8(paint, i) == 0
				and buffer.readf32(film, i * 4) <= 0
				and buffer.readf32(sealed, i * 4) < missBar then
				local b = byBase + math.floor(x / bs) + 1
				local n = cnt[b]
				if n == 0 then
					lox[b], hix[b], loy[b], hiy[b] = x, x, y, y
				else
					if x < lox[b] then lox[b] = x elseif x > hix[b] then hix[b] = x end

					hiy[b] = y
				end
				cnt[b] = n + 1
				sx[b] += x
				sy[b] += y
			end
		end
	end

	local list = {}
	for b = 1, nb do
		local n = cnt[b]
		if n > 0 then
			local lx, lz = self:CellToWorld(sx[b] / n, sy[b] / n)
			list[#list + 1] = {

				id = b,
				x = lx, z = lz,
				area = n * self.cellArea,
				w = (hix[b] - lox[b] + 1) * cell,
				h = (hiy[b] - loy[b] + 1) * cell,
			}
		end
	end

	if nearX and nearZ then
		for _, p in ipairs(list) do
			local dx, dz = p.x - nearX, p.z - nearZ
			p.d = dx * dx + dz * dz
		end
		table.sort(list, function(a, b) return a.d < b.d end)
	else
		table.sort(list, function(a, b) return a.area > b.area end)
	end
	for i = #list, (maxPatches or 8) + 1, -1 do list[i] = nil end
	return list
end

function SurfaceGrid:LooseVolume(): (number, number?, number?)
	local liq, mask = self.liquid, self.mask
	local W = self.W
	local total = 0
	local deepest, deepestI = 0, -1
	for i = 0, W * self.H - 1 do
		if buffer.readu8(mask, i) == 1 then
			local v = buffer.readf32(liq, i * 4)
			total += v
			if v > deepest then deepest, deepestI = v, i end
		end
	end
	if deepestI < 0 then return total * self.cellArea, nil, nil end
	local lx, lz = self:CellToWorld(deepestI % W, math.floor(deepestI / W))
	return total * self.cellArea, lx, lz
end

function SurfaceGrid:SampleDepth(wx: number, wz: number): number
	local fx, fy = self:WorldToCell(wx, wz)
	local x, y = math.round(fx), math.round(fy)
	if x < 0 or y < 0 or x >= self.W or y >= self.H then return 0 end
	local i4 = (y * self.W + x) * 4
	return buffer.readf32(self.liquid, i4) + buffer.readf32(self.film, i4)
end

function SurfaceGrid:CountGaps(x0: number, y0: number, x1: number, y1: number): (number, number)
	local W, H = self.W, self.H
	x0 = math.max(1, x0); y0 = math.max(1, y0)
	x1 = math.min(W - 2, x1); y1 = math.min(H - 2, y1)
	local counted, mask = self.counted, self.mask
	local gaps, cells, sealed = 0, 0, 0
	for y = y0, y1 do
		local rowBase = y * W
		for x = x0, x1 do
			local i = rowBase + x
			if buffer.readu8(mask, i) == 1 then
				cells += 1
				if buffer.readu8(counted, i) == 1 then
					sealed += 1
				elseif buffer.readu8(counted, i - 1) == 1 and buffer.readu8(counted, i + 1) == 1
					and buffer.readu8(counted, i - W) == 1 and buffer.readu8(counted, i + W) == 1 then
					gaps += 1
				end
			end
		end
	end
	return gaps, (if cells > 0 then sealed / cells else 0)
end

function SurfaceGrid:Reset()
	for _, name in ipairs({"liquid", "film", "delta", "vx", "vy", "sealed", "stain", "wet", "gloss", "ripple", "rvel"}) do
		buffer.fill(self[name], 0, 0)
	end
	buffer.fill(self.counted, 0, 0)

	buffer.fill(self.slowT, 0, 0)
	self.sealedCount = 0
	self.sealedFrac = 0
	self.stainCount = 0
	self.loose = 0
	self.pile = 0

	self:MarkAllDirty()
end

function SurfaceGrid:FillSealed()
	for _, name in ipairs({"liquid", "film", "delta", "vx", "vy", "wet", "ripple", "rvel"}) do
		buffer.fill(self[name], 0, 0)
	end
	local mask, sealedB, glossB, counted = self.mask, self.sealed, self.gloss, self.counted
	local settle = Config.GlossSettle
	for i = 0, self.N - 1 do
		local on = buffer.readu8(mask, i) == 1
		buffer.writef32(sealedB, i * 4, if on then 1 else 0)
		buffer.writef32(glossB, i * 4, if on then settle else 0)
		buffer.writeu8(counted, i, if on then 1 else 0)
	end
	self.sealedCount = self.maskCount - self.paintCount
	self.sealedFrac = self.sealedCount
	self.loose = 0
	self.pile = 0

	self:MarkAllDirty()
end

local KEPT = { "liquid", "film", "sealed", "stain", "wet", "gloss" }

function SurfaceGrid:Snapshot()
	local snap = { W = self.W, H = self.H, cellSize = self.cellSize }
	local counted = buffer.create(self.N)
	buffer.copy(counted, 0, self.counted)
	snap.counted = counted
	for _, name in ipairs(KEPT) do
		local b = buffer.create(self.N * 4)
		buffer.copy(b, 0, self[name])
		snap[name] = b
	end
	return snap
end

function SurfaceGrid:Restore(snap): boolean
	if not snap then return false end
	if snap.W ~= self.W or snap.H ~= self.H or snap.cellSize ~= self.cellSize then
		return false
	end
	buffer.copy(self.counted, 0, snap.counted)
	for _, name in ipairs(KEPT) do
		buffer.copy(self[name], 0, snap[name])
	end

	local mask, paintB, counted = self.mask, self.paint, self.counted
	local sealedB, stainB = self.sealed, self.stain
	local liquidB, filmB = self.liquid, self.film
	local thresh = Config.SealedThreshold
	local invThresh = 1 / thresh
	local sealedCount, sealedFrac, stainCount = 0, 0, 0
	local looseSum, filmSum = 0, 0
	for i = 0, self.N - 1 do
		if buffer.readu8(mask, i) == 1 then
			local i4 = i * 4
			if buffer.readu8(paintB, i) == 0 then
				if buffer.readu8(counted, i) == 1 then sealedCount += 1 end
				local s = buffer.readf32(sealedB, i4)
				sealedFrac += if s >= thresh then 1 else s * invThresh
			end
			if buffer.readf32(stainB, i4) > 0 then stainCount += 1 end
			looseSum += buffer.readf32(liquidB, i4)
			filmSum += buffer.readf32(filmB, i4)
		end
	end
	self.sealedCount = sealedCount
	self.sealedFrac = sealedFrac
	self.stainCount = stainCount
	self.loose = looseSum * self.cellArea

	self.pile = 0

	self:MarkAllDirty()

	if looseSum > 0 or filmSum > 0 then self:WakeAll() end
	return true
end

return SurfaceGrid
