--!strict
--[[
	Boosts -- the things you buy by the minute rather than for good.

	A game pass is a fact about an account and Roblox remembers it. A boost is a
	DEADLINE, and nobody remembers it but us -- which is the whole reason this is
	a second file rather than a flag in Passes. That one asks Roblox a yes/no
	question once a join and mirrors the answer onto the Player; this one holds a
	timestamp, and a timestamp has to be written, saved and re-read.

	  Boost_EndlessUntil   the server time the boost stops working

	AN ABSOLUTE DEADLINE, NOT A COUNTDOWN, and that is what makes it cheap. There
	is no ticking thread anywhere, nothing to pause while a profile loads, nothing
	to re-send when a player walks out of range and nothing to correct after a lag
	spike: every reader compares the same number against the same clock and gets
	the same answer.

	⚠ The clock is `Workspace:GetServerTimeNow()`, NOT `os.clock()` or `tick()`.
	GetServerTimeNow is the one reading that is identical on the server and on
	every client, which is exactly what a deadline crossing the wire needs. See
	the same warning over BattleConfig.NextAtAttr, which learned it the hard way.

	Written by UpgradeService -- the only place a receipt becomes time -- and it
	rides in the profile with everything else, because five minutes bought thirty
	seconds before a server restart is five minutes the player paid for.
]]

local Workspace = game:GetService("Workspace")

local Boosts = {}

export type Boost = {
	-- our own name for it, and the attribute stem; never the product id, which
	-- can be re-created on the Dashboard while the thing it buys does not change
	id: string,
	-- what Roblox knows it as. A DEVELOPER PRODUCT rather than a game pass: a
	-- pass can only be owned once, and the whole shape of this is buying another
	-- five minutes when the last five run out.
	productId: number,
	name: string,
	blurb: string,
	short: string,
	seconds: number,
}

local List: { Boost } = {
	{
		id = "Endless",
		productId = 3707797397,
		--[[
			The listing's own words, because Roblox's purchase dialog prints them beside
			whatever the card says and two names for one purchase reads as having
			clicked the wrong thing. Same rule Passes follows for Instant Refill, 2x
			Cash and the Squeegee Attachment.

			The title on the site is "Instant Coat [5 Minutes OP]" and the bracket is
			dropped. It is the one liberty taken: the name label on a shop card is 320px
			at a 1280-wide window and a TextLabel does not clip to its own size, so the
			full title runs out over the badge. What the bracket says is on the card
			twice over anyway -- the ribbon reads 5 MINUTES and the badge reads 5 MIN.
		]]
		name = "Instant Coat",
		--[[
			Held to the length the shop's other blurbs are held to: three wrapped lines
			in a 48px box at a 1280-wide window. A TextLabel does not clip to its own
			size, so a fourth line does not truncate, it spills out of the card -- see
			the note on the VIP blurb in Passes, which is where that was measured.
		]]
		blurb = "Five minutes of a squeegee that never runs dry -- the blade lays"
			.. " its own sealer as it sweeps. No pail, no pump, just paint.",
		-- What the corner of the screen calls it while it is running. The card has
		-- room for the listing's name; a 32px stat row beside a live clock does not.
		short = "Instant Coat",
		seconds = 5 * 60,
	},
}

local ById: { [string]: Boost } = {}
local ByProduct: { [number]: Boost } = {}
for _, b in ipairs(List) do
	ById[b.id] = b
	ByProduct[b.productId] = b
end

Boosts.List = List
Boosts.ById = ById

function Boosts.attrName(id: string): string
	return "Boost_" .. id .. "Until"
end

-- Which boost a receipt is for. Nil is the honest answer for anything else --
-- the shop sells one developer product of its own as well, and UpgradeService
-- uses this to tell the two apart.
function Boosts.byProduct(productId: number): Boost?
	return ByProduct[productId]
end

function Boosts.now(): number
	return Workspace:GetServerTimeNow()
end

--[[
	The question everything else asks, and it answers in SECONDS rather than in
	yes/no because almost every caller wants the number as well.

	Clamped at zero rather than going negative: an expired deadline and one that
	was never set have to read as the same thing, or the countdown on the HUD
	counts up through nothing after the boost lapses. Never sticky -- there is no
	"it ran out" event anywhere in the game, and there does not need to be, since
	the frame after the deadline this returns 0 on its own.
]]
function Boosts.secondsLeft(plr: Player?, id: string): number
	if not plr then return 0 end
	local until_ = plr:GetAttribute(Boosts.attrName(id))
	if type(until_) ~= "number" then return 0 end
	local left = until_ - Workspace:GetServerTimeNow()
	return if left > 0 then left else 0
end

function Boosts.active(plr: Player?, id: string): boolean
	return Boosts.secondsLeft(plr, id) > 0
end

-- m:ss, which is what a five minute purchase wants; the hour case cannot arise
-- from one product but stacking a dozen of them can, so it is not assumed away.
function Boosts.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	local h = s // 3600
	if h > 0 then
		return ("%d:%02d:%02d"):format(h, (s % 3600) // 60, s % 60)
	end
	return ("%d:%02d"):format(s // 60, s % 60)
end

return Boosts
