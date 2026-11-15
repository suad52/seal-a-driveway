--!strict
--[[
	SectionGateClient -- opens the road at the end of a section once this player
	has finished every slab in it.

	Client-side, and it has to be. Progress is per player -- the server keeps one
	record each and DrivewayServer derives the per-section attributes from it -- but
	the gate is a single model in Workspace shared by everybody in the server.
	Swinging it on the server would open one player's road for the whole lobby.

	So the gate is a per-player VIEW of a shared prop: transparency, CanCollide and
	CFrame are all set locally here, which the server never sees and other clients
	never receive. The character collides against the local physics state, so a
	leaf this client has opened is one this client can drive through and nobody
	else can.

	The gate models were built with Progress and Unlocked attributes already on
	them and nothing reading either. Those are set here too -- locally, mirroring
	this player -- so the scaffolding means what it looks like it means.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sections = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Sections"))
local Rebirth = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Rebirth"))

local plr = Players.LocalPlayer

local SWING = math.rad(104)   -- how far a leaf lies back when open
local SWING_TIME = 1.6

--==[ THE LEAVES ]============================================================

local function hingeOf(leaf: BasePart, centre: Vector3): (CFrame, number)
	local half = leaf.CFrame.RightVector * (leaf.Size.X * 0.5)
	local a, b = leaf.Position + half, leaf.Position - half
	local pivot = if (a - centre).Magnitude > (b - centre).Magnitude then a else b

	local free = (leaf.Position - pivot)
	local flat = Vector3.new(free.X, 0, free.Z)
	local look = leaf.CFrame.LookVector
	local lookFlat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 or lookFlat.Magnitude < 1e-4 then
		return CFrame.new(pivot), 1
	end
	local sign = if flat.Unit:Cross(lookFlat.Unit).Y >= 0 then 1 else -1
	return CFrame.new(pivot), sign
end

local function isLeaf(d: Instance): boolean
	return d:IsA("BasePart") and (d.Name == "LeafLeft" or d.Name == "LeafRight")
end

-- The pair of poses for one leaf, worked out from where it is sitting NOW.
-- Only ever called on a leaf in its server state -- see noteLeaf.
local function posesOf(leaf: BasePart, centre: Vector3): (CFrame, CFrame)
	local pivot, sign = hingeOf(leaf, centre)
	-- rotate the leaf about the hinge: back into the hinge frame, turn, out again
	return leaf.CFrame, pivot * CFrame.Angles(0, SWING * sign, 0) * pivot:Inverse() * leaf.CFrame
end

--==[ THE BOARD ]=============================================================

local function boardLabel(gate: Model): TextLabel?
	local board = gate:FindFirstChild("ProgressBoard")
	local gui = board and board:FindFirstChildOfClass("SurfaceGui")
	return gui and gui:FindFirstChildWhichIsA("TextLabel", true) or nil
end

--==[ THE JUMP GUARDS ]======================================================

--==[ ONE GATE ]==============================================================

local function bind(s: Sections.Section): boolean
    if s.gate == "NoEndGate" then
        return true
    end
	local gate = Sections.gateOf(s)
	if not gate then return false end
    -- SkipZone: gate ownership comes from Sections.gateContainer.

	local leaves: { [BasePart]: { shut: CFrame, open: CFrame } } = {}

	local function noteLeaf(d: Instance)
		if not isLeaf(d) then return end
		local p = d :: BasePart
		if leaves[p] then return end
		-- safe to read as the shut pose: a part is only ever seen here on the frame it
		-- streams in, and it arrives carrying whatever the server has, never our edit
		local shut, openCF = posesOf(p, gate:GetPivot().Position)
		leaves[p] = { shut = shut, open = openCF }
	end

	-- Nothing is tweened on the first pass. A player who walks in with the road
	-- already open should find it open, not watch it swing for them as though they
	-- had just earned it. Same for a leaf that has only just streamed back in.
	local settled = false

	local function apply()
		local open = plr:GetAttribute(Sections.openAttr(s.id)) == true
		local done = (plr:GetAttribute(Sections.doneAttr(s.id)) :: number?) or 0
		-- the server's count, not the client's: see Sections.totalAttr
		local total = (plr:GetAttribute(Sections.totalAttr(s.id)) :: number?) or #Sections.slabsOf(s)
		local rebirths = (plr:GetAttribute("Rebirths") :: number?) or 0

		local sign, signGuis, beacons, guards = {}, {}, {}, {}
		for _, d in ipairs(gate:GetChildren()) do
			if d:IsA("BasePart") then
				if d.Name == "ProgressBoard" or d.Name == "BoardFrame" or d.Name == "BoardLeg" then
					sign[#sign + 1] = d
					--[[
						A SurfaceGui draws whether or not its part does. Transparency on the
						board hides the slab of plastic and leaves the Gui painted on the same
						plane, so the sign came out as a black rectangle floating over an open
						road. Hiding the label inside it is not enough either -- the Frame
						behind the label is what the black was.
					]]
					for _, g in ipairs(d:GetDescendants()) do
						if g:IsA("SurfaceGui") then signGuis[#signGuis + 1] = g end
					end
				elseif d.Name == "Beacon" then
					beacons[#beacons + 1] = d
				elseif d.Name == "JumpGuard" then
					guards[#guards + 1] = d
				end
			end
		end
		local label = boardLabel(gate)
		-- Every slab finished and the gate still shut means the other half of the
		-- toll is outstanding: rebirths. The board has to say so, or it reads as
		-- "15 / 15" over a road that will not open and looks broken.
		local owed = total > 0 and done >= total
			and Rebirth.countOf(plr) < Sections.requiresOf(s)

		-- the scaffolded attributes, now meaning what they say -- locally, for this
		-- player, which is the only scope they can honestly have
		gate:SetAttribute("Progress", if total > 0 then done / total else 0)
		gate:SetAttribute("Unlocked", open)

		for p, st in pairs(leaves) do
			if p.Parent == nil then
				-- streamed out from under us; the entry goes with it, and noteLeaf will
				-- read a fresh rest pose if it ever comes back
				leaves[p] = nil
			else
				p.CanCollide = not open
				local want = if open then st.open else st.shut
				if settled and (p.CFrame.Position - want.Position).Magnitude > 0.05 then
					TweenService:Create(p, TweenInfo.new(SWING_TIME,
						Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = want }):Play()
				else
					p.CFrame = want
				end
			end
		end

		-- The guards switch with the leaves and are never posed -- they are wall,
		-- not gate. See THE JUMP GUARDS.
		for _, d in ipairs(guards) do d.CanCollide = not open end

		-- The sign goes, rather than changing to say the road is open: an open road
		-- says that by itself, and a board still standing over it reads as a gate
		-- that has not quite finished opening.
		for _, d in ipairs(sign) do d.Transparency = if open then 1 else 0 end
		for _, g in ipairs(signGuis) do g.Enabled = not open end
		if label then
			label.Visible = not open
			label.Text = if open then
				s.open
				elseif owed then
				(string.format("%s %i / %i", s.owed, rebirths, s.requires) or s.closed)
				--s.owed .. rebirths .. " / " .. s.requires
				elseif total > 0 then 
				("%s  \u{2022}  %d / %d"):format(s.closed, done, total)
				else 
				s.closed
		end
		for _, b in ipairs(beacons) do
			b.Transparency = if open then 1 else 0
			local light = b:FindFirstChildWhichIsA("Light", true)
			if light then light.Enabled = not open end
		end
	end

	for _, d in ipairs(gate:GetChildren()) do noteLeaf(d) end
	apply()
	settled = true

	gate.ChildAdded:Connect(function(d)
		if not (isLeaf(d) or d:IsA("BasePart")) then return end
		noteLeaf(d)
		-- a part that has just streamed in should be found in its final state, not
		-- caught swinging, so this pass is not tweened
		local was = settled
		settled = false
		apply()
		settled = was
	end)

	plr:GetAttributeChangedSignal(Sections.openAttr(s.id)):Connect(apply)
	plr:GetAttributeChangedSignal(Sections.doneAttr(s.id)):Connect(apply)
	plr:GetAttributeChangedSignal(Sections.totalAttr(s.id)):Connect(apply)
	-- The rebirths are the other half of the toll, and only the board reads them --
	-- whether the gate OPENS is still the server's answer, above.
	plr:GetAttributeChangedSignal(Rebirth.Attr):Connect(apply)
	return true
end

task.spawn(function()
	local t0 = os.clock()
	while not plr:GetAttribute("ProfileLoaded") and os.clock() - t0 < 20 do
		task.wait(0.2)
	end
	local pending = table.clone(Sections.List)
	while #pending > 0 do
		-- backwards, so removing an entry cannot skip the one after it
		for i = #pending, 1, -1 do
			if bind(pending[i]) then table.remove(pending, i) end
		end
		if #pending == 0 then break end
		task.wait(3)
	end
end)

