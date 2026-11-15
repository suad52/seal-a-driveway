
local M = {}

function M.skins(S)
	if S.HalloweenSharedVersion == 2 then
		return
	end

	S.HalloweenSharedVersion = 2

	local function make(id, name, green, order)
		local c = green and Color3.fromRGB(97, 240, 76) or Color3.fromRGB(255, 119, 35)

		return {
			id = id,
			name = name,
			rarity = "Legendary",
			order = order,
			blurb = "HALLOWEEN EVENT",

			paint = {
				Blade = {
					colour = Color3.fromRGB(34, 22, 42),
					material = Enum.Material.SmoothPlastic
				},
				Head = {
					colour = c,
					material = Enum.Material.Neon
				},
				Collar = {
					colour = Color3.fromRGB(159, 64, 230),
					material = Enum.Material.Neon
				},
				Pole = {
					colour = Color3.fromRGB(47, 28, 60),
					material = Enum.Material.Metal
				}
			},

			dress = function(rig)
				if rig:GetAttribute("ForViewport") then
					return
				end

				local head = rig:FindFirstChild("Head")

				if head then
					local e = Instance.new("ParticleEmitter")
					e.Name = "HalloweenSkinSparkles"
					e:SetAttribute("SqueegeeSkin", true)
					e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
					e.Color = ColorSequence.new(c)
					e.Rate = 10
					e.Lifetime = NumberRange.new(.35, 1.1)
					e.Speed = NumberRange.new(.2, .6)
					e.LockedToPart = true
					e.Parent = head

					local light = Instance.new("PointLight")
					light:SetAttribute("SqueegeeSkin", true)
					light.Color = c
					light.Brightness = 1.3
					light.Range = 10
					light.Parent = head
				end
			end
		}
	end

	for _, entry in ipairs({
		make("Sweet", "Trick or Sweet!", false, 30),
		make("Spell", "Spell", true, 31)
		}) do
		if not S.ById[entry.id] then
			table.insert(S.List, entry)
			S.ById[entry.id] = entry
		end
	end

	local owns, ownedSet, price = S.owns, S.ownedSet, S.priceOf

	local function event(id)
		return id == "Sweet" or id == "Spell"
	end

	S.owns = function(p, id)
		if event(id) then
			return p ~= nil and p:GetAttribute("HalloweenOwned_" .. id) == true
		end

		return owns(p, id)
	end

	S.ownedSet = function(p)
		local set = ownedSet(p)

		if p then
			for _, id in ipairs({ "Sweet", "Spell" }) do
				if p:GetAttribute("HalloweenOwned_" .. id) == true then
					set[id] = true
				end
			end
		end

		return set
	end

	S.priceOf = function(id)
		if event(id) then
			return 0
		end

		return price(id)
	end
end

function M.catalog(C)
	if C.HalloweenSharedVersion == 2 then
		return
	end

	C.HalloweenSharedVersion = 2

	for _, entry in ipairs({
		{
			id = "pumpkinrescue",
			name = "Pumpkin Rescue",
			event = true
		},
		{
			id = "nightmares",
			name = "Nightmares",
			event = true
		}
		}) do
		if not C.ById[entry.id] then
			table.insert(C.List, entry)
			C.ById[entry.id] = entry
		end
	end

	local owns = C.owns

	C.owns = function(p, id)
		if id == "pumpkinrescue" then
			return p:GetAttribute("HalloweenOwned_PumpkinRescue") == true
		end

		if id == "nightmares" then
			return p:GetAttribute("HalloweenOwned_Nightmares") == true
		end

		return owns(p, id)
	end
end

function M.palettes(list)
	local found = {}

	for _, p in ipairs(list) do
		found[p.id] = true
	end

	for _, entry in ipairs({
		{
			"pumpkinrescue",
			"Pumpkin Rescue",
			{
				"ff5400",
				"681c08",
				"ff5400",
				"681c08",
				"ff5400",
				"681c08"
			}
		},
		{
			"nightmares",
			"Nightmares",
			{
				"9600ff",
				"080d68",
				"000000",
				"2c0868",
				"8400ff",
				"1712d5"
			}
		}
		}) do
		if found[entry[1]] then
			continue
		end

		local colors = {}
		local keys = {}

		for i, hex in ipairs(entry[3]) do
			local c = Color3.fromHex(hex)

			colors[i] = c
			keys[i] = ColorSequenceKeypoint.new(
				(i - 1) / (#entry[3] - 1),
				c
			)
		end

		local c = colors[1]
		local v = Vector3.new(c.R, c.G, c.B)

		local p = {
			id = entry[1],
			name = entry[2],
			note = "HALLOWEEN EVENT",
			colors = colors,
			sequence = ColorSequence.new(keys),
			liquid = v,
			sealed = v,
			spec = Vector3.new(1, .97, 1),
			sheen = Vector3.new(1, .8, .8),
			lut = table.create(256)
		}

		for i = 0, 255 do
			local t = i / 255 * (#colors - 1)
			local a = math.min(math.floor(t) + 1, #colors - 1)

			local color = colors[a]:Lerp(
				colors[a + 1],
				t - (a - 1)
			)

			p.lut[i + 1] = Vector3.new(
				color.R,
				color.G,
				color.B
			)
		end

		table.insert(list, p)
	end
end

return M
