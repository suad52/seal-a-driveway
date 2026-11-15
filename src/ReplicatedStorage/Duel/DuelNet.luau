--!strict
--[[
	DuelNet -- the duel's RemoteEvents, and the only place they are named.

	The SERVER creates them and the client waits for them, which is the one
	ordering that works under every load order: a client that reaches this module
	before the server script has run yields on WaitForChild instead of building its
	own orphan copies in ReplicatedStorage, where the server would never hear them
	fire. Byte for byte BattleNet's and RaceNet's shape, deliberately.

	THERE IS NO STROKE CHANNEL HERE, and that is the interesting difference.

	The arena has to forward every stroke because eight players share one canvas.
	A duel never does, for two separate reasons:

	  Speed Run and Turf War lay ORDINARY SEALABLE SLABS, so the painting is
	  DrivewayClient's, the scoring rides the coverage reports that file already
	  sends, and there is nothing here to add. Sealing has been private since
	  2026-08-08 -- see the note at the foot of DrivewayServer -- so there is no
	  relay to forward even in the neighbourhood.

	  Squeegee Battle is not run by this pack at all. It is handed to the arena
	  through ServerScriptService.DuelBus, and the strokes go down BattleNet's own
	  channel exactly as they do for a scheduled match.

	So this pack's whole wire surface is a conversation -- who challenged whom, to
	what, and what happened -- which is six small reliable events and no hot path.

	Every one of these is a boundary. Nothing here validates anything; the handlers
	do, and each handler in DuelServer opens with the checks its payload needs.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DuelNet = {}

local FOLDER = "Duel"
local REMOTES = "Remotes"

--[[
	SendChallenge  client -> server: (targetPlayer, modeId). The challenger has
	                  picked a mode off the menu the E prompt opened.
	Offer          server -> the target: "<name> wants a <mode>", plus the purse
	                  it would be worth and a DURATION to count down (os.clock on
	                  the server is meaningless to a client -- the client counts
	                  down itself, same rule as PromptRaceUI)
	OfferReply     client -> server: (accept: boolean)
	Notice         server -> one client: a line of text for the toast rail --
	                  "challenge sent", "they declined", "they are already in one"
	DuelState      server -> the two duellists: phase, clock, both scores
	DuelResult     server -> the two duellists: the summary card
]]
local NAMES = table.freeze({
	SendChallenge = "RemoteEvent",
	Offer         = "RemoteEvent",
	OfferReply    = "RemoteEvent",
	Notice        = "RemoteEvent",
	DuelState     = "RemoteEvent",
	DuelResult    = "RemoteEvent",
})

local function container(): Folder
	local pack = ReplicatedStorage:FindFirstChild(FOLDER)
	if not pack then
		if not RunService:IsServer() then
			pack = ReplicatedStorage:WaitForChild(FOLDER, 30)
		end
		if not pack then
			error("[Duel] ReplicatedStorage." .. FOLDER .. " is missing", 2)
		end
	end
	return pack :: Folder
end

-- Cached: the client reaches this from its prompt handler and from three event
-- handlers, and a FindFirstChild per remote per call is a cost with nothing to buy.
local cache: { [string]: any }? = nil

function DuelNet.remotes(): { [string]: any }
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
			-- Rebuilt rather than reused when the class is wrong, so a half-edited
			-- place cannot leave a RemoteFunction standing where a RemoteEvent is
			-- fired at -- which fails silently on one side only.
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
			error("[Duel] the server never published " .. REMOTES, 2)
		end
		for name in pairs(NAMES) do
			out[name] = folder:WaitForChild(name, 30)
		end
	end

	cache = out
	return out
end

return DuelNet
