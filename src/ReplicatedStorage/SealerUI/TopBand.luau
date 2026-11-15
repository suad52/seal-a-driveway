--!strict
--[[
	TopBand -- who stands along the top of the screen, and where.

	SIX WIDGETS EACH DECIDED THEY OWNED THIS STRIP, and every one of them wrote
	down the same correct reasoning for it: the address and the job meter are top
	left, the rail is right, the wallet and the hotbar are along the bottom, so the
	top middle is the only place a HUD element can stand without covering
	something the player is already reading. All six then hard-coded a y of 10, 12,
	14 or 24 and an anchor of (0.5, 0), which is the same place.

		MatchHud    360x320 at 10   BattleUI
		Ticker      280x70  at 12   BattleUI
		Countdown   330x48  at 12   GoldenHourClient
		CashTally   300x46  at 12   Shell
		Card        380x172 at 14   AfkClient
		Toasts      560 wide at 24  Shell

	Some pairs are mutually exclusive by construction and were fine -- the ticker
	hides when a match starts, and the Golden Hour bar and the ticker can never be
	up together because one schedule runs both events. The pairs that are NOT
	exclusive simply drew on top of each other, in whatever order their ScreenGui
	DisplayOrders happened to give: the event ticker sat across the AFK card's
	title, and toasts arrived underneath the ticker with its badge over the middle
	of the sentence.

	GoldenHourClient's own note called this out and left it -- "that overlap is
	real, but it is not new and it is not this file's ... the two are therefore
	wrong together or right together, which is the better way round for whoever
	comes to fix it". This is that fix, and it is right together: the strip has one
	owner, everybody registers, and what is on screen is stacked down it in a fixed
	order. Nothing has to know what else exists.

	WHY A STACK RATHER THAN PRIORITY-AND-HIDE. Hiding the loser is the other
	answer and it is worse in both directions: hide the ticker under the AFK card
	and a player who went idle can no longer see when the next event lands, which
	is exactly the thing they would come back for; hide the AFK card and the
	visit's own readout and its way out disappear. Everything in this list is small
	and the strip is wide, so there is room to show them all.
]]

local RunService = game:GetService("RunService")

local UIKit = require(script.Parent:WaitForChild("UIKit"))

local TopBand = {}

--[[
	Where the strip starts, and the space between blocks.

	12 by convention rather than by measurement -- the area header sits at 10, and
	the cash tally and the event ticker were both written to 12 by different people
	on different days, which is as close to a convention as this HUD has. The gap is
	enough that two stacked cards read as two cards rather than as one tall one.
]]
local TOP = 12
local GAP = 8

--[[
	The order down the strip, and it is a judgement rather than an arbitrary list.

	The rule is HOW LONG IT WILL BE THERE, longest first, so that the block a
	player's eye has learned to find does not move when something transient turns
	up underneath it. The tutorial card and the match bar own the screen for as
	long as they are up; the ticker and the Golden Hour bar stand for whole
	minutes; the AFK card stands for a visit; the tally and toasts are seconds.

	Gaps of ten so a seventh widget can be slotted between two of these without
	renumbering anything.
]]
TopBand.Rank = table.freeze({
	Tutorial   = 5,
	MatchHud   = 10,
	Ticker     = 20,
	GoldenHour = 30,
	Afk        = 40,
	Tally      = 50,
	Toasts     = 90,
})

--[[
	Height is DECLARED, not measured off AbsoluteSize, and that is deliberate.

	Half of these widgets animate in on a UIScale -- the ticker opens from 0.001 --
	and one of them pulses a second UIScale once a second. AbsoluteSize follows all
	of that, so a measured stack would slide every block below the ticker down its
	own height over the reveal tween and jitter with the pulse for the rest of the
	gap. The layout wants the space a widget OCCUPIES, which is its design size, not
	the size it happens to be drawn at on this frame.

	A number is a fixed height in pixels. A function is passed the current window
	fit and returns pixels, which is what the widgets that shrink with the window
	use -- each one knows whether it does, and none of them agree, so asking is
	safer than assuming.
]]
type Height = number | (number) -> number

type Claim = {
	name: string,
	rank: number,
	frame: GuiObject,
	height: Height,
	conns: { RBXScriptConnection },
}

local claims: { Claim } = {}

--[[
	A block that places ITSELF and only wants to be stacked around.

	The tutorial card is the one of these. It already computes its own y every time
	its contents change, clamping upward against the hotbar so a card too tall for
	the space covers the area title rather than the tool keys -- a rule this file
	has no way to know and no business duplicating. So it reports where it ENDS and
	everything else starts below that.
]]
local reserves: { { name: string, bottom: () -> number? } } = {}

local fit = 1
local pending = false

local function heightOf(c: Claim): number
	local h = c.height
	if type(h) == "function" then return h(fit) end
	return h
end

local function layout()
	pending = false

	--[[
		Dropped when the widget is, rather than on being asked.

		The AFK card is built fresh for each visit and destroyed with its ScreenGui
		on the way out, so a claim that had to be released by hand would leak one dead
		entry per visit and hold that entry's height against everything below it --
		a strip that creeps further down the screen the longer somebody plays. Every
		claim watches its own AncestryChanged, so a destroyed widget both triggers a
		layout and is swept here on the way through it.
	]]
	for i = #claims, 1, -1 do
		local c = claims[i]
		if not c.frame:IsDescendantOf(game) then
			for _, cn in ipairs(c.conns) do cn:Disconnect() end
			table.remove(claims, i)
		end
	end

	local y = TOP
	for _, r in ipairs(reserves) do
		local b = r.bottom()
		if b and b + GAP > y then y = b + GAP end
	end

	for _, c in ipairs(claims) do
		-- An invisible block takes no space. That is the whole reason the exclusive
		-- pairs cost nothing: the ticker hides when a match starts, so the match bar
		-- takes the top of the strip rather than a slot under an empty one.
		if c.frame.Visible then
			local at = math.round(y)
			-- guarded, because a Position write on an unchanged value still dirties the
			-- widget, and a fit change touches every block at once
			if c.frame.Position.Y.Offset ~= at or c.frame.Position.X.Scale ~= 0.5 then
				c.frame.Position = UDim2.new(0.5, 0, 0, at)
			end
			y += heightOf(c) + GAP
		end
	end
end

--[[
	Deferred and coalesced.

	A window resize calls every registered fit hook in turn and several of those
	are blocks in this strip, so an immediate re-layout would run the whole list
	once per block for one resize. Deferring also means a caller can claim, show
	and size a widget in one breath and be laid out once, after all of it.
]]
local function refresh()
	if pending then return end
	pending = true
	task.defer(layout)
end
TopBand.refresh = refresh

--[[
	Take a slot. The frame is positioned by this file from now on, so whatever it
	was built with is overwritten -- keep the design y in the source anyway, as
	documentation of where the widget expects to be when it is the only one up.

	Showing and hiding stay the caller's: this watches Visible rather than offering
	a show/hide of its own, so nothing about how a widget appears has to change to
	join the strip.
]]
function TopBand.claim(name: string, rank: number, frame: GuiObject, height: Height)
	-- There is no window on the server, and a module that quietly hooks a camera
	-- is a nasty thing to inherit -- same guard, same reason, as UIKit.onFit.
	if not RunService:IsClient() then return end

	local c: Claim = {
		name = name, rank = rank, frame = frame, height = height, conns = {},
	}
	table.insert(c.conns, frame:GetPropertyChangedSignal("Visible"):Connect(refresh))
	table.insert(c.conns, frame.AncestryChanged:Connect(refresh))
	claims[#claims + 1] = c
	table.sort(claims, function(a, b) return a.rank < b.rank end)
	refresh()
end

-- Reserve the top of the strip without being placed by it. `bottom` answers the
-- y this widget ends at, or nil when it is not on screen. Call TopBand.refresh()
-- whenever that answer changes.
function TopBand.reserve(name: string, bottom: () -> number?)
	if not RunService:IsClient() then return end
	reserves[#reserves + 1] = { name = name, bottom = bottom }
	refresh()
end

-- The strip shrinks with the window like everything else in it does; the fit is
-- read here so the blocks that scale can be asked for their height in real
-- pixels. onFit fires immediately, so `fit` is right before the first claim.
UIKit.onFit(function(f)
	fit = f
	refresh()
end)

return TopBand
