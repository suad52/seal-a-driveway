--!strict
--[[
	DealershipSigns -- writes the showroom's spec plates from the rig catalogue.

	The building is authored and saved in the place, which is what makes it
	visible in Studio, and that is exactly why the NUMBERS on it cannot be. Bake a
	price into a SurfaceGui and the day somebody retunes Rigs.List the showroom
	starts advertising a figure the till does not charge, with nothing anywhere to
	catch it. Rigs' own header says the table exists so "a rig can never advertise
	a number it does not actually have" -- so the geometry is authored and the text
	is not.

	Display only. It sells nothing, checks nothing and owns nothing: the plates are
	read by players, and the prompts beside them open the panel that UpgradeService
	actually takes money through.

	One plate per rig, matched by name. A rig with no plate is a rig the showroom
	silently stopped mentioning, so it warns rather than skipping quietly -- adding
	a fourth truck to the catalogue grows the buy screen on its own and this is the
	only place that would not follow.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rigs = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Rigs"))
local Upgrades = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Upgrades"))

-- Thousands separators, because a showroom price is read rather than compared:
-- Upgrades.short would render the Cistern as "25M", which is right on a shop row
-- and wrong on a windscreen.
local function money(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function label(host: Instance, name: string): TextLabel?
	local gui = host:FindFirstChildOfClass("SurfaceGui")
	local t = gui and gui:FindFirstChild(name)
	return (t and t:IsA("TextLabel")) and t or nil
end

local function write()
	local hall = workspace:WaitForChild("RigDealership", 30)
	if not hall then
		warn("[DealershipSigns] no RigDealership in Workspace -- no plates to write")
		return
	end

	for _, rig in ipairs(Rigs.List) do
		local host = hall:FindFirstChild("NamePlate_" .. rig.id, true)
		if not host then
			warn(("[DealershipSigns] %s has no NamePlate_%s in the showroom --"
				.. " its card will stay blank"):format(rig.name, rig.id))
			continue
		end

		local title = label(host, "Title")
		if title then title.Text = rig.name end
		local tagline = label(host, "Tagline")
		if tagline then tagline.Text = rig.tagline end

		-- The four figures the buy screen draws its bars from, in the same order and
		-- the same units, so the plate and the panel can never tell two stories.
		local stats = label(host, "Stats")
		if stats then
			-- Two lines, not four. The plate is 3.6 studs wide and TextScaled wraps
			-- rather than shrinks once a line is longer than the box, so a third line
			-- of "studs of hose" turns into a fourth and walks over the price.
			stats.Text = ("%d spd  \u{2022}  %d hose\n%s tank  \u{2022}  x%.2f pump")
				:format(rig.topSpeed, rig.hose, Upgrades.short(rig.tank), rig.pump)
		end

		local price = label(host, "Price")
		if price then price.Text = "$" .. money(rig.price) end
	end
end

task.spawn(write)
