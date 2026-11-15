local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remote = ReplicatedStorage:FindFirstChild("TeleportToPvPLobby")

local COOLDOWN = 3 -- seconds between teleports per player
local lastTeleport = {}

local function getTeleportPart()
	local lobby = workspace:FindFirstChild("PvPLobby")
	return lobby and lobby:FindFirstChild("PvPLobbyTeleportPart")
end

if remote then
	remote.OnServerEvent:Connect(function(player)
		-- Cooldown check to prevent spam
		local now = os.clock()
		if lastTeleport[player.UserId] and now - lastTeleport[player.UserId] < COOLDOWN then
			return
		end

		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		local teleportPart = getTeleportPart()

		if hrp and teleportPart then
			lastTeleport[player.UserId] = now
			-- Teleport slightly above the part so the player doesn't clip into it
			hrp.CFrame = teleportPart.CFrame + Vector3.new(0, 4, 0)
		end
	end)
end