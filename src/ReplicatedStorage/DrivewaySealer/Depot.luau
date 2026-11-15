--!strict
--[[
	Depot -- where the fixed installations in the garage actually are.

	Everything is looked up from the built world rather than written down as
	coordinates, for the same reason UpgradeService measures its shop zone off the
	garage floor: the building has already been dragged down the map once, and a
	hardcoded box silently stops matching the moment it moves again.

	Shared by the client (the bucket refills here) and the server (the rig's tank
	refills here, and the spawner lives here), so the two can never disagree about
	where "the tanks" are.
]]

local CollectionService = game:GetService("CollectionService")

local Depot = {}
require(script.Parent:WaitForChild("ExtraRefuel")).prepare()

--[[
	A refuel bay that is not the depot's, marked with a tag rather than found by
	another folder lookup.

	The depot's bay is resolved by name because there is exactly one of it and it
	has moved once already. Districts added later need their own, and hardcoding a
	second path here would mean a third district needs a third. A tag lets a bay be
	built anywhere and be a bay, which is the same reasoning as SealableDriveway.

	⚠️ The depot's own points are still collected FIRST and the tagged ones appended
	after, because TutorialClient anchors its step-3 marker on refuelPoints()[1] and
	expects the depot's FillPad. Sorting this list, or collecting tags first, sends
	the tutorial to another district.
]]
Depot.RefuelTag = "SealerRefuel"

local function garage(): Instance?
	local hood = workspace:FindFirstChild("Neighbourhood")
	local depot = hood and hood:FindFirstChild("Depot")
	return depot and depot:FindFirstChild("Garage") or nil
end
Depot.garage = garage

--[[
	The refuelling points: the pad you stand on and the bulk tanks behind it.

	All of them are returned rather than one, because the bay is long and the
	tanks sit ten studs apart -- measuring to the nearest of them is what makes
	standing anywhere sensible in that corner count as being at the tanks.
]]
--[[
	The answer is cached, because two callers ask for it EVERY FRAME.

	DrivewayClient's hint block and TruckServer's fill loop both call
	distanceToRefuel on their per-frame path, and rebuilding cost two table
	allocations, a literal array, four full GetChildren passes over a 37-child
	folder (one per name) and a GetTagged -- for installations that never move.

	Invalidated rather than trusted: under StreamingEnabled a part can be destroyed
	out from under the cache, and a destroyed or streamed-out part has no Parent, so
	one property read per point is the whole staleness test. A tag added or removed
	after the first call has to rebuild too, since a valid cache would otherwise
	never consult GetTagged again.
]]
local cached: { BasePart }? = nil

local function stale(points: { BasePart }): boolean
	for _, p in ipairs(points) do
		if p.Parent == nil then return true end
	end
	return false
end

CollectionService:GetInstanceAddedSignal(Depot.RefuelTag):Connect(function()
	cached = nil
end)
CollectionService:GetInstanceRemovedSignal(Depot.RefuelTag):Connect(function()
	cached = nil
end)

function Depot.refuelPoints(): { BasePart }
	local hit = cached
	if hit and #hit > 0 and not stale(hit) then return hit end

	local points: { BasePart } = {}
	local seen: { [Instance]: boolean } = {}

	local g = garage()
	local refuel = g and g:FindFirstChild("Refuel")
	if refuel then
		for _, name in ipairs({ "FillPad", "BulkTank", "ArmNozzle", "PumpBody" }) do
			for _, c in ipairs(refuel:GetChildren()) do
				if c.Name == name and c:IsA("BasePart") and not seen[c] then
					seen[c] = true
					table.insert(points, c)
				end
			end
		end
	end

	-- Every other bay in the map. Guarded on seen so a tag on a depot part -- the
	-- obvious thing to try when adding the second bay -- cannot list it twice and
	-- weight distanceToRefuel toward it.
	for _, p in ipairs(CollectionService:GetTagged(Depot.RefuelTag)) do
		if p:IsA("BasePart") and not seen[p] then
			seen[p] = true
			table.insert(points, p)
		end
	end

	-- Only cache a real answer. An empty list means the garage has not streamed in
	-- yet, and caching that would lock every caller out for the session.
	if #points > 0 then cached = points end
	return points
end

-- Distance to the nearest refuelling point, or nil when the garage has no
-- refuel bay at all (in which case callers should not lock anyone out).
function Depot.distanceToRefuel(position: Vector3): number?
	local points = Depot.refuelPoints()
	if #points == 0 then return nil end
	local best = math.huge
	for _, p in ipairs(points) do
		-- to the part's surface, not its centre: the bulk tanks are eleven studs
		-- across and centre distance would have you refuelling from inside one
		local d = (p:GetClosestPointOnSurface(position) - position).Magnitude
		if d < best then best = d end
	end
	return best
end

-- Where the rig is parked and spawned. Falls back to the garage floor's middle
-- so a place without a marked bay still works.
function Depot.bayPivot(): CFrame?
	local g = garage()
	if not g then return nil end
	local bay = g:FindFirstChild("Bay")
	local label = bay and bay:FindFirstChild("BayLabel")
	if label and label:IsA("BasePart") then
		return CFrame.new(label.Position.X, label.Position.Y, label.Position.Z)
	end
	local shell = g:FindFirstChild("Shell")
	local floor = shell and shell:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") then
		return CFrame.new(floor.Position + Vector3.new(0, floor.Size.Y * 0.5, 0))
	end
	return nil
end

return Depot
