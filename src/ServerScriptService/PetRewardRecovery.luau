local RS = game:GetService("ReplicatedStorage")
local Pets = require(RS:WaitForChild("DrivewaySealer"):WaitForChild("Pets"))
local State = require(RS:WaitForChild("ZoneProgress"):WaitForChild("ZoneProgressState"))

local Recovery = {}

function Recovery.ensure(player)
    local state = State.read(player)
    if state.claims["6"] ~= "claimed" then return false end
    if not Pets.ById.BloomTail then return false end

    local owned = Pets.ownedSet(player)
    if owned.BloomTail then return false end

    owned.BloomTail = true
    player:SetAttribute(Pets.OwnedAttr, Pets.serialise(owned))
    return true
end

return Recovery
