--!strict
--[[
	RaceNet -- the event's RemoteEvents, and the only place they are named.

	The SERVER creates them and the client waits for them, which is the one
	ordering that works under every load order: a client that reaches this module
	before the server script has run yields on WaitForChild instead of building
	its own orphan copies in ReplicatedStorage, where the server would never hear
	them fire. Byte for byte BattleNet's shape, deliberately.

	THERE IS NO StrokeRelay HERE, and that is the one interesting difference.

	The arena has eight players on one canvas, so every stroke has to reach every
	other machine or the picture is wrong. A race lane belongs to ONE player and
	nobody else can paint it, so there is nothing to forward -- which also means
	this event costs a fraction of the arena's bandwidth and every client solves
	one grid instead of eight painters' worth of one. Other racers' progress
	reaches the HUD as a number on RaceState, which is what a scoreboard needs and
	all it needs. The neighbourhood made the same call in 2026-08-08 and for
	stronger reasons -- see the note at the top of DrivewayClient.

	Every one of these is a boundary. Nothing here validates anything; the
	handlers do, and each handler in DrivewayRaceServer opens with the checks its
	payload needs.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RaceNet = {}

local FOLDER = "DrivewayRace"
local REMOTES = "Remotes"

local NAMES = table.freeze({
	PromptRaceUI = "RemoteEvent",
	JoinResponse = "RemoteEvent",
	QueueUpdate  = "RemoteEvent",
	RaceState    = "RemoteEvent",
	StrokeSend   = "UnreliableRemoteEvent",
	RaceResults  = "RemoteEvent",
})

local function container(): Folder
	local pack = ReplicatedStorage:FindFirstChild(FOLDER)
	if not pack then
		if not RunService:IsServer() then
			pack = ReplicatedStorage:WaitForChild(FOLDER, 30)
		end
		if not pack then
			error("[DrivewayRace] ReplicatedStorage." .. FOLDER .. " is missing", 2)
		end
	end
	return pack :: Folder
end

-- Cached: this is reached from a Heartbeat-adjacent path on the client, and a
-- FindFirstChild per remote per frame is a cost with nothing to buy.
local cache: { [string]: any }? = nil

function RaceNet.remotes(): { [string]: any }
	if cache then return cache end

	local pack = container()
	local out = {}

	if RunService:IsServer() then
		local folder = pack:FindFirstChild(REMOTES)
		if not folder then
			folder = Instance.new("Folder")
			;(folder :: Folder).Name = REMOTES
			;(folder :: Folder).Parent = pack
		end
		for name, class in pairs(NAMES) do
			local r = folder:FindFirstChild(name)
			if not r or not r:IsA(class) then
				if r then r:Destroy() end
				r = Instance.new(class)
				r.Name = name
				r.Parent = folder
			end
			out[name] = r
		end
	else
		local folder = pack:WaitForChild(REMOTES, 30)
		if not folder then
			error("[DrivewayRace] the server never published " .. REMOTES, 2)
		end
		for name in pairs(NAMES) do
			out[name] = folder:WaitForChild(name, 30)
		end
	end

	cache = out
	return out
end

return RaceNet
