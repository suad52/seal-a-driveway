--!strict
--[[
	UpgradeService -- owns every player's upgrade levels and takes their money.

	Levels live on the Player as attributes (Upg_Tank, Upg_Blade, ...) because
	attributes replicate on their own: the shop UI and the client-side effect
	applier both just read them and listen for changes, with no bespoke
	replication to keep in sync.

	The server is authoritative about the level and the price. The client applies
	the *effects* locally -- it has to, the sealing simulation runs there -- so a
	tampered client can widen its own squeegee. That is the same trust boundary
	the coverage reporting already lives with (see DrivewayServer); the thing
	worth protecting is the wallet, and that is here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local WorldProfile = require(game.ServerScriptService:WaitForChild("WorldProfile"))
local WorldsAccess = require(game.ServerScriptService:WaitForChild("WorldsAccess"))
local WORLD = "1"
local worldSession = game:GetService("HttpService"):GenerateGUID(false)
local resetWorldExtras = {}
local releasedWorldProfiles = {}
local BASE_MAX = {Tank=14, Refill=14, Blade=15, Pour=16, Speed=14}
local LEASE_SECONDS = 360
local STUDIO_PROFILE_STORE = "SealerProfiles_WorldsStudio_v1"
local function loadWorldProfile(profileStore, key)
 local paidWorld2 = false
 if WORLD == "2" then
  local userId = tonumber(key:match("^p_(%d+)$"))
  if userId then paidWorld2 = WorldsAccess.paid(userId) end
 end
 local seed
 if RunService:IsStudio() and profileStore:GetAsync(key) == nil then
  local live = DataStoreService:GetDataStore("SealerProfiles_v1"):GetAsync(key)
  seed = WorldProfile.migrate(live)
  seed.WorldLease = nil
 end
 local accessDenied = false
 local claimed = profileStore:UpdateAsync(key, function(previous)
  local data = WorldProfile.migrate(previous or seed)
  if paidWorld2 then data.World2Unlocked = true end
  if not RunService:IsStudio() and WORLD == "2" and data.World2Unlocked ~= true then accessDenied = true; return nil end
  local lease = data.WorldLease
  if type(lease) == "table" and lease.token ~= worldSession and (tonumber(lease.expires) or 0) > os.time() then return nil end
  data.WorldLease = {token=worldSession, expires=os.time()+LEASE_SECONDS}
  return data
 end)
 if accessDenied then error("Complete the desert city and use its portal to unlock World 2") end
 if not claimed or not claimed.WorldLease or claimed.WorldLease.token ~= worldSession then
  error("Profile is still active on another server; please rejoin shortly")
 end
 return WorldProfile.project(claimed, WORLD, BASE_MAX)
end

local Upgrades = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Upgrades"))
local Rebirth = require(ReplicatedStorage.SealerUI:WaitForChild("Rebirth"))
local Quests = require(ReplicatedStorage.SealerUI:WaitForChild("Quests"))
local Daily = require(ReplicatedStorage.SealerUI:WaitForChild("Daily"))
-- The timed purchases. Only two things in the game know they exist: this file,
-- which turns a receipt into a deadline, and whatever reads that deadline. See
-- the note there for why a boost is not a pass.
local Boosts = require(ReplicatedStorage.SealerUI:WaitForChild("Boosts"))
-- Cash sold outright, in fixed increments. Another developer product, answered
-- in the one ProcessReceipt below like the boosts and the skins.
local CashPacks = require(ReplicatedStorage.SealerUI:WaitForChild("CashPacks"))
--[[
	The second helping, offered when the arena or the yard has just paid a lump
	sum. This file owns two of the three ends it needs -- the note rides in the
	profile below like PendingRobux does, and ProcessReceipt is the only place it
	may be spent -- while DoubleUpService owns the offer itself and the wallet it
	lands in. Neither requires the other's callers.
]]
local DoubleUp = require(ReplicatedStorage.SealerUI:WaitForChild("DoubleUp"))
local DoubleUpService = require(game.ServerScriptService.DoubleUpService)
--[[
	The squeegee wardrobe: which skins are owned and which one is worn.

	Both of those used to come from SealerUI.SkinRoll, the slot machine's contract
	module. The machine was removed on 2026-08-14 and that module went with it --
	ownership moved into the CATALOGUE, which is where it belonged: it was never
	about rolling, and keeping it in the machine made the machine load-bearing for
	a wardrobe that has nothing to do with it.
]]
local Skins = require(ReplicatedStorage.DrivewaySealer:WaitForChild("SqueegeeSkins"))
-- The skin shop. It owns both currencies; this file owns the till and the
-- profile field its Robux note rides in -- the same split the doubling uses.
local SkinShop = require(game.ServerScriptService.SkinShopService)
local ColorShop = require(game.ServerScriptService:WaitForChild("ColorShopService"))
local SpinWheel = require(game.ServerScriptService:WaitForChild("SpinWheelService"))
--[[
	The one place this file needs the sealing package, and it is worth the
	dependency it used to avoid.

	SECTIONS_KEY and NOW_KEY below are still spelled out rather than read from here
	-- the name is the contract with the profile and it should be visible in this
	file. What cannot be duplicated is the ENCODING: restoring SealedNow now merges
	rather than overwrites (see the note at that restore), and a second
	pipe-splitting routine that drifted from the first would corrupt the record
	rather than merely disagree about it.
]]
local Sections = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Sections"))
local RebirthBus = require(game.ServerScriptService.RebirthBus)

local remotes = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage.SealerUI
end
local function remote(name: string): RemoteEvent
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	return r :: RemoteEvent
end
local BuyUpgrade = remote("BuyUpgrade")
local BuyRobux = remote("BuyRobux")
local BuyResult = remote("BuyResult")

--[[
	The Settings panel's five switches, now kept with the profile.

	They used to live in the session and nowhere else -- the panel's own note said
	so. That is a convenience bug for the two sound sliders and a PERFORMANCE bug
	for the other three: a player on a weak phone who turns Shadows and the 3D
	Sealer Surface off has a playable game until they rejoin, at which point both
	come back on and they have to find the panel again. Most will not. They will
	conclude the game is laggy, which is the report we keep getting.

	The two heaviest things in the game already had off switches. The problem was
	never that players could not turn them off, it is that turning them off did not
	last.
]]
local SET_KEYS = { "Set_Music", "Set_Sfx", "Set_Sheet", "Set_Shadows", "Set_Fancy" }
local SET_IS = {
	Set_Music = "number", Set_Sfx = "number",
	Set_Sheet = "boolean", Set_Shadows = "boolean", Set_Fancy = "boolean",
}

--[[
	Written by the CLIENT, because that is the only side that knows.

	A toggle sets its attribute from a LocalScript, and a client-set attribute never
	reaches the server -- so without this remote the profile has nothing to save.
	Validated by name and by type against the table above: this writes into the same
	profile as cash and levels, so an unrecognised key must not be able to add
	itself to it, and a volume arriving as a string must not be stored as one.

	Diagnostic-grade trust, like the feedback context: nothing is spent or granted
	on any of it, and the worst a forged value achieves is a player choosing their
	own graphics settings, which is what the panel is for.
]]
local SaveSetting = remote("SaveSetting")
SaveSetting.OnServerEvent:Connect(function(plr, key, value)
	local want = if type(key) == "string" then SET_IS[key] else nil
	if not want or type(value) ~= want then return end
	if want == "number" then
		if value ~= value then return end   -- NaN
		value = math.clamp(value, 0, 1)
	end
	plr:SetAttribute(key, value)
end)

local store: DataStore? = nil
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore(if RunService:IsStudio() then STUDIO_PROFILE_STORE else "SealerProfiles_v1")
	end)
	store = ok and s or nil
	if not store then
		warn("[UpgradeService] No DataStore access -- upgrades will not persist."
			.. " In Studio enable File > Game Settings > Security >"
			.. " \"Enable Studio Access to API Services\".")
	end
end

local function attrName(id: string): string
	return "Upg_" .. id
end

-- The section record, named the same in the profile as on the Player. Spelled
-- out rather than required from Sections because this script has no other reason
-- to depend on the sealing package, and the name is the whole contract.
local SECTIONS_KEY = "SecSealed"
-- And the live record: which slabs are sealed RIGHT NOW rather than which have
-- ever been. Cleared by a rebirth, so it has to be saved with the rebirth count
-- it belongs to -- see the note on Sections.NowAttr.
local NOW_KEY = "SealedNow"
--[[
	The pass-shaped key, spelled out here for the same reason the two above are.

	VipDay is the UTC day their VIP packet was last handed over. It is not a PASS
	-- ownership is Roblox's record and is re-asked every join by PassService,
	never saved -- it is the state a pass accumulates, which is ours and has to
	persist.
]]
local VIP_DAY_KEY = "VipDay"

local function cashOf(plr: Player): IntValue?
	local ls = plr:FindFirstChild("leaderstats")
	return ls and ls:FindFirstChild("Cash") :: IntValue? or nil
end

--==[ the Robux till ]========================================================
--[[
	One developer product for the whole shop, not one per rung.

	A product is a price and nothing else -- the receipt Roblox hands back carries
	a ProductId and no trace of which button opened the prompt -- so the track being
	bought has to be remembered on this side. The server writes down what the
	player asked for BEFORE prompting, and ProcessReceipt reads it back. Sending
	the track up with the receipt instead would let a client prompt the one product
	and then claim whichever rung it liked.

	That note has to survive a rejoin, because it can outlive the session that made
	it: a player who buys and then drops before the grant lands gets ProcessReceipt
	re-fired on their NEXT join, by which point an in-memory table is long gone. So
	it rides in the profile with the levels, and is written the moment the prompt
	opens rather than at the next autosave.

	Both tables are keyed by UserId rather than Player: the Player object a receipt
	arrives for is not the one that opened the prompt.
]]
local ROBUX_PRODUCT = 3634048798
local SKIP_REBIRTH_PRODUCT = 3710199253

local pending: { [number]: string } = {}        -- UserId -> track id awaiting a receipt
local handled: { [number]: { string } } = {}    -- UserId -> PurchaseIds already granted

-- Roblox may re-fire a receipt it is unsure landed, so the grant has to be
-- idempotent. Only the recent ones are kept -- the list rides in the profile,
-- and a purchase history is not what this key is for.
local RECEIPT_MEMORY = 40

local function wasHandled(userId: number, purchaseId: string): boolean
	local list = handled[userId]
	if not list then return false end
	return table.find(list, purchaseId) ~= nil
end

local function markHandled(userId: number, purchaseId: string)
	local list = handled[userId]
	if not list then list = {}; handled[userId] = list end
	table.insert(list, purchaseId)
	while #list > RECEIPT_MEMORY do table.remove(list, 1) end
end

--==[ load / save ]===========================================================

local loaded: { [Player]: boolean } = {}
--[[
	ONE LOAD PER SESSION, and the absence of this was a progress-losing bug.

	load() is wired from two places on purpose -- the PlayerAdded signal, and a
	sweep of Players:GetPlayers() for anyone who beat the script into the server.
	On a cold server start those two can BOTH catch the same player, and nothing
	stopped the second one running.

	A second load is not harmless. It re-restores the profile as it was ON DISK,
	and the restore of SealedNow is a straight overwrite -- so every driveway
	finished between the first load and the second is erased from the record. With
	LOAD_TRIES retries and their backoff, the second load can land seven seconds
	in, which is easily a job or two on a small walkway.

	The symptom is the one that is hardest to attribute: gates stay open, because
	SecSealed is written from the same handler and is sticky, while the driveways
	themselves come back grey. Never cleared during the session -- once `loaded` is
	true the guard below holds on its own, and a completed load must not be
	repeatable either.
]]
local loading: { [Player]: boolean } = {}

local function keyFor(plr: Player): string
	return "p_" .. plr.UserId
end

local function applyDefaults(plr: Player)
	for _, t in ipairs(Upgrades.Tracks) do
		if plr:GetAttribute(attrName(t.id)) == nil then
			plr:SetAttribute(attrName(t.id), 1)
		end
	end
	-- Set even for a brand new profile, because the panel and the payout both
	-- read it every frame and an absent attribute is a different thing to zero.
	if plr:GetAttribute(Rebirth.Attr) == nil then
		plr:SetAttribute(Rebirth.Attr, 0)
	end
	-- Same for the quest board. A nil counter and a zero counter draw the same
	-- row, but only one of them survives being read as a number.
	for _, c in ipairs(Quests.Counters) do
		if plr:GetAttribute(c) == nil then plr:SetAttribute(c, 0) end
	end
	for _, t in ipairs(Quests.Tracks) do
		local a = Quests.claimedAttr(t.id)
		if plr:GetAttribute(a) == nil then plr:SetAttribute(a, 0) end
	end
	--[[
		The day book's streak, for the same reason: the panel reads it as a number
		every frame.

		The DAY is deliberately left unset. Nil there means "no packet has ever been
		taken", which is what puts Day 1 in front of a brand new player; writing a
		zero would be a day number, and one that reads as very long ago, so the first
		claim would arrive already flagged as a broken streak.
	]]
	if plr:GetAttribute(Daily.StreakAttr) == nil then
		plr:SetAttribute(Daily.StreakAttr, 0)
	end
	--[[
		Every boost starts expired rather than absent, for the reason the pass
		attributes are written false before PassService has answered: a reader that
		sees nil once grows a branch for "unknown", and there is nothing to do with
		unknown here. Zero is a deadline in 1970, which is exactly the right answer
		for somebody who has not bought one.
	]]
	for _, b in ipairs(Boosts.List) do
		local a = Boosts.attrName(b.id)
		if plr:GetAttribute(a) == nil then plr:SetAttribute(a, 0) end
	end
	--[[
		The wardrobe, and the starter skin is WRITTEN DOWN rather than implied.

		Skins.ownedSet already treats Site Standard as owned by everybody, so this
		changes nothing it answers -- but the Squeegee Case draws its states off the
		stored string, and a brand new player looking at a grid with nothing owned
		has no idea the first one is already theirs.
	]]
	if plr:GetAttribute(Skins.OwnedAttr) == nil then
		plr:SetAttribute(Skins.OwnedAttr, Skins.Default)
	end
end

--[[
	Set once the saved profile has landed, or once it is known there is none.

	Anything that reads a persisted flag to decide whether to show itself needs
	this. The tutorial is the case that made it necessary: it keys off TutorialDone,
	which arrives from GetAsync a moment after the client does, so without a signal
	to wait on it either guessed a delay -- and flashed step one at players who
	finished weeks ago -- or showed nothing for as long as the longest plausible
	load. applyDefaults does not count as loaded: it runs before the fetch and only
	writes level 1 into anything unset.
]]
local PROFILE_READY = "ProfileLoaded"

--[[
	TWO SEPARATE FACTS, AND CONFLATING THEM WAS A PROFILE-WIPING BUG.

	`loaded[plr]` means "we know what this player owns, so it is safe to write over
	their stored profile". The PROFILE_READY attribute means "stop waiting for me" --
	the tutorial card, DrivewayClient's rebirth guard and the section restore all
	hang off it, and a session where it never arrives is broken in its own quieter
	ways.

	These used to be one call, made unconditionally at the end of load(). So a
	GetAsync that THREW -- a throttle, a blip, an outage -- left the player holding
	applyDefaults' level-1 attributes with `loaded` true, and the 120-second autosave
	then SetAsync'd those defaults straight over a real profile. One failed read and
	everything was gone, with nothing in the log but a warn nobody was reading.

	Split, a failed read sets the attribute and leaves `loaded` false, which makes
	save() a no-op for the rest of that session. The player sees a blank profile and
	is told why; the real one is still sitting in the store, untouched.
]]
local function markReady(plr: Player)
	plr:SetAttribute(PROFILE_READY, true)
end

local function markLoaded(plr: Player)
	loaded[plr] = true
	ColorShop.profileReady(plr)
	markReady(plr)
end

--[[
	Retries, because the usual failure here is transient and a moment apart.

	Kept short on purpose: DepotGateClient gives ProfileLoaded 12 seconds before it
	gives up waiting (SectionGateClient allows 20), so the whole budget here has to
	fit inside that or a slow retry flashes step one at a veteran.

	Five tries with the backoff capped at 2s -- 1, 2, 2, 2 -- is 7 seconds of
	waiting worst case, which leaves about 5 for the GetAsync calls themselves.

	It was three tries and 3 seconds, and the extra two are aimed squarely at the
	PUBLISH case. Publishing shuts every server down at once and their players all
	migrate together, so the reads pile up exactly when the store is busiest -- and
	a read that fails here is not a slow join, it is a session that will never be
	saved (see markReady below: `loaded` stays false and save() is a no-op for the
	rest of it). Total data loss for that player. Two more attempts is a cheap
	hedge against the one failure mode that costs everything.
]]
local LOAD_TRIES = 5

local function load(plr: Player)
	-- see `loading`: PlayerAdded and the GetPlayers sweep can both reach the same
	-- player, and the second restore would overwrite this session's work
	if loading[plr] or loaded[plr] then return end
	loading[plr] = true
	applyDefaults(plr)
 plr:SetAttribute("ProfileStorage",if RunService:IsStudio() then STUDIO_PROFILE_STORE else "SealerProfiles_v1")
	if not store then markLoaded(plr) return end

	local ok, data
	for attempt = 1, LOAD_TRIES do
		ok, data = pcall(function()
			return loadWorldProfile(store, keyFor(plr))
		end)
		if ok then break end
		-- capped, so five tries still fit inside the client's 12-second budget
		if attempt < LOAD_TRIES then task.wait(math.min(attempt, 2)) end
		-- and stop if they gave up on us in the meantime
		if not plr.Parent then return end
	end

	if not ok then
        if not RunService:IsStudio() then
            warn("[UpgradeService] Profile load refused: " .. tostring(data))
            plr:Kick("Your save is unavailable or still active on another server. Please rejoin shortly.")
            return
        end
		warn(("[UpgradeService] load failed for %s after %d tries, so this session"
			.. " will NOT be saved: %s"):format(plr.Name, LOAD_TRIES, tostring(data)))
		--[[
			Told, rather than left to find out.

			Without `loaded` their real profile is safe, but what they are looking at is
			a level-1 account with no cash -- and an hour of work on top of that is an
			hour thrown away at the door. Saying so up front is the only thing that
			makes a read-only session better than a wiped one.
		]]
		markReady(plr)
		BuyResult:FireClient(plr, "Profile", false,
			"Could not load your save -- nothing from this session will be kept."
				.. " Rejoin to try again.")
		return
	end

	-- ok with no table is a player who has never saved, which is a real answer and
	-- must still count as loaded or a brand new profile could never write itself
	if type(data) == "table" then
        plr:SetAttribute("World2Unlocked", data.World2Unlocked == true)
        require(ReplicatedStorage.HalloweenShopState).restore(plr,data)
        require(ReplicatedStorage.ZoneProgress.ZoneProgressState).restore(plr, data)
        require(ReplicatedStorage.BonusZones.BonusState).restore(plr, data)
        require(ReplicatedStorage.SkipZone.SkipZoneState).restore(plr, data)
        require(ReplicatedStorage.SkipRoad.SkipRoadState).restore(plr, data)
plr:SetAttribute("PumpkinCoins", math.max(0, math.floor(tonumber(data.PumpkinCoins) or 0)))
        plr:SetAttribute("GraveyardRuns", math.max(0,math.floor(tonumber(data.GraveyardRuns) or 0)))
        plr:SetAttribute("GraveyardClaim1", math.max(0,math.floor(tonumber(data.GraveyardClaim1) or 0)))
        plr:SetAttribute("GraveyardClaim2", math.max(0,math.floor(tonumber(data.GraveyardClaim2) or 0)))
        plr:SetAttribute("GraveyardClaim3", math.max(0,math.floor(tonumber(data.GraveyardClaim3) or 0)))
        plr:SetAttribute("GraveyardClaim4", math.max(0,math.floor(tonumber(data.GraveyardClaim4) or 0)))
        plr:SetAttribute("GraveyardResetVersion", math.max(0,math.floor(tonumber(data.GraveyardResetVersion) or 0)))
        plr:SetAttribute("GraveyardLapComplete",data.GraveyardLapComplete==true)
        plr:SetAttribute("HalloweenTruckEquipped",data.HalloweenTruckEquipped==true)
		for _, t in ipairs(Upgrades.Tracks) do
			local lv = tonumber((data :: any)[t.id])
			if lv then
				plr:SetAttribute(attrName(t.id), math.clamp(math.floor(lv), 1, #t.values))
			end
		end
		-- Set by DepotGate: the tutorial flags and the yard gate. Persisted here
		-- rather than in their own store so a door cannot end up disagreeing with
		-- the upgrades a profile was saved with.
		-- Quest counters, and how far up each ladder has been claimed. Clamped on
		-- the way in like the levels are: a saved tier past the top of a track
		-- would index past the end of its rewards array.
		for _, c in ipairs(Quests.Counters) do
			local v = tonumber((data :: any)[c])
			if v then plr:SetAttribute(c, math.max(0, math.floor(v))) end
		end
		for _, t in ipairs(Quests.Tracks) do
			local a = Quests.claimedAttr(t.id)
			local v = tonumber((data :: any)[a])
			if v then plr:SetAttribute(a, math.clamp(math.floor(v), 0, #t.tiers)) end
		end
		-- TutReplay rides with them: a replay is armed in one session and spent in the
		-- NEXT one, because the tutorial only restarts on a rejoin. Left out of this
		-- list it would be dropped at exactly the moment it has to survive, and the
		-- re-seal would pay in full. See TutorialReplay.
		for _, flag in ipairs({ "DepotSealed", "TutSealed", "TutBought", "TutorialDone",
			"TutReplay" }) do
			if (data :: any)[flag] then
				plr:SetAttribute(flag, true)
			end
		end
		--[[
			The graphics and sound switches. Restored by TYPE rather than by truthiness,
			which the flags above can afford and these cannot: `false` is a real answer
			here and the whole point of saving them, so `if data[k] then` would silently
			drop every setting a player had turned OFF -- the only ones that matter.
		]]
		for _, k in ipairs(SET_KEYS) do
			local v = (data :: any)[k]
			if type(v) == SET_IS[k] then plr:SetAttribute(k, v) end
		end
		--[[
			Which slabs this player has ever finished, which is what opens the gates at
			the end of each section. Written by DrivewayServer, which recomputes the
			per-section counts whenever it changes -- including on this restore, which
			is the only reason a returning player's road is open when they walk up to it.

			Kept here with everything else for the reason the door flags above are: one
			profile, so a road cannot end up disagreeing with the upgrades it was saved
			alongside. Written back verbatim; Sections owns the format.
		]]
		local sealed = (data :: any)[SECTIONS_KEY]
		if type(sealed) == "string" then
			plr:SetAttribute(SECTIONS_KEY, sealed)
		end
		-- Rebirths taken. Floored at zero on the way in, and no longer capped: the
		-- ladder has no top rung to clamp to, and clamping to one would delete
		-- rebirths a player really took the moment they came back for them.
		local count = tonumber((data :: any)[Rebirth.Attr])
		if count then
			plr:SetAttribute(Rebirth.Attr, math.max(0, math.floor(count)))
		end
		--[[
			And which of them are still black -- RESTORED AFTER THE REBIRTH COUNT, and
			that order is the fix rather than a detail.

			It used to be the other way round, on the reasoning that DrivewayServer
			empties this record whenever the count moves, so the count had to be written
			first -- with a ProfileLoaded check over there as the actual guard. The
			profiles say that guard is not holding: of the ten players on the jobs board,
			every one with a rebirth behind them has SealedNow short of SecSealed, and
			every one without has the two dead level. A player who has never rebirthed is
			the only player whose restore does not MOVE this attribute -- applyDefaults
			already put a 0 there -- which is exactly the population the damage skips.

			So the order is reversed and the argument no longer depends on the other
			file's guard being right. If restoring the count does fire a reset, it fires
			before this line rather than after it, and this line puts the record back.

			Merged rather than written, which covers the other direction: the attribute
			is nil on a fresh Player and only ever grows one key at a time as jobs are
			paid for, so anything already here is work done while the GetAsync was in
			flight -- and that read can take five seconds with its retries, which is long
			enough to finish a walkway in.

			Between the two, the record can only ever grow across a load. That is the
			property worth having; the exact trigger is one I never managed to reproduce.
		]]
		local sealedNow = (data :: any)[NOW_KEY]
		if type(sealedNow) == "string" then
			local live = plr:GetAttribute(NOW_KEY)
			if type(live) == "string" and live ~= "" then
				local set = Sections.decode(sealedNow)
				for k in pairs(Sections.decode(live)) do set[k] = true end
				plr:SetAttribute(NOW_KEY, Sections.encode(set))
			else
				plr:SetAttribute(NOW_KEY, sealedNow)
			end
		end

		-- The pass-shaped one. A plain number, re-validated by the code that reads
		-- it, so a hand-edited profile cannot do more than claim a packet it has
		-- already had.
		local vipDay = tonumber((data :: any)[VIP_DAY_KEY])
		if vipDay then plr:SetAttribute(VIP_DAY_KEY, math.floor(vipDay)) end
		--[[
			The day book: which day the last packet was taken on, and how many days in
			a row. Both plain numbers, and Daily re-derives everything from them against
			today's date, so the worst a hand-edited profile can do is claim one packet
			early or lose its own streak.

			Restored here with everything else rather than in their own store for the
			reason the door flags are, and left alone by the rebirth below on purpose:
			turning up is not something a rebirth should take away.
		]]
		local dailyDay = tonumber((data :: any)[Daily.DayAttr])
		if dailyDay then plr:SetAttribute(Daily.DayAttr, math.floor(dailyDay)) end
		local dailyStreak = tonumber((data :: any)[Daily.StreakAttr])
		if dailyStreak then
			plr:SetAttribute(Daily.StreakAttr, math.max(0, math.floor(dailyStreak)))
		end
		--[[
			Time left on a boost, and it survives a rejoin because it has to: five
			minutes bought thirty seconds before a shutdown is five minutes somebody
			paid Robux for, and a server migration is not their doing.

			Safe to restore verbatim because the stored figure is an ABSOLUTE server
			time rather than a remaining duration -- so a profile that sat on disk for a
			week comes back with a deadline a week in the past, which reads as expired
			without anything having to notice. See the note over Boosts.

			The worst a hand-edited profile can do here is hand itself the boost, which
			is the same trust boundary the whole client-side simulation already sits on
			-- see the note at the top of this file. The wallet is what is defended.
		]]
		for _, b in ipairs(Boosts.List) do
			local a = Boosts.attrName(b.id)
			local until_ = tonumber((data :: any)[a])
			if until_ then plr:SetAttribute(a, until_) end
		end
		--[[
			Which squeegee skins this profile owns.

			The owned list is re-serialised through the catalogue rather than restored
			verbatim: that drops any id which is not a skin any more, so retiring one
			from SqueegeeSkins cannot leave a dead entry riding in every profile that
			ever held it.
		]]
		ColorShop.restore(plr, data)
 -- StellarQuest maxima snapshot
 require(game.ServerScriptService.StellarQuestService).restoreMaxima(plr,data)
		SpinWheel.restore(plr, data)
		local ownedRaw = (data :: any)[Skins.OwnedAttr]
		if type(ownedRaw) == "string" then
			plr:SetAttribute(Skins.OwnedAttr, ownedRaw)
			plr:SetAttribute(Skins.OwnedAttr, Skins.serialise(Skins.ownedSet(plr)))
		end

		-- Which skin they were wearing. Validated against the list for the same
		-- reason the owned string is re-serialised.
		local worn = (data :: any)[Skins.Attr]
		if type(worn) == "string" and Skins.ById[worn] then
			plr:SetAttribute(Skins.Attr, worn)
		end
		-- The pets, restored through the same two rules as the wardrobe: the
		-- owned string is re-serialised through the catalogue so a retired pet id
		-- cannot ride in a profile forever, and the choice is dropped unless they
		-- still own it.
		do
			local Pets = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Pets"))
			local ownedRaw = (data :: any)[Pets.OwnedAttr]
			if type(ownedRaw) == "string" and ownedRaw ~= "" then
				plr:SetAttribute(Pets.OwnedAttr, ownedRaw)
				plr:SetAttribute(Pets.OwnedAttr, Pets.serialise(Pets.ownedSet(plr)))
			end
			require(game.ServerScriptService.PetRewardRecovery).ensure(plr)
			local equipped = (data :: any)[Pets.Attr]
			if type(equipped) == "string" and equipped ~= "" and Pets.owns(plr, equipped) then
				plr:SetAttribute(Pets.Attr, equipped)
			end
		end
		--[[
			A doubling that was bought and not yet granted, restored for exactly the
			reason PendingRobux below is: the receipt for it can arrive on THIS join,
			after a session that ended between the dialog and the grant, and the figure
			it pays is not in the receipt -- it is this.

			Validated no further than being a positive number. Unlike a track id there
			is nothing to check it against, so the trust boundary is the same one the
			boosts sit on above: a hand-edited profile could inflate its own doubling,
			and the wallet it would be inflating is the same one a tampered client can
			already lie to about coverage. Nothing here is worth a second store.
		]]
		local owed = tonumber((data :: any)[DoubleUp.OwedAttr])
		if owed and owed >= 1 then
			plr:SetAttribute(DoubleUp.OwedAttr, math.floor(owed))
		end
		-- A prompt opened last session whose receipt has not been granted yet, and
		-- the receipts that have. Both must be back in memory before ProcessReceipt
		-- is allowed to run, which is what markLoaded gates.
		local intent = (data :: any).PendingRobux
		if type(intent) == "string" and Upgrades.ById[intent] then
			pending[plr.UserId] = intent
		end
		local receipts = (data :: any).Receipts
		if type(receipts) == "table" then
			local list = {}
			for _, v in ipairs(receipts) do
				if type(v) == "string" then table.insert(list, v) end
			end
			handled[plr.UserId] = list
		end
		--[[
			Cash, and this waits INLINE rather than on its own thread.

			It used to be a task.spawn, so markLoaded ran immediately while the wallet
			was still empty -- and `loaded` is the only thing gating save(). A player who
			joined and left inside that five-second window was saved with
			`data.Cash = c.Value` read off a leaderstat still sitting at zero, which wrote
			their real balance to nothing. Narrow, but it is the exact shape of "my
			progress did not save when I left".

			Blocking here only delays ProfileLoaded, and only for as long as DrivewayServer
			takes to build leaderstats -- normally no time at all, capped at five seconds,
			and TutorialClient allows twelve before it stops waiting.
		]]
		local cash = tonumber((data :: any).Cash)
		if cash then
			-- leaderstats is built by DrivewayServer, which may not have run yet
			local c = cashOf(plr)
			local t0 = os.clock()
			while not c and os.clock() - t0 < 5 and plr.Parent do
				task.wait(0.1)
				c = cashOf(plr)
			end
			-- gone while we waited: leave `loaded` false so save() cannot write a
			-- half-restored profile over the real one
			if not plr.Parent then return end
			if c then c.Value = math.max(0, math.floor(cash)) end
		end
	end
	markLoaded(plr)
end

--[[
	How many times a write is retried before the session's work is written off.

	SetAsync throws on a throttle, and a throttle is exactly what a busy shutdown
	looks like -- so the one attempt this used to make was most likely to fail in
	the moment it mattered most. 1s then 2s, which fits inside the BindToClose
	budget below even with every player saving at once.
]]
local SAVE_TRIES = 3

local function saveSnapshot(plr: Player, release: boolean?): boolean
	if not store or not loaded[plr] or releasedWorldProfiles[plr] then return false end
	-- Studio writes only its isolated test store; live profiles are read once to seed it.
	local data: { [string]: any } = {}
	for _, t in ipairs(Upgrades.Tracks) do
		data[t.id] = plr:GetAttribute(attrName(t.id)) :: number or 1
	end
	local c = cashOf(plr)
	data.Cash = c and c.Value or 0
	require(ReplicatedStorage.HalloweenShopState).capture(plr,data)
    require(ReplicatedStorage.ZoneProgress.ZoneProgressState).capture(plr, data)
    require(ReplicatedStorage.BonusZones.BonusState).capture(plr, data)
    require(ReplicatedStorage.SkipZone.SkipZoneState).capture(plr, data)
    require(ReplicatedStorage.SkipRoad.SkipRoadState).capture(plr, data)
data.PumpkinCoins = plr:GetAttribute("PumpkinCoins") or 0
	data.GraveyardRuns=plr:GetAttribute("GraveyardRuns") or 0
	data.GraveyardClaim1=plr:GetAttribute("GraveyardClaim1") or 0
	data.GraveyardClaim2=plr:GetAttribute("GraveyardClaim2") or 0
	data.GraveyardClaim3=plr:GetAttribute("GraveyardClaim3") or 0
	data.GraveyardClaim4=plr:GetAttribute("GraveyardClaim4") or 0
	data.GraveyardResetVersion=plr:GetAttribute("GraveyardResetVersion") or 0
	data.GraveyardLapComplete=plr:GetAttribute("GraveyardLapComplete")==true
	data.HalloweenTruckEquipped=plr:GetAttribute("HalloweenTruckEquipped")==true
	data.World2Unlocked = plr:GetAttribute("World2Unlocked") == true
	for _, flag in ipairs({ "DepotSealed", "TutSealed", "TutBought", "TutorialDone",
		"TutReplay" }) do
		data[flag] = plr:GetAttribute(flag) and true or nil
	end
	-- nil for anything never touched, so a profile only carries the switches its
	-- owner actually moved
	for _, k in ipairs(SET_KEYS) do
		local v = plr:GetAttribute(k)
		data[k] = if type(v) == SET_IS[k] then v else nil
	end
	data[SECTIONS_KEY] = plr:GetAttribute(SECTIONS_KEY) :: string? or nil
	data[NOW_KEY] = plr:GetAttribute(NOW_KEY) :: string? or nil
	data[Rebirth.Attr] = Rebirth.countOf(plr)
	data[VIP_DAY_KEY] = plr:GetAttribute(VIP_DAY_KEY) :: number? or nil
	data[Daily.DayAttr] = plr:GetAttribute(Daily.DayAttr) :: number? or nil
	data[Daily.StreakAttr] = plr:GetAttribute(Daily.StreakAttr) :: number? or 0
	for _, c in ipairs(Quests.Counters) do
		data[c] = plr:GetAttribute(c) or 0
	end
	for _, t in ipairs(Quests.Tracks) do
		data[Quests.claimedAttr(t.id)] = plr:GetAttribute(Quests.claimedAttr(t.id)) or 0
	end
	-- Written only while there is time left on it. A spent deadline is noise in
	-- every profile that has ever bought one, and applyDefaults puts the zero back.
	for _, b in ipairs(Boosts.List) do
		local a = Boosts.attrName(b.id)
		local until_ = plr:GetAttribute(a) :: number?
		data[a] = if until_ and until_ > Boosts.now() then until_ else nil
	end
	-- The wardrobe: which skins are owned, and which one is worn. The owned string
	-- is written even when it is only the starter -- unlike a spent boost deadline
	-- it is not noise, it is the record every future grant is diffed against.
	data[Skins.OwnedAttr] = plr:GetAttribute(Skins.OwnedAttr) :: string? or nil
	data[Skins.Attr] = plr:GetAttribute(Skins.Attr) :: string? or nil
	-- The pets: which are owned, and which one is out. Same two-field shape as
	-- the wardrobe above.
	local Pets = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Pets"))
	require(game.ServerScriptService.PetRewardRecovery).ensure(plr)
	data[Pets.OwnedAttr] = plr:GetAttribute(Pets.OwnedAttr) :: string? or nil
	data[Pets.Attr] = plr:GetAttribute(Pets.Attr) :: string? or nil
	ColorShop.capture(plr, data)
	SpinWheel.capture(plr, data)
	data.PendingRobux = pending[plr.UserId]
	-- Written only while one is outstanding, for the reason a spent boost deadline
	-- is not: a zero in every profile that has ever bought one is noise, and
	-- nothing reads this except the restore above.
	local owedNow = DoubleUp.owedOf(plr)
	data[DoubleUp.OwedAttr] = if owedNow > 0 then owedNow else nil
	data.Receipts = handled[plr.UserId]
	local ok, err
	for attempt = 1, SAVE_TRIES do
		ok, err = pcall(function()
			local wrote = false
            (store :: DataStore):UpdateAsync(keyFor(plr), function(previous)
                wrote = false
                local lease = type(previous) == "table" and previous.WorldLease
                if type(lease) ~= "table" or lease.token ~= worldSession then return nil end
                local merged = WorldProfile.merge(previous, data, WORLD, BASE_MAX, resetWorldExtras[plr] == true)
                merged.WorldLease = if release then nil else {token=worldSession, expires=os.time()+LEASE_SECONDS}
                wrote = true
                return merged
            end)
            if not wrote then error("Profile session ownership changed; save cancelled") end
		end)
		if ok then break end
		if attempt < SAVE_TRIES then task.wait(attempt) end
	end
	if not ok then
		warn(("[UpgradeService] save failed for %s after %d tries: %s")
			:format(plr.Name, SAVE_TRIES, tostring(err)))
	end
	if ok and release then releasedWorldProfiles[plr] = true end
 return ok == true
end
local colorSaveLocks: {[Player]: boolean} = {}
local function save(plr: Player, release: boolean?): boolean
	local deadline = os.clock() + 20
	while colorSaveLocks[plr] do
		if os.clock() > deadline then return false end
		task.wait(0.1)
	end
	colorSaveLocks[plr] = true
	local ok, saved = pcall(saveSnapshot, plr, release)
	colorSaveLocks[plr] = nil
	if not ok then
		warn("[UpgradeService] Profile serialization failed: " .. tostring(saved))
		return false
	end
	return saved == true
end

--[[
	And the doubling gets to push its own note straight to the store.

	Same rule as the Robux till below -- the note goes down before the dialog goes
	up -- and this is what makes it true for a purchase that starts in another
	file. Without it the note still rides out on the autosave and on
	PlayerRemoving, so what this actually covers is a server dying inside the few
	seconds a purchase dialog is open.
]]
local worldSave = Instance.new("BindableFunction")
worldSave.Name = "WorldTravelSave"
worldSave.OnInvoke = function(plr)
 if WORLD == "1" then
  for _,section in ipairs(Sections.List) do
   if section.id == "NewZone" then
    local done,total = Sections.progressOf(plr,section)
    if total > 0 and done >= total then plr:SetAttribute("World2Unlocked",true) end
   end
  end
 end
 if RunService:IsStudio() then return loaded[plr] == true end
 return save(plr)
end
worldSave.Parent = game.ServerScriptService
local graveyardSave=Instance.new("BindableFunction")
graveyardSave.Name="GraveyardSave"
graveyardSave.OnInvoke=function(plr) return save(plr) end
graveyardSave.Parent=game.ServerScriptService

require(game.ServerScriptService.SkipZoneService).configure(save, function(player)
    return loaded[player] == true and not releasedWorldProfiles[player]
end)

require(game.ServerScriptService.SkipRoadService).configure(save, function(player)
    return loaded[player] == true and not releasedWorldProfiles[player]
end)
DoubleUpService.provideSave(save)
-- And the skin shop, so a purchase is on disk before the player can close the
-- game on it.
SkinShop.provideSave(save)
ColorShop.provideSave(save, function(plr) return loaded[plr] == true and (store ~= nil or RunService:IsStudio()) end)
SpinWheel.start(save, function(plr) return loaded[plr] == true end)
require(game.ServerScriptService:WaitForChild("PumpkinCurrency")).configure(save, function(plr) return loaded[plr] == true and not releasedWorldProfiles[plr] end)

--==[ PENDING GRANTS ]=======================================================

--[[
	Cash owed to a player, paid into their wallet BY THEIR OWN SESSION.

	WHY THIS EXISTS RATHER THAN JUST EDITING THE SAVED PROFILE. Writing cash
	straight into a profile only works while the player is offline, and there is no
	way to know that they are: someone in a live server holds their balance in
	memory over there, and when that server saves them on the way out it writes its
	own figure straight over yours. Measured on 2026-08-14 -- two grants of a
	million were written to the store and both were gone within the hour. One came
	back reading 7,203 against the 5,402 it had been written onto, which is the
	proof: that is the player's own earnings continuing from a balance where the
	grant had simply never happened.

	So this stops fighting the session and lets it do the work. The amount is
	written to a store nothing else touches, and the player's next join reads it,
	adds it, and zeroes it. There is no race left to lose, because the only writer
	of a wallet is the one session that owns it.

	TO OWE SOMEBODY MONEY, from the command bar -- no game code needed:

		local s = game:GetService("DataStoreService"):GetDataStore("Grants_v1")
		s:SetAsync("g_" .. USER_ID, { amount = 1000000, note = "launch gift" })

	ZEROED RATHER THAN DELETED once paid, and the reason is a genuine trap:
	returning nil from an UpdateAsync transform ABORTS the write, it does not remove
	the key. Written the obvious way this would have re-paid the same grant on every
	join, forever. A key sitting at zero is also a record that it was paid, which a
	deleted one is not.
]]
local GRANTS_STORE = "Grants_v1"
-- IntValue is 32-bit and wraps NEGATIVE past this -- the ceiling DevCash clamps to
-- for the same reason. A grant is the one path that can arrive at any size.
local MAX_CASH = 2 ^ 31 - 1

-- Set once this session has applied a grant but not yet confirmed it on disk.
-- Keeps a retry to re-saving instead of re-paying; see applyGrant.
local credited: { [Player]: string } = {}
Players.PlayerRemoving:Connect(function(plr) credited[plr] = nil end)

--[[
	WHAT A GRANT MAY CONTAIN, and the two rules that make it safe to hand out.

		{ cash = 1000000, upgrades = { Tank = 16 }, rebirths = 3, skins = { "Gold" } }

	CASH AND SKINS ARE ADDED. LEVELS AND REBIRTHS ARE RAISED TO, NEVER DOWN TO.
	That asymmetry is the whole safety argument: a grant is a gift, so there must be
	no way to write one that takes something away. Handing somebody "Tank = 5" when
	they are already on 14 does nothing rather than demoting them, which also makes
	every grant safe to apply twice -- and it will be applied twice, because the
	retry below re-runs it whenever a save could not be confirmed.

	Everything is clamped to what the game itself allows: a level to the length of
	its own track, cash to the 32-bit ceiling an IntValue wraps at, a skin to an id
	that actually exists. A grant is typed by hand into a text box, so it is the one
	input in the game most likely to contain a typo.

	Returns a human summary of what actually changed, or "" if nothing did.
]]
local function applyPayload(plr: Player, p: { [string]: any }): string
	local did: { string } = {}

	-- `amount` is the original cash-only shape, still accepted so grants queued
	-- before this existed are not stranded
	local cash = tonumber(p.cash) or tonumber(p.amount)
	if cash and cash > 0 then
		local c = cashOf(plr)
		if c then
			c.Value = math.clamp(math.floor(c.Value + cash), 0, MAX_CASH)
			did[#did + 1] = ("$%d"):format(math.floor(cash))
		end
	end

	if type(p.upgrades) == "table" then
		for _, t in ipairs(Upgrades.Tracks) do
			local want = tonumber((p.upgrades :: any)[t.id])
			if want then
				local target = math.clamp(math.floor(want), 1, #t.values)
				local have = (plr:GetAttribute(attrName(t.id)) :: number?) or 1
				if target > have then
					plr:SetAttribute(attrName(t.id), target)
					did[#did + 1] = ("%s Lv%d"):format(t.id, target)
				end
			end
		end
	end

	local rb = tonumber(p.rebirths)
	if rb then
		local target = math.max(0, math.floor(rb))
		if target > Rebirth.countOf(plr) then
			plr:SetAttribute(Rebirth.Attr, target)
			did[#did + 1] = ("Rebirths %d"):format(target)
		end
	end

	if type(p.skins) == "table" then
		local set = Skins.ownedSet(plr)
		local added = 0
		for _, id in ipairs(p.skins :: { any }) do
			if type(id) == "string" and Skins.ById[id] and not set[id] then
				set[id] = true
				added += 1
			end
		end
		if added > 0 then
			plr:SetAttribute(Skins.OwnedAttr, Skins.serialise(set))
			did[#did + 1] = ("%d skin(s)"):format(added)
		end
	end

	return table.concat(did, ", ")
end

-- Whether a queued entry is worth acting on at all. Distinct from applyPayload
-- returning "": an entry that asks for Tank 5 on a player already at 14 HAS
-- content and should be retired, it just changes nothing.
local function hasContent(p: { [string]: any }): boolean
	if (tonumber(p.cash) or tonumber(p.amount) or 0) > 0 then return true end
	if tonumber(p.rebirths) then return true end
	if type(p.upgrades) == "table" and next(p.upgrades :: any) ~= nil then return true end
	if type(p.skins) == "table" and #(p.skins :: { any }) > 0 then return true end
	return false
end

local grants: DataStore? = nil
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore(GRANTS_STORE)
	end)
	grants = ok and s or nil
end

local function applyGrant(plr: Player)
	--[[
		STUDIO NEVER COLLECTS ONE, and this guard is not optional.

		save() refuses to write from Studio. Without this, a playtest would zero a real
		player's grant in the live store and then fail to persist the cash it paid for
		-- the money gone AND the record of owing it gone with it. Same rule the rest of
		this file follows: Studio reads, Studio does not write.
	]]
	if RunService:IsStudio() then return end
	-- `loaded` false means the profile read failed, and save() is a no-op for the
	-- rest of this session -- so paying now would zero the grant and lose the cash
	if not grants or not loaded[plr] then return end

	--[[
		CREDIT FIRST, RETIRE THE KEY LAST -- and that order is the whole correctness
		argument. It was the other way round and it cost two players a million each.

		The first version zeroed the grant inside the UpdateAsync that read it, then
		went looking for the wallet. Everything after the zero was unprotected: two
		early returns, a save() that no-ops when `loaded` is false, and the straggler
		save -- a player moving from an old server to a new one has the PREVIOUS
		session's save land late, after the new session has loaded and paid, writing a
		pre-grant balance over the top.

		WHICH of those fired on 2026-08-14 was never established, and the honest record
		is that it did not need to be. What was measured is that both keys read
		amount=0 with a paid stamp while neither profile had ever held the money, and
		that there was nothing left to retry from -- the record of the debt was the very
		thing the code destroyed first. A design where the only durable evidence is
		erased before the work is done has no good failure, so the ordering is the fix
		whether or not the exact trigger is ever named.

		So the key is now the LAST thing to move, and only once the store has been read
		back and agrees. Anything that goes wrong before that leaves the grant standing,
		and the poll below simply tries again twenty seconds later. The failure mode
		turns from "money silently gone" into "money arrives a little late".
	]]
	local owed = credited[plr]
	if not owed then
		-- A plain read: nothing is written until the gift is actually in their hands.
		local ok, entry = pcall(function()
			return (grants :: DataStore):GetAsync("g_" .. plr.UserId)
		end)
		if not ok then return end
		-- a bare number is the very first shape this store ever held
		local payload: { [string]: any }
		if type(entry) == "table" then
			payload = entry :: any
		elseif type(entry) == "number" then
			payload = { cash = entry }
		else
			return
		end
		if not hasContent(payload) then return end
		if not cashOf(plr) then return end
		local summary = applyPayload(plr, payload)
		--[[
			Remembered for this session, so a retry re-saves rather than re-applying.
			The payload is idempotent by construction -- see applyPayload -- so a second
			application would be harmless for levels and skins, but NOT for cash, which
			is added. This is what keeps that from happening.
		]]
		credited[plr] = if summary ~= "" then summary else "nothing outstanding"
		owed = credited[plr]
		if summary ~= "" then
			BuyResult:FireClient(plr, "Grant", true, ("You received: %s"):format(summary))
		end
	end

	-- Force it to disk, then ask the store what it actually holds. A straggler that
	-- clobbered us shows up here as a mismatch, and re-saving from memory -- which
	-- still has the grant in it -- is what repairs it.
	save(plr)
	local c = cashOf(plr)
	if not c then return end
	local ok2, stored = pcall(function()
		return (store :: DataStore):GetAsync(keyFor(plr))
	end)
	if not (ok2 and type(stored) == "table" and tonumber((stored :: any).Cash) == c.Value) then
		warn(("[UpgradeService] grant (%s) for %s is not on disk yet -- left"
			.. " outstanding, the poll will retry"):format(tostring(owed), plr.Name))
		return
	end

	-- Confirmed. Now, and only now, the debt is settled.
	local ok3 = pcall(function()
		(grants :: DataStore):UpdateAsync("g_" .. plr.UserId, function(entry)
			local amount = 0
			if type(entry) == "table" then
				amount = tonumber((entry :: any).amount) or 0
			elseif type(entry) == "number" then
				amount = entry
			end
			-- already zero: abort rather than write a zero over a zero forever
			if amount <= 0 then return nil end
			return { amount = 0, paid = os.time() }
		end)
	end)
	if ok3 then
		credited[plr] = nil
		print(("[UpgradeService] granted %s to %s"):format(tostring(owed), plr.Name))
	end
end

-- After load, never beside it: the grant is added to the balance the profile
-- restored, so it has to land after that restore has written it.
local function loadThenGrant(plr: Player)
	load(plr)
	applyGrant(plr)
end

Players.PlayerAdded:Connect(function(plr)
	task.spawn(loadThenGrant, plr)
end)
for _, plr in ipairs(Players:GetPlayers()) do task.spawn(loadThenGrant, plr) end

--[[
	AND AGAIN WHILE THEY PLAY, so a grant can be paid to somebody who is already
	in a server rather than only at their next join.

	The join-time claim above is the whole mechanism when the queue is written in
	advance. It is not enough when the queue is written WHILE they are playing: the
	only way to collect it would be to leave and come back, which for a live server
	is the thing this was meant to avoid.

	A POLL RATHER THAN A MESSAGE, and that is a deliberate trade. MessagingService
	would be instant, but nothing can publish to a live topic except another live
	server or the Open Cloud API -- Studio's command bar cannot, and the command bar
	is where this actually gets used. A DataStore is the one channel both ends can
	reach: Studio writes the key, the server notices within the interval.

	CHEAP READ FIRST. Almost every poll finds nothing, so the common path is a
	single GetAsync and no write at all -- UpdateAsync would spend write budget on
	every player every interval to discover that nobody is owed anything. The claim
	itself still goes through applyGrant's UpdateAsync, which is what keeps it
	exactly-once; this read only decides whether it is worth asking.

	Budget: one GetAsync per player per interval. GetAsync allows 60 + 10 per player
	a minute, so at 20 seconds a 20-player server spends 60 of an allowance of 260.
]]
local GRANT_POLL = 20   -- seconds

local function pollGrant(plr: Player)
	-- the same two guards applyGrant opens with, applied before spending a read
	if RunService:IsStudio() then return end
	if not grants or not loaded[plr] then return end
	-- Already applied this session and waiting on a confirmed save: go straight in,
	-- because what needs retrying is the WRITE, and the queue may already read empty.
	if credited[plr] then applyGrant(plr) return end
	local ok, entry = pcall(function()
		return (grants :: DataStore):GetAsync("g_" .. plr.UserId)
	end)
	-- a failed read is not worth a warn every 20 seconds; the next poll retries
	if not ok then return end
	local has = false
	if type(entry) == "table" then
		has = hasContent(entry :: any)
	elseif type(entry) == "number" then
		has = entry > 0
	end
	if not has then return end
	applyGrant(plr)
end

task.spawn(function()
	while true do
		task.wait(GRANT_POLL)
		-- spawned per player so one slow read cannot hold up the rest of the sweep,
		-- the same shape BindToClose uses for the same reason
		for _, plr in ipairs(Players:GetPlayers()) do
			task.spawn(pollGrant, plr)
		end
	end
end)

--==[ THE ADMIN DESK ]=======================================================

--[[
	Handing things out from inside the game, for the people allowed to.

	WHO IS ALLOWED IS DECIDED HERE AND NOWHERE ELSE. A client tells this remote a
	name and a payload, and both are worth nothing on their own -- the only thing
	that authorises the grant is the UserId Roblox itself attaches to the call.
	So the check is against a list written into the server, not against anything
	sent, and not against a flag on the player that a client could hope to move.
	The panel on the client is a convenience for typing; it is not the gate. Anyone
	can fire this remote -- that is what a RemoteFunction is -- and everyone who is
	not on this list gets the same refusal.

	If this ever grows past a couple of people, move it to a group rank rather than
	lengthening the table: an id in a source file is a redeploy every time it
	changes, and the temptation then is to make it editable at runtime, which is
	exactly the door this is meant to be.
]]
local ADMINS: { [number]: boolean } = {
	[1210700083] = true,   -- IsABigBot, the owner
	[139112508]  = true,   -- Endey678
	[3159364800] = true,   -- sooad_sooad
	[254153724]  = true,   -- imad166
}

--[[
	WHO GAVE WHAT TO WHOM, written down somewhere that outlives the server.

	The console prints below are gone the moment the server shuts down, which is
	fine while one person can grant and useless the moment four can. This is the
	record you read weeks later when a player is suddenly holding ten million and
	nobody remembers authorising it.

	REFUSALS ARE LOGGED TOO, and they are the entries actually worth reading. A
	grant by somebody on the list is routine; an attempt by somebody who is NOT on
	it means either an admin was removed and does not know, or a client is firing
	the remote by hand -- and the second one is the thing you want to find out about
	from a log rather than from an economy that has quietly stopped making sense.

	FIRE AND FORGET. Spawned, never awaited, and every failure swallowed: a slow or
	broken log must not delay the grant it is describing, and must certainly not
	fail it. A missing log entry costs an audit trail; a grant that errors because
	its log could not be written costs a player their compensation.

	KEYED BY TIME so the store reads chronologically, with a random tail because two
	grants inside the same second would otherwise overwrite each other -- easily
	done when handing the same reward to a list of people.
]]
local grantLog: DataStore? = nil
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore("GrantLog_v1")
	end)
	grantLog = ok and s or nil
end

local function logGrant(by: Player, toName: string, toId: number?,
	mode: string, what: string, payload: any)
	-- Studio never writes, the same rule the rest of this file follows: a playtest
	-- grant does not persist, so an entry claiming it happened would be a lie.
	if RunService:IsStudio() then return end
	if not grantLog then return end
	task.spawn(function()
		pcall(function()
			(grantLog :: DataStore):SetAsync(
				("L_%d_%d_%04d"):format(os.time(), by.UserId, math.random(0, 9999)), {
					at = os.time(),
					by = by.UserId, byName = by.Name,
					to = toId, toName = toName,
					mode = mode,       -- "live" | "queued" | "refused"
					what = what,       -- what actually changed, or why it did not
					asked = payload,   -- what was requested, verbatim
				})
		end)
	end)
end

--[[
	ONE REFUSAL IS AN AUDIT ENTRY; A THOUSAND A SECOND ARE A DENIAL OF SERVICE.

	logGrant is fire-and-forget, and that is exactly what made the refusal path
	dangerous: nothing on this remote stopped a modified client invoking it in a
	loop, and every invocation bought a coroutine and a SetAsync. The write budget
	is 60 + 10 per player per minute and it is SHARED -- so a client spinning on a
	refusal did not just fill the grant log, it pushed this file's own profile
	saves behind its backlog: the PlayerRemoving save, and the shutdown drain that
	has thirty seconds and no more. The cost of an unauthorised call was somebody
	else's progress.

	So a refused caller is dropped on a per-player clock, and only the FIRST
	attempt in each window is written down. That is not a thinner audit trail:
	one deliberate attempt and a loop of ten thousand both want the same entry --
	who, and when -- and the other 9,999 copies say nothing the first does not.

	ADMINS ARE DELIBERATELY NOT RATE LIMITED. Handing the same reward to a list of
	people arrives as a burst of invocations by design (it is why the log key has a
	random tail at all); throttling that would break the one thing this remote is
	for. The admin check is a single table lookup, so it costs nothing to put the
	limit behind it.

	os.clock, not os.time: monotonic, cannot be dragged backwards, and this only
	ever measures a gap inside one server's lifetime.
]]
local REFUSE_COOLDOWN = 30   -- seconds; at most one logged refusal per player per window
local refusedAt: { [Player]: number } = {}
-- Keyed by Player, so it has to be cleared when they leave or it pins a reference
-- to everyone the server has ever refused. Same shape as `credited` above.
Players.PlayerRemoving:Connect(function(plr) refusedAt[plr] = nil end)

-- NOT remote() above -- that helper only ever makes RemoteEvents, and this has to
-- answer the caller with whether the grant landed. Built by hand for that reason.
local adminGrant = remotes:FindFirstChild("AdminGrant")
if adminGrant and not adminGrant:IsA("RemoteFunction") then
	-- a place saved while this was briefly a RemoteEvent; replace it rather than
	-- leaving something that cannot be invoked sitting under the right name
	adminGrant:Destroy()
	adminGrant = nil
end
if not adminGrant then
	local r = Instance.new("RemoteFunction")
	r.Name = "AdminGrant"
	r.Parent = remotes
	adminGrant = r
end

--[[
	LIVE IF THEY ARE HERE, QUEUED IF THEY ARE NOT -- and the caller is told which.

	A player in this server is holding their own wallet in memory, so the grant is
	applied to it directly and saved: instant, and it cannot be lost to the race
	that the queue exists to dodge. Anyone else goes into Grants_v1 and is paid by
	their own next session, which is the same path the poll above serves.

	The queue write MERGES rather than overwrites. Two grants sent to an offline
	player before they next log in should both arrive; SetAsync would silently keep
	only the second, and the person sending them would have no way to tell.
]]
(adminGrant :: RemoteFunction).OnServerInvoke = function(plr: Player, targetName: any, payload: any)
	--[[
		SHAPE FIRST, AUTHORISATION SECOND -- but the shape verdict is HELD, not returned.

		All three of these are O(1) reads off the arguments, and a malformed call is
		malformed whoever sent it, so checking them first is what stops an
		attacker-sized payload ever reaching the log below.

		Returning here would be the mistake, though, and it is a subtle one: an
		unauthorised caller could then probe this remote in COMPLETE SILENCE just by
		sending rubbish -- no warn, no log entry, at any rate -- which is precisely what
		the refusal trail exists to catch. So a non-admin falls through to the branch
		below and is recorded on the same cooldown whether their arguments were well
		formed or not, and only an ADMIN gets the shape complaint back as their answer.

		A non-admin is told "Not authorised" either way: which of their arguments was
		wrong is not something an unauthorised caller needs to learn.
	]]
	local bad: string? = nil
	if type(targetName) ~= "string" or targetName == "" then
		bad = "No player named"
	elseif type(payload) ~= "table" or not hasContent(payload) then
		bad = "Nothing to grant"
	end

	if not ADMINS[plr.UserId] then
		-- A table lookup and a subtraction, then out: no coroutine, no SetAsync. Only
		-- the first refusal in each REFUSE_COOLDOWN window is written down; see the
		-- note above the table for why that is the same audit trail, not a weaker one.
		local now = os.clock()
		local last = refusedAt[plr]
		if last == nil or now - last >= REFUSE_COOLDOWN then
			refusedAt[plr] = now
			warn(("[UpgradeService] %s (%d) tried to use AdminGrant")
				:format(plr.Name, plr.UserId))
			-- The payload's SIZE is the caller's choice and `asked` is stored verbatim, so
			-- it is omitted here. A refusal is worth who and when; nobody unauthorised gets
			-- to choose how many bytes we persist for them. The name is cut to 20 for the
			-- same reason -- the longest a real Roblox username can be -- and guarded,
			-- because a malformed call reaches this branch now too and targetName may not
			-- be a string at all.
			local who = if type(targetName) == "string" then targetName:sub(1, 20) else "<malformed>"
			logGrant(plr, who, nil, "refused",
				if bad then "not on the admin list; " .. bad else "not on the admin list", nil)
		end
		return false, "Not authorised"
	end

	-- Held from above: an admin gets the real complaint, and gets it before any of
	-- the work below.
	if bad then return false, bad end

	-- Resolve by name so the sender never has to know a UserId. An unknown name
	-- throws rather than returning nil, hence the pcall.
	local okId, uid = pcall(function()
		return Players:GetUserIdFromNameAsync(targetName)
	end)
	if not okId or type(uid) ~= "number" then
		return false, ("No Roblox user called %q"):format(targetName)
	end

	local here = Players:GetPlayerByUserId(uid)
	if here and loaded[here] then
		local summary = applyPayload(here, payload)
		if summary == "" then return false, "They already have all of that" end
		save(here)
		BuyResult:FireClient(here, "Grant", true, ("You received: %s"):format(summary))
		print(("[UpgradeService] %s granted %s to %s (live)")
			:format(plr.Name, summary, here.Name))
		logGrant(plr, here.Name, uid, "live", summary, payload)
		return true, ("%s got %s"):format(here.Name, summary)
	end

	if not grants then return false, "No DataStore access" end
	local okQ, err = pcall(function()
		(grants :: DataStore):UpdateAsync("g_" .. uid, function(old)
			local merged: { [string]: any } = {}
			if type(old) == "table" then
				for k, v in pairs(old :: any) do merged[k] = v end
			elseif type(old) == "number" then
				merged.cash = old
			end
			merged.cash = (tonumber(merged.cash) or tonumber(merged.amount) or 0)
				+ (tonumber(payload.cash) or tonumber(payload.amount) or 0)
			merged.amount = nil   -- folded into cash; one field from here on
			if type(payload.upgrades) == "table" then
				local up: { [string]: any } = if type(merged.upgrades) == "table"
					then merged.upgrades else {}
				-- the higher of the two, matching applyPayload's raise-only rule
				for id, lv in pairs(payload.upgrades :: any) do
					if type(lv) == "number" and lv > (tonumber(up[id]) or 0) then up[id] = lv end
				end
				merged.upgrades = up
			end
			if tonumber(payload.rebirths) then
				merged.rebirths = math.max(tonumber(merged.rebirths) or 0,
					tonumber(payload.rebirths) :: number)
			end
			if type(payload.skins) == "table" then
				local sk: { any } = if type(merged.skins) == "table" then merged.skins else {}
				for _, id in ipairs(payload.skins :: { any }) do
					if table.find(sk, id) == nil then sk[#sk + 1] = id end
				end
				merged.skins = sk
			end
			merged.paid = nil   -- outstanding again
			merged.note = ("queued by %s"):format(plr.Name)
			return merged
		end)
	end)
	if not okQ then return false, ("Queue write failed: %s"):format(tostring(err)) end
	print(("[UpgradeService] %s queued a grant for %s (%d), offline")
		:format(plr.Name, targetName, uid))
	logGrant(plr, targetName, uid, "queued", "collected on their next join", payload)
	return true, ("%s is offline -- queued, they get it on their next join"):format(targetName)
end

Players.PlayerRemoving:Connect(function(plr)
	save(plr, true)
	loaded[plr] = nil
	loading[plr] = nil
	-- after save, which is what writes them down; a receipt arriving for a player
	-- who has left is answered on their next join off the profile instead
	pending[plr.UserId] = nil
	handled[plr.UserId] = nil
end)
--[[
	The shutdown save, and it has to run EVERYONE AT ONCE.

	This is the path a game update takes: Roblox shuts every old server down and the
	players on them migrate. It used to be a plain sequential loop, so with a full
	server it was N SetAsync round trips end to end -- each one able to yield for a
	second or more, and more likely to throttle the more of them there were. Roblox
	gives BindToClose about thirty seconds and then kills the server regardless, so
	the players at the back of that loop were never written at all. Whoever was last
	in the list lost whatever they had done since the last autosave, every update.

	Spawned per player, they overlap and the whole thing costs about one save. The
	deadline is what stops a wedged write holding the shutdown open until Roblox
	pulls the plug mid-SetAsync.
]]
local CLOSE_DEADLINE = 25   -- seconds; Roblox allows ~30 before it stops waiting

game:BindToClose(function()
	local players = Players:GetPlayers()
	if #players == 0 then return end
	local outstanding = #players
	for _, plr in ipairs(players) do
		task.spawn(function()
			save(plr, true)
			outstanding -= 1
		end)
	end
	local t0 = os.clock()
	while outstanding > 0 and os.clock() - t0 < CLOSE_DEADLINE do task.wait(0.1) end
	if outstanding > 0 then
		warn(("[UpgradeService] shutdown: %d save(s) did not finish in %ds")
			:format(outstanding, CLOSE_DEADLINE))
	end
end)
-- periodic autosave so a crash costs minutes, not a session
task.spawn(function()
	while true do
		task.wait(120)
		for _, plr in ipairs(Players:GetPlayers()) do save(plr) end
	end
end)

--==[ where you may buy ]=====================================================
--[[
	Buying used to require standing on the garage's floor slab, and that is what
	made the shop look broken: the Upgrades panel opens from the icon rail
	anywhere on the map, and the depot's own spawn point is ~28 studs outside the
	slab, so the very first buy a player tries -- with money in the corner of the
	screen -- comes back "Upgrades are sold at the depot garage" and reads as the
	button not working. A rule the UI never mentions until it refuses you is a
	bug, not a design.

	So the gate is off by default: flip REQUIRE_GARAGE back to true to sell over
	the counter only. It is kept, rather than deleted, because it is the correct
	shape for that rule if it ever comes back -- server-side, since a client that
	never opens the shop can still fire the remote from anywhere, and measured off
	the slab's own object space rather than hardcoded coordinates, because the
	building has already been dragged forty studs down the map once.

	The zone is also given a margin now, so "at the depot" means the forecourt and
	the doorway too, not just the painted floor.
]]
local REQUIRE_GARAGE = false   -- true = upgrades sell only at the depot counter
local ZONE_HEADROOM = 18       -- studs above the slab that still count as inside
local ZONE_MARGIN = 24         -- studs of apron outside the slab that still count

--[[
	Trucks are the exception, and they keep their gate.

	The reasoning above is about a rule the player only ever hears when it
	refuses them. The dealership does not have that problem: its panel checks the
	same slab on the client, greys its own buy buttons out and says "visit the
	dealership" on them, so walking there is a visible prerequisite rather than a
	surprise. A showroom you can buy from anywhere in the map is not a showroom.
]]
local function zoneFloor(zone: string?): BasePart?
	if zone == "Dealership" then
		local hall = workspace:FindFirstChild("RigDealership")
		local floor = hall and hall:FindFirstChild("Floor")
		return (floor and floor:IsA("BasePart")) and floor or nil
	end
	local hood = workspace:FindFirstChild("Neighbourhood")
	local depot = hood and hood:FindFirstChild("Depot")
	local garage = depot and depot:FindFirstChild("Garage")
	local shell = garage and garage:FindFirstChild("Shell")
	local floor = shell and shell:FindFirstChild("Floor")
	return (floor and floor:IsA("BasePart")) and floor or nil
end

local ZONE_LABEL: { [string]: string } = {
	Garage = "the depot garage",
	Dealership = "the rig dealership",
}

local function inZone(plr: Player, zone: string?): boolean
	if zone=="Dealership" and require(game.ReplicatedStorage.DrivewaySealer.ExtraRefuel).at(plr) then return true end
	if zone ~= "Dealership" and not REQUIRE_GARAGE then return true end
	local floor = zoneFloor(zone)
	if not floor then return true end   -- no such building here: never lock anyone out
	local character = plr.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return false end
	--[[
		The showroom's own skirt is written on its slab, not here.

		It was a flat 6, with the note "the showroom is a small building and has no
		forecourt to be generous about". It has one now -- most of the site is
		forecourt -- and a player stood among the trucks outside would have been told
		rigs are sold at the rig dealership while standing in it. The number belongs
		with the geometry that decides it, so the builder stamps it on Floor and both
		counters read the same one. 6 remains the answer for a slab that says nothing.
	]]
	local margin = if zone == "Dealership"
		then ((floor:GetAttribute("ZoneMargin") :: number?) or 6)
		else ZONE_MARGIN
	local p = floor.CFrame:PointToObjectSpace(root.Position)
	return math.abs(p.X) <= floor.Size.X * 0.5 + margin
		and math.abs(p.Z) <= floor.Size.Z * 0.5 + margin
		and p.Y > -2 and p.Y < ZONE_HEADROOM
end

--==[ purchase ]==============================================================

local lastBuy: { [Player]: number } = {}

--[[
	Everything the two tills have to agree on, price aside.

	Cash and Robux buy exactly the same rung, so the rules about WHICH rung may be
	bought cannot live inside either handler -- a gate enforced at one counter and
	not the other is a gate that gets bought around rather than passed. Returns the
	refusal to show the player, or nil when the sale may go ahead.
]]
local function ineligible(plr: Player, track: Upgrades.Track): string?
	if not inZone(plr, track.zone) then
		return ("%s is sold at %s"):format(track.name, ZONE_LABEL[track.zone or "Garage"])
	end

	--[[
		During the tutorial the only sale is the one the tutorial asks for.

		The tutorial driveway is priced to just cover Squeegee Length Lv 2 and there
		is no second job to earn from until the bay door opens, so spending it on any
		other track would strand the player with too little for the step that opens
		the door. Lifts the moment DepotGate marks the tutorial finished.
	]]
	if not plr:GetAttribute("TutorialDone") and track.id ~= "Blade" then
		return "Squeegee Length first -- that is the tutorial"
	end

	local level = plr:GetAttribute(attrName(track.id)) :: number or 1
	if not Upgrades.costOf(track.id, level) then return "Already maxed out" end

	--[[
		The top rungs of every track want rebirths behind them.

		Refused by name rather than by price, because those are different problems
		and a player told "not enough cash" for something no amount of cash can buy
		will go and earn it. The shop draws the same rows locked for the same reason.

		Robux does not buy past this either. It buys TIME -- cash the player could
		have earned anyway -- and the late ladder is paced against rebirths rather
		than against money on purpose, so selling that gate would hand over the whole
		endgame on the first day.
	]]
	local needs = Upgrades.requiresOf(track.id, level)
	if needs > Rebirth.countOf(plr) then
		return ("%s Lv %d needs %d rebirth%s")
			:format(track.name, level + 1, needs, needs == 1 and "" or "s")
	end

	return nil
end

-- The whole of what either till hands over. Shared for the same reason the
-- checks above are: two ways to buy a rung, one meaning of having bought it.
local function grantLevel(plr: Player, track: Upgrades.Track)
	local level = plr:GetAttribute(attrName(track.id)) :: number or 1
	plr:SetAttribute(attrName(track.id), level + 1)
	-- The quest board counts rungs BOUGHT, and this is the one place a rung is
	-- granted whichever way it was paid for -- which is exactly why the counter
	-- goes here rather than in either purchase handler.
	plr:SetAttribute("Q_Upgrades", ((plr:GetAttribute("Q_Upgrades") :: number?) or 0) + 1)
	BuyResult:FireClient(plr, track.id, true,
		if track.unlock then ("%s purchased"):format(track.name)
			else track.name .. " Lv " .. (level + 1))
end

BuyUpgrade.OnServerEvent:Connect(function(plr, id)
	if type(id) ~= "string" then return end
	local track = Upgrades.ById[id]
	if not track then return end

	-- a click cannot arrive faster than this; anything quicker is a script
	local now = os.clock()
	if lastBuy[plr] and now - lastBuy[plr] < 0.12 then return end
	lastBuy[plr] = now

	local why = ineligible(plr, track)
	if why then BuyResult:FireClient(plr, id, false, why) return end

	--[[
		A game pass row is not for sale here at any price.

		It sits in the ladder so players find it, and it carries costs of { 0, 0 } so
		the table stays the shape every other reader expects -- which is exactly why
		this guard has to exist. Without it the remote would hand the thing over for
		nothing to anyone who fired it with the row's id.
	]]
	if track.pass then
		BuyResult:FireClient(plr, id, false,
			("%s is a game pass, not a counter sale"):format(track.name))
		return
	end

	local level = plr:GetAttribute(attrName(id)) :: number or 1
	local listed = Upgrades.costOf(id, level) :: number

	--[[
		Rebirths discount the ladder, and the till has to charge the discounted price
		or the shop is lying about it. Trucks are excluded: they survive a rebirth, so
		discounting them would let a player rebirth purely to buy the same rig cheaper
		-- and the price on the showroom card is the one thing in the dealership that
		is supposed to be fixed.
	]]
	local cost = if track.unlock then listed else Rebirth.priceOf(plr, listed)
	local cash = cashOf(plr)
	if not cash then return end
	if cash.Value < cost then
		-- 4th arg is a structured reason code. SealerUIClient uses it to open the
		-- shop's CASH tab (where the cash packs live) on a failed purchase. Extra
		-- args are simply ignored by listeners that don't read them, so this is
		-- backward-safe with every existing OnClientEvent handler.
		BuyResult:FireClient(plr, id, false, "Not enough cash", "InsufficientCash")
		return
	end

	cash.Value -= cost
	grantLevel(plr, track)
end)

--==[ the same rung, bought with Robux ]======================================

BuyRobux.OnServerEvent:Connect(function(plr, id)
	if type(id) ~= "string" then return end
	local track = Upgrades.ById[id]
	if not track then return end

	local now = os.clock()
	if lastBuy[plr] and now - lastBuy[plr] < 0.12 then return end
	lastBuy[plr] = now

	-- Refusing to prompt is the only safe answer before the profile lands: the
	-- levels are not known yet, so neither is what the player would be paying for.
	if not loaded[plr] then
		BuyResult:FireClient(plr, id, false, "Still loading your profile")
		return
	end

	local why = ineligible(plr, track)
	if why then BuyResult:FireClient(plr, id, false, why) return end

	--[[
		The note goes down before the dialog goes up.

		Saved now rather than at the next autosave, because the gap it covers is
		exactly the one where the player is sitting looking at a Robux prompt: if the
		server dies while it is open, this is what tells the next session which rung
		was paid for. Spawned rather than awaited so the dialog is not held behind a
		DataStore round trip -- it has seconds of reading time to land in, and the
		receipt cannot arrive before the player has clicked.
	]]
	pending[plr.UserId] = id
	task.spawn(save, plr)

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(plr, ROBUX_PRODUCT)
	end)
	if not ok then
		pending[plr.UserId] = nil
		BuyResult:FireClient(plr, id, false, "The Robux shop is not answering -- try again")
		warn("[UpgradeService] PromptProductPurchase failed: " .. tostring(err))
	end
end)

--[[
	A boost becomes time on the clock, and buying another one STACKS.

	The new five minutes are added to whatever is left rather than replacing it,
	which is the only behaviour that is not a robbery: the player who buys again
	with forty seconds to go did not ask to throw those forty seconds away, and a
	prompt that quietly shortens what you already own is the kind of thing people
	remember about a shop.

	The floor is `now` rather than the old deadline, so an expired boost restarts
	from this moment instead of extending a stamp that is an hour in the past --
	which would have handed over nothing at all and looked exactly like a purchase
	that did not land.
]]

--[[
	Rebirths the player, skipping requirements and resetting.
]]
local function grantBoost(plr: Player, boost: Boosts.Boost)
	local attr = Boosts.attrName(boost.id)
	local now = Boosts.now()
	local from = plr:GetAttribute(attr) :: number? or 0
	if from < now then from = now end
	local until_ = from + boost.seconds
	plr:SetAttribute(attr, until_)
	BuyResult:FireClient(plr, boost.id, true,
		("%s \u{2022} %s left"):format(boost.name, Boosts.clock(until_ - now)))
end

local function grantRebirthSkip(plr: Player)
	local count = Rebirth.countOf(plr)
	plr:SetAttribute("RebirthSkipping", true)
	plr:SetAttribute(Rebirth.Attr, count + 1)
	task.delay(1, function()
		plr:SetAttribute("RebirthSkipping", nil)	
	end)

	local m = Rebirth.multiplierAt(count + 1)
	BuyResult:FireClient(plr, "Rebirth", true,
		("Rebirth skipped \u{2022} %s \u{2022} every job now pays x%s \u{2022} upgrades %d%% off")
			:format(Rebirth.rankAt(count + 1),
				if m < 100 then string.format("%.1f", m) else string.format("%d", m + 0.5),
				math.floor((1 - Rebirth.discountAt(count + 1)) * 100 + 0.5)))
end

--[[
	ProcessReceipt -- the only place Robux actually becomes a level.

	Roblox calls this until it is told the purchase landed, which includes calling
	it on a later join, and may call it twice for one purchase. So it has to be
	safe to run again -- the PurchaseId is checked against the ones already granted
	-- and anything it cannot answer yet is left NotProcessedYet so Roblox asks
	again, rather than the player paying for nothing.

	⚠ ONE CALLBACK FOR THE WHOLE GAME. ProcessReceipt is a single assignable
	field on MarketplaceService, not a signal, so a second script setting its own
	does not add a handler -- it silently replaces this one and every upgrade
	bought with Robux stops being granted. Anything sold as a developer product
	has to be answered from inside this function, which is why the boosts are here
	rather than in a file of their own.
]]
local RobotService = require(game.ServerScriptService:WaitForChild("RobotService"))
local World2Receipts = require(game.ServerScriptService:WaitForChild("World2Receipts"))
MarketplaceService.ProcessReceipt = function(info)
    local skipRoad = require(game.ServerScriptService.SkipRoadService)
    if skipRoad.isProduct(info.ProductId) then
        return skipRoad.receipt(info)
    end
    local skipZone = require(game.ServerScriptService.SkipZoneService)
    if skipZone.isProduct(info.ProductId) then
        return skipZone.receipt(info)
    end
 -- StellarQuest receipt route
 local stellar=require(game.ServerScriptService.StellarQuestService)
 if stellar.isProduct(info.ProductId) then return stellar.receipt(info) end
 local eventShop=require(game.ServerScriptService.HalloweenShopService)
 if eventShop.isProduct(info.ProductId) then return eventShop.receipt(info) end
    if WorldsAccess.isProduct(info.ProductId) then return WorldsAccess.processReceipt(info) end
    if World2Receipts.colorOf(info.ProductId) then return World2Receipts.process(info) end
	if RobotService.isProduct(info.ProductId) then return RobotService.processReceipt(info) end
	if ColorShop.isProduct(info.ProductId) then return ColorShop.processReceipt(info) end
	local spinPurchase = SpinWheel.isProduct(info.ProductId)
	local boost = Boosts.byProduct(info.ProductId)
	local doubling = info.ProductId == DoubleUp.ProductId
	-- Nil for anything that is not one of the skin products, so a shop with a gap
	-- in it cannot claim an unrelated receipt.
	local skinId = Skins.skinOfProduct(info.ProductId)
	-- Nil for the same reason, and for one more: an unlisted pack carries id 0 and
	-- byProduct never matches on it, so the packs that are not on sale yet cannot
	-- between them claim somebody else's receipt.
	local pack = CashPacks.byProduct(info.ProductId)
	local skipRebirth = info.ProductId == SKIP_REBIRTH_PRODUCT
	if info.ProductId ~= ROBUX_PRODUCT and not spinPurchase and not boost and not doubling and not skinId
		and not pack and not skipRebirth then
		warn("[UpgradeService] receipt for unknown product " .. tostring(info.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local plr = Players:GetPlayerByUserId(info.PlayerId)
	if not plr then return Enum.ProductPurchaseDecision.NotProcessedYet end

	--[[
		The note lives in the profile, so nothing can be decided until the profile is
		in. A receipt held over from a previous session arrives here first.

		The boosts need this wait every bit as much, for a different reason: the
		deadline they write is one of the things the restore puts back, so a grant
		that landed first would be overwritten by the saved figure a moment later --
		and the player would watch five paid-for minutes vanish on the frame their
		profile arrived.
	]]
	local t0 = os.clock()
	while not loaded[plr] and os.clock() - t0 < 30 do
		task.wait(0.25)
		if not plr.Parent then return Enum.ProductPurchaseDecision.NotProcessedYet end
	end
	if not loaded[plr] then return Enum.ProductPurchaseDecision.NotProcessedYet end

	local purchaseId = tostring(info.PurchaseId)
	if wasHandled(info.PlayerId, purchaseId) then
		-- already granted; Roblox simply did not hear us say so
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if spinPurchase then
		SpinWheel.grantPurchased(plr, info.ProductId)
		markHandled(info.PlayerId, purchaseId)
		save(plr)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	--[[
		A boost needs no note written down beforehand, and that is the one way it is
		simpler than the shop's product: the PRODUCT IS THE PURCHASE here, so there is
		nothing the receipt could be ambiguous about. `pending` is untouched, which
		matters -- a boost bought with an upgrade prompt still outstanding must not
		consume the note that upgrade is waiting on.
	]]
	if boost then
		grantBoost(plr, boost)
		markHandled(info.PlayerId, purchaseId)
		save(plr)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	--[[
		The doubling, which is the shop's own product in reverse.

		There the note says which RUNG was asked for and the price is fixed; here the
		price is fixed and the note says how much CASH. Either way the receipt on its
		own cannot answer the question, and `pending` is left alone for the same
		reason the boosts leave it alone: a doubling bought with an upgrade prompt
		still outstanding must not consume the note that upgrade is waiting on.

		A zero back means there was nothing recorded to pay -- the note was lost with
		a server that died before it could be written, or it has already been spent by
		a grant this receipt is a duplicate of that `handled` somehow missed. Held
		rather than granted, so the player is not charged for nothing; Roblox asks
		again on their next join. That is the same answer the missing-pending-upgrade
		case gives below, and it terminates the only way this one can be made whole.
	]]
	if doubling then
		local paid = DoubleUpService.grant(plr)
		if paid <= 0 then
			warn(("[UpgradeService] a %s receipt arrived for %s with nothing owed")
				:format(DoubleUp.Name, plr.Name))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		markHandled(info.PlayerId, purchaseId)
		save(plr)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if skipRebirth then
		grantRebirthSkip(plr)
		markHandled(info.PlayerId, purchaseId)
		save(plr)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	--[[
		A skin, and it is the SIMPLEST of the four: one developer product per skin,
		so the PRODUCT IS THE PURCHASE and there is nothing the receipt could be
		ambiguous about -- exactly like a boost.

		`pending` is left alone, for the same reason the boosts and the doubling
		leave it alone: a skin bought with an upgrade prompt still outstanding must
		not consume the note that upgrade is waiting on.
	]]
	if skinId then
		if not SkinShop.grantFromReceipt(plr, info.ProductId) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		markHandled(info.PlayerId, purchaseId)
		save(plr)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	--[[
		A cash pack, which is the simplest of the lot: one product per amount, so the
		PRODUCT IS THE PURCHASE and there is nothing to write down beforehand.
		`pending` is left alone for the reason the boosts, the doubling and the skins
		leave it alone -- a pack bought with an upgrade prompt still outstanding must
		not consume the note that upgrade is waiting on.

		⚠ THE AMOUNT IS FLAT. No rebirth multiplier, no 2x Cash pass, no Double Cash
		window. Those multiply what a DRIVEWAY pays, which is the thing the player
		earns; this is a fixed quantity of money bought at a fixed price, and running
		it through the earning multipliers would mean the same Robux buys five times
		as much for a player at rebirth 12 as for the one who needed it. If that is
		ever wanted it belongs here, deliberately, and the shop card has to say so.

		A missing wallet is held rather than granted: leaderstats is built on join and
		the profile is already in by this point, so its absence means something is
		wrong rather than merely early -- and NotProcessedYet has Roblox ask again on
		the next join instead of charging for nothing.
	]]
	if pack then
		local cash = cashOf(plr)
		if not cash then
			warn(("[UpgradeService] %s paid for %s and has no Cash value to pay into")
				:format(plr.Name, pack.name))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		cash.Value += pack.amount
		BuyResult:FireClient(plr, pack.id, true,
			("%s \u{2022} %s added"):format(pack.name, CashPacks.short(pack.amount)))
		markHandled(info.PlayerId, purchaseId)
		save(plr)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local id = pending[info.PlayerId]
	local track = id and Upgrades.ById[id]
	if not track then
		-- Nothing to grant and no way to guess which rung it was. Hold the receipt
		-- rather than taking Robux for it; Roblox will ask again.
		warn("[UpgradeService] receipt with no pending upgrade for " .. plr.Name)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	--[[
		Maxed between the prompt opening and the receipt landing -- they bought the
		last rung with cash while the dialog was up. Rare, but it has to terminate:
		holding the receipt would re-ask forever on a track that can never take
		another level. The cash goes back instead, so the player is out neither.
	]]
	local level = plr:GetAttribute(attrName(track.id)) :: number or 1
	if not Upgrades.costOf(track.id, level) then
		local refund = track.costs[#track.costs] or 0
		local c = cashOf(plr)
		if c then c.Value += refund end
		BuyResult:FireClient(plr, track.id, true,
			("%s was already maxed \u{2022} refunded $%s")
				:format(track.name, Upgrades.short(refund)))
	else
		grantLevel(plr, track)
	end

	pending[info.PlayerId] = nil
	markHandled(info.PlayerId, purchaseId)
	-- Straight to the store rather than waiting for the autosave: a granted receipt
	-- that is not written down is a receipt that gets granted again on the next join.
	save(plr)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- The Income Multiplier track is gone, and the cash-watcher that topped up
-- every payout by its multiplier went with it. Nothing reads or writes Cash
-- here now except the purchase above.
Players.PlayerRemoving:Connect(function(plr) lastBuy[plr] = nil end)

--==[ the reward board ]======================================================

--[[
	Claiming a quest tier.

	Here for the same reason every other payout is: it puts cash in the wallet,
	and the wallet is the one thing the client is never allowed to decide. The
	panel works out which button to draw; whether the tier was actually met is
	re-checked from the same Quests.statusOf the panel used, so the two cannot
	disagree about it.

	The claimed tier moves first and the cash lands second. A player who somehow
	managed to fire this twice in the same frame would rather be paid once than
	paid twice -- and the attribute is what makes the second call see a tier that
	is no longer ready.
]]
local ClaimQuest = remote("ClaimQuest")

ClaimQuest.OnServerEvent:Connect(function(plr, id)
	if type(id) ~= "string" then return end
	local track = Quests.ById[id]
	if not track then return end

	local now = os.clock()
	if lastBuy[plr] and now - lastBuy[plr] < 0.12 then return end
	lastBuy[plr] = now

	if not loaded[plr] then return end

	local st = Quests.statusOf(plr, track)
	if st.finished then
		BuyResult:FireClient(plr, "Quest", false, track.name .. " is finished")
		return
	end
	if not st.ready then
		BuyResult:FireClient(plr, "Quest", false, "That one is not done yet")
		return
	end

	local cash = cashOf(plr)
	if not cash then return end

	plr:SetAttribute(Quests.claimedAttr(track.id), st.tier)
	local reward = st.reward or 0
	cash.Value += reward
	-- a claimed reward is earnings too, so the Turnover track sees it
	plr:SetAttribute("Q_Earned", ((plr:GetAttribute("Q_Earned") :: number?) or 0) + reward)

	BuyResult:FireClient(plr, "Quest", true,
		("%s \u{2022} tier %d \u{2022} $%s"):format(track.name, st.tier, Upgrades.short(reward)))
end)

--==[ the day book ]=========================================================

--[[
	The daily packet.

	Here with the other two claims rather than in a script of its own, and for the
	same two reasons: it puts cash in the wallet, which is the one thing the client
	is never allowed to decide, and it writes a profile key that has to be on disk
	before the player's next join -- and `loaded` and `save` both live here. A
	separate service would have to reach into both.

	The client works out which tile to light; whether a packet is actually due is
	re-checked from the same Daily.statusOf the panel used, so the two cannot
	disagree about what day it is.
]]
local ClaimDaily = remote("ClaimDaily")

ClaimDaily.OnServerEvent:Connect(function(plr)
	-- shares the purchase cooldown; a double-fire here would be a second packet
	local now = os.clock()
	if lastBuy[plr] and now - lastBuy[plr] < 0.12 then return end
	lastBuy[plr] = now

	--[[
		The whole decision is today's date against the date in the profile, so the
		profile has to be in. Answering before it lands would pay a returning player
		a second time for a day they were already paid for -- the same race the VIP
		packet waits on, and the reason Daily.statusOf reports `loading` at all.
	]]
	if not loaded[plr] then
		BuyResult:FireClient(plr, "Daily", false, "Still loading your profile")
		return
	end

	--[[
		No packets until the tutorial is done, and refused HERE as well as on the rail.

		The client shuts the day book for the same reason the rebirth screen refuses
		mid-tutorial: the first job is meant to be earned, and Day 1 is more than the
		rung the tutorial asks the player to buy. But the rail lock only locks a
		button, and this remote does not need the button -- so the rule has to live at
		the till too or it is a rule the UI merely suggests.
	]]
	if not plr:GetAttribute("TutorialDone") then
		BuyResult:FireClient(plr, "Daily", false, "Finish the tutorial first")
		return
	end

	local st = Daily.statusOf(plr)
	if not st.ready then
		BuyResult:FireClient(plr, "Daily", false,
			("Next packet in %s"):format(Daily.formatWait(st.secondsLeft)))
		return
	end

	local cash = cashOf(plr)
	if not cash then return end

	-- The book is signed before the money moves, so a second call in the same frame
	-- sees a day that has already been claimed. Same order, and the same reason, as
	-- the quest tier above.
	plr:SetAttribute(Daily.DayAttr, Daily.today())
	plr:SetAttribute(Daily.StreakAttr, st.streakAfter)
	cash.Value += st.amount
	-- a packet is earnings, like the VIP one and a claimed tier, so the Turnover
	-- track sees it like any other pay
	plr:SetAttribute("Q_Earned", ((plr:GetAttribute("Q_Earned") :: number?) or 0) + st.amount)

	--[[
		Non-cash rewards: a skin on Day 3 and a boost on Day 7, read from the same
		rung table the cash came from. The skin is added to the owned set (a skin
		already owned is a no-op, which is the right answer for a streak that wraps
		round); the boost is granted through the same function a receipt uses, so the
		deadline and the notification are identical to a paid one.
	]]
	local rung = Daily.Days[st.day]
	local skinName: string?
	if rung then
		local skinId = (rung :: any).skin
		if type(skinId) == "string" and Skins.ById[skinId] then
			local set = Skins.ownedSet(plr)
			if not set[skinId] then
				set[skinId] = true
				plr:SetAttribute(Skins.OwnedAttr, Skins.serialise(set))
				skinName = Skins.ById[skinId].name
			end
		end
	end

	local msg = if st.amount > 0
		then ("Day %d \u{2022} $%s"):format(st.day, Upgrades.short(st.amount))
		else ("Day %d"):format(st.day)
	if skinName then
		msg = msg .. " \u{2022} " .. skinName .. " skin"
	end
	msg = msg .. (" \u{2022} %d day%s running")
		:format(st.streakAfter, st.streakAfter == 1 and "" or "s")
	BuyResult:FireClient(plr, "Daily", true, msg)

	if rung then
		local boostId = (rung :: any).boost
		if type(boostId) == "string" and Boosts.ById[boostId] then
			grantBoost(plr, Boosts.ById[boostId])
		end
	end

	-- Straight to the store rather than at the next autosave: a packet that is paid
	-- and not written down is a packet that gets paid again on the next join.
	task.spawn(save, plr)
end)

--==[ rebirth ]==============================================================

--[[
	Rebirth, and it lives here for the same reason the purchase does: it empties
	the wallet and hands out a permanent multiplier, and those two have to be one
	decision made somewhere the client cannot reach.

	What it does NOT do is reset the world. DrivewayServer and DrivewayClient both
	watch the Rebirths attribute and wind their own state back when it moves, so
	this function only ever touches the two things it actually owns -- the levels
	and the money -- and the reset cannot be asked for separately from the rebirth
	that paid for it.

	The cash is no longer the PRICE, though -- a rebirth is paid for in driveways
	sealed on this lap now (see SealerUI.Rebirth for why). It is still emptied,
	because emptying it is what starting the business again means and the whole
	upgrade discount curve is priced against re-climbing the ladder from nothing.
	The difference is that the wallet can no longer be the thing standing between a
	player and the rest of the game.
]]
local DoRebirth = remote("Rebirth")

DoRebirth.OnServerEvent:Connect(function(plr)
    if plr:GetAttribute("SkipRoadGrantPending") == true then
        BuyResult:FireClient(plr, "Rebirth", false, "Your Skip Road purchase is still being saved.")
        return
    end
    if plr:GetAttribute("SkipZoneGrantPending") == true then
        BuyResult:FireClient(plr, "Rebirth", false, "Your Skip Zone purchase is still being saved.")
        return
    end
	-- shares the purchase cooldown: both spend money, and a double-fire on this
	-- one would cost a player a whole lap
	local now = os.clock()
	if lastBuy[plr] and now - lastBuy[plr] < 0.5 then return end
	lastBuy[plr] = now

	if not loaded[plr] then
		BuyResult:FireClient(plr, "Rebirth", false, "Still loading your profile")
		return
	end

	-- Rebirthing mid-tutorial would wind back the very upgrade DepotGate is
	-- waiting on and shut the bay door on a player who had done nothing wrong.
	if not plr:GetAttribute("TutorialDone") then
		BuyResult:FireClient(plr, "Rebirth", false, "Finish the tutorial first")
		return
	end

	local st = Rebirth.statusOf(plr)
	--[[
		No "you have taken them all" refusal above this any more. The ladder does not
		end (see SealerUI.Rebirth); what ends is the share, at a full sweep of the
		map, and that is a price the check below already enforces.
	]]
	--[[
		Re-checked off the same statusOf the panel drew its button from, and it is
		safe to trust here because both figures it reads are attributes this SERVER
		wrote -- refreshSections in DrivewayServer publishes them. A LocalScript
		setting an attribute on its own Player does not replicate, so there is
		nothing for a client to forge.
	]]
	if not st.ready then
		BuyResult:FireClient(plr, "Rebirth", false,
			if not st.counted then "Still counting the map"
				else ("Seal %d more driveway%s to rebirth")
				:format(st.left, st.left == 1 and "" or "s"))
		return
	end

	local cash = cashOf(plr)
	if not cash then return end

	-- The wallet goes back to nothing, along with the levels below it. Not a
	-- charge -- the lap already paid for this -- but the reset the multiplier and
	-- the ladder discount are both priced against.
	resetWorldExtras[plr] = true
	cash.Value = 0
	for _, id in ipairs(Rebirth.Tracks) do
		plr:SetAttribute(attrName(id), 1)
	end
	plr:SetAttribute(Rebirth.Attr, st.count + 1)
	--[[
		And SAY so, rather than leaving DrivewayServer to notice the attribute move.

		This is the only place a rebirth actually happens, so it is the only place
		that can announce one without being wrong. See RebirthBus: the attribute is
		also written by the profile restore on every join, and the signal that
		carried it is deferred, so "it changed" arrived after the flags that were
		meant to tell the two apart had already settled.
	]]
	RebirthBus.fire(plr)

	local m = Rebirth.multiplierAt(st.count + 1)
	BuyResult:FireClient(plr, "Rebirth", true,
		("%s \u{2022} every job now pays x%s \u{2022} upgrades %d%% off")
			:format(Rebirth.rankAt(st.count + 1),
				if m < 100 then string.format("%.1f", m) else string.format("%d", m + 0.5),
				math.floor((1 - Rebirth.discountAt(st.count + 1)) * 100 + 0.5)))

	-- Straight to the store rather than waiting for the autosave. A rebirth is the
	-- one thing in this profile that would really hurt to lose to a crash.
	task.spawn(save, plr)
end)

--==[ the cash packs, audited on the way up ]=================================

--[[
	Says out loud which packs are sellable and whether the dashboard agrees with
	the prices this game thinks it set -- the same job SkinShopService's ready line
	does for the skins, and for the same reason: a gap that is printed is a gap
	somebody notices, and a gap that is merely true is one discovered by a player.

	Two different faults, kept apart because the fixes are:

	  NO PRODUCT ID -- the pack is drawn SOON and cannot be bought. Expected until
	  the products are made; harmless, and the tab says so on the card.

	  PRICE MISMATCH -- the product exists and is charging something other than
	  what CashPacks says it is worth. This is the one that costs money: it is what
		a price typed into the wrong product looks like, and nothing else in the game
		would ever mention it. The dashboard WINS -- the shop draws the live price and
		the player is charged it -- so this is a warning to go and fix the listing,
		not a thing the code can correct.

	Spawned, because GetProductInfo is a web call per pack and none of this is
	worth holding the server's startup for.
]]
task.spawn(function()
	local live, blank, wrong = 0, 0, 0
	for _, pack in ipairs(CashPacks.List) do
		if pack.productId == 0 then
			blank += 1
		else
			live += 1
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(pack.productId, Enum.InfoType.Product)
			end)
			if not ok or type(info) ~= "table" then
				warn(("[CashPacks] %s: product %d could not be read -- %s")
					:format(pack.name, pack.productId, tostring(info)))
			elseif tonumber(info.PriceInRobux) ~= pack.robux then
				wrong += 1
				warn(("[CashPacks] %s is listed at %s R but this game prices it at %d R"
					.. " -- the dashboard wins, so fix the listing or fix CashPacks")
					:format(pack.name, tostring(info.PriceInRobux), pack.robux))
			end
		end
	end
	print(("[CashPacks] ready -- %d packs, %s..%s, %d on sale, %d awaiting a product id%s")
		:format(#CashPacks.List,
			CashPacks.short(CashPacks.List[1].amount),
			CashPacks.short(CashPacks.List[#CashPacks.List].amount),
			live, blank,
			if wrong > 0 then (", %d MISPRICED"):format(wrong) else ""))
end)
