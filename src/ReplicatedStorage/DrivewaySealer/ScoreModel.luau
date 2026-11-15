--!strict
--[[
	Scoring. A "stroke" is one continuous squeegee engagement -- from pressing
	the button to letting go, or to standing still long enough that the pass has
	clearly ended. Bonuses are judged per stroke, which is the unit the player
	actually feels.
]]

local Players = game:GetService("Players")
local Config = require(script.Parent.Config)
-- What the ground is worth. Bonuses are priced off it too, so a careful pass on
-- an estate drive is worth what an estate drive is worth.
local Economy = require(script.Parent.Economy)
-- Rebirths multiply the payout, and the HUD has to show the figure the
-- server is going to pay. multiplierOf takes a nil player and answers 1, so
-- this stays harmless if the module is ever required somewhere with no local
-- player -- see the note on it.
local Rebirth = require(game:GetService("ReplicatedStorage")
	:WaitForChild("SealerUI"):WaitForChild("Rebirth"))
-- Passes multiply the pay too, and a premium contract multiplies it again. Both
-- have to be in the HUD's figure or it advertises the wrong number.
local Passes = require(game:GetService("ReplicatedStorage")
	:WaitForChild("SealerUI"):WaitForChild("Passes"))
local Lucky = require(script.Parent.Lucky)
-- And the server-wide 3x window multiplies it again, for everyone at once. It is
-- read from the replicated flag rather than from a remote this file listened to,
-- so a player who joined mid-window draws the same figure as everybody else.
local GoldenHour = require(game:GetService("ReplicatedStorage")
	:WaitForChild("SealerUI"):WaitForChild("GoldenHour"))
-- +15% Cash per friend on the same server. Kept in step with DrivewayServer's
-- payMultiplier so the HUD advertises what the wallet gets.
local FriendBonus = require(game:GetService("ReplicatedStorage")
	:WaitForChild("SealerUI"):WaitForChild("FriendBonus"))

local ScoreModel = {}
ScoreModel.__index = ScoreModel

function ScoreModel.new(surface)
	return setmetatable({
		surface = surface,
		combo = 1,
		comboTimer = 0,
		bonusTotal = 0,
		stroke = nil,
		listeners = {},
	}, ScoreModel)
end

function ScoreModel:OnBonus(fn: (string, number, number) -> ())
	table.insert(self.listeners, fn)
end

--[[
	How much ground a stroke covered, in square studs.

	The swept rectangle -- distance pushed times the width of the rubber -- rather
	than `touched`, which counts CELLS PER FRAME and so scores a slow pass over
	the same ground many times over. Blade width is read live because the Squeegee
	Length track mutates it on this client, so a wider blade earns proportionally
	more for the same walk, which is exactly what the player paid for.
]]
function ScoreModel:_strokeArea(s): number
	return s.length * Config.BladeHalfLen * 2
end

-- Bonuses are a share of the work, so `pct` is turned into cash here against the
-- slab's own rate before anything sees it.
function ScoreModel:_tip(label: string, pct: number, area: number, combo: number?)
	local cash = pct * area * Economy.studRate(self.surface.slab) * (combo or self.combo)
	if cash < 1 then return end
	self:_fire(label, math.floor(cash), combo)
end

function ScoreModel:_fire(label: string, amount: number, combo: number?)
	self.bonusTotal += amount
	local shown = combo or self.combo
	for _, fn in ipairs(self.listeners) do
		task.spawn(fn, label, amount, shown)
	end
end

function ScoreModel:BeginStroke(worldPos: Vector3)
	self.stroke = {
		origin = worldPos,
		length = 0,
		touched = 0,
		qualitySum = 0,
		qualityN = 0,
		minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge,
	}
end

-- Called every frame the blade is engaged.
function ScoreModel:Accumulate(result, travel: number, cellRect: { number }?)
	local s = self.stroke
	if not s then return end
	s.length += travel
	if result.touched > 0 then
		s.touched += result.touched
		s.qualitySum += result.spreadQuality * result.touched
		s.qualityN += result.touched
	end
	if cellRect then
		if cellRect[1] < s.minX then s.minX = cellRect[1] end
		if cellRect[2] < s.minY then s.minY = cellRect[2] end
		if cellRect[3] > s.maxX then s.maxX = cellRect[3] end
		if cellRect[4] > s.maxY then s.maxY = cellRect[4] end
	end
end

function ScoreModel:EndStroke()
	local s = self.stroke
	self.stroke = nil
	if not s or s.touched < Config.StrokeMinCells then return end

	local quality = if s.qualityN > 0 then s.qualitySum / s.qualityN else 0
	local area = self:_strokeArea(s)
	local earned = false

	if quality >= Config.PerfectSpreadMin then
		self:_tip("Perfect Spread", Economy.TipPerfect, area)
		earned = true
	end

	if s.length >= Config.SmoothSpreadLen and quality >= 0.70 then
		self:_tip("Large Smooth Spread", Economy.TipSmooth, area)
		earned = true
	end

	--[[
		Holidays are judged on a delay. The coat this pass just laid has not
		cured yet, so checking immediately would find no sealed cells at all and
		hand out the bonus for free. Waiting until the film has set is also more
		honest to the player: the spot either closed up or it did not.

		This award deliberately does not feed the combo -- it resolves after the
		stroke has already been scored, and retroactively bumping the multiplier
		would be impossible to read.
	]]
	if s.minX < math.huge and quality >= 0.60 then
		local combo = self.combo
		local x0, y0, x1, y1 = s.minX, s.minY, s.maxX, s.maxY
		task.delay(2.6, function()
			local gaps, sealedFrac = self.surface.grid:CountGaps(x0, y0, x1, y1)
			if gaps == 0 and sealedFrac >= 0.80 then
				self:_tip("No Missed Spots", Economy.TipNoMissed, area, combo)
			end
		end)
	end

	if earned then
		self.combo = math.min(Config.ComboMax, self.combo + 1)
		self.comboTimer = Config.ComboWindow
	else
		-- a weak pass does not break the chain, it just does not extend it
		self.comboTimer = math.min(self.comboTimer, Config.ComboWindow * 0.5)
	end
end

function ScoreModel:Update(dt: number)
	if self.combo > 1 then
		self.comboTimer -= dt
		if self.comboTimer <= 0 then
			self.combo = 1
		end
	end
end

-- A share of the whole job rather than of one stroke, because that is what it
-- is for: finishing. Deliberately not multiplied by the combo -- it would reward
-- whatever happened to be in flight as the last percent landed.
function ScoreModel:AwardCompletion()
	local cash = Economy.TipCompletion * Economy.jobBase(self.surface.slab)
	self:_fire("Driveway Complete", math.floor(cash), 1)
end

--[[
	Everything that multiplies this player's pay on this slab.

	⚠ KEEP IN STEP WITH DrivewayServer's DrivewayComplete handler, which computes
	the same product for the money that actually lands. The two are separate on
	purpose -- one is a client drawing a number, the other is the server paying it,
	and the server must not take the client's word for it -- but if they ever
	disagree the HUD is lying about a payout, which is the one bug in this file
	worth being paranoid about.
]]
function ScoreModel:multiplier(): number
	local plr = Players.LocalPlayer
	return Rebirth.multiplierOf(plr)
		* Passes.cashMultiplier(plr)
		* Lucky.multiplierFor(plr, self.surface.slab)
		-- Handed the player: the 3x window is server-wide but it does not reach a
		-- player who is still in the tutorial, and this figure has to be the one
		-- DrivewayServer is about to pay. See GoldenHour.appliesTo.
		* GoldenHour.cashMultiplier(plr)
		* FriendBonus.multiplierOf(plr)
end

function ScoreModel:Value(): number
	-- One formula, shared with DrivewayServer, so the figure the player watches
	-- climb is the figure that lands in their wallet.
	return Economy.payout(self.surface.slab, self.surface:Coverage(), self.bonusTotal,
		self:multiplier())
end

-- Wound back by a rebirth: the running total belongs to a driveway that is bare
-- concrete again.
function ScoreModel:Reset()
	self.bonusTotal = 0
	self.combo = 1
	self.comboTimer = 0
	self.stroke = nil
end

return ScoreModel
