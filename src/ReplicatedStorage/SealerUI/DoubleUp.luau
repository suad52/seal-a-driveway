--!strict
--[[
	DoubleUp -- the second helping, sold at the moment the first one lands.

	Two things in this game pay a LUMP rather than a trickle: the Squeegee Battle,
	at the buzzer, and the AFK yard, when the player comes back to collect. Both
	end with a figure on the screen and a player looking at it, and that is the
	only moment this is offered -- pay the product and the same amount is paid
	again, once.

	DELIBERATELY NOT ON EVERY PAYOUT. A driveway pays every couple of minutes all
	session long, and an offer that followed each one would be the shop shouting
	over the game. Two moments a session at the outside is what keeps it an offer
	rather than a toll.

	WHY A DEVELOPER PRODUCT AND NOT A PASS

	The same reason Boosts gives: a pass can only be owned once, and the whole
	shape of this is buying it again the next time something pays out.

	It is also why the 2x Cash PASS is a different thing and has to stay one. That
	one doubles every payout forever and is priced against forever. This one
	doubles WHAT ACTUALLY LANDED -- the figure read back out of the wallet, pass
	and rebirth multiplier already folded in -- so the two compound instead of
	arguing about which of them applies. See Passes.cashMultiplier, which nothing
	here calls.

	WHAT CROSSES THE WIRE

	Not the amount, in either direction. The server records what it just paid, the
	client is TOLD the figure so it can draw it, and the only thing the client ever
	sends back is yes or no. A client that lies about the number is lying to its
	own screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Rebirth = require(script.Parent:WaitForChild("Rebirth"))

local DoubleUp = {}

--==[ WHAT IT IS ]============================================================

--[[
	The listing, and the listing's own name for itself.

	Same rule Boosts and Passes follow: Roblox's purchase dialog prints the
	product's real title beside whatever our card says, and two names for one
	purchase reads as having clicked the wrong thing. The site calls it "2x
	Reward"; so does the card.
]]
DoubleUp.ProductId = 3707904631
DoubleUp.Name = "2x Reward"

--[[
	The price is ASKED FOR at runtime and this is only the fallback.

	GetProductInfo is the authority -- a price changed on the Dashboard must not
	leave a card quoting last month's figure -- but it is a web call that can be
	slow or fail, and a card that says "... R$" while the player decides is worse
	than one that is briefly out of date. 20 is the listed price today.
]]
DoubleUp.Price = 20

--[[
	The cash awaiting a receipt, written on the Player before the dialog opens.

	This is the note the whole purchase hangs on, and it is an ATTRIBUTE rather
	than a table for one reason: it has to survive the session that made it.
	Roblox re-fires an ungranted receipt on the player's NEXT join, by which point
	an in-memory record is long gone -- so UpgradeService saves and restores this
	with the rest of the profile, exactly as it does its own PendingRobux note.

	Absent and zero mean the same thing here, and readers go through owedOf below
	rather than testing for nil, so neither spelling can be mistaken for a debt.
]]
DoubleUp.OwedAttr = "DoubleUpOwed"

--[[
	How long an offer stands.

	Long enough to read three lines and get through Roblox's own purchase dialog,
	short enough that it is unmistakably about the thing that just happened. It is
	enforced on the SERVER when the answer arrives; the countdown on the card is a
	drawing of this number, not the rule itself.
]]
DoubleUp.WindowSeconds = 45

--[[
	How long a NO is respected before this player is asked again.

	Declining is an answer, not a dismissal, and re-offering the same card thirty
	seconds later because another payout happened is how a reasonable prompt turns
	into nagging -- which costs more than the sale is worth. Owner's call,
	2026-08-14.

	PER PLAYER and not per source: the objection a player is expressing is to being
	asked at all, and a card that comes straight back with different words on it is
	the same interruption.

	It is deliberately SHORTER than the gap between events, so a player who says no
	to one duel is asked again after the next one rather than being written off for
	the session. Nothing else about the offer changes -- an expired card, a card
	they ignored, or a purchase they completed all leave this untouched, because
	none of those is somebody saying no.
]]
DoubleUp.DeclineCooldown = 30

--[[
	HOW LONG THE CARD WILL WAIT ON A PURCHASE BEFORE LETTING GO, and it exists
	because the card could otherwise trap a player on screen forever.

	Pressing DOUBLE IT hands the screen to Roblox's own purchase dialog. The card
	stays up underneath it -- deliberately, so somebody who cancels sees what they
	cancelled -- and it is taken down by the SERVER, on "paid" when the receipt
	lands or "closed" when PromptProductPurchaseFinished says the dialog shut.

	⚠ THAT EVENT DOES NOT ALWAYS FIRE. Measured 2026-08-14: prompting a product and
	closing the dialog left DoubleUpOwed still set at the full amount, so no "closed"
	was ever sent. Reported by a player as being stuck after backing out of the
	Robux window with too few Robux to buy.

	With no answer coming, the card sat under its own full-screen dim -- which is a
	button, and which eats every click -- and the player could not move, seal or
	leave. The one thing a purchase prompt must never do.

	So the card gives up on its own after this. Generous, because a real purchase
	can take a while (a Robux top-up is a whole flow of its own) and closing the
	card early on somebody who is mid-purchase would be its own small betrayal.
	Giving up is purely a CLIENT act: no answer is sent, nothing is cancelled, and a
	receipt that lands afterwards still pays through ProcessReceipt exactly as it
	would have.
]]
DoubleUp.PurchaseGrace = 90

--[[
	And how long the SERVER holds an unanswered note before writing it off.

	The same missing event leaves DoubleUpOwed set, and that attribute is saved with
	the profile -- so a note stranded once refuses every future offer for that
	account forever, silently. The note over OwedAttr calls that failure out; this is
	what stops it being permanent.

	WELL PAST any real purchase, because the risk runs the other way too: a receipt
	that lands after the note is gone is HELD rather than granted (see the note over
	`spend`), so Roblox keeps asking and the player is not charged twice -- but they
	are not paid on time either. Five minutes is far longer than a purchase that is
	actually going to complete while the player is still in the server, and far
	shorter than "never".

	It does not touch the case the persistence was built for: a player who
	disconnects mid-purchase is gone, and this only ever runs for somebody still
	here.
]]
DoubleUp.NoteGrace = 300

--[[
	Too small to be worth asking about, and it rides the rebirth curve like
	everything else that touches this wallet.

	A flat floor would stop meaning anything by rebirth three, when every figure in
	the game is a hundred times bigger. So the test is against what a thousand is
	WORTH to this player: about a fifth of a Maple driveway at rebirth zero, and
	about a fifth of one at rebirth twelve as well.

	What it gates, at rebirth zero: an AFK visit under three and a half minutes,
	and the bottom half of a battle scoreboard (fourth through eighth place is 600
	plus the show-up bonus). Both of those are real rewards and neither is worth 20
	Robux -- offering it there would read as the game trying it on, which costs
	more than the sale is worth.
]]
DoubleUp.MinBase = 1000

function DoubleUp.minimumFor(plr: Player?): number
	return DoubleUp.MinBase * Rebirth.multiplierOf(plr)
end

function DoubleUp.worthOffering(plr: Player?, amount: number): boolean
	return amount >= DoubleUp.minimumFor(plr)
end

-- The one reader of the note. Answers a number always, so no caller has to know
-- whether "nothing owed" was spelled nil or 0.
function DoubleUp.owedOf(plr: Player?): number
	if not plr then return 0 end
	local n = (plr :: Player):GetAttribute(DoubleUp.OwedAttr)
	if type(n) ~= "number" then return 0 end
	return if n > 0 then math.floor(n) else 0
end

--==[ WHERE IT IS OFFERED ]===================================================

--[[
	The two moments, and the words each one gets.

	Held here rather than in the client because the SERVER picks which of them
	applies -- it is the only side that knows what just paid out -- and a client
	that chose its own wording could put the battle's title over the yard's money.
	The client is sent the key and looks it up.
]]
export type Source = {
	title: string,
	-- one %s, which is the figure already earned
	what: string,
}

local Sources: { [string]: Source } = {
	battle = {
		title = "DOUBLE YOUR WINNINGS?",
		what = "You took $%s out of the Squeegee Battle.",
	},
	-- Its own entry rather than sharing the battle's, even though the words are
	-- nearly the same: the card is shown seconds after a results screen that named
	-- the event, and a player who has just raced being told what they took out of
	-- the Squeegee Battle would read as the game having lost track of what they did.
	race = {
		title = "DOUBLE YOUR WINNINGS?",
		what = "You took $%s out of the Driveway Race.",
	},
	afk = {
		title = "DOUBLE YOUR EARNINGS?",
		what = "Your crew earned $%s while you were away.",
	},
	--[[
		Its own entry for the reason the race has one: the card lands seconds after a
		summary that named the thing they just did, and a player who has just won a
		duel being told what they took out of the Squeegee Battle would read as the
		game having lost track.

		"WON" rather than "took", because a duel purse is a prize rather than wages --
		it is the one payout in the game with a loser attached to it.
	]]
	duel = {
		title = "DOUBLE YOUR PRIZE?",
		what = "You won $%s off your opponent.",
	},
}
for _, s in pairs(Sources) do table.freeze(s) end
DoubleUp.Sources = table.freeze(Sources)

--==[ THE WIRE ]==============================================================

--[[
	Two remotes in the shell's own folder, built by the server and waited on by
	the client -- the ordering BattleNet spells out, and for the same reason: a
	client that got here first would otherwise build its own orphan copies in
	ReplicatedStorage and fire them at nobody.

	  DoubleOffer   server -> one player. Every message this feature sends down
	                carries a `state`, so the card has one handler rather than four
	                remotes to keep in step.
	  DoubleAnswer  client -> server. "yes" or "no", and nothing else is read.
]]
local FOLDER = "Remotes"
local NAMES = table.freeze({ "DoubleOffer", "DoubleAnswer" })

local cache: { [string]: RemoteEvent }? = nil

function DoubleUp.remotes(): { [string]: RemoteEvent }
	if cache then return cache end

	local ui = ReplicatedStorage:WaitForChild("SealerUI")
	local out: { [string]: RemoteEvent } = {}

	if RunService:IsServer() then
		-- UpgradeService builds this folder too, and whichever of us runs first is
		-- fine: both look before making one.
		local folder = ui:FindFirstChild(FOLDER)
		if not folder then
			folder = Instance.new("Folder")
			;(folder :: Folder).Name = FOLDER
			;(folder :: Folder).Parent = ui
		end
		for _, name in ipairs(NAMES) do
			local r = folder:FindFirstChild(name)
			if not r then
				r = Instance.new("RemoteEvent")
				;(r :: RemoteEvent).Name = name
				;(r :: RemoteEvent).Parent = folder
			end
			out[name] = r :: RemoteEvent
		end
	else
		local folder = ui:WaitForChild(FOLDER, 30)
		if not folder then
			error("[DoubleUp] the server never published " .. FOLDER, 2)
		end
		for _, name in ipairs(NAMES) do
			out[name] = folder:WaitForChild(name, 30) :: RemoteEvent
		end
	end

	cache = out
	return out
end

return DoubleUp
