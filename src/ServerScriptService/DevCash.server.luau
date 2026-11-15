--!strict
--[[
	DevCash -- a testing wallet that works from the Studio command bar.

	Why this exists: `leaderstats.Cash.Value = 1000000000` typed into the command
	bar sets the number on whichever side the bar is pointed at, and it defaults to
	the Client. leaderstats replicates server -> client only, so a client-side
	write paints the HUD and nothing else -- the server's wallet is still whatever
	it was, and every purchase comes back "Not enough cash" while the corner of the
	screen reads a billion dollars. That looks exactly like a broken shop.

	Rather than remember to flip the bar to Server every session, this takes the
	request over a remote so it lands on the authoritative side no matter where it
	was typed:

		game.ReplicatedStorage.SealerUI.Remotes.DevGiveCash:FireServer(1000000)

	Studio only. In a published server the remote is never created, so there is
	nothing for a real client to call -- which is the whole reason the grant lives
	behind a remote the game itself never fires.
]]

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- IntValue is 32-bit; a grant that overflows it wraps negative, which would look
-- like yet another broken wallet
local MAX_CASH = 2 ^ 31 - 1

local pack = ReplicatedStorage:WaitForChild("SealerUI")
local remotes = pack:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = pack
end

local give = remotes:FindFirstChild("DevGiveCash")
if not give then
	give = Instance.new("RemoteEvent")
	give.Name = "DevGiveCash"
	give.Parent = remotes
end

local function cashOf(plr: Player): IntValue?
	local ls = plr:FindFirstChild("leaderstats")
	return ls and ls:FindFirstChild("Cash") :: IntValue? or nil
end

-- `set` replaces the balance; leave it false to add to it
(give :: RemoteEvent).OnServerEvent:Connect(function(plr, amount, set)
	local n = tonumber(amount)
	if not n then return end
	local c = cashOf(plr)
	if not c then return end
	local target = set and n or c.Value + n
	c.Value = math.clamp(math.floor(target), 0, MAX_CASH)
	print(("[DevCash] %s -> $%d"):format(plr.Name, c.Value))
end)

print("[DevCash] ready -- ReplicatedStorage.SealerUI.Remotes.DevGiveCash:FireServer(amount)")
