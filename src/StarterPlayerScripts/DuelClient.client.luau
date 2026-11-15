--!strict
--[[
	DuelClient -- the E prompt, the mode menu, the accept card and the duel HUD.

	Four screens and no simulation. That is the point of the whole feature's shape:
	two of the three modes are played on ORDINARY SEALABLE SLABS, so DrivewayClient
	is already doing the pouring, the spreading, the coverage readout and the
	finished-job flourish, and the third is played in the arena, where
	SqueegeeBattleClient is already doing all of it. Nothing in this file paints
	anything.

	HOW PRESSING E ON A PERSON REACHES THIS FILE WITH NO REMOTE

	DuelServer parents a ProximityPrompt to every character's root.
	ProximityPromptService.PromptTriggered fires on the SERVER and on the
	triggering player's own client, so the menu opens locally the instant it is
	pressed -- no round trip, and nothing to open the wrong menu on somebody else's
	screen. The dealership desk and the upgrade counter already work this way.

	The challenge itself IS a remote, because it is a decision about another player
	and a client may not be trusted with one. See the checks at the top of
	DuelServer's SendChallenge handler, every one of which is re-run at the accept.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Pack = ReplicatedStorage:WaitForChild("Duel")
local Duel = require(Pack:WaitForChild("DuelConfig"))
local DuelNet = require(Pack:WaitForChild("DuelNet"))

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(SealerUI:WaitForChild("UIKit"))
-- A player still being taught the game is shown no duel prompt at all -- see
-- `applyTo`, which is the per-viewer half of the rule the server also enforces.
local Tutorial = require(SealerUI:WaitForChild("Tutorial"))
local T = UIKit.Theme

local player = Players.LocalPlayer
local Remotes = DuelNet.remotes()
local SendChallenge = Remotes.SendChallenge :: RemoteEvent
local Offer         = Remotes.Offer :: RemoteEvent
local OfferReply    = Remotes.OfferReply :: RemoteEvent
local Notice        = Remotes.Notice :: RemoteEvent
local DuelState     = Remotes.DuelState :: RemoteEvent
local DuelResult    = Remotes.DuelResult :: RemoteEvent

-- The pail is named "Sealer Bucket" and the squeegee "Squeegee", but both carry
-- a SealerTool attribute (see ToolBuilder), so reading that beats matching
-- either name. Used both to hide the E prompt and to refuse an already-open one.
local function holdingSealTool(): boolean
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	local kind = tool and tool:GetAttribute("SealerTool")
	return kind == "Bucket" or kind == "Squeegee"
end

--==[ THE SCREEN ]============================================================

--[[
	ABOVE EVERYTHING THE PLAYER MIGHT BE LOOKING AT, and 51 is measured rather
	than picked.

	The layers already in this place: the shell at 20, GoldenHourHUD at 21, the
	tutorial's three at 25-27, and the two event HUDs -- SqueegeeBattleUI and
	DrivewayRaceUI -- at 50. That last pair matters, because SqueegeeBattleUI also
	owns the NEXT EVENT ticker, which sits top-centre and is up all the time.

	A challenge card is a MODAL QUESTION with a deadline: somebody is waiting on the
	answer, and a card with a line of it hidden behind a clock is a card that gets
	answered wrong. So it goes above the lot.

	It is not a fight with the two event HUDs. A duellist cannot be in a race or a
	scheduled match at the same time -- DuelServer.busyReason refuses in both
	directions -- and the one place the arena's HUD and this file genuinely coexist
	is a Squeegee Battle duel, where this one deliberately hides itself. See
	`handOff`.

	21 was the first guess and it was wrong twice: under the ticker, and tied with
	GoldenHourHUD, which leaves the winner of that tie up to the engine.
]]
local gui = Instance.new("ScreenGui")
gui.Name = "DuelUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 51
gui.Parent = player:WaitForChild("PlayerGui")

--[[
	EVERY BLOCK IN HERE IS DRAWN IN PIXELS AGAINST A DESKTOP, so every block in
	here has to be scaled to the window it finds itself in.

	The challenge card is 540 x 430. That is a third of a 1280 x 720 window and it
	is most of a handset, or of a small Studio play window -- measured at 452px
	tall, where the card ran within eleven pixels of both edges. UIKit's fit is the
	one shared answer the whole HUD uses, so a duel card shrinks by exactly as much
	as the panel behind it and the two still read as one product.

	ONE HOOK, not one per card. UIKit.onFit has no way to unregister, so a hook
	taken out per card would leak a closure for every challenge anybody ever sent.
	This one walks whatever is currently on screen instead, and `fitted` stamps the
	current answer onto each card as it is built.

	A UIScale scales about the AnchorPoint, and every block here is anchored to the
	edge or the centre it belongs on -- so a scaled card shrinks toward its own
	corner rather than drifting across the screen. UIKit.onFit's own note says the
	same thing.
]]
local fit = 1

local function fitted(holder: GuiObject): GuiObject
	local s = Instance.new("UIScale")
	s.Scale = fit
	s.Parent = holder
	return holder
end

UIKit.onFit(function(f: number)
	fit = f
	for _, child in ipairs(gui:GetChildren()) do
		local s = child:FindFirstChildOfClass("UIScale")
		if s then s.Scale = f end
	end
end)

local function money(n: number): string
	-- Thousands separators, because a duel purse is routinely six figures and an
	-- unbroken run of digits is not a number anybody reads at a glance.
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(s // 60, s % 60)
end

--==[ TOASTS ]================================================================

--[[
	One line, top of the screen, gone in three seconds.

	This file has its own rather than borrowing Shell:Toast because every message
	here is about a conversation between two players -- "challenge sent", "they
	declined" -- and those have to be readable while a modal card is up, which the
	shell's toasts are drawn under.
]]
local toastHolder = Instance.new("Frame")
toastHolder.Name = "Toasts"
toastHolder.AnchorPoint = Vector2.new(0.5, 0)
toastHolder.Position = UDim2.new(0.5, 0, 0, 96)
toastHolder.Size = UDim2.fromOffset(460, 0)
toastHolder.AutomaticSize = Enum.AutomaticSize.Y
toastHolder.BackgroundTransparency = 1
toastHolder.Parent = gui
fitted(toastHolder)

local toastList = Instance.new("UIListLayout")
toastList.SortOrder = Enum.SortOrder.LayoutOrder
toastList.HorizontalAlignment = Enum.HorizontalAlignment.Center
toastList.Padding = UDim.new(0, 6)
toastList.Parent = toastHolder

local function toast(text: string, ok: boolean)
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(460, 44)
	card.BackgroundColor3 = if ok then T.greenDark else T.navy
	card.BorderSizePixel = 0
	card.Parent = toastHolder

	local r = Instance.new("UICorner")
	r.CornerRadius = UDim.new(0, 12)
	r.Parent = card
	local s = Instance.new("UIStroke")
	s.Thickness = 2.5
	s.Color = T.ink
	s.Parent = card

	local l = UIKit.label(card, text, 19, T.cream)
	l.Size = UDim2.fromScale(1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Center

	task.delay(3, function()
		if not card.Parent then return end
		TweenService:Create(card, TweenInfo.new(0.25),
			{ BackgroundTransparency = 1 }):Play()
		TweenService:Create(l, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
		task.wait(0.3)
		card:Destroy()
	end)
end

Notice.OnClientEvent:Connect(function(msg)
	if type(msg) ~= "table" then return end
	toast(tostring(msg.text), msg.ok == true)
end)

--==[ THE MODE MENU ]=========================================================

local menuTarget: Player? = nil
local menuHolder: Frame? = nil

local function closeMenu()
	menuTarget = nil
	if menuHolder then
		menuHolder:Destroy()
		menuHolder = nil
	end
end

--[[
	The menu is BUILT each time rather than shown and hidden.

	It names the person being challenged in its title, so a cached panel would have
	to be relabelled anyway -- and this opens at most once every few seconds, by
	hand, which is nowhere near often enough for three frames of construction to
	matter. Rebuilding also means a menu can never be left holding a target who has
	since walked away.
]]
local function openMenu(target: Player)
	closeMenu()
	menuTarget = target

	local holder, content = UIKit.panel(gui,
		UDim2.fromOffset(560, 470), UDim2.fromScale(0.5, 0.5),
		"Duel " .. target.DisplayName, T.gold)
	fitted(holder)
	menuHolder = holder
	UIKit.closeButton(holder:FindFirstChild("Panel") :: GuiObject, closeMenu)

	local blurb = UIKit.label(content,
		"Free to send, free to accept. The winner takes the average of both wallets.",
		17, T.blueLight)
	blurb.Position = UDim2.fromOffset(24, 4)
	blurb.Size = UDim2.new(1, -48, 0, 40)
	blurb.TextWrapped = true
	blurb.TextXAlignment = Enum.TextXAlignment.Center

	for i, mode in ipairs(Duel.Modes) do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Position = UDim2.fromOffset(24, 46 + (i - 1) * 124)
		row.Size = UDim2.new(1, -48, 0, 114)
		row.Parent = content

		local btn = UIKit.button(row, mode.glyph .. "  " .. mode.name:upper(),
			UDim2.new(1, 0, 0, 60), mode.tint, function()
				local who = menuTarget
				closeMenu()
				if who then SendChallenge:FireServer(who, mode.id) end
			end)
		btn.Position = UDim2.fromOffset(0, 0)

		local note = UIKit.label(row, mode.blurb, 15, T.blueLight)
		note.Position = UDim2.fromOffset(6, 62)
		note.Size = UDim2.new(1, -12, 0, 48)
		note.TextWrapped = true
		note.TextYAlignment = Enum.TextYAlignment.Top
	end
end

--==[ THE E PROMPT ]==========================================================

--[[
	Whose character is this prompt on?

	Searched UPWARD for the character rather than walked as a fixed chain of
	.Parent hops. The prompt hangs on an Attachment on the root (see
	Duel.PromptHeight for why it cannot live on the root itself), so the chain is
	prompt -> Attachment -> HumanoidRootPart -> Character, and the first version of
	this counted two hops and landed on the root -- which is not a Model, so it
	answered nil and the menu never opened.

	FindFirstAncestorWhichIsA cannot be broken by that: it finds the character
	however deep the prompt ends up sitting.
]]
local function playerOfPrompt(prompt: ProximityPrompt): Player?
	local char = prompt:FindFirstAncestorWhichIsA("Model")
	if not char then return nil end
	return Players:GetPlayerFromCharacter(char)
end

ProximityPromptService.PromptTriggered:Connect(function(prompt, who)
	if who ~= player or prompt.Name ~= Duel.PromptName then return end
	-- Belt and braces: the prompt is hidden from a player who may not duel (see
	-- `applyTo`), and the server refuses them again on the far side of the remote.
	-- This is the middle of the three, and it is the one that stops a menu opening.
	if not Tutorial.isDone(player) then return end
	if holdingSealTool() then return end
	local target = playerOfPrompt(prompt)
	if not target or target == player then return end
	openMenu(target)
end)

--[[
	WHICH DUEL PROMPTS THIS PLAYER MAY SEE, which is not the same question the
	server answers.

	The server decides whether a player is CHALLENGEABLE -- mid-duel, mid-race, in
	the arena, still in the tutorial -- and that is one answer for everybody, so it
	belongs on the instance. Three more rules are per-VIEWER, and an instance property
	cannot hold two answers at once, so they can only live here:

	  * your own prompt is never shown to you. The server has to build one on every
	    character including yours, or nobody else could challenge you.
	  * NOBODY's prompt is shown to a player who is still in the tutorial. They are
	    being taught one driveway and one purchase, and a duel offer is the worst
	    possible interruption of it -- the same call DrivewayRaceServer.toEligible
	    makes when it declines to send them a race card at all.
	  * NOBODY's prompt is shown while you have the Sealer Bucket or the Squeegee
	    equipped (see `holdingSealTool`). Both hands are already busy with a pour
	    or a stroke, and a challenge card popping up over that gets answered by a
	    misclick mid-swing rather than a real decision.

	WHY THIS KEEPS A COPY OF WHAT THE SERVER WANTED. A local write to a replicated
	instance does not replicate back, so hiding is just `Enabled = false` -- but the
	server goes on writing that property whenever the target's availability moves,
	and each of those writes lands on top of the local one. So the hide has to be
	re-asserted, and once it has been, the server's own intent is gone from the
	property. `wanted` is that intent, kept so the prompt can be handed back
	correctly the moment the tutorial ends rather than being guessed at.
]]
local forced: { [ProximityPrompt]: boolean } = {}
local wanted: { [ProximityPrompt]: boolean } = {}
local watched: { { prompt: ProximityPrompt, mine: boolean } } = {}

local function applyTo(prompt: ProximityPrompt, mine: boolean)
	local allow = not mine and Tutorial.isDone(player) and not holdingSealTool()
	if allow then
		if forced[prompt] then
			forced[prompt] = nil
			-- back to whatever the server last asked for, not unconditionally on
			prompt.Enabled = wanted[prompt] ~= false
		end
	else
		if not forced[prompt] then wanted[prompt] = prompt.Enabled end
		forced[prompt] = true
		if prompt.Enabled then prompt.Enabled = false end
	end
end

local function applyAll()
	for i = #watched, 1, -1 do
		local e = watched[i]
		if not e.prompt.Parent then
			table.remove(watched, i)
		else
			applyTo(e.prompt, e.mine)
		end
	end
end

local function trackPrompts(plr: Player)
	local mine = plr == player
	local function bind(char: Model)
		task.spawn(function()
			local hrp = char:WaitForChild("HumanoidRootPart", 20)
			if not hrp then return end
			local at = hrp:WaitForChild(Duel.PromptAttachName, 20)
			if not at then return end
			local prompt = at:WaitForChild(Duel.PromptName, 20)
			if not prompt or not prompt:IsA("ProximityPrompt") then return end

			wanted[prompt] = prompt.Enabled
			watched[#watched + 1] = { prompt = prompt, mine = mine }

			prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
				if forced[prompt] then
					-- Only the server can have done this. Remember what it asked for,
					-- then put the hide back.
					if prompt.Enabled then
						wanted[prompt] = true
						prompt.Enabled = false
					end
				else
					wanted[prompt] = prompt.Enabled
				end
			end)
			prompt.Destroying:Connect(function()
				forced[prompt] = nil
				wanted[prompt] = nil
			end)

			applyTo(prompt, mine)
		end)
	end
	if plr.Character then bind(plr.Character) end
	plr.CharacterAdded:Connect(bind)
end

for _, plr in ipairs(Players:GetPlayers()) do trackPrompts(plr) end
Players.PlayerAdded:Connect(trackPrompts)

--[[
	The other per-viewer input that can change mid-session: whether YOU have the
	pail or squeegee out right now.

	WATCHED ON THE CHARACTER, not on a Humanoid event -- there is no such event.
	The first version of this hooked Humanoid.Equipped/Unequipped, which are members
	of TOOL and not of Humanoid; the connect threw inside its own task.spawn, so the
	only symptom was that the rule silently never re-ran and the prompt stayed up.

	A tool moves Backpack -> Character when it is equipped, whatever equipped it:
	the hotbar, a number key, the backpack UI, or a script. Listening to the
	character catches all of them -- the same reasoning AudioClient uses for its
	own tool cue.

	Swapping pail for squeegee fires a remove and an add. Measured in a playtest
	rather than reasoned about: under deferred signals both reparents land before
	either callback runs, so both read the FINAL state and the gate never dips to
	"allowed" mid-swap. A slower swap by hand -- stow, then draw -- does restore the
	prompt in the gap, which is correct: the remove hands back the server's intent
	and the add re-hides it, so `wanted` survives either path instead of being
	overwritten with a forced `false`.
]]
local function watchHeldTool(char: Model)
	local function onChange(child: Instance)
		if child:IsA("Tool") then applyAll() end
	end
	char.ChildAdded:Connect(onChange)
	char.ChildRemoved:Connect(onChange)
	applyAll()
end
if player.Character then watchHeldTool(player.Character) end
player.CharacterAdded:Connect(watchHeldTool)

--[[
	The tutorial flag is another input to the rule that can change mid-session, and
	it changes exactly once -- the moment the player finishes. Watching it is what
	hands them the whole feature at that moment instead of on their next rejoin.
]]
player:GetAttributeChangedSignal(Tutorial.DoneAttr):Connect(applyAll)
player:GetAttributeChangedSignal(Tutorial.ReadyAttr):Connect(applyAll)

--==[ THE CHALLENGE CARD ]====================================================

local offerHolder: Frame? = nil
local offerConn: RBXScriptConnection? = nil

local function closeOffer()
	if offerConn then
		offerConn:Disconnect()
		offerConn = nil
	end
	if offerHolder then
		offerHolder:Destroy()
		offerHolder = nil
	end
end

Offer.OnClientEvent:Connect(function(msg)
	if type(msg) ~= "table" then return end
	closeOffer()
	closeMenu()

	local mode = Duel.modeById(msg.mode)
	local tint = if mode then mode.tint else T.gold

	local holder, content = UIKit.panel(gui,
		UDim2.fromOffset(540, 430), UDim2.fromScale(0.5, 0.5),
		"Duel Challenge", tint)
	fitted(holder)
	offerHolder = holder

	local who = UIKit.label(content,
		("%s challenges you to"):format(tostring(msg.fromName)), 20, T.cream)
	who.Position = UDim2.fromOffset(20, 6)
	who.Size = UDim2.new(1, -40, 0, 28)
	who.TextXAlignment = Enum.TextXAlignment.Center

	local what = UIKit.outlined(content,
		((mode and mode.glyph or "") .. " " .. tostring(msg.modeName)):upper(),
		34, tint, 3)
	what.Position = UDim2.fromOffset(20, 36)
	what.Size = UDim2.new(1, -40, 0, 46)
	what.TextXAlignment = Enum.TextXAlignment.Center

	local blurb = UIKit.label(content, tostring(msg.blurb or ""), 16, T.blueLight)
	blurb.Position = UDim2.fromOffset(30, 86)
	blurb.Size = UDim2.new(1, -60, 0, 56)
	blurb.TextWrapped = true

	--[[
		The purse and the gate, together.

		The server quotes both -- see DuelServer.quoteFor -- so that a duel which will
		not pay is one the player knowingly agreed to play for pride. Finding that out
		afterwards would read as the game quietly keeping the money.
	]]
	local prize = UIKit.outlined(content,
		"WINNER TAKES $" .. money(tonumber(msg.prize) or 0), 26, T.gold, 2.6)
	prize.Position = UDim2.fromOffset(20, 146)
	prize.Size = UDim2.new(1, -40, 0, 34)
	prize.TextXAlignment = Enum.TextXAlignment.Center

	if msg.reason then
		local warn = UIKit.label(content, "⚠ " .. tostring(msg.reason)
			.. " -- this one is for pride", 15, T.red)
		warn.Position = UDim2.fromOffset(24, 180)
		warn.Size = UDim2.new(1, -48, 0, 34)
		warn.TextWrapped = true
		warn.TextXAlignment = Enum.TextXAlignment.Center
	else
		local fair = UIKit.label(content,
			"the average of both your wallets, right now", 15, T.blueLight)
		fair.Position = UDim2.fromOffset(24, 180)
		fair.Size = UDim2.new(1, -48, 0, 26)
		fair.TextXAlignment = Enum.TextXAlignment.Center
	end

	local accept = UIKit.button(content, "ACCEPT", UDim2.fromOffset(210, 62),
		T.green, function()
			closeOffer()
			OfferReply:FireServer(true)
		end)
	accept.Position = UDim2.fromOffset(36, 224)

	local decline = UIKit.button(content, "DECLINE", UDim2.fromOffset(210, 62),
		T.red, function()
			closeOffer()
			OfferReply:FireServer(false)
		end)
	decline.Position = UDim2.new(1, -246, 0, 224)

	--[[
		The card counts ITSELF down, off a duration rather than a deadline.

		os.clock on the server is time since that machine started and is meaningless
		here, so the server sends how many seconds the offer has rather than when it
		ends -- the same rule PromptRaceUI follows, and the reason BattleConfig's
		NextEventAt uses GetServerTimeNow instead.

		The OFFER expires on the server independently. This bar is the player's
		warning, not the rule.
	]]
	local total = tonumber(msg.seconds) or Duel.OfferSeconds
	local bar, fill, label = UIKit.progressPill(content, 468)
	bar.Position = UDim2.fromOffset(36, 296)

	local endsAt = os.clock() + total
	offerConn = RunService.Heartbeat:Connect(function()
		local left = endsAt - os.clock()
		if left <= 0 then
			closeOffer()
			toast("The challenge expired", false)
			return
		end
		fill.Size = UDim2.fromScale(math.clamp(left / total, 0, 1), 1)
		label.Text = ("%ds to decide"):format(math.ceil(left))
	end)
end)

--==[ THE DUEL HUD ]==========================================================

--[[
	The scoreboard for the two sealing modes, and it is the only thing this file
	draws during a match.

	Squeegee Battle sends `handOff`, and this hides itself for the whole of it: the
	arena has its own HUD with its own clock and its own eight-way scoreboard, and
	two timers disagreeing by a frame in the corner of one screen is the exact bug
	the single-scheduler rewrite existed to delete.
]]
local hud = Instance.new("Frame")
hud.Name = "DuelHud"
hud.AnchorPoint = Vector2.new(0.5, 0)
hud.Position = UDim2.new(0.5, 0, 0, 12)
hud.Size = UDim2.fromOffset(420, 132)
hud.BackgroundColor3 = T.navy
hud.BorderSizePixel = 0
hud.Visible = false
hud.Parent = gui
fitted(hud)
do
	local r = Instance.new("UICorner")
	r.CornerRadius = UDim.new(0, 16)
	r.Parent = hud
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = T.ink
	s.Parent = hud
end

local hudMode = UIKit.label(hud, "", 16, T.blueLight)
hudMode.Position = UDim2.fromOffset(0, 6)
hudMode.Size = UDim2.new(1, 0, 0, 18)
hudMode.TextXAlignment = Enum.TextXAlignment.Center

local hudClock = UIKit.outlined(hud, "", 30, T.cream, 2.6)
hudClock.Position = UDim2.fromOffset(0, 22)
hudClock.Size = UDim2.new(1, 0, 0, 34)
hudClock.TextXAlignment = Enum.TextXAlignment.Center

local rows: { { name: TextLabel, score: TextLabel, bar: Frame, fill: Frame } } = {}
for i = 1, 2 do
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(14, 58 + (i - 1) * 34)
	row.Size = UDim2.new(1, -28, 0, 30)
	row.Parent = hud

	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromScale(1, 1)
	bar.BackgroundColor3 = Color3.fromRGB(26, 52, 96)
	bar.BorderSizePixel = 0
	bar.Parent = row
	local br = Instance.new("UICorner")
	br.CornerRadius = UDim.new(0, 9)
	br.Parent = bar

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = if i == 1 then Color3.fromRGB(255, 72, 86)
		else Color3.fromRGB(70, 168, 255)
	fill.BorderSizePixel = 0
	fill.ZIndex = 2
	fill.Parent = bar
	local fr = Instance.new("UICorner")
	fr.CornerRadius = UDim.new(0, 9)
	fr.Parent = fill

	local name = UIKit.label(bar, "", 17, T.cream)
	name.Position = UDim2.fromOffset(10, 0)
	name.Size = UDim2.new(1, -110, 1, 0)
	name.ZIndex = 4

	local score = UIKit.label(bar, "", 18, T.white)
	score.Position = UDim2.new(1, -100, 0, 0)
	score.Size = UDim2.fromOffset(90, 30)
	score.TextXAlignment = Enum.TextXAlignment.Right
	score.ZIndex = 4

	rows[i] = { name = name, score = score, bar = bar, fill = fill }
end

-- Sent once at the count-in and remembered, because the per-tick state carries
-- scores and a clock and nothing else -- the same split RaceState makes.
local unit = "percent"
local target = 1

local function drawState(msg: { [string]: any })
	if msg.unit then unit = tostring(msg.unit) end
	if type(msg.target) == "number" then target = msg.target end

	if msg.handOff then
		hud.Visible = false
		return
	end

	hudMode.Text = Duel.nameOf(msg.mode):upper()
	hud.Visible = msg.phase ~= Duel.State.Over or msg.over ~= true

	if msg.phase == Duel.State.CountIn then
		hudClock.Text = "GET READY"
	elseif type(msg.left) == "number" then
		hudClock.Text = clock(msg.left)
		-- The last ten seconds go red, which is the only colour change on this HUD
		-- and is therefore the only thing that can mean "hurry". Battle and Race use
		-- the same threshold for the same reason.
		hudClock.TextColor3 = if msg.left <= 10 then T.red else T.cream
	end

	if type(msg.rows) ~= "table" then return end
	for i, r in ipairs(msg.rows) do
		local ui = rows[i]
		if ui then
			local mine = r.userId == player.UserId
			ui.name.Text = (if mine then "▶ " else "") .. tostring(r.name)
			if unit == "percent" then
				ui.score.Text = ("%d%%"):format(math.floor((r.score or 0) * 100))
				ui.fill.Size = UDim2.fromScale(
					math.clamp((r.score or 0) / math.max(target, 1e-6), 0, 1), 1)
			else
				ui.score.Text = ("%d"):format(r.score or 0)
				ui.fill.Size = UDim2.fromScale(
					math.clamp((r.score or 0) / math.max(target, 1), 0, 1), 1)
			end
		end
	end
end

DuelState.OnClientEvent:Connect(function(msg)
	if type(msg) ~= "table" then return end
	drawState(msg)
end)

--==[ THE RESULT ]============================================================

DuelResult.OnClientEvent:Connect(function(msg)
	if type(msg) ~= "table" then return end
	hud.Visible = false

	local won, draw = msg.won == true, msg.draw == true
	local tint = if draw then T.slate elseif won then T.green else T.red

	-- 300 rather than 360: the tallest this card ever gets is a verdict, two score
	-- lines, a prize and a two-line reason, which lands at 250. Measured with the
	-- longest of the three gate sentences in it.
	local holder, content = UIKit.panel(gui,
		UDim2.fromOffset(520, 300), UDim2.fromScale(0.5, 0.5),
		tostring(msg.modeName or "Duel"), tint)
	fitted(holder)

	-- A forfeit says so, because "YOU WIN" over a scoreline nobody finished reads
	-- as the game having decided at random.
	local headline = if draw then "A DRAW"
		elseif msg.forfeit == true then (if won then "THEY LEFT -- YOU WIN" else "YOU FORFEITED")
		elseif won then "YOU WIN"
		else "YOU LOSE"
	local verdict = UIKit.outlined(content, headline,
		if msg.forfeit == true then 32 else 46, tint, 3.4)
	verdict.Position = UDim2.fromOffset(20, 6)
	verdict.Size = UDim2.new(1, -40, 0, 60)
	verdict.TextXAlignment = Enum.TextXAlignment.Center

	if type(msg.rows) == "table" then
		for i, r in ipairs(msg.rows) do
			local line = UIKit.label(content,
				("%s   %s"):format(tostring(r.name),
					if unit == "percent"
						then ("%d%%"):format(math.floor((r.score or 0) * 100))
						else ("%d driveways"):format(r.score or 0)),
				20, if r.userId == player.UserId then T.cream else T.blueLight)
			line.Position = UDim2.fromOffset(30, 76 + (i - 1) * 30)
			line.Size = UDim2.new(1, -60, 0, 26)
			line.TextXAlignment = Enum.TextXAlignment.Center
		end
	end

	local paid = tonumber(msg.prize) or 0
	if paid > 0 then
		local cash = UIKit.outlined(content, "+$" .. money(paid), 34, T.gold, 3)
		cash.Position = UDim2.fromOffset(20, 146)
		cash.Size = UDim2.new(1, -40, 0, 44)
		cash.TextXAlignment = Enum.TextXAlignment.Center
	end

	--[[
		WHY NOTHING WAS PAID, always, when nothing was.

		A winner who is handed a zero and no sentence has been cheated as far as they
		can tell. Every path that pays nothing carries a reason -- the gate, a draw, or
		somebody leaving -- and this is where all three of them surface.
	]]
	if msg.reason then
		local note = UIKit.label(content, tostring(msg.reason), 16, T.blueLight)
		note.Position = UDim2.fromOffset(28, if paid > 0 then 192 else 152)
		note.Size = UDim2.new(1, -56, 0, 48)
		note.TextWrapped = true
		note.TextXAlignment = Enum.TextXAlignment.Center
	end

	task.delay(tonumber(msg.seconds) or Duel.ResultSeconds, function()
		if holder.Parent then holder:Destroy() end
	end)
end)

--==[ ESCAPE ]================================================================

-- Escape shuts the mode menu, which is the one panel here a player opens by
-- accident. It deliberately does NOT answer a challenge: declining is a thing
-- somebody else is waiting on, and it should take the button that says so.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape then closeMenu() end
end)
