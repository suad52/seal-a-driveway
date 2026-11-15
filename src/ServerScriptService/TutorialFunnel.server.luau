--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AnalyticsService = game:GetService("AnalyticsService")

local STEP_NAMES: { [number]: string } = {
	[1] = "Started",
	[2] = "ReachedDriveway",
	[3] = "PouredOut",
	[4] = "FirstPass",
	[5] = "DrivewaySealed",
	[6] = "Complete",
}

local CLIENT_TOP = 4

local sealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local remotes = sealerUI:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = sealerUI
end

local stepRemote = remotes:FindFirstChild("TutorialStep")
if not stepRemote then
	stepRemote = Instance.new("RemoteEvent")
	stepRemote.Name = "TutorialStep"
	stepRemote.Parent = remotes
end

local sent: { [Player]: { [number]: boolean } } = {}
local finishedOnArrival: { [Player]: boolean } = {}

Players.PlayerRemoving:Connect(function(plr)
	sent[plr] = nil
	finishedOnArrival[plr] = nil
end)

local function report(plr: Player, n: number)
	local name = STEP_NAMES[n]
	if not name then return end
	if finishedOnArrival[plr] then return end

	local mine = sent[plr]
	if not mine then
		mine = {}
		sent[plr] = mine
	end
	if mine[n] then return end

	mine[n] = true

	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(plr, n, name)
	end)

	if not ok then
		mine[n] = false
		warn(("[TutorialFunnel] %s step %d (%s) failed: %s")
			:format(plr.Name, n, name, tostring(err)))
	elseif RunService:IsStudio() then
		print(("[TutorialFunnel] %s -> %d %s (Studio: not recorded)")
			:format(plr.Name, n, name))
	end
end

(stepRemote :: RemoteEvent).OnServerEvent:Connect(function(plr, n)
	if type(n) ~= "number" or n ~= n then return end

	local step = math.floor(n)
	if step < 1 or step > CLIENT_TOP then return end

	report(plr, step)
end)

local function bind(plr: Player)
	task.spawn(function()
		local t0 = os.clock()
		while plr.Parent
			and plr:GetAttribute("ProfileLoaded") ~= true
			and os.clock() - t0 < 20 do
			task.wait(0.2)
		end

		if not plr.Parent then return end
		if plr:GetAttribute("ProfileLoaded") ~= true then return end

		finishedOnArrival[plr] =
			plr:GetAttribute("TutorialDone") == true
			or plr:GetAttribute("DepotSealed") == true

		local function look()
			if finishedOnArrival[plr] then return end
			if plr:GetAttribute("TutSealed") == true then
				report(plr, 5)
			end
			if plr:GetAttribute("TutorialDone") == true then
				report(plr, 6)
			end
		end

		plr:GetAttributeChangedSignal("TutSealed"):Connect(look)
		plr:GetAttributeChangedSignal("TutorialDone"):Connect(look)
		look()
	end)
end

Players.PlayerAdded:Connect(bind)
for _, plr in ipairs(Players:GetPlayers()) do
	bind(plr)
end

if RunService:IsStudio() then
	print("[TutorialFunnel] ready -- 6 steps, 1..4 from the client, 5..6 from here")
end
