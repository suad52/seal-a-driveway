--!strict
--[[
	SqueegeeSkinService -- puts the player's chosen squeegee skin on their tool.

	ON THE SERVER, AND THAT IS THE WHOLE REASON THIS FILE EXISTS.

	A skin dressed on a client is dressed on that one screen. The tools are
	per-player clones out of StarterPack, so the instances a player carries are
	real, replicated instances -- dress them here and every other client sees the
	skin on that player's squeegee, which is the point of having one. This is the
	same arrangement VipService uses for the gold kit, and this file follows its
	shape deliberately: watch both containers, re-ask on every arrival, and never
	assume a tool was there at spawn.

	WHY THE WAND AND THE PAIL ARE NOT TOUCHED. Skins are squeegee-only for now, and
	SqueegeeSkins.rigOf refuses anything whose SealerTool attribute is not
	"Squeegee" -- so a pail can never be handed to a dresser that expects a blade.

	⚠ ORDER AGAINST VIP GOLD. VipService gilds a tool synchronously as it arrives;
	this defers, so an explicitly chosen skin lands last and wins. That is the
	intended precedence -- a player who picked Neon Circuit picked it -- and a VIP
	who has chosen nothing still gets gold, because the default skin is applied
	only when one has actually been set. See `wanted` below.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local SqueegeeSkins = require(Pack:WaitForChild("SqueegeeSkins"))
-- For the kits that are owned by holding a game pass; see `wanted` and the pass
-- hook in `watch`.
local Passes = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Passes"))

--[[
	Nil means "has not chosen", which is NOT the same as choosing Site Standard.

	A player who has never opened the skin list must come out of this file exactly
	as they went in, or a VIP's gold squeegee would be repainted grey by a service
	they never asked for. Only an explicit choice is applied.
]]
local function wanted(plr: Player): string?
	local id = plr:GetAttribute(SqueegeeSkins.Attr)
	if type(id) ~= "string" or id == "" then return nil end
	if not SqueegeeSkins.ById[id] then return nil end
	--[[
		⚠ AND STILL OWNED -- asked on every dressing, never trusted from the equip
		that wrote the attribute.

		The CHOICE persists: UpgradeService restores `Skin_Squeegee` off the profile
		and validates it against the catalogue and nothing more. A PASS KIT's
		ownership does not persist with it -- it is the pass, live, every time -- so
		without this, buying VIP, wearing the kit and then being refunded left the
		gold kit on for good. That is the exact leak `SqueegeeSkins.serialise`
		refuses to write a pass kit into `SkinsOwned` to avoid, and it was still open
		through the worn attribute.
	]]
	if not SqueegeeSkins.owns(plr, id) then return nil end
	return id
end

local function dress(plr: Player, tool: Instance)
	local id = wanted(plr)
	if not id then return end
	local rig = SqueegeeSkins.rigOf(tool)
	if rig then SqueegeeSkins.apply(rig, id) end
end

local function dressAll(plr: Player)
	for _, where in ipairs({ plr:FindFirstChildOfClass("Backpack"), plr.Character }) do
		if where then
			for _, tool in ipairs(where:GetChildren()) do
				if tool:IsA("Tool") then dress(plr, tool) end
			end
		end
	end
end

--[[
	One connection per container, and dressing is idempotent -- apply() strips its
	own litter and repaints from a known base every time -- so the equip and
	unequip traffic this also catches costs a walk of a handful of parts and
	changes nothing.
]]
local watched: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function watchTools(where: Instance, plr: Player)
	if watched[where] then return end
	watched[where] = true
	where.ChildAdded:Connect(function(c)
		-- deferred so it lands after VipService's synchronous gild; see the header
		if c:IsA("Tool") then task.defer(dress, plr, c) end
	end)
end

local function watch(plr: Player)
	plr.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then watchTools(c, plr) end
	end)
	local pack = plr:FindFirstChildOfClass("Backpack")
	if pack then watchTools(pack, plr) end

	local function onCharacter(character: Model)
		watchTools(character, plr)
		--[[
			Twice, and the second one is not superstition.

			The backpack is refilled from StarterPack on spawn and VipService gilds on
			the same frame; whose deferred pass runs first depends on connection order,
			which is not something this file should depend on. The late pass costs a
			walk of four parts and settles it.
		]]
		task.defer(dressAll, plr)
		task.delay(0.35, function()
			if plr.Parent then dressAll(plr) end
		end)
	end
	plr.CharacterAdded:Connect(onCharacter)
	if plr.Character then task.spawn(onCharacter, plr.Character) end

	-- Choosing a skin mid-session repaints what is already in hand.
	plr:GetAttributeChangedSignal(SqueegeeSkins.Attr):Connect(function()
		dressAll(plr)
	end)

	--[[
		⚠ AND ON EVERY PASS A KIT IS GATED BEHIND, which stopped being optional the
		moment `wanted` started asking about ownership.

		PassService asks Roblox and mirrors the answer onto `Pass_<id>` a second or
		two INTO the session -- well after the spawn pass below. A VIP whose chosen
		skin is the kit would come out of that pass undressed, because at that
		instant they provably did not own it, and nothing would have looked again
		until they next changed skin.

		It is also what puts the kit straight into the hands of somebody who buys VIP
		mid-session, with no re-equip.

		Hooked once per distinct pass rather than per skin, since one pass could gate
		several kits later -- the same shape SkinCase hooks its own redraw with.
	]]
	local hooked: { [string]: boolean } = {}
	for _, sk in ipairs(SqueegeeSkins.List) do
		local p = sk.pass
		if p and not hooked[p] then
			hooked[p] = true
			plr:GetAttributeChangedSignal(Passes.attrName(p)):Connect(function()
				dressAll(plr)
			end)
		end
	end

	dressAll(plr)
end

--==[ CHOOSING ONE ]========================================================

--[[
	The equip remote, moved here when the slot machine was removed (2026-08-14).

	It lived in SkinRollService, which is gone -- but choosing a skin was never
	the machine's business, and this file is already the one thing in the game
	that owns `Skin_Squeegee`. Setting that attribute IS the whole equip path:
	the watcher above sees it change and repaints what is in the player's hands.

	⚠ THE ID ARRIVES FROM A CLIENT AND IS WORTH NOTHING UNTIL IT IS CHECKED --
	against the catalogue AND against what this player owns, in that order. A
	value that is not a skin id would otherwise be written straight into the
	attribute this file reads back, and a real id nobody earned would hand out a
	Legendary for free.

	NO `provideSave` HOOK, unlike the service this came from: that one was a
	ModuleScript and this is a Script, so UpgradeService cannot require it to hand
	one in. The choice rides out on the ordinary autosave instead, which is what
	the old hook's own comment called the acceptable fallback -- the only case
	that degrades is a server dying in the seconds after somebody changes skin.
]]
-- Selling is SkinShopService's; this file only wears them.
local EquipReq = SqueegeeSkins.remotes():WaitForChild("SkinEquip") :: RemoteEvent

local lastEquip: { [Player]: number } = {}

EquipReq.OnServerEvent:Connect(function(plr, id)
	if type(id) ~= "string" then return end
	local now = os.clock()
	if now - (lastEquip[plr] or 0) < 0.25 then return end
	lastEquip[plr] = now

	if not SqueegeeSkins.ById[id] then return end
	if not SqueegeeSkins.owns(plr, id) then return end
	if plr:GetAttribute(SqueegeeSkins.Attr) == id then return end

	plr:SetAttribute(SqueegeeSkins.Attr, id)
end)

Players.PlayerRemoving:Connect(function(plr) lastEquip[plr] = nil end)

Players.PlayerAdded:Connect(watch)
for _, plr in ipairs(Players:GetPlayers()) do task.spawn(watch, plr) end

print(("[SqueegeeSkinService] ready -- %d skins, set the %s attribute on a player")
	:format(#SqueegeeSkins.List, SqueegeeSkins.Attr))
