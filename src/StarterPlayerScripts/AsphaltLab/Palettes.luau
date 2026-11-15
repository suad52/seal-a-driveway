-- Test-only palette catalog. No writes to the game's Config.
local function v(r, g, b) return Vector3.new(r, g, b) end
local function palette(id, name, note, liquid, sealed, sheen, colors)
	return { id = id, name = name, note = note, liquid = liquid, sealed = sealed,
		spec = v(1, 0.97, 1), sheen = sheen, colors = colors }
end
local palettes = {
	{ id = "classic", name = "Classic", note = "Original game appearance", colors = {Color3.fromRGB(32,32,36), Color3.fromRGB(77,78,84)} },
	palette("pink", "Baby Pink", "Soft candy pink", v(1,.64,.79), v(.96,.57,.74), v(1,.80,.91), {Color3.fromRGB(255,163,201), Color3.fromRGB(255,218,234)}),
	palette("gold", "Champagne Gold", "Polished gold + golden sparkles", v(.95,.80,.35), v(.84,.71,.29), v(1,.91,.60), {Color3.fromRGB(214,181,74), Color3.fromRGB(255,240,170)}),
	palette("pearl", "Lavender Pearl", "Lavender pearl + delicate sparkles", v(.77,.65,.94), v(.67,.55,.85), v(.77,.91,1), {Color3.fromRGB(171,140,217), Color3.fromRGB(209,235,255)}),
	palette("mint", "Mint Candy", "Soft mint finish", v(.49,.94,.77), v(.38,.83,.66), v(.72,1,.91), {Color3.fromRGB(97,212,168), Color3.fromRGB(192,255,230)}),
	palette("ice", "Ice Blue", "Ice blue + crystal sparkles", v(.48,.79,1), v(.36,.67,.90), v(.82,.95,1), {Color3.fromRGB(92,171,230), Color3.fromRGB(209,243,255)}),
	palette("rainbow", "Pastel Rainbow", "Soft rainbow + pastel sparkles", v(1,.64,.79), v(.96,.57,.74), v(.90,.90,1), {
		Color3.fromRGB(255,163,201), Color3.fromRGB(195,169,245), Color3.fromRGB(139,206,255),
		Color3.fromRGB(144,237,201), Color3.fromRGB(255,231,147), Color3.fromRGB(255,163,201),
	}),
	palette("vivid", "Vivid Rainbow", "Bright rainbow + colorful sparkles", v(1,.12,.3), v(.94,.1,.28), v(1,.9,1), {
		Color3.fromRGB(255,35,90), Color3.fromRGB(190,40,255), Color3.fromRGB(35,110,255),
		Color3.fromRGB(15,235,210), Color3.fromRGB(85,245,50), Color3.fromRGB(255,220,20), Color3.fromRGB(255,35,90),
	}),
	palette("sunset", "Neon Sunset", "Hot pink, coral and electric gold", v(1,.1,.4), v(.94,.08,.35), v(1,.72,.8), {
		Color3.fromRGB(145,20,255), Color3.fromRGB(255,20,160), Color3.fromRGB(255,65,100),
		Color3.fromRGB(255,135,30), Color3.fromRGB(255,230,65),
	}),
	palette("aurora", "Electric Aurora", "Violet, cyan and luminous emerald", v(.12,.85,1), v(.08,.76,.94), v(.65,1,.92), {
		Color3.fromRGB(105,25,255), Color3.fromRGB(45,80,255), Color3.fromRGB(10,220,255),
		Color3.fromRGB(20,255,180), Color3.fromRGB(150,255,55),
	}),
}
for _, p in ipairs(palettes) do
	local keys = {}
	for i,c in ipairs(p.colors) do keys[i] = ColorSequenceKeypoint.new((i-1)/(#p.colors-1),c) end
	p.sequence = ColorSequence.new(keys)
	if p.id == "rainbow" or p.id == "vivid" or p.id == "sunset" or p.id == "aurora" then
		p.lut = table.create(256)
		for i=0,255 do
			local t = i/255*(#p.colors-1)
			local a = math.min(math.floor(t)+1,#p.colors-1)
			local c = p.colors[a]:Lerp(p.colors[a+1],t-(a-1))
			p.lut[i+1] = v(c.R,c.G,c.B)
		end
	end
end
palettes[3].reflectance = 0.42
palettes[3].specStrength = 0.65
palettes[3].skyWet = 0.22
palettes[3].skyDry = 0.16
for _, i in ipairs({3,4,6,7,8,9,10}) do palettes[i].sparkles = true end
return palettes
