--[[
	Shell -- the whole on-screen interface, laid out to the reference art.

	  top left      area name, job progress, reward, quick actions
	  right edge    square icon rail with notification tabs
	  bottom left   outlined stat readouts
	  bottom centre the hotbar, and the rig's gauge in place of it while driving

	No panel sits behind the text blocks; the hard outline is what keeps them
	legible over the world, which is what the reference does and why it reads as
	bright rather than boxed-in.

	Every live number comes from HudBus, which DrivewayClient fills with the same
	table it hands its own HUD. Nothing here recomputes the simulation.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local GuiService = game:GetService("GuiService")

local Pack = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(Pack:WaitForChild("UIKit"))
local TopBand = require(Pack:WaitForChild("TopBand"))
local Upgrades = require(Pack:WaitForChild("Upgrades"))
local Rebirth = require(Pack:WaitForChild("Rebirth"))
local Quests = require(Pack:WaitForChild("Quests"))
local Daily = require(Pack:WaitForChild("Daily"))
local CashFx = require(Pack:WaitForChild("CashFx"))
local HudBus = require(Pack:WaitForChild("HudBus"))
local Passes = require(Pack:WaitForChild("Passes"))
local Boosts = require(Pack:WaitForChild("Boosts"))
local CashPacks = require(Pack:WaitForChild("CashPacks"))
local HudActions = require(Pack:WaitForChild("HudActions"))
-- The squeegee case is its own module rather than another Shell:_build. This
-- file is 5,600 lines, is edited live by another builder, and its Source is
-- close enough to the 200,000-character write limit that appending a screen to
-- it fails outright. It takes gui / plr / close() / _register() from `self`.
local SkinCase = require(Pack:WaitForChild("SkinCase"))
local ColorCase = require(Pack:WaitForChild("ColorCase"))
local SealPack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Rigs = require(SealPack:WaitForChild("Rigs"))
local Sections = require(SealPack:WaitForChild("Sections"))
local Lucky = require(SealPack:WaitForChild("Lucky"))
-- Only for the colours the Skins rail key cycles through; the case screen itself
-- is SkinCase's, and it requires this module separately for its own reasons.
local Skins = require(SealPack:WaitForChild("SqueegeeSkins"))
-- and the canonical rig it dresses; see _dressSkinsKey
local ToolBuilder = require(SealPack:WaitForChild("ToolBuilder"))

local T = UIKit.Theme
local Console = require(game:GetService("ReplicatedStorage"):WaitForChild("SealerUI"):WaitForChild("ConsoleControls"))

local Shell = {}
Shell.__index = Shell

--[[
	The one mounted instance, published so scripts that did not mount the shell
	themselves (ZoneProgressClient, BlueberryBundleToastClient) can still show a
	toast. Nil until SealerUIClient has mounted; a toast asked for before then is
	dropped rather than queued, because every caller fires long after mount.
]]
local mounted: any = nil

function Shell.toast(text: string, good: boolean?)
	if mounted then mounted:Toast(text, good) end
end

local MINT   = Color3.fromRGB(122, 255, 206)
local GOLD   = Color3.fromRGB(255, 214, 54)
local ORANGE = Color3.fromRGB(255, 148, 42)
local LIME    = Color3.fromRGB(126, 255, 118)
local SKY    = Color3.fromRGB(86, 208, 255)

local ROBUX_PRODUCT = 3634048798
local SKIP_REBIRTH_PRODUCT = 3710199253
local robuxPrice: number? = nil
local robuxRows: { () -> () } = {}

task.spawn(function()
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(ROBUX_PRODUCT, Enum.InfoType.Product)
	end)
	if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
		robuxPrice = tonumber(info.PriceInRobux)
	else
		warn("[Shell] could not read the upgrade product price: " .. tostring(info))
	end
	-- the rows are built before this lands, so they are told rather than polled
	for _, fn in ipairs(robuxRows) do fn() end
end)


local FILL_PASS = Passes.ById.InstantFill
local passPrice: number? = nil

local passOnSale: boolean? = nil
local passRows: { () -> () } = {}

task.spawn(function()
	if not FILL_PASS or FILL_PASS.assetId == 0 then
		passOnSale = false
		return
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(FILL_PASS.assetId, Enum.InfoType.GamePass)
	end)
	if ok and type(info) == "table" then
		passPrice = tonumber(info.PriceInRobux)
		passOnSale = info.IsForSale == true and passPrice ~= nil
	else
		warn("[Shell] could not read the " .. FILL_PASS.name .. " pass: " .. tostring(info))
	end
	for _, fn in ipairs(passRows) do fn() end
end)

-- Hotbar keys: idle blue, equipped lime. The held tool has to be readable from
-- the corner of the eye, which a colour does and a caption does not.
local SLOT_IDLE = Color3.fromRGB(64, 172, 255)
local SLOT_ON   = Color3.fromRGB(96, 232, 108)
local SLOT      = 82
local SLOT_GAP  = 10
-- The stat stack in the bottom-left corner. Named rather than written inline
-- because the hint line has to clear it, and the two were sized independently
-- for long enough to end up drawn through each other.
local STAT_X, STAT_Y = 24, 18    -- margins off the left and bottom edges
local STAT_W, STAT_H = 440, 182
-- Studs from your own truck within which its readout is worth showing. About
-- three truck lengths: close enough that you are working ON it -- loading the
-- wand, backing onto the fill pad -- rather than merely on the same street.
local RIG_NEAR = 70
local SHOW_HINT = false

-- Rail keys match the hotbar's, since they are now the same object: a moulded
-- square with a picture over a caption. The rail sizes itself from these rather
-- than carrying a hardcoded height that stopped matching its contents.АааАААА
local RAIL_BOX  = 82
local RAIL_GAP  = 10

--==[ fitting the window ]====================================================

--[[
	How big this window is against the one the reference art was drawn for.

	Every block on this HUD is laid out in pixel offsets, and those offsets were
	taken off art drawn for a desktop. A phone is not a small desktop: it reports a
	window about a third of the area and nothing here was ever told so. The
	440-wide stat stack is over half the width of a handset, and the six-key rail
	is 542px against a screen that is often under 400 -- so both ends of the rail
	were drawn past the edge of the screen, and the corner readouts sat over the
	middle of the world. That is the whole of the "the mobile UI covers everything"
	complaint, and it is a units problem rather than a design one.

	So: one ratio, read off the camera and shared by every block. Taken on the
	TIGHTER axis, because a block scaled to fit the width can still run off the
	bottom, and height is what a handset is short of.

	It is applied as a UIScale on each block's root rather than by rewriting the
	offsets, and that is what makes it cheap: a UIScale scales about the
	AnchorPoint, and every block here is already anchored to the edge it belongs
	on, so a scaled block shrinks toward its own corner instead of drifting into
	the middle of the screen. The gauge has worked this way since it started
	sharing the bottom edge with the stat stack; this is that trick given one
	source and pointed at the rest of the screen.

	THE FLOOR WAS 0.62 AND IT WAS THE BUG (2026-08-14). It was set where legibility
	was thought to beat footprint -- 32px stat rows, 12px rail captions -- on the
	reasoning that a HUD which is proportionally too big beats one that cannot be
	read. That trade is real, but the number was above what every phone except the
	very largest actually asks for, so the clamp was not a rare fallback: it was the
	normal case, and it INFLATED the HUD on almost every handset in the world.

	Measured against the three devices in the report:

		device                viewport   wants   got     result
		iPhone 16 Pro Max     956x440    0.611   0.620   +1%   -- fine, and it was
		iPhone 15/14          844x390    0.542   0.620   +14%
		Android 20:9          892x412    0.572   0.620   +8%
		Android 16:9          800x360    0.500   0.620   +24%

	The Pro Max is the one screen tall enough that the floor barely touches it,
	which is exactly why it was the one that looked right. Everything else was being
	drawn up to a quarter too large, and it showed twice over: the rail could not
	fit one column and wrapped into two (see RAIL_SQUEEZE, which is measured against
	this number), and the left column ran out of room -- on the 16:9 Android the
	stat stack overlapped the quick buttons by fifteen pixels.

	At 0.45 every one of them gets its natural scale, the rail is one column
	everywhere, and the gap between the quick buttons and the stat stack comes out
	at 50-70px on all four -- the Pro Max's own spacing. The type does get smaller
	(16px rather than 20 on the smallest), and that is the honest cost: it is the
	SAME PROPORTION of a smaller screen, which is what "fits" means, and it beats
	overlapping furniture by a distance.

	0.45 rather than lower because the shortest landscape handset worth drawing for
	is about 320 tall, which asks for 0.444. Below that is not a phone.
]]
local DESIGN_W, DESIGN_H = 1280, 720
local FIT_FLOOR = 0.45

local TOUCH = UserInputService.TouchEnabled

local fitNow = 1
local viewNow = Vector2.new(DESIGN_W, DESIGN_H)
local fitHooks: { (number, Vector2) -> () } = {}
local watching = false

local function refit()
	local cam = workspace.CurrentCamera
	local v = if cam then cam.ViewportSize else viewNow
	if v.X < 200 or v.Y < 200 then return end
	viewNow = v
	fitNow = math.clamp(math.min(v.X / DESIGN_W, v.Y / DESIGN_H), FIT_FLOOR, 1)
	for _, fn in ipairs(fitHooks) do fn(fitNow, v) end
end

-- Told the current answer on the way in, so a block is built and fitted in one
-- place and never needs a first pass of its own.
local function onFit(fn: (number, Vector2) -> ())
	table.insert(fitHooks, fn)
	fn(fitNow, viewNow)
end

local function watchWindow()
	if watching then return end
	watching = true
	local conn: RBXScriptConnection? = nil
	local function hook()
		if conn then conn:Disconnect() end
		local cam = workspace.CurrentCamera
		conn = if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(refit) else nil
		refit()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hook)
	hook()
end

-- The height a block may actually use: the window less Roblox's own topbar,
-- which this ScreenGui sits below rather than under -- see mount.
local function usableY(v: Vector2): number
	return v.Y - GuiService:GetGuiInset().Y
end

local function fitBlock(frame: GuiObject, place: ((number, Vector2) -> ())?): UIScale
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	onFit(function(f, v)
		scale.Scale = f
		if place then place(f, v) end
	end)
	return scale
end

local RAIL_BUDGET  = 0.80
local RAIL_SQUEEZE = 0.85
local RAIL_GROW    = 1.35
local RAIL_EDGE     = 22
local RAIL_EDGE_MIN = 22

local function comma(n: number): string
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function cashOf(plr: Player): number
	local ls = plr:FindFirstChild("leaderstats")
	local cash = ls and ls:FindFirstChild("Cash")

	if cash and cash:IsA("IntValue") then
		return cash.Value
	end

	return 0
end
local function zone1Remote(): RemoteEvent?
	local remotes = Pack:FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild("Zone1Teleport")

	return if remote and remote:IsA("RemoteEvent")
		then remote
		else nil
end
--==[ construction ]==========================================================

function Shell.mount(playerGui: PlayerGui)
	local gui = playerGui:FindFirstChild("SealerShell")
	if gui then gui:Destroy() end
	gui = Instance.new("ScreenGui")
	gui.Name = "SealerShell"
	gui.ResetOnSpawn = false
	-- Respect the topbar inset. Ignoring it put the area title and the tool
	-- switcher underneath Roblox's own menu and chat buttons, where they were
	-- both hard to read and hard to click.
	gui.IgnoreGuiInset = false
	-- Sibling, explicitly: under Global these children would be ranked against
	-- every other ScreenGui's and the old job HUD punches through the panels.
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 20
	gui.Parent = playerGui

	local self = setmetatable({
		gui = gui,
		plr = Players.LocalPlayer,
		panels = {},
		sizes = {},
		slots = {},
		railLock = {},
		toolOrder = {},
		open = nil :: string?,
		lastBucket = 1,

		upgradeDots = {},
		upgradeHintShown = false,
		quickUpgradeAlert = nil,

		zone1FxToken = 0,
		zone1RemoteConn = nil,

	}, Shell)


	table.clear(fitHooks)
	watchWindow()

	self:_buildArea()
	self:_buildHotbar()
	self:_buildGauge()
	self:_buildRail()
	self:_buildStats()
	self:_buildFill()
	self:_buildUpgrades()
	self:_buildDealership()
	SkinCase.build(self)
	ColorCase.build(self)
	self:_buildRigBay()
	self:_buildRebirth()
	self:_buildDaily()
	self:_buildQuests()
	self:_buildShop()
	self:_buildSettings()
	self:_buildFeedback()
	self:_buildTally()
	self:_buildToasts()
	self:_buildPrompt()
	self:_watchCash()
	self:_watchSections()
	self:_watchDriving()
	self:_startUpdate()
	Console.attach(self)
	-- only now, with every pane _buildToasts included in place, is the instance
	-- ready for Shell.toast to write into
	mounted = self
	return self
end

--==[ top left: area header ]=================================================

function Shell:_buildArea()
	local block = Instance.new("Frame")
	block.Name = "Area"
	block.BackgroundTransparency = 1
	block.Position = UDim2.fromOffset(24, 10)
	block.Parent = self.gui
	fitBlock(block, function(f)
		block.Position = UDim2.fromOffset(math.round(24 * f), math.round(10 * f))
	end)


	local ROW_GAP, GROUP_GAP = 12, 18   -- between rows, and before the button pair
	local COL = 4                       -- shared left edge, clear of the chip shadow
	local y = 0                         -- bottom of the last row's visible extent
	local function row(inst, height, overTop, overBottom, gapBelow)
		local top = math.round(y + overTop)
		inst.Position = UDim2.fromOffset(COL, top)
		y = top + height + overBottom + (gapBelow or 0)
		return inst
	end

	local title, titleHolder = UIKit.bigTitle(block, "Maple Drive", 44, MINT)
	self.titleLabel = title
	-- No overhang: the 55px line box already swallows the title's own stroke.
	row(titleHolder, 55, 0, 0, ROW_GAP)

	local pill, fill, pillText = UIKit.progressPill(block, 300)
	self.progBlockPill, self.progFill, self.progText = pill, fill, pillText
	row(pill, 34, 2.5, 2.5, ROW_GAP)

	self.rewardLabel = UIKit.outlined(block, "", 26, GOLD)
	self.rewardLabel.Size = UDim2.fromOffset(450, 34)
	row(self.rewardLabel, 34, 0, 0, GROUP_GAP)

	local function toPump()
		self:Toast("Hold E on the pump nozzle in the depot garage", true)
	end

	local refill = row(UIKit.chip(block, "Quick Refill", 172, SKY, function()
		if Passes.owns(self.plr, "InstantFill") then
			-- fire reports whether anything was listening; if DrivewayClient has not
			-- registered yet, say what to do by hand rather than claim it worked
			if HudActions.fire("RefillPail") then
				self:Toast("Pail topped up", true)
			else
				toPump()
			end
		elseif passOnSale ~= false and FILL_PASS then
			MarketplaceService:PromptGamePassPurchase(self.plr, FILL_PASS.assetId)
		else
			toPump()
		end
	end), 38, 2.2, 7, ROW_GAP)

	self.refillChipLabel = refill:FindFirstChild("Label", true) :: TextLabel?

	-- Last row, so no gap below it: the block is sized to its own visible extent
	-- and a trailing ROW_GAP would be 12px of nothing hanging off the bottom.
	local quickUpgrade = row(UIKit.chip(block, "Quick Upgrade", 172, GOLD, function()
		if self.quickUpgradeAlert then
			self.quickUpgradeAlert.Visible = false
		end

		self:toggle("Upgrades")
	end), 38, 2.2, 7)

	local alert = Instance.new("TextLabel")
	alert.Name = "AffordableAlert"
	alert.AnchorPoint = Vector2.new(0.5, 0.5)
	alert.Position = UDim2.new(1, -4, 0, 4)
	alert.Size = UDim2.fromOffset(28, 28)
	alert.BackgroundColor3 = T.red
	alert.BorderSizePixel = 0
	alert.Font = UIKit.Display
	alert.Text = "!"
	alert.TextSize = 20
	alert.TextColor3 = T.white
	alert.TextXAlignment = Enum.TextXAlignment.Center
	alert.TextYAlignment = Enum.TextYAlignment.Center
	alert.ZIndex = 30
	alert.Visible = false
	alert.Parent = quickUpgrade

	UIKit.corner(alert, 14)
	UIKit.stroke(alert, 2)

	self.quickUpgradeAlert = alert

	local areaBaseHeight = y

	local coatOffer = script:FindFirstChild("InstantCoatOffer")
	if coatOffer then
		coatOffer = coatOffer:Clone()
		coatOffer.Parent = block

		local cap = coatOffer:FindFirstChild("Cap") :: TextButton
		local priceLabel = coatOffer:FindFirstChild("Price") :: TextLabel

		local boost = Boosts.ById.Endless

		local priced: string? = nil

		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfoAsync(boost.productId, Enum.InfoType.Product)
			end)
			if ok and tonumber(info.PriceInRobux) then
				priced = ("R$ %d"):format(tonumber(info.PriceInRobux) :: number)
				priceLabel.Text = priced
			else
				warn("[Shell] could not read Instant Coat price: " .. tostring(info))
				priceLabel.Text = "???"
			end
		end)

		local originalPos = cap.Position

		cap.MouseButton1Down:Connect(function()
			TweenService:Create(cap, TweenInfo.new(0.06), {
				Position = originalPos + UDim2.fromOffset(0, 4)
			}):Play()
		end)

		local function release()
			TweenService:Create(cap, TweenInfo.new(0.09, Enum.EasingStyle.Back), {
				Position = originalPos
			}):Play()
		end
		cap.MouseButton1Up:Connect(release)
		cap.MouseLeave:Connect(release)

		UIKit.bob(coatOffer, 0.06, 1.8)

		cap.Activated:Connect(function()
			if not boost or not boost.productId or boost.productId == 0 then
				self:Toast("Instant Coat is not on sale yet", false)
				return
			end
			MarketplaceService:PromptProductPurchase(self.plr, boost.productId)
		end)
	end

	block.Size = UDim2.fromOffset(460, areaBaseHeight)

	task.spawn(function()
		local remotes = Pack:WaitForChild("Remotes", 30)
		local remote = remotes and remotes:WaitForChild("Zone1Teleport", 30)

		if not (remote and remote:IsA("RemoteEvent")) then
			return
		end

		if self.zone1RemoteConn then
			self.zone1RemoteConn:Disconnect()
		end

		self.zone1RemoteConn = remote.OnClientEvent:Connect(function(action: string)
			if action ~= "Arrived" then
				return
			end

			local point = workspace:FindFirstChild("TeleportPoint")
			if not point then
				return
			end

			self.zone1FxToken += 1

			local token = self.zone1FxToken

			for _, inst in ipairs(point:GetDescendants()) do
				if inst:IsA("Beam")
					or inst:IsA("Trail")
					or inst:IsA("ParticleEmitter") then

					inst.Enabled = true

					if inst:IsA("ParticleEmitter") then
						inst:Emit(
							math.max(
								12,
								math.floor(inst.Rate * 0.35)
							)
						)
					end
				end
			end

			task.delay(3, function()
				if self.zone1FxToken ~= token then
					return
				end

				for _, inst in ipairs(point:GetDescendants()) do
					if inst:IsA("Beam")
						or inst:IsA("Trail")
						or inst:IsA("ParticleEmitter") then

						inst.Enabled = false

						if inst:IsA("ParticleEmitter") then
							inst:Clear()
						end
					end
				end
			end)
		end)
	end)

end

--==[ bottom centre: hotbar ]=================================================

local KEY_OF = {
	[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = 10,
}

local TextService = game:GetService("TextService")

local NAME_W, NAME_H = SLOT - 14, 20

-- "Sealer Bucket" -> "Bucket", "Squeegee" -> "Squeegee". The noun is the name;
-- everything in front of it is decoration the icon has already covered.
local function shortName(full: string): string
	local last = full
	for w in full:gmatch("%S+") do last = w end
	return last
end

local TOOL_GLYPH: { [string]: string } = {
	Bucket   = "rbxassetid://91502742751495",
	Squeegee = "rbxassetid://75056316133031",
	Wand     = "rbxassetid://80563590321370",
}

-- Where the icon sits inside the key, named because three places now share them.
local ICON_TOP, ICON_H = 4, 46

local TOOL_ICON_SCALE: { [string]: number } = {
	Wand = 1.5,
}

local TOOL_ICON_DROP: { [string]: number } = {
	Wand = 8,
}
local TOOL_GLYPH_FALLBACK = "\u{1F9F0}"

local function fitSize(text: string): number
	local words = {}
	for w in text:gmatch("%S+") do table.insert(words, w) end
	if #words == 0 then return 16 end
	for size = 16, 10, -1 do
		local widest = 0
		for _, w in ipairs(words) do
			widest = math.max(widest, TextService:GetTextSize(w, size, UIKit.Display, Vector2.new(9999, 9999)).X)
		end
		if widest <= NAME_W and #words * size * 1.3 <= NAME_H then return size end
	end
	return 10
end

-- one word per line; the parens matter, gsub also returns a count
local function stack(text: string): string
	return (text:gsub("%s+", "\n"))
end
function Shell:_upgradeAffordable(track): boolean
	if track.hidden or track.pass then
		return false
	end

	local level = (self.plr:GetAttribute("Upg_" .. track.id) :: number?) or 1
	local listed = Upgrades.costOf(track.id, level)

	if listed == nil then
		return false
	end

	local needs = Upgrades.requiresOf(track.id, level)

	if needs > Rebirth.countOf(self.plr) then
		return false
	end

	local cost = if not track.unlock
		then Rebirth.priceOf(self.plr, listed)
		else listed

	return cost ~= nil and cashOf(self.plr) >= cost
end

function Shell:_refreshUpgradeAlerts()
	local anyAffordable = false

	for _, track in ipairs(Upgrades.Tracks) do
		if track.hidden then
			continue
		end

		local affordable = self:_upgradeAffordable(track)

		local dot = self.upgradeDots[track.id]
		if dot then
			dot.Visible = affordable
		end

		if affordable then
			anyAffordable = true
		end
	end

	-- Do not show the onboarding alert before the tutorial is complete.
	if self.plr:GetAttribute("DepotSealed") ~= true then
		return
	end

	-- Show the exclamation mark only once per session.
	if anyAffordable and not self.upgradeHintShown then
		self.upgradeHintShown = true

		if self.quickUpgradeAlert then
			self.quickUpgradeAlert.Visible = true
		end
	end
end
function Shell:_buildHotbar()
	local bar = Instance.new("Frame")
	bar.Name = "Hotbar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.BackgroundTransparency = 1
	bar.Position = UDim2.new(0.5, 0, 1, -16)
	bar.Size = UDim2.fromOffset(0, SLOT + 8)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.Parent = self.gui
	self.hotbar = bar
	-- AutomaticSize measures the row in its own space, so the scale lands on the
	-- measured result rather than fighting it: the keys shrink, the row still
	-- hugs however many of them there are.
	fitBlock(bar, function(f)
		bar.Position = UDim2.new(0.5, 0, 1, -math.round(16 * f))
	end)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, SLOT_GAP)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = bar

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if self.seat then return end
		local i = KEY_OF[input.KeyCode]
		if i then self:_equipSlot(i) end
	end)

	local plr = self.plr
	local function hook(inst: Instance?)
		if not inst then return end
		-- A tool MOVES between the backpack and the character on equip, so both
		-- containers fire; the defer collapses the pair into a single rebuild.
		inst.ChildAdded:Connect(function() task.defer(function() self:_refreshHotbar() end) end)
		inst.ChildRemoved:Connect(function() task.defer(function() self:_refreshHotbar() end) end)
	end
	plr.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then hook(c); self:_refreshHotbar() end
	end)
	plr.CharacterAdded:Connect(function(ch)
		hook(ch)
		task.defer(function() self:_refreshHotbar() end)
	end)
	hook(plr:FindFirstChildOfClass("Backpack"))
	hook(plr.Character)
	self:_refreshHotbar()
end

-- one moulded plastic key
function Shell:_makeSlot(index: number)
	local holder = Instance.new("Frame")
	holder.Name = "Slot" .. index
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(SLOT, SLOT)
	holder.LayoutOrder = index
	holder.Parent = self.hotbar
	UIKit.dropShadow(holder, 17, 6, 1)

	local plinth = Instance.new("Frame")
	plinth.Name = "Plinth"
	plinth.BackgroundColor3 = UIKit.deepen(SLOT_IDLE, 0.32)
	plinth.BorderSizePixel = 0
	plinth.Position = UDim2.fromOffset(0, 6)
	plinth.Size = UDim2.new(1, 0, 1, -6)
	plinth.ZIndex = 2
	plinth.Parent = holder
	UIKit.corner(plinth, 17)
	UIKit.stroke(plinth, 2.4)

	local cap = Instance.new("TextButton")
	cap.Name = "Cap"
	cap.AutoButtonColor = false
	cap.Text = ""
	cap.BackgroundColor3 = SLOT_IDLE
	cap.BorderSizePixel = 0
	cap.Size = UDim2.new(1, 0, 1, -6)
	cap.ZIndex = 3
	cap.Parent = holder
	UIKit.corner(cap, 17)
	UIKit.stroke(cap, 2.4)
	UIKit.gradient(cap)

	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.76
	shine.BorderSizePixel = 0
	shine.Position = UDim2.fromOffset(8, 7)
	shine.Size = UDim2.new(1, -16, 0, 18)
	shine.ZIndex = 4
	shine.Parent = cap
	UIKit.corner(shine, 9)

	local icon = Instance.new("TextLabel")
	icon.Name = "Glyph"
	icon.BackgroundTransparency = 1
	icon.Font = Enum.Font.GothamBold
	icon.Text = ""
	icon.TextSize = 38
	icon.TextColor3 = T.white
	icon.Position = UDim2.fromOffset(0, 4)
	icon.Size = UDim2.new(1, 0, 0, 46)
	icon.ZIndex = 5
	icon.Parent = cap

	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.BackgroundTransparency = 1
	art.Image = ""
	art.ScaleType = Enum.ScaleType.Fit
	-- Centred rather than top-left, so a scaled box grows about the middle of the
	-- key instead of hanging off its bottom edge. Same centre the glyph occupies.
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.new(0.5, 0, 0, ICON_TOP + ICON_H * 0.5)
	art.Size = UDim2.new(1, 0, 0, ICON_H)
	art.ZIndex = icon.ZIndex
	art.Visible = false
	art.Parent = cap

	-- Tucked further into the corner and a size smaller. Centred, the icon spans
	-- the middle of the key, so the badge only has to clear its left edge -- and
	-- the couple of pixels they do share read as a badge pinned on top of an
	-- icon, which is what every hotbar in the genre looks like.
	local badge = Instance.new("Frame")
	badge.Name = "Key"
	badge.Position = UDim2.fromOffset(5, 4)
	badge.Size = UDim2.fromOffset(22, 22)
	badge.BackgroundColor3 = GOLD
	badge.BorderSizePixel = 0
	badge.ZIndex = 6
	badge.Parent = cap
	UIKit.corner(badge, 7)
	UIKit.stroke(badge, 2)
	UIKit.gradient(badge, 1.15)

	local num = Instance.new("TextLabel")
	num.Name = "Digit"
	num.BackgroundTransparency = 1
	num.Size = UDim2.fromScale(1, 1)
	num.Font = UIKit.Display
	num.Text = tostring(index % 10)
	num.TextSize = 15
	num.TextColor3 = T.ink
	num.ZIndex = 7
	num.Parent = badge

	-- Sized by _refreshHotbar, not by TextScaled -- see fitSize. Left unwrapped
	-- on purpose: the line breaks are put in by hand, one word per line.
	local name = UIKit.outlined(cap, "", 16, T.white, 2)
	name.Name = "ToolName"
	name.AnchorPoint = Vector2.new(0.5, 1)
	name.Position = UDim2.new(0.5, 0, 1, -5)
	name.Size = UDim2.new(1, -12, 0, NAME_H)
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.TextYAlignment = Enum.TextYAlignment.Bottom
	name.ZIndex = 6

	cap.Activated:Connect(function() self:_equipSlot(index) end)
	cap.MouseButton1Down:Connect(function()
		TweenService:Create(cap, TweenInfo.new(0.06), { Position = UDim2.fromOffset(0, 6) }):Play()
	end)
	local function up()
		TweenService:Create(cap, TweenInfo.new(0.09), { Position = UDim2.fromOffset(0, 0) }):Play()
	end
	cap.MouseButton1Up:Connect(up)
	cap.MouseLeave:Connect(up)

	local isOn = false
	local function setOn(on: boolean)
		if isOn == on then return end
		isOn = on
		local col = on and SLOT_ON or SLOT_IDLE
		-- retint, not a colour write: the ramp's keypoints are ratios against the
		-- old base and describe the wrong hues once the base moves
		UIKit.retint(cap, col)
		UIKit.retint(badge, on and T.white or GOLD, 1.15)
		plinth.BackgroundColor3 = UIKit.deepen(col, 0.32)
	end

	return { holder = holder, name = name, icon = icon, art = art, setOn = setOn,
		tool = nil :: Tool? }
end

function Shell:_refreshHotbar()
	if not self.hotbar then return end
	local plr = self.plr
	local ch = plr.Character
	local live = {}
	for _, src in ipairs({ plr:FindFirstChildOfClass("Backpack"), ch }) do
		if src then
			for _, t in ipairs(src:GetChildren()) do
				if t:IsA("Tool") then live[t] = true end
			end
		end
	end

	local kept = {}
	for _, t in ipairs(self.toolOrder) do
		if live[t] then table.insert(kept, t); live[t] = nil end
	end
	-- anything new goes on the end, where the default hotbar puts it; sorted only
	-- so two tools arriving in the same frame land in a repeatable order
	local fresh = {}
	for t in pairs(live) do table.insert(fresh, t) end
	table.sort(fresh, function(a, b) return a.Name < b.Name end)
	for _, t in ipairs(fresh) do table.insert(kept, t) end
	self.toolOrder = kept

	-- one size across the whole bar: per-slot sizing is legible but the captions
	-- come out at different heights and the row stops reading as one control
	local size = 16
	for _, t in ipairs(kept) do size = math.min(size, fitSize(shortName(t.Name))) end

	for i = 1, math.max(#kept, #self.slots) do
		local tool = kept[i]
		if tool and not self.slots[i] then
			self.slots[i] = self:_makeSlot(i)
		end
		local slot = self.slots[i]
		if slot then
			-- a UIListLayout skips invisible children, so a spare slot costs no gap
			slot.holder.Visible = tool ~= nil
			slot.tool = tool
			if tool then
				slot.name.Text = stack(shortName(tool.Name))
				slot.name.TextSize = size
				-- anything without the attribute is somebody else's tool in our bar,
				-- so it gets the generic toolbox rather than nothing at all
				local kind = tool:GetAttribute("SealerTool") :: string?
				local want = (tool.Name == "BonusHammer" and "rbxassetid://104339650135000") or (kind and TOOL_GLYPH[kind]) or TOOL_GLYPH_FALLBACK
				local isArt = want:sub(1, 13) == "rbxassetid://"

				slot.art.Image = if isArt then want else ""
				slot.art.Visible = isArt
				-- height only; see TOOL_ICON_SCALE for why the width is left alone
				local scale = (kind and TOOL_ICON_SCALE[kind]) or 1
				slot.art.Size = UDim2.new(1, 0, 0, math.round(ICON_H * scale))
				-- re-centred every refresh alongside the size, so the two cannot drift
				local drop = (kind and TOOL_ICON_DROP[kind]) or 0
				slot.art.Position = UDim2.new(0.5, 0, 0, ICON_TOP + ICON_H * 0.5 + drop)
				slot.icon.Text = if isArt then "" else want
				slot.icon.Visible = not isArt
				slot.setOn(tool.Parent == ch)
			end
		end
	end
end

function Shell:_equipSlot(index: number)
	local slot = self.slots[index]
	local tool = slot and slot.tool
	if not tool then return end
	local ch = self.plr.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	-- pressing the key of the tool already in hand puts it away, same as the
	-- default hotbar
	if tool.Parent == ch then hum:UnequipTools() else hum:EquipTool(tool) end
end

--==[ bottom centre: the rig's gauge ]========================================

local MPH_PER_STUD = 0.28 * 2.23694

local DIAL      = 144        -- bezel diameter
local DIAL_FACE = 130        -- the dark face inside it
local PIPS      = 21         -- ticks around the arc, every fifth one long
local SWEEP     = 122        -- degrees either side of straight up
local PIP_R     = 53         -- radius the ticks are struck at
local NEEDLE_LEN, NEEDLE_TAIL = 40, 12   -- reach, and the counterweight behind the hub
local GAUGE_W, GAUGE_H = 232, 172
local PLATE_W, PLATE_H = 168, 52
local FACE_COL = Color3.fromRGB(26, 46, 84)

--[[
	Screen offset of a clockwise angle from straight up.

	Rotation pivots about a GuiObject's own CENTRE, never its AnchorPoint -- so
	pinning a needle's base to the hub and turning it does not swing the needle,
	it spins it on the spot. Everything radial here is POSITIONED on the circle
	and only ORIENTED by Rotation.
]]
local function polar(deg: number, r: number): (number, number)
	local a = math.rad(deg)
	return math.sin(a) * r, -math.cos(a) * r
end

-- Green for most of the dial, gold where you are pressing on, red at the top
-- end. The ticks, the needle and the digits all read off this one function, so
-- the three can never disagree about where the redline is.
local function zoneOf(f: number): Color3
	if f < 0.55 then return LIME elseif f < 0.82 then return GOLD end
	return T.red
end

function Shell:_buildGauge()
	local holder = Instance.new("Frame")
	holder.Name = "Gauge"
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.new(0.5, 0, 1, -14)
	holder.Size = UDim2.fromOffset(GAUGE_W, GAUGE_H)
	holder.Visible = false
	holder.Parent = self.gui
	self.gauge = holder

	local scale = Instance.new("UIScale")
	scale.Parent = holder
	self.gaugeScale = scale
	self.gaugeFit = 1

	onFit(function(f)
		self.gaugeFit = f
		scale.Scale = f
	end)

	--[ the dial ]------------------------------------------------------------

	-- its own wrapper, because the drop shadow has to be a SIBLING of the disc:
	-- a child always draws over its parent whatever its ZIndex
	local wrap = Instance.new("Frame")
	wrap.Name = "Dial"
	wrap.AnchorPoint = Vector2.new(0.5, 0)
	wrap.BackgroundTransparency = 1
	wrap.Position = UDim2.new(0.5, 0, 0, 0)
	wrap.Size = UDim2.fromOffset(DIAL, DIAL)
	wrap.Parent = holder
	UIKit.dropShadow(wrap, math.floor(DIAL / 2), 7, 1)

	-- A corner radius is clamped to half the shortest side, so asking for the
	-- full diameter is how you get a circle out of a square frame.
	local bezel = Instance.new("Frame")
	bezel.Name = "Bezel"
	bezel.BackgroundColor3 = SLOT_IDLE
	bezel.BorderSizePixel = 0
	bezel.Size = UDim2.fromScale(1, 1)
	bezel.ZIndex = 2
	bezel.Parent = wrap
	UIKit.corner(bezel, DIAL)
	UIKit.stroke(bezel, 3)
	UIKit.gradient(bezel)

	-- Dark, and the only dark surface on the HUD. An instrument face has to be
	-- the thing the needle and the lit ticks are read AGAINST; on the kit's usual
	-- bright fill a red needle and a gold arc both disappear.
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.fromOffset(DIAL_FACE, DIAL_FACE)
	face.BackgroundColor3 = FACE_COL
	face.BorderSizePixel = 0
	face.ZIndex = 3
	face.Parent = bezel
	UIKit.corner(face, DIAL_FACE)
	UIKit.stroke(face, 2.2)
	UIKit.vignette(face, DIAL_FACE, 90, 0.4)

	--[ the arc ]-------------------------------------------------------------

	local pips = {}
	for i = 1, PIPS do
		local f = (i - 1) / (PIPS - 1)
		local major = (i - 1) % 5 == 0
		local deg = -SWEEP + f * SWEEP * 2
		local dx, dy = polar(deg, PIP_R)

		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. i
		pip.AnchorPoint = Vector2.new(0.5, 0.5)
		pip.Position = UDim2.new(0.5, dx, 0.5, dy)
		pip.Size = UDim2.fromOffset(if major then 8 else 6, if major then 18 else 12)
		pip.Rotation = deg
		pip.BorderSizePixel = 0
		pip.ZIndex = 4
		pip.Parent = face
		UIKit.corner(pip, 3)
		UIKit.stroke(pip, 1.2)

		local lit = zoneOf(f)
		pips[i] = { frame = pip, at = f, lit = lit, dim = UIKit.deepen(lit, 0.62), on = nil }
		pip.BackgroundColor3 = pips[i].dim
	end
	self.gaugePips = pips

	local brand = UIKit.outlined(face, "SEALPRO", 12, T.blueLight, 1.8)
	brand.Name = "Brand"
	brand.AnchorPoint = Vector2.new(0.5, 0.5)
	brand.Position = UDim2.new(0.5, 0, 0.5, -29)
	brand.Size = UDim2.fromOffset(96, 14)
	brand.TextXAlignment = Enum.TextXAlignment.Center
	brand.TextTransparency = 0.25
	brand.ZIndex = 4

	local glass = Instance.new("Frame")
	glass.Name = "Glass"
	glass.AnchorPoint = Vector2.new(0.5, 0)
	glass.Position = UDim2.new(0.5, 0, 0, 10)
	glass.Size = UDim2.fromOffset(80, 32)
	glass.BackgroundColor3 = Color3.new(1, 1, 1)
	glass.BackgroundTransparency = 0.88
	glass.BorderSizePixel = 0
	glass.ZIndex = 5
	glass.Parent = face
	UIKit.corner(glass, 16)

	--[ the needle ]----------------------------------------------------------
	local needle = Instance.new("Frame")
	needle.Name = "Needle"
	needle.AnchorPoint = Vector2.new(0.5, 0.5)
	needle.Size = UDim2.fromOffset(7, NEEDLE_LEN + NEEDLE_TAIL)
	needle.BackgroundColor3 = T.red
	needle.BorderSizePixel = 0
	needle.ZIndex = 6
	needle.Parent = face
	UIKit.corner(needle, 3)
	UIKit.stroke(needle, 2)
	self.gaugeNeedle = needle

	local hub = Instance.new("Frame")
	hub.Name = "Hub"
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromOffset(26, 26)
	hub.BackgroundColor3 = GOLD
	hub.BorderSizePixel = 0
	hub.ZIndex = 7
	hub.Parent = face
	UIKit.corner(hub, 13)
	UIKit.stroke(hub, 2.2)
	UIKit.gradient(hub, 1.15)
	UIKit.gloss(hub, 4, 6, 0.42).ZIndex = 8

	--[ the readout plate ]---------------------------------------------------
	local plateWrap = Instance.new("Frame")
	plateWrap.Name = "Readout"
	plateWrap.AnchorPoint = Vector2.new(0.5, 1)
	plateWrap.BackgroundTransparency = 1
	plateWrap.Position = UDim2.new(0.5, 0, 1, 0)
	plateWrap.Size = UDim2.fromOffset(PLATE_W, PLATE_H)
	plateWrap.ZIndex = 9
	plateWrap.Parent = holder
	UIKit.dropShadow(plateWrap, 16, 6, 9)

	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.BackgroundColor3 = FACE_COL
	plate.BorderSizePixel = 0
	plate.Size = UDim2.fromScale(1, 1)
	plate.ZIndex = 10
	plate.Parent = plateWrap
	UIKit.corner(plate, 16)
	UIKit.stroke(plate, 2.6)
	UIKit.gloss(plate, 5, 11, 0.34).ZIndex = 11

	local gear = Instance.new("Frame")
	gear.Name = "Gear"
	gear.AnchorPoint = Vector2.new(0, 0.5)
	gear.Position = UDim2.new(0, 8, 0.5, 0)
	gear.Size = UDim2.fromOffset(36, 36)
	gear.BackgroundColor3 = LIME
	gear.BorderSizePixel = 0
	gear.ZIndex = 12
	gear.Parent = plate
	UIKit.corner(gear, 18)
	UIKit.stroke(gear, 2.2)
	UIKit.gradient(gear, 1.15)
	self.gaugeGear = gear

	local gearText = Instance.new("TextLabel")
	gearText.Name = "Letter"
	gearText.BackgroundTransparency = 1
	gearText.Font = UIKit.Display
	gearText.Text = "N"
	gearText.TextSize = 21
	gearText.TextColor3 = T.ink
	gearText.Size = UDim2.fromScale(1, 1)
	gearText.ZIndex = 14
	gearText.Parent = gear
	self.gaugeGearText = gearText

	local num = UIKit.outlined(plate, "0", 34, MINT, 3)
	num.Name = "Reading"
	num.AnchorPoint = Vector2.new(0, 0.5)
	num.Position = UDim2.new(0, 48, 0.5, 1)
	num.Size = UDim2.fromOffset(82, 38)
	num.TextXAlignment = Enum.TextXAlignment.Center
	num.ZIndex = 12
	self.gaugeNum = num

	local unit = UIKit.outlined(plate, "MPH", 14, T.cream, 2)
	unit.Name = "Unit"
	unit.AnchorPoint = Vector2.new(0, 0.5)
	unit.Position = UDim2.new(0, 132, 0.5, 2)
	unit.Size = UDim2.fromOffset(34, 18)
	unit.ZIndex = 12

	local bladeBtn, bladeCap, bladeTint = UIKit.button(holder, "\u{25BC}",
		UDim2.fromOffset(66, 66), GOLD, function()
			if not Passes.owns(self.plr, "TruckBlade") then
				local pass = Passes.ById.TruckBlade
				if pass and pass.assetId ~= 0 then
					MarketplaceService:PromptGamePassPurchase(self.plr, pass.assetId)
				else
					-- assetId 0 is a pass not yet created on the site; see Passes. Saying
					-- so beats a dialog that never opens.
					self:Toast("The Truck Squeegee pass is not on sale yet", false)
				end
				return
			end
			-- The server owns the blade attribute and re-checks the pass before it
			-- moves it; this only asks.
			local remotes = SealPack:FindFirstChild("Remotes")
			local ev = remotes and remotes:FindFirstChild("TruckControl")
			if ev then (ev :: RemoteEvent):FireServer("blade", not self.bladeDown) end
		end)
	bladeBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	bladeBtn.Position = UDim2.new(0.5, DIAL * 0.5 + 46, 0, DIAL * 0.5)
	bladeCap.TextSize = 26

	local bladeWord = UIKit.label(holder, "LOWER", 13, T.cream)
	bladeWord.AnchorPoint = Vector2.new(0.5, 0)
	bladeWord.Position = UDim2.new(0.5, DIAL * 0.5 + 46, 0, DIAL * 0.5 + 38)
	bladeWord.Size = UDim2.fromOffset(92, 16)
	bladeWord.TextXAlignment = Enum.TextXAlignment.Center
	bladeWord.ZIndex = 12

	self.bladeBtn = { cap = bladeCap, word = bladeWord, tint = bladeTint, at = nil }
	self.bladeDown = false

	--[ the spray bar ]--------------------------------------------------------

	local pourBtn, pourCap, pourTint = UIKit.button(holder, "\u{1F4A7}",
		UDim2.fromOffset(66, 66), T.blueLight, function()
			-- Same shape as the blade's handler, and the same reason for every line of
			-- it: see the note over that one.
			if not Passes.owns(self.plr, "TruckPour") then
				local pass = Passes.ById.TruckPour
				if pass and pass.assetId ~= 0 then
					MarketplaceService:PromptGamePassPurchase(self.plr, pass.assetId)
				else
					self:Toast("The Spray Bar pass is not on sale yet", false)
				end
				return
			end
			-- The server owns the valve and re-checks both the pass and the drum before
			-- it opens it; this only asks.
			local remotes = SealPack:FindFirstChild("Remotes")
			local ev = remotes and remotes:FindFirstChild("TruckControl")
			if ev then (ev :: RemoteEvent):FireServer("pour", not self.pouring) end
		end)
	pourBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	pourBtn.Position = UDim2.new(0.5, -(DIAL * 0.5 + 46), 0, DIAL * 0.5)
	pourCap.TextSize = 26

	local pourWord = UIKit.label(holder, "POUR", 13, T.cream)
	pourWord.AnchorPoint = Vector2.new(0.5, 0)
	pourWord.Position = UDim2.new(0.5, -(DIAL * 0.5 + 46), 0, DIAL * 0.5 + 38)
	pourWord.Size = UDim2.fromOffset(92, 16)
	pourWord.TextXAlignment = Enum.TextXAlignment.Center
	pourWord.ZIndex = 12

	self.pourBtn = { cap = pourCap, word = pourWord, tint = pourTint, at = nil }
	self.pouring = false

	--[ the way out ]---------------------------------------------------------
	local exitBtn, exitCap = UIKit.button(holder, "EXIT",
		UDim2.fromOffset(128, 44), T.red, function()
			local ch = self.plr.Character
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			if not hum then return end
			hum:SetAttribute("LeavingSeat", true)
			hum.Sit = false
			task.delay(2.5, function()
				if hum.Parent then hum:SetAttribute("LeavingSeat", nil) end
			end)
		end)
	exitBtn.AnchorPoint = Vector2.new(0.5, 1)
	-- Over the dial rather than beside it: both flanks are spoken for by the pass
	-- controls, and the holder's lower half is the readout plate. Clear of the top
	-- of the holder, so the UIScale that fits the instrument to a narrow window
	-- carries it in with everything else.
	exitBtn.Position = UDim2.new(0.5, 0, 0, -12)
	exitCap.TextSize = 22
	self.consoleExit = exitCap

	self.gaugeShown, self.gaugeVel, self.gaugeMax = 0, 0, 40
	self.gaugeZone, self.gaugeGearAt = nil, nil
end

--==[ in the cab ]============================================================

function Shell:_setDriving(seat: VehicleSeat?)
	self.seat = seat
	if self.hotbar then self.hotbar.Visible = seat == nil end
	if not self.gauge then return end

	if seat then

		pcall(function() seat.HeadsUpDisplay = false end)

		-- The dial is scaled to the truck you are in: a Longline's 84 studs/s would
		-- peg a dial drawn for the stock rig and never come off the stop. It is the
		-- rig's own TopSpeed attribute, which is the same number RigController
		-- drives the motors from.
		local model = seat:FindFirstAncestorOfClass("Model")
		local top = (model and model:GetAttribute("TopSpeed") :: number?) or 52
		self.gaugeMax = math.max(20, math.ceil(top * MPH_PER_STUD / 10) * 10)
		self.gaugeShown, self.gaugeVel = 0, 0

		self.gauge.Visible = true
		local base = self.gaugeFit or 1
		self.gaugeScale.Scale = base * 0.7
		TweenService:Create(self.gaugeScale, TweenInfo.new(0.24, Enum.EasingStyle.Back,
			Enum.EasingDirection.Out), { Scale = base }):Play()
	else
		self.gauge.Visible = false
	end
end

function Shell:_watchDriving()
	local function look(hum: Humanoid)
		local part = hum.SeatPart
		self:_setDriving(if part and part:IsA("VehicleSeat") then part else nil)
	end
	local function watch(character: Model)
		local hum = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if not hum then return end
		hum:GetPropertyChangedSignal("SeatPart"):Connect(function() look(hum) end)
		look(hum)
	end
	self.plr.CharacterAdded:Connect(watch)
	-- dying at the wheel never fires SeatPart, it just takes the humanoid away
	self.plr.CharacterRemoving:Connect(function() self:_setDriving(nil) end)
	if self.plr.Character then task.spawn(watch, self.plr.Character) end
end

function Shell:_updateGauge(dt: number)
	local holder = self.gauge
	if not holder or not holder.Visible then return end

	--[ the front blade toggle ]-----------------------------------------------

	local btn = self.bladeBtn
	if btn then
		local model = if self.seat then self.seat:FindFirstAncestorOfClass("Model") else nil
		local down = model ~= nil and model:GetAttribute("BladeDown") == true
		local locked = not Passes.owns(self.plr, "TruckBlade")
		self.bladeDown = down
		local glyph = if locked then "\u{1F512}" elseif down then "\u{25B2}" else "\u{25BC}"
		if btn.cap.Text ~= glyph then btn.cap.Text = glyph end
		local word = if locked then "PASS" elseif down then "RAISE" else "LOWER"
		if btn.word.Text ~= word then btn.word.Text = word end
		local col = if locked then SLOT_IDLE elseif down then LIME else GOLD
		if btn.at ~= col then
			btn.at = col
			btn.tint(col)
		end
	end

	--[ the spray bar valve ]-------------------------------------------------

	local pbtn = self.pourBtn
	if pbtn then
		local model = if self.seat then self.seat:FindFirstAncestorOfClass("Model") else nil
		local on = model ~= nil and model:GetAttribute("Pouring") == true
		-- Against the model's own ceiling rather than a constant: Bucket Capacity
		-- scales the drum, so a fixed "nearly empty" figure would mean a different
		-- thing on every rig and on every rung of that track.
		local tank = (model and model:GetAttribute("Tank") :: number?) or 0
		local cap = (model and model:GetAttribute("TankCapacity") :: number?) or 0
		local dry = tank <= 0
		local locked = not Passes.owns(self.plr, "TruckPour")
		self.pouring = on

		local glyph = if locked then "\u{1F512}"
			elseif dry then "\u{1F6AB}" elseif on then "\u{25A0}" else "\u{1F4A7}"
		if pbtn.cap.Text ~= glyph then pbtn.cap.Text = glyph end
		local word = if locked then "PASS"
			elseif dry then "EMPTY" elseif on then "STOP" else "POUR"
		if pbtn.word.Text ~= word then pbtn.word.Text = word end
		local low = cap > 0 and tank < cap * 0.1
		local col = if locked then SLOT_IDLE
			elseif dry then SLOT_IDLE
			elseif on then (if low then GOLD else LIME)
			else T.blueLight
		if pbtn.at ~= col then
			pbtn.at = col
			pbtn.tint(col)
		end
	end

	local seat = self.seat
	-- storing the rig destroys the seat out from under a seated driver, and no
	-- property signal fires for that
	if not seat or not seat.Parent then self:_setDriving(nil) return end

	local vel = seat.AssemblyLinearVelocity
	local target = vel.Magnitude * MPH_PER_STUD

	dt = math.min(dt, 1 / 20)
	self.gaugeVel += ((target - self.gaugeShown) * 260 - self.gaugeVel * 23) * dt
	self.gaugeShown += self.gaugeVel * dt
	local shown = math.max(self.gaugeShown, 0)

	local frac = math.clamp(shown / self.gaugeMax, 0, 1)
	local deg = -SWEEP + frac * SWEEP * 2
	-- the needle's own centre sits forward of the hub by half its overhang, which
	-- is what puts the pivot at the hub once it is turned
	local dx, dy = polar(deg, (NEEDLE_LEN - NEEDLE_TAIL) * 0.5)
	self.gaugeNeedle.Position = UDim2.new(0.5, dx, 0.5, dy)
	self.gaugeNeedle.Rotation = deg

	-- guarded per tick: 21 comparisons a frame, versus 21 property writes
	for _, pip in ipairs(self.gaugePips) do
		local on = pip.at <= frac + 1e-4
		if pip.on ~= on then
			pip.on = on
			pip.frame.BackgroundColor3 = if on then pip.lit else pip.dim
		end
	end

	local reading = tostring(math.floor(shown + 0.5))
	if self.gaugeNum.Text ~= reading then self.gaugeNum.Text = reading end
	local zone = zoneOf(frac)
	if self.gaugeZone ~= zone then
		self.gaugeZone = zone
		self.gaugeNum.TextColor3 = if frac < 0.55 then MINT else zone
	end

	-- R means rolling backwards, not holding reverse; N is a standstill
	local along = vel:Dot(seat.CFrame.LookVector)
	local gear = if shown < 0.6 then "N" elseif along < -0.5 then "R" else "D"
	if self.gaugeGearAt ~= gear then
		self.gaugeGearAt = gear
		self.gaugeGearText.Text = gear
		UIKit.retint(self.gaugeGear,
			if gear == "D" then LIME elseif gear == "R" then T.red else T.slate, 1.15)
	end
end

--==[ the skins key, which wears its own stock ]==============================

function Shell:_dressSkinsKey(holder: GuiObject)
	local face = holder:FindFirstChildOfClass("TextButton")
	local glyph = face and face:FindFirstChild("Glyph") :: TextLabel?
	if not (face and glyph) then return end

	local ids: { string } = {}
	for _, sk in ipairs(Skins.List) do ids[#ids + 1] = (sk :: any).id end
	if #ids == 0 then return end

	local ok, rig = pcall(function()
		local tool = ToolBuilder.buildSqueegee()
		local r = tool:FindFirstChild("Rig")
		-- out of the tool BEFORE the tool goes, or the rig is destroyed with it
		if r and r:IsA("Model") then r.Parent = nil end
		tool:Destroy()
		return r
	end)

	if not (ok and rig and rig:IsA("Model")) then return end

	local model = rig :: Model
	local CASE_GROW = 1.3
	local gp, gs = glyph.Position, glyph.Size
	local vp = Instance.new("ViewportFrame")
	vp.Name = "Case"
	vp.BackgroundTransparency = 1
	vp.AnchorPoint = Vector2.new(0.5, 0.5)
	vp.Position = UDim2.new(
		gp.X.Scale + gs.X.Scale * 0.5, gp.X.Offset + gs.X.Offset * 0.5,
		gp.Y.Scale + gs.Y.Scale * 0.5, gp.Y.Offset + gs.Y.Offset * 0.5)
	vp.Size = UDim2.new(gs.X.Scale * CASE_GROW, gs.X.Offset * CASE_GROW,
		gs.Y.Scale * CASE_GROW, gs.Y.Offset * CASE_GROW)
	vp.ZIndex = glyph.ZIndex
	vp.Ambient = Color3.fromRGB(180, 188, 202)
	vp.LightColor = Color3.fromRGB(255, 250, 240)
	vp.LightDirection = Vector3.new(-0.45, -1, -0.55)
	vp.Parent = face

	-- a WorldModel, or the viewport ignores LightDirection and everything renders
	-- flat -- SkinCase's own note, and it applies identically here
	local world = Instance.new("WorldModel")
	world.Parent = vp

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Light") or d:IsA("ParticleEmitter") or d:IsA("Sound") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CastShadow = false
		end
	end
	model.Parent = world

	model.PrimaryPart = nil
	local cf, sz = model:GetBoundingBox()
	model.WorldPivot = CFrame.new(cf.Position)
	model:PivotTo(CFrame.new())

	local FOV = 30
	local reach = math.max(sz.X, sz.Y, sz.Z)
	-- 1.0 is the exact fit; anything above it is margin, and margin at this size is
	-- what made the squeegee look small inside its own key
	local dist = (reach * 0.5) / math.tan(math.rad(FOV * 0.5)) * 1.0
	local cam = Instance.new("Camera")
	cam.FieldOfView = FOV
	cam.CFrame = CFrame.lookAt(Vector3.new(0, dist * 0.10, dist), Vector3.zero)
	cam.Parent = vp
	vp.CurrentCamera = cam

	glyph.Visible = false
	self.skinsKey = vp

	local at = 0
	local worn = self.plr:GetAttribute(Skins.Attr)
	if type(worn) == "string" then
		for i, id in ipairs(ids) do if id == worn then at = i - 1 break end end
	end
	task.spawn(function()
		while vp.Parent do
			at = at % #ids + 1
			pcall(function() Skins.apply(model, ids[at]) end)
			task.wait(1.5)
		end
	end)
end

--==[ right edge: icon rail ]=================================================

function Shell:_buildRail()
	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.AnchorPoint = Vector2.new(1, 0.5)
	rail.BackgroundTransparency = 1
	rail.Position = UDim2.new(1, -22, 0.5, 0)
	rail.Parent = self.gui

	local truckSpacer = Instance.new("Frame")
	truckSpacer.Name="TruckLeftSpacer";truckSpacer.BackgroundTransparency=1;truckSpacer.LayoutOrder=4;truckSpacer.Visible=false;truckSpacer.Parent=rail
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(RAIL_BOX, RAIL_BOX)
	layout.CellPadding = UDim2.fromOffset(RAIL_GAP, RAIL_GAP)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = rail

	type RailKey = {
		id: string,
		title: string,
		glyph: string,
		tint: Color3,
		nub: boolean,
		action: string?,
	}

	local entries: { RailKey } = {
		{ id = "Rebirth",    title = "Rebirth",    glyph = "\u{1F501}", tint = T.teal,   nub = false },		
		{ id = "Board",      title = "Rewards",    glyph = "\u{2B50}",  tint = T.gold,   nub = false },		
		{ id = "Skins",      title = "Skins",      glyph = "\u{1F9F9}", tint = T.blue,   nub = false },		
		-- Dealership rail key removed: the Trucks icon no longer shows in the bar.
		{ id = "Colors", title = "Colors", glyph = "", tint = T.purple, nub = false },
		{ id = "Settings",   title = "Settings",   glyph = "\u{2699}\u{FE0F}", tint = T.purple, nub = false },
		{ id = "Shop",       title = "Shop",       glyph = "\u{1F6D2}", tint = T.green,  nub = true },
	}

	local function span(cols: number): (number, number, number)
		local visibleCount = 0
		for _, entry in ipairs(entries) do
			local button = self.railBtns and self.railBtns[entry.id]
			if not button or button.Visible then visibleCount += 1 end
		end
		if cols>1 and UserInputService.TouchEnabled and self.railBtns and self.railBtns.Dealership and self.railBtns.Dealership.Visible then visibleCount+=1 end
		local rows = math.max(1, math.ceil(visibleCount / cols))
		return cols * RAIL_BOX + (cols - 1) * RAIL_GAP,
			rows * RAIL_BOX + (rows - 1) * RAIL_GAP,
			rows
	end

	local railScale = Instance.new("UIScale")
	railScale.Parent = rail

	local lastView = Vector2.new(1280, 720)
	local function seatRail(v: Vector2?)
		if v then lastView = v end
		local side = math.max(0, math.floor((lastView.X - self.gui.AbsoluteSize.X) * 0.5))
		local margin = math.round(RAIL_EDGE * railScale.Scale)
		rail.Position = UDim2.new(1, -(math.max(RAIL_EDGE_MIN, margin) - side), 0.5, 0)
	end

	local railFit, railView
	local function fitRail(f, v)
		railFit, railView = f, v
		local budget = usableY(v) * RAIL_BUDGET
		local _, oneTall = span(1)
		local cols = if budget / oneTall >= f * RAIL_SQUEEZE then 1 else 2
		truckSpacer.Visible=cols>1 and UserInputService.TouchEnabled and self.railBtns~=nil and self.railBtns.Dealership~=nil and self.railBtns.Dealership.Visible
		local w, h, rows = span(cols)
		-- only a wrapped rail may stand bigger than the rest of the HUD, and only
		-- because it has just given up a column of width to earn it
		local grow = if cols > 1 then RAIL_GROW else 1
		layout.FillDirectionMaxCells = rows
		rail.Size = UDim2.fromOffset(w, h)
		railScale.Scale = math.clamp(budget / h, f * RAIL_SQUEEZE, math.min(1, f * grow))
		seatRail(v)
	end
	onFit(fitRail)

	self.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		seatRail(nil)
	end)

	-- one size across the whole rail; see the note on UIKit.fitText
	local titles = {}
	for i, e in ipairs(entries) do titles[i] = e.title end
	local titleSize = UIKit.fitText(titles, RAIL_BOX - 12, 14, 8)

	local function openBoard()
		local plr = self.plr
		local bookShut = self.railLock["Daily"] ~= nil
		if not bookShut and Daily.statusOf(plr).ready then
			self:toggle("Daily")
		elseif Quests.claimableCount(plr) > 0 or bookShut then
			self:toggle("Rewards")
		else
			self:toggle("Daily")
		end
	end

	local RAIL_ART: { [string]: string } = {
		Rebirth  = "rbxassetid://115318209895502",
		Board    = "rbxassetid://78952219366736",   -- the Rewards key
		Settings = "rbxassetid://131768831887022",
		Shop     = "rbxassetid://80513192214844",
	}

	-- Hides the glyph rather than destroying it: a moderated asset draws nothing,
	-- and one line restores a key that at least says what it is.
	local function wearArt(face: GuiObject, image: string)
		local glyph = face:FindFirstChild("Glyph") :: TextLabel?
		if not glyph then return end
		local art = Instance.new("ImageLabel")
		art.Name = "Art"
		art.BackgroundTransparency = 1
		art.Image = image
		art.ScaleType = Enum.ScaleType.Fit
		art.Position = glyph.Position
		art.Size = glyph.Size
		art.ZIndex = glyph.ZIndex
		art.Parent = face
		glyph.Visible = false
	end

	self.nubs = {}
	self.railBtns = {}
	-- see _dressSkinsKey; declared here so the rail loop below can reach it
	self.skinsKey = nil :: GuiObject?
	local function buildKey(i: number, e: RailKey)
		local holder, alert = UIKit.squareIcon(rail, e.glyph, RAIL_BOX, e.tint, function()
			-- A locked button says where to go instead of opening. Only the rail is
			-- locked, never the panel: whatever holds the lock still has a way in.
			local locked = self.railLock[e.id]
			if locked then
				self:Toast(locked, false)
			elseif e.id == "Board" then
				-- the one key with two panels behind it; it picks which
				openBoard()
			elseif e.action then
				-- fire reports whether anything was listening. AfkClient registers on
				-- join, so a miss here is the startup race rather than a missing
				-- feature, and saying "not yet" beats a button that silently does
				-- nothing -- the same rule Quick Refill follows above.
				if not HudActions.fire(e.action) then
					self:Toast("Not ready yet, try again in a moment", false)
				end
			elseif self.panels[e.id] then
				self:toggle(e.id)
			else
				self:Toast(e.id .. " is coming soon", true)
			end
		end, e.title, titleSize)

		-- The one key that shows its own contents rather than a glyph.
		if e.id == "Skins" then task.spawn(function() self:_dressSkinsKey(holder) end) end

		-- Drawn artwork where there is any; see RAIL_ART. The Shop block below adds
		-- its own flourishes on top of whatever it is wearing.
		if e.id == "Colors" then
			local icon = Instance.new("ImageLabel")
			icon.Name = "ColorsIcon"
			icon.Image = require(SealPack:WaitForChild("ColorCatalog")).Icon
			icon.BackgroundTransparency = 1
			icon.Size = UDim2.fromScale(0.6, 0.6)
			icon.Position = UDim2.fromScale(0.2, 0.08)
			icon.ZIndex = 20
			icon.Parent = holder
		end
		local artFor = RAIL_ART[e.id]
		if artFor then
			local f = holder:FindFirstChildOfClass("TextButton")
			if f then wearArt(f, artFor) end
		end

		if e.id == "Shop" then
			-- Turned up on request (2026-08-15). 7% on a shorter cycle is a key that is
			-- plainly pulsing rather than merely breathing; past about 9% the caption
			-- under it starts to visibly swim, which reads as broken rather than lively.
			UIKit.bob(holder, 0.07, 1.5)
			local face = holder:FindFirstChildOfClass("TextButton")
			if face then
				UIKit.sunburst(face, 10, RAIL_BOX * 1.12, Color3.fromRGB(228, 255, 206), 4)
				UIKit.sheen(face, 1.9, 6)
				UIKit.sheen(face, 2.9, 6)

				local SHAKE = 8
				local OUT, BACK, REST = 0.11, 0.2, 1
				-- left-right pairs per burst
				local WOBBLES = 2
				local cart = face:FindFirstChild("Art")
				if cart and cart:IsA("ImageLabel") then
					local label = cart :: ImageLabel
					local function turn(to: number, secs: number)
						TweenService:Create(label, TweenInfo.new(secs, Enum.EasingStyle.Sine,
							Enum.EasingDirection.InOut), { Rotation = to }):Play()
						task.wait(secs)
					end
					task.spawn(function()
						-- stops with the shell rather than outliving it
						while label.Parent do
							for i = 1, WOBBLES do
								-- only the FIRST leg is a flick from standstill; the rest are
								-- already in motion, so they take the full crossing time
								turn(-SHAKE, if i == 1 then OUT else BACK)
								turn(SHAKE, BACK)
							end
							turn(0, OUT)
							task.wait(REST)
						end
					end)
				end
			end
		end
		holder.LayoutOrder = if e.id == "Dealership" and UserInputService.TouchEnabled then 100 elseif e.id == "Colors" and UserInputService.TouchEnabled then 99 else i
		alert.Visible = e.nub
		self.nubs[e.id] = alert
		self.railBtns[e.id] = holder
		-- shown by the dealership's zone poll and by nothing else. UIListLayout
		-- skips invisible children, so the rail simply closes up when it is away.
		if e.id == "Dealership" then holder.Visible = false end
	end

	for i, e in ipairs(entries) do
		local had: { [Instance]: boolean } = {}
		for _, c in ipairs(rail:GetChildren()) do had[c] = true end
		local ok, err = pcall(buildKey, i, e)
		if not ok then
			for _, c in ipairs(rail:GetChildren()) do
				if not had[c] then c:Destroy() end
			end
			warn(("[Shell] rail key %q did not build: %s"):format(tostring(e.id), tostring(err)))
		end
	end -- ColorsMobileLayoutFix
	local function refreshRail()
		if railFit and railView then fitRail(railFit, railView) end
	end
	for _, button in pairs(self.railBtns) do
		button:GetPropertyChangedSignal("Visible"):Connect(refreshRail)
	end
	refreshRail()

end

--==[ bottom left: stats ]====================================================

function Shell:_buildStats()
	local block = Instance.new("Frame")
	block.Name = "Stats"
	block.AnchorPoint = Vector2.new(0, 1)
	block.BackgroundTransparency = 1
	block.Position = UDim2.new(0, STAT_X, 1, -STAT_Y)
	block.Size = UDim2.fromOffset(STAT_W, STAT_H)
	block.Parent = self.gui
	fitBlock(block, function(f, v)

		local lift = 0
		block.Position = UDim2.new(0, math.round(STAT_X * f),
			1, -math.round(STAT_Y * f + lift))
	end)

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = block

	local function row(order: number, glyph: string, colour: Color3): (TextLabel, Frame)
		local holder = Instance.new("Frame")
		holder.Name = "Stat"
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(STAT_W, 42)
		holder.LayoutOrder = order
		holder.Parent = block

		local badge = Instance.new("Frame")
		badge.Name = "Chip"
		badge.AnchorPoint = Vector2.new(0, 0.5)
		badge.Position = UDim2.new(0, 0, 0.5, 0)
		badge.Size = UDim2.fromOffset(34, 34)
		badge.BackgroundColor3 = colour
		badge.BorderSizePixel = 0
		badge.ZIndex = 3
		badge.Parent = holder
		UIKit.corner(badge, 11)
		UIKit.stroke(badge, 2.2)
		UIKit.gradient(badge, 1.2)
		UIKit.gloss(badge, 3, 7, 0.44).ZIndex = 3

		-- Raw label, not UIKit.label: that one hangs an ink stroke on the glyphs,
		-- and a contextual outline round a 20px colour emoji is a black rim that
		-- eats most of the picture.
		local g = Instance.new("TextLabel")
		g.BackgroundTransparency = 1
		g.Font = Enum.Font.GothamBold
		g.Text = glyph
		g.TextSize = 20
		g.TextColor3 = T.navy
		g.Size = UDim2.fromScale(1, 1)
		g.ZIndex = 5
		g.Parent = badge

		local l = UIKit.outlined(holder, "", 32, colour)
		l.Position = UDim2.fromOffset(44, 0)
		l.Size = UDim2.new(1, -44, 1, 0)
		l.ZIndex = 3
		return l, holder
	end
	-- The rig line only appears when a truck is actually present. It carries the
	-- readout the old HUD had in this same corner, so disabling that one loses
	-- nothing.
	-- the counter the money flies to; it gets a scale of its own so the arrival
	-- kick cannot fight the list layout the row sits in
	self.rigLabel, self.rigRow = row(1, "\u{1F69B}", SKY)
	-- Slot 2, which the note below says has been free twice over. The hose length
	-- lives here rather than sharing the truck's line: together they overflow the
	-- column, and they are two different readings anyway.
	self.hoseLabel, self.hoseRow = row(2, "\u{1F6BF}", SKY)
	self.boostLabel, self.boostRow = row(0, "\u{1F308}", T.white)
	self.boostRow.Visible = false
	-- and the chip wears the same rainbow the shop card does, which is the whole of
	-- what ties the two together on sight
	local boostChip = self.boostRow:FindFirstChild("Chip")
	if boostChip then UIKit.rainbow(boostChip :: Frame, 5) end

	self.sealerLabel = row(3, "\u{1F6E2}", GOLD)
	self.jobsLabel   = row(4, "\u{2705}", ORANGE)
	local cashLabel, cashRow = row(5, "\u{1F4B5}", LIME)
	self.cashLabel, self.cashRow = cashLabel, cashRow
	self.cashScale = Instance.new("UIScale")
	self.cashScale.Parent = cashRow
	-- the whole row hides, not just its text, or the layout keeps its gap
	self.rigRow.Visible = false
	self.hoseRow.Visible = false

	if not SHOW_HINT then return end

	self.hintLabel = UIKit.outlined(self.gui, "", 22, Color3.fromRGB(226, 240, 255), 2.6)
	self.hintLabel.AnchorPoint = Vector2.new(0.5, 1)
	self.hintLabel.Size = UDim2.fromOffset(900, 30)
	self.hintLabel.TextXAlignment = Enum.TextXAlignment.Center

	local function liftHint()
		self.hintLabel.Position =
			UDim2.new(0.5, 0, 1, -(STAT_Y + layout.AbsoluteContentSize.Y + 12))
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(liftHint)
	liftHint()
end

--==[ centre screen: the fill readout ]=======================================

function Shell:_buildFill()
	local block = Instance.new("Frame")
	block.Name = "Filling"
	block.BackgroundTransparency = 1
	block.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Below the middle rather than on it: dead centre is where the nozzle they
	-- are holding is drawn, and this would cover the thing it is reporting on.
	block.Position = UDim2.new(0.5, 0, 0.66, 0)
	block.Size = UDim2.fromOffset(340, 116)
	block.Visible = false
	block.Parent = self.gui
	self.fillBlock = block
	-- The offer hangs below the block rather than inside it (see below), so the
	-- scale has to be on the block: hung off the gui it would be the one part of
	-- this readout still drawn at desktop size.
	fitBlock(block)

	self.fillCap = UIKit.outlined(block, "FILLING", 26, MINT)
	self.fillCap.Size = UDim2.fromOffset(340, 32)
	self.fillCap.TextXAlignment = Enum.TextXAlignment.Center

	local function bar(y: number, tint: Color3)
		local root, fill, label = UIKit.progressPill(block, 340)
		root.Position = UDim2.fromOffset(0, y)
		fill.BackgroundColor3 = tint
		return root, fill, label
	end

	self.pailBar, self.pailFill, self.pailText = bar(40, GOLD)
	self.drumBar, self.drumFill, self.drumText = bar(82, SKY)

	local offer = Instance.new("Frame")
	offer.Name = "Offer"
	offer.BackgroundTransparency = 1
	offer.Position = UDim2.fromOffset(0, 128)
	offer.Size = UDim2.fromOffset(340, 50)
	offer.Visible = false
	offer.Parent = block
	self.fillOffer = offer

	local _, cap = UIKit.button(offer, "", UDim2.fromOffset(340, 50), GOLD, function()

		if FILL_PASS and FILL_PASS.assetId ~= 0 then
			MarketplaceService:PromptGamePassPurchase(self.plr, FILL_PASS.assetId)
		end
	end)

	local function label()
		-- the pass's own name, never a second copy of it typed here: the button and
		-- Roblox's dialog have to agree about what is being bought
		local nm = if FILL_PASS then FILL_PASS.name else "Instant Refill"
		cap.Text = if passPrice
			then ("\u{26A1} %s  --  %d R$"):format(nm, passPrice)
			else ("\u{26A1} %s  --  skip the wait"):format(nm)
	end
	label()
	table.insert(passRows, label)
end

function Shell:_updateFill(fill)
	if not self.fillBlock then return end
	if not fill then
		self.fillBlock.Visible = false
		return
	end
	self.fillBlock.Visible = true
	self.fillCap.Text = fill.caption or "FILLING"

	local function set(frac: number, name: string, meter: Frame, label: TextLabel)
		local f = math.clamp(frac, 0, 1)
		meter.Size = UDim2.fromScale(f, 1)
		label.Text = if f >= 0.999
			then name .. "  FULL"
			else ("%s  %d%%"):format(name, math.floor(f * 100 + 0.5))
	end

	set(fill.pail, "PAIL", self.pailFill, self.pailText)
	self.drumBar.Visible = fill.drum ~= nil
	if fill.drum then
		set(fill.drum, "DRUM", self.drumFill, self.drumText)
	end

	if self.fillOffer then
		self.fillOffer.Visible = passOnSale ~= false
			and not Passes.owns(self.plr, "InstantFill")
	end
end

--==[ live update ]===========================================================

--==[ getting paid ]=========================================================

function Shell:_buildTally()
	local holder = Instance.new("Frame")
	holder.Name = "CashTally"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	-- Where it lands when the strip is otherwise empty, which for the tally is the
	-- ordinary case. SealerUI.TopBand owns the strip and stacks it -- the tally is
	-- second from the bottom, above only the toast lane, because it is on screen
	-- for the length of one combo and everything above it stands for minutes.
	holder.Position = UDim2.new(0.5, 0, 0, 12)
	holder.Size = UDim2.fromOffset(300, 46)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = self.gui
	-- 46 x the fit: the UIScale below carries the window fit for this block.
	TopBand.claim("Tally", TopBand.Rank.Tally, holder, function(f) return 46 * f end)

	local label = UIKit.outlined(holder, "", 38, GOLD)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Size = UDim2.fromScale(1, 1)

	-- Its own scale, so the kick on each instalment cannot fight anything else --
	-- which is also why the window fit is folded INTO it rather than added beside
	-- it: one UIScale per instance is all that is honoured. `tallyBase` is the size
	-- the kick springs back to, and it is the fit.
	local scale = Instance.new("UIScale")
	scale.Parent = holder
	self.tallyBase = 1
	onFit(function(f)
		self.tallyBase = f
		scale.Scale = f
	end)

	self.tallyRow, self.tallyLabel, self.tallyScale = holder, label, scale
	self.tally = 0
end

-- Bank an instalment and show it. Kicked rather than tweened up from zero: the
-- instalments arrive twice a second and a running tween would never finish one.
function Shell:_addTally(amount: number)
	self.tally += amount
	self.tallyLabel.Text = ("+$%s"):format(comma(self.tally))
	self.tallyRow.Visible = true
	local base = self.tallyBase or 1
	self.tallyScale.Scale = base * 1.12
	TweenService:Create(self.tallyScale,
		TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = base }):Play()
end

-- Combo over: spend what was banked, once, as a single note and a single chime.
function Shell:_flushTally()
	local owed = self.tally
	self.tally = 0
	self.tallyRow.Visible = false
	if owed > 0 then self.cashFx:Burst(owed, nil, true) end
end

function Shell:_watchCash()
	local plr = self.plr
	self.cashFx = CashFx.new(self.gui, self.cashRow, function()
		-- one kick per note landing, restarted rather than queued so a shower
		-- reads as one sustained bounce
		self.cashScale.Scale = 1.16
		TweenService:Create(self.cashScale,
			TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }):Play()
	end)

	local last: number? = nil
	local function bind()
		local ls = plr:FindFirstChild("leaderstats")
		local cash = ls and ls:FindFirstChild("Cash")
		if not (cash and cash:IsA("IntValue")) then return false end

		last = cash.Value
		task.defer(function()
			self:_refreshUpgradeAlerts()
		end)
		cash:GetPropertyChangedSignal("Value"):Connect(function()
			local now = cash.Value
			local was = last or now
			last = now
			self:_refreshUpgradeAlerts()

			if not plr:GetAttribute("ProfileLoaded") then return end

			if now > was and ((plr:GetAttribute("HelperQuietCashUntil") :: number?) or 0) <= workspace:GetServerTimeNow() then
				-- Mid-pass: bank it and let the number at the top climb. Anything
				-- else -- the completion bonus, the yard, a purchase refund -- is a
				-- single event and still lands straight away.
				if self.tallyOpen then
					self:_addTally(now - was)
				else
					self.cashFx:Burst(now - was)
				end
			end
		end)
		return true
	end

	if not bind() then
		task.spawn(function()
			local t0 = os.clock()
			while os.clock() - t0 < 30 and not bind() do task.wait(0.25) end
		end)
	end
end

function Shell:_startUpdate()
	local plr = self.plr
	local function stat(name: string): number
		local ls = plr:FindFirstChild("leaderstats")
		local v = ls and ls:FindFirstChild(name)
		return v and (v :: IntValue).Value or 0
	end

	RunService.RenderStepped:Connect(function(dt: number)
		-- the needle has its own physics, so it wants the frame time rather than
		-- the wall clock; everything below this line is a straight readout
		self:_updateGauge(dt)

		local s = HudBus.latest

		-- area header
		-- job names read "108 Maple Drive - Driveway"; the suffix is what the
		-- progress line already says, and the full string runs into the switcher

		local afk = HudBus.afk


		local chaining = s.stroking == true or (s.combo or 1) > 1
		local banking = chaining and afk == nil
		if banking ~= self.tallyOpen then
			self.tallyOpen = banking
			if not banking then self:_flushTally() end
		end

		local full = if afk then "The Yard" else (s.name or "Empty")
		local name = full:match("^(.-)%s*%-%s*") or full
		-- one label now: see the note on UIKit.bigTitle for why the pale layer went
		if name == "Empty" then
			self.titleLabel.Text = ""
			self.titleLabel.Visible = false
		elseif self.titleLabel.Text ~= name then
			self.titleLabel.Text = name
			self.titleLabel.Visible = true
		end
		local cov = math.clamp((if afk then afk.coverage else s.coverage) or 0, 0, 1)
		self.progBlockPill.Visible = name ~= "Empty"
		self.progFill.Size = UDim2.fromScale(cov, 1)
		self.progText.Text = ("%d%% SEALED"):format(math.floor(cov * 100 + 0.5))
		-- Once a rebirth has been taken the reward figure is a multiple of the base
		-- one, and the multiple is the whole reason the player sold it -- so it is
		-- said on the line it applies to rather than only on the rebirth screen.
		local mult = Rebirth.multiplierOf(plr)
		-- In the yard the line says what the yard is paying, because there is no job
		-- and "Job Reward: --" under a working crew reads as broken.
		self.rewardLabel.Visible = name ~= "Empty"
		self.rewardLabel.Text = if afk
			then ("Earning: $%s / min"):format(comma(afk.perMinute))
			else s.value and s.value > 0
			and ("Job Reward: $%s%s"):format(comma(s.value),
				if mult > 1 then ("  \u{00D7}%.2f"):format(mult) else "")
			or "Job Reward: --"


		if s.bucket then self.lastBucket = s.bucket end
		local litres = plr:GetAttribute("Eff_TankLitres") or Upgrades.valueAt("Tank", 1)
		self.sealerLabel.Text = ("Sealer: %d / %dL"):format(
			math.floor(self.lastBucket * litres + 0.5), litres)
		self.jobsLabel.Text = ("Jobs Done: %d"):format(stat("Sealed"))
		self.cashLabel.Text = ("Cash: $%s"):format(Upgrades.short(stat("Cash")))


		if self.boostRow then
			local live: Boosts.Boost? = nil
			local left = 0
			for _, b in ipairs(Boosts.List) do
				local s = Boosts.secondsLeft(plr, b.id)
				if s > 0 then live, left = b, s break end
			end
			local running = live ~= nil
			if self.boostRow.Visible ~= running then self.boostRow.Visible = running end
			if live then
				local want = ("%s: %s"):format(live.short, Boosts.clock(left))
				if self.boostLabel.Text ~= want then self.boostLabel.Text = want end
			end
		end

		if self.refillChipLabel then
			local want = if Passes.owns(plr, "InstantFill") or passOnSale == false
				then "Quick Refill"
				else "\u{26A1} Quick Refill"
			if self.refillChipLabel.Text ~= want then self.refillChipLabel.Text = want end
		end

		local rig = s.rig
		local show = rig ~= nil
			and ((rig.distance or math.huge) <= RIG_NEAR or rig.deployed == true)
		self.rigRow.Visible = show

		local showHose = show and rig ~= nil and rig.deployed == true
		if self.hoseRow then self.hoseRow.Visible = showHose end
		if show and rig then			
			self.rigLabel.Text = ("Truck Tank: %d%%")
				:format(math.floor((rig.tankFrac or 0) * 100 + 0.5))
			if self.hoseLabel and showHose then
				self.hoseLabel.Text = ("Hose Length: %d/%d")
					:format(math.floor(rig.hoseOut or 0), math.floor(rig.hoseMax or 0))
			end
		end

		local farNow = rig ~= nil and rig.wandFar == true
		if farNow and not self.wandWasFar then
			self:Toast("Too far from the truck -- the hose will not reach", false)
		end
		self.wandWasFar = farNow

		-- absent entirely when SHOW_HINT is off, not merely blank
		if self.hintLabel then self.hintLabel.Text = s.hint or "" end
		-- nil whenever the nozzle is shut, which is what takes the panel off screen
		self:_updateFill(s.fill)

		-- Whether you are standing in the showroom decides what the buy buttons
		-- say, so they are refreshed while the panel is up rather than only when it
		-- opens. Three comparisons, and only while it is open.
		if self.open == "Dealership" and self.dealerRows then
			for _, fn in ipairs(self.dealerRows) do fn() end
		end
		-- The bay picker reads which rig is OUT, and a truck being stored fires no
		-- attribute on this player -- so unlike the ownership rows it cannot be
		-- driven by a signal. Four rows while the panel is open, and only then.
		if self.open == "RigBay" and self.rigBayRows then
			for _, fn in ipairs(self.rigBayRows) do fn() end
		end
		-- the rebirth screen is mostly a progress bar against a count of the lap that
		-- moves every time a driveway is finished, so it refreshes the same way
		if self.open == "Rebirth" and self.rebirthRefresh then self.rebirthRefresh() end
		if self.open == "Rewards" and self.questRows then
			for _, fn in ipairs(self.questRows) do fn() end
		end
		-- the day book wants a frame for the same reason plus one of its own: what it
		-- shows when there is nothing to claim is a countdown
		if self.open == "Daily" and self.dailyRefresh then self.dailyRefresh() end
		-- the shop's cards read ownership, which PassService writes the moment a
		-- purchase completes, so OWNED lands without a rejoin
		if self.open == "Shop" and self.shopRows then
			for _, fn in ipairs(self.shopRows) do fn() end
		end

		local ready = Quests.claimableCount(plr) > 0


		local packet = not self.railLock["Daily"] and Daily.statusOf(plr).ready

		-- One badge over the two of them, because the two of them are one key now.
		-- OR rather than a count: the badge has never meant "how much", it means
		-- "there is something here", and that is true if either half says so.
		local owed = ready or packet
		local boardNub = self.nubs and self.nubs["Board"]
		if boardNub and boardNub.Visible ~= owed then boardNub.Visible = owed end
	end)
end

--==[ panel plumbing ]========================================================

local BOARD_TABS = {
	{ id = "Daily",   title = "Daily",  tint = ORANGE },
	{ id = "Rewards", title = "Quests", tint = T.gold },
}

function Shell:_boardTabs(root: Frame, current: string)
	local pill = root:FindFirstChild("TitleBar")
	if pill then (pill :: GuiObject).Visible = false end

	local strip = Instance.new("Frame")
	strip.Name = "Tabs"
	strip.AnchorPoint = Vector2.new(0.5, 0.5)
	-- exactly where the pill sat, so the panel's silhouette is unchanged
	strip.Position = UDim2.new(0.5, 0, 0, 2)
	strip.Size = UDim2.fromOffset(340, 46)
	strip.BackgroundTransparency = 1
	strip.ZIndex = 8
	strip.Parent = root

	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.Padding = UDim.new(0, 8)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = strip

	for i, tab in ipairs(BOARD_TABS) do
		local here = tab.id == current
		-- The tab you are on is its own colour and does nothing when pressed; the
		-- other is slate and takes you there. Two live-looking buttons where one is
		-- already the answer is the same misread the shop's two buy buttons are
		-- coloured apart to avoid.
		local holder = UIKit.button(strip, tab.title:upper(), UDim2.fromOffset(160, 42),
			if here then tab.tint else T.slate,
			function()
				if here then return end

				local shut = self.railLock[tab.id]
				if shut then
					self:Toast(shut, false)
					return
				end
				self:toggle(tab.id)
			end)
		holder.LayoutOrder = i
		holder.ZIndex = 9
	end
end

function Shell:_register(id: string, holder: Frame, size: UDim2)
	-- Keep the responsive panel fraction while scaling its pixel-sized contents.
	fitBlock(holder, function(f)
		holder.Size = UDim2.fromScale(size.X.Scale / f, size.Y.Scale / f)
	end)
	holder.Visible = false
	holder.SelectionGroup = true
	self.panels[id] = holder
	self.sizes[id] = size
end

local FREE_ZOOM = 10      -- studs; far enough out that the module stops locking
local CLAMP_ARRIVE = 0.35 -- studs; close enough to call the camera arrived
local CLAMP_TIMEOUT = 1.5 -- seconds before the ceiling is let go regardless

function Shell:_camDistance(): number
	local char = self.plr.Character
	local head = char and char:FindFirstChild("Head")
	local cam = workspace.CurrentCamera
	if not head or not cam then return self.plr.CameraMinZoomDistance end
	return ((cam.CFrame.Position - (head :: BasePart).Position).Magnitude)
end

function Shell:_freeMouse(on: boolean)
	local plr = self.plr
	if on then
		if self.cam == nil then
			self.cam = {
				min = plr.CameraMinZoomDistance,
				max = plr.CameraMaxZoomDistance,
				dist = self:_camDistance(),
			}
		else
			-- a restore from the panel being replaced is mid-flight; take the ceiling
			-- back off before it can drag the camera in behind the new panel
			plr.CameraMaxZoomDistance = self.cam.max
		end
		self.camToken = (self.camToken or 0) + 1
		if plr.CameraMinZoomDistance < FREE_ZOOM then
			if plr.CameraMaxZoomDistance < FREE_ZOOM then
				plr.CameraMaxZoomDistance = FREE_ZOOM
			end
			plr.CameraMinZoomDistance = FREE_ZOOM
		end
	else
		local s = self.cam
		if not s then return end
		self.camToken = (self.camToken or 0) + 1
		local token = self.camToken

		local want = math.clamp(s.dist, s.min, s.max)
		plr.CameraMaxZoomDistance = math.max(want, s.min)
		plr.CameraMinZoomDistance = s.min
		task.spawn(function()
			local t0 = os.clock()
			while os.clock() - t0 < CLAMP_TIMEOUT do
				-- another panel opened while the ceiling was down; that path has already
				-- put it back and still owns the saved state
				if self.camToken ~= token then return end
				if math.abs(self:_camDistance() - want) < CLAMP_ARRIVE then break end
				task.wait()
			end
			if self.camToken ~= token then return end
			plr.CameraMaxZoomDistance = s.max
			self.cam = nil
		end)
	end
end

function Shell:toggle(id: string)
	if self.open == id then self:close() return end
	self:close()
	local p = self.panels[id]
	if not p then return end
	self.open = id
	self:_freeMouse(true)
	p.Visible = true
	Console.setMenu(true, p)

	if id == "Dealership" then
		self.plr:SetAttribute("RigMenuVisited", true)
	end

	local target = self.sizes[id]
	local fit = math.max(fitNow, 0.01)
	local targetSize = UDim2.fromScale(target.X.Scale / fit, target.Y.Scale / fit)
	p.Size = UDim2.fromScale(targetSize.X.Scale * 0.9, targetSize.Y.Scale * 0.9)
	TweenService:Create(p, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = targetSize }):Play()
	if id ~= "Rewards" and id ~= "Rebirth" and id ~= "Daily" then
		local nub = self.nubs and self.nubs[id]
		if nub then nub.Visible = false end
	end
end

function Shell:LockRail(id: string, message: string?)
	self.railLock[id] = message
	if message and self.open == id then self:close() end
end

function Shell:openShopTab(tabId: string)
	if self.selectShopTab then
		self.selectShopTab(tabId)
	else
		-- Shop not built yet: remember the tab; _buildShop keeps whatever is set.
		self.shopTab = tabId
	end
	if self.open ~= "Shop" then
		self:toggle("Shop")
	end
end

function Shell:close()
	if not self.open then return end
	local p = self.panels[self.open]
	if p then p.Visible = false end
	if self.rebirthDisarm then self.rebirthDisarm() end
	self.open = nil
	Console.setMenu(false)
	self:_freeMouse(false)
end

--==[ upgrades ]==============================================================

function Shell:_buildUpgrades()
	-- 0.62 rather than 0.54: the rows carry a second buy button now, and the width
	-- to hold it has to come from somewhere. Taken from the panel rather than from
	-- the blurbs, which were already truncating at the old size, and rather than
	-- from the row height -- four rows still have to fit without a scrollbar.
	local size = UDim2.fromScale(0.62, 0.7)
	local holder, content, root = UIKit.panel(self.gui, size, UDim2.fromScale(0.5, 0.5), "Upgrades", T.green)
	UIKit.closeButton(root, function() self:close() end)
	local list = UIKit.scroller(content, 12)

	for i, track in ipairs(Upgrades.Tracks) do
		-- Trucks are tracks too, but they are sold on their own screen with a
		-- picture and stat bars; a bare row here would be a second, worse place to
		-- buy the same thing.
		if track.hidden then continue end

		local row = Instance.new("Frame")
		row.Name = track.id
		row.Size = UDim2.new(1, 0, 0, 96)
		row.BackgroundColor3 = T.blue
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.ZIndex = 8
		row.Parent = list
		UIKit.corner(row, 15)
		UIKit.stroke(row, 2.4)
		UIKit.gradient(row, 0.75)
		-- Below the row's own contents, which all sit at 9 and up: a sheen laid over
		-- the caption would wash the top of every letter.
		UIKit.gloss(row, 5, 11, 0.36).ZIndex = 8

		local badge = Instance.new("Frame")
		badge.Position = UDim2.fromOffset(12, 14)
		badge.Size = UDim2.fromOffset(68, 68)
		badge.BackgroundColor3 = track.tint
		badge.BorderSizePixel = 0
		badge.ZIndex = 9
		badge.Parent = row
		UIKit.corner(badge, 15)
		UIKit.stroke(badge, 2.2)
		UIKit.gradient(badge, 1.2)
		UIKit.gloss(badge, 4, 9, 0.44).ZIndex = 9
		local gl = UIKit.label(badge, track.glyph, 34, T.navy)
		gl.Size = UDim2.fromScale(1, 1)
		gl.TextXAlignment = Enum.TextXAlignment.Center
		gl.ZIndex = 10

		local INSET = -436

		local name = UIKit.label(row, track.name, 22, T.cream)
		name.Position = UDim2.fromOffset(92, 8)
		name.Size = UDim2.new(1, INSET, 0, 28)
		name.ZIndex = 9

		local blurb = UIKit.label(row, track.blurb, 15, Color3.fromRGB(214, 234, 252))
		blurb.Position = UDim2.fromOffset(92, 34)
		blurb.Size = UDim2.new(1, INSET, 0, 20)
		blurb.TextTruncate = Enum.TextTruncate.AtEnd
		blurb.ZIndex = 9

		local stat = UIKit.label(row, "", 19, T.gold)
		stat.Position = UDim2.fromOffset(92, 58)
		stat.Size = UDim2.new(1, INSET, 0, 26)
		stat.ZIndex = 9

		local pips = Instance.new("Frame")
		pips.BackgroundTransparency = 1
		pips.AnchorPoint = Vector2.new(1, 0)
		pips.Position = UDim2.new(1, -16, 0, 12)
		pips.Size = UDim2.fromOffset(200, 14)
		pips.ZIndex = 9
		pips.Parent = row
		local pl = Instance.new("UIListLayout")
		pl.FillDirection = Enum.FillDirection.Horizontal
		pl.Padding = UDim.new(0, 4)
		pl.HorizontalAlignment = Enum.HorizontalAlignment.Right
		pl.Parent = pips

		local pipW = math.clamp(math.floor((200 - 4 * (#track.values - 1)) / #track.values), 5, 14)
		local pipParts = {}
		for k = 1, #track.values do
			local p = Instance.new("Frame")
			p.Size = UDim2.fromOffset(pipW, 12)
			p.BackgroundColor3 = T.navy
			p.BorderSizePixel = 0
			p.LayoutOrder = k
			p.ZIndex = 10
			p.Parent = pips
			UIKit.corner(p, 4)
			pipParts[k] = p
		end

		local function fire(name: string)
			local remotes = Pack:FindFirstChild("Remotes")
			local ev = remotes and remotes:FindFirstChild(name)
			if ev then (ev :: RemoteEvent):FireServer(track.id) end
		end

		-- Cash keeps the right edge. That is where the buy button has always been and
		-- what a returning player's hand goes to; the new one takes the space beside
		-- it rather than pushing the familiar one along.
		local buyHolder, buyCap = UIKit.button(row, "", UDim2.fromOffset(166, 50), T.green, function()

			if track.pass then
				local pass = Passes.ById[track.pass]
				if Passes.owns(self.plr, track.pass) then
					self:Toast(if Rigs.chosen(self.plr)
						then "Already fitted -- drop it from the driver's dial"
						else "Pass held -- buy a rig at the dealership to fit it", true)
				elseif pass and pass.assetId ~= 0 then
					MarketplaceService:PromptGamePassPurchase(self.plr, pass.assetId)
				else
					self:Toast("That pass is not on sale yet", false)
				end
				return
			end
			fire("BuyUpgrade")
		end)
		buyHolder.AnchorPoint = Vector2.new(1, 1)
		buyHolder.Position = UDim2.new(1, -16, 1, -12)
		local affordableDot = Instance.new("Frame")
		affordableDot.Name = "AffordableDot"
		affordableDot.AnchorPoint = Vector2.new(0.5, 0.5)
		affordableDot.Position = UDim2.new(1, -3, 0, 3)
		affordableDot.Size = UDim2.fromOffset(15, 15)
		affordableDot.BackgroundColor3 = T.red
		affordableDot.BorderSizePixel = 0
		affordableDot.ZIndex = 30
		affordableDot.Visible = false
		affordableDot.Parent = buyHolder

		UIKit.corner(affordableDot, 8)
		UIKit.stroke(affordableDot, 1.5)

		self.upgradeDots[track.id] = affordableDot
		-- Gold, not green. Two green buttons an inch apart on the same row is one
		-- misclick that spends real money, and the whole point of the pair is that
		-- the player can tell at a glance which currency they are about to spend.
		local robuxHolder, robuxCap = UIKit.button(row, "", UDim2.fromOffset(134, 50), T.gold, function()
			-- belt and braces against the row ever being shown again: this remote buys
			-- a LEVEL, and a pass row has no ladder for it to buy a rung of
			if track.pass then return end
			fire("BuyRobux")
		end)
		robuxHolder.AnchorPoint = Vector2.new(1, 1)
		robuxHolder.Position = UDim2.new(1, -192, 1, -12)

		robuxHolder.Visible = not track.pass

		local function refresh()
			local level = self.plr:GetAttribute("Upg_" .. track.id) :: number or 1
			local maxL = #track.values
			local listed = Upgrades.costOf(track.id, level)
			local cost = if listed and not track.unlock
				then Rebirth.priceOf(self.plr, listed) else listed
			-- Locked is not the same as expensive, and must not look like it: the top
			-- rungs cannot be bought at any price until enough rebirths are behind them.
			local needs = Upgrades.requiresOf(track.id, level)
			local locked = needs > Rebirth.countOf(self.plr)

			-- Bought with Robux and bolted to a vehicle, so it answers to neither the
			-- cash ladder nor the rebirth gates, and leaves before either is consulted.
			if track.pass then
				local hasPass = Passes.owns(self.plr, track.pass)
				local hasRig = Rigs.chosen(self.plr) ~= nil
				stat.Text = if hasPass and hasRig then
					"<font color=\"rgb(150,240,150)\">FITTED \u{2022} drop it from the driver's dial</font>"
					elseif hasPass then
					"Pass held \u{2022} <font color=\"rgb(250,200,120)\">still needs a truck</font>"
					else
					"<font color=\"rgb(250,200,120)\">Requires truck and gamepass</font>"
				buyCap.Text = if hasPass and hasRig then "FITTED"
					elseif hasPass then "NEEDS A RIG"
					else "\u{1F512} GAMEPASS"
				for _, p in ipairs(pipParts) do
					p.BackgroundColor3 = if hasPass and hasRig then track.tint else T.navy
				end
				return
			end

			if track.unlock then
				-- A one-time purchase has no ladder to describe: "Lv 1 - 0 -> 1" is
				-- noise on a row whose only question is whether you own it.
				local owned = level >= maxL
				stat.Text = owned
					and "<font color=\"rgb(150,240,150)\">OWNED \u{2022} spawn it in the bay</font>"
					or "Not owned yet"
				buyCap.Text = owned and "OWNED" or ("$ " .. Upgrades.short(cost or 0))
			else
				local cur = Upgrades.valueAt(track.id, level)
				local nxt = level < maxL and Upgrades.valueAt(track.id, level + 1) or nil
				-- Literal UTF-8, not &#8226; / &#8594;: Roblox RichText only understands a
				-- handful of NAMED entities and passes numeric ones through as raw text,
				-- so those rendered as stray quotes and replacement characters.
				stat.Text = if locked then
					("Lv %d  \u{2022}  %s%s  <font color=\"rgb(250,200,120)\">\u{2022} %d rebirth%s to go further</font>")
					:format(level, Upgrades.short(cur), track.suffix, needs, needs == 1 and "" or "s")
					elseif nxt then
					("Lv %d  \u{2022}  %s%s  <font color=\"rgb(150,240,150)\">\u{2192} %s%s</font>")
					:format(level, Upgrades.short(cur), track.suffix, Upgrades.short(nxt), track.suffix)
					else
					("Lv %d  \u{2022}  %s%s  (MAX)"):format(level, Upgrades.short(cur), track.suffix)
				buyCap.Text = if locked then ("\u{1F512} %d REBIRTH%s"):format(needs, needs == 1 and "" or "S")
					elseif cost then "$ " .. Upgrades.short(cost)
					else "MAXED"
			end

			robuxHolder.Visible = cost ~= nil and not locked
			-- The price arrives a moment after the panel is built, so the caption has a
			-- word to wear until it does rather than a number that might be wrong.
			robuxCap.Text = if robuxPrice then ("R$ %d"):format(robuxPrice) else "ROBUX"

			for k, p in ipairs(pipParts) do
				-- the rebirth-gated rungs read as a different colour until they open, so
				-- the shape of the ladder is visible before you can climb it
				local gated = Upgrades.requiresOf(track.id, k - 1) > Rebirth.countOf(self.plr)
				p.BackgroundColor3 = if k <= level then track.tint
					elseif gated then Color3.fromRGB(88, 74, 52)
					else T.navy
			end

			local affordable =
				not track.pass
				and not locked
				and cost ~= nil
				and cashOf(self.plr) >= cost

			affordableDot.Visible = affordable
		end
		refresh()
		-- redrawn once more when GetProductInfo answers, so "ROBUX" becomes a price
		table.insert(robuxRows, refresh)
		self.plr:GetAttributeChangedSignal("Upg_" .. track.id):Connect(refresh)
		-- A rebirth moves every price on this screen and opens the gated rungs, so
		-- the rows have to redraw off it as well as off their own level.
		self.plr:GetAttributeChangedSignal(Rebirth.Attr):Connect(refresh)
		-- A pass row answers to two things the others do not: the pass landing, and
		-- a truck being bought after it.
		if track.pass then
			self.plr:GetAttributeChangedSignal(Passes.attrName(track.pass)):Connect(refresh)
			for _, r in ipairs(Rigs.All) do
				self.plr:GetAttributeChangedSignal("Upg_" .. r.id):Connect(refresh)
			end
		end
	end

	task.defer(function()
		self:_refreshUpgradeAlerts()
	end)

	self:_register("Upgrades", holder, size)
end

--==[ the rig bay picker ]====================================================

local function fleetOut(plr: Player): string?
	for _, m in ipairs(workspace:GetChildren()) do
		if m:GetAttribute("OwnerUserId") == plr.UserId then
			return m:GetAttribute("RigId") :: string?
		end
	end
	return nil
end

function Shell:_buildRigBay()
	local size = UDim2.fromScale(0.56, 0.76)
	local holder, content, root = UIKit.panel(self.gui, size, UDim2.fromScale(0.5, 0.5),
		"Rig Bay", SKY)
	UIKit.closeButton(root, function() self:close() end)
	local list = UIKit.scroller(content, 12)

	self.rigBayRows = {}

	local function fire(name: string, id: string?)
		local remotes = Pack:FindFirstChild("Remotes")
		local ev = remotes and remotes:FindFirstChild(name)
		if ev then (ev :: RemoteEvent):FireServer(id) end
		self:close()
	end

	local function passFor(rig: Rigs.Rig)
		local p = if rig.pass then Passes.ById[rig.pass]
			elseif rig.id == Rigs.cheapest().id then Passes.ById.PermanentRig
			else nil
		return if p and p.assetId ~= 0 then p else nil
	end

	-- Rigs.All: the pass truck has to be callable from here once it is owned, and
	-- this panel is the only place a rig can be called up from.
	for i, rig in ipairs(Rigs.All) do
		local row = Instance.new("Frame")
		row.Name = rig.id
		row.Size = UDim2.new(1, 0, 0, 96)
		-- the rig's own livery, at the same sixth the shop tiers use, so the row and
		-- the truck that turns up are recognisably the same thing
		row.BackgroundColor3 = T.blue:Lerp(rig.tint, 0.18)
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.ZIndex = 8
		row.Parent = list
		UIKit.corner(row, 17)
		UIKit.stroke(row, 2.6)
		UIKit.gradient(row, 0.75)

		local badge = Instance.new("Frame")
		badge.Position = UDim2.fromOffset(12, 12)
		badge.Size = UDim2.fromOffset(72, 72)
		badge.BackgroundColor3 = rig.tint
		badge.BorderSizePixel = 0
		badge.ZIndex = 9
		badge.Parent = row
		UIKit.corner(badge, 16)
		UIKit.stroke(badge, 2.4)
		UIKit.gradient(badge, 1.15)
		local mark = UIKit.outlined(badge, "\u{1F69B}", 30, T.white, 2.2)
		mark.Size = UDim2.fromScale(1, 1)
		mark.TextXAlignment = Enum.TextXAlignment.Center
		mark.ZIndex = 10

		local title = UIKit.outlined(row, rig.name, 24, T.white, 2.4)
		title.Position = UDim2.fromOffset(96, 8)
		title.Size = UDim2.new(1, -280, 0, 30)
		title.ZIndex = 9

		-- The stats, in the units the rest of the game already says them in, so the
		-- row can be compared against the tank and hose readouts in the corner.
		local stat = UIKit.label(row, "", 15, Color3.fromRGB(214, 236, 255))
		stat.Position = UDim2.fromOffset(96, 38)
		stat.Size = UDim2.new(1, -280, 0, 20)
		stat.RichText = true
		stat.ZIndex = 9

		local note = UIKit.label(row, rig.tagline, 14, Color3.fromRGB(168, 198, 226))
		note.Position = UDim2.fromOffset(96, 60)
		note.Size = UDim2.new(1, -280, 0, 20)
		note.ZIndex = 9

		-- The THIRD return, which is the one that actually recolours a button: the
		-- holder is transparent, so retinting it changes nothing you can see, and the
		-- cap and its plinth have to move together or the hover tween pulls the old
		-- shade back the moment the pointer leaves. See UIKit.button.
		local actHolder, actCap, actColour = UIKit.button(row, "", UDim2.fromOffset(168, 52), T.green,
			function()
				if Rigs.owns(self.plr, rig.id) then

					if fleetOut(self.plr) == rig.id then
						fire("StoreRig")
					else
						fire("SpawnRig", rig.id)
					end
					return
				end

				local pass = passFor(rig)
				if pass then
					MarketplaceService:PromptGamePassPurchase(self.plr, pass.assetId)
					return
				end
				-- A pass-only rig is not sold at the dealership and never will be, so
				-- pointing the player at the showroom would be sending them across the
				-- map for nothing.
				self:Toast(if rig.pass
					then rig.name .. " is sold by game pass only"
					else rig.name .. " is sold at the dealership", false)
				return
			end)
		actHolder.AnchorPoint = Vector2.new(1, 0.5)
		actHolder.Position = UDim2.new(1, -16, 0.5, 0)
		actCap.TextScaled = true
		actCap.TextWrapped = true

		-- Fixed for the life of the row, so it is written once rather than every
		-- frame the panel is open. mph because that is what the cab gauge reads.
		stat.Text = ("%d mph  \u{2022}  %s hose  \u{2022}  %s tank")
			:format(math.floor(rig.topSpeed * MPH_PER_STUD + 0.5),
				Upgrades.short(rig.hose), Upgrades.short(Rigs.tankFor(self.plr, rig)))

		local shown: string? = nil
		local function refresh()
			local out = fleetOut(self.plr)
			local pass = passFor(rig)
			local state
			if not Rigs.owns(self.plr, rig.id) then
				state = if pass then "offer" else "locked"
				-- "Out now" and "store first" are worth spelling out separately: the server
				-- refuses a second rig while you have one in the bay, and a SPAWN button
				-- that is going to be turned down is worse than no button.
			elseif out == rig.id then state = "here"
			elseif out then state = "busy"
			else state = "ready"
			end

			if state == shown then return end
			shown = state

			if state == "ready" then
				note.Text = rig.tagline
				actCap.Text = "SPAWN"
				actColour(T.green)
			elseif state == "here" then
				note.Text = "Out in the bay now"
				actCap.Text = "STORE"
				-- red, because it is the one button here that takes something away
				actColour(T.red)
			elseif state == "busy" then
				note.Text = "Store the one you have out first"
				actCap.Text = "STORE FIRST"
				actColour(T.slate)
			elseif state == "offer" then
				-- the pass's own name, never a second copy typed here: this button and
				-- Roblox's dialog have to agree about what is being bought
				note.Text = "Yours for good with " .. (pass :: any).name
				actCap.Text = "\u{26A1} UNLOCK"
				actColour(T.gold)
			else
				-- A pass rig has no price to quote and no counter to quote it at. It
				-- only reaches this state while its listing does not exist yet.
				note.Text = if rig.pass then "Sold by game pass"
					else "$" .. Upgrades.short(rig.price) .. " at the dealership"
				actCap.Text = "LOCKED"
				actColour(T.slate)
			end
		end

		refresh()
		table.insert(self.rigBayRows, refresh)
		-- the unlock attribute is how a rig is owned however it came to be owned:
		-- bought at the counter, restored from a save, or granted by the pass
		self.plr:GetAttributeChangedSignal("Upg_" .. rig.id):Connect(refresh)
	end

	local go = UIKit.chip(list, "Take me to the dealership", 300, T.gold, function()
		fire("GoDealership")
		self:close()
	end)
	-- The rows above take LayoutOrder 1..n from their own loop, so this sits past
	-- the end of any fleet the game might grow to.
	go.LayoutOrder = 900

	self:_register("RigBay", holder, size)
end

--==[ dealership ]============================================================

local function atDealership(): boolean
	if require(game.ReplicatedStorage.DrivewaySealer.ExtraRefuel).at(Players.LocalPlayer) then return true end
	local hall = workspace:FindFirstChild("RigDealership")
	local floor = hall and hall:FindFirstChild("Floor")
	if not (floor and floor:IsA("BasePart")) then return true end
	local slab = floor :: BasePart
	local ch = Players.LocalPlayer.Character
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then return false end
	local margin = (slab:GetAttribute("ZoneMargin") :: number?) or 6
	local p = slab.CFrame:PointToObjectSpace((root :: BasePart).Position)
	return math.abs(p.X) <= slab.Size.X * 0.5 + margin
		and math.abs(p.Z) <= slab.Size.Z * 0.5 + margin
		and p.Y > -2 and p.Y < 18
end

local SPIN_RATE = 0.5      -- radians a second, unattended
local DRAG_RATE = 0.010    -- radians per pixel dragged
-- How far the stand's aim point drops below the rig, as a fraction of its reach.
-- SOLVED, not eyeballed: project the silhouette (model bounding box + both
-- turntable discs) onto the camera's up axis and find the aim height that puts
-- the top and bottom extremes the same distance from the middle. All four rigs
-- want 0.1187 - 0.1231, a spread of under 2px on a 450px viewport, so one
-- constant serves the range -- but re-solve it if the camera angle, the field of
-- view or the 1.14/1.22 pad sizing ever move.
local STAND_LIFT = 0.123

function Shell:_buildDealership()
	local size = UDim2.fromScale(0.82, 0.84)
	local holder, content, root = UIKit.panel(self.gui, size, UDim2.fromScale(0.5, 0.5),
		"Rig Dealership", T.gold)
	UIKit.closeButton(root, function() self:close() end)

	self.dealerRows = {}

	--==[ the stand ]=========================================================

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.BackgroundColor3 = T.navy
	stage.BorderSizePixel = 0
	stage.Position = UDim2.new(0, 18, 0, 6)
	stage.Size = UDim2.new(0.55, -10, 1, -110)
	stage.ZIndex = 8
	stage.Parent = content
	UIKit.corner(stage, 16)
	UIKit.stroke(stage, 2.4)
	UIKit.vignette(stage, 16, 0, 0.42)

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Stand"
	viewport.BackgroundTransparency = 1
	viewport.Position = UDim2.fromOffset(5, 5)
	viewport.Size = UDim2.new(1, -10, 1, -10)
	viewport.ZIndex = 9
	viewport.Ambient = Color3.fromRGB(150, 158, 172)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.45, -1, -0.55)
	viewport.Parent = stage

	-- a WorldModel rather than parenting parts straight in: without one a
	-- ViewportFrame ignores the light direction and everything renders flat
	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = viewport
	viewport.CurrentCamera = cam

	local pad = Instance.new("Part")
	pad.Name = "Turntable"
	pad.Shape = Enum.PartType.Cylinder
	pad.Anchored = true
	pad.Material = Enum.Material.SmoothPlastic
	pad.Color = Color3.fromRGB(34, 40, 54)
	pad.Size = Vector3.new(0.7, 33, 33)
	pad.Parent = world

	local rim = Instance.new("Part")
	rim.Name = "TurntableRim"
	rim.Shape = Enum.PartType.Cylinder
	rim.Anchored = true
	rim.Material = Enum.Material.Neon
	rim.Size = Vector3.new(0.4, 35, 35)
	rim.Parent = world

	local hint = UIKit.label(stage, "DRAG TO TURN", 14, Color3.fromRGB(148, 168, 192))
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -6)
	hint.Size = UDim2.new(1, -24, 0, 18)
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.ZIndex = 12

	-- A transparent button over the stand. A ViewportFrame is not a button, and
	-- catching a drag on a plain GuiObject is not reliable; this is.
	local grab = Instance.new("TextButton")
	grab.Name = "Grab"
	grab.BackgroundTransparency = 1
	grab.AutoButtonColor = false
	grab.Text = ""
	grab.Size = UDim2.fromScale(1, 1)
	grab.ZIndex = 13
	grab.Parent = stage

	--==[ the model on it ]===================================================

	local clones: { [string]: Model } = {}
	local shownId: string? = nil
	local angle = 0

	local function stand(id: string)
		if shownId == id then return end
		local prev = shownId and clones[shownId]
		if prev then prev.Parent = nil end
		shownId = nil

		local m = clones[id]
		if not m then
			local hall = workspace:FindFirstChild("RigDealership")
			local shelf = hall and hall:FindFirstChild("Display")
			local src = shelf and shelf:FindFirstChild("Display_" .. id)
			if not (src and src:IsA("Model")) then return end
			m = (src :: Model):Clone()
			-- a viewport draws geometry and nothing else
			for _, d in ipairs(m:GetDescendants()) do
				if d:IsA("ProximityPrompt") or d:IsA("Light") or d:IsA("Sound")
					or d:IsA("ParticleEmitter") then
					d:Destroy()
				elseif d:IsA("BasePart") then
					d.Anchored = true
					d.CastShadow = false
				end
			end

			m.PrimaryPart = nil
			local cf, sz = m:GetBoundingBox()
			m.WorldPivot = CFrame.new(cf.Position)
			m:PivotTo(CFrame.new())
			m:SetAttribute("Reach", math.max(sz.X, sz.Y, sz.Z))
			m:SetAttribute("Drop", sz.Y * 0.5)
			clones[id] = m
		end

		m.Parent = world
		shownId = id

		local reach = (m:GetAttribute("Reach") :: number?) or 24
		local drop = (m:GetAttribute("Drop") :: number?) or 5

		-- the stand is sized off the truck standing on it, or the Dart sits in the
		-- middle of a disc built for the Cistern like a toy on a dinner plate
		pad.Size = Vector3.new(0.7, reach * 1.14, reach * 1.14)
		rim.Size = Vector3.new(0.4, reach * 1.22, reach * 1.22)
		pad.CFrame = CFrame.new(0, -drop - 0.35, 0) * CFrame.Angles(0, 0, math.rad(90))
		rim.CFrame = CFrame.new(0, -drop - 0.5, 0) * CFrame.Angles(0, 0, math.rad(90))

		-- framed off the model's own longest axis, so a short Dart is not lost in
		-- the middle of a frame built for the Cistern. 1.06 rather than a rounder
		-- number: the rig turns, so the frame has to hold its LENGTH broadside as
		-- well as its width nose-on, and that is what the longest axis already is.
		local dist = (reach * 0.5) / math.tan(math.rad(cam.FieldOfView * 0.5)) * 1.06
		local dir = Vector3.new(0.78, 0.36, 0.62).Unit

		cam.CFrame = CFrame.lookAt(dir * dist,
			Vector3.new(0, -drop * 0.10 - reach * STAND_LIFT, 0))
	end

	--==[ turning it ]========================================================

	local dragging = false
	local lastX = 0

	grab.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			lastX = input.Position.X
			rim.Transparency = 0
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			-- PLUS, not minus. Dragging is grabbing the truck, not orbiting a camera
			-- around it: pull right and the side facing you comes right with the hand.
			-- Negated it reads as the model shoving back against the cursor.
			angle += (input.Position.X - lastX) * DRAG_RATE
			lastX = input.Position.X
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			-- let go and it picks the spin back up from wherever it was left,
			-- rather than snapping back to where it would have been
			dragging = false
		end
	end)

	--==[ the numbers beside it ]=============================================

	local info = Instance.new("Frame")
	info.Name = "Info"
	info.BackgroundTransparency = 1
	info.Position = UDim2.new(0.55, 16, 0, 12)
	info.Size = UDim2.new(0.45, -34, 1, -122)
	info.ZIndex = 8
	info.Parent = content

	local sheet = Instance.new("Frame")
	sheet.Name = "Sheet"
	sheet.AnchorPoint = Vector2.new(0, 0.5)
	sheet.BackgroundTransparency = 1
	sheet.Position = UDim2.new(0, 0, 0.5, -56)
	sheet.Size = UDim2.new(1, 0, 0, 250)
	sheet.ZIndex = 8
	sheet.Parent = info

	local nameLabel = UIKit.label(sheet, "", 36, T.cream)
	nameLabel.Font = UIKit.Display
	nameLabel.Size = UDim2.new(1, 0, 0, 42)
	nameLabel.ZIndex = 9

	local tagLabel = UIKit.label(sheet, "", 20, T.gold)
	tagLabel.Position = UDim2.fromOffset(0, 44)
	tagLabel.Size = UDim2.new(1, 0, 0, 26)
	tagLabel.ZIndex = 9

	local blurbLabel = UIKit.label(sheet, "", 19, Color3.fromRGB(198, 214, 232))
	blurbLabel.Position = UDim2.fromScale(0, 0.296)
	blurbLabel.Size = UDim2.fromScale(1, 0.248)
	blurbLabel.TextScaled = true
	blurbLabel.TextWrapped = true
	blurbLabel.TextYAlignment = Enum.TextYAlignment.Top
	blurbLabel.ZIndex = 9

	local bars: { [string]: (any, string, number) -> () } = {}
	local function statRow(y: number, key: string, caption: string)
		local cap = UIKit.label(sheet, caption, 17, Color3.fromRGB(186, 206, 228))
		cap.Position = UDim2.fromOffset(0, y)
		cap.Size = UDim2.fromOffset(76, 22)
		cap.ZIndex = 9

		-- All three columns move together or they collide: caption 76 wide, bar
		-- starting at 82, value 128 wide off the right edge. -220 is what leaves a
		-- 10px gap between the end of the bar and the start of the number.
		local bg = Instance.new("Frame")
		bg.Position = UDim2.new(0, 82, 0, y + 5)
		bg.Size = UDim2.new(1, -220, 0, 13)
		bg.BackgroundColor3 = T.navy
		bg.BorderSizePixel = 0
		bg.ZIndex = 9
		bg.Parent = sheet
		UIKit.corner(bg, 5)

		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = T.gold
		fill.BorderSizePixel = 0
		fill.ZIndex = 10
		fill.Parent = bg
		UIKit.corner(fill, 5)

		local val = UIKit.label(sheet, "", 17, T.cream)
		val.AnchorPoint = Vector2.new(1, 0)
		val.Position = UDim2.new(1, 0, 0, y)
		val.Size = UDim2.fromOffset(128, 22)
		val.TextXAlignment = Enum.TextXAlignment.Right
		val.ZIndex = 9

		bars[key] = function(rig, text, frac)
			fill.BackgroundColor3 = rig.tint
			TweenService:Create(fill, TweenInfo.new(0.28, Enum.EasingStyle.Quad),
				{ Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1) }):Play()
			val.Text = text
		end
	end
	statRow(144, "speed", "SPEED")
	statRow(172, "hose", "HOSE")
	statRow(200, "tank", "TANK")
	statRow(228, "pump", "PUMP")

	-- sat with the button rather than under the bars: they are one statement
	local priceLabel = UIKit.outlined(info, "", 34, T.gold, 2.4)
	priceLabel.AnchorPoint = Vector2.new(0, 1)
	priceLabel.Position = UDim2.new(0, 0, 1, -66)
	priceLabel.Size = UDim2.new(1, 0, 0, 40)
	priceLabel.ZIndex = 9

	local selected = Rigs.List[1]

	local buyHolder, buyCap, recolour = UIKit.button(info, "", UDim2.new(1, 0, 0, 58),
		T.gold, function()
			local rig = selected
			if Rigs.owns(self.plr, rig.id) then
				local gamePack = ReplicatedStorage:FindFirstChild("DrivewaySealer")
				local rem = gamePack and gamePack:FindFirstChild("Remotes")
				local ev = rem and rem:FindFirstChild("TruckControl")
				if ev then (ev :: RemoteEvent):FireServer("spawn", rig.id) end
			elseif not atDealership() then
				self:Toast("Come to the rig dealership to buy", false)
			else
				local rem = Pack:FindFirstChild("Remotes")
				local ev = rem and rem:FindFirstChild("BuyUpgrade")
				if ev then (ev :: RemoteEvent):FireServer(rig.id) end
			end
		end)
	buyHolder.AnchorPoint = Vector2.new(0, 1)
	buyHolder.Position = UDim2.new(0, 0, 1, 0)
	buyCap.TextScaled = true
	buyCap.TextWrapped = true

	--==[ the range along the bottom ]========================================

	local strip = Instance.new("Frame")
	strip.Name = "Range"
	strip.BackgroundTransparency = 1
	strip.Position = UDim2.new(0, 18, 1, -98)
	strip.Size = UDim2.new(1, -36, 0, 88)
	strip.ZIndex = 8
	strip.Parent = content

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.Padding = UDim.new(0, 10)
	row.HorizontalAlignment = Enum.HorizontalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = strip

	local chipRefresh: { () -> () } = {}

	-- which of your trucks is actually parked in the bay. The spawned model
	-- carries its own RigId, so the card that matches it says so and stops
	-- offering to fetch a truck that is already there.
	local function outId(): string?
		for _, mdl in ipairs(workspace:GetChildren()) do
			if mdl.Name == "SealcoatRig"
				and mdl:GetAttribute("OwnerUserId") == self.plr.UserId then
				return mdl:GetAttribute("RigId") :: string?
			end
		end
		return nil
	end

	local function select(rig)
		selected = rig
		nameLabel.Text = rig.name
		tagLabel.Text = rig.tagline
		tagLabel.TextColor3 = rig.tint
		blurbLabel.Text = rig.blurb
		rim.Color = rig.tint
		bars.speed(rig, tostring(rig.topSpeed), Rigs.normal("speed", rig.topSpeed))
		bars.hose(rig, rig.hose .. " studs", Rigs.normal("hose", rig.hose))
		-- The figure THIS player's truck will actually carry, not the catalogue base:
		-- the Bucket Capacity track scales the drum, and the showroom quoting the
		-- unscaled number was advertising a tank the rig does not have.
		bars.tank(rig, Upgrades.short(Rigs.tankFor(self.plr, rig)),
			Rigs.normal("tank", rig.tank))
		bars.pump(rig, ("x%.2f"):format(rig.pump), Rigs.normal("pump", rig.pump))
		stand(rig.id)
		for _, fn in ipairs(chipRefresh) do fn() end
	end

	for i, rig in ipairs(Rigs.List) do
		local card = Instance.new("TextButton")
		card.Name = rig.id
		card.AutoButtonColor = false
		card.Text = ""
		card.BackgroundColor3 = T.blue
		card.BorderSizePixel = 0
		card.LayoutOrder = i
		card.Size = UDim2.new(1 / #Rigs.List, -10, 1, 0)
		card.ZIndex = 9
		card.Parent = strip
		UIKit.corner(card, 13)
		local edge = UIKit.stroke(card, 2.4)
		UIKit.gradient(card, 0.8)

		local swatch = Instance.new("Frame")
		swatch.BackgroundColor3 = rig.tint
		swatch.BorderSizePixel = 0
		swatch.Position = UDim2.fromOffset(10, 10)
		swatch.Size = UDim2.new(1, -20, 0, 7)
		swatch.ZIndex = 10
		swatch.Parent = card
		UIKit.corner(swatch, 3)

		local cname = UIKit.label(card, rig.name, 19, T.cream)
		cname.Position = UDim2.fromScale(0.08, 0.25)
		cname.Size = UDim2.fromScale(0.9, 0.3)
		cname.TextXAlignment = Enum.TextXAlignment.Center
		cname.ZIndex = 10
		cname.TextScaled = true

		local cstate = UIKit.label(card, "", 17, T.gold)
		cstate.Position = UDim2.fromScale(0.08, 0.58)
		cstate.Size = UDim2.fromScale(0.8, 0.30)
		cstate.TextXAlignment = Enum.TextXAlignment.Center
		cstate.ZIndex = 10
		cstate.TextScaled = true

		card.Activated:Connect(function() select(rig) end)

		local wasPicked, wasText = nil, nil
		table.insert(chipRefresh, function()
			local picked = selected.id == rig.id
			if picked ~= wasPicked then
				wasPicked = picked
				edge.Color = picked and rig.tint or T.ink
				edge.Thickness = picked and 4 or 2.4
				card.BackgroundColor3 = picked and T.blueLight or T.blue
			end
			local text = if outId() == rig.id then "IN THE BAY"
				elseif Rigs.owns(self.plr, rig.id) then "OWNED"
				else "$ " .. Upgrades.short(rig.price)
			if text ~= wasText then
				wasText = text
				cstate.Text = text
				cstate.TextColor3 = if text == "OWNED" then T.green
					elseif text == "IN THE BAY" then T.blueLight else T.gold
			end
		end)

		self.plr:GetAttributeChangedSignal("Upg_" .. rig.id):Connect(function()
			for _, fn in ipairs(chipRefresh) do fn() end
		end)
	end

	--==[ the live half ]=====================================================

	local shownCol: Color3? = nil
	local function refresh()
		local rig = selected
		local owned = Rigs.owns(self.plr, rig.id)
		local wantPrice = if owned then "OWNED" else "$ " .. Upgrades.short(rig.price)
		if priceLabel.Text ~= wantPrice then
			priceLabel.Text = wantPrice
			priceLabel.TextColor3 = if owned then T.green else T.gold
		end

		local want, text
		if outId() == rig.id then
			want, text = T.blueLight, "IN THE BAY"
		elseif owned then
			want, text = T.green, "CALL UP"
		elseif not atDealership() then
			-- said on the button, rather than discovered by being refused
			want, text = T.slate, "AT DEALERSHIP"
		else
			want, text = T.gold, "BUY"
		end
		if buyCap.Text ~= text then buyCap.Text = text end
		if want ~= shownCol then
			shownCol = want
			recolour(want)
		end
		for _, fn in ipairs(chipRefresh) do fn() end
	end
	table.insert(self.dealerRows, refresh)

	select(Rigs.List[1])
	refresh()

	RunService.RenderStepped:Connect(function(dt)
		if self.open ~= "Dealership" then return end
		if not dragging then
			angle += dt * SPIN_RATE
			if rim.Transparency < 0.55 then rim.Transparency = math.min(0.55, rim.Transparency + dt) end
		end
		local mdl = shownId and clones[shownId]
		if mdl then mdl:PivotTo(CFrame.Angles(0, angle, 0)) end
	end)

	task.spawn(function()
		while holder.Parent do
			task.wait(0.3)
			-- the rail's Trucks button lives and dies with the zone; see _buildRail
			local btn = self.railBtns and self.railBtns.Dealership
			local inside = atDealership()
			if btn and btn.Visible ~= inside then btn.Visible = inside end
		end
	end)

	self:_register("Dealership", holder, size)
end

--==[ rebirth ]==============================================================

function Shell:_buildRebirth()
	local size = UDim2.fromScale(0.55, 0.73)
	local holder, content, root = UIKit.panel(self.gui, size, UDim2.fromScale(0.5, 0.5),
		"Rebirth", T.teal)
	UIKit.closeButton(root, function() self:close() end)

	local page = Instance.new("Frame")
	page.Name = "Page"
	page.BackgroundTransparency = 1
	page.Position = UDim2.fromOffset(22, 10)
	page.Size = UDim2.new(1, -44, 1, -18)
	page.ZIndex = 8
	page.Parent = content

	-- The readout owns the upper part of the page. Its canvas grows with the
	-- content, so long rebirth text can never render underneath the buttons.
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "ContentScroll"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, 0)
	scroll.Size = UDim2.new(1, 0, 1, -78)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = T.teal
	scroll.ZIndex = 8
	scroll.Parent = page

	-- The stack itself is as tall as its contents; ScrollingFrame measures it.
	local stack = Instance.new("Frame")
	stack.Name = "Content"
	stack.BackgroundTransparency = 1
	stack.Size = UDim2.new(1, -8, 0, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.ZIndex = 8
	stack.Parent = scroll

	local rows = Instance.new("UIListLayout")
	-- 6 -> 5: seven gaps, so a pixel off each is a row's worth of the headroom the
	-- unlock line needed, and nothing on the panel reads as tighter for it
	rows.Padding = UDim.new(0, 5)
	rows.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rows.SortOrder = Enum.SortOrder.LayoutOrder
	rows.Parent = stack

	local function line(order: number, px: number, colour: Color3, display: boolean?): TextLabel
		local l = if display
			then UIKit.outlined(stack, "", px, colour, 2.4)
			else UIKit.label(stack, "", px, colour)
		l.Size = UDim2.new(1, 0, 0, math.floor(px * 1.45))
		l.TextXAlignment = Enum.TextXAlignment.Center
		l.LayoutOrder = order
		l.ZIndex = 9
		return l
	end

	local function rule(order: number, text: string, tint: Color3): Frame
		local row = Instance.new("Frame")
		row.Name = "Heading"
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 26)
		row.LayoutOrder = order
		row.ZIndex = 8
		row.Parent = stack

		local cap = UIKit.outlined(row, text, 17, T.cream, 2.6)
		cap.Position = UDim2.fromOffset(2, 0)
		cap.Size = UDim2.new(1, -4, 0, 20)
		cap.ZIndex = 9

		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = tint
		bar.BorderSizePixel = 0
		bar.Position = UDim2.fromOffset(2, 20)
		bar.Size = UDim2.new(1, -8, 0, 5)
		bar.ZIndex = 8
		bar.Parent = row
		UIKit.corner(bar, 3)
		UIKit.stroke(bar, 2)
		return row
	end

	local hero = Instance.new("Frame")
	hero.Name = "Hero"
	hero.BackgroundTransparency = 1
	hero.Size = UDim2.new(1, 0, 0, 112)
	hero.LayoutOrder = 1
	hero.ZIndex = 8
	hero.Parent = stack
	UIKit.sunburst(hero, 11, 190, T.gold, 8)

	local medal = Instance.new("Frame")
	medal.Name = "Medal"
	medal.AnchorPoint = Vector2.new(0.5, 0.5)
	medal.Position = UDim2.fromScale(0.5, 0.5)
	medal.Size = UDim2.fromOffset(106, 106)
	medal.BackgroundColor3 = T.gold
	medal.BorderSizePixel = 0
	medal.ZIndex = 10
	medal.Parent = hero
	UIKit.corner(medal, 53)
	UIKit.stroke(medal, 3)
	UIKit.gradient(medal, 1.2)
	UIKit.gloss(medal, 8, 22, 0.42).ZIndex = 10
	UIKit.bob(medal, 0.05, 2.1)

	-- the struck inner face
	local face = Instance.new("Frame")
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.fromOffset(80, 80)
	face.BackgroundColor3 = T.goldDark
	face.BorderSizePixel = 0
	face.ZIndex = 11
	face.Parent = medal
	UIKit.corner(face, 40)
	UIKit.stroke(face, 2.2)

	local medalNum = UIKit.outlined(medal, "0", 44, T.cream, 3)
	medalNum.Size = UDim2.fromScale(1, 1)
	medalNum.Position = UDim2.fromOffset(0, -2)
	medalNum.TextXAlignment = Enum.TextXAlignment.Center
	medalNum.ZIndex = 12

	local rankLabel  = line(2, 32, T.gold, true)
	local countLabel = line(3, 25, T.cream)

	-- The ladder, the gain it buys and the lap you are on are one thought; the two
	-- cards under the second rule are a different one.
	rule(4, "THIS LAP", T.teal)

	local pipRow = Instance.new("Frame")
	pipRow.BackgroundTransparency = 1
	pipRow.Size = UDim2.new(1, 0, 0, 30)
	pipRow.LayoutOrder = 5
	pipRow.ZIndex = 8
	pipRow.Parent = stack
	local pipLay = Instance.new("UIListLayout")
	pipLay.FillDirection = Enum.FillDirection.Horizontal
	pipLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	pipLay.VerticalAlignment = Enum.VerticalAlignment.Center
	pipLay.Padding = UDim.new(0, 7)
	pipLay.SortOrder = Enum.SortOrder.LayoutOrder
	pipLay.Parent = pipRow

	local pips: { Frame } = {}
	for i = 1, Rebirth.Ladder do
		local p = Instance.new("Frame")
		p.Size = UDim2.fromOffset(22, 22)
		p.BackgroundColor3 = T.navy
		p.BorderSizePixel = 0
		p.LayoutOrder = i
		p.ZIndex = 9
		p.Parent = pipRow
		UIKit.corner(p, 7)
		UIKit.stroke(p, 2)
		-- moulded like everything else in the kit rather than printed flat: unlit,
		-- a bare navy square reads as a gap in the row instead of an empty slot
		UIKit.gradient(p, 1.1)
		UIKit.gloss(p, 3, 5, 0.40).ZIndex = 9
		pips[i] = p
	end

	local multLabel = line(6, 34, MINT)
	local unlockLabel = line(7, 19, T.gold)
	unlockLabel.Visible = false

	local BEYOND: { [string]: string } = { ParkingGarage = "the deck park" }
	local function beyondName(s: Sections.Section): string
		for _, other in ipairs(Sections.List) do
			if other.container == s.beyond then return Sections.nameOf(other) end
		end
		return BEYOND[s.beyond or ""] or "the next district"
	end

	local pillRow = Instance.new("Frame")
	pillRow.BackgroundTransparency = 1
	pillRow.Size = UDim2.new(1, 0, 0, 46)
	pillRow.LayoutOrder = 8
	pillRow.ZIndex = 8
	pillRow.Parent = stack

	local pill, fill, pillText = UIKit.progressPill(pillRow, 380)
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.new(0.5, 0, 0.5, 0)
	pill.ZIndex = 9

	rule(9, "WHAT A REBIRTH DOES", T.gold)

	local cards = Instance.new("Frame")
	cards.BackgroundTransparency = 1
	-- 94 -> 104: the wiped-track sentence measured 56px of copy in a 52px box.
	-- Sized off the longest body there is rather than off the shorter one.
	cards.Size = UDim2.new(1, -8, 0, 104)
	cards.LayoutOrder = 10
	cards.ZIndex = 8
	cards.Parent = stack
	local cardLay = Instance.new("UIListLayout")
	cardLay.FillDirection = Enum.FillDirection.Horizontal
	cardLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardLay.Padding = UDim.new(0, 10)
	cardLay.SortOrder = Enum.SortOrder.LayoutOrder
	cardLay.Parent = cards

	local function outcome(order: number, heading: string, tint: Color3, body: string, glyph: string)
		local c = Instance.new("Frame")
		c.Size = UDim2.new(0.5, -5, 1, 0)
		c.BackgroundColor3 = T.blue:Lerp(tint, 0.18)
		c.BorderSizePixel = 0
		c.LayoutOrder = order
		c.ZIndex = 9
		c.Parent = cards
		UIKit.corner(c, 18)
		UIKit.stroke(c, 3)
		UIKit.gradient(c, 0.75)
		UIKit.gloss(c, 6, 13, 0.34).ZIndex = 9

		local band = Instance.new("Frame")
		band.Size = UDim2.new(1, 0, 0, 30)
		band.BackgroundColor3 = tint
		band.BorderSizePixel = 0
		band.ZIndex = 10
		band.Parent = c
		UIKit.corner(band, 18)
		UIKit.gradient(band, 1.1)

		local mark = Instance.new("ImageLabel")
		mark.BackgroundTransparency = 1
		mark.AnchorPoint = Vector2.new(0, 0.5)
		mark.Position = UDim2.new(0, 9, 0.5, 0)
		mark.Size = UDim2.fromOffset(20, 20)
		mark.Image = glyph
		mark.ImageColor3 = T.cream
		mark.ScaleType = Enum.ScaleType.Fit
		mark.ZIndex = 11
		mark.Parent = band

		-- Inset by the sprite on BOTH sides, so the words stay optically centred in
		-- the band rather than centred in what is left of it.
		local h = UIKit.outlined(band, heading, 16, T.white, 2.2)
		h.Position = UDim2.fromOffset(33, 0)
		h.Size = UDim2.new(1, -66, 1, 0)
		h.TextXAlignment = Enum.TextXAlignment.Center
		h.ZIndex = 11

		local t = UIKit.label(c, body, 14, T.cream)
		t.RichText = order == 2
		t.Position = UDim2.fromScale(0, 0.3)
		t.Size = UDim2.fromScale(1, 0.7)
		t.TextScaled = true
		t.TextWrapped = true
		t.TextYAlignment = Enum.TextYAlignment.Center
		t.TextXAlignment = Enum.TextXAlignment.Center
		-- Keep the description behind the title band while letting it use the
		-- complete card area for TextScaled fitting.
		t.ZIndex = 9
		return c
	end

	local wiped = {}
	for _, id in ipairs(Rebirth.Tracks) do
		local t = Upgrades.ById[id]
		wiped[#wiped + 1] = t and t.name or id
	end
	local listed = if #wiped > 1
		then table.concat(wiped, ", ", 1, #wiped - 1) .. " and " .. wiped[#wiped]
		else (wiped[1] or "your upgrades")

	outcome(1, "YOURS TO KEEP", T.green,
		"Your skins, colors, trucks, opened roads, and the other world’s sealed roads"
			.. " \u{2014} for good.", "rbxassetid://18856185133")
	outcome(2, "STARTS AGAIN", T.red,
		("<b>Your CASH \u{1F4B5} RESETS</b>. %s back to Lv 1. World 1 roads back to bare concrete"
			.. " \u{2014} and worth more the second time round."):format(listed),
		"rbxassetid://11769203234")

	local armed = false
	local shownState: string? = nil
	local refresh: () -> ()

	-- A separate bottom zone. It is outside the scrolling canvas, so neither
	-- button can cover content and content cannot slide over either button.
	local footer = Instance.new("Frame")
	footer.Name = "Actions"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.BackgroundTransparency = 1
	footer.Position = UDim2.new(0, 0, 1, 0)
	footer.Size = UDim2.new(1, 0, 0, 70)
	footer.ZIndex = 12
	footer.Parent = page

	local btnHolder, btnCap, btnColour = UIKit.button(footer, "REBIRTH",
		UDim2.fromOffset(230, 60), T.green, function()
			local st = Rebirth.statusOf(self.plr)
			if not st.ready then
				self:Toast(if not st.counted then "Still counting the map"
					else ("Seal %d more driveway%s first")
					:format(st.left, st.left == 1 and "" or "s"), false)
				return
			end
			if not armed then
				armed = true
				refresh()
				task.delay(5, function()
					if armed then armed = false; refresh() end
				end)
				return
			end
			armed = false
			local rem = Pack:FindFirstChild("Remotes")
			local ev = rem and rem:FindFirstChild("Rebirth")
			if ev then (ev :: RemoteEvent):FireServer() end
			refresh()
		end)

	btnHolder.AnchorPoint = Vector2.new(1, 1)
	btnHolder.Position = UDim2.new(0.5, -6, 1, -4)

	local skipHolder, skipCap = UIKit.button(footer, "SKIP REBIRTH",
		UDim2.fromOffset(230, 60), T.green, function()
			MarketplaceService:PromptProductPurchase(self.plr, SKIP_REBIRTH_PRODUCT)
		end)
	skipHolder.AnchorPoint = Vector2.new(0, 1)
	skipHolder.Position = UDim2.new(0.5, 6, 1, -4)

	refresh = function()
		local st = Rebirth.statusOf(self.plr)

		rankLabel.Text = st.rank:upper()
		-- No "of 12" any more, because there is no denominator to quote. What a player
		-- wants to know once the pips are full is what the next one costs, and the
		-- pill below says that in driveways.
		-- The absolute pair lives here now, as the small print under the gain. It is
		-- the figure the upgrade screen and the payout both quote, so it cannot simply
		-- go -- but it is not the reason to press the button either.
		countLabel.Text = ("Rebirths: %d   \u{2022}   💵 \u{00D7}%.2f now, 💵 \u{00D7}%.2f after")
			:format(st.count, st.multiplier, st.nextMultiplier)
		medalNum.Text = tostring(st.count)

		-- lit up to what has been taken; the next one breathes so the panel points
		-- at the rebirth being bought
		for i, p in ipairs(pips) do
			local lit = i <= st.count
			p.BackgroundColor3 = if lit then T.gold else T.navy
			local old = p:FindFirstChildOfClass("UIScale")
			if old then old:Destroy() end
			-- past the last pip there is no next one to point at, and the row stays full
			if i == st.count + 1 then UIKit.bob(p, 0.16, 0.75) end
		end
		-- There is always a next rebirth to quote now, so the branch that dropped the
		-- arrow went with the top of the ladder.

		local gain = if st.multiplier > 0 then st.nextMultiplier / st.multiplier else 0
		multLabel.Text = ("EVERY JOB PAYS <font color=\"rgb(150,240,150)\">%.1f \u{00D7} 💵 MORE</font>")
			:format(gain)

		local opensNow: string? = nil
		local soonName: string? = nil
		local soonLeft = 0
		for _, s in ipairs(Sections.List) do
			local need = Sections.requiresOf(s)
			if st.count < need then
				local done = (self.plr:GetAttribute(Sections.doneAttr(s.id)) :: number?) or 0
				local total = (self.plr:GetAttribute(Sections.totalAttr(s.id)) :: number?) or 0
				if total > 0 and done >= total then
					if st.count + 1 >= need then
						opensNow = opensNow or beyondName(s)
					elseif not soonName then
						soonName, soonLeft = beyondName(s), need - st.count
					end
				end
			end
		end
		if opensNow then
			unlockLabel.Text = ("\u{1F513}  THIS ONE OPENS THE ROAD TO %s")
				:format((opensNow :: string):upper())
			unlockLabel.Visible = true
		elseif soonName then
			unlockLabel.Text = ("%d MORE OPENS THE ROAD TO %s")
				:format(soonLeft, (soonName :: string):upper())
			unlockLabel.Visible = true
		else
			unlockLabel.Visible = false
		end

		fill.Size = UDim2.fromScale(st.progress, 1)

		pillText.Text = if not st.need then "COUNTING THE MAP"
			-- Said out loud once the share is pinned at 100%, because it is the whole
			-- shape of the back half of the game: from here every rebirth is one
			-- complete sweep, and "34 / 34" alone does not tell a player that the 34
			-- IS the map rather than this lap's slice of it.
			elseif st.full then ("%d / %d \u{2022} THE WHOLE MAP")
			:format(math.min(st.done, st.need), st.need)
			else ("%d / %d DRIVEWAYS THIS LAP")
			:format(math.min(st.done, st.need), st.need)

		-- One recolour per state change, never per frame: rebuilding the ramp every
		-- frame fights the hover tween and the button flickers. Same reason the
		-- dealership rows track `shown`.
		local state, text, tint
		if armed then
			state, text, tint = "armed", "TAP AGAIN TO CONFIRM", T.red
		elseif st.ready then
			state, text, tint = "ready", "REBIRTH", T.green
		elseif not st.counted then
			-- the second or two before the server has published the map size. Says so,
			-- rather than claiming the whole map is still to do
			state, text, tint = "counting", "COUNTING THE MAP", T.slate
		else
			state, tint = "short", T.slate
			text = ("%d MORE DRIVEWAY%s"):format(st.left, st.left == 1 and "" or "S")
		end
		if btnCap.Text ~= text then btnCap.Text = text end
		if state ~= shownState then
			shownState = state
			btnColour(tint)
		end
	end

	refresh()
	self.rebirthRefresh = refresh
	-- Closing the panel disarms it, so the screen can never be reopened already
	-- one click from rebirthing.
	self.rebirthDisarm = function()
		if not armed then return end
		armed = false
		refresh()
	end
	self.plr:GetAttributeChangedSignal(Rebirth.Attr):Connect(function()
		armed = false
		refresh()
	end)

	self:_register("Rebirth", holder, size)
end

--==[ the day book ]=========================================================

-- The week as it is laid out: everything but the last rung goes across the top.
local DAY_ROW = 126      -- height of the six-across row
local DAY_BIG = 104      -- and of the seventh
local DAY_FOOT = 86

function Shell:_buildDaily()
	-- 0.68 rather than the 0.7-odd the other panels take: measured in a 693-pixel
	-- gui space the week and the foot come to about 450, so anything taller is blue
	-- nothing under the seventh tile.
	local size = UDim2.fromScale(0.64, 0.68)
	local holder, content, root = UIKit.panel(self.gui, size, UDim2.fromScale(0.5, 0.5),
		"Daily Rewards", ORANGE)
	UIKit.closeButton(root, function() self:close() end)
	-- the title pill is replaced by the two tabs; see _boardTabs
	self:_boardTabs(root, "Daily")
	local list = UIKit.scroller(content, 10)
	-- Room for the pinned foot; the scroller sizes itself for a panel that has
	-- none. Width stays full-bleed -- the side margin is UIPadding inside the
	-- frame now, and narrowing the frame again would put the clip line back over
	-- the row strokes.
	list.Size = UDim2.new(1, 0, 1, -12 - DAY_FOOT)

	--==[ the streak line ]===================================================

	local head = Instance.new("Frame")
	head.Name = "Head"
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0, 42)
	head.LayoutOrder = 1
	head.ZIndex = 8
	head.Parent = list

	-- raw label: a contextual ink stroke round a colour emoji eats the picture,
	-- which is why the quest badges draw their glyphs the same way
	local flame = Instance.new("TextLabel")
	flame.Name = "Flame"
	flame.BackgroundTransparency = 1
	flame.Font = Enum.Font.GothamBold
	flame.Text = "\u{1F525}"
	flame.TextSize = 26
	flame.Size = UDim2.fromOffset(30, 42)
	flame.ZIndex = 9
	flame.Parent = head

	local streakLabel = UIKit.outlined(head, "", 22, GOLD, 2.6)
	streakLabel.Position = UDim2.fromOffset(34, 0)
	streakLabel.Size = UDim2.new(0.56, -34, 1, 0)
	streakLabel.ZIndex = 9

	-- Why the figures on the tiles are not the ones a friend quotes. Blank at zero
	-- rebirths, where there is nothing to explain.
	local multLabel = UIKit.outlined(head, "", 16, MINT, 2.2)
	multLabel.AnchorPoint = Vector2.new(1, 0)
	multLabel.Position = UDim2.new(1, 0, 0, 0)
	multLabel.Size = UDim2.new(0.44, 0, 1, 0)
	multLabel.TextXAlignment = Enum.TextXAlignment.Right
	multLabel.ZIndex = 9

	--==[ one tile ]==========================================================

	local function tile(parent: Instance, day: number, wide: boolean): (Frame, (Daily.Status) -> ())
		local card = Instance.new("Frame")
		card.Name = "Day" .. day
		card.BackgroundColor3 = T.navy
		card.BorderSizePixel = 0
		card.ClipsDescendants = true
		card.ZIndex = 8
		card.Parent = parent
		UIKit.corner(card, 14)
		local edge = UIKit.stroke(card, 2.4)
		UIKit.gradient(card, 0.8)
		UIKit.gloss(card, 5, 10, 0.34).ZIndex = 8

		local title = UIKit.outlined(card,
			if wide then ("DAY %d \u{2022} WEEK'S END"):format(day) else ("DAY %d"):format(day),
			if wide then 20 else 16, T.cream, 2.2)
		title.Position = UDim2.fromOffset(0, if wide then 8 else 6)
		title.Size = UDim2.new(1, 0, 0, if wide then 24 else 20)
		title.TextXAlignment = Enum.TextXAlignment.Center
		title.ZIndex = 10

		-- a drawn coin rather than a money glyph, for the reason UIKit.coin exists
		local coin = UIKit.coin(card, if wide then 44 else 34, GOLD, 10)
		coin.AnchorPoint = if wide then Vector2.new(1, 0) else Vector2.new(0.5, 0)
		--coin.Position = if wide then UDim2.new(0.5, -8, 0, 40) else UDim2.new(0.5, 0, 0, 30) -- position is now set in function itself

		local burst: Frame? = nil
		if wide then
			local halo = Instance.new("Frame")
			halo.Name = "Halo"
			halo.BackgroundTransparency = 1
			halo.AnchorPoint = coin.AnchorPoint
			halo.Position = coin.Position
			halo.Size = coin.Size
			halo.ZIndex = 9
			halo.Parent = card
			-- through a local rather than written back on the next line: a statement that
			-- opens with "(" straight after a call is parsed as calling that call's result
			local rays = UIKit.sunburst(halo, 10, DAY_BIG - 6, GOLD, 9)
			rays.Visible = false
			burst = rays
		end

		local amount = UIKit.outlined(card, "", if wide then 28 else 18, T.white, 2.4)
		amount.Position = if wide then UDim2.new(0.5, 8, 0, 42) else UDim2.fromOffset(0, 64)
		amount.Size = if wide then UDim2.new(0.5, -16, 0, 40) else UDim2.new(1, 0, 0, 24)
		amount.TextXAlignment = if wide then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center
		amount.ZIndex = 10

		-- The word along the bottom is what actually says which of the three states a
		-- tile is in. The fill says it too, but a colour alone is not a caption --
		-- see the note on the rail about spanners and shopping trolleys.
		local strip = Instance.new("Frame")
		strip.Name = "State"
		-- On the seventh it goes on the RIGHT rather than underneath. That card is one
		-- row tall and the full width of the panel, so the room it has is sideways;
		-- stacking a caption under the coin there squeezed the coin and the caption
		-- both into about twenty pixels each.
		strip.AnchorPoint = if wide then Vector2.new(1, 0.5) else Vector2.new(0.5, 1)
		strip.Position = if wide then UDim2.new(1, -16, 0.5, 0) else UDim2.new(0.5, 0, 1, -6)
		strip.Size = if wide then UDim2.fromOffset(128, 26) else UDim2.new(1, -12, 0, 24)
		strip.BackgroundColor3 = T.slate
		strip.BorderSizePixel = 0
		strip.ZIndex = 10
		strip.Parent = card
		UIKit.corner(strip, 8)
		UIKit.stroke(strip, 2)
		UIKit.gradient(strip, 1.05)

		local stateText = UIKit.outlined(strip, "SOON", 14, T.white, 1.8)
		stateText.Size = UDim2.fromScale(1, 1)
		stateText.TextXAlignment = Enum.TextXAlignment.Center
		stateText.ZIndex = 11

		local shown: string? = nil
		return card, function(st: Daily.Status)
			-- the figure moves with the rebirth multiplier, so it is re-read rather than
			-- written once at build time; guarded, so it is a comparison a frame
			local money = "$" .. Upgrades.short(Daily.amountAt(day, self.plr))
			if amount.Parent.Name == "Day7" then
				money = "x1 Instant Coat"
			elseif amount.Parent.Name == "Day3" then
				money = money .. "\nBrushed Steel Skin"
			end
			if amount.Text ~= money then
				amount.Text = money
			end

			local state
			if st.loading then
				state = "wait"
			elseif day <= st.collected then
				state = "paid"
			elseif day == st.day and st.ready then
				state = "ready"
			else
				state = "locked"
			end

			if state == "ready" then
				edge.Thickness = 3.1 + 0.9 * math.sin(os.clock() * 3.4)
			end

			if state == shown then return end
			shown = state

			if state == "paid" then
				UIKit.retint(card, T.navy:Lerp(T.green, 0.34), 0.8)
				UIKit.retint(strip, T.green, 1.05)
				stateText.Text = "PAID"
				edge.Color, edge.Thickness = T.ink, 2.4
			elseif state == "ready" then
				UIKit.retint(card, Color3.fromRGB(168, 96, 20), 0.8)
				UIKit.retint(strip, ORANGE, 1.05)
				stateText.Text = "TODAY"
				edge.Color = GOLD
			else
				UIKit.retint(card, T.navy, 0.8)
				UIKit.retint(strip, T.slate, 1.05)
				-- "SOON" would be a promise the panel cannot keep while the profile is
				-- still in the post: for all it knows every one of these is already paid
				stateText.Text = if state == "wait" then "\u{2022}\u{2022}\u{2022}" else "SOON"
				edge.Color, edge.Thickness = T.ink, 2.4
			end
			if burst then burst.Visible = state == "ready" end
		end
	end

	--==[ the week ]==========================================================

	local refreshers: { (Daily.Status) -> () } = {}

	local across = #Daily.Days - 1
	local week = Instance.new("Frame")
	week.Name = "Week"
	week.BackgroundTransparency = 1
	week.Size = UDim2.new(1, 0, 0, DAY_ROW)
	week.LayoutOrder = 2
	week.ZIndex = 8
	week.Parent = list

	-- Placed by scale rather than by pixels: the panel is a fraction of the window,
	-- so a row of six sized in offsets is a row that overflows on one machine and
	-- leaves a gap on the next.
	for day = 1, across do
		local card, refresh = tile(week, day, false)
		card.Position = UDim2.new((day - 1) / across, 4, 0, 0)
		card.Size = UDim2.new(1 / across, -8, 1, 0)
		table.insert(refreshers, refresh)
	end

	local bigRow = Instance.new("Frame")
	bigRow.Name = "WeeksEnd"
	bigRow.BackgroundTransparency = 1
	bigRow.Size = UDim2.new(1, 0, 0, DAY_BIG)
	bigRow.LayoutOrder = 3
	bigRow.ZIndex = 8
	bigRow.Parent = list

	local bigCard, bigRefresh = tile(bigRow, #Daily.Days, true)
	bigCard.Position = UDim2.fromOffset(4, 0)
	bigCard.Size = UDim2.new(1, -8, 1, 0)
	table.insert(refreshers, bigRefresh)

	--==[ the button ]========================================================

	-- Pinned to the panel rather than added to the scroller; see DAY_FOOT.
	local foot = Instance.new("Frame")
	foot.Name = "Foot"
	foot.AnchorPoint = Vector2.new(0.5, 1)
	foot.BackgroundTransparency = 1
	foot.Position = UDim2.new(0.5, 0, 1, -6)
	foot.Size = UDim2.new(1, -36, 0, DAY_FOOT - 6)
	foot.ZIndex = 8
	foot.Parent = content

	local btnRow = Instance.new("Frame")
	btnRow.Name = "Claim"
	btnRow.BackgroundTransparency = 1
	btnRow.Size = UDim2.new(1, 0, 0, 58)
	btnRow.ZIndex = 8
	btnRow.Parent = foot

	local claimState: string? = nil
	local claimHolder, claimCap, claimColour
	claimHolder, claimCap, claimColour = UIKit.button(btnRow, "", UDim2.new(1, -8, 0, 58),
		T.green, function()

			if claimState == "ready" then
				CashFx.hintFrom(claimHolder.AbsolutePosition + claimHolder.AbsoluteSize * 0.5)
			end
			local rem = Pack:FindFirstChild("Remotes")
			local ev = rem and rem:FindFirstChild("ClaimDaily")
			if ev then (ev :: RemoteEvent):FireServer() end
		end)
	claimHolder.AnchorPoint = Vector2.new(0.5, 0)
	claimHolder.Position = UDim2.new(0.5, 0, 0, 0)

	local note = UIKit.label(foot, "The book turns over at midnight UTC \u{2022} "
		.. "miss a day and the week starts again", 15, Color3.fromRGB(198, 224, 250))
	note.Name = "Footnote"
	note.AnchorPoint = Vector2.new(0.5, 1)
	note.Position = UDim2.new(0.5, 0, 1, 0)
	note.Size = UDim2.new(1, 0, 0, 22)
	note.TextXAlignment = Enum.TextXAlignment.Center
	note.ZIndex = 8

	--==[ dressing it ]=======================================================

	local function refresh()
		local st = Daily.statusOf(self.plr)
		local line

		if st.loading then
			line = "Reading your book\u{2026}"
		elseif st.resets then
			line = ("Streak of %d broken \u{2022} starting again"):format(st.streak)
		elseif st.streak <= 0 then
			line = "Your first packet is waiting"
		else
			line = ("%d day%s running"):format(st.streak, st.streak == 1 and "" or "s")
		end
		if streakLabel.Text ~= line then streakLabel.Text = line end
		local lit = not st.loading and not st.resets and st.streak > 0
		if flame.Visible ~= lit then flame.Visible = lit end

		local mult = Rebirth.multiplierOf(self.plr)
		local scaled = if mult > 1
			then ("Packets scaled \u{00D7}%s by your rebirths"):format(
				if mult < 100 then string.format("%.1f", mult) else string.format("%d", mult + 0.5))
			else ""
		if multLabel.Text ~= scaled then multLabel.Text = scaled end

		for _, fn in ipairs(refreshers) do fn(st) end

		local state, text, tint
		if st.loading then
			state, text, tint = "wait", "LOADING\u{2026}", T.slate
		elseif st.ready then
			state, tint = "ready", T.green
			text = ("CLAIM DAY %d \u{2022} $%s"):format(st.day, Upgrades.short(st.amount))
		else
			state, tint = "waiting", T.slate
			text = ("NEXT PACKET IN %s"):format(Daily.formatWait(st.secondsLeft))
		end
		if claimCap.Text ~= text then claimCap.Text = text end
		if state ~= claimState then
			claimState = state
			claimColour(tint)
		end
	end

	refresh()
	self.dailyRefresh = refresh
	self:_register("Daily", holder, size)
end

--==[ quests ]===============================================================

function Shell:_buildQuests()
	local size = UDim2.fromScale(0.56, 0.72)
	local holder, content, root = UIKit.panel(self.gui, size, UDim2.fromScale(0.5, 0.5),
		"Quests", T.gold)
	UIKit.closeButton(root, function() self:close() end)
	self:_boardTabs(root, "Rewards")
	local list = UIKit.scroller(content, 12)

	self.questRows = {}

	for i, track in ipairs(Quests.Tracks) do
		local row = Instance.new("Frame")
		row.Name = track.id
		row.Size = UDim2.new(1, 0, 0, 104)
		row.BackgroundColor3 = T.blue
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.ZIndex = 8
		row.Parent = list
		UIKit.corner(row, 15)
		UIKit.stroke(row, 2.4)
		UIKit.gradient(row, 0.75)
		UIKit.gloss(row, 5, 11, 0.36).ZIndex = 8

		local badge = Instance.new("Frame")
		badge.Position = UDim2.fromOffset(12, 18)
		badge.Size = UDim2.fromOffset(68, 68)
		badge.BackgroundColor3 = track.tint
		badge.BorderSizePixel = 0
		badge.ZIndex = 9
		badge.Parent = row
		UIKit.corner(badge, 15)
		UIKit.stroke(badge, 2.2)
		UIKit.gradient(badge, 1.2)
		UIKit.gloss(badge, 4, 9, 0.44).ZIndex = 9

		-- raw label: a contextual ink stroke round a colour emoji eats the picture
		local gl = Instance.new("TextLabel")
		gl.BackgroundTransparency = 1
		gl.Font = Enum.Font.GothamBold
		gl.Text = track.glyph
		gl.TextSize = 34
		gl.Size = UDim2.fromScale(1, 1)
		gl.ZIndex = 10
		gl.Parent = badge

		local name = UIKit.label(row, track.name, 22, T.cream)
		name.Position = UDim2.fromOffset(92, 10)
		name.Size = UDim2.new(1, -320, 0, 28)
		name.ZIndex = 9

		local goal = UIKit.label(row, "", 17, Color3.fromRGB(214, 234, 252))
		goal.Position = UDim2.fromOffset(92, 36)
		goal.Size = UDim2.new(1, -320, 0, 22)
		goal.ZIndex = 9

		local bar, fill, barText = UIKit.progressPill(row, 200)
		bar.Position = UDim2.fromOffset(92, 62)
		bar.Size = UDim2.new(1, -340, 0, 30)
		bar.ZIndex = 9
		barText.ZIndex = 12

		-- the ladder, so how deep in you are reads without a wall of checkboxes
		local pips = Instance.new("Frame")
		pips.BackgroundTransparency = 1
		pips.AnchorPoint = Vector2.new(1, 0)
		pips.Position = UDim2.new(1, -16, 0, 14)
		pips.Size = UDim2.fromOffset(200, 14)
		pips.ZIndex = 9
		pips.Parent = row
		local pl = Instance.new("UIListLayout")
		pl.FillDirection = Enum.FillDirection.Horizontal
		pl.Padding = UDim.new(0, 4)
		pl.HorizontalAlignment = Enum.HorizontalAlignment.Right
		pl.Parent = pips
		local pipParts = {}
		for k = 1, #track.tiers do
			local p = Instance.new("Frame")
			p.Size = UDim2.fromOffset(14, 12)
			p.BackgroundColor3 = T.navy
			p.BorderSizePixel = 0
			p.LayoutOrder = k
			p.ZIndex = 10
			p.Parent = pips
			UIKit.corner(p, 4)
			pipParts[k] = p
		end

		local btnHolder, btnCap, btnColour
		btnHolder, btnCap, btnColour = UIKit.button(row, "", UDim2.fromOffset(178, 52),
			T.green, function()
				-- so the notes burst out of the button that was pressed rather than
				-- out of the middle of the screen
				CashFx.hintFrom(btnHolder.AbsolutePosition + btnHolder.AbsoluteSize * 0.5)
				local rem = Pack:FindFirstChild("Remotes")
				local ev = rem and rem:FindFirstChild("ClaimQuest")
				if ev then (ev :: RemoteEvent):FireServer(track.id) end
			end)
		btnHolder.AnchorPoint = Vector2.new(1, 1)
		btnHolder.Position = UDim2.new(1, -16, 1, -14)

		-- one recolour per state change, never per frame; see the dealership rows
		local shown: string? = nil
		local function refresh()
			local st = Quests.statusOf(self.plr, track)

			local function amount(n: number): string
				return if track.money then "$" .. Upgrades.short(n) else Upgrades.short(n)
			end

			if st.finished then
				goal.Text = "<font color=\"rgb(150,240,150)\">Every tier claimed</font>"
				fill.Size = UDim2.fromScale(1, 1)
				barText.Text = "DONE"
			else
				-- "Own 1 rigs" is the first tier of a track whose later tiers are all
				-- plural, so the unit is singularised at the point of use rather than
				-- the catalogue carrying two spellings of every noun
				local unit = track.unit
				if not track.money and st.target == 1 and unit:sub(-1) == "s" then
					unit = unit:sub(1, -2)
				end
				goal.Text = ("%s %s %s  \u{2022}  <font color=\"rgb(255,214,92)\">$%s</font>")
					:format(track.verb, amount(st.target or 0), unit,
						Upgrades.short(st.reward or 0))
				fill.Size = UDim2.fromScale(st.fraction, 1)
				barText.Text = ("%s / %s"):format(amount(math.min(st.have, st.target or 0)),
					amount(st.target or 0))
			end

			for k, p in ipairs(pipParts) do
				p.BackgroundColor3 = if k < st.tier then track.tint else T.navy
			end

			local state, text, tint
			if st.finished then
				state, text, tint = "done", "COMPLETE", T.slate
			elseif st.ready then
				state, text, tint = "ready", "CLAIM", T.green
			else
				state, tint = "busy", T.slate
				text = ("%d%%"):format(math.floor(st.fraction * 100))
			end
			if btnCap.Text ~= text then btnCap.Text = text end
			if state ~= shown then
				shown = state
				btnColour(tint)
			end
		end

		refresh()
		table.insert(self.questRows, refresh)
	end

	self:_register("Rewards", holder, size)
end

--==[ shop ]==================================================================

--[[
	THE SHOP IS A TABBED BOARD OF CARDS, not a column of rows (rebuilt 2026-08-12
	against two reference shots the owner supplied, both of the chunky-cartoon
	Roblox house style).

	What the references actually specify, and what each thing became here:

	  a title bar with a close cross   -> UIKit.panel already draws exactly this,
	                                      so the silhouette is unchanged
	  a row of category tabs           -> the strip below, built from what is
	                                      genuinely for sale rather than from the
	                                      three tabs in the picture
	  a LIMITED TIME! banner, full     -> the boosts, which are the only timed
	    width, prices along it            thing in the game -- see wideCard
	  a grid of product cards, each     -> gridCard, and the green pill IS the buy
	    with a GREEN price pill           button, which is the load-bearing idea
	                                      lifted from both shots

	THE GREEN PILL IS THE WHOLE POINT. The old shop had a BUY button on the right
	of every row and the price inside it, which meant the price was the least
	prominent thing on a card selling something. In the references the price is the
	brightest object on the tile and it is also the thing you press. That is the
	change; everything else here is layout serving it.

	TWO TABS, NOT THREE, and that is deliberate. The second reference has
	GAMEPASS / CASH / BOOSTS, and this game has no cash products at all -- there is
	nothing behind a CASH tab but a lie. A tab is added by putting a category in
	TABS below and giving its entries an `order`; nothing else here needs to know.

	COLOURS ARE OURS, NOT THE REFERENCE'S. The shots are orange/green/red on white;
	this HUD is blue panels, cream text, gold accents, and every other window in the
	game already reads that way. So the tabs take the tint of what they sell (gold
	for the permanent things, purple for the timed one, which is the colour boosts
	have worn since they shipped), the pills take T.green because that is this
	kit's "press me", and the cards keep the per-item tints the old shop already
	taught players to read.
]]
function Shell:_buildShop()
	return require(Pack:WaitForChild("AuthoredShop")).mount(self)
end

--==[ settings ]==============================================================

function Shell:_buildSettings()
	local size = UDim2.fromScale(0.4, 0.66)
	local holder, content, root = UIKit.panel(self.gui, size, UDim2.fromScale(0.5, 0.5), "Settings", T.blue)
	UIKit.closeButton(root, function() self:close() end)
	local list = UIKit.scroller(content, 10)

	local Lighting = game:GetService("Lighting")
	local plr = self.plr

	local function num(attr: string, dflt: number): number
		local v = plr:GetAttribute(attr)
		return if type(v) == "number" then v else dflt
	end

	--==[ sound ]=============================================================

	local saveSetting = (function()
		local r = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
		r = r and r:FindFirstChild("SaveSetting")
		return r
	end)()
	local function set(key: string, value: any)
		plr:SetAttribute(key, value)
		-- the panel still works with no remote; the choice simply does not persist
		if saveSetting then (saveSetting :: RemoteEvent):FireServer(key, value) end
	end

	UIKit.slider(list, "Music Volume", num("Set_Music", 0.6), function(v)
		set("Set_Music", v)
	end).LayoutOrder = 1
	UIKit.slider(list, "Sound Effects", num("Set_Sfx", 0.8), function(v)
		set("Set_Sfx", v)
	end).LayoutOrder = 2

	--==[ quality ]===========================================================

	UIKit.toggle(list, "3D Sealer Surface", plr:GetAttribute("Set_Sheet") == true, function(on)
		set("Set_Sheet", on)
	end, "Higher quality \u{2014} may cause lag on weaker devices").LayoutOrder = 3

	UIKit.toggle(list, "Shadows", plr:GetAttribute("Set_Shadows") == true, function(on)
		set("Set_Shadows", on)
		Lighting.GlobalShadows = on
	end).LayoutOrder = 4

	-- Bloom and sun rays: cheaper than the two above and the least missed, so they
	-- come last. Started from whether any of them is actually enabled right now.
	local function fancyOn(): boolean
		for _, fx in ipairs(Lighting:GetChildren()) do
			if (fx:IsA("BloomEffect") or fx:IsA("SunRaysEffect")) and (fx :: any).Enabled then
				return true
			end
		end
		return false
	end
	UIKit.toggle(list, "Fancy Lighting", fancyOn(), function(on)
		set("Set_Fancy", on)
		for _, fx in ipairs(Lighting:GetChildren()) do
			if fx:IsA("BloomEffect") or fx:IsA("SunRaysEffect") then (fx :: any).Enabled = on end
		end
	end).LayoutOrder = 5

	UIKit.button(list, "Send Feedback", UDim2.new(1, -8, 0, 52), T.gold, function()
		self:toggle("Feedback")
	end).LayoutOrder = 6

	local replayBusy = false
	local replayHolder, replayCap = UIKit.button(list, "Replay Tutorial",
		UDim2.new(1, -8, 0, 52), T.purple, nil)
	replayHolder.LayoutOrder = 7
	replayCap.Activated:Connect(function()
		-- InvokeServer yields; a second click inside that yield would fire the reset
		-- twice and the second one would re-arm a replay the first had spent
		if replayBusy then return end
		replayBusy = true
		replayCap.Text = "Resetting..."
		task.spawn(function()
			local remotes = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
			local fn = remotes and remotes:FindFirstChild("ReplayTutorial")
			local ok, done, message = pcall(function()
				return (fn :: RemoteFunction):InvokeServer()
			end)
			replayBusy = false
			replayCap.Text = "Replay Tutorial"
			if not ok then
				self:Toast("Could not reset the tutorial", false)
				return
			end
			self:Toast(message or "Tutorial reset", done == true)
		end)
	end)

	self:_register("Settings", holder, size)
end

--==[ feedback ]==============================================================

function Shell:_buildFeedback()
	local size = UDim2.fromScale(0.46, 0.5)
	local holder, content, root = UIKit.panel(self.gui, size, UDim2.fromScale(0.5, 0.5),
		"Feedback", T.gold)
	UIKit.closeButton(root, function() self:close() end)

	local blurb = UIKit.label(content, "Tell us what you think \u{2014} bugs, ideas, anything.",
		20, T.cream)
	blurb.Position = UDim2.fromOffset(14, 8)
	blurb.Size = UDim2.new(1, -28, 0, 26)
	blurb.TextWrapped = true

	local box = Instance.new("TextBox")
	box.Name = "Entry"
	box.Position = UDim2.fromOffset(14, 42)
	box.Size = UDim2.new(1, -28, 1, -128)
	box.BackgroundColor3 = UIKit.deepen(T.panel, 0.45)
	box.BorderSizePixel = 0
	box.Font = UIKit.Font
	box.TextSize = 20
	box.TextColor3 = T.white
	box.PlaceholderText = "Type your feedback here..."
	box.Text = ""
	box.ClearTextOnFocus = false
	box.MultiLine = true
	box.TextWrapped = true
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.ZIndex = 6
	box.Parent = content
	UIKit.corner(box, 10)
	UIKit.stroke(box, 2.2)

	-- Matches FeedbackService's own cap. The server re-checks and truncates; this
	-- is here so nobody types a paragraph that gets silently cut in half.
	local MAX_CHARS = 400
	local count = UIKit.label(content, "", 18, T.cream)
	count.AnchorPoint = Vector2.new(1, 1)
	count.Position = UDim2.new(1, -14, 1, -62)
	count.Size = UDim2.fromOffset(120, 22)
	count.TextXAlignment = Enum.TextXAlignment.Right

	local sending = false
	local sendHolder, sendCap = UIKit.button(content, "Send",
		UDim2.new(1, -28, 0, 46), T.green)
	sendHolder.AnchorPoint = Vector2.new(0, 1)
	sendHolder.Position = UDim2.new(0, 14, 1, -8)

	local function refresh()
		local n = #box.Text
		count.Text = ("%d / %d"):format(n, MAX_CHARS)
		-- red once they are over, so the truncation is not a surprise
		count.TextColor3 = if n > MAX_CHARS then T.red else T.cream
	end
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if #box.Text > MAX_CHARS then box.Text = box.Text:sub(1, MAX_CHARS) end
		refresh()
	end)
	refresh()

	sendCap.Activated:Connect(function()
		-- one in flight at a time: InvokeServer yields, and a second click during that
		-- yield would post the same text twice
		if sending then return end
		local body = box.Text
		if #(body:gsub("%s", "")) == 0 then
			self:Toast("Type something first", false)
			return
		end
		sending = true
		sendCap.Text = "Sending..."
		task.spawn(function()
			local remotes = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
			local fn = remotes and remotes:FindFirstChild("SendFeedback")
			local ctx: { [string]: any } = {
				-- averaged over a handful of frames: a single delta is whatever that one
				-- frame happened to cost, which for a lag report is the wrong number
				frameRate = (function()
					local total, n = 0, 8
					for _ = 1, n do total += RunService.RenderStepped:Wait() end
					return if total > 0 then math.round(n / total) else nil
				end)(),
				-- the switch the server cannot see. `== true` matches how DrivewayClient
				-- reads it: unset means off.
				sealerSurface3D = self.plr:GetAttribute("Set_Sheet") == true,
				touchScreen = UserInputService.TouchEnabled,

				device = (function()
					local okTen, ten = pcall(function()
						return GuiService:IsTenFootInterface()
					end)
					if okTen and ten then return "Console" end
					local touch = UserInputService.TouchEnabled
					local keys = UserInputService.KeyboardEnabled
					local cam = workspace.CurrentCamera
					local wide = cam and cam.ViewportSize.X or 0
					if touch and not keys then
						return if wide >= 900 then "Tablet" else "Phone"
					end
					if touch and keys then return "Hybrid" end
					return "Desktop"
				end)(),
				-- the raw width behind that guess, so a wrong `device` can still be read past
				screenWidth = (function()
					local cam = workspace.CurrentCamera
					return if cam then math.round(cam.ViewportSize.X) else nil
				end)(),
				--[[
					Arguably the most useful number here. A device under memory pressure
					stutters, and that correlates with what a player calls "laggy" far more
					directly than the name of their hardware does.
				]]
				memoryMb = (function()
					local okm, m = pcall(function()
						return game:GetService("Stats"):GetTotalMemoryUsageMb()
					end)
					return if okm then math.round(m) else nil
				end)(),
				qualityLevel = (function()
					local okq, q = pcall(function()
						return UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
					end)
					return if okq then q else nil
				end)(),
			}
			local ok, sent, message = pcall(function()
				return (fn :: RemoteFunction):InvokeServer(body, ctx)
			end)
			sending = false
			sendCap.Text = "Send"
			if not ok then
				self:Toast("Could not send -- try again", false)
				return
			end
			self:Toast(message or (if sent then "Sent" else "Could not send"), sent == true)
			-- cleared only on success, so a failed send does not cost them the typing
			if sent then box.Text = "" end
		end)
	end)

	self:_register("Feedback", holder, size)
end

--==[ toasts ]================================================================

function Shell:_buildToasts()
	local holder = Instance.new("Frame")
	holder.Name = "Toasts"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.new(0.5, 0, 0, 24)
	holder.Size = UDim2.fromOffset(560, 200)
	holder.Parent = self.gui

	fitBlock(holder)

	TopBand.claim("Toasts", TopBand.Rank.Toasts, holder, 0)
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 8)
	l.HorizontalAlignment = Enum.HorizontalAlignment.Center
	l.Parent = holder
	self.toasts = holder
end

function Shell:Toast(text: string, good: boolean?)
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(0, 46)
	card.AutomaticSize = Enum.AutomaticSize.X
	card.BackgroundColor3 = (good == false) and T.red or T.green
	card.BorderSizePixel = 0
	card.ZIndex = 30
	card.Parent = self.toasts
	UIKit.corner(card, 13)
	UIKit.stroke(card, 2.4)
	UIKit.gradient(card)
	UIKit.gloss(card, 4, 9, 0.44).ZIndex = 30
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 18); pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = card
	-- a tick or a cross reads before the sentence does, which is the whole job of
	-- a message that is on screen for two seconds
	local mark = if good == false then "\u{2716}  " else "\u{2714}  "
	local l = UIKit.outlined(card, mark .. text, 20, T.white, 2.4)
	l.AutomaticSize = Enum.AutomaticSize.X
	l.Size = UDim2.new(0, 0, 1, 0)
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.ZIndex = 31

	task.delay(2.4, function()
		if card.Parent then
			TweenService:Create(card, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(l, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
			task.wait(0.28)
			card:Destroy()
		end
	end)
end

--==[ the call to rebirth ]===================================================

function Shell:_buildPrompt()
	local container, body = UIKit.shadowed(self.gui, UDim2.fromOffset(620, 300),
		UDim2.fromScale(0.5, 0.42), Vector2.new(0.5, 0.5), 22, 9)
	container.Name = "Prompt"
	container.Visible = false
	container.ZIndex = 40

	fitBlock(container)
	body.BackgroundColor3 = T.teal
	UIKit.stroke(body, 3)
	UIKit.gradient(body, 0.9)
	UIKit.gloss(body, 8, 18, 0.30).ZIndex = 5
	UIKit.vignette(body, 22, 90, 0.22)

	local title = UIKit.outlined(body, "", 30, T.cream, 3)
	title.Position = UDim2.fromOffset(28, 22)
	title.Size = UDim2.new(1, -56, 0, 38)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 6

	local blurb = UIKit.label(body, "", 19, T.white)
	blurb.Position = UDim2.fromOffset(38, 70)
	blurb.Size = UDim2.new(1, -76, 0, 140)
	blurb.TextWrapped = true
	blurb.TextXAlignment = Enum.TextXAlignment.Center
	blurb.TextYAlignment = Enum.TextYAlignment.Top
	blurb.ZIndex = 6

	local function dismiss()
		container.Visible = false
		if Console.active() then GuiService.SelectedObject = nil end
	end

	local go = UIKit.button(body, "REBIRTH", UDim2.fromOffset(272, 58), T.gold, function()
		dismiss()
		if self.open ~= "Rebirth" then self:toggle("Rebirth") end
	end)
	go.AnchorPoint = Vector2.new(1, 1)
	go.Position = UDim2.new(0.5, -8, 1, -24)

	local later = UIKit.button(body, "NOT YET", UDim2.fromOffset(172, 58), T.slate, dismiss)
	later.AnchorPoint = Vector2.new(0, 1)
	later.Position = UDim2.new(0.5, 8, 1, -24)

	self.prompt = container
	self.promptShow = function(head: string, text: string)
		title.Text = head
		blurb.Text = text
		container.Visible = true
		Console.focus(container)
	end
	self.promptHide = dismiss
end

function Shell:_watchSections()
	local plr = self.plr

	for _, s in ipairs(Sections.List) do
		local need = Sections.requiresOf(s)
		if need <= 0 then continue end

		local armed, shown = false, false
		local function badge(on: boolean)
			local nub = self.nubs and self.nubs.Rebirth
			if nub and nub.Visible ~= on then nub.Visible = on end
		end

		local function check()
			if plr:GetAttribute(Sections.openAttr(s.id)) == true then
				badge(false)
				return
			end

			local done = (plr:GetAttribute(Sections.doneAttr(s.id)) :: number?) or 0
			local total = (plr:GetAttribute(Sections.totalAttr(s.id)) :: number?)
				or #Sections.slabsOf(s)
			if not (total > 0 and done >= total) then
				if plr:GetAttribute("ProfileLoaded") then armed = true end
				badge(false)
				return
			end
			if Rebirth.countOf(plr) >= need then
				badge(false)
				return
			end

			badge(true)
			if shown or not armed then return end
			shown = true
			self.promptShow("THE ROAD IS DONE",
				("Every driveway in %s is sealed, and sealed it stays -- there is no more"
					.. " work here until you rebirth.\n\nRebirthing hands the whole map back"
					.. " to be sealed again, pays you a permanent bonus on every job from now"
					.. " on, and opens the road."):format(Sections.nameOf(s)))
		end

		plr:GetAttributeChangedSignal(Sections.doneAttr(s.id)):Connect(check)
		plr:GetAttributeChangedSignal(Sections.totalAttr(s.id)):Connect(check)
		plr:GetAttributeChangedSignal(Sections.openAttr(s.id)):Connect(check)
		plr:GetAttributeChangedSignal(Rebirth.Attr):Connect(check)
		plr:GetAttributeChangedSignal("ProfileLoaded"):Connect(check)
		check()
	end
end

return Shell

