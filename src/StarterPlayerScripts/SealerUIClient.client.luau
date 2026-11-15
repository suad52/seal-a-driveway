--[[
	SealerUIClient -- mounts the shell and turns upgrade levels into real effects.

	The sealing simulation runs on this client and reads Config live, so the
	cleanest place to apply an upgrade is Config itself: the client's own copy of
	the module is mutated and every system downstream picks it up on the next
	frame with no changes to DrivewayClient at all.

	The untouched values are captured once at load, so effects are always computed
	from the base rather than compounding each time a level changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Pack = ReplicatedStorage:WaitForChild("SealerUI")
local Shell = require(Pack:WaitForChild("Shell"))
local UIKit = require(Pack:WaitForChild("UIKit"))
local Upgrades = require(Pack:WaitForChild("Upgrades"))
local Passes = require(Pack:WaitForChild("Passes"))
local Config = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Config"))
-- only for setBladeWidth: how wide a squeegee is DRAWN is the tool's business,
-- and RemoteToolsClient has to agree with this file about it
local ToolBuilder = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("ToolBuilder"))

local plr = Players.LocalPlayer
local playerGui = plr:WaitForChild("PlayerGui")
local shell = Shell.mount(playerGui)
local theme = UIKit.Theme

local notificationGui = playerGui:FindFirstChild("SpinNotificationOverlay")
if not notificationGui or not notificationGui:IsA("ScreenGui") then
	notificationGui = Instance.new("ScreenGui")
	notificationGui.Name = "SpinNotificationOverlay"
	notificationGui.ResetOnSpawn = false
	notificationGui.IgnoreGuiInset = false
	notificationGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	notificationGui.Parent = playerGui
end
notificationGui.DisplayOrder = 999

local notificationHolder = notificationGui:FindFirstChild("Notifications")
if not notificationHolder or not notificationHolder:IsA("Frame") then
	notificationHolder = Instance.new("Frame")
	notificationHolder.Name = "Notifications"
	notificationHolder.AnchorPoint = Vector2.new(0.5, 0)
	notificationHolder.Position = UDim2.new(0.5, 0, 0, 24)
	notificationHolder.Size = UDim2.fromOffset(560, 220)
	notificationHolder.BackgroundTransparency = 1
	notificationHolder.Parent = notificationGui
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = notificationHolder
end

local function showSpinNotification(text: string, good: boolean)
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(0, 46)
	card.AutomaticSize = Enum.AutomaticSize.X
	card.BackgroundColor3 = (good == false) and theme.red or theme.green
	card.BorderSizePixel = 0
	card.ZIndex = 30
	card.Parent = notificationHolder
	UIKit.corner(card, 13)
	UIKit.stroke(card, 2.4)
	UIKit.gradient(card)
	UIKit.gloss(card, 4, 9, 0.44).ZIndex = 30
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = card
	local mark = if good == false then "\u{2716}  " else "\u{2714}  "
	local label = UIKit.outlined(card, mark .. text, 20, theme.white, 2.4)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.new(0, 0, 1, 0)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.ZIndex = 31
	task.delay(2.4, function()
		if not card.Parent then return end
		TweenService:Create(card, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(label, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
		task.wait(0.28)
		card:Destroy()
	end)
end

--==[ spin wheel ]============================================================

task.spawn(function()
	local playerGui = plr:WaitForChild("PlayerGui")
	local spinGui = playerGui:WaitForChild("Spin")
	if not spinGui then return end
	local button = spinGui:FindFirstChild("SpinWheel", true)
	local window = spinGui:FindFirstChild("SpinWheelFrame", true)
	if not button or not button:IsA("TextButton") or not window or not window:IsA("Frame") then return end
	local spinner = window:FindFirstChild("Spinner", true)
	local open = window:FindFirstChild("Frame")
	local amount = spinGui:FindFirstChild("SpinAmount", true)
	local timer = spinGui:FindFirstChild("TimerUntilFree", true)
	if not spinner or not spinner:IsA("ImageLabel") or not open or not open:IsA("Frame") then return end
	local spinButton = open:FindFirstChild("Spin", true)
	local buy3 = open:FindFirstChild("Buy3", true)
	local buy10 = open:FindFirstChild("Buy10", true)
	local closeFrame = open:FindFirstChild("CloseFrame", true)
	local close = closeFrame and closeFrame:FindFirstChild("Button", true)
	if not spinButton or not spinButton:IsA("TextButton") then return end
	local spinTitle = spinButton:FindFirstChild("Title", true)
	local freeSpinTimer = spinButton:FindFirstChild("FreeSpinTimer", true)

	local remoteFolder = ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Remotes")
	local remote = remoteFolder:WaitForChild("SpinWheel") :: RemoteEvent
	local busy = false
	local idleToken = 0
	local idleTween: Tween?

	local function setLabel(root: Instance?, text: string)
		if root and root:IsA("TextLabel") then root.Text = text end
	end

	local function refresh()
		setLabel(amount, tostring((plr:GetAttribute("SpinCount") :: number?) or 0))
		local nextAt = plr:GetAttribute("SpinNextFreeAt")
		local left = if type(nextAt) == "number"
			then math.max(0, math.ceil(nextAt - workspace:GetServerTimeNow())) else 0
		local hours = math.floor(left / 3600)
		local minutes = math.floor(left % 3600 / 60)
		local seconds = left % 60
		setLabel(timer, string.format("%02d:%02d:%02d", hours, minutes, seconds))
		setLabel(freeSpinTimer, string.format("+1 free spin in %02d:%02d", minutes, seconds))
		setLabel(spinTitle, ("SPIN (x%d)"):format((plr:GetAttribute("SpinCount") :: number?) or 0))
	end

	local function stopIdle()
		idleToken += 1
		if idleTween then idleTween:Cancel(); idleTween = nil end
	end

	local function startIdle()
		stopIdle()
		local token = idleToken
		task.spawn(function()
			while window.Visible and token == idleToken and not busy do
				local tween = TweenService:Create(spinner, TweenInfo.new(18, Enum.EasingStyle.Linear),
					{ Rotation = spinner.Rotation + 360 })
				idleTween = tween;tween:Play();tween.Completed:Wait()
			end
		end)
	end

	local function playWinSounds()
		for name, asset in pairs({ PartyHorn = "rbxassetid://6161421479", Purchased = "rbxassetid://104644728934074" }) do
			local sound = Instance.new("Sound")
			sound.Name = name;sound.SoundId = asset;sound.Volume = 0.8;sound.Parent = playerGui
			sound:Play();sound.Ended:Connect(function() sound:Destroy() end)
		end
	end

	button.Activated:Connect(function() 
		window.Visible = true 
	end)
	close.Activated:Connect(function() 
		window.Visible = false 
	end)

	window:GetPropertyChangedSignal("Visible"):Connect(function()
		if window.Visible then startIdle() else stopIdle() end
	end)
	
	spinButton.Activated:Connect(function()
		if busy or ((plr:GetAttribute("SpinCount") :: number?) or 0) <= 0 then 
			return
		end
		busy = true
		stopIdle()
		remote:FireServer("Spin")
	end)

	buy3.Activated:Connect(function()
		remote:FireServer("Buy", 3)
	end)

	buy10.Activated:Connect(function() 
		remote:FireServer("Buy", 10)
	end)
	
	plr:GetAttributeChangedSignal("SpinCount"):Connect(refresh)
	plr:GetAttributeChangedSignal("SpinNextFreeAt"):Connect(refresh)
	
	task.spawn(function()
		while spinGui.Parent do 
			refresh()
			task.wait(1) 
		end
	end)

	remote.OnClientEvent:Connect(function(action, a, b, c)
		if action == "Reward" then
			local target = (spinner.Rotation // 360) * 360 + (tonumber(b) - 1 or 0) * (-60)
			if target <= spinner.Rotation then
				target += 360
			end
			local tween = TweenService:Create(spinner, TweenInfo.new(4, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ Rotation = target + 4 * 360 })
			tween:Play()
			tween.Completed:Wait()
			playWinSounds()
			showSpinNotification("You got " .. tostring(c) .. "!", true)
			busy = false
			if window.Visible then 
				startIdle()
			end
		elseif action == "FreeSpin" then
			showSpinNotification("You received a free spin!", true)
			refresh()
		elseif action == "Purchased" then
			showSpinNotification(("You bought %sx spins!"):format(tostring(a)), true)
			refresh()
		elseif action == "Message" then
			showSpinNotification(tostring(a), false)
			busy = false
			if window.Visible then startIdle() end
		end
	end)
	refresh()
end)

task.spawn(function()
	local old = plr.PlayerGui:WaitForChild("DrivewaySealerHUD", 20)
	if old then (old :: ScreenGui).Enabled = false end
end)

pcall(function()
	game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

local BASE = {
	bucket = Config.BucketCapacity,
	pour   = Config.PourRate,
	dump   = Config.PourDump,
	blade  = Config.BladeHalfLen,
	wand   = Config.WandRate,
	refill = Config.BucketRefill,
}

local BASE_FILL = BASE.bucket / BASE.refill
local TANK_BASE_L = Upgrades.valueAt("Tank", 1)
local TUT_DONE_FLAGS = { "TutSealed", "TutorialDone", "DepotSealed" }

local function onStockGear(): boolean
	-- nothing is forced until the profile has landed; see above
	if not plr:GetAttribute("ProfileLoaded") then return false end
	if plr:GetAttribute("TutReplay") == true then return true end
	for _, flag in ipairs(TUT_DONE_FLAGS) do
		if plr:GetAttribute(flag) == true then return false end
	end
	return true
end

local function level(id: string): number
	if onStockGear() then return 1 end
	return plr:GetAttribute("Upg_" .. id) :: number or 1
end

local function applyAll()
	local tankL  = Upgrades.valueAt("Tank", level("Tank"))
	local pour   = Upgrades.valueAt("Pour", level("Pour"))
	local width  = Upgrades.valueAt("Blade", level("Blade"))
	local speed  = Upgrades.valueAt("Speed", level("Speed"))
	local refill = Upgrades.valueAt("Refill", level("Refill"))

	-- Capacity is a straight ratio against the stock bucket now. The Sealing
	-- Efficiency track used to multiply in here as well, which is exactly why it
	-- was cut: to a simulation whose only unit is coat-studs, "each litre covers
	-- more" and "the tank holds more litres" were the same number twice.
	Config.BucketCapacity = BASE.bucket * (tankL / TANK_BASE_L)
	Config.PourRate = BASE.pour * pour

	Config.PourDump = BASE.dump * pour
	-- The wand is a pour too, so the Pour track drives it as well. It is
	-- deliberately still a HOSE -- it meters nothing and locks nothing -- because it
	-- is bought with a truck, by players who learned the puddle a hundred driveways
	-- ago, and reach rather than rate is what it is for. Its radius is fixed: with
	-- the fan gone there is no width to keep in step with the blade any more.
	Config.WandRate = BASE.wand * pour
	Config.BladeHalfLen = width * 0.5

	local fillSeconds = BASE_FILL / refill
	Config.BucketRefill = Config.BucketCapacity / fillSeconds

	-- VIP rides the Walk Speed ladder rather than replacing it, so a VIP who has
	-- also bought the track is still faster than one who has not.
	speed *= Passes.walkMultiplier(plr)

	-- The equipped pet's bonuses (PetService writes these; 1 with no pet on).
	-- Capacity is scaled with the tank rather than after it, so the fill-time
	-- arithmetic below stays a single ratio all the way down.
	local petCapacity = (plr:GetAttribute("Pet_CapacityMult") :: number?) or 1
	local petSpeed = (plr:GetAttribute("Pet_SpeedMult") :: number?) or 1
	tankL *= petCapacity
	speed *= petSpeed

	local ch = plr.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if hum then hum.WalkSpeed = speed end

	-- Publish what was actually applied. The HUD can show effective stats from
	-- this, and it is the only way to observe the result from outside: Config is
	-- a module table, so anything that requires it from another context gets its
	-- own copy and would read stale numbers.
	plr:SetAttribute("Eff_TankLitres", tankL)
	plr:SetAttribute("Eff_Capacity", Config.BucketCapacity)
	plr:SetAttribute("Eff_PourRate", Config.PourRate)
	plr:SetAttribute("Eff_PourDump", Config.PourDump)
	plr:SetAttribute("Eff_BladeWidth", Config.BladeHalfLen * 2)
	plr:SetAttribute("Eff_WalkSpeed", speed)
	plr:SetAttribute("Eff_RefillSeconds", fillSeconds)

	for _, where in ipairs({ ch, plr:FindFirstChildOfClass("Backpack") }) do
		if where then
			for _, tool in ipairs(where:GetChildren()) do
				if tool:IsA("Tool") and tool:GetAttribute("SealerTool") == "Squeegee" then
					ToolBuilder.setBladeWidth(tool:FindFirstChild("Rig"), width)
				end
			end
		end
	end
end

for _, t in ipairs(Upgrades.Tracks) do
	plr:GetAttributeChangedSignal("Upg_" .. t.id):Connect(applyAll)
end
-- VIP multiplies walk speed, and PassService answers a second or two into the
-- session -- so the effects have to be re-applied when the answer lands, not
-- only when a ladder level moves. Buying it mid-session takes the same path.
plr:GetAttributeChangedSignal(Passes.attrName("VIP")):Connect(applyAll)

for _, flag in ipairs({ "ProfileLoaded", "TutReplay", "TutSealed", "TutorialDone",
	"DepotSealed", "Pet_CapacityMult", "Pet_SpeedMult" }) do
	plr:GetAttributeChangedSignal(flag):Connect(applyAll)
end
-- Re-apply when the squeegee SKIN changes. Skins are dressed on the SERVER, so
-- the inlay parts (SkinEdge, SkinInlayFront, etc.) arrive at the server's blade
-- width (6.4) regardless of the local player's upgrade level. setBladeWidth
-- resizes them to match, but only runs if we ask. The delay lets the new parts
-- replicate before we size them.
plr:GetAttributeChangedSignal("Skin_Squeegee"):Connect(function()
	task.wait(0.3)
	applyAll()
end)
plr.CharacterAdded:Connect(function()
	task.wait(0.4)
	applyAll()
end)
local function watch(ch: Model)
	ch.ChildAdded:Connect(function(c)
		if c:IsA("Tool") then task.wait(0.1); applyAll() end
	end)

	ch.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") and d:GetAttribute("SkinFollowsWidth") then
			applyAll()
		end
	end)
end
if plr.Character then watch(plr.Character) end
plr.CharacterAdded:Connect(watch)
applyAll()

--==[ purchase feedback ]=====================================================

task.spawn(function()
	local remotes = Pack:WaitForChild("Remotes", 20)
	if not remotes then return end
	local result = remotes:WaitForChild("BuyResult", 10)
	if not result then return end
	(result :: RemoteEvent).OnClientEvent:Connect(function(_, ok, message, reason)
		shell:Toast(tostring(message), ok and true or false)

		if not ok and reason == "InsufficientCash" then
			shell:openShopTab("Cash")
		end
	end)
end)

--==[ the showroom desk opens the buy screen ]================================

task.spawn(function()
	local bound: Instance? = nil
	local function hook(d: Instance)
		if d:IsA("ProximityPrompt") and string.find(d.Name, "DealershipPrompt", 1, true) then
			d.Triggered:Connect(function()
				if shell.open ~= "Dealership" then shell:toggle("Dealership") end
			end)
		end
	end
	local function bind(hall: Instance)
		if hall == bound then return end
		bound = hall
		for _, d in ipairs(hall:GetDescendants()) do hook(d) end
		hall.DescendantAdded:Connect(hook)
	end
	local found = workspace:FindFirstChild("RigDealership")
	if found then bind(found) end
	-- and again for any that replaces it, which is what the server's fallback does
	workspace.ChildAdded:Connect(function(c)
		if c.Name == "RigDealership" then bind(c) end
	end)
end)

--==[ the bay console opens the rig picker ]==================================

task.spawn(function()
	local storePrompts: { ProximityPrompt } = {}

	local function refreshStore()
		local out = false
		for _, m in ipairs(workspace:GetChildren()) do
			if m:GetAttribute("OwnerUserId") == plr.UserId then out = true break end
		end
		for _, p in ipairs(storePrompts) do
			if p.Parent and p.Enabled ~= out then p.Enabled = out end
		end
	end

	local function hook(d: Instance)
		if not d:IsA("ProximityPrompt") then return end
		if d.Name == "RigBayPrompt" then
			d.Triggered:Connect(function()
				if shell.open ~= "RigBay" then shell:toggle("RigBay") end
			end)
		elseif d.Name == "RigStorePrompt" then
			table.insert(storePrompts, d)
			refreshStore()
		end
	end
	local bound: Instance? = nil
	local function bind(console: Instance)
		if console == bound then return end
		bound = console
		for _, d in ipairs(console:GetDescendants()) do hook(d) end
		console.DescendantAdded:Connect(hook)
	end
	local found = workspace:FindFirstChild("RigSpawner")
	if found then bind(found) end
	workspace.ChildAdded:Connect(function(c)
		if c.Name == "RigSpawner" then bind(c) end
		refreshStore()
	end)
	-- a stored rig is a destroyed model, which arrives here as a child going away
	workspace.ChildRemoved:Connect(refreshStore)
	refreshStore()
end)

--==[ the upgrade counter in the store ]======================================

task.spawn(function()
	local function isShopPrompt(d: Instance): boolean
		return d:IsA("ProximityPrompt")
			and d.Name == "ShopPrompt"
			and d:FindFirstAncestor("ShopTerminal") ~= nil
	end

	local hooked: { [Instance]: boolean } = {}
	local seen = false

	local function hook(d: Instance)
		if not isShopPrompt(d) or hooked[d] then return end
		hooked[d] = true
		seen = true
		d.Destroying:Connect(function() hooked[d] = nil end)

		d.Triggered:Connect(function()
			-- The one remaining way this can look dead: the panel never got built, so
			-- toggle returns without a word. Say it rather than swallow it.
			if not shell.panels["Upgrades"] then
				warn("[SealerUIClient] the counter terminal fired but the Upgrades panel"
					.. " does not exist -- Shell:_buildUpgrades did not register it")
				return
			end
			shell:toggle("Upgrades")
		end)
	end

	for _, d in ipairs(workspace:GetDescendants()) do hook(d) end
	workspace.DescendantAdded:Connect(hook)

	-- And if it never turns up at all, say THAT too. Twenty seconds is well past
	-- any streaming-in of the depot from a spawn 47 studs away.
	task.delay(20, function()
		if not seen then
			warn("[SealerUIClient] no ShopPrompt found under a ShopTerminal after 20s"
				.. " -- the upgrade counter will do nothing when pressed")
		end
	end)
end)

local function syncRailLock()
	if plr:GetAttribute("TutorialDone") then
		shell:LockRail("Upgrades", nil)
		shell:LockRail("Daily", nil)
	else
		shell:LockRail("Upgrades", "The upgrade counter is inside the store")
		shell:LockRail("Daily", "Finish the tutorial and the day book opens")
	end
end
syncRailLock()
plr:GetAttributeChangedSignal("TutorialDone"):Connect(syncRailLock)

--==[ escape closes whatever is open ]========================================

game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape then shell:close() end
end)

game:GetService("ProximityPromptService").PromptTriggered:Connect(function(prompt,who)
	if who==plr and prompt:GetAttribute("ExtraRefuelShop")==true then
		if shell.open~="Dealership" then shell:toggle("Dealership") end
	end
end)
