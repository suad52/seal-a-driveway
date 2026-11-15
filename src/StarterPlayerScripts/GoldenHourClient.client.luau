--!strict
--[[
	GoldenHourClient -- the sunset and the countdown, on this screen only.

	Everything here is presentation. The window is opened and shut by
	ServerScriptService.EventHandler and it is turned into money by DrivewayServer;
	if this file failed to run the player would still be paid triple, they simply
	would not know it.

	THE SKY IS CHANGED CLIENT-SIDE, which is not a shortcut. A Sky parented on one
	client does not replicate, so each player gets their own sunset and the
	server's own Lighting never moves.

	THE HOUR IS NOT TOUCHED, which is worth saying because an earlier version of
	this file fought hard to move it. ReplicatedStorage.WorldTime pins ClockTime and
	puts it back the instant anything writes it -- a guard no tween can win -- so
	the hour had to be walked forward by hand through WorldTime.setHour. That went
	with the rest of the faked sunset: the skybox carries the evening now, the world
	stays lit the way it always is, and WorldTime is left alone.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(Pack:WaitForChild("UIKit"))
local TopBand = require(Pack:WaitForChild("TopBand"))
local GoldenHour = require(Pack:WaitForChild("GoldenHour"))
local Tutorial = require(Pack:WaitForChild("Tutorial"))

local T = UIKit.Theme
local plr = Players.LocalPlayer

--==[ THE SKY ]===============================================================

--[[
	A skybox swap, and that is the whole of the environment change.

	This file used to lerp nine lighting properties across three objects over four
	seconds -- ambient colours, brightness, atmosphere, bloom, the hour, and a
	full-screen colour grade -- to fake a sunset out of a blue sky. All of it is
	gone. See the note in GoldenHour for what it was and why it was the wrong
	trade; the short version is that it recoloured the whole neighbourhood to get
	at the sky.

	A Sky cannot be tweened -- a skybox is six textures, not a number -- so the
	swap is INSTANT, and that suits the thing it is announcing better than a fade
	did. The window opens, the sky is on fire, and the player looks up.
]]

--[[
	The place's own Sky, if it ever has one.

	It has none today: Lighting holds SunRays, an Atmosphere and a Bloom, and the
	skybox is Roblox's default -- so "put it back" means removing ours and letting
	the default return. Parked rather than assumed absent all the same, because a
	place that gains an authored sky later would otherwise have it silently
	destroyed by the first Golden Hour of the session.

	Parented to nil rather than destroyed, and held by this reference, so it is
	the same instance that goes back.
]]
local authoredSky = Lighting:FindFirstChildOfClass("Sky")
local goldenSky: Sky? = nil

local function buildSky(): Sky
	local sky = Instance.new("Sky")
	sky.Name = "GoldenHourSky"
	sky.SkyboxBk = GoldenHour.SkyboxBk
	sky.SkyboxDn = GoldenHour.SkyboxDn
	sky.SkyboxFt = GoldenHour.SkyboxFt
	sky.SkyboxLf = GoldenHour.SkyboxLf
	sky.SkyboxRt = GoldenHour.SkyboxRt
	sky.SkyboxUp = GoldenHour.SkyboxUp
	--[[
		No sun, no moon, no stars -- the evening is painted into the faces.

		The hour is untouched by this event, so Roblox would draw its own disc
		wherever ClockTime already has it: high overhead, at midday, in a sky
		painted as an evening. It was wrong against the previous skybox because
		that one had a sun of its own in the picture and you got two; it is wrong
		against this one for the opposite reason, since the zenith here is a flat
		wash and a hard white disc in the middle of it reads as a hole rather than
		as the sun. Stars go with it -- nothing in this picture is night.
	]]
	sky.CelestialBodiesShown = false
	sky.StarCount = 0
	return sky
end

--[[
	CLIENT-LOCAL, like everything else this event does: a Sky parented on one
	client does not replicate, so each player gets their own sunset and the
	server's Lighting never moves.
]]
local function applySky(on: boolean)
	if ReplicatedStorage:GetAttribute("PumpkinWeatherActive") == true then return end
	if on then
		if not goldenSky then goldenSky = buildSky() end
		if authoredSky then authoredSky.Parent = nil end
		(goldenSky :: Sky).Parent = Lighting
	else
		if goldenSky then (goldenSky :: Sky).Parent = nil end
		if authoredSky then authoredSky.Parent = Lighting end
	end
end

ReplicatedStorage:GetAttributeChangedSignal("PumpkinWeatherActive"):Connect(function()
 if ReplicatedStorage:GetAttribute("PumpkinWeatherActive") ~= true then
  applySky(GoldenHour.active() and GoldenHour.appliesTo(plr))
 end
end)

--==[ THE SCREEN ]============================================================

local gui = Instance.new("ScreenGui")
gui.Name = "GoldenHourHUD"
gui.ResetOnSpawn = false
-- Respect the topbar inset, and rank children against each other rather than
-- against every other ScreenGui -- both for the same reasons Shell.mount gives.
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 21
gui.Parent = plr:WaitForChild("PlayerGui")

--[[
	The countdown takes the TOP SLOT, at the same 12px the NEXT EVENT ticker sits
	at -- and sharing that slot is the point rather than a coincidence.

	It was at 76, chosen to clear the shell's cash tally and its toast lane, and
	clearing them is precisely what made it wrong: 76px is far enough down to sit
	IN the view rather than along its edge, and a bar that stands there for three
	solid minutes stops reading as a status line and starts reading as something
	in the way. (Owner's call, and right.)

	12 is where the top of this HUD is, by convention rather than by measurement:
	the area header sits at 10, the cash tally and the event ticker both at 12. So
	this is THE top, not a new position close to it.

	Taking the ticker's slot costs nothing, because the two can never be up
	together -- the scheduler clears the ticker's deadline the moment a slot is
	spent and sets no other until the event is over, see EventHandler. One place on
	screen answers "what is the event doing", and it is either counting down to one
	or counting one out.

	What this DOES share the strip with is the cash tally, a 46px block at the same
	12 that appears mid-stroke -- and during a 3x window there is a lot of
	mid-stroke. That overlap was real, and it was never this file's alone: the
	ticker had it too. Fixed together, as the note here said it should be -- the
	strip has an owner now (SealerUI.TopBand), everything in it registers, and the
	12 below is what this bar gets when it is the only thing standing there.
]]
local timer = Instance.new("Frame")
timer.Name = "Countdown"
timer.AnchorPoint = Vector2.new(0.5, 0)
timer.BackgroundColor3 = T.goldDark
timer.BorderSizePixel = 0
timer.Position = UDim2.new(0.5, 0, 0, 12)
timer.Size = UDim2.fromOffset(330, 48)
timer.Visible = false
timer.ZIndex = 4
timer.Parent = gui
UIKit.corner(timer, 14)
UIKit.stroke(timer, 2.6)
UIKit.gradient(timer)
UIKit.gloss(timer, 4, 10, 0.42).ZIndex = 5

--[[
	Shrunk with the window, on the shared fit every other block uses.

	This was fixed at 330x48, which is a fifth of a desktop and half the width of a
	handset -- and being oversized is most of what made it feel like it was sitting
	IN the view rather than along the top of it. It also overran the area title on
	anything narrower than about 772px.

	The holder is anchored (0.5, 0), and a UIScale scales about the AnchorPoint, so
	a smaller bar hugs the top edge instead of drifting down into the middle.

	Only one UIScale per instance is honoured -- this is the bar's only one, and
	nothing else here animates it, so it can simply hold the fit.
]]
local timerScale = Instance.new("UIScale")
timerScale.Parent = timer
UIKit.onFit(function(f) timerScale.Scale = f end)

-- The bar shrinks on that same fit and it is anchored (0.5, 0), so the space it
-- occupies in the strip is 48 x the fit rather than a flat 48.
TopBand.claim("GoldenHour", TopBand.Rank.GoldenHour, timer, function(f) return 48 * f end)

local timerLabel = UIKit.outlined(timer, "", 24, T.cream, 2.6)
timerLabel.Size = UDim2.fromScale(1, 1)
timerLabel.TextXAlignment = Enum.TextXAlignment.Center
timerLabel.ZIndex = 7

--[[
	The announcement card, built once and hidden rather than made on demand -- the
	same arrangement as Shell's rebirth prompt, and for the same reason: showing it
	is then one property and it cannot end up on screen twice.

	Above the middle rather than on it, so it does not land over the pail and
	nozzle a player may be holding when the window opens.
]]
local card, body = UIKit.shadowed(gui, UDim2.fromOffset(640, 158),
	UDim2.fromScale(0.5, 0.34), Vector2.new(0.5, 0.5), 24, 10)
card.Name = "Announce"
card.Visible = false
card.ZIndex = 40
body.BackgroundColor3 = T.goldDark
UIKit.stroke(body, 3)
UIKit.gradient(body, 0.9)
UIKit.gloss(body, 8, 18, 0.30).ZIndex = 5
UIKit.vignette(body, 24, 90, 0.22)

local head = UIKit.outlined(body, "", 38, T.cream, 3.4)
head.AnchorPoint = Vector2.new(0.5, 0)
head.Position = UDim2.new(0.5, 0, 0, 26)
head.Size = UDim2.new(1, -44, 0, 46)
head.TextXAlignment = Enum.TextXAlignment.Center
head.ZIndex = 8

local sub = UIKit.outlined(body, "", 30, T.white, 3)
sub.AnchorPoint = Vector2.new(0.5, 0)
sub.Position = UDim2.new(0.5, 0, 0, 86)
sub.Size = UDim2.new(1, -44, 0, 42)
sub.TextXAlignment = Enum.TextXAlignment.Center
sub.ZIndex = 8

--[[
	One UIScale, and it is the card's only one -- UIKit.bob would add a second and
	only one per instance is honoured, so the pop and a bob cannot both be had.
]]
local pop = Instance.new("UIScale")
pop.Parent = card

-- Retires an earlier card's hide, so a window that shuts moments after it opened
-- cannot have the first announcement's timer pull the second one off the screen.
local announceGen = 0

local function announce(headline: string, line: string, hold: number)
	announceGen += 1
	local gen = announceGen
	head.Text = headline
	sub.Text = line
	card.Visible = true
	pop.Scale = 0.55
	TweenService:Create(pop,
		TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
	task.delay(hold, function()
		if announceGen ~= gen then return end
		local out = TweenService:Create(pop,
			TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0 })
		out:Play()
		out.Completed:Wait()
		if announceGen ~= gen then return end
		card.Visible = false
	end)
end

--==[ THE COUNTDOWN ]=========================================================

local ticking: RBXScriptConnection? = nil

local function startTicking()
	if ticking then return end
	timer.Visible = true
	local drawn = ""
	local function draw()
		-- Read from the shared deadline every frame rather than counted down locally,
		-- so this agrees with the server and with every other player's screen -- see
		-- GoldenHour.secondsLeft.
		-- The rate is read off the flag with the deadline, every frame, so
		-- the Friday x5 hour words this bar exactly as the ordinary x3 does
		-- -- one read, one surface, and no second constant to drift out of
		-- agreement with the wallet.
		local text = ("GOLDEN HOUR \u{00D7}%d CASH   %s"):format(
			GoldenHour.currentMultiplier(),
			GoldenHour.clock(GoldenHour.secondsLeft()))
		-- a comparison a frame rather than a property write, which is the idiom the
		-- shell's own per-frame readouts use
		if text ~= drawn then
			drawn = text
			timerLabel.Text = text
		end
	end
	draw()
	ticking = RunService.Heartbeat:Connect(draw)
end

local function stopTicking()
	local c = ticking
	if c then
		c:Disconnect()
		ticking = nil
	end
	timer.Visible = false
end

--==[ CONVERGING ON THE FLAG ]================================================

--[[
	What the screen is currently showing, which is not the same question as what
	the server says.

	This is what makes the whole file idempotent: the remote and the BoolValue both
	land in refresh, and whichever arrives second does nothing. That matters
	because their order is not guaranteed -- and because the remote does not reach
	a player who joined mid-window at all, so the replicated flag has to be able to
	drive this on its own.

	nil rather than false to start, so "the first thing this client ever saw" is
	tellable from "the window just shut".
]]
local showing: boolean? = nil

--[[
	NOTHING IS DRAWN UNTIL WE KNOW WHOSE SCREEN THIS IS.

	The window does not reach a player who is still in the tutorial, and the flag
	that says whether they are arrives from the DataStore a moment after this
	script does. Every other entry to `refresh` -- the BoolValue, the remote, the
	tutorial finishing -- can land inside that moment, so the gate has to be here
	rather than only at the boot below.

	It is a local rather than a Tutorial.known call because `await` gives up after
	twenty seconds: a session where ProfileLoaded never arrives is broken in its
	own way, and answering that by withholding the sunset for the rest of it would
	be this file inventing a second failure on top of somebody else's.

	Keeping `showing` nil throughout is the point of gating rather than early
	-returning a `false`. `showing == nil` is what tells the first refresh it is
	the first, and a first sighting is drawn INSTANT and silent -- so a player
	whose profile lands mid-window arrives with the sky already gold instead of
	watching a four second sunset for a window that opened before they got here.
]]
local known = false

local function refresh()
	if not known then return end
	--[[
		Two facts, and they are different questions.

		GoldenHour.active is the server's: the window is open, for everybody, until
		EndsAt. appliesTo is this player's, and it is false while they are still
		being taught -- no sunset, no countdown, and DrivewayServer is paying them
		the ordinary rate to match. The screen and the wallet read one predicate so
		they cannot disagree.

		A player who FINISHES mid-window lands here with `showing` already false, so
		this is not a first sighting: they get the sky AND the announcement card,
		which is exactly right. The event really has just started, for them.
	]]
	local on = GoldenHour.active() and GoldenHour.appliesTo(plr)
	if on == showing then return end
	local first = showing == nil
	showing = on

	--[[
		The sky no longer cares whether this is a first sighting.

		`first` used to suppress a four second fade, so a player joining mid-window
		arrived with the sky already gold rather than watching a sunset that started
		before they got here. A skybox swap is instant for everybody, so there is
		nothing left to suppress -- but `first` still governs the ANNOUNCEMENT below,
		which is the half that always mattered.
	]]
	applySky(on)

	if on then
		startTicking()
		-- Worded exactly as the countdown bar words it, off the same read
		-- of the flag. Two surfaces stating one fact two ways is how the
		-- one a player quotes back ends up being neither. The Friday hour
		-- holds its card a beat longer: it is an hour of the player's
		-- evening, not three minutes between driveways.
		local mult = GoldenHour.currentMultiplier()
		announce("GOLDEN HOUR", ("\u{00D7}%d CASH"):format(mult),
			if mult > GoldenHour.Multiplier then 4.6 else 3.4)
	else
		stopTicking()
		-- Never on a first sighting: "Golden Hour over" shown to everybody the moment
		-- they join is an announcement about nothing having happened.
		if not first then
			announce("GOLDEN HOUR OVER", "Back to normal rates", 2.6)
		end
	end
end

--[[
	The flag is the truth. Note the refresh AFTER the wait rather than before it:
	a window that was already open when this client joined replicates as a BoolValue
	that is simply true, and a value that arrives true never fires a change signal.
	Without this line a late joiner would earn triple under a midday sky.
]]
task.spawn(function()
	local flag = ReplicatedStorage:WaitForChild(GoldenHour.StateName, 60)
	if not flag then
		warn(("[GoldenHourClient] no %s in ReplicatedStorage after 60s -- EventHandler"
			.. " is not running, so no window will ever be drawn on this screen")
			:format(GoldenHour.StateName))
		return
	end
	flag:GetPropertyChangedSignal("Value"):Connect(refresh)
	-- Connected before the wait, so a window that opens DURING it is caught by
	-- the refresh below rather than lost -- `known` makes the early fire a no-op.
	Tutorial.await(plr)
	known = true
	refresh()
end)

--[[
	And the moment the tutorial is finished, the event is theirs.

	Both attributes, which is Tutorial.onChanged's whole job: the finish is the
	obvious signal, and the profile landing is the one a returning player gets
	instead -- their TutorialDone arrives already true and so never fires a change
	of its own. Either way `refresh` decides whether anything has actually moved.
]]
Tutorial.onChanged(plr, refresh)

-- And the remote, which is a hint rather than the truth: it says "look again"
-- and refresh decides whether anything has actually changed.
task.spawn(function()
	local remotes = Pack:WaitForChild("Remotes", 60)
	local ev = remotes and remotes:WaitForChild(GoldenHour.RemoteName, 60)
	if ev and ev:IsA("RemoteEvent") then
		ev.OnClientEvent:Connect(function() refresh() end)
	end
end)
