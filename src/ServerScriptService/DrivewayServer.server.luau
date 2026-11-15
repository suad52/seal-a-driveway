--!strict
--[[
	DrivewayServer.

	The sealing simulation is deliberately client-side -- it has to be, for the
	spreading to feel instant. The server's jobs are to hand out the tools, own
	the payout, and forward strokes so other players see the driveway change.

	Coverage is therefore client-reported. It is rate-limited below, which stops
	casual tampering but is not a hard anti-exploit boundary; a competitive
	economy would want the grid mirrored here as well.
]]

local Players = game:GetService("Players")
local StarterPack = game:GetService("StarterPack")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Pack:WaitForChild("Config"))
local Economy = require(Pack:WaitForChild("Economy"))
local ToolBuilder = require(Pack:WaitForChild("ToolBuilder"))
local Sections = require(Pack:WaitForChild("Sections"))
local Lucky = require(Pack:WaitForChild("Lucky"))
local Rebirth = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Rebirth"))
local Passes = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Passes"))
-- The server-wide 3x window. EventHandler owns when it is open; this file is one
-- of the two places that turn it into money -- see the note on payMultiplier.
local GoldenHour = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("GoldenHour"))
-- +15% Cash per friend on the same server. See FriendBonusService.
local FriendBonus = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("FriendBonus"))
-- Only for the name of one attribute. See `isDuelSlab`.
local Duel = require(ReplicatedStorage:WaitForChild("Duel"):WaitForChild("DuelConfig"))

local Remotes = Pack:WaitForChild("Remotes")
local ReportCoverage = Remotes:WaitForChild("ReportCoverage") :: RemoteEvent
local DrivewayComplete = Remotes:WaitForChild("DrivewayComplete") :: RemoteEvent

--==[ TOOLS ]=================================================================

for _, name in ipairs({ "Sealer Bucket", "Squeegee" }) do
	local existing = StarterPack:FindFirstChild(name)
	if existing then existing:Destroy() end
end
ToolBuilder.buildBucket().Parent = StarterPack
ToolBuilder.buildSqueegee().Parent = StarterPack

--==[ WHERE AN UNPOSED RIG RESTS ]============================================
-- Matches RemoteToolsClient and DrivewayClient: the rubber rides this far ahead
-- of the torso. Kept in step by hand, as those two already are.
local BLADE_FORWARD = 2.9

local function parkRig(ch: Model, thing: Instance)
	if not thing:IsA("Tool") then return end
	local rig = thing:FindFirstChild("Rig")
	if not (rig and rig:IsA("Model")) then return end
	local hrp = ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local cf = (hrp :: BasePart).CFrame
	local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local look = if flat.Magnitude < 1e-4 then Vector3.new(0, 0, -1) else flat.Unit

	local at: Vector3
	if thing:GetAttribute("SealerTool") == "Wand" then
		-- the wand rig's pivot is its grip, so this is roughly their hand
		at = cf.Position + cf.RightVector * 0.85 + cf.LookVector * 0.55
			+ Vector3.new(0, 0.35, 0)
	else
		-- the squeegee rig's pivot is the rubber, so this is on the ground in front
		-- of them. No raycast: it is a resting pose, and 2.6 under the root is the
		-- same fallback RemoteToolsClient uses when its own ground ray misses.
		at = cf.Position + look * BLADE_FORWARD - Vector3.new(0, 2.6, 0)
	end

	local model = rig :: Model
	model:PivotTo(CFrame.lookAt(at, at + look))
end

local function parkTools(plr: Player)
	local function bind(ch: Model)
		-- ChildAdded is the equip: a Tool moves from the Backpack into the character
		ch.ChildAdded:Connect(function(c) parkRig(ch, c) end)
		-- and whatever is already in hand, for a character that arrived holding one
		for _, c in ipairs(ch:GetChildren()) do parkRig(ch, c) end
	end
	if plr.Character then bind(plr.Character :: Model) end
	plr.CharacterAdded:Connect(bind)
end

--==[ SUPPLY DRUM ]===========================================================
local staleDrum = workspace:FindFirstChild("SealerSupply")
if staleDrum then staleDrum:Destroy() end

--==[ PROGRESS + PAYOUT ]=====================================================
local function isDuelSlab(slab: BasePart): boolean
	return slab:GetAttribute(Duel.SlabAttr) ~= nil
end

-- `banked` is cash already handed over for this slab, as a high-water mark. See
-- payUpTo: it is what makes paying by the stud add up to the same total as the
-- one lump used to.
type Progress = { coverage: number, lastStamp: number, paid: boolean, banked: number, rawCoverage: number }
local progress: { [Player]: { [BasePart]: Progress } } = {}

local function stats(plr: Player)
	local ls = plr:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = plr
		local cash = Instance.new("IntValue")
		cash.Name = "Cash"
		cash.Parent = ls
		local done = Instance.new("IntValue")
		done.Name = "Sealed"
		done.Parent = ls
	end
	return ls
end

local function mirrorJobs(plr: Player)
	local done = stats(plr):FindFirstChild("Sealed") :: IntValue?
	if done then
		done.Value = (plr:GetAttribute("Q_Sealed") :: number?) or 0
	end
end

local function promoteLapRecord(plr: Player)
	local now = Sections.nowSetOf(plr)
	if next(now) == nil then return end
	local set = Sections.sealedSetOf(plr)
	local moved = false
	for _, s in ipairs(Sections.List) do
		for _, slab in ipairs(Sections.slabsOf(s)) do
			local key = Sections.keyOf(slab)
			if now[key] and not set[key] then
				set[key] = true
				moved = true
			end
		end
	end
	if moved then
		plr:SetAttribute(Sections.SealedAttr, Sections.encode(set))
	end
end

local function refreshSections(plr: Player)
	-- Before anything is counted: see promoteLapRecord. It changes no figure in
	-- this pass -- only whether the next rebirth can take one away.
	promoteLapRecord(plr)
	local rebirths = Rebirth.countOf(plr)
	local openById: { [string]: boolean } = {}
	for _, s in ipairs(Sections.List) do
		local done, total = Sections.progressOf(plr, s)
		plr:SetAttribute(Sections.doneAttr(s.id), done)
		-- published because the client cannot count it for itself under streaming;
		-- see the note on Sections.totalAttr
		plr:SetAttribute(Sections.totalAttr(s.id), total)
		-- total > 0 guards the frame before the map's tags have registered: with no
		-- slabs found, done and total are both zero and every gate would spring open
		local open = total > 0 and done >= total
			and rebirths >= Sections.requiresOf(s)
        open = open or plr:GetAttribute("SkipZoneBypass_" .. s.id) == true
		openById[s.id] = open
		plr:SetAttribute(Sections.openAttr(s.id), open)
	end

	local now = Sections.nowSetOf(plr)
	local ground = Sections.reachableGround(function(id)
		return openById[id] == true
	end)
	local reach, sealed = 0, 0
	for _, name in ipairs(ground) do
		for _, slab in ipairs(Sections.slabsIn(name)) do
			reach += 1
			if now[Sections.keyOf(slab)] then sealed += 1 end
		end
	end
	plr:SetAttribute(Rebirth.ReachAttr, reach)
	plr:SetAttribute(Rebirth.DoneAttr, sealed)
end

local function alreadySealed(plr: Player, slab: BasePart): boolean
	return Sections.nowSetOf(plr)[Sections.keyOf(slab)] == true
end

local lastRebirths: { [Player]: number } = {}

local RebirthBus = require(game.ServerScriptService.RebirthBus)

RebirthBus.Event:Connect(function(plr: Player)
	progress[plr] = {}
	lastRebirths[plr] = Rebirth.countOf(plr)
	plr:SetAttribute(Sections.NowAttr, "")
	refreshSections(plr)
end)

local function watch(plr: Player)
	progress[plr] = {}
	stats(plr)
	-- see the note over parkRig: the ghost squeegee's resting place
	parkTools(plr)
	lastRebirths[plr] = Rebirth.countOf(plr)
	-- Jobs Done, both halves: whatever the profile restores a moment from now, and
	-- every job finished after that. See mirrorJobs.
	plr:GetAttributeChangedSignal("Q_Sealed"):Connect(function() mirrorJobs(plr) end)
	mirrorJobs(plr)
	
	plr:GetAttributeChangedSignal(Rebirth.Attr):Connect(function()
		lastRebirths[plr] = Rebirth.countOf(plr)
		refreshSections(plr)
	end)
	-- Recomputed when the saved record lands, not only when a slab is finished:
	-- UpgradeService restores SecSealed some way into the session, and until it
	-- does a returning player's gates read as shut.
	plr:GetAttributeChangedSignal(Sections.SealedAttr):Connect(function()
		refreshSections(plr)
	end)
	
	plr:GetAttributeChangedSignal(Sections.NowAttr):Connect(function()
		refreshSections(plr)
	end)
    for _, section in ipairs(Sections.List) do
        plr:GetAttributeChangedSignal("SkipZoneBypass_" .. section.id):Connect(function()
            refreshSections(plr)
        end)
    end
	refreshSections(plr)
end

Players.PlayerAdded:Connect(watch)
for _, plr in ipairs(Players:GetPlayers()) do watch(plr) end
Players.PlayerRemoving:Connect(function(plr)
	progress[plr] = nil
	lastRebirths[plr] = nil
end)

local function entry(plr: Player, slab: BasePart): Progress?
    local bonus = slab:GetAttribute("BonusZone")
    if bonus and plr:GetAttribute("BonusClear_" .. bonus) ~= true then return nil end
	local byPlayer = progress[plr]
	if not byPlayer then return nil end
	local e = byPlayer[slab]
	if not e then
		-- A slab already finished since the last rebirth opens its ledger closed,
		-- which is what makes the record above mean anything after a rejoin.
		local done = alreadySealed(plr, slab)
		e = {
			coverage = if done then 1 else 0,
			lastStamp = os.clock(),
			paid = done,
			banked = 0,
			rawCoverage = if done then 1 else 0,
		}
		byPlayer[slab] = e
	end
	return e
end

local maxCoverageRate = Config.maxCoverageRate

local function payMultiplier(plr: Player, slab: BasePart): number
	if plr:GetAttribute("TutReplay") == true and slab == Sections.tutorialSlab() then
		return 0
	end
	return Rebirth.multiplierOf(plr)
		* Passes.cashMultiplier(plr)
		* Lucky.multiplierFor(plr, slab)
		* GoldenHour.cashMultiplier(plr)
		* FriendBonus.multiplierOf(plr)
		-- the equipped pet's cash bonus; 1 when no pet is on (PetService)
		* ((plr:GetAttribute("Pet_CashMult") :: number?) or 1)
end

-- Top the player up to `target` total for this slab. Returns what it handed over.
local function payUpTo(plr: Player, e: Progress, target: number): number
	local owed = math.floor(target) - e.banked
	if owed <= 0 then return 0 end
	e.banked += owed
	local cash = stats(plr):FindFirstChild("Cash") :: IntValue?
	if cash then cash.Value += owed end
	-- the lifetime counter the quest board and the TOP EARNERS board run on; it
	-- follows the cash rather than the completion, so half a job still counts
	plr:SetAttribute("Q_Earned", ((plr:GetAttribute("Q_Earned") :: number?) or 0) + owed)
	return owed
end

ReportCoverage.OnServerEvent:Connect(function(plr, slab, coverage)
	if typeof(slab) ~= "Instance" or not slab:IsA("BasePart") then return end
	if not CollectionService:HasTag(slab, "SealableDriveway") then return end
	-- DuelServer has its own listener on this same remote for these. See isDuelSlab.
	if isDuelSlab(slab) then return end
	if type(coverage) ~= "number" or coverage ~= coverage then return end
	coverage = math.clamp(coverage, 0, 1)

	local e = entry(plr, slab)
	if not e then return end
	local now = os.clock()
	local allowed = e.coverage + maxCoverageRate(slab) * (now - e.lastStamp) + 0.01
	e.lastStamp = now
	e.coverage = math.min(coverage, allowed)
	e.rawCoverage = coverage

	-- Nothing for a slab that has already been settled: `paid` covers both a job
	-- finished this session and one restored from the record on join, so a rejoin
	-- cannot re-buy a driveway the player was already paid for.
	if not e.paid then
		payUpTo(plr, e, Economy.payout(slab, e.coverage, 0, payMultiplier(plr, slab)))
	end
end)

local function completeRoad(plr, slab, claimedValue, force)
	if typeof(slab) ~= "Instance" or not slab:IsA("BasePart") then return end
	if not CollectionService:HasTag(slab, "SealableDriveway") then return end
	-- Not paid, and -- the half that would actually do damage -- not written into
	-- the player's sealed record either. See isDuelSlab.
	if isDuelSlab(slab) then return end
	
	local e = entry(plr, slab)
	if not e then return end
	if e.paid then return true end

    if force then
        e.coverage = 1
        e.rawCoverage = 1
    end
	
	local now = os.clock()
	local elapsed = now - e.lastStamp
	if elapsed > 0 then
		e.coverage = math.min(1, e.coverage + maxCoverageRate(slab) * elapsed + 0.01)
		e.lastStamp = now
	end
	
	if e.coverage < Config.CompleteAt - 0.05 and e.rawCoverage >= Config.CompleteAt - 0.05 then
		e.coverage = Config.CompleteAt - 0.05
	end
	
	if e.coverage < Config.CompleteAt - 0.05 then
		warn(("[DrivewayServer] %s finished %s but the server had only seen %.2f"
			.. " coverage (needs %.2f) -- not paid and NOT recorded")
			:format(plr.Name, slab:GetFullName(), e.coverage, Config.CompleteAt - 0.05))
		return
	end
	e.paid = true

	
	local mult = payMultiplier(plr, slab)
	local payout = Economy.payout(slab, 1, 0, mult)
	if type(claimedValue) == "number" then
		payout = math.min(payout * 3, math.max(payout, math.floor(claimedValue)))
	end

	
	local sealedNow = Sections.nowSetOf(plr)
	local key = Sections.keyOf(slab)
	if not sealedNow[key] then
		sealedNow[key] = true
		plr:SetAttribute(Sections.NowAttr, Sections.encode(sealedNow))
	end

	payUpTo(plr, e, payout)
	
	plr:SetAttribute("Q_Sealed", ((plr:GetAttribute("Q_Sealed") :: number?) or 0) + 1)
	
	local section = Sections.sectionOfSlab(slab)
	if section then
		local set = Sections.sealedSetOf(plr)
		local key = Sections.keyOf(slab)
		if not set[key] then
			set[key] = true
			-- refreshSections runs off the attribute changing, so this is the only
			-- write needed; setting it unconditionally would re-fire it every job
			plr:SetAttribute(Sections.SealedAttr, Sections.encode(set))
		end
	end

	
	if plr:GetAttribute("TutReplay") == true and slab == Sections.tutorialSlab() then
		plr:SetAttribute("TutReplay", nil)
	end
    return true
end

DrivewayComplete.OnServerEvent:Connect(function(player, slab, claimedValue)
    completeRoad(player, slab, claimedValue, false)
end)

local skipZoneSealRoad = Instance.new("BindableFunction")
skipZoneSealRoad.Name = "SkipZoneSealRoad"
skipZoneSealRoad.OnInvoke = function(player, slab)
    if player.Parent ~= Players or player:GetAttribute("ProfileLoaded") ~= true then
        return false
    end

    return completeRoad(player, slab, nil, true) == true
end
skipZoneSealRoad.Parent = game:GetService("ServerScriptService")
