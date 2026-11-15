--!strict
--[[
	TutorialClient -- the first job, taught by making the player do it.

	Nothing in here explains a mechanic the player could learn by being made to
	perform it. The card carries ONE line of two to five words, the keys that line
	needs drawn as keycaps, and a bar when the step is measured. Everything else --
	where to go, what to touch, which way to sweep -- is said out in the world with
	a marker, an outline and a row of moving chevrons, because a picture of the
	answer is read by players who will not read a sentence about it.

	FIVE numbered objectives, several of which have two or three BEATS. A beat is a
	single instruction -- "take the sealer", then "pour it all out" -- and it earns
	its own tick when it completes but does NOT move the counter, because the
	player is still on the same job. That split is what keeps "what do I do right
	now" down to one short line without the run reading as twelve steps long.

	The beat is DERIVED from the world every frame rather than kept as a cursor.
	Running dry, wandering off, rejoining a day later are all questions about the
	world right now, not about how far down a list somebody walked. The only
	per-session memory is a handful of latches, and every one of them is
	re-inferable from the slab -- see `relatch`.

	WHAT THIS FILE DOES NOT OWN: TutSealed, TutBought, TutorialDone and DepotSealed
	belong to DepotGate on the server, because they are worth money and a door.
	This reads them and never writes them.
]]

--[[
	THE FIRST JOB IS A FRONT WALK NOW, NOT A DRIVEWAY (2026-08-13, owner's call:
	"people keep leaving after step 4").

	Objective 4 -- finish the slab, unaided -- was where the run was losing people,
	and the slab was the reason. 30 x 20 is three blade-widths across, so covering
	it means laying lanes and remembering which ones you laid; the honest limit in
	Config's easy-flow note is that a player who only ever pushes ONE WAY plateaus
	at 0.88 and never finishes at any fluid setting. That is a shape problem, and no
	amount of thinner sealer fixes it.

	So the job is House_114's front walk instead: 40 x 8, the same strip every other
	lot on the map has in front of its door. It is 8 studs wide against a 6.4-stud
	blade, so one stroke down it and one back IS the lane plan -- the failure that
	was costing us the step cannot happen on it -- and it is a bit over half the
	ground, so the step is shorter as well as easier.

	IT PAYS EXACTLY WHAT THE DRIVEWAY PAID. The slab's PayScale carries that; see
	the note on Economy.scaleOf, and DepotGate's startup check, which prints the
	figure against the 1,200 gate on every boot.

	The part is still NAMED Driveway and has to stay that way: Sections.keyOf is a
	slab's full path, so renaming it would un-finish it for everybody who has
	already sealed it and shut the Neighbourhood gate behind them. What the player
	reads is the DrivewayName attribute and the titles below.
]]

--[[
	THE RECLAIM BEAT IS GONE (2026-08-11), and this note is here because this file
	was swapped in from ReplicatedStorage.TutorialStaging on the same day the
	mechanic was removed, which is how it briefly shipped teaching one.

	Setting the pail down on a finished driveway and sweeping the leftovers back in
	no longer exists, in either its manual or its Auto Reclaim form: a slab settles
	to cured coat on the frame it is called done and takes the loose sealer with it,
	and the Auto Reclaim game pass is delisted. Objective 4's second beat, its three
	RECLAIM_ constants and its latches came out; nothing renumbered, because it was
	a beat and not an objective. See the tombstone where it stood.

	⚠ `loose` and `looseAt` are NOT part of that removal even though the reclaim
	beat was their loudest reader. They were pruned from HudBus the same afternoon
	on exactly that reasoning and had to be put straight back: this file gates its
	pour beat on `loose` and anchors START HERE and the sweep chevrons on `looseAt`.
	Check those two before pruning them again.
]]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Pack = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(Pack:WaitForChild("UIKit"))
local TopBand = require(Pack:WaitForChild("TopBand"))
local HudBus = require(Pack:WaitForChild("HudBus"))
local HudActions = require(Pack:WaitForChild("HudActions"))
local Sealer = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Sealer:WaitForChild("Config"))
local Depot = require(Sealer:WaitForChild("Depot"))
local SoundKit = require(Sealer:WaitForChild("SoundKit"))

local plr = Players.LocalPlayer

local NAVY  = Color3.fromRGB(38, 44, 56)
local CREAM = Color3.fromRGB(236, 233, 222)
local GOLD  = Color3.fromRGB(255, 214, 92)
local LIME  = Color3.fromRGB(126, 255, 118)
local SLATE = Color3.fromRGB(84, 94, 110)

-- Six pips, and the number is fixed. The old card grew and shrank its row
-- depending on whether the reclaim step turned out to apply, which meant the
-- player watched "OF 5" become "OF 6" halfway through -- the one thing a
-- progress readout must never do. Reclaim was demoted to a BEAT inside objective
-- four to settle that, and then removed outright with the mechanic itself
-- (2026-08-11), which is the same answer twice over: the denominator is a
-- constant and no beat may change it.
--
-- Six became FIVE on 2026-08-11, when the depot apron stopped being the last
-- objective (owner's call). It was a third slab to the same recipe after the
-- loop had already been taught, and the gate it used to open now comes off
-- finishing the tutorial itself -- see DEPOT_ATTR.
local OBJECTIVES = 5

--[[
	The flag that says the run is over and the map is open.

	Set server-side by DepotGate alongside TutorialDone, and persisted with the
	profile, so it is also what tells a returning player they have nothing left to
	owe.

	IT IS NO LONGER NAMED FOR WHAT IT MEANS. It used to be "the depot apron is
	sealed", which was a second stage this run does not have any more; the name is
	kept because it is the key every saved profile already stores this under, and
	renaming it would hand the whole map back to everybody who has finished.
]]
local DEPOT_ATTR = "DepotSealed"

--==[ gates ]=================================================================
--[[
	The numbers the run is scored against, in one place.

	Every one of them is a share of something the simulation already measures, so
	none of them drift when the economy is retuned: POUR_SHARE is a share of
	whatever the pail currently holds, FIRST_PASS and the finish bar are shares of
	the slab.
]]
-- How much of a pail has to land ON OUR SLAB before the pour step can tick off.
-- This is the whole point of the redesign: a player who dribbles a cupful and
-- starts squeegeeing has learned the wrong game.
--
-- It is no longer the whole gate. The step now waits for the pail to be genuinely
-- empty as well -- see the pour gate below -- because this share on its own ticked
-- the step with sealer still visibly in the pail, which is the one thing the
-- card's own wording promises it will not do. What the share still decides is
-- whether the sealer went on THIS driveway or on the road beside it.
local POUR_SHARE = 0.85
--[[
	Coverage that counts as "you have done a pass and you understand it".

	The rule has not changed and neither has the reason for it: the chevrons and
	the start ring have to come off while the player is still MOVING, not at the
	moment they stop, or the tutorial reads as having waited for them to finish
	something before admitting they had understood it. What changed is the slab.

	The stock blade is 6.4 studs wide. On the old 30 x 20 driveway one sweep down
	the short axis laid 6.4 x 20 / 600 = 21%, and 0.12 was a little over half of
	that. On the 40 x 8 front walk one sweep runs the LONG axis and lays
	6.4 x 40 / 320 = 80%, so 0.12 is an eighth of a stroke -- about a second and a
	half of walking, which is the guidance vanishing before it has been read.

	0.30 is the same fraction of the same gesture as 0.12 used to be: a bit over a
	third of the way down the first stroke, roughly fifteen studs in.
]]
local FIRST_PASS = 0.30

-- A pail with less than this in it is empty, and the beats that send you to the
-- pump key off it. Named rather than spelled 0.03 in three places because the
-- STALL block below is defined as its complement: above this line you are told to
-- pour what you have, below it you are told to go and fill up, and a gap between
-- the two would be a state with no instruction in it.
local PAIL_EMPTY = 0.03

--[[
	The pail is FULL, and the refill lesson is over.

	Not 1.0: the level is a float summed off a per-frame fill rate and read through
	HudBus, so it settles a hair under the cap often enough that holding out for the
	last thousandth would leave a player stood at the pump with a bar reading 100%
	and a step that will not tick.
]]
local FILL_FULL = 0.97
--[[
	How much has to go back INTO the pail, in one session, for the player to be
	counted as already taught where sealer comes from.

	Half a pail rather than any rise at all, because a rise of one frame is what you
	get from brushing past the pump: the lesson is holding the key and watching the
	bar climb, and half a pail is about two and a half seconds of that at the stock
	rate. Only consulted while the driveway is unfinished -- see `refilled`.
]]
local FILL_SHARE = 0.5

--[[
	Nothing left on the ground to push, as a share of a pail.

	A share rather than an absolute so it survives a Bucket Capacity upgrade, and
	generous: a squeegee can do nothing useful with two percent of a pail spread
	over a 36 x 24 slab, and waiting for a true zero would mean waiting for a figure
	the solver only reaches once the last cell has cured.
]]
local STALL_LOOSE = 0.02
--[[
	How long the slab has to stay bare before the reminder appears.

	Timed rather than instant, and the delay is doing real work. `lastLoose` is
	legitimately near zero twice in normal play -- in the moment between two pours,
	and at the tail of a pass that has just scraped the last of the bead forward --
	and a beat that flickered in on either would read as the card losing its place.
]]
local STALL_PATIENCE = 2.0

-- How long a finished beat sits on screen wearing its tick before the next one
-- slides in. Long enough to register as a reward, short enough that nobody feels
-- held up.
local TICK_HOLD = 0.62
-- A beat that came and went faster than this gets no tick. Derived state can
-- resolve a step in one frame -- walking onto a driveway that is already half
-- sealed settles three latches at once -- and a tick for something the player
-- never saw themselves do reads as the interface glitching.
local TICK_MIN = 0.4
-- How long the finale sits before the whole thing tears itself down.
local HOLD_DONE = 6

--==[ which controls this player actually has ]===============================
--[[
	Re-asked every frame rather than decided once at load.

	The old card latched "is this a touch device" on its first frame, which is
	wrong on every hybrid -- a tablet with a case keyboard, a laptop with a
	touchscreen. The question worth answering is what the player touched LAST, and
	Roblox reports exactly that.

	TWO ANSWERS, because only two are true of this game. The tools are bound to
	the mouse button and to a ContextActionService touch button and to nothing
	else; there is no gamepad binding anywhere in DrivewayClient (see USE_TOOLS).
	A cap reading [RT] over a trigger that does nothing would be worse than no cap
	at all, so a pad falls through to the keyboard wording -- which at least names
	something the player can reach for.
]]
local touchNow = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

UserInputService.LastInputTypeChanged:Connect(function(t: Enum.UserInputType)
	if t == Enum.UserInputType.Touch then
		touchNow = true
	elseif t == Enum.UserInputType.Keyboard
		or t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.MouseMovement then
		touchNow = false
	end
end)

--[[
	One control, drawn as the key it is.

	`cap` is what is printed on the keycap. `keys` is the diagram case -- several
	keys that are one control, drawn as separate caps the way a manual would draw
	them, which is the whole of W A S D.

	The two are kept apart rather than splitting `cap` on spaces, and that is not
	fussiness: the touch build's caps are WORDS, and "PAIL DOWN" split on its space
	would draw as two keys that do not exist.

	`note` is at most three words and says what working it does. Anything longer is
	a sentence with a picture next to it, which is the thing this card exists to
	stop being.
]]
export type Chip = {
	cap: string?,
	keys: { string }?,
	note: string?,
	hold: boolean?,     -- lean on it rather than tap it
	action: string?,    -- HudActions channel; on touch the cap IS the button
}

-- Both halves are written out at the call site rather than one derived from the
-- other, because the two do not name the same objects: there is no 1 key on a
-- phone and no mouse button to lean on. Deriving is how you end up telling
-- somebody to tap the 1.
local function chip(keyboard: Chip, touch: Chip): Chip
	return if touchNow then touch else keyboard
end

--==[ where everything is ]===================================================
--[[
	Looked up once and kept, but re-resolved whenever the cached part has been
	unparented: the depot streams, so an early call can find nothing and a later
	one still has to succeed.
]]
local cachedDrive: BasePart? = nil
local function drivewayPart(): BasePart?
	if cachedDrive and cachedDrive.Parent then return cachedDrive end
	local hood = workspace:FindFirstChild("Neighbourhood")
	local pave = hood and hood:FindFirstChild("Pavement")
	local lot = pave and pave:FindFirstChild("Lot_114")
	local d = lot and lot:FindFirstChild("Driveway")
	cachedDrive = if d and d:IsA("BasePart") then d else nil
	return cachedDrive
end

-- What HudBus calls this slab, so its coverage can be told from any other's.
-- HudBus reports whichever surface the HELD TOOL is working on, which is very
-- often not the one underfoot -- see the note over `relatch`.
local function driveName(): string?
	local d = drivewayPart()
	if not d then return nil end
	return (d:GetAttribute("DrivewayName") :: string?) or d.Name
end

local function drivewaySpot(): Vector3?
	local d = drivewayPart()
	return if d then d.Position + Vector3.new(0, 0.5, 0) else nil
end

-- Exact tutorial destinations. These stay as lookups instead of cached hard refs
-- because the depot may stream out and back in.
local function depotGarage(): Instance?
	local hood = workspace:FindFirstChild("Neighbourhood")
	local depot = hood and hood:FindFirstChild("Depot")
	return depot and depot:FindFirstChild("Garage")
end

local function pumpPart(): BasePart?
	local garage = depotGarage()
	local refuel = garage and garage:FindFirstChild("Refuel")
	local dripTray = refuel and refuel:FindFirstChild("DripTray")
	return if dripTray and dripTray:IsA("BasePart") then dripTray else nil
end

local function groundSpot(part: BasePart?): Vector3?
	if not part then return nil end
	-- Base/DripTray are the WORLD targets; the walk marker belongs at their feet,
	-- not at the centre of a screen/counter several studs above the floor.
	return Vector3.new(part.Position.X,
		part.Position.Y - part.Size.Y * 0.5 + 0.12,
		part.Position.Z)
end

local function refuelSpot(): Vector3?
	return groundSpot(pumpPart())
end

local function counterPart(): BasePart?
	local garage = depotGarage()
	local counter = garage and garage:FindFirstChild("Counter")
	local terminal = counter and counter:FindFirstChild("ShopTerminal")
	local base = terminal and terminal:FindFirstChild("Base")
	return if base and base:IsA("BasePart") then base else nil
end

local function counterSpot(): Vector3?
	return groundSpot(counterPart())
end

local function mapExitPart(): BasePart?
	local hood = workspace:FindFirstChild("Neighbourhood")
	local depot = hood and hood:FindFirstChild("Depot")
	local apron = depot and depot:FindFirstChild("DepotApron")
	return if apron and apron:IsA("BasePart") then apron else nil
end

local function mapExitSpot(): Vector3?
	local apron = mapExitPart()
	if not apron then return nil end
	return Vector3.new(apron.Position.X,
		apron.Position.Y + apron.Size.Y * 0.5 + 0.12,
		apron.Position.Z)
end

local function rootPart(): BasePart?
	local ch = plr.Character
	local r = ch and ch:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

-- What is in the player's hand right now. Read off the character rather than off
-- HudBus, because HudBus reports the tool it last had a job for and this has to
-- answer "have you equipped it yet" on the frame they do.
local function heldTool(): string?
	local ch = plr.Character
	local t = ch and ch:FindFirstChildOfClass("Tool")
	return if t then t.Name else nil
end

--==[ the card ]==============================================================
--[[
	Small, and that is the point of it.

	What this replaces was 660 wide with a paragraph inside it and up to three
	rows of keycap under that -- a third of a phone screen, parked over the busiest
	strip of the display, for as long as it takes to earn and spend the first
	payout. Nobody read it. What is left is a title, six pips, one bar and at most
	two keys, and the whole thing is shorter than one line of the old body copy.
]]
local gui = Instance.new("ScreenGui")
gui.Name = "SealerTutorial"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 25
gui.Enabled = false
gui.Parent = plr:WaitForChild("PlayerGui")

local card = Instance.new("Frame")
card.Name = "Card"
card.AnchorPoint = Vector2.new(0.5, 0)
card.Position = UDim2.fromOffset(0, 14)
card.Size = UDim2.fromOffset(460, 0)
card.AutomaticSize = Enum.AutomaticSize.Y
card.BackgroundColor3 = NAVY
card.BorderSizePixel = 0
card.ZIndex = 30
card.Parent = gui
UIKit.corner(card, 14)
-- Kept on its own handle: the tick flashes it lime and it has to go back to ink.
local cardStroke = UIKit.stroke(card, 2.6)
-- A UIGradient rather than a decorative child frame, and that is not a style
-- choice: the card lays its rows out with a UIListLayout, which lays out EVERY
-- visible child, so a sheen panel would be positioned as another row. A gradient
-- is not a GuiObject and the layout never sees it.
UIKit.gradient(card, 0.55)

-- The pop is a scale rather than a size tween: the card measures itself, and
-- animating Size would fight AutomaticSize every frame.
local cardScale = Instance.new("UIScale")
cardScale.Parent = card

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 9)
pad.PaddingBottom = UDim.new(0, 11)
pad.PaddingLeft = UDim.new(0, 16)
pad.PaddingRight = UDim.new(0, 16)
pad.Parent = card

local rows = Instance.new("UIListLayout")
rows.SortOrder = Enum.SortOrder.LayoutOrder
rows.Padding = UDim.new(0, 6)
rows.Parent = card

--[ header: the word TUTORIAL, and how much of it is left ]--------------------
local header = Instance.new("Frame")
header.Name = "Header"
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, 16)
header.LayoutOrder = 1
header.ZIndex = 31
header.Parent = card

local crumb = UIKit.label(header, "TUTORIAL", 13, GOLD)
crumb.Size = UDim2.new(1, -120, 1, 0)
crumb.TextXAlignment = Enum.TextXAlignment.Left
crumb.ZIndex = 31

-- Pips, so "how much of this is left" is answerable without reading a word.
local pipRow = Instance.new("Frame")
pipRow.BackgroundTransparency = 1
pipRow.AnchorPoint = Vector2.new(1, 0.5)
pipRow.Position = UDim2.new(1, 0, 0.5, 0)
pipRow.Size = UDim2.fromOffset(112, 11)
pipRow.ZIndex = 31
pipRow.Parent = header

local pipLayout = Instance.new("UIListLayout")
pipLayout.FillDirection = Enum.FillDirection.Horizontal
pipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
pipLayout.Padding = UDim.new(0, 5)
pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
pipLayout.Parent = pipRow

local pips: { Frame } = {}
for i = 1, OBJECTIVES do
	local p = Instance.new("Frame")
	p.Size = UDim2.fromOffset(13, 10)
	p.BackgroundColor3 = SLATE
	p.BorderSizePixel = 0
	p.LayoutOrder = i
	p.ZIndex = 32
	p.Parent = pipRow
	UIKit.corner(p, 4)
	UIKit.stroke(p, 1.5)
	pips[i] = p
end

--[ the instruction itself ]---------------------------------------------------
-- Everything else on this card is furniture. Two to five words, and they are set
-- in the display face at a size nobody can claim not to have noticed.
local title = UIKit.label(card, "", 27, CREAM)
title.Name = "Objective"
title.Font = UIKit.Display
title.Size = UDim2.new(1, 0, 0, 0)
title.AutomaticSize = Enum.AutomaticSize.Y
title.TextWrapped = true
title.TextXAlignment = Enum.TextXAlignment.Left
title.LayoutOrder = 2
title.ZIndex = 31
UIKit.stroke(title, 2.4, nil, true)

--[ the bar, on the steps that are measured ]----------------------------------
--[[
	Only on beats whose completion is a QUANTITY, and it always reaches exactly
	100% on the frame the beat ticks off -- it is drawn straight off the same
	fraction the gate is testing. A progress bar that fills to 90% and stops, or
	one that finishes early and then waits, teaches the player to stop trusting it.
]]
local barRow = Instance.new("Frame")
barRow.Name = "Bar"
barRow.BackgroundTransparency = 1
barRow.Size = UDim2.new(1, 0, 0, 16)
barRow.LayoutOrder = 3
barRow.Visible = false
barRow.ZIndex = 31
barRow.Parent = card

local barWell = Instance.new("Frame")
barWell.AnchorPoint = Vector2.new(0, 0.5)
barWell.Position = UDim2.new(0, 0, 0.5, 0)
barWell.Size = UDim2.new(1, -104, 0, 11)
barWell.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
barWell.BorderSizePixel = 0
barWell.ZIndex = 31
barWell.Parent = barRow
UIKit.corner(barWell, 6)
UIKit.stroke(barWell, 1.8)

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = GOLD
barFill.BorderSizePixel = 0
barFill.ZIndex = 32
barFill.Parent = barWell
UIKit.corner(barFill, 6)

local barCap = UIKit.label(barRow, "", 14, CREAM)
barCap.AnchorPoint = Vector2.new(1, 0.5)
barCap.Position = UDim2.new(1, 0, 0.5, 0)
barCap.Size = UDim2.fromOffset(98, 16)
barCap.TextXAlignment = Enum.TextXAlignment.Right
barCap.ZIndex = 31

-- Eased toward the true figure rather than written to it. `loose` and the
-- coverage readout both arrive off a scan that runs in uneven bites, and a bar
-- that jitters backwards reads as the game losing track of what you did.
local barShown = 0

--==[ the keys ]==============================================================
--[[
	At most two chips, laid left to right, and INERT on desktop.

	That inertness is inherited from the card this replaces and it is deliberate:
	most of these beats are played with the button held down, and a live button up
	there would swallow strokes that started under it. With Active false the click
	passes through to the world and the cap is just a picture of a key.

	On touch a chip MAY be the control -- see the reclaim beat, where there is no G
	to press and the cap is the only way to set the pail down at all.
]]
local CHIP_MAX = 2
local CAP_H = 38

local chipRow = Instance.new("Frame")
chipRow.Name = "Chips"
chipRow.BackgroundTransparency = 1
chipRow.Size = UDim2.new(1, 0, 0, CAP_H)
chipRow.LayoutOrder = 4
chipRow.Visible = false
chipRow.ZIndex = 31
chipRow.Parent = card

local chipLayout = Instance.new("UIListLayout")
chipLayout.FillDirection = Enum.FillDirection.Horizontal
chipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
chipLayout.Padding = UDim.new(0, 14)
chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
chipLayout.Parent = chipRow

-- Cap width is arithmetic rather than AutomaticSize, because the hold bar has to
-- run to the cap's own edges and a cap that measures itself changes width as the
-- text inside it changes -- which on a latch (POUR becoming STOP) would shuffle
-- the whole row sideways mid-press.
local function capWidth(text: string): number
	return if #text <= 2 then 46 else 18 + #text * 13
end

-- Four keys is the most any cue asks for; W A S D is the only one that uses them
-- all and there is nothing sensible past it.
local CAPS_PER_CHIP = 4

type CapView = { btn: TextButton, fill: Frame }
type ChipView = { holder: Frame, caps: { CapView }, note: TextLabel }
local chips: { ChipView } = {}
-- which HudActions channel each chip is standing in for right now, if any
local chipAction: { [number]: string? } = {}

for i = 1, CHIP_MAX do
	local holder = Instance.new("Frame")
	holder.Name = "Chip" .. i
	holder.BackgroundTransparency = 1
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Size = UDim2.fromOffset(0, CAP_H)
	holder.LayoutOrder = i
	holder.Visible = false
	holder.ZIndex = 31
	holder.Parent = chipRow

	local inner = Instance.new("UIListLayout")
	inner.FillDirection = Enum.FillDirection.Horizontal
	inner.VerticalAlignment = Enum.VerticalAlignment.Center
	inner.Padding = UDim.new(0, 5)
	inner.SortOrder = Enum.SortOrder.LayoutOrder
	inner.Parent = holder

	local caps: { CapView } = {}
	for k = 1, CAPS_PER_CHIP do
		local btn = Instance.new("TextButton")
		btn.Name = "Cap" .. k
		btn.Size = UDim2.fromOffset(46, CAP_H)
		btn.BackgroundColor3 = CREAM
		btn.Active = false
		btn.AutoButtonColor = false
		btn.Font = UIKit.Display
		btn.Text = ""
		btn.TextSize = 22
		btn.TextColor3 = NAVY
		-- the hold bar runs to the cap's edges and the rounded corner has to cut it
		btn.ClipsDescendants = true
		btn.LayoutOrder = k
		btn.Visible = false
		btn.ZIndex = 32
		btn.Parent = holder
		UIKit.corner(btn, 9)
		UIKit.stroke(btn, 2.4)

		--[[
			The tell that a control is a hold rather than a tap.

			Colour alone could not carry it: the caps are cream and gold on a navy
			card, and on touch a cap is a WORD rather than a letter, so the difference
			between two coloured word-shaped boxes is not something anyone notices at a
			glance. A bar that keeps sweeping the foot of the cap is a picture of the
			gesture itself, and it reads before the words do.
		]]
		local fill = Instance.new("Frame")
		fill.Name = "Hold"
		fill.AnchorPoint = Vector2.new(0, 1)
		fill.Position = UDim2.new(0, 0, 1, 0)
		fill.Size = UDim2.new(0, 0, 0, 5)
		fill.BackgroundColor3 = NAVY
		fill.BackgroundTransparency = 0.4
		fill.BorderSizePixel = 0
		fill.Visible = false
		fill.ZIndex = 33
		fill.Parent = btn

		btn.MouseButton1Click:Connect(function()
			local channel = chipAction[i]
			if touchNow and channel then HudActions.fire(channel) end
		end)

		caps[k] = { btn = btn, fill = fill }
	end

	local note = UIKit.label(holder, "", 16, CREAM)
	note.AutomaticSize = Enum.AutomaticSize.X
	note.Size = UDim2.fromOffset(0, CAP_H)
	note.TextXAlignment = Enum.TextXAlignment.Left
	note.LayoutOrder = CAPS_PER_CHIP + 1
	note.ZIndex = 31

	chips[i] = { holder = holder, caps = caps, note = note }
end

-- How long the hold bar takes to cross a cap. Long enough to read as "keep it
-- down" rather than as something being loaded.
local HOLD_SWEEP = 1.2

local function setChips(list: { Chip }?)
	local want: { Chip } = list or {}
	chipRow.Visible = #want > 0
	if not chipRow.Visible then return end

	for i, view in ipairs(chips) do
		local c = want[i]
		chipAction[i] = if c then c.action else nil
		if not c then
			view.holder.Visible = false
			continue
		end
		view.holder.Visible = true

		local tokens = c.keys or { c.cap or "" }
		for k, cap in ipairs(view.caps) do
			local word = tokens[k]
			cap.btn.Visible = word ~= nil and word ~= ""
			if not cap.btn.Visible then
				continue
			end
			cap.btn.Text = word
			cap.btn.Size = UDim2.fromOffset(capWidth(word), CAP_H)
			cap.btn.TextSize = if #word <= 2 then 22 else 17
			cap.btn.BackgroundColor3 = if c.hold then GOLD else CREAM
			-- live only where the press has somewhere to go; see the note above
			cap.btn.Active = touchNow and c.action ~= nil
			cap.btn.AutoButtonColor = cap.btn.Active

			cap.fill.Visible = c.hold == true
			if c.hold then
				cap.fill.Size = UDim2.new((os.clock() % HOLD_SWEEP) / HOLD_SWEEP, 0, 0, 5)
			end
		end

		view.note.Visible = c.note ~= nil and c.note ~= ""
		view.note.Text = c.note or ""
	end
end

--==[ the nudge ]=============================================================
-- One short line, and it is the ONLY text on this card that is not an
-- instruction. It appears when the player has genuinely stalled and nowhere
-- else -- see the escalation block down in the loop.
local nudge = UIKit.label(card, "", 15, GOLD)
nudge.Name = "Nudge"
nudge.Size = UDim2.new(1, 0, 0, 17)
nudge.TextXAlignment = Enum.TextXAlignment.Left
nudge.LayoutOrder = 5
nudge.Visible = false
nudge.ZIndex = 31

--==[ fitting it on the screen ]==============================================
--[[
	MEASURED off the shell, not copied from it.

	The reasoning is inherited from the card this replaces and has not changed: the
	shell keeps a block down the top left and a key rail down the right, so a card
	centred on the screen lands on top of the area title on anything narrower than a
	wide desktop window -- covering the driveway's own name while telling the player
	to go and seal it. So the card is centred in the GAP between the two, pulled back
	to the true centre whenever that still clears them, narrowed if the gap is
	tighter than its natural width, and only if that would leave it unreadable does
	it drop under the area block and span the screen.

	What changed is where those two widths come from. They were written here as the
	shell's desktop offsets -- 460 for the block, 82 for the rail -- copied by hand
	and true of exactly one size of window. The shell fits itself to the window now
	(see SealerUI.Shell), so on a handset that block is 285 wide and the rail has
	wrapped into two columns at 146. Both copies were wrong, and both were wrong in
	the direction that hurts: together they claimed a 196px gap where there was
	really 348, so the card took the narrow branch it did not need -- and that
	branch is the one that drops it 294px down the screen. 294px down a 375-tall
	phone is the hotbar. The card was being drawn over the very keys it was naming.

	So it asks the shell how big it actually is. The old numbers survive as the
	fallback for the frames before the shell exists, since the two are separate
	scripts with no ordering between them.
]]
--[[
	The GUI's own space, which is NOT the viewport.

	This card and the shell both sit in ScreenGuis with IgnoreGuiInset false, so the
	space they lay out in starts below Roblox's topbar and is shorter than the
	window by an inset that differs per device -- AfkClient carries the same note
	for the same reason. Laying out against the raw viewport puts everything an
	inset lower than it meant to be, which on a phone is most of the way onto the
	hotbar before anything else has gone wrong.

	Computed rather than read off `gui.AbsoluteSize`, which would be the obvious
	way to get it and does not work: a ScreenGui that is DISABLED is not laid out,
	and its AbsoluteSize sits at a stale 800x600 -- measured, in a playtest, on this
	very card. The card is disabled for all of a finished player's session and for
	the first seconds of everybody's, so that is the state it would be sized in.

	The 200px guard is the cold join, where the camera reports 1x1 until the first
	frame is drawn. Nothing that small is a window; the real size arrives on the
	ViewportSize signal a moment later and restyles from there.
]]
local function screen(): Vector2
	local cam = workspace.CurrentCamera
	local v = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	if v.X < 200 or v.Y < 200 then v = Vector2.new(1280, 720) end
	return Vector2.new(v.X, math.max(1, v.Y - GuiService:GetGuiInset().Y))
end

local FALLBACK_AREA = 24 + 460 + 14   -- shell area block at full size, plus a gap
local FALLBACK_RAIL = 22 + 82 + 14    -- shell icon rail at full size, plus a gap
local FALLBACK_DROP = 294
local EDGE_GAP  = 14
local CARD_MAX  = 460
-- 300 rather than the 320 it was: with the shell fitting itself to the window, a
-- phone leaves almost exactly 320 between the block and the rail, and a threshold
-- sitting on top of the commonest answer decides that case by rounding.
local CARD_MIN  = 300

--[[
	The shell's own blocks, or nil until it has built them.

	`shell` is set by the watcher at the foot of this section rather than looked up
	here. The Visible test earns its keep on the hotbar: that row is taken off the
	screen while the player is driving, and a floor measured off a hidden row would
	pin the card halfway up the screen for the whole of a delivery.
]]
local shell: Instance? = nil
local function shellBlock(name: string): GuiObject?
	local sh = shell
	if not sh or not sh.Parent then return nil end
	local f = sh:FindFirstChild(name)
	return if f and f:IsA("GuiObject") and f.Visible and f.AbsoluteSize.X > 0
		then f :: GuiObject
		else nil
end

local baseY, baseX = 14, 0

--[[
	Put the card where restyle asked unless that runs it into something.

	MEASURED rather than predicted, which is why it is not folded into restyle:
	AbsoluteSize is the only thing that knows how many lines the title wrapped to
	and whether this beat has a bar, and both change while the card is up.

	The floor is the HOTBAR, not the bottom of the screen, and that is the other
	half of the bug above: a card too tall for the space it was given slides up
	until it fits on the screen, and what is at the bottom of the screen is the tool
	keys. Where the squeeze is bad enough that it has to overlap something anyway it
	takes the area block instead -- a covered title is a name the player has already
	read, a covered hotbar is a control they cannot find.
]]
--[[
	ON A SHORT WINDOW THE CARD CLIMBS INTO ROBLOX'S OWN TOPBAR BAND.

	This gui sits below the topbar inset, so y 0 is already 58 pixels down on a
	desktop and about that on a handset. On a desktop that costs nothing -- the
	card is a fifth of the height and there is room underneath it for the whole
	game. On a phone in landscape the usable height is barely three hundred pixels,
	the same card is close to half of it, and those 58 pixels are the difference
	between a card ALONG the top and a card sitting in the middle of the driveway
	the player is being told to pour on.

	The band is not actually spoken for. GuiService.TopbarInset is the FREE
	rectangle of it -- Roblox's own buttons run from the left edge to its Min.X and
	the rest is empty -- so a card that starts to the right of that can stand in it
	without covering anything. Both halves are checked rather than assumed, because
	both move: the chrome's width is a platform decision, and the card's own left
	edge is wherever restyle could fit it between the area block and the rail.

	TIGHT is what makes this a mobile change and not a change. A card taking under
	a third of the height it stands in is not in anybody's way and does not move --
	which on the desktop this HUD was drawn for is every card, always.
]]
local TOPBAR_CLEAR = 10
local TIGHT = 0.30

local function lift(): number
	local inset = GuiService:GetGuiInset().Y
	if inset <= 0 then return 0 end

	local vp = screen()
	if math.ceil(card.AbsoluteSize.Y) < vp.Y * TIGHT then return 0 end

	--[[
		The card's left edge in SCREEN pixels, which is not its own AbsolutePosition.

		AbsolutePosition is measured inside the gui's frame, and on a device with a
		display cutout that frame is inset from the glass on both sides -- so a card
		at gui-x 340 is at screen-x 390, and it is the screen figure that has to be
		compared against TopbarInset. The inset is read off the SHELL's gui rather
		than this one: this gui is disabled between beats and a disabled ScreenGui
		reports a stale 800x600, which is the trap the note over screen() describes.
	]]
	local side = if shell and shell.AbsoluteSize.X > 200
		then math.max(0, (vp.X - shell.AbsoluteSize.X) * 0.5)
		else 0
	local left = side + baseX - math.ceil(card.AbsoluteSize.X * 0.5)
	if left < GuiService.TopbarInset.Min.X + TOPBAR_CLEAR then return 0 end

	-- All of the band bar a hairline, so the card reads as being ALONG the top
	-- edge rather than tucked under it.
	return math.max(0, inset - 6)
end

local function place()
	local vp = screen()
	local floor = vp.Y - 10
	local hotbar = shellBlock("Hotbar")
	if hotbar then floor = math.min(floor, hotbar.AbsolutePosition.Y - 10) end
	-- The squeeze against the hotbar is worked out where the card normally lives
	-- and the whole answer is then raised, so the lift is exactly the lift and
	-- cannot interact with the clamp.
	local y = math.min(baseY, math.max(8, floor - math.ceil(card.AbsoluteSize.Y))) - lift()
	if card.Position.Y.Offset ~= y or card.Position.X.Offset ~= baseX then
		card.Position = UDim2.fromOffset(baseX, y)
	end
	-- This card stands in the same top-centre strip as the cash tally and the toast
	-- lane, and it moved just now -- so whatever is stacked under it is stale. See
	-- the reserve below for why this file keeps its own placement.
	TopBand.refresh()
end

--[[
	The card RESERVES the top of the strip rather than being placed in it.

	Everything else in there is a fixed-size block that TopBand can simply put
	somewhere. This one is not: it grows with its own copy, and place() above
	clamps it upward against the hotbar so that a card too tall for the space
	covers the area title instead of the tool keys -- a rule that belongs to this
	file and would have to be reimplemented to move it. So it keeps the pen and
	reports where it ENDS, and the tally and the toast lane start below that.

	nil while it is not up, which is the ordinary state: the gui is disabled
	outright between beats, and a disabled ScreenGui's children still read Visible.
]]
TopBand.reserve("Tutorial", function(): number?
	if not gui.Enabled or not card.Visible then return nil end
	return card.Position.Y.Offset + math.ceil(card.AbsoluteSize.Y)
end)

--[[
	The card's OWN height is watched, and both of the things that read it are the
	reason why.

	It is AutomaticSize.Y, so it changes between beats without anything else on the
	screen moving -- a title that wraps to two lines, a beat that carries a bar, one
	that carries two keycaps. Nothing re-ran the placement on that before, and it
	did not matter while the only thing place() did with the height was clamp it
	against the hotbar, which almost never binds. It matters now: lift() decides
	whether the card climbs into the topbar band by comparing that height against
	the window, and the TopBand reserve above hands the card's BOTTOM to everything
	stacked under it. Both would be answering for the previous beat.

	place() rather than restyle(): a card that got taller has not changed which
	gap between the area block and the rail it has to fit into. It cannot loop --
	place only ever writes Position.

	Enabled likewise. It is the switch the whole card goes on and off with, and the
	reserve reads it, so the strip has to be told when it moves or the tally and the
	toast lane stay parked below a card that is no longer there.
]]
card:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
gui:GetPropertyChangedSignal("Enabled"):Connect(TopBand.refresh)

local function restyle()
	local vp = screen()
	local area = shellBlock("Area")
	local rail = shellBlock("Rail")
	-- the band each of them owns, measured in from its own edge of the screen
	local left = if area
		then area.AbsolutePosition.X + area.AbsoluteSize.X + EDGE_GAP
		else FALLBACK_AREA
	local right = if rail
		then vp.X - rail.AbsolutePosition.X + EDGE_GAP
		else FALLBACK_RAIL
	local gap = vp.X - left - right
	local w, x, y
	if gap >= CARD_MIN then
		w = math.min(CARD_MAX, gap)
		x = math.clamp(vp.X * 0.5, left + w * 0.5, vp.X - right - w * 0.5)
		y = 14
	else
		w = math.min(CARD_MAX, vp.X - 32)
		x = vp.X * 0.5
		-- under the block itself, wherever it has ended up, rather than under where
		-- it stood on a desktop
		y = if area
			then math.ceil(area.AbsolutePosition.Y + area.AbsoluteSize.Y) + 7
			else FALLBACK_DROP
	end
	card.Size = UDim2.fromOffset(math.floor(w), 0)
	baseX, baseY = math.floor(x), y
	place()

	-- The instruction shrinks with the card; the KEYCAPS do not. A keycap scaled
	-- down with the card stops reading as a key, and it is the one part of this
	-- that has to be findable without looking for it.
	title.TextSize = if w < 380 then 21 elseif w < 440 then 24 else 27
	barWell.Size = UDim2.new(1, if w < 380 then -88 else -104, 0, 11)
	-- The line beside a cap shrinks too. It is the only part of a chip that can
	-- afford to: it says what the key does, and the key itself is already visible.
	local noteSize = if w < 380 then 13 elseif w < 440 then 15 else 16
	for _, view in ipairs(chips) do view.note.TextSize = noteSize end
end

--[[
	Re-measured whenever anything it measures can have moved.

	The shell is a different script with no ordering against this one, and it
	parents its ScreenGui BEFORE it builds the blocks into it -- so neither "is it
	there yet" question can be answered once at startup. Everything here is arranged
	to come out right whichever order the two come up in, and to survive the shell
	being rebuilt underneath it. Reaching for a child that is not there yet is the
	single most expensive habit in this codebase; it has quietly killed four
	features, most recently the store's E prompt.

	The blocks' own AbsoluteSize is watched as well as the window's, because the
	shell fits itself on the same signal this does and there is no telling which of
	the two runs first.
]]
local SHELL_BLOCKS = { Area = true, Rail = true, Hotbar = true }
local hooked: { [Instance]: boolean } = {}

local function hookBlock(f: Instance)
	if hooked[f] or not f:IsA("GuiObject") or not SHELL_BLOCKS[f.Name] then return end
	hooked[f] = true
	f:GetPropertyChangedSignal("AbsoluteSize"):Connect(restyle)
	f:GetPropertyChangedSignal("AbsolutePosition"):Connect(restyle)
	f:GetPropertyChangedSignal("Visible"):Connect(restyle)
	restyle()
end

local function watchShell(sh: Instance)
	shell = sh
	for _, f in ipairs(sh:GetChildren()) do hookBlock(f) end
	sh.ChildAdded:Connect(hookBlock)
	restyle()
end

local shellNow = plr.PlayerGui:FindFirstChild("SealerShell")
if shellNow then watchShell(shellNow) end
plr.PlayerGui.ChildAdded:Connect(function(c)
	if c.Name == "SealerShell" then watchShell(c) end
end)

restyle()
local camera = workspace.CurrentCamera
if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(restyle) end
-- The topbar inset is not constant: it changes when Roblox shows or hides its own
-- chrome, and the whole gui space moves under the card with it.
GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(restyle)

local function pop(scale: number?)
	cardScale.Scale = scale or 0.94
	TweenService:Create(cardScale, TweenInfo.new(0.22, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

--==[ the big short one ]=====================================================
--[[
	Two moments in the whole run get the middle of the screen, and both are over
	inside two seconds: the driveway coming good, and the gate opening. Everything
	else is the card.

	Its own ScreenGui at a higher DisplayOrder, so it is not switched off with the
	card when a shell panel opens -- the driveway can finish while the store is up.
]]
local bannerGui = Instance.new("ScreenGui")
bannerGui.Name = "SealerTutorialBanner"
bannerGui.ResetOnSpawn = false
bannerGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
bannerGui.DisplayOrder = 27
bannerGui.Enabled = false
bannerGui.Parent = plr.PlayerGui

local bannerHolder = Instance.new("Frame")
bannerHolder.BackgroundTransparency = 1
bannerHolder.AnchorPoint = Vector2.new(0.5, 0.5)
bannerHolder.Position = UDim2.new(0.5, 0, 0.36, 0)
bannerHolder.Size = UDim2.new(1, 0, 0, 120)
bannerHolder.Parent = bannerGui

local bannerScale = Instance.new("UIScale")
bannerScale.Parent = bannerHolder

local bannerText = UIKit.outlined(bannerHolder, "", 62, LIME, 4)
bannerText.Size = UDim2.new(1, 0, 1, 0)
bannerText.TextXAlignment = Enum.TextXAlignment.Center
bannerText.Font = UIKit.Display

local bannerUntil = 0

local function banner(text: string, tint: Color3, seconds: number)
	bannerText.Text = text
	bannerText.TextColor3 = tint
	bannerGui.Enabled = true
	bannerUntil = os.clock() + seconds
	bannerScale.Scale = 0.6
	TweenService:Create(bannerScale, TweenInfo.new(0.34, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = 1 }):Play()
	SoundKit.play("Sparkle")
end

--==[ the waypoint out in the world ]=========================================
--[[
	A floating marker over wherever the beat wants the player, a ring on the ground
	under it, and a line of dashes running there from their feet.

	All of it is built on this client and parented into Workspace, so it exists for
	this player only -- nobody sees another player's tutorial arrows. The marker's
	billboard is AlwaysOnTop on purpose: the refill beat points at the bulk tanks,
	which are inside the building, and a marker you cannot see through a wall is no
	help in finding the door.
]]
local fx = Instance.new("Folder")
fx.Name = "TutorialFX"
fx.Parent = workspace

local function decor(name: string, size: Vector3, colour: Color3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	-- CanQuery false matters twice over: it keeps the marker out of the pour aim
	-- ray in DrivewayClient, and out of the blocker probe DrivewaySurface runs when
	-- it works out which cells of a slab are sealable. A queryable decoration
	-- punches a permanent hole in the driveway it is drawn on.
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = colour
	p.Size = size
	p.Parent = fx
	return p
end

local ring = decor("Ring", Vector3.new(0.4, 11, 11), GOLD)
ring.Shape = Enum.PartType.Cylinder
ring.Transparency = 0.35

-- the dashed path. A few extra cells keep long tutorial routes continuous enough
-- to read as one direction rather than a handful of unrelated marks.
local DASHES = 12
local dashes: { BasePart } = {}
for i = 1, DASHES do
	dashes[i] = decor("Dash", Vector3.new(2.6, 0.15, 1.1), GOLD)
end

local anchor = decor("Anchor", Vector3.new(0.2, 0.2, 0.2), GOLD)
anchor.Transparency = 1

local bb = Instance.new("BillboardGui")
bb.Name = "Marker"
bb.AlwaysOnTop = true
bb.Size = UDim2.fromOffset(190, 116)
bb.Parent = anchor

local chevron = UIKit.outlined(bb, "\u{25BC}", 62, GOLD, 3)
chevron.AnchorPoint = Vector2.new(0.5, 1)
chevron.Position = UDim2.new(0.5, 0, 1, 0)
chevron.Size = UDim2.fromOffset(190, 64)
chevron.TextXAlignment = Enum.TextXAlignment.Center

local markerCap = UIKit.outlined(bb, "", 24, CREAM, 3)
markerCap.AnchorPoint = Vector2.new(0.5, 0)
markerCap.Position = UDim2.new(0.5, 0, 0, 0)
markerCap.Size = UDim2.fromOffset(190, 44)
markerCap.TextXAlignment = Enum.TextXAlignment.Center

--==[ the chevrons that say which way to sweep ]==============================
--[[
	"Move the squeegee ACROSS the driveway" is the one instruction in this whole
	run that a sentence genuinely cannot deliver -- it is a direction, and a
	direction wants an arrow. Laid on the slab, sliding the way the blade should go.

	THEY DRAW A LAP, NOT A STROKE, and that is the fix for the thing new players
	actually got wrong (owner's report): they did not work out that the job is to
	stand in the sealer and drag it up and back, so they poked at the puddle or
	walked one line and stopped. A single outbound line of chevrons was, read
	literally, telling them to do exactly that. Four run out and four come back
	alongside, which is a picture of the pattern rather than of one pass.

	Each is two bars meeting at a tip rather than one part, because a rectangle
	lying on the ground is a stripe and reads as a parking bay; a chevron is
	unmistakably a direction at any angle.

	HEIGHT IS LOAD-BEARING. The sealer overlay draws 0.060 studs over the slab, so
	anything below that is painted over by the coat the player is laying and
	vanishes exactly when they start doing the thing it is asking for.
]]
-- Eight, in two lanes of four: out, and back alongside. See showArrows.
local ARROWS = 8
local ARROW_LIFT = 0.16
-- How far the return lane sits from the outbound one. Just under a stock blade
-- (6.4 studs) so the two lanes read as overlapping passes rather than as two
-- separate errands with a strip of grey left between them.
local LANE = 5.5
type Arrow = { a: BasePart, b: BasePart }
local arrows: { Arrow } = {}
for i = 1, ARROWS do
	-- Wide rather than thin, and that is a viewing-angle fact rather than taste:
	-- the default camera sits about eight studs up looking barely fifteen degrees
	-- down, so anything lying flat is seen almost edge-on and a slim bar reads as a
	-- scratch. The gold trail dashes are 2.6 across for the same reason.
	arrows[i] = {
		a = decor("Chev", Vector3.new(1.3, 0.12, 3.4), LIME),
		b = decor("Chev", Vector3.new(1.3, 0.12, 3.4), LIME),
	}
end

local function hideArrows()
	for _, m in ipairs(arrows) do
		m.a.Transparency = 1
		m.b.Transparency = 1
	end
end

--[[
	Which way is "across" for a given slab, pointed away from where the player is
	standing.

	Off the slab's own long axis rather than off the camera: a driveway is a
	rectangle and the pass that covers it in the fewest strokes runs down its
	length. Off the PART's frame rather than off world axes, so a lot that has been
	rotated on the map still gets an arrow along its tarmac.

	THE TIE-BREAK IS THE PART THAT MATTERS. Which of the two ways along that axis
	is "forward" normally comes from which end of the slab is further away -- but a
	player standing in the MIDDLE has no far end, and the test collapses to the sign
	of a number near zero. Left there it points wherever, which half the time is
	behind the player: arrows they have to turn around to find are worse than none.
	So near the middle the tie goes to the way they are already facing.
]]
local function sweepAxis(slab: BasePart, from: Vector3, facing: Vector3?): Vector3
	local size = slab.Size
	local localAxis = if size.X >= size.Z then Vector3.xAxis else Vector3.zAxis
	local a = slab.CFrame:VectorToWorldSpace(localAxis)
	a = Vector3.new(a.X, 0, a.Z)
	if a.Magnitude < 1e-3 then return Vector3.xAxis end
	a = a.Unit

	local toMiddle = Vector3.new(slab.Position.X - from.X, 0, slab.Position.Z - from.Z)
	local reach = toMiddle:Dot(a)
	if math.abs(reach) < 4 and facing then
		local f = Vector3.new(facing.X, 0, facing.Z)
		if f.Magnitude > 1e-3 and f.Unit:Dot(a) < 0 then a = -a end
	elseif reach < 0 then
		a = -a
	end
	return a
end

local function showArrows(slab: BasePart, start: Vector3, facing: Vector3?, urgent: boolean)
	local fwd = sweepAxis(slab, start, facing)
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	local y = slab.Position.Y + slab.Size.Y * 0.5 + ARROW_LIFT

	local SPAN = 18
	local half = ARROWS // 2
	local slide = (os.clock() * 0.55) % 1

	for i, m in ipairs(arrows) do
		--[[
			The outbound lane starts under the player's feet; the return lane starts at
			the far end of it and comes back one blade over. Both slide in their own
			direction, so the pair animates as a circuit being walked rather than as two
			arrows disagreeing about which way to go.
		]]
		local outbound = i <= half
		local n = if outbound then i else i - half
		local f = ((n - 1) / half + slide) % 1

		local dir = if outbound then fwd else -fwd
		local base = if outbound then start
			else start + right * LANE + fwd * (3 + SPAN)
		local tip = base + dir * (3 + f * SPAN)
		local at = Vector3.new(tip.X, y, tip.Z)

		-- the two bars of the chevron, opening away from whichever way this lane runs
		local dirA = (dir + right * 0.8).Unit
		local dirB = (dir - right * 0.8).Unit
		m.a.CFrame = CFrame.lookAt(at - dirA * 1.7, at)
		m.b.CFrame = CFrame.lookAt(at - dirB * 1.7, at)

		-- fade in at the near end and out at the far end, so the line never just stops
		local fade = 0.15 + 0.55 * math.abs(f - 0.5) * 2
		if urgent then fade *= 0.5 end
		m.a.Transparency = fade
		m.b.Transparency = fade
	end
end

--==[ the outline on the thing that matters ]=================================
--[[
	A pulsing edge around whichever PART the beat is about -- the driveway, the
	pump, the counter terminal.

	A Highlight rather than parts of my own, and that is the safe choice here
	rather than the lazy one: a Highlight is a post-process with no physical
	presence at all, so unlike every other decoration in this file it cannot end up
	in the pour aim ray or the sealable-cell probe no matter what it is adorned to.

	Outline only. A filled Highlight over the driveway would tint the coat the
	player is laying, which is the one surface they need to read honestly.
]]
local glow = Instance.new("Highlight")
glow.Name = "TutorialGlow"
glow.FillTransparency = 1
glow.FillColor = GOLD
glow.OutlineColor = GOLD
glow.Enabled = false
glow.Parent = fx

local function setGlow(part: BasePart?, through: boolean, urgent: boolean)
	if not part then
		glow.Enabled = false
		glow.Adornee = nil
		return
	end
	-- Guarded: this runs every frame, and re-adorning a Highlight to the instance
	-- it is already on rebuilds its outline mesh.
	if glow.Adornee ~= part then glow.Adornee = part end
	glow.Enabled = true
	-- Through a wall for the two indoor targets, occluded for the slabs. A depot
	-- pump glowing through the roof is the whole point of pointing at it; a
	-- driveway doing the same would shine through the house in front of it.
	glow.DepthMode = if through then Enum.HighlightDepthMode.AlwaysOnTop
		else Enum.HighlightDepthMode.Occluded
	local k = 0.5 + 0.5 * math.sin(os.clock() * 3.4)
	glow.OutlineTransparency = 0.05 + 0.35 * k
	-- The escalation: a player who has stood still long enough gets the shape
	-- filled in as well, which is much harder to miss than an edge.
	glow.FillTransparency = if urgent then 0.72 + 0.16 * k else 1
end

local function hideWorld()
	ring.Transparency = 1
	anchor.Transparency = 1
	bb.Enabled = false
	for _, d in ipairs(dashes) do d.Transparency = 1 end
	hideArrows()
	glow.Enabled = false
end

--[[
	The ring is a WALK HERE marker, so it comes off once the player is here.

	On the pour and spread beats the spot IS the driveway, so a gold disc sat in
	the middle of the slab they are trying to coat -- and not on it but THROUGH it:
	the cylinder is centred 0.35 under the spot with a half-thickness of 0.2, which
	on a 0.5-stud slab puts its upper face 0.04 above the sealer overlay. It drew
	over the black coat, flickering, right where the player was looking.

	A beat that genuinely needs a ring underfoot asks for one (`ringClose`), and
	that one rides ABOVE the coat instead of through it.
]]
local RING_NEAR = 14   -- studs; comfortably wider than the ring's own 11.6
-- 0.2 to break the surface (the cylinder is 0.4 thick on its side), then 0.15 to
-- clear the sealer overlay sitting 0.06 over it.
local RING_LIFT = 0.2 + 0.15

-- Route cache for the two indoor errands. A straight line to an object inside the
-- garage visually ends on the outside wall; a path gives the dashes the same route
-- the player can actually walk through the doorway. Recomputed at most twice a second.
local routeAt = 0
local routeFrom: Vector3? = nil
local routeTo: Vector3? = nil
local routePoints: { Vector3 } = {}
local routeBusy = false
local routeVersion = 0

local function worldRoute(from: Vector3, to: Vector3): { Vector3 }
	local now = os.clock()
	local moved = routeFrom == nil or (from - (routeFrom :: Vector3)).Magnitude >= 5
	local changedTarget = routeTo == nil or (to - (routeTo :: Vector3)).Magnitude >= 1
	local stale = now - routeAt >= 0.5 or moved or changedTarget

	if stale and not routeBusy then
		routeAt = now
		routeFrom = from
		routeTo = to
		routeBusy = true
		routeVersion += 1
		local myVersion = routeVersion
		local fromNow, toNow = from, to

		task.spawn(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				AgentCanJump = true,
				WaypointSpacing = 5,
			})

			local ok = pcall(function()
				path:ComputeAsync(fromNow, toNow)
			end)

			local points: { Vector3 } = { fromNow }
			if ok and path.Status == Enum.PathStatus.Success then
				for _, waypoint in ipairs(path:GetWaypoints()) do
					table.insert(points, waypoint.Position)
				end
			end
			if #points < 2 then
				table.insert(points, toNow)
			elseif (points[#points] - toNow).Magnitude > 2 then
				table.insert(points, toNow)
			end

			if myVersion == routeVersion then
				routePoints = points
			end
			routeBusy = false
		end)
	end

	-- Never make the guide disappear while PathfindingService is answering.
	-- If the cached route belongs to another target, use a direct line for this frame.
	if #routePoints >= 2 and not changedTarget then
		return routePoints
	end
	return { from, to }
end

local function routeLength(points: { Vector3 }): number
	local total = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		total += Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
	end
	return total
end

local function alongRoute(points: { Vector3 }, distance: number): (Vector3, Vector3)
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local len = flat.Magnitude
		if len > 0.001 then
			if distance <= len then
				local dir = flat.Unit
				return a + dir * distance, dir
			end
			distance -= len
		end
	end

	local last = points[#points]
	local prev = points[math.max(1, #points - 1)]
	local flat = Vector3.new(last.X - prev.X, 0, last.Z - prev.Z)
	local dir = if flat.Magnitude > 0.001 then flat.Unit else Vector3.new(0, 0, 1)
	return last, dir
end

local function showWorld(spot: Vector3, caption: string, from: Vector3?,
	ringClose: boolean?, urgent: boolean)
	local t = os.clock()
	local bob = math.sin(t * 3.2) * 0.55

	bb.Enabled = true
	markerCap.Text = caption
	anchor.CFrame = CFrame.new(spot + Vector3.new(0, 7.4 + bob, 0))
	-- The escalation, out in the world: the chevron over the marker grows. Nothing
	-- new appears on screen, the thing already there simply gets louder.
	chevron.TextSize = if urgent then 76 + 18 * (0.5 + 0.5 * math.sin(t * 5)) else 62

	local flat = if from then Vector3.new(spot.X - from.X, 0, spot.Z - from.Z) else nil
	local span = if flat then flat.Magnitude else 0

	if ringClose or not flat or span >= RING_NEAR then
		ring.Transparency = 0.35 + 0.18 * (0.5 + 0.5 * math.sin(t * 3.2))
		local y = if ringClose then spot.Y + RING_LIFT else spot.Y - 0.35
		-- a cylinder's flat faces are on its X axis, so it is tipped on its side to lie down
		ring.CFrame = CFrame.new(spot.X, y, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
		local pulse = (if urgent then 12 else 10) + 1.6 * math.sin(t * 3.2)
		ring.Size = Vector3.new(0.4, pulse, pulse)
	else
		ring.Transparency = 1
	end

	-- Keep the route visible almost all the way to the target. At 16 studs the
	-- upgrade trail disappeared while the player was still several steps from the counter.
	if not from or not flat or span < 4 then
		for _, d in ipairs(dashes) do d.Transparency = 1 end
		return
	end

	local points = worldRoute(from, spot)
	local routeSpan = routeLength(points)
	if routeSpan < 4 then
		for _, d in ipairs(dashes) do d.Transparency = 1 end
		return
	end

	local slide = (t * (if urgent then 0.95 else 0.35)) % 1
	for i, d in ipairs(dashes) do
		local f = ((i - 1) / DASHES + slide) % 1
		local distance = 3 + f * math.max(1, routeSpan - 4)
		local at, dir = alongRoute(points, distance)

		-- Ride the floor along the computed walkable route. Excluding our own FX stops
		-- a dash from ray-hitting the dash in front of it.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { fx, plr.Character }
		local hit = workspace:Raycast(at + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), params)
		local y = if hit then hit.Position.Y else at.Y
		local foot = Vector3.new(at.X, y + 0.12, at.Z)

		d.CFrame = CFrame.lookAt(foot, foot + dir)
		d.Material = if urgent then Enum.Material.Neon else Enum.Material.SmoothPlastic
		d.Size = if urgent then Vector3.new(4.2, 0.18, 1.55) else Vector3.new(2.6, 0.15, 1.1)
		d.Transparency = if urgent
			then 0.04 + 0.24 * math.abs(f - 0.5)
			else 0.25 + 0.6 * math.abs(f - 0.5)
	end
end

--==[ the ring that marks a control on screen ]===============================
--[[
	A pulsing outline drawn around whichever button the beat wants pressed -- the
	hotbar slot holding the pail, or the Squeegee Length row once the store is open.

	Its own ScreenGui rather than riding on the card's, because the card hides
	itself whenever a shell panel is open and the upgrade beat sends the player
	into a panel and then needs to point at a row inside it. Separate surface,
	separate switch.
]]
local pointerGui = Instance.new("ScreenGui")
pointerGui.Name = "SealerTutorialPointer"
pointerGui.ResetOnSpawn = false
pointerGui.IgnoreGuiInset = false
pointerGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pointerGui.DisplayOrder = 26   -- over the shell's panels, which is where the row is
pointerGui.Parent = plr.PlayerGui

local pulse = Instance.new("Frame")
pulse.Name = "Pulse"
pulse.BackgroundColor3 = GOLD
pulse.BackgroundTransparency = 0.82
pulse.BorderSizePixel = 0
pulse.ZIndex = 40
pulse.Visible = false
pulse.Parent = pointerGui
UIKit.corner(pulse, 14)

local pulseStroke = Instance.new("UIStroke")
pulseStroke.Color = GOLD
pulseStroke.Thickness = 3
pulseStroke.Parent = pulse

local shell = plr.PlayerGui:WaitForChild("SealerShell", 20)

-- Found by caption rather than by slot index: the hotbar orders itself from what
-- the player is carrying, so "slot 1" is not a promise.
local function slotFor(word: string): GuiObject?
	local bar = if shell then shell:FindFirstChild("Hotbar") else nil
	-- The whole row hides while the player is driving, and a hidden PARENT does not
	-- clear its children's Visible or their AbsoluteSize -- so testing the slots
	-- alone would ring a key that is not on the screen.
	if not bar or not (bar :: GuiObject).Visible then return nil end
	for _, slot in ipairs(bar:GetChildren()) do
		if slot:IsA("GuiObject") and slot.Visible then
			local cap = slot:FindFirstChild("ToolName", true)
			if cap and cap:IsA("TextLabel") and cap.Text:lower():find(word) then
				return slot
			end
		end
	end
	return nil
end

-- The number printed on that key, so the cap can say it. Read off the slot rather
-- than assumed, for the same reason slotFor exists.
local function keyFor(word: string): string?
	local slot = slotFor(word)
	local digit = if slot then slot:FindFirstChild("Digit", true) else nil
	if digit and digit:IsA("TextLabel") and digit.Text ~= "" then return digit.Text end
	return nil
end

--[[
	`Visible` is not the question for a row inside a panel.

	A row in a CLOSED panel is still Visible and still has a laid-out AbsoluteSize
	-- Roblox hides a panel by flipping its holder, not the rows in it. Testing the
	row alone puts a gold ring in the middle of the sky over a shut menu. What
	matters is the whole chain up to an enabled ScreenGui.
]]
local function onScreen(g: GuiObject): boolean
	local node: Instance? = g
	while node and not node:IsA("ScreenGui") do
		if node:IsA("GuiObject") and not node.Visible then return false end
		node = node.Parent
	end
	return node ~= nil and (node :: ScreenGui).Enabled
end

-- The buy button on the Squeegee Length row, once the panel is open. Walked down
-- from the row rather than reached by a stored path: the row carries its track id
-- as its name, which is the one part of that layout that cannot drift without the
-- purchase itself breaking.
--[[
	Walked ONCE, then held.

	Shell.mount fills SealerShell with a few thousand instances, and this used to
	walk every one of them -- an IsA and two property reads apiece -- on every
	frame of the blade beat. That beat is the last objective and a new player can
	sit on it for minutes, so it was milliseconds a frame and a fresh few-thousand
	entry table for the collector to sweep up, all for an answer that does not move.

	What is cached is the SEARCH, never the answer: onScreen is still asked of the
	held row on every call, because that is the part that legitimately flips as the
	panel opens and shuts, and the ring has to follow it. The cache is dropped only
	when the row goes stale -- destroyed, reparented out of the shell, or laid out
	to zero width -- and never merely because it is hidden, so shutting the panel
	costs nothing when it opens again. Holding a single row is safe for the reason
	above: the name is the track id, so there is only ever one of them.
]]
local bladeRow: GuiObject? = nil
local bladeButton: GuiObject? = nil
-- A search that finds nothing has nothing to cache, and the blade beat sits on
-- exactly that for as long as it takes them to walk to the counter -- so the
-- misses get a floor between them rather than running every frame too. Short
-- enough that the ring still arrives on the same breath as the panel.
local BLADE_RESCAN = 0.2
local bladeScanAt = 0

local function bladeBuyButton(): GuiObject?
	if not shell then return nil end

	local row = bladeRow
	if row then
		-- IsDescendantOf answers destroyed and reparented in the one test
		if row:IsDescendantOf(shell) and row.AbsoluteSize.X > 0 then
			if not onScreen(row) then return nil end
			local cached = bladeButton
			if cached and cached:IsDescendantOf(row) then return cached end
			-- row still good, button gone: walking the row again is nothing next to
			-- walking the shell
			for _, b in ipairs(row:GetDescendants()) do
				if b:IsA("TextButton") then
					bladeButton = b
					return b
				end
			end
			return nil
		end
		bladeRow, bladeButton = nil, nil
	end

	local now = os.clock()
	if now < bladeScanAt then return nil end
	bladeScanAt = now + BLADE_RESCAN

	for _, d in ipairs(shell:GetDescendants()) do
		if d:IsA("GuiObject") and d.Name == "Blade" and d.AbsoluteSize.X > 0 and onScreen(d) then
			bladeRow = d
			for _, b in ipairs(d:GetDescendants()) do
				if b:IsA("TextButton") then
					bladeButton = b
					return b
				end
			end
			return nil
		end
	end
	return nil
end

-- Pixels of margin the ring breathes between. The rail buttons carry a gold
-- outline of their own, so a thin gold ring sat on one reads as part of the
-- button rather than as something asking to be pressed -- it has to leave the
-- button's own edge behind to register.
local RING_TIGHT, RING_WIDE = 5, 21

local function markControl(target: GuiObject?)
	if not target or target.AbsoluteSize.X == 0 then
		pulse.Visible = false
		return
	end
	pulse.Visible = true
	local k = 0.5 + 0.5 * math.sin(os.clock() * 4.2)   -- 0 tight, 1 wide
	local grow = RING_TIGHT + (RING_WIDE - RING_TIGHT) * k

	-- AbsolutePosition needs no inset correction: the pulse shares IgnoreGuiInset
	-- with the shell. Rounded, because a fractional offset makes the stroke shimmer
	-- as it breathes.
	local p, s = target.AbsolutePosition, target.AbsoluteSize
	pulse.Position = UDim2.fromOffset(math.round(p.X - grow), math.round(p.Y - grow))
	pulse.Size = UDim2.fromOffset(math.round(s.X + grow * 2), math.round(s.Y + grow * 2))

	-- brightest and thickest when tightest, so it reads as a squeeze on the button
	-- rather than as something fading in and out beside it
	pulseStroke.Thickness = 2.6 + 3.4 * (1 - k)
	pulseStroke.Transparency = 0.45 * k
	pulse.BackgroundTransparency = 0.66 + 0.30 * k
end

--==[ making room for the toasts ]============================================
--[[
	The shell's toast stack lives at top centre too, 24px down, exactly under this
	card -- which draws over it at a higher DisplayOrder. So every bonus, every
	purchase result and DepotGate's own "now spend it" landed behind the tutorial
	and could not be read at the one moment they were being used to teach
	something. The card is the persistent element, so the transient one moves.
]]
local toastLane = if shell then shell:FindFirstChild("Toasts") else nil
-- READ off the lane rather than written here. 24 is the desktop figure and the
-- shell scales its own margins to the window, so on a handset the lane goes home
-- to 15 -- and this file is the other writer of that property. Taken now, before
-- anything here has moved it.
local TOAST_HOME = if toastLane and toastLane:IsA("Frame")
	then toastLane.Position.Y.Offset
	else 24
local laneAt = TOAST_HOME

local function setToastLane(y: number)
	if not (toastLane and toastLane:IsA("Frame")) then return end
	if math.abs(laneAt - y) < 1 then return end
	laneAt = y
	toastLane.Position = UDim2.new(0.5, 0, 0, y)
end

local function laneBelowCard(): number
	return card.Position.Y.Offset + math.ceil(card.AbsoluteSize.Y) + 12
end

--[[
	Stand down entirely while one of the shell's panels is open.

	The panels are centred and their title bar lands at roughly the height the card
	occupies, so the upgrade beat -- which exists to send the player into Upgrades
	-- was covering the word "UPGRADES" the moment they got there. They are reading
	a menu at that point, not an instruction.
]]
local function panelOpen(): boolean
	if not shell then return false end
	for _, c in ipairs(shell:GetChildren()) do
		if c.Name == "PanelHolder" and c:IsA("GuiObject") and c.Visible then return true end
	end
	return false
end

--==[ what the player has already proved ]====================================
--[[
	The latches, and every one of them is re-inferable from the slab.

	Somebody who logged out having sealed half the driveway comes back with a full
	pail and nothing poured this session. On a plain sequence that is "step one,
	go and pour some sealer" over a driveway that is already half black. Sealer on
	the slab is proof of a pour; coverage is proof of a spread; a finished job is
	proof of everything.
]]
local arrived = false      -- has reached the tutorial driveway
local pouredOut = false    -- has emptied a pail onto it
local sweptOnce = false    -- has laid a first pass with the blade
--[[
	Has filled the pail at the tanks, and the one latch here that is NOT re-inferable
	from the slab.

	Nothing in the world remembers a refill: the pail comes back full on every join
	(see DrivewayClient), a sealed driveway says nothing about where the sealer came
	from, and there is no attribute for it. So it starts false for everybody and the
	run asks for one fill before it ends -- which is the right way to be wrong. A
	player who already knows loses one press at a depot they are walking into
	anyway; a player who does not know would otherwise finish the tutorial never
	having learned the one thing that unblocks their second driveway.

	That is also why the whole run can no longer be completed without it: the
	first slab takes a pail and a half at most tunings, but at a generous one it
	takes less, and those players were reaching the map having never seen the pump.
]]
local refilled = false

-- Fractions of a pail that have gone on OUR slab, summed from the level dropping
-- frame to frame. This rather than the pail level itself is what the pour beat is
-- scored on, because it survives a refill: a player who arrives half full empties
-- it, fills up, and carries on from where the bar had got to.
local pourSpent = 0
local prevBucket: number? = nil
-- And the same sum in the other direction: fractions of a pail that have gone back
-- in. Only the pump can raise the level, so this needs no location test of its own
-- to mean "has stood at the tanks and held the key".
local fillGain = 0

--[[
	The readouts, each latched against the slab it belongs to.

	HudBus reports whichever surface the HELD TOOL is working on, not the one
	underfoot -- with the pail that is the slab under the cursor. So walking off the
	driveway toward the garage makes the nearest slab the depot apron at 0%, and the
	coverage readout fell from 60% to 0% on the way to a refill. Only the tutorial
	slab's own figure is believed; anything else leaves the last one standing.
]]
local lastBucket = 1
local lastCoverage = 0
-- When the slab first went bare with sealer still in the pail; nil whenever it is
-- not in that state. See the STALL block in currentBeat.
local stallSince: number? = nil
-- How much sealer is lying on the slab, and where the deepest of it is. Both come
-- off one scan in DrivewayClient; see SurfaceGrid:LooseVolume. `lastLoose` is a
-- second way to pass the pour beat and it proves the player has been here at all;
-- `lastLooseAt` is where START HERE and the chevrons are anchored.
local lastLoose = 0
local lastLooseAt: Vector3? = nil

-- Set when the last flag arrives while the card is up, so the finale gets a
-- moment on screen instead of the whole thing vanishing on the same frame.
local finishedAt: number? = nil

--==[ the beats ]=============================================================
export type Beat = {
	step: number,          -- which of the six numbered objectives this belongs to
	key: string,           -- identity, so the loop can tell one beat from the next
	title: string,         -- two to five words, and never more
	chips: { Chip }?,
	bar: number?,          -- 0..1, drawn only when present
	barCap: string?,
	spot: Vector3?,        -- where the waypoint goes
	caption: string?,      -- one or two words over the marker
	ringClose: boolean?,   -- keep the ground ring even when stood on the spot
	point: string?,        -- "bucket" | "squeegee" | "blade": which control to ring
	glow: BasePart?,       -- what to outline in the world
	glowThrough: boolean?, -- outline it through walls
	arrowsOn: BasePart?,   -- draw the sweep chevrons on this slab
	arrowsFrom: Vector3?,
	hint: string?,         -- the nudge, if they stall. Four words at most.
	finale: boolean?,
	strongGuide: boolean?, -- keep the world route in its loud state immediately
}

--==[ the onboarding funnel ]================================================
--[[
	How far a new player gets before they give up, reported to Roblox's own
	onboarding funnel so the drop-off shows up per step in the Creator Dashboard.

	FOUR OF THE SIX STEPS ARE SENT FROM HERE and the last two are not: sealing the
	driveway and finishing the tutorial are facts the server owns (TutSealed,
	TutorialDone), and a client that could assert them could assert its way to the
	bottom of the funnel without playing. What this end reports is the three latches
	above plus "the card drew at all", none of which is worth lying about and none
	of which any door hangs on.

	DEDUPED PER SESSION, NOT PER PLAYER, and that is enough. The funnel counts
	unique users per step, so somebody who rejoins mid-tutorial and re-reports the
	steps they already passed does not add a second body to those steps -- they are
	already counted at each. Persisting a high-water mark would buy nothing and be
	one more thing in the profile to keep correct.

	The queue exists because the remote is created by a server script and this runs
	before it necessarily exists; without it the first step would be marked sent and
	thrown away. Same shape as every other arrival race in this place, cheaper fix.
]]
local funnelSent: { [number]: boolean } = {}
local funnelQueue: { number } = {}
local funnelRemote: RemoteEvent? = nil

task.spawn(function()
	local pack = ReplicatedStorage:WaitForChild("SealerUI", 30)
	local rem = pack and pack:WaitForChild("Remotes", 30)
	local r = rem and rem:WaitForChild("TutorialStep", 30)
	if not (r and r:IsA("RemoteEvent")) then return end
	funnelRemote = r
	for _, n in ipairs(funnelQueue) do r:FireServer(n) end
	table.clear(funnelQueue)
end)

local function funnel(step: number)
	if funnelSent[step] then return end
	funnelSent[step] = true
	local r = funnelRemote
	if r then r:FireServer(step) else table.insert(funnelQueue, step) end
end

local function currentBeat(): Beat?
	-- The run is over when the gate opens, which DepotGate now does in the same
	-- breath as marking the tutorial done -- see DEPOT_ATTR.
	if plr:GetAttribute(DEPOT_ATTR) == true or plr:GetAttribute("TutBought") == true then
		local gate = mapExitPart()
		local spot = mapExitSpot()
		local root = rootPart()

		if gate and spot and root then
			local flat = Vector3.new(spot.X - root.Position.X, 0, spot.Z - root.Position.Z)
			if flat.Magnitude <= 12 then return nil end

			return {
				step = OBJECTIVES, key = "done", title = "THE MAP IS YOURS", finale = true,
				spot = spot, caption = "MAP EXIT", ringClose = true,
				glow = gate, glowThrough = true, strongGuide = true,
				hint = "Follow the gold trail",
			}
		end

		if not finishedAt or os.clock() - finishedAt > HOLD_DONE then return nil end
		return { step = OBJECTIVES, key = "done", title = "THE MAP IS YOURS", finale = true }
	end

	--==[ read the world ]====================================================
	local st = HudBus.latest
	local onOurs = st.name ~= nil and st.name == driveName()

	local b = st.bucket
	if b then
		-- Only the DROP counts, and only over our own slab. A refill is a rise and a
		-- pour onto the road is somebody else's surface; neither is progress here.
		if prevBucket and onOurs and b < prevBucket then
			pourSpent += prevBucket - b
		end
		-- A rise is a fill, wherever the player happens to be pointing -- there is
		-- nothing else in the game that puts sealer back in the pail.
		if prevBucket and b > prevBucket then
			fillGain += b - prevBucket
		end
		prevBucket, lastBucket = b, b
	end
	if st.coverage and onOurs then lastCoverage = st.coverage end
	if st.loose and onOurs then
		lastLoose = st.loose
		lastLooseAt = st.looseAt
	end

	local finished = plr:GetAttribute("TutSealed") == true
	local upgraded = plr:GetAttribute("TutBought") == true
	local pail = Config.BucketCapacity

	--[[
		Stalled: the slab is bare and the pail is not.

		The pour beat ends on an empty pail now, so it no longer hands the spreading
		beats a part-full one. This still has to exist for the pail the player fills
		LATER: refill-finish sends them back to the pump mid-job, and they can walk away
		from it with sealer in hand and nothing left on the slab to push. From the
		player's side that is indistinguishable from the squeegee having stopped
		working: they hold the button, they walk, and nothing goes black. The one thing
		they will not think to do is put the tool away and pour again.

		Scored on loose sealer rather than on the pail alone, because the pail being
		part-full is not itself a problem -- it is only a problem once there is nothing
		left on the ground to work with.

		`lastLoose` holds its last reading when HudBus stops naming our slab, so
		walking off the driveway freezes this rather than clearing it. That is the
		right way round: a player who wanders off mid-job comes back to the same
		instruction they left.
	]]
	--[[
		AND NEVER ONCE THE SLAB IS DONE, because from that moment the pour this beat
		asks for is REFUSED.

		DrivewayClient shuts the spout on a completed slab outright -- `canPour` carries
		`not surface.completed`, and rightly: nothing recovers loose sealer any more, so
		a pail emptied over cured coat is a whole trip to the pump thrown away. But this
		beat's whole instruction is "pour what is left onto the slab", and `finished`
		only goes true when the SERVER sets TutSealed. Between the client calling the
		job done and the server agreeing, the tutorial was asking for the one action the
		game had just taken away -- and if the server never agreed, it asked forever.

		That is the "it won't let me empty the pail" report. Its root cause was
		DepotGate's coverage limiter refusing the completion (see the note over
		Config.maxCoverageRate, now fixed), but the dead end itself was here: a beat
		with no exit that the player could reach.

		`lastCoverage` is the honest test rather than `finished`, because it is the
		CLIENT's view -- and the client is the side that shuts the spout. So the two can
		never disagree about it, whatever the server does or does not write.
	]]
	local slabDone = lastCoverage >= Config.CompleteAt

	local bare = lastLoose <= pail * STALL_LOOSE
	if bare and not finished and not slabDone and lastBucket > PAIL_EMPTY then
		stallSince = stallSince or os.clock()
	else
		stallSince = nil
	end
	local stalled = stallSince ~= nil and os.clock() - stallSince >= STALL_PATIENCE
	local held = heldTool()
	local drive = drivewayPart()
	local hrp = rootPart()

	--[[
		The refill latch, and it is deliberately two different tests either side of the
		slab being finished.

		WHILE THERE IS STILL A DRIVEWAY TO SEAL, any real fill counts: the player was
		sent to the pump by one of the refill beats, they held the key, half a pail went
		in, and they have been taught. Nothing needs to be full for that to have landed.

		ONCE IT IS FINISHED, only a full pail at the tanks does -- because from there on
		the beat below is what is asking, and it draws the pail level as its bar. Ticking
		a step off on a half-fill would leave that bar sitting at sixty percent with a
		tick over it, which reads as the card losing count. The two rules meet at the
		same place: you have watched the pail come back up.

		The full-at-the-pump half also answers the case that would otherwise hang: a
		player who reaches the end still carrying a full pail cannot make the level rise
		at all, and "hold E until the bar fills" would be an instruction with no way to
		obey it. Standing on the pad with a full pail IS the end state being asked for,
		so it ticks on arrival.
	]]
	if not refilled then
		local toPump = if hrp then Depot.distanceToRefuel(hrp.Position) else nil
		local atPump = toPump ~= nil and toPump <= Config.FillReach
		if (not finished and fillGain >= FILL_SHARE)
			or (atPump and lastBucket >= FILL_FULL) then
			refilled = true
		end
	end

	--==[ relatch: what the world says they have already done ]================
	if lastLoose > 0 or lastCoverage > 0 then arrived = true end
	if not arrived and hrp and drive then
		--[[
			Standing on the slab, or one pace off its edge.

			PER AXIS rather than one radius around the centre, and that started
			mattering when the slab became a 40 x 8 front walk. A circle sized off the
			longer side reaches 26 studs out on the shorter one, so a player crossing
			the lawn twenty studs clear of the walk was counted as having arrived at it
			-- objective 1 ticking off from somewhere they cannot even see the sealer.
			On the old 30 x 20 rectangle the two tests agreed closely enough that the
			difference never showed.

			The slab is axis-aligned, so world axes are its axes.
		]]
		local dx = math.abs(hrp.Position.X - drive.Position.X) - drive.Size.X * 0.5
		local dz = math.abs(hrp.Position.Z - drive.Position.Z) - drive.Size.Z * 0.5
		if math.max(dx, 0) <= 6 and math.max(dz, 0) <= 6 then
			arrived = true
		end
	end

	--[[
		Coverage this deep is a PREVIOUS SESSION's work, and only that.

		The figure is deliberately well clear of what a player who ignores the card
		can produce in a few seconds -- splash a cupful, smear it, and you are at two
		or three percent. Latching the pour gate open at that would hand the one
		lesson this rewrite exists to teach to exactly the player least likely to have
		worked it out. Somebody who rejoins at five percent is sent back to pour, and
		that is the right answer for them too: five percent of a slab needs more
		sealer on it before anything else is worth doing.
	]]
	if lastCoverage >= 0.08 or finished then
		arrived, pouredOut = true, true
	end
	if lastCoverage >= FIRST_PASS or finished then sweptOnce = true end

	--[[
		The pour gate: the pail has to be EMPTY, and it has to have emptied HERE.

		⚠ THE PAIL TEST IS THE ONE THE PLAYER CAN SEE, which is why it is the gate.
		Reported 2026-08-14: "the percent bar fills up and moves onto the next step
		before the user actually empties out the pail." It did. A glug is 75 units out
		of a 500-unit pail (Config.PourDump), so six taps put 450 down and `pourSpent`
		cleared the old 0.85 share on its own with 50 units -- a tenth of a pail --
		still sitting in it. The card said "until it is empty" over a bar that was full
		and a pail that was not.

		So `lastBucket` decides when the beat ends. It is the same reading the pail's
		own level disc is drawn from, so the card, the bar and the thing in the
		player's hand cannot disagree -- and PAIL_EMPTY is the threshold every other
		beat in this file already calls empty, so there is no gap between this ticking
		and the refill beats deciding you are dry.

		THE SHARE IS STILL HERE, as the other half of the AND: it is what says the
		sealer landed on OUR slab. `pourSpent` only counts while HudBus is naming our
		driveway, which with the pail in hand is the slab under the CURSOR, so a player
		pouring over the edge drains the pail without moving it. Half a pail lying
		loose on the driveway passes too -- a direct measurement of the thing being
		asked for, which cannot disagree with what is on the ground in front of them.
		Empty the pail onto the ROAD and neither passes, and that is correct: the
		branch below sees an empty pail and sends them to the pump.
	]]
	local landedHere = pourSpent >= POUR_SHARE or lastLoose >= pail * 0.5
	if not pouredOut and landedHere and lastBucket <= PAIL_EMPTY then
		pouredOut = true
	end

	--[[
		Report the funnel off the latches rather than off the beat on screen.

		A beat can be swapped out and back -- running dry sends you to the pump and
		back again -- but a latch only ever goes one way, which is the shape a funnel
		step wants. Step 1 is unconditional: reaching this line at all means the card
		is up and the player is in the tutorial, and the early return above has already
		taken out everybody who finished it in an earlier session.
	]]
	funnel(1)
	if arrived then funnel(2) end
	if pouredOut then funnel(3) end
	if sweptOnce then funnel(4) end

	--==[ 1 -- get there ]====================================================
	if not arrived then
		return {
			step = 1, key = "walk", title = "GO TO THE FRONT PATH",
			chips = { chip({ keys = { "W", "A", "S", "D" }, note = "MOVE" },
				{ cap = "STICK", note = "MOVE" }) },
			spot = drivewaySpot(), caption = "SEAL THIS ONE",
			glow = drive, hint = "Follow the gold marker",
		}
	end

	--==[ 2 -- put the whole pail on the ground ]==============================
	--[[
		THE ONE THING NEW PLAYERS GET WRONG, and half the reason this file was
		rewritten.

		They hold the pail like a spray can and walk it up and down the slab trying
		to cover the whole thing with the pour -- which lays a film far too thin to
		seal anything and empties the pail doing it, so they refill and do it again.
		Sealer FLOWS. One heavy puddle and a squeegee covers what no amount of careful
		pouring will.

		The old card SAID that, in a sentence, above a step that ticked off the
		instant six percent of a pail had left the spout -- so the lesson was written
		down and then immediately contradicted by the thing measuring it. It is a
		gate now: the beat does not end until the pail is empty.

		⚠ It also used to end "and over-pouring costs nothing anyway, because whatever
		is left over goes back in the pail". That stopped being true on 2026-08-11: the
		reclaim mechanic is gone and a finished slab takes its leftovers with it. The
		instruction is unchanged -- a puddle is still how you seal anything at all --
		but the pail emptied here is now genuinely spent. Checked before the gate was
		tightened to require an empty one: a full pail is 500 units against a 320 stud^2
		slab, so one pailful is 1.56x what the job needs and emptying it cannot strand
		anybody. POUR_SHARE is still the number to turn if that ever stops being true.
	]]
	if not pouredOut then
		-- Arrived part-full, or spent it somewhere it did not count. The waypoint
		-- turns round to the tanks and the bar keeps its place.
		if lastBucket <= PAIL_EMPTY then
			return {
				step = 2, key = "refill-pour", title = "FILL THE PAIL",
				chips = { chip({ cap = "E", note = "HOLD AT PUMP", hold = true },
					{ cap = "HOLD", note = "AT THE PUMP", hold = true }) },
				spot = refuelSpot(), caption = "REFILL",
				glow = pumpPart(), glowThrough = true,
				--[[
					THE PAIL, not the pour -- the same rule as the stall beat below and 5a
					at the end of this function, which already says it: the bar has to show
					the thing the title is asking for.

					While this beat is up the player is stood at the tanks holding E, and
					POURED cannot move until they are back on the slab. So the bar under
					"FILL THE PAIL" sat frozen at whatever they had managed before running
					dry, and the card read as asking for two different things at once.
				]]
				bar = lastBucket, barCap = "PAIL",
				hint = "Sealer comes from the depot",
			}
		end
		if held ~= "Sealer Bucket" then
			return {
				step = 2, key = "take-pail", title = "TAKE THE SEALER",
				chips = { chip({ cap = keyFor("bucket") or "1", note = "SEALER" },
					{ cap = "TAP", note = "SEALER" }) },
				point = "bucket", spot = drivewaySpot(), caption = "POUR HERE",
				glow = drive, hint = "It is in your toolbar",
			}
		end
		return {
			step = 2, key = "pour", title = "POUR IT ALL OUT",
			-- One press is one glug now, not an open spout (see Config.PourDump), so
			-- the desktop chip stopped saying HOLD. The touch chip still says ON / OFF:
			-- that control is a latch and a held latch chains glugs.
			chips = { chip({ cap = "LMB", note = "HOLD TO POUR" },
				{ cap = "POUR", note = "ON / OFF" }) },
			-- THE PAIL, not the pour: a bar has to show the thing its own gate is
			-- waiting for, or it fills up while the step goes on refusing to tick --
			-- which is exactly what was reported. Reaches 1.0 on the frame lastBucket
			-- touches PAIL_EMPTY, which is the frame the beat ends.
			bar = (1 - lastBucket) / (1 - PAIL_EMPTY), barCap = "PAIL",
			spot = drivewaySpot(), caption = "ONE BIG PUDDLE", ringClose = true,
			glow = drive, hint = "Keep tipping it out in ONE place until it is empty",
		}
	end

	--==[ 2b -- ran the slab dry with sealer still in the pail ]===============
	--[[
		Not an objective of its own, deliberately: it wears whichever number the player
		was already on, so the crumb does not jump backwards and the denominator stays
		put. It is the same lesson as objective 2 arriving late, which is why it says
		the same thing in the same words.

		The bar fills as the pail empties, so it reads as a job to finish rather than as
		a telling-off. It replaces the coverage bar for as long as it is up -- coverage
		cannot move while there is nothing to spread, and a frozen bar under a live
		instruction is worse than no bar.
	]]
	if stalled then
		return {
			step = if sweptOnce then 4 else 3, key = "top-up", title = "EMPTY THE PAIL",
			chips = { chip({ cap = keyFor("bucket") or "1", note = "SEALER" },
				{ cap = "TAP", note = "SEALER" }),
				chip({ cap = "LMB", note = "HOLD TO POUR" },
				{ cap = "POUR", note = "ON / OFF" }) },
			bar = 1 - lastBucket, barCap = "PAIL",
			-- ring the hotbar slot only while the pail is not the thing in hand
			point = if held ~= "Sealer Bucket" then "bucket" else nil,
			spot = drivewaySpot(), caption = "POUR THE REST", ringClose = true,
			-- NOT "put it down", which was the first wording: setting the pail down used
			-- to be a real control (the removed reclaim mechanic) and the phrase still
			-- reads as one. What is being asked for is a pour.
			glow = drive, hint = "Pour what is left onto the slab",
		}
	end

	--==[ 3 -- the first pass ]===============================================
	if not sweptOnce then
		if held ~= "Squeegee" then
			return {
				step = 3, key = "take-blade", title = "TAKE THE SQUEEGEE",
				chips = { chip({ cap = keyFor("squeegee") or "2", note = "SQUEEGEE" },
					{ cap = "TAP", note = "SQUEEGEE" }) },
				point = "squeegee", spot = lastLooseAt or drivewaySpot(),
				caption = "STAND IN IT", ringClose = true,
				glow = drive, hint = "Then go and stand in the sealer",
			}
		end
		--[[
			The only beat that draws the chevrons, and the only one that needs to.

			They run from the puddle out across the slab and back, which is the whole
			instruction: stand where the sealer is and drag it up and down the grey. Once
			the pass has landed they come off and never come back -- guiding a player who
			has understood is how a tutorial outstays its welcome.

			The title names the PUDDLE rather than saying "it". Reported by the owner:
			players did not connect the sealer on the ground with the tool in their hand,
			and "PUSH IT ACROSS" over "Walk while you hold it" never once says what is
			being pushed -- both "it"s could as easily have meant the squeegee, or the
			mouse button.
		]]
		local from = lastLooseAt or (drive and drive.Position) or Vector3.zero
		return {
			step = 3, key = "spread", title = "PUSH THE PUDDLE",
			-- Notes stay SHORT. The keycap column is sized off the cap, not the note, so
			-- a long note is what pushes a chip into wrapping -- and the meaning is
			-- carried by the title and the chevrons anyway, not by the chips.
			chips = { chip({ cap = "LMB", note = "HOLD", hold = true },
				{ cap = "SPREAD", note = "ON / OFF" }),
				chip({ cap = "W", note = "UP AND BACK" },
				{ cap = "STICK", note = "UP AND BACK" }) },
			bar = lastCoverage / FIRST_PASS, barCap = "SPREAD",
			spot = from, caption = "STAND IN IT", ringClose = true,
			glow = drive, arrowsOn = drive, arrowsFrom = from,
			hint = "Stand in the sealer and drag it",
		}
	end

	--==[ 4 -- the rest of it, unaided ]======================================
	--[[
		The hand comes off here. No chevrons, no start ring -- the player has laid a
		pass and the only thing left to say is how much is still grey, which the bar
		says without words.
	]]
	if not finished then
		--[[
			FINISHING THE PATH COMES FIRST; THE REFILL IS THE STEP AFTER IT.

			Owner, 2026-08-14: "only once they finish the entire sidewalk then make them
			refill the pail." This beat was what broke that order -- it fired the instant
			the pail read empty, which is most of the way through every job, so the card
			sent the player to the tanks with the path still half grey. It is the same
			complaint as the earlier "its telling me to fill the pail but i'm supposed to
			coat the driveway fully" (COATED 74% under FILL THE PAIL); that was answered
			by fixing the BAR, and the ordering was still wrong.

			`bare` is what makes an empty pail stop being a blocker. Coverage rises by
			SPREADING, not by pouring, so a player with sealer still lying on the slab has
			everything they need and nothing to go to the pump for. Since the pour gate was
			tightened to require an empty pail, they reach this beat having already tipped
			a whole 500-unit pail onto a 320 stud^2 path -- 1.56x what one coat needs --
			so in the ordinary run this now never fires at all, and the refill they are
			asked for is 5a below, after the path is done.

			⚠ IT CANNOT JUST BE DELETED. Pail empty AND slab bare is a player who
			genuinely cannot raise coverage by any action available to them; with no beat
			here that is a dead end on the last objective, which is the exact shape of bug
			this tutorial has already shipped twice. Both halves, or neither.
		]]
		if lastBucket <= PAIL_EMPTY and bare then
			return {
				step = 4, key = "refill-finish", title = "FILL THE PAIL",
				chips = { chip({ cap = "E", note = "HOLD AT PUMP", hold = true },
					{ cap = "HOLD", note = "AT THE PUMP", hold = true }) },
				spot = refuelSpot(), caption = "REFILL",
				glow = pumpPart(), glowThrough = true,
				-- The pail, for the reason given on refill-pour above: the bar has to show
				-- the thing the title is asking for, and coverage cannot move while there
				-- is nothing on the slab to push.
				bar = lastBucket, barCap = "PAIL",
				hint = "Out of sealer -- top up, then finish the path",
			}
		end
		return {
			step = 4, key = "finish", title = "FINISH THE PATH",
			chips = { chip({ cap = "LMB", note = "HOLD", hold = true },
				{ cap = "SPREAD", note = "ON / OFF" }) },
			bar = lastCoverage / Config.CompleteAt, barCap = "COATED",
			spot = drivewaySpot(), caption = "KEEP GOING",
			glow = drive, hint = "Up and back -- overlap every pass",
		}
	end

	--[[
		A "SWEEP UP THE REST" beat sat here, between finishing the slab and going in to
		spend: set the pail down by the deepest puddle and squeegee the leftovers back
		into it, scored against whatever was lying there when it opened.

		Removed on 2026-08-11 with the mechanic it taught. A finished driveway settles
		to cured coat on the frame it is called done and the loose sealer goes with it,
		so there is nothing left on the slab to point a player at. RECLAIM_SHOW,
		RECLAIM_CLEAR, RECLAIM_PATIENCE and the three latches went with it, and so did
		the only cue in this file that named a HudActions channel -- "TogglePail" is no
		longer registered by anything, so a touch player pressing it would have been
		pressing a dead button.

		Nothing renumbered: it was a BEAT inside objective four, never an objective.
	]]

	--==[ 5a -- fill up, if the first slab never made them ]===================
	--[[
		THE LESSON THE TUTORIAL COULD PREVIOUSLY SKIP (owner, 2026-08-12).

		Running dry is taught by happening: `refill-pour` and `refill-finish` catch a
		player whose pail empties mid-job and send them to the tanks. But a player who
		gets through the whole first driveway on what they started with is never sent,
		and the tutorial used to end there -- so they walked out onto the map with an
		empty pail, a driveway they could not start, and nothing anywhere having said
		where more sealer comes from. Every other control in the game is taught by being
		made to use it; this is that, for the one control the first job does not force.

		A BEAT, NOT A SIXTH OBJECTIVE. The denominator is a constant and no beat may
		move it -- see OBJECTIVES. It wears the number of the objective it sits inside,
		and that is 5 rather than 4 on purpose: the driveway is done, the crumb has
		already earned its last tick, and both halves of this step are the same errand --
		go to the depot, fill up, spend your money. The waypoint moves from the pad to
		the counter without the card ever counting past five.

		SKIPPED ENTIRELY IF THERE IS NO PUMP TO POINT AT. A place with no Refuel bay in
		its garage would otherwise hand the player a step with no completable condition
		and no marker, one beat short of the end of the run. The refill beats above can
		afford to be careless about that -- a player can always pour their way out of
		them -- and this one cannot, because nothing but the pump clears it.

		WHAT IT CANNOT COVER: somebody who walks past the pump to the counter and buys
		anyway. The purchase is what sets DepotSealed, the flag is the server's word that
		the run is over, and the early return at the top of this function honours it --
		so that player gets the finale with the lesson still owed. Ordering is the whole
		of the defence here: this beat holds the card and the marker until they have
		filled, and the counter is a step they have not been told about yet.
	]]
	if not refilled and pumpPart() then
		return {
			step = OBJECTIVES, key = "learn-fill", title = "FILL THE PAIL",
			chips = { chip({ cap = "E", note = "HOLD AT PUMP", hold = true },
				{ cap = "HOLD", note = "AT THE PUMP", hold = true }) },
			-- The pail itself, so the bar the player is watching is the thing they are
			-- filling, and it reads 100% on the frame the step ticks.
			bar = lastBucket, barCap = "PAIL",
			spot = refuelSpot(), caption = "REFILL", ringClose = true,
			glow = pumpPart(), glowThrough = true, strongGuide = true,
			hint = "Follow the gold trail",
		}
	end

	--==[ 5 -- spend it ]=====================================================
	if not upgraded then
		return {
			step = 5, key = "buy", title = "BUY AN UPGRADE",
			chips = { chip({ cap = "E", note = "THE COUNTER" }, { cap = "TAP", note = "THE COUNTER" }) },
			point = "blade", spot = counterSpot(), caption = "UPGRADES", ringClose = true,
			glow = counterPart(), glowThrough = true, strongGuide = true,
			hint = "Follow the gold trail",
		}
	end

	--==[ bought, and waiting on the round trip that opens the gate ]==========
	--[[
		A beat rather than nil, and that is the whole reason it exists: nil is
		teardown, and DepotSealed lands a round trip after the purchase does.

		In practice nobody sees this. DepotGate sets TutBought and DepotSealed in the
		same breath, so the two reach this client in one replication batch and the
		finale takes over on the same frame. But "in one batch" is a guess about the
		network, and the cost of being wrong is the card vanishing with the finale
		never drawn -- so nothing here is resting on the guess.
	]]
	-- TutBought can replicate before DepotSealed. Do not leave the player on a
	-- dead "THAT'S THE JOB" card while that server flag catches up: the purchase
	-- itself is enough to move the client guidance to the depot apron.
	local gate = mapExitPart()
	local spot = mapExitSpot()
	if gate and spot then
		return {
			step = OBJECTIVES, key = "done", title = "THE MAP IS YOURS", finale = true,
			spot = spot, caption = "GO TO MAP", ringClose = true,
			glow = gate, glowThrough = true, strongGuide = true,
			hint = "Follow the gold trail",
		}
	end
	return { step = OBJECTIVES, key = "opening", title = "THE MAP IS YOURS", finale = true }
end

--==[ drive it ]==============================================================
--[[
	Wait for the saved profile before drawing anything.

	The flags arrive from the DataStore a moment after the client does, so this
	used to sleep a flat three seconds and hope -- under which a slow load still
	flashed step one at a player who finished weeks ago, and a fast one made every
	new player stare at nothing. UpgradeService says when the profile has landed;
	the timeout is only there so a place with no DataStore access still starts.
]]
if not plr:GetAttribute("ProfileLoaded") then
	local ready = false
	local conn = plr:GetAttributeChangedSignal("ProfileLoaded"):Connect(function()
		ready = true
	end)
	local t0 = os.clock()
	while not ready and os.clock() - t0 < 12 do task.wait(0.1) end
	conn:Disconnect()
end

-- A player who arrives with it already done never sees any of this, and the loop
-- below has nothing to do for the rest of the session. Read off DepotSealed
-- rather than TutorialDone: between the two sits the one state this has to get
-- right, somebody who bought the blade last session and logged out before sealing
-- the yard.
local alreadyDone = plr:GetAttribute(DEPOT_ATTR) == true

local loop: RBXScriptConnection? = nil
local function teardown()
	gui.Enabled = false
	bannerGui.Enabled = false
	pulse.Visible = false
	pointerGui.Enabled = false
	hideWorld()
	setToastLane(TOAST_HOME)
	fx:Destroy()
	if loop then loop:Disconnect() end
end

if alreadyDone then
	teardown()
	return
end

-- The two moments that get the middle of the screen.
plr:GetAttributeChangedSignal("TutSealed"):Connect(function()
	if plr:GetAttribute("TutSealed") then
		banner("DRIVEWAY COMPLETE!", LIME, 1.7)
	end
end)

local function markTutorialComplete()
	if finishedAt then return end
	if plr:GetAttribute(DEPOT_ATTR) == true or plr:GetAttribute("TutBought") == true then
		finishedAt = os.clock()
		banner("TUTORIAL COMPLETE!", GOLD, 2.2)
	end
end

plr:GetAttributeChangedSignal(DEPOT_ATTR):Connect(markTutorialComplete)
plr:GetAttributeChangedSignal("TutBought"):Connect(markTutorialComplete)

--[[
	The tick, and why it needs a state machine at all.

	The beat is derived, so "the player finished something" is not an event -- it is
	the frame on which `currentBeat` starts answering differently. The completed
	beat is held on screen wearing its tick for TICK_HOLD before the new one is
	allowed to draw, which is the entire reward for finishing a step and the reason
	none of this needs a dialogue box to click through.
]]
local shownKey: string? = nil
local shownTitle = ""
local shownStep = 0
local shownAt = 0
local tickUntil = 0

--[[
	Out of the way while they work.

	The card is a persistent block across the top of the screen, and on a handset
	that is a real share of everything the player can see -- with the shell's own
	corner block and its key rail either side of it, what is left to look at the
	driveway through is not large. The card earns that space while they are reading
	it. It does not earn it while they are holding the button down on the thing it
	has just told them to do, which is most of the run: a pour is five seconds of
	holding and a pass is the length of a driveway.

	So while a tool is actually laying sealer the card folds down to what is still
	worth reading mid-pour -- the instruction and the bar -- and drops the step
	counter, the keycaps and the nudge. The keycaps are the clearest of the three:
	they are a picture of the key the player currently has held down.

	HELD for a beat past the last working frame rather than tracked exactly. A
	TAPPED pour is discrete glugs Config.PourDumpGap apart -- 0.85s of shut spout
	between them -- and a card that unfolded and refolded between every tap would be
	worse than one that never moved at all. Holding the button keeps the spout open
	and `laying` continuously true (see Config.PourHold), so this only ever bridges
	gaps; it never extends a stream.
]]
local BUSY_HOLD = 1.0
local busyUntil = 0

-- Escalation. Two thresholds, and the second only makes what is already on
-- screen louder rather than adding anything new to read.
local IDLE_SOFT, IDLE_HARD = 5, 11
-- Seeded rather than left at zero: os.clock() is already large by the time this
-- runs, so a zero here reads as "idle for the whole session" and the nudge fires
-- on the first frame.
local movedAt = os.clock()
local lastWhere: Vector3? = nil
local lastBar = 0
local lastHeld: string? = nil

loop = RunService.RenderStepped:Connect(function()
	local now = os.clock()

	if bannerGui.Enabled and now > bannerUntil then
		bannerGui.Enabled = false
	end

	local beat = currentBeat()
	if not beat then
		teardown()
		return
	end

	--==[ has anything at all happened lately ]===============================
	--[[
		Three kinds of progress, because a player can be stuck in three different
		ways: not walking, not working the tool, not finding the toolbar. Any one of
		them resets the clock, so the nudge only ever fires at somebody genuinely
		standing still doing nothing.

		THE TWO MEASURED ONES ARE HIGH-WATER MARKS, NOT FRAME DELTAS, and that is the
		whole of whether this works. "Has the player moved 2.5 studs SINCE LAST FRAME"
		is false at every walking speed the game has -- 16 studs a second at 60fps is a
		quarter of a stud per frame -- so a frame-to-frame test never fires once and
		the nudge pops at five seconds into a player who is sprinting across the map.
		The reference point only moves when the threshold is actually cleared, which
		turns the test into "since the last time we noticed you move".
	]]
	local hrp = rootPart()
	local where = if hrp then hrp.Position else nil
	local held = heldTool()
	local barNow = beat.bar or 0

	if where and (not lastWhere or (where - lastWhere).Magnitude > 2.5) then
		movedAt = now
		lastWhere = where
	end
	if barNow > lastBar + 0.004 then
		movedAt = now
		lastBar = barNow
	elseif barNow < lastBar - 0.05 then
		-- a fresh beat brought a fresh bar; re-baseline rather than treating the drop
		-- as progress
		lastBar = barNow
	end
	if held ~= lastHeld then
		movedAt = now
		lastHeld = held
	end

	local idle = now - movedAt
	local urgent = idle >= IDLE_HARD

	--==[ beat changed? ]=====================================================
	if beat.key ~= shownKey then
		--[[
			A beat that came and went inside TICK_MIN was derived state settling rather
			than something the player did -- walking onto a driveway that is already half
			sealed resolves three latches on one frame -- and a tick for something nobody
			saw themselves do reads as the interface glitching.
		]]
		if shownKey and now - shownAt >= TICK_MIN and not beat.finale then
			tickUntil = now + TICK_HOLD
			SoundKit.play("Ding", nil, 0.04)
			pop(0.9)
		else
			-- straight through: nothing to celebrate, the new instruction draws now
			tickUntil = 0
			shownTitle, shownStep = beat.title, beat.step
			pop()
		end
		shownKey, shownAt = beat.key, now
		movedAt = now
	end

	local ticking = now < tickUntil
	if not ticking and (shownTitle ~= beat.title or shownStep ~= beat.step) then
		-- the tick has run out; the new instruction takes the card
		shownTitle, shownStep = beat.title, beat.step
		pop()
	end

	--==[ stand down behind a panel ]=========================================
	if panelOpen() then
		gui.Enabled = false
		hideWorld()
		setToastLane(TOAST_HOME)
		-- The one thing with work to do behind an open panel: the ring on the row the
		-- upgrade beat is asking them to buy.
		if beat.point == "blade" then
			markControl(bladeBuyButton())
		else
			pulse.Visible = false
		end
		return
	end
	gui.Enabled = true

	--==[ the card ]==========================================================
	--[[
		Folded down while they are working -- see BUSY_HOLD.

		Never during the tick or the finale: those are the card's two moments of being
		worth looking at, they last seconds, and by the time either is on screen the
		player has stopped working anyway. The fade is part of it rather than dressing
		-- what is left is a strip of type over the driveway, and it should read as
		something laid over the world instead of a panel still parked on it.
	]]
	if HudBus.latest.laying == true then busyUntil = now + BUSY_HOLD end
	local compact = now < busyUntil and not ticking and not beat.finale
	header.Visible = not compact
	card.BackgroundTransparency = if compact then 0.3 else 0
	cardStroke.Transparency = if compact then 0.3 else 0

	if beat.finale then
		crumb.Text = "TUTORIAL COMPLETE"
		crumb.TextColor3 = LIME
	else
		crumb.Text = ("TUTORIAL  %d / %d"):format(shownStep, OBJECTIVES)
		crumb.TextColor3 = GOLD
	end

	if ticking then
		title.Text = "\u{2713}  " .. shownTitle
		title.TextColor3 = LIME
		cardStroke.Color = LIME
		setChips(nil)
		barRow.Visible = false
		nudge.Visible = false
	else
		title.Text = beat.title
		title.TextColor3 = if beat.finale then LIME else CREAM
		cardStroke.Color = UIKit.Theme.ink
		setChips(if compact then nil else beat.chips)

		barRow.Visible = beat.bar ~= nil
		if beat.bar then
			local want = math.clamp(beat.bar, 0, 1)
			-- eased up, snapped down: a bar creeping backwards looks like the game
			-- forgetting, but a reset (a fresh beat) should land immediately
			barShown = if want < barShown - 0.05 then want
				else barShown + (want - barShown) * 0.18
			barFill.Size = UDim2.new(math.clamp(barShown, 0, 1), 0, 1, 0)
			barFill.BackgroundColor3 = if barShown >= 0.999 then LIME else GOLD
			barCap.Text = ("%s  %d%%"):format(beat.barCap or "", math.floor(barShown * 100 + 0.5))
		end

		nudge.Visible = not compact and idle >= IDLE_SOFT and beat.hint ~= nil
		if nudge.Visible then
			nudge.Text = "\u{2192}  " .. (beat.hint or "")
			nudge.TextTransparency = if urgent then 0.15 * (0.5 + 0.5 * math.sin(now * 6)) else 0
		end
	end

	--[[
		Filled off the LIVE beat and lit off the SHOWN one.

		That split is what colours an objective's pip in while the card is still
		reading "done" for it -- and what stops a tick BETWEEN two beats of the SAME
		objective (take the sealer, then pour it) flashing that pip green and taking
		it back half a second later.
	]]
	for i, p in ipairs(pips) do
		p.BackgroundColor3 = if i < beat.step then LIME
			elseif i == shownStep then GOLD
			else SLATE
	end

	-- After the chips, because they are most of what decides how tall the card is,
	-- and before the toast lane, which is measured off where it ends up.
	place()
	setToastLane(laneBelowCard())

	--==[ the world ]=========================================================
	local strongWorldGuide = urgent or beat.strongGuide == true
	if beat.spot then
		showWorld(beat.spot, beat.caption or "", where, beat.ringClose, strongWorldGuide)
	else
		hideWorld()
	end
	setGlow(beat.glow, beat.glowThrough == true, strongWorldGuide)

	if beat.arrowsOn and beat.arrowsFrom and not ticking then
		showArrows(beat.arrowsOn, beat.arrowsFrom,
			if hrp then hrp.CFrame.LookVector else nil, urgent)
	else
		hideArrows()
	end

	--==[ the control on screen ]=============================================
	if beat.point == "bucket" then
		markControl(slotFor("bucket"))
	elseif beat.point == "squeegee" then
		markControl(slotFor("squeegee"))
	elseif beat.point == "blade" then
		-- nothing to ring until they reach the counter and open the panel
		markControl(bladeBuyButton())
	else
		pulse.Visible = false
	end
end)
