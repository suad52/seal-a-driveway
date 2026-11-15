--!strict
--[[
	SectionHelpClient -- "what's left?", asked at the gate that is stopping you.

	A player standing at a shut road gate can read the board on it -- ROAD CLOSED,
	12 / 16 -- and still have no idea WHICH four. The map is a neighbourhood of
	driveways that all look alike once they are sealed, and the only thing that told
	them apart was the missed-patch highlights, which are per-slab and only show up
	once you are already standing on the right one.

	So: a glowing ring on the tarmac just short of the gate. Stand in it and the
	prompt asks the question; take it and the gold marker goes up over ONE job, with
	a trail of dashes running to it from your feet. It is the same picture the
	tutorial points at things with, and deliberately so -- a player learned to
	follow that chevron in their first five minutes.

	ONE AT A TIME, AND THE RING IS THE LOOP. Seal it, walk back to the ring, ask
	again, get the next one. The player never carries more than one instruction and
	the only thing they have to remember is where the ring is -- which is the gate
	they were already stood at wondering what was left.

	CLIENT-SIDE, AND IT HAS TO BE, for exactly the reason SectionGateClient gives:
	progress is per player and the gate is one shared model. The ring, the prompt
	and the marker are all built here and parented into Workspace, so they are this
	player's view of a shared prop and nobody else sees them.

	The marker puts itself away when the player walks up to it or after HOLD
	seconds, whichever comes first. It never needs dismissing, and it cannot be left
	standing over a slab that has since been sealed.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Sections = require(Pack:WaitForChild("Sections"))
local Waypoint = require(Pack:WaitForChild("Waypoint"))
local Rebirth = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Rebirth"))

local plr = Players.LocalPlayer

local YELLOW = Color3.fromRGB(255, 214, 66)

-- The ring's radius, and therefore how close counts as standing in it: the prompt
-- reaches exactly as far as the paint does, so "inside it" is a thing you can see.
local PAD_R = 7.5
-- How far short of the gate the ring sits. The stop line is 5 studs out, so this
-- puts it on the approach rather than under the arch.
local STAND_OFF = 12
-- Seconds the marker stands before it times out on its own.
local HOLD = 30
-- And how close is close enough to count as having walked up to it. Generous,
-- because the marker sits on a slab's CENTRE and a driveway is 30 to 60 studs
-- across -- landing on the tarmac is arriving, and the highlights take over there.
local ARRIVED = 22

local fx = Instance.new("Folder")
fx.Name = "SectionHelpFX"
fx.Parent = workspace

local wp = Waypoint.new("SectionHelpMarker")

type Showing = {
	spot: Vector3,
	caption: string,
	expires: number,
	-- nil when the marker is on the gate itself: the player is already standing in
	-- the ring, so an arrival test would put it away on the frame it went up
	arriveWithin: number?,
}
local showing: Showing? = nil

local pads: { [string]: BasePart } = {}

--==[ THE RING ]==============================================================

local function placePad(s: Sections.Section): BasePart?
	local gate = Sections.gateOf(s)
	if not gate then return nil end
	-- Under StreamingEnabled the model replicates as a stub long before its parts
	-- do, and a pivot taken then is the bounding box of nothing. The stop line is
	-- the part worth waiting for anyway.
	local mark = gate:FindFirstChild("StopLine") :: BasePart?
	if not mark then return nil end

	local slabs = Sections.slabsOf(s)
	if #slabs == 0 then return nil end
	local sum = Vector3.zero
	for _, slab in ipairs(slabs) do sum += slab.Position end
	local toward = sum / #slabs - mark.Position
	local flat = Vector3.new(toward.X, 0, toward.Z)
	if flat.Magnitude < 1 then return nil end

	local at = mark.Position + flat.Unit * STAND_OFF
	-- Dropped onto whatever the road actually is rather than assumed flat, and with
	-- our own decoration filtered out or the ring lands on last frame's ring.
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { fx, wp.folder }
	local hit = workspace:Raycast(at + Vector3.new(0, 60, 0), Vector3.new(0, -120, 0), rp)
	local y = if hit then hit.Position.Y else mark.Position.Y

	local pad = Instance.new("Part")
	pad.Name = "WhatsLeft_" .. s.id
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(0.3, PAD_R * 2, PAD_R * 2)
	-- a cylinder's flat faces are on its X axis, so it is tipped on its side to lie
	-- down; 0.12 clears the sealer overlay's 0.035 on the road underneath
	pad.CFrame = CFrame.new(at.X, y + 0.12, at.Z) * CFrame.Angles(0, 0, math.rad(90))
	pad.Anchored = true
	pad.CanCollide = false

	pad.CanQuery = false
	pad.CanTouch = false
	pad.CastShadow = false
	pad.Material = Enum.Material.Neon
	pad.Color = YELLOW
	pad.Transparency = 0.5
	pad.Parent = fx

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "WhatsLeft"
	prompt.ActionText = "See what's next"
	prompt.ObjectText = ""
	prompt.HoldDuration = 0
	-- Exactly the ring's own radius, so the question appears when the player is
	-- standing on the paint and not a step before it.
	prompt.MaxActivationDistance = PAD_R
	-- The gate's own wing walls are between the player and the middle of the ring
	-- from some approaches, and a prompt that vanishes behind a fence post reads as
	-- broken. There is nothing to hide behind out here anyway.
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad

	pads[s.id] = pad
	return pad
end

--==[ WHAT IS ACTUALLY LEFT ]=================================================

local focusKey: { [string]: string? } = {}

local function nextJob(s: Sections.Section, pad: BasePart): (Vector3, string, number?)
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local here = if root then root.Position else pad.Position

	local sealed = Sections.sealedSetOf(plr)
	local now = Sections.nowSetOf(plr)
	local want = focusKey[s.id]
	local held: BasePart? = nil
	local nearest: BasePart? = nil
	local bestD = math.huge
	local left = 0
	for _, slab in ipairs(Sections.slabsOf(s)) do
		local key = Sections.keyOf(slab)
		if not (sealed[key] or now[key]) then
			left += 1
			if want and key == want then held = slab end
			local d = (slab.Position - here).Magnitude
			if d < bestD then nearest, bestD = slab, d end
		end
	end

	local target = held or nearest
	if target then
		focusKey[s.id] = Sections.keyOf(target)

		local what = Sections.plainName(target):upper()
		local caption = if left == 1
			then ("LAST ONE  \u{2022}  SEAL THIS %s"):format(what)
			else ("SEAL THIS %s"):format(what)
		return target.Position, caption, ARRIVED
	end
	focusKey[s.id] = nil

	local owed = Sections.requiresOf(s) - Rebirth.countOf(plr)
	if owed > 0 then
		return pad.Position,
			(if owed == 1 then "ALL SEALED  \u{2022}  REBIRTH ONCE TO PASS"
			else ("ALL SEALED  \u{2022}  REBIRTH %d TIMES TO PASS"):format(owed)),
			nil
	end
	return pad.Position, "NOTHING LEFT  \u{2022}  THE ROAD IS OPENING", nil
end

--==[ THE RING'S OWN STATE ]==================================================

-- The server's count rather than this client's, for the reason on
-- Sections.totalAttr: CollectionService only knows what has streamed in.
local function refresh(s: Sections.Section)
	local pad = pads[s.id]
	if not pad then return end
	local open = plr:GetAttribute(Sections.openAttr(s.id)) == true
	local prompt = pad:FindFirstChildOfClass("ProximityPrompt") :: ProximityPrompt?

	--[[
		An open road has nothing left to ask about, so the ring goes rather than
		greying out. It is a question, and the question has been answered.
	]]
	pad.Transparency = if open then 1 else 0.5
	if not prompt then return end
	prompt.Enabled = not open

	local done = (plr:GetAttribute(Sections.doneAttr(s.id)) :: number?) or 0
	local total = (plr:GetAttribute(Sections.totalAttr(s.id)) :: number?) or #Sections.slabsOf(s)
	local owed = total > 0 and done >= total
		and Rebirth.countOf(plr) < Sections.requiresOf(s)
	-- Said on the prompt as well as behind it, so a player who does not take the
	-- offer still walks away knowing the shape of what is left.
	prompt.ObjectText = if owed then "Everything sealed"
		elseif total > 0 then ("%d of %d done"):format(done, total)
		else Sections.nameOf(s)
end

--==[ THE MARKER ]============================================================

RunService.Heartbeat:Connect(function()
	-- the ring breathes whether or not anybody is looking at it; it is the thing
	-- that has to be noticed from down the road
	local glow = 0.5 + 0.12 * (0.5 + 0.5 * math.sin(os.clock() * 2.2))
	for _, pad in pairs(pads) do
		if pad.Transparency < 1 then pad.Transparency = glow end
	end

	local st = showing
	if not st then return end
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		wp:Hide()
		showing = nil
		return
	end

	local here = (root :: BasePart).Position
	local flat = Vector3.new(st.spot.X - here.X, 0, st.spot.Z - here.Z)
	local arrived = st.arriveWithin ~= nil and flat.Magnitude <= (st.arriveWithin :: number)
	if arrived or os.clock() >= st.expires then
		wp:Hide()
		showing = nil
		return
	end
	wp:Show(st.spot, st.caption, here)
end)

--==[ WIRING ]================================================================

task.spawn(function()
	local t0 = os.clock()
	while not plr:GetAttribute("ProfileLoaded") and os.clock() - t0 < 20 do
		task.wait(0.2)
	end

	for _, s in ipairs(Sections.List) do
		local section = s
		plr:GetAttributeChangedSignal(Sections.openAttr(section.id)):Connect(function()
			refresh(section)
		end)
		plr:GetAttributeChangedSignal(Sections.doneAttr(section.id)):Connect(function()
			refresh(section)
		end)
		plr:GetAttributeChangedSignal(Sections.totalAttr(section.id)):Connect(function()
			refresh(section)
		end)
		plr:GetAttributeChangedSignal(Rebirth.Attr):Connect(function()
			refresh(section)
		end)
	end

	while true do
		local waiting = false
		for _, s in ipairs(Sections.List) do
			if not pads[s.id] then
				local pad = placePad(s)
				if pad then
					local section = s
					local prompt = pad:FindFirstChildOfClass("ProximityPrompt") :: ProximityPrompt?
					if prompt then
						prompt.Triggered:Connect(function()
							local spot, caption, within = nextJob(section, pad)
							-- asking again re-aims and restarts the clock, which is what a
							-- player who has wandered off and come back is asking for
							showing = {
								spot = spot,
								caption = caption,
								expires = os.clock() + HOLD,
								arriveWithin = within,
							}
						end)
					end
					refresh(section)
				else
					waiting = true
				end
			end
		end
		if not waiting then break end
		task.wait(3)
	end
end)
