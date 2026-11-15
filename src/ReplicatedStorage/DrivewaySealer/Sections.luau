--!strict
--[[
	Sections -- which slabs belong to which stretch of map, and the gate at the
	end of it.

	Both gates were built with Progress and Unlocked attributes already on them and
	nothing anywhere reading or writing either, so the mechanic existed as scenery.
	This is the missing half.

	A section is a container in Workspace plus the gate model that closes it. Its
	slabs are whatever is tagged sealable UNDER that container, rather than a list
	written out here -- the map is still being built, and a hand-kept list would go
	stale silently the first time a driveway was added. The cost is that adding a
	slab lengthens the requirement for players midway through it, which is the
	right way round: a list that missed one would open the road early instead.

	Progress is per player and it is STICKY -- a slab counts once it has ever been
	finished, not while it currently is. It was forced when it was written, because
	a finished driveway went dirty again after two and a half minutes and "all
	done at once" was unreachable by construction. Driveways now stay sealed until
	the next rebirth, so the two would agree either way -- but sticky is still the
	right rule, because a rebirth DOES hand every driveway back, and progress that
	unwound with it would shut a road the player had already opened.

	A section also carries what it costs to get PAST it, which is rebirths. See the
	note on `requires`.
]]

local CollectionService = game:GetService("CollectionService")

local Sections = {}

Sections.Tag = "SealableDriveway"

export type Section = {
	id: string,
	container: string,
	gate: string,
	closed: string,
	open: string,
	-- how the interface says the place's name in a sentence; the id is a key and
	-- reads like one the moment it lands in prose
	name: string?,
	-- rebirths needed before the gate will open, on top of finishing every slab
	requires: number?,
	-- what the board says while the slabs are done and the rebirths are not
	owed: string?,

	beyond: string?,
    gateContainer: string?,
}

function Sections.tollAt(index: number): number
	return index * 2 - 1
end

-- a local first, because Luau only takes a type annotation on a local binding
local LIST: { Section } = {
	-- 1st gate -> the estate district. tollAt(1) = 1
	{ id = "Neighbourhood", container = "Neighbourhood", gate = "Gate",
	  closed = "ROAD CLOSED", open = "ROAD OPEN", name = "the neighbourhood",
	  requires = 1, owed = "REBIRTH TO PASS", beyond = "EstateDistrict" },

	{ id = "EstateDistrict", container = "EstateDistrict", gate = "RoadEndGate",
	  closed = "ROAD CLOSED", open = "ROAD OPEN", name = "the estate district",
	  requires = 3, owed = "REBIRTH TO PASS", beyond = "RetailPark" },

	{ id = "RetailPark", container = "RetailPark", gate = "RoadEndGate",
	  closed = "ROAD CLOSED", open = "ROAD OPEN", name = "the Megamart",
	  requires = Sections.tollAt(3), owed = "REBIRTH TO PASS", beyond = "Airport" },
	
	{ id = "Airport", container = "Airport", gate = "RoadEndGate",
	closed = "ROAD CLOSED", open = "ROAD OPEN", name = "the airport",
	requires = Sections.tollAt(4), owed = "REBIRTH TO PASS", beyond = "ParkingGarage" },
    { id = "ParkingGarage", container = "ParkingGarage", gateContainer = "NewZone",
      gate = "RoadEndGate", name = "the parking garage", closed = "FINISH PARKING GARAGE",
      open = "DESERT CITY OPEN", requires = 0, beyond = "NewZone" },
{ id = "NewZone", container = "NewZone", gate = "NoEndGate", name = "the desert city", closed = "RESTORE THE DISTRICT", open = "DISTRICT RESTORED", requires = 0, owed = "RESTORE THE DISTRICT" },

}
Sections.List = LIST

function Sections.requiresOf(s: Section): number
	return s.requires or 0
end

function Sections.nameOf(s: Section): string
	return s.name or s.id
end

--==[ ATTRIBUTES ]============================================================

Sections.SealedAttr = "SecSealed"          -- string: every slab key ever finished
function Sections.doneAttr(id: string): string return "Sec_" .. id end      -- number
function Sections.openAttr(id: string): string return "SecOpen_" .. id end  -- boolean

function Sections.totalAttr(id: string): string return "SecTotal_" .. id end -- number

Sections.NowAttr = "SealedNow"             -- string: slab keys finished since the last rebirth

--==[ THE MAP ]===============================================================

function Sections.containerOf(s: Section): Instance?
	return workspace:FindFirstChild(s.container)
end

function Sections.gateOf(s: Section): Model?
	local c = workspace:FindFirstChild(s.gateContainer or s.container)
	local g = c and c:FindFirstChild(s.gate)
	return (g and g:IsA("Model")) and g or nil
end

-- By container NAME rather than by Section, because the retail park is ground
-- with no section of its own -- see the note on `beyond`.
function Sections.slabsIn(containerName: string): { BasePart }
	if containerName == "ParkingGarage" then
		return {}
	end
	local c = workspace:FindFirstChild(containerName)
	local found = {}
	if not c then return found end
	for _, slab in ipairs(CollectionService:GetTagged(Sections.Tag)) do
		if slab:IsA("BasePart") and slab:IsDescendantOf(c) then
			found[#found + 1] = slab
		end
	end
	return found
end

function Sections.slabsOf(s: Section): { BasePart }
    if s.id == "ParkingGarage" then
        local container = Sections.containerOf(s)
        local found = {}
        if container then
            for _, slab in ipairs(CollectionService:GetTagged(Sections.Tag)) do
                if slab:IsA("BasePart") and slab:IsDescendantOf(container) then
                    table.insert(found, slab)
                end
            end
        end
        return found
    end

    return Sections.slabsIn(s.container)
end

function Sections.reachableGround(isOpen: (string) -> boolean): { string }
	local first = LIST[1]
	if not first then return {} end
	local names = { first.container }

	for _, s in ipairs(LIST) do
		if not isOpen(s.id) then break end
		if s.beyond then names[#names + 1] = s.beyond end
	end
	return names
end

local TUTORIAL_SLAB_PATH = { "Neighbourhood", "Pavement", "Lot_114", "Driveway" }

function Sections.tutorialSlab(): BasePart?
	local node: Instance? = workspace
	for _, name in ipairs(TUTORIAL_SLAB_PATH) do
		node = node and node:FindFirstChild(name)
	end
	return (node and node:IsA("BasePart")) and node or nil
end

function Sections.keyOf(slab: Instance): string
    if slab:GetAttribute("BonusRoadKey") then return slab:GetAttribute("BonusRoadKey") end
	return (slab:GetFullName():gsub("^Workspace%.", ""))
end

function Sections.sectionOfSlab(slab: Instance): Section?
	for _, s in ipairs(Sections.List) do
		local c = Sections.containerOf(s)
		if c and slab:IsDescendantOf(c) then return s end
	end
	return nil
end

--==[ THE RECORD ]============================================================

-- Pipe-separated rather than JSON: the keys are instance paths, which cannot
-- contain a pipe, and this stays readable in the DataStore viewer.
local SEP = "|"

function Sections.decode(packed: string?): { [string]: boolean }
	local set = {}
	if type(packed) ~= "string" or packed == "" then return set end
	for key in string.gmatch(packed, "[^" .. SEP .. "]+") do
		set[key] = true
	end
	return require(script.Parent.World1RestorationCatalog).expand(set)
end

function Sections.encode(set: { [string]: boolean }): string
	local keys = {}
	for k in pairs(set) do keys[#keys + 1] = k end
	-- sorted so an unchanged record encodes identically every save, which keeps
	-- the profile from churning on every autosave for no reason
	table.sort(keys)
	return table.concat(keys, SEP)
end

function Sections.sealedSetOf(plr: Player): { [string]: boolean }
	return Sections.decode(plr:GetAttribute(Sections.SealedAttr) :: string?)
end

-- Same format, different question -- see the note on NowAttr.
function Sections.nowSetOf(plr: Player): { [string]: boolean }
	local set = Sections.decode(plr:GetAttribute(Sections.NowAttr) :: string?)
    local State = require(game.ReplicatedStorage.BonusZones.BonusState)
    for _, zone in pairs(State.read(plr).zones) do
        for key, done in pairs(zone.roads) do if done then set[key] = true end end
    end
    return set
end

-- done, total. Counts against what is tagged RIGHT NOW, so a slab that has been
-- untagged stops being required even if it is still in somebody's record.
function Sections.progressOf(plr: Player, s: Section): (number, number)
	local set = Sections.sealedSetOf(plr)
	local now = Sections.nowSetOf(plr)
	local slabs = Sections.slabsOf(s)
	local done = 0
	for _, slab in ipairs(slabs) do
		local key = Sections.keyOf(slab)
		if set[key] or now[key] then done += 1 end
	end
	return done, #slabs
end

--==[ WHAT TO CALL IT WHEN YOU ARE POINTING AT IT ]===========================

local PLAIN: { [string]: string } = {
	Driveway    = "driveway",
	Walkway     = "front path",
	Road        = "road",
	Carriageway = "road",
	RoadBulb    = "turning circle",
	DepotApron  = "depot yard",
	EntryDrive  = "entry road",
	EntryFlare  = "entry road",
	Forecourt   = "forecourt",
	Union       = "ramp yard",
}

function Sections.plainName(slab: Instance): string
	local exact = PLAIN[slab.Name]
	if exact then return exact end
	local n = slab.Name
	if n:match("^Drive_") then return "driveway" end
	if n:match("^Lot_") then return "car park" end

	if n:match("^Deck_") then return "parking deck" end
	if n:match("^Aisle") then return "parking aisle" end
	if n:match("^Seam") then return "parking deck" end
	if n:match("^Ramp") then return "ramp" end
	if n:find("Ring") then return "ring road" end
	if n:find("Walk") then return "front path" end
	if n:find("Road") or n:find("Carriageway") then return "road" end
	if n:match("^Runway") then return "runway" end
	if n:match("^Taxiway") then return "taxiway" end
	if n:match("^Apron_") then return "apron" end
	if n:find("Apron") or n:find("Yard") then return "yard" end
	-- Driveways outnumber everything else two to one, and a wrong noun on an arrow
	-- that is pointing at the thing costs nothing.
	return "driveway"
end

return Sections
