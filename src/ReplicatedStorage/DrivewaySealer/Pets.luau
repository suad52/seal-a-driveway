--[[
	Pets -- the pet catalogue, and nothing else.

	Deliberately the same shape as SqueegeeSkins' ownership layer: a list of
	entries, an id index, a CSV owned string riding in the profile, and one
	remote carrying a choice up from the case. Adding a pet is adding an entry
	here and a model under ReplicatedStorage.Assets.Pets -- nothing else in the
	game hard-codes a pet.

	Ownership is EMPTY for everybody right now: selling comes later, and when it
	does it only has to write ids into the owned attribute. Nothing here assumes
	a pet is owned by default.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Passes = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Passes"))

local Pets = {}

-- The attribute a player's choice rides on: a pet id, or "" for none.
Pets.Attr = "PetEquipped"

-- Comma-joined pet ids, exactly like SkinsOwned: one string, one profile field.
Pets.OwnedAttr = "PetsOwned"

-- The multiplier attributes PetService writes when the choice changes. They are
-- plain numbers (1.3 means +30%) so the systems that read them never have to
-- know a pet is involved -- DrivewayServer's pay chain and SealerUIClient's
-- applyAll just multiply them in.
Pets.CashAttr = "Pet_CashMult"
Pets.CapacityAttr = "Pet_CapacityMult"
Pets.SpeedAttr = "Pet_SpeedMult"

--[[
	The roster. `model` is the instance name under ReplicatedStorage.Assets.Pets;
	`bonuses` are fractions (0.3 = +30%).
]]
Pets.List = {
	{
		id = "BlueberryHowl",
		name = "Blueberry Howl",
		model = "Blueberry Howl",
		icon = "rbxassetid://87911016308017",
		-- Not sold on its own: this pet is one half of the Blueberry Bundle pass,
		-- and ownership is the pass. See Pets.owns below.
		pass = "BlueberryBundle",
		bonuses = { cash = 0.3, capacity = 0.3, speed = 0.2 },
	},
	
	
	{
		id = "BloomTail",
		name = "Bloom Tail",
		model = "Bloom Tail",
		icon = "rbxassetid://96403103706999",
		-- Not sold on its own: this pet is one half of the Blueberry Bundle pass,
		-- and ownership is the pass. See Pets.owns below.
		--pass = "BlueberryBundle",
		bonuses = { cash = 0.4, capacity = 0.2, speed = 0.3 },
	},
}

table.insert(Pets.List, {
    id = "WireRaccoon", name = "Wire Raccoon", model = "Wire Raccoon",
    icon = "rbxassetid://137551967659987",
    bonuses = {cash = 0.4, capacity = 0.2, speed = 0.15},
})
local ById: { [string]: any } = {}
for _, p in ipairs(Pets.List) do ById[p.id] = p end
Pets.ById = ById

--==[ OWNERSHIP ]============================================================

function Pets.ownedSet(plr: Player?): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if not plr then return set end
	local raw = plr:GetAttribute(Pets.OwnedAttr)
	if type(raw) == "string" then
		for id in raw:gmatch("[^,]+") do
			if ById[id] then set[id] = true end
		end
	end
	return set
end

function Pets.owns(plr: Player?, id: string): boolean
	if not plr then return false end
	if Pets.ownedSet(plr)[id] == true then return true end
	-- A pet tied to a pass is owned for exactly as long as the pass is: the
	-- attribute PassService keeps in sync is the whole of the record, so a
	-- refund takes the pet back with it and a re-buy needs no migration.
	local def = ById[id]
	return def ~= nil and def.pass ~= nil and Passes.owns(plr, def.pass)
end

-- Serialised in the list's own order so the stored string is stable, and so a
-- retired pet id cannot keep riding in every profile that ever held it.
function Pets.serialise(set: { [string]: boolean }): string
	local out = {}
	for _, p in ipairs(Pets.List) do
		if set[p.id] then table.insert(out, p.id) end
	end
	return table.concat(out, ",")
end

--==[ THE REMOTE ]============================================================

--[[
	The one remote this feature has: a pet id going up from the case, or "" to
	take the pet off. Validated on arrival by PetService.

	⚠ Created on the SERVER only, exactly like SqueegeeSkins.remotes: a client
	that made its own would get a local instance that never reaches anybody.
	Readers use WaitForChild.
]]
function Pets.remotes(): Folder
	local ui = ReplicatedStorage:WaitForChild("SealerUI")
	local folder = ui:FindFirstChild("Remotes")
	if not folder then
		local RunService = game:GetService("RunService")
		if not RunService:IsServer() then return ui:WaitForChild("Remotes") :: Folder end
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ui
	end
	if game:GetService("RunService"):IsServer() then
		if not folder:FindFirstChild("PetEquip") then
			local r = Instance.new("RemoteEvent")
			r.Name = "PetEquip"
			r.Parent = folder
		end
	end
	return folder :: Folder
end

return Pets
