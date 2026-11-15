local Profile = {}

local localKeys = {
	"SecSealed", "SealedNow", "DepotSealed", "TutSealed",
	"TutBought", "TutorialDone", "TutReplay", "Skin_Squeegee", "AsphaltColorEquipped",
}
local keySet = {}
for _, key in ipairs(localKeys) do keySet[key] = true end

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, item in pairs(value) do out[key] = copy(item) end
	return out
end

local function union(a, b)
	local found, list = {}, {}
	for _, raw in ipairs({a or "", b or ""}) do
		if type(raw) == "string" then
			for id in raw:gmatch("[^,]+") do
				if not found[id] then found[id] = true; table.insert(list, id) end
			end
		end
	end
	table.sort(list)
	return table.concat(list, ",")
end

local function rebirthCount(value)
	local n = tonumber(value) or 0
	if n ~= n or math.abs(n) == math.huge then return 0 end
	return math.max(0, math.floor(n))
end

function Profile.migrate(raw)
	local data = if type(raw) == "table" then copy(raw) else {}
	data.WorldProgress = if type(data.WorldProgress) == "table" then data.WorldProgress else {}
	if type(data.WorldProgress["1"]) ~= "table" then
		local first = {}
		for _, key in ipairs(localKeys) do first[key] = data[key] end
		data.WorldProgress["1"] = first
	end
	if type(data.WorldProgress["2"]) ~= "table" then
		data.WorldProgress["2"] = {SecSealed = "", SealedNow = ""}
	end
	if type(data.WorldProgress["3"]) ~= "table" then
		data.WorldProgress["3"] = {SecSealed="", SealedNow=""}
	end
	-- Old releases stored a separate counter in each world. Keep the highest
	-- achieved count rather than adding copies of the same progression together.
	data.Rebirths = math.max(rebirthCount(data.Rebirths),
		rebirthCount(data.WorldProgress["1"].Rebirths),
		rebirthCount(data.WorldProgress["2"].Rebirths))
	data.WorldProgress["1"].Rebirths = nil
	data.WorldProgress["2"].Rebirths = nil
	data.World2Extra = if type(data.World2Extra) == "table" then data.World2Extra else {}
	data.WorldSchema = 2
	return data
end

function Profile.project(raw, world, baseMax)
	assert(world == "1" or world == "2" or world == "3", "Invalid world")
	local data = Profile.migrate(raw)
	local view = copy(data)
	for key,value in pairs(data.WorldProgress["3"].GraveyardRewards or {}) do view[key]=copy(value) end
	local localData = data.WorldProgress[world]
	for _, key in ipairs(localKeys) do view[key] = localData[key] end
	view.SecSealed = view.SecSealed or ""
	view.SealedNow = view.SealedNow or ""
	view.Rebirths = view.Rebirths or 0
	for id, maximum in pairs(baseMax) do
		local base = math.clamp(math.floor(tonumber(data[id]) or 1), 1, maximum)
		local extra = math.clamp(math.floor(tonumber(data.World2Extra[id]) or 0), 0, 3)
		view[id] = base + (if world == "2" and base == maximum then extra else 0)
	end
	if world == "2" or world == "3" then
		view.DepotSealed = true
		view.TutorialDone = true
		view.TutSealed = true
		view.TutBought = true
		view.TutReplay = nil
	end
	return view
end

function Profile.merge(raw, snapshot, world, baseMax, resetExtras)
	assert(world == "1" or world == "2" or world == "3", "Invalid world")
	local data = Profile.migrate(raw)
	local other = if world == "1" then "2" else "1"
	local otherProgress = copy(data.WorldProgress[other])
	for key,value in pairs(data.WorldProgress["3"].GraveyardRewards or {}) do data[key]=copy(value) end
	local ownedSkins, ownedColors = data.SkinsOwned, data.AsphaltColorsOwned
	local rebirths = math.max(data.Rebirths, rebirthCount(snapshot.Rebirths))
	-- Snapshot owns ordinary fields; world containers and the session lease are protected.
	local protected = {PumpkinCoins=true, WorldProgress=true, World2Extra=true, WorldSchema=true, WorldLease=true}
	for _,key in ipairs({"GraveyardRuns","GraveyardClaim1","GraveyardClaim2","GraveyardClaim3","GraveyardClaim4","GraveyardResetVersion","GraveyardLapComplete","HalloweenTruckEquipped"}) do protected[key]=true end
	for key in pairs(data) do
		if not protected[key] and not keySet[key] then data[key] = nil end
	end
	for key, value in pairs(snapshot) do
		if not protected[key] and not keySet[key] then data[key] = copy(value) end
	end
	data.GraveyardRuns=math.max(tonumber(data.GraveyardRuns) or 0,tonumber(snapshot.GraveyardRuns) or 0)
	data.GraveyardClaim1=math.max(tonumber(data.GraveyardClaim1) or 0,tonumber(snapshot.GraveyardClaim1) or 0)
	data.GraveyardClaim2=math.max(tonumber(data.GraveyardClaim2) or 0,tonumber(snapshot.GraveyardClaim2) or 0)
	data.GraveyardClaim3=math.max(tonumber(data.GraveyardClaim3) or 0,tonumber(snapshot.GraveyardClaim3) or 0)
	data.GraveyardClaim4=math.max(tonumber(data.GraveyardClaim4) or 0,tonumber(snapshot.GraveyardClaim4) or 0)
	data.GraveyardResetVersion=math.max(tonumber(data.GraveyardResetVersion) or 0,tonumber(snapshot.GraveyardResetVersion) or 0)
	if world=="3" and type(snapshot.GraveyardLapComplete)=="boolean" then data.GraveyardLapComplete=snapshot.GraveyardLapComplete end
	if type(snapshot.HalloweenTruckEquipped)=="boolean" then data.HalloweenTruckEquipped=snapshot.HalloweenTruckEquipped end
	local current = {}
	for _, key in ipairs(localKeys) do current[key] = snapshot[key] end
	current.SecSealed = current.SecSealed or ""
	current.SealedNow = current.SealedNow or ""
	data.WorldProgress[world] = current
	data.WorldProgress[other] = otherProgress
	local rewards={}
	for _,key in ipairs({"GraveyardRuns","GraveyardClaim1","GraveyardClaim2","GraveyardClaim3","GraveyardClaim4","GraveyardResetVersion","GraveyardLapComplete","HalloweenTruckEquipped"}) do rewards[key]=copy(data[key]) end
	data.WorldProgress["3"].GraveyardRewards=rewards
	if resetExtras then data.World2Extra = {} end
	for id, maximum in pairs(baseMax) do
		local level = math.max(1, math.floor(tonumber(snapshot[id]) or 1))
		data[id] = math.min(level, maximum)
		if world == "2" then data.World2Extra[id] = math.clamp(level - maximum, 0, 3) end
	end
	data.SkinsOwned = union(ownedSkins, snapshot.SkinsOwned)
	data.AsphaltColorsOwned = union(ownedColors, snapshot.AsphaltColorsOwned)
	data.Rebirths = rebirths
	-- Earn-only event currency: preserve it across worlds, rebirths and older snapshots.
	data.PumpkinCoins = math.max(tonumber(data.PumpkinCoins) or 0, tonumber(snapshot.PumpkinCoins) or 0)
	-- Legacy root remains a World 1 view for audit tools, never a World 2 road list.
	for _, key in ipairs(localKeys) do data[key] = data.WorldProgress["1"][key] end
	return data
end

require(game.ReplicatedStorage.HalloweenProfileBridge).wrap(Profile)

require(game.ReplicatedStorage.SkipZone.SkipZoneProfile).wrap(Profile)

require(game.ReplicatedStorage.SkipRoad.SkipRoadProfile).wrap(Profile)

require(game.ReplicatedStorage.ZoneProgress.ZoneProgressState).wrap(Profile)

require(game.ReplicatedStorage.BonusZones.BonusState).wrap(Profile)
return Profile
