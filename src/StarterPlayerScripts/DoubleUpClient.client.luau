--!strict
--[[
	DoubleUpClient -- the card that asks, and nothing else.

	One offer at a time, put up by the server when something has just paid this
	player a lump sum, and taken down again by the server, by the clock, or by the
	player answering it. Nothing here decides who is asked, what the figure is or
	whether the offer is still good -- see DoubleUpService, which owns all three.

	BUILT LIKE THE YARD'S OWN DIALOG, and that is deliberate. A dialog that does
	not look like the rest of the game reads as a Roblox system prompt, and players
	dismiss those without reading them -- so this is the same navy panel, gold
	keyline, outlined lines and chip buttons as AfkClient's "are you sure", which
	is the established modal here.

	IT DRAWS OVER THE ARENA'S RESULTS SCREEN and everything else: DisplayOrder 60
	against BattleUI's 50 and the shell's 20. The battle offer is not fired until
	the summary has had its run and the players are home, so in practice the two
	are never up together -- but an offer that can be hidden behind a panel is an
	offer that expires unread.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(SealerUI:WaitForChild("UIKit"))
local DoubleUp = require(SealerUI:WaitForChild("DoubleUp"))

local Remotes = DoubleUp.remotes()
local Offer = Remotes.DoubleOffer
local Answer = Remotes.DoubleAnswer

local T = UIKit.Theme

local function comma(n: number): string
	local str = tostring(math.floor(n))
	local out = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

--==[ WHAT IT COSTS ]=========================================================

--[[
	Asked once, and the listing is the authority.

	A price changed on the Dashboard must not leave this card quoting last month's
	figure, so it is fetched rather than typed -- the same call the shop's boost
	cards make. DoubleUp.Price stands in until the answer arrives and if the call
	fails altogether, because a card that says "Pay ... R$" while the player
	decides is worse than one that is briefly out of date.
]]
local price = DoubleUp.Price

task.spawn(function()
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(DoubleUp.ProductId, Enum.InfoType.Product)
	end)
	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
		price = info.PriceInRobux
	end
end)

--==[ THE CARD ]==============================================================

local gui: ScreenGui? = nil
--[[
	Which offer the card on screen belongs to.

	Every closure that outlives a frame -- the countdown, the tween at the end --
	captures this and gives up if it has moved. Without it a countdown from a card
	the player already answered goes on ticking and takes the NEXT card down with
	it a moment after it appears.
]]
local gen = 0

local function close()
	gen += 1
	if gui then
		gui:Destroy()
		gui = nil
	end
end

local function build(payload: any)
	close()
	gen += 1
	local mine = gen

	local source = DoubleUp.Sources[payload.source]
	if not source then return end
	local amount = math.floor(tonumber(payload.amount) or 0)
	if amount < 1 then return end
	local seconds = tonumber(payload.seconds) or DoubleUp.WindowSeconds

	local screen = Instance.new("ScreenGui")
	screen.Name = "DoubleUpOffer"
	-- The offer outlives a respawn: the AFK card is put up as the player is
	-- teleported home, and dying in the yard is one of the ways a visit ends.
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 60
	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen

	--[[
		The dim is a BUTTON, for the reason the yard's dialog gives: it reads as a
		modal, but what it is actually for is swallowing the press, so the thumb that
		arrives while this is going up does not carry on into the rail underneath.
		Tapping it declines, which is what tapping outside a dialog should do.
	]]
	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = T.ink
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Parent = screen

	-- 440 x 250 is the yard dialog's 420 x 210 with a line's worth of height for
	-- the price sentence and the timer strip along the bottom.
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(440, 250)
	card.BackgroundColor3 = T.navy
	card.BorderSizePixel = 0
	card.Parent = screen

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, 16)
	round.Parent = card

	local edge = Instance.new("UIStroke")
	edge.Color = T.gold
	edge.Thickness = 2.5
	edge.Parent = card

	-- Centred, because UIKit.outlined ranges left by default.
	local function line(text: string, size: number, colour: Color3, y: number, h: number)
		local l = UIKit.outlined(card, text, size, colour)
		l.TextXAlignment = Enum.TextXAlignment.Center
		l.Size = UDim2.new(1, -24, 0, h)
		l.Position = UDim2.fromOffset(12, y)
		l.TextWrapped = true
		return l
	end

	line(source.title, 28, T.gold, 14, 36)
	line(source.what:format(comma(amount)), 19, T.cream, 54, 26)
	--[[
		The total is spelled out rather than left as "double".

		"2x" is what the product is called and it is on the button; what decides the
		purchase is the figure it turns into, and asking a player to do the sum while
		a countdown runs is how an offer goes unread.
	]]
	local pitch = line(("Pay %d R$ and we will pay it again \u{2014} $%s in total.")
		:format(price, comma(amount * 2)), 20, T.white, 86, 52)

	--[[
		Answered once, whatever is still on screen.

		The dim stays live under the card after a yes -- it has to, it is what keeps
		the rail from being pressed through this -- so without a latch a tap on it
		while the Robux window is opening would send a "no" after the "yes" and take
		the card down mid-purchase.
	]]
	local decided = false

	local function answer(yes: boolean)
		if gen ~= mine or decided then return end
		decided = true
		if not yes then
			Answer:FireServer("no")
			close()
			return
		end
		Answer:FireServer("yes")
		--[[
			AND A WAY OUT IF THE SERVER NEVER ANSWERS.

			From here the card is waiting on "paid" or "closed", both of which come from
			the server, and the countdown below has already been disarmed by `decided`.
			If neither arrives the card stays up under a full-screen dim that eats every
			click, and the player cannot move, seal or leave -- which is exactly what was
			reported after backing out of the Robux window without enough to buy.

			The cause is on Roblox's side (PromptProductPurchaseFinished does not always
			fire; see the note over DoubleUp.PurchaseGrace, where it is measured), so the
			card cannot rely on being told. It gives up on its own instead.

			NO ANSWER IS SENT. Nothing is cancelled and nothing is declined -- this only
			takes the card off the screen. A receipt that lands afterwards still pays
			through ProcessReceipt, and the decline cooldown is untouched, because the
			player did not decline anything.
		]]
		task.delay(DoubleUp.PurchaseGrace, function()
			if gen ~= mine then return end
			close()
		end)
		--[[
			The card stays up, with the buttons gone.

			Roblox's own purchase dialog takes the screen from here, and what is behind
			it when it closes should be the thing that asked -- a card that vanished on
			the press would leave a player who cancels with no idea what they cancelled.
			It is taken down by the server either way: "paid" when the receipt lands,
			"closed" when the dialog is shut without buying.
		]]
		for _, d in ipairs(card:GetChildren()) do
			if d.Name == "Chip" then (d :: GuiObject).Visible = false end
		end
		pitch.Text = "Finish up in the Robux window\u{2026}"
	end

	local go = UIKit.chip(card, "Double it", 190, T.gold, function() answer(true) end)
	go.AnchorPoint = Vector2.new(1, 1)
	go.Position = UDim2.new(0.5, -8, 1, -30)

	local no = UIKit.chip(card, "No thanks", 190, T.red, function() answer(false) end)
	no.AnchorPoint = Vector2.new(0, 1)
	no.Position = UDim2.new(0.5, 8, 1, -30)

	--[[
		Tapping the dim declines -- until a purchase is in flight, after which it
		dismisses instead.

		It used to call answer(false) unconditionally, which did NOTHING once `decided`
		was set: answer returns early, so after pressing DOUBLE IT the dim was a
		full-screen button that swallowed clicks and did not respond to them. That is
		the other half of the stuck card -- the player's instinct is to tap the
		background to get out, and it was the one input guaranteed to do nothing.

		Dismissing rather than declining, for the reason the grace timer gives: the
		purchase may still be live, and telling the server "no" would start a decline
		cooldown for something they did not decline.
	]]
	dim.Activated:Connect(function()
		if decided then close() else answer(false) end
	end)

	--==[ the clock ]=========================================================
	--[[
		A strip that empties, rather than a number counting down.

		The server is what actually enforces the window (see the note in
		DoubleUpService); this only has to say "not for long". A bar does that at a
		glance and does not put a second set of digits on a card that is already
		about numbers.
	]]
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, -12)
	track.Size = UDim2.new(1, -40, 0, 6)
	track.BackgroundColor3 = UIKit.deepen(T.navy, 0.35)
	track.BorderSizePixel = 0
	track.Parent = card
	local tr = Instance.new("UICorner")
	tr.CornerRadius = UDim.new(1, 0)
	tr.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = T.gold
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fr = Instance.new("UICorner")
	fr.CornerRadius = UDim.new(1, 0)
	fr.Parent = fill

	TweenService:Create(fill, TweenInfo.new(seconds, Enum.EasingStyle.Linear), {
		Size = UDim2.fromScale(0, 1),
	}):Play()

	task.delay(seconds, function()
		-- Answered, superseded or already taken down by the server. The `decided`
		-- case is the one that matters: a purchase dialog can easily be open past
		-- the window, and the card must not be pulled out from under it.
		if gen ~= mine or decided then return end
		--[[
			"lapsed", NOT "no" -- the card ran out, nobody pressed anything.

			This fired "no" and the two are not the same thing. A decline now starts
			DoubleUp.DeclineCooldown before this player is asked again (see the server's
			Answer handler), and a player who simply did not look at the card in time
			has not declined anything -- silencing the next offer for them would be
			punishing them for being busy, which is the opposite of what the cooldown is
			for.

			The server clears the offer for both, so the card still goes away exactly as
			it did before; only the cooldown tells them apart.
		]]
		Answer:FireServer("lapsed")
		close()
	end)
end

--==[ PAID ]==================================================================

--[[
	The receipt landed, so the card says so before it goes.

	The cash counter in the corner moves on its own and this is two seconds of
	telling the player which of the numbers on their screen just changed and why.
	Built fresh rather than reusing whatever is up: the offer card may already have
	been taken down by its own clock, and a purchase that lands late still deserves
	an answer.
]]
local function paid(amount: number)
	close()
	gen += 1
	local mine = gen

	local screen = Instance.new("ScreenGui")
	screen.Name = "DoubleUpPaid"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 60
	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(400, 118)
	card.BackgroundColor3 = T.navy
	card.BorderSizePixel = 0
	card.Parent = screen

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, 16)
	round.Parent = card

	local edge = Instance.new("UIStroke")
	edge.Color = T.gold
	edge.Thickness = 2.5
	edge.Parent = card

	local function line(text: string, size: number, colour: Color3, y: number, h: number)
		local l = UIKit.outlined(card, text, size, colour)
		l.TextXAlignment = Enum.TextXAlignment.Center
		l.Size = UDim2.new(1, -24, 0, h)
		l.Position = UDim2.fromOffset(12, y)
		return l
	end

	line("DOUBLED", 30, T.gold, 16, 36)
	line(("$%s added to your cash"):format(comma(amount)), 21, T.cream, 58, 30)

	task.delay(2.2, function()
		if gen ~= mine then return end
		close()
	end)
end

--==[ THE SWITCH ]============================================================

Offer.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	local state = payload.state
	if state == "offer" then
		build(payload)
	elseif state == "paid" then
		paid(math.floor(tonumber(payload.amount) or 0))
	elseif state == "closed" then
		close()
	end
end)
