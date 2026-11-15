--!strict
--[[
	FeedbackService -- what players write in the Settings panel, kept where you can
	read it back.

	A DATASTORE AND NOT A FUNNEL, and that is not a preference. Analytics events
	carry numbers and a handful of enum-keyed fields, and nothing in the Creator
	Dashboard will hand you an arbitrary string back -- so a funnel can tell you HOW
	MANY people sent feedback but never what any of them said. The sentence is the
	whole point, so it has to go somewhere readable.

	HOW TO READ IT

	Keys are "f_<epoch>_<userId>" in one store, so they list in roughly the order
	they were written -- epoch is fixed-width until the year 2286, so lexicographic
	and chronological are the same thing.

	  * Open Cloud: GET /datastores/v1/universes/<id>/standard-datastores/
	    datastore/entries/entry?datastoreName=Feedback_v1&entryKey=<key>, with
	    .../entries to list. This is the one that does not need the game running.
	  * Or ListKeysAsync from a server script, if you would rather read it in-game.

	⚠ STORED UNFILTERED, deliberately, because it is written for YOU and never shown
	to another player. The moment any of this is displayed in-experience it has to go
	through TextService:FilterStringAsync first -- that is a Roblox policy
	requirement, not a nicety.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")

local STORE_NAME = "Feedback_v1"
local MAX_CHARS = 400      -- what the box accepts; the client caps to match
local COOLDOWN = 60        -- seconds between one player's submissions

--[[
	Same guarded fetch UpgradeService uses. A place without API access must not
	throw on load -- the button simply reports that it could not send, which is the
	honest answer rather than a silent success.
]]
local store: DataStore? = nil
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = ok and s or nil
	if not store then
		warn("[FeedbackService] No DataStore access -- feedback cannot be saved."
			.. " In Studio enable File > Game Settings > Security >"
			.. " \"Enable Studio Access to API Services\".")
	end
end

-- Same Remotes folder and the same idiom as UpgradeService, so there is one
-- folder under SealerUI rather than two that disagree about who made it.
local remotes = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage.SealerUI
end
local function remote(name: string, class: string): Instance
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new(class)
		r.Name = name
		r.Parent = remotes
	end
	return r
end
--[[
	A RemoteFunction rather than an event, because the button has to be able to say
	whether it worked. A fire-and-forget would leave "Thanks!" on screen for a
	submission that hit a throttled DataStore and went nowhere, which is worse than
	no button: the player has said their piece and believes it landed.
]]
local SendFeedback = remote("SendFeedback", "RemoteFunction") :: RemoteFunction

local lastSent: { [Player]: number } = {}
Players.PlayerRemoving:Connect(function(plr) lastSent[plr] = nil end)

--[[
	Returns (ok, message). The message is shown to the player either way, so it has
	to be true as well as short.

	Everything is re-checked here even though the client checks it too: the client's
	cap is there to stop somebody typing a novel and losing it, not to be trusted.
]]
--[[
	What the client says about the machine it is running on.

	WHY IT COMES FROM THE CLIENT AT ALL, when nothing else here trusts one: because
	the server genuinely cannot see any of it. Frame rate is a client fact. So is
	touch. And the 3D Sealer Surface switch writes a PLAYER ATTRIBUTE FROM A
	LOCALSCRIPT, which does not replicate -- the server reads nil for Set_Sheet no
	matter what the player has chosen. The alternative to trusting the client is
	having nothing at all.

	It is diagnostic, never authority. Nothing is spent, granted or gated on any of
	it; the worst a forged payload achieves is a misleading line in a report only
	the owner reads. Every field is still type-checked and clamped, because a
	malformed one would break the DataStore write and lose the REAL feedback with it
	-- that is the failure worth defending against here, not a lie about somebody's
	frame rate.

	WHY THESE FOUR. A "laggy" report with no context is nearly undiagnosable -- the
	one that prompted this (ixxBroken, build 825) came from a player seven slabs in
	on a level-4 pail, which rules out every content-scale cause and leaves exactly
	these questions unanswered:

	  fps    what they actually saw. The whole complaint, as a number.
	  sheet  the 3D surface, about a third of the sealer's per-frame cost and the
	         first thing to ask about. Defaults off, so "on" is a real answer.
	  touch  a phone and a desktop are different machines with the same report.
	  qual   Roblox's own quality slider, which players do move.
]]
local function context(raw: any): { [string]: any }?
	if type(raw) ~= "table" then return nil end
	--[[
		READABLE NAMES OUT, EITHER NAME IN.

		These were abbreviated to keep the stored entry small, which was the wrong
		trade: a feedback record is written by a machine and read by a person, so the
		bytes never mattered and `qual` versus `qualityLevel` did.

		The READER still accepts the old short keys, because a rename ships in two
		places at once and clients do not all reload together -- for a while after this
		publishes, somebody's session is still running the previous Shell and sending
		`vp`. Dropping those would put holes in exactly the reports sent during the
		changeover. It costs one `or` each and can go once no old client can still be
		running.

		Entries written BEFORE this keep their short keys -- nothing rewrites history --
		so a reader walking the whole store should expect both shapes.
	]]
	local r = raw :: any
	local fps = tonumber(r.frameRate or r.fps)
	local qual = tonumber(r.qualityLevel or r.qual)
	local vp = tonumber(r.screenWidth or r.vp)
	local mem = tonumber(r.memoryMb or r.mem)
	--[[
		`dev` is checked against a LIST rather than merely being a string, because it
		is the one field a reader will treat as a fact at a glance. A free-text device
		name out of a client is a place to hide anything from a novel to a slur, and
		this lands in a report the owner reads. Anything unrecognised is dropped, and
		`vp` below still carries the raw width it was derived from.
	]]
	local DEVICES = { Console = true, Phone = true, Tablet = true,
		Hybrid = true, Desktop = true }
	local dev = r.device or r.dev
	local sheet = if r.sealerSurface3D ~= nil then r.sealerSurface3D else r.sheet
	local touch = if r.touchScreen ~= nil then r.touchScreen else r.touch
	return {
		-- clamped rather than rejected: an absurd figure is still evidence that
		frameRate = if fps then math.clamp(math.floor(fps), 0, 999) else nil,
		qualityLevel = if qual then math.clamp(math.floor(qual), 0, 21) else nil,
		screenWidth = if vp then math.clamp(math.floor(vp), 0, 16384) else nil,
		memoryMb = if mem then math.clamp(math.floor(mem), 0, 65536) else nil,
		device = if type(dev) == "string" and DEVICES[dev] then dev else nil,
		sealerSurface3D = if type(sheet) == "boolean" then sheet else nil,
		touchScreen = if type(touch) == "boolean" then touch else nil,
	}
end

SendFeedback.OnServerInvoke = function(plr: Player, text: any, ctx: any): (boolean, string)
	if type(text) ~= "string" then return false, "Nothing to send" end

	-- trimmed before the emptiness test, or a box of spaces counts as feedback
	local body = (text:gsub("^%s+", ""):gsub("%s+$", ""))
	if #body == 0 then return false, "Type something first" end
	if #body > MAX_CHARS then body = body:sub(1, MAX_CHARS) end

	local now = os.clock()
	local last = lastSent[plr]
	if last and now - last < COOLDOWN then
		return false, ("Please wait %d seconds"):format(math.ceil(COOLDOWN - (now - last)))
	end

	if not store then return false, "Feedback is unavailable right now" end

	--[[
		The cooldown is stamped BEFORE the write, not after.

		SetAsync yields, and a player who clicks twice either side of that yield would
		pass the check twice -- the same reason TutorialFunnel latches before its call.
		It is handed back if the write fails, because this is a rate limit and not a
		record of having tried.
	]]
	lastSent[plr] = now

	local key = ("f_%d_%d"):format(os.time(), plr.UserId)
	--[[
		Spelled out for the same reason the context block is: a person reads this.
		Entries written before this keep u / n / t / v, so expect both shapes when
		walking the whole store.
	]]
	local entry = {
		userId = plr.UserId,
		name = plr.Name,
		text = body,
		at = os.time(),
		-- which build they were playing, so a complaint can be placed against a
		-- version rather than guessed at
		placeVersion = game.PlaceVersion,
		-- and what it was running on; see `context`
		client = context(ctx),
	}

	local ok, err = pcall(function()
		(store :: DataStore):SetAsync(key, entry, { plr.UserId })
	end)
	if not ok then
		lastSent[plr] = last
		warn(("[FeedbackService] save failed for %s: %s"):format(plr.Name, tostring(err)))
		return false, "Could not send -- try again in a moment"
	end

	if RunService:IsStudio() then
		print(("[FeedbackService] %s -> %s  %q"):format(plr.Name, key, body))
	end
	return true, "Thanks -- your feedback was sent"
end

if RunService:IsStudio() then
	print(("[FeedbackService] ready -- store %q, %d char cap, %ds cooldown")
		:format(STORE_NAME, MAX_CHARS, COOLDOWN))
end
