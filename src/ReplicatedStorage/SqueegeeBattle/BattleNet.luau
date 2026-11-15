--!strict
--[[
	BattleNet -- the event's RemoteEvents, and the only place they are named.

	The SERVER creates them and the client waits for them, which is the one
	ordering that works under every load order: a client that reaches this module
	before the server script has run yields on WaitForChild instead of building
	its own orphan copies in ReplicatedStorage, where the server would never hear
	them fire.

	⚠ Every one of these is a boundary. Nothing here validates anything -- the
	handlers do, and each handler in SqueegeeBattleServer opens with the checks
	the payload needs. See the note at the top of that file for the list.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BattleNet = {}

local FOLDER = "SqueegeeBattle"
local REMOTES = "Remotes"

local NAMES = table.freeze({
	PromptEventUI = "RemoteEvent",   -- server -> all
	JoinResponse  = "RemoteEvent",   -- client -> server
	QueueUpdate   = "RemoteEvent",   -- server -> all
	MatchState    = "RemoteEvent",   -- server -> all
	StrokeSend    = "UnreliableRemoteEvent",  -- client -> server
	StrokeRelay   = "UnreliableRemoteEvent",  -- server -> all in match
	MatchResults  = "RemoteEvent",   -- server -> participants
})


local function container(): Folder
	local pack = ReplicatedStorage:FindFirstChild(FOLDER)
	if not pack then
		if not RunService:IsServer() then
			pack = ReplicatedStorage:WaitForChild(FOLDER, 30)
		end
		if not pack then
			error("[SqueegeeBattle] ReplicatedStorage." .. FOLDER .. " is missing", 2)
		end
	end
	return pack :: Folder
end

local cache: { [string]: any }? = nil

function BattleNet.remotes(): { [string]: any }
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
			error("[SqueegeeBattle] the server never published " .. REMOTES, 2)
		end
		for name in pairs(NAMES) do
			out[name] = folder:WaitForChild(name, 30)
		end
	end

	cache = out
	return out
end

return BattleNet
