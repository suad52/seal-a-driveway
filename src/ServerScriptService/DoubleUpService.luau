--!strict
--[[
	DoubleUpService -- who has been offered the second helping, and paying it.

	Three files talk to this and none of them talk to each other:

	  SqueegeeBattleServer   offer(plr, winnings, "battle")  once the match is over
	  AfkService             offer(plr, earned, "afk")       once the visit is over
	  UpgradeService         grant(plr)                      once the receipt lands

	A MODULE RATHER THAN A SCRIPT, AND RATHER THAN A BUS

	The yard and the arena reach each other through AfkBus because they are two
	large systems that must not require each other. This is the opposite shape: it
	is a small file that requires nothing of theirs, so there is no cycle to break
	and a bus would only be an extra hop to read through. Its remote handler is
	connected on first require, and all three of its callers require it at server
	start, so it is live before anything can pay anybody.

	THE NOTE GOES DOWN BEFORE THE DIALOG GOES UP

	The amount is written onto the Player -- and pushed straight to the store --
	before PromptProductPurchase is called, never after. That is the same rule
	UpgradeService follows for its own product and it covers the same gap: the
	seconds a player spends looking at a Robux dialog are seconds the server can
	die in, and a receipt for a purchase we no longer have a figure for is one
	Roblox will re-ask about on their next join.

	WHAT A CLIENT CAN DO HERE

	Say yes, and say no. The figure, whether there is an offer at all, and whether
	it has expired are all read from this side; the remote carries no numbers in.
	The worst a tampered client manages is opening a purchase dialog for an offer
	it was already given.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DoubleUp = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("DoubleUp"))

local Service = {}

local Remotes = DoubleUp.remotes()
local Offer = Remotes.DoubleOffer
local Answer = Remotes.DoubleAnswer

--==[ THE MONEY ]=============================================================

local function cashOf(plr: Player): IntValue?
	local ls = plr:FindFirstChild("leaderstats")
	local cash = ls and ls:FindFirstChild("Cash")
	return (cash and cash:IsA("IntValue")) and cash or nil
end

--[[
	Pay, and move Q_Earned with it.

	Q_Earned is the lifetime counter the quest board and the TOP EARNERS
	leaderboard run on, and every other payout in the game moves it -- the
	driveways, the arena, the yard. This is cash landing in the same wallet by the
	same rules, so leaving it out would make the board disagree with the balance,
	which Leaderboards says must never happen.

	Answers what actually landed, and zero is a real answer: a player whose
	leaderstats have not been built yet cannot be paid, and the caller has to know
	that rather than assume it worked. See grant, which holds the receipt on a zero
	rather than pocketing it.
]]
local function pay(plr: Player, amount: number): number
	if amount <= 0 then return 0 end
	local cash = cashOf(plr)
	if not cash then
		warn(("[DoubleUp] %s has no cash leaderstat -- %d not paid")
			:format(plr.Name, amount))
		return 0
	end
	cash.Value += amount
	plr:SetAttribute("Q_Earned", ((plr:GetAttribute("Q_Earned") :: number?) or 0) + amount)
	return amount
end

--==[ THE PROFILE ]===========================================================

--[[
	How the note reaches the DataStore without this file knowing there is one.

	UpgradeService owns the profile and hands its own save in at startup. Optional
	on purpose: without it the note still rides out on the ordinary autosave and on
	PlayerRemoving, so the only case that degrades is a server dying inside the few
	seconds a purchase dialog is open.
]]
local saveNow: ((Player) -> ())? = nil

function Service.provideSave(fn: (Player) -> ())
	saveNow = fn
end

local function noteDown(plr: Player, amount: number)
	plr:SetAttribute(DoubleUp.OwedAttr, amount)
	local fn = saveNow
	if not fn then return end
	-- Spawned so the Robux dialog is not held behind a DataStore round trip. It
	-- has the length of the purchase to land in, and the receipt cannot arrive
	-- before the player has clicked.
	task.spawn(function()
		local ok, err = pcall(fn, plr)
		if not ok then
			warn("[DoubleUp] could not write the note for " .. plr.Name .. ": " .. tostring(err))
		end
	end)
end

--==[ WHO HAS BEEN ASKED ]====================================================

type Live = {
	amount: number,
	source: string,
	expires: number,
	-- rate-limits the answer remote; there is nothing to gain from spamming it,
	-- but a remote that opens a purchase dialog is not one to leave uncapped
	last: number,
}

local live: { [Player]: Live } = {}

--[[
	When each player last said NO, so they are not asked again straight away.

	Keyed by UserId rather than by Player: a Player instance is replaced on every
	join, and a table keyed on it would hand somebody a fresh card for the price of
	a reconnect -- which is exactly the nagging the cooldown exists to stop. Cleared
	on PlayerRemoving would defeat the same thing, so it is not.
]]
local declinedAt: { [number]: number } = {}

--[[
	Put the offer up.

	Silent to the PLAYER about every refusal, and each one is a case where showing
	the card would be worse than not: an amount below what the product is worth
	(see DoubleUp.MinBase), a source this file does not have words for, a recent
	no, and -- the one that matters -- a purchase already in flight. That last one
	is what stops a second offer overwriting the note the first one is waiting on,
	which would pay one amount for the other's receipt.

	IT ANSWERS THE CALLER, THOUGH, and that is the change worth knowing about.

	Returns (shown, why). Every refusal above is invisible from outside, which is
	fine while the answer is always "the reward was too small" -- and is not fine
	the moment a caller has several ways to end up here. A duel win that produced no
	card is indistinguishable from a broken feature unless something says which of
	five rules turned it away; that is precisely the silence DrivewayServer's own
	turned-away-completion warning exists to break.

	No existing caller has to change: they all ignore the returns and behave exactly
	as before.
]]
function Service.offer(plr: Player, amount: number, source: string): (boolean, string?)
	if not plr.Parent then return false, "they have left" end
	if not DoubleUp.Sources[source] then
		warn("[DoubleUp] no such source: " .. tostring(source))
		return false, "no such source: " .. tostring(source)
	end

	amount = math.floor(amount)
	if amount < 1 then return false, "nothing was paid" end
	if not DoubleUp.worthOffering(plr, amount) then
		return false, ("%d is under the %d minimum for this player")
			:format(amount, DoubleUp.minimumFor(plr))
	end
	if DoubleUp.owedOf(plr) > 0 then
		return false, "they already owe an unanswered purchase"
	end

	-- They said no recently, and a no is an answer. See DoubleUp.DeclineCooldown.
	local since = os.clock() - (declinedAt[plr.UserId] or -math.huge)
	if since < DoubleUp.DeclineCooldown then
		return false, ("they declined %ds ago (cooldown %ds)")
			:format(math.floor(since), DoubleUp.DeclineCooldown)
	end

	live[plr] = {
		amount = amount,
		source = source,
		expires = os.clock() + DoubleUp.WindowSeconds,
		last = 0,
	}
	Offer:FireClient(plr, {
		state = "offer",
		amount = amount,
		source = source,
		seconds = DoubleUp.WindowSeconds,
	})
	return true, nil
end

--==[ THE ANSWER ]============================================================

Answer.OnServerEvent:Connect(function(plr, action)
	local o = live[plr]
	-- No offer outstanding is the ordinary case for a stray fire, and there is
	-- nothing to say about it.
	if not o then return end

	local now = os.clock()
	if now - o.last < 0.35 then return end
	o.last = now

	--[[
		A CARD THAT RAN OUT IS NOT A DECLINE, and the two arrive here separately for
		that reason alone.

		The client sends "lapsed" when its countdown finishes with nobody having
		pressed anything. Both clear the offer -- the card goes away either way -- but
		only the deliberate no starts DoubleUp.DeclineCooldown. A player who was busy
		when the card appeared has not said no to anything, and silencing their next
		offer would punish them for not looking.
	]]
	if action == "lapsed" then
		live[plr] = nil
		return
	end

	if action == "no" then
		live[plr] = nil
		-- Stamped only on a deliberate press of No thanks. A lapsed card, a superseded
		-- one and a completed purchase are all different answers, and none of them
		-- starts this.
		declinedAt[plr.UserId] = now
		return
	end
	if action ~= "yes" then return end

	--[[
		The window is enforced HERE and drawn on the card, not the other way round.

		The countdown the player watches is a picture of DoubleUp.WindowSeconds; this
		is the rule. A client that never took its own card down still cannot buy a
		doubling of something that happened ten minutes ago.
	]]
	if now > o.expires then
		live[plr] = nil
		Offer:FireClient(plr, { state = "closed" })
		return
	end

	if DoubleUp.owedOf(plr) > 0 then
		-- Their last purchase has not been answered yet. Two notes cannot be held at
		-- once, so the offer is left standing and they can press again in a moment.
		return
	end

	live[plr] = nil
	noteDown(plr, o.amount)

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(plr, DoubleUp.ProductId)
	end)
	if not ok then
		plr:SetAttribute(DoubleUp.OwedAttr, nil)
		Offer:FireClient(plr, { state = "closed" })
		warn("[DoubleUp] PromptProductPurchase failed: " .. tostring(err))
		return
	end

	--[[
		AND A DEADLINE ON THE NOTE, because the event that is supposed to clear it
		does not always arrive.

		PromptProductPurchaseFinished is what normally takes the note off when somebody
		closes the dialog without buying. Measured 2026-08-14: it did not fire, and the
		note was still sitting at the full amount afterwards. That attribute is saved
		with the profile, and every future offer is refused while it is set -- so one
		unanswered prompt switched the whole feature off for that account permanently,
		which is the exact failure the note over OwedAttr warns about.

		Guarded on the amount being UNCHANGED, so this can only ever clear the note it
		was armed for: a receipt that landed in the meantime has already spent it (and
		set it to nil or to something else), and this then does nothing.

		The player is told, because the card on their screen is waiting on exactly this
		message -- though it now gives up on its own too, and rather sooner. See
		DoubleUp.PurchaseGrace.
	]]
	local owedThen = o.amount
	task.delay(DoubleUp.NoteGrace, function()
		if not plr.Parent then return end
		if DoubleUp.owedOf(plr) ~= owedThen then return end
		plr:SetAttribute(DoubleUp.OwedAttr, nil)
		Offer:FireClient(plr, { state = "closed" })
		warn(("[DoubleUp] %s never resolved a %d note in %ds -- written off so the"
			.. " offer is not disabled for them for good")
			:format(plr.Name, owedThen, DoubleUp.NoteGrace))
	end)
end)

--[[
	The dialog was closed without buying, so the note comes back off.

	Without this a player who opens the prompt and thinks better of it is left
	holding an outstanding note forever, and every future offer is refused by the
	guard above -- the feature switches itself off for that account for the rest of
	the session, and silently.

	Only ever cleared on FALSE. A true finish is followed by ProcessReceipt, which
	is the one place the note may be spent, and clearing it here would race that
	call for the figure it is about to read.

	⚠ A SIGNAL, not the assignable callback ProcessReceipt is -- see the warning
	over that one in UpgradeService. Connecting here adds a handler rather than
	replacing one, so this file is safe to connect from and that one is not.
]]
MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, bought)
	if productId ~= DoubleUp.ProductId or bought then return end
	local plr = Players:GetPlayerByUserId(userId)
	if not plr then return end
	plr:SetAttribute(DoubleUp.OwedAttr, nil)
	Offer:FireClient(plr, { state = "closed" })
end)

--==[ THE SECOND HELPING ]====================================================

--[[
	Spend the note. Called from ProcessReceipt and from nowhere else.

	Answers what was paid, and ZERO IS THE IMPORTANT ANSWER: it means there was no
	figure to pay or no wallet to pay it into, and the caller holds the receipt
	rather than granting it -- so Roblox asks again instead of the player paying
	for nothing. The note is cleared only once the money is actually in.
]]
function Service.grant(plr: Player): number
	local owed = DoubleUp.owedOf(plr)
	if owed <= 0 then return 0 end

	local paid = pay(plr, owed)
	if paid <= 0 then return 0 end

	plr:SetAttribute(DoubleUp.OwedAttr, nil)
	live[plr] = nil
	Offer:FireClient(plr, { state = "paid", amount = paid })
	return paid
end

Players.PlayerRemoving:Connect(function(plr)
	-- The note is deliberately NOT cleared here: it is the player's, it is in
	-- their profile, and a receipt that lands after they have gone is answered on
	-- their next join off that record.
	live[plr] = nil
end)

return Service
