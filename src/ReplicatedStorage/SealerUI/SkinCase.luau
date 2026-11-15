--!strict
--[[
	SkinCase -- every squeegee in the game on its own turntable, and the ONLY
	place one can be chosen.

	Before this the only way to change squeegee was to roll a new one: the slot
	machine equips on a win and nothing else ever equips at all, so owning six
	skins meant being stuck in whichever came out last. The slots panel is where
	skins are WON; this is where they are WORN, and they are deliberately not the
	same screen.

	It shows the LOCKED ones too, in full colour and turning. That is the whole
	pitch for another pull, and it is why this is a case of turntables rather than
	a list of names.

	A SEPARATE MODULE RATHER THAN ANOTHER Shell:_build. Shell is 5,600 lines, is
	edited live by another builder in this Team Create place, and its Source is
	already close enough to the 200,000-character write limit that appending a
	screen to it fails outright. Everything this needs from the shell it takes
	through the four calls below -- `gui`, `plr`, `close()` and `_register()` --
	so Shell's side of this feature is one require, one rail entry and one line.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(Pack:WaitForChild("UIKit"))
local Upgrades = require(Pack:WaitForChild("Upgrades"))   -- only for `short`
local SealPack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Skins = require(SealPack:WaitForChild("SqueegeeSkins"))
local ToolBuilder = require(SealPack:WaitForChild("ToolBuilder"))

local T = UIKit.Theme

-- One colour per rarity, matching the slot machine's. A Legendary that is gold
-- on the reel and purple in the case is two different prizes.
local function eventSkin(id: string): boolean
 return id=="Sweet" or id=="Spell"
end
local RARITY: { [string]: Color3 } = {
	Common = Color3.fromRGB(150, 162, 178),
	Uncommon = Color3.fromRGB(96, 200, 122),
	Rare = Color3.fromRGB(74, 156, 255),
	Epic = Color3.fromRGB(178, 108, 255),
	Legendary = Color3.fromRGB(255, 178, 40),
	-- the game's one gold, the same value ToolBuilder gilds in
	VIP = Color3.fromRGB(255, 206, 56),
}

local LOCKED_LINE = Color3.fromRGB(76, 96, 126)
local CARD_H, GAP = 250, 14

--[[
	How much room the subject is given beyond the tightest frame that holds it.

	This is THE zoom dial for the whole case, and it can be a small number because
	the fit under it is now SOLVED rather than guessed: 1.0 is the exact frame with
	the silhouette touching the edges. Every card reads off this one number, so
	they cannot drift apart.
]]
local FRAME_MARGIN = 1.08

local SkinCase = {}

function SkinCase.build(shell: any)
	local plr = shell.plr :: Player
	-- ownership and these remotes used to come from SealerUI.SkinRoll; that module
	-- went with the slot machine and all of it moved into the catalogue itself
	local Remotes = Skins.remotes()
	local EquipReq = Remotes:WaitForChild("SkinEquip") :: RemoteEvent
	local BuyReq = Remotes:WaitForChild("SkinBuy") :: RemoteEvent
	local RobuxReq = Remotes:WaitForChild("SkinBuyRobux") :: RemoteEvent
	-- the server only ever talks back to refuse: an unconfigured product
	RobuxReq.OnClientEvent:Connect(function(reason)
		if type(reason) == "string" then shell:Toast(reason, false) end
	end)

	--[[
		⚠ 0.70 TALL IS A CEILING, not a preference.

		The panel is centred, so half its height climbs toward the topbar band -- and
		BattleUI's NEXT EVENT badge is on a ScreenGui at DisplayOrder 50, over the
		shell's. At 0.78 the title bar rode up under the badge and the badge won: the
		panel was captioned by something drawn on top of it. Anything this screen
		needs comes out of the card, not out of the height.
	]]
	local size = UDim2.fromScale(0.54, 0.70)
	local holder, content, root = UIKit.panel(shell.gui, size, UDim2.fromScale(0.5, 0.5),
		"Squeegee Case", T.purple)
	UIKit.closeButton(root, function() shell:close() end)

	--==[ the header ]========================================================

	local tally = UIKit.outlined(content, "", 20, T.gold, 2.6)
	tally.Position = UDim2.fromOffset(0, 2)
	tally.Size = UDim2.new(1, 0, 0, 26)
	tally.TextXAlignment = Enum.TextXAlignment.Center
	tally.ZIndex = 9

	local barBack = Instance.new("Frame")
	barBack.Name = "Bar"
	barBack.AnchorPoint = Vector2.new(0.5, 0)
	barBack.Position = UDim2.new(0.5, 0, 0, 32)
	barBack.Size = UDim2.new(0.62, 0, 0, 12)
	barBack.BackgroundColor3 = Color3.fromRGB(22, 44, 82)
	barBack.BorderSizePixel = 0
	barBack.ZIndex = 9
	barBack.Parent = content
	UIKit.corner(barBack, 6)
	UIKit.stroke(barBack, 2)

	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = T.gold
	barFill.BorderSizePixel = 0
	barFill.ZIndex = 10
	barFill.Parent = barBack
	UIKit.corner(barFill, 6)
	UIKit.gradient(barFill, 1.2)

	--==[ the cards ]=========================================================

	local list = UIKit.scroller(content, 10)
	list.Position = UDim2.fromOffset(0, 54)
	list.Size = UDim2.new(1, 0, 1, -62)
	list.ZIndex = 9

	require(Pack:WaitForChild("TruckCosmetics")).mount(content,list,plr)
	local rigs: { { model: Model, phase: number } } = {}
	local cards: { [string]: any } = {}

	-- Read live rather than cached: the wallet moves while this screen is open --
	-- a job finishing behind it is the ordinary case -- and a price button that
	-- went affordable half a minute ago is a button that lies.
	local function cashNow(): number
		local ls = plr:FindFirstChild("leaderstats")
		local cash = ls and ls:FindFirstChild("Cash")
		return (cash and cash:IsA("IntValue")) and cash.Value or 0
	end
	-- every stand and the card it belongs to, for the cull below
	local stands: { { vp: ViewportFrame, card: GuiObject } } = {}

	--[[
		Two cards to a ROW FRAME rather than a UIGridLayout in the scroller.

		UIKit.scroller already carries a UIListLayout -- and with it the padding fix
		that stops a row's own stroke being sliced off down both sides -- so a grid
		layout would be a second layout fighting the first. A row that is one
		full-width child holding two cards keeps that fix and costs one frame.
	]]
	local rowFrames: { Frame } = {}
	for r = 1, math.ceil(#Skins.List / 2) do
		local row = Instance.new("Frame")
		row.Name = "Row" .. r
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, CARD_H)
		row.LayoutOrder = r
		row.ZIndex = 9
		row.Parent = list
		rowFrames[r] = row
	end

	local function makeCard(skin: any, index: number)
		local rcol = RARITY[skin.rarity] or RARITY.Common
		local row = rowFrames[math.ceil(index / 2)]
		local left = index % 2 == 1

		local container, body = UIKit.shadowed(row,
			UDim2.new(0.5, -GAP / 2, 1, -GAP),
			UDim2.new(if left then 0 else 0.5, if left then 0 else GAP / 2, 0, 0),
			Vector2.new(0, 0), 16, 7)
		container.Name = "Card_" .. skin.id
		body.BackgroundColor3 = T.navy
		body.ZIndex = 10
		UIKit.gradient(body, 0.9)

		--[[
			⚠ ONLY THE FIRST UIStroke ON AN INSTANCE APPLIES, so this card wears the
			rarity colour INSTEAD of the kit's black keyline rather than outside it.
			That is the intent -- the colour is the information, and it is what the eye
			sorts ten cards by -- but it means `UIKit.stroke(body, ...)` added here
			later would silently do nothing at all.
		]]
		local edge = Instance.new("UIStroke")
		edge.Color = rcol
		edge.Thickness = 3
		edge.LineJoinMode = Enum.LineJoinMode.Round
		edge.Parent = body

		--==[ the turntable ]=================================================

		local stage = Instance.new("Frame")
		stage.Name = "Stage"
		stage.BackgroundColor3 = Color3.fromRGB(12, 24, 48)
		stage.BorderSizePixel = 0
		stage.Position = UDim2.fromOffset(10, 10)
		stage.Size = UDim2.new(1, -20, 0, 150)
		stage.ZIndex = 11
		stage.Parent = body
		UIKit.corner(stage, 12)
		UIKit.stroke(stage, 2.2)
		UIKit.vignette(stage, 12, 0, 0.4)

		local viewport = Instance.new("ViewportFrame")
		viewport.Name = "Stand"
		viewport.BackgroundTransparency = 1
		viewport.Size = UDim2.fromScale(1, 1)
		viewport.ZIndex = 12
		viewport.Ambient = Color3.fromRGB(158, 166, 182)
		viewport.LightColor = Color3.fromRGB(255, 250, 240)
		viewport.LightDirection = Vector3.new(-0.45, -1, -0.55)
		viewport.Parent = stage
		table.insert(stands, { vp = viewport, card = container })

		-- a WorldModel, or the ViewportFrame ignores LightDirection and the whole
		-- rig renders flat
		local world = Instance.new("WorldModel")
		world.Parent = viewport

		local cam = Instance.new("Camera")
		cam.FieldOfView = 30
		cam.Parent = viewport
		viewport.CurrentCamera = cam

		--==[ the rig on it ]=================================================

		--[[
			BUILT here, not cloned off the player's own tool.

			SqueegeePose re-lengths the handle of a held squeegee every frame to reach
			the hands, so a clone of the equipped one carries whatever pose it was in.
			`buildSqueegee` gives the canonical rig every time, and `Skins.apply` is
			the same call the server dresses the real one with -- so what turns in this
			box is provably what turns up in your hands.
		]]
		local tool = ToolBuilder.buildSqueegee()
		local rig = tool:FindFirstChild("Rig")
		if rig and rig:IsA("Model") then
			rig:SetAttribute("ForViewport", true)
			Skins.apply(rig, skin.id)
			-- out of the tool BEFORE the tool is destroyed, or the rig goes with it
			rig.Parent = world
		end
		tool:Destroy()

		local rimPart: Part? = nil
		if rig and rig:IsA("Model") then
			for _, d in ipairs(rig:GetDescendants()) do
				if d:IsA("Light") or d:IsA("ParticleEmitter") or d:IsA("Sound") then
					d:Destroy()
				elseif d:IsA("BasePart") then
					d.Anchored = true
					d.CastShadow = false
				end
			end

			--[[
				⚠ PrimaryPart FIRST. While a model has one, its pivot IS that part's
				CFrame and writing WorldPivot is silently ignored -- and ToolBuilder sets
				the BLADE as PrimaryPart, which sits at the very bottom of the rig. Spun
				about that, the squeegee swings round the stand like a boom instead of
				turning on the spot.
			]]
			rig.PrimaryPart = nil
			local cf, sz = rig:GetBoundingBox()
			rig.WorldPivot = CFrame.new(cf.Position)
			rig:PivotTo(CFrame.new())

			local reach = math.max(sz.X, sz.Y, sz.Z)
			local drop = sz.Y * 0.5

			-- ⚠ a Roblox Cylinder runs along LOCAL X: a disc is
			-- (thickness, diameter, diameter) stood up with a quarter turn about Z.
			-- Written the intuitive way round it comes out a rod.
			local pad = Instance.new("Part")
			pad.Name = "Turntable"
			pad.Shape = Enum.PartType.Cylinder
			pad.Anchored = true
			pad.Material = Enum.Material.SmoothPlastic
			pad.Color = Color3.fromRGB(30, 36, 52)
			pad.Size = Vector3.new(0.35, reach * 0.86, reach * 0.86)
			pad.CFrame = CFrame.new(0, -drop - 0.2, 0) * CFrame.Angles(0, 0, math.rad(90))
			pad.Parent = world

			local rim = Instance.new("Part")
			rim.Name = "Rim"
			rim.Shape = Enum.PartType.Cylinder
			rim.Anchored = true
			rim.Material = Enum.Material.Neon
			rim.Color = rcol
			rim.Size = Vector3.new(0.22, reach * 0.94, reach * 0.94)
			rim.CFrame = CFrame.new(0, -drop - 0.3, 0) * CFrame.Angles(0, 0, math.rad(90))
			rim.Parent = world
			rimPart = rim

			-- What the camera actually has to hold, and it is NOT the rig's bounding
			-- box: the rig sweeps a CYLINDER as it turns, and the turntable is a second
			-- one under it. `spinR` is the radius that sweep reaches at its widest.
			local spinR = math.sqrt((sz.X * 0.5) ^ 2 + (sz.Z * 0.5) ^ 2)
			local discR = reach * 0.47
			local discY = -drop - 0.41

			--[[
				⚠ FieldOfView IS THE VERTICAL ANGLE, so a frame has to be solved against
				the viewport's ASPECT or a wide subject comes out half the size it should.

				These stages are about 2:1, and a squeegee is 6.4 studs of blade against
				2.9 of handle -- the widest thing in the game relative to its height.
				Distancing off the longest axis against the vertical FOV (which is what the
				dealership does, where a truck is roughly as tall as it is wide) put the
				camera 13.4 studs out when 6.5 was enough, and every squeegee sat marooned
				in the middle of its box with the horizontal room going spare.

				Solved from the LIVE AbsoluteSize rather than an assumed ratio: these cards
				are scale-sized, so their aspect is whatever the window makes it, and it is
				zero on the frame they are built. Hence the re-solve on the signal, and the
				guard against the cold size.

				The width term uses the BLADE, not the depth, because the rig turns and the
				frame has to hold it broadside; the aim point sits below centre, which is
				what lifts the rig up the picture -- whatever a camera looks at lands in the
				middle of it, and the disc projects as a deep ellipse hanging underneath.
			]]
			local dir = Vector3.new(0.52, 0.40, 0.75).Unit

			--[[
				SOLVE THE SILHOUETTE. Do not reason about it in world units.

				Every earlier attempt here framed the RIG and let the turntable fall
				wherever it fell, and the turntable is what kept getting cut off: the
				camera looks down about 24 degrees, so a disc six studs across does not
				project as a line under the blade -- it projects as an ELLIPSE two and a
				half studs deep, hanging well below anything the rig's own bounding box
				knows about. Guessing that overhang as a constant under-called it by 65%.

				So the subject is modelled as what it actually is -- two coaxial cylinders,
				the one the rig sweeps as it turns and the one the disc already is -- and
				its extremes are sampled round the three rims and PROJECTED onto the
				camera's own right and up axes. Both the distance and the aim point then
				fall out of the same measurement, so the picture is centred on the
				silhouette rather than on the geometry, and nothing can be off-frame
				without the numbers saying so.

				The camera DIRECTION is fixed, which is what makes this solvable in one
				pass: only the distance along it and the point it aims at are being found.
			]]
			local function frame()
				local vp = viewport.AbsoluteSize
				if vp.X < 4 or vp.Y < 4 then return end
				local tanV = math.tan(math.rad(cam.FieldOfView) * 0.5)
				local tanH = tanV * (vp.X / vp.Y)

				local fwd = -dir
				local right = fwd:Cross(Vector3.new(0, 1, 0)).Unit
				local up = right:Cross(fwd).Unit

				-- a cylinder's silhouette extremes all lie on its end rims, so three
				-- circles describe the whole subject
				local pts: { Vector3 } = {}
				for i = 0, 23 do
					local a = i / 24 * math.pi * 2
					local cx, cz = math.cos(a), math.sin(a)
					table.insert(pts, Vector3.new(cx * spinR, sz.Y * 0.5, cz * spinR))
					table.insert(pts, Vector3.new(cx * spinR, -sz.Y * 0.5, cz * spinR))
					table.insert(pts, Vector3.new(cx * discR, discY, cz * discR))
				end

				--[[
					⚠ THE FRUSTUM IS A CONE, NOT A BOX -- solve it in ANGLES.

					Projecting the silhouette onto the up/right axes and dividing by tan is
					an ORTHOGRAPHIC fit, and it quietly under-calls a subject with depth: it
					sizes every extreme as if it sat at the target's distance, while the near
					side of a six-stud cylinder is three studs closer, where the frustum is
					narrower. Measured against the real frustum that fit ran 12% over the
					edge -- which looks exactly like "nearly right", and is why this is worth
					measuring rather than eyeballing.

					The exact condition for one point is `d >= |lateral|/tan + depthAlong`,
					so the distance is the worst of those over the silhouette. That answer
					depends on where the camera aims and the aim depends on the answer, so it
					is iterated: solve the distance, re-centre on the ANGULAR extremes at
					that distance, repeat. It settles in two or three passes; eight is free
					because this runs on build and on resize, never per frame.
				]]
				local cu = 0
				local cr = 0
				local dist = 1
				for _ = 1, 8 do
					local target = up * cu + right * cr
					local need = 0
					for _, p in ipairs(pts) do
						local q = p - target
						local along = q:Dot(dir)
						need = math.max(need,
							math.abs(q:Dot(up)) / tanV + along,
							math.abs(q:Dot(right)) / tanH + along)
					end
					dist = need * FRAME_MARGIN

					local loU, hiU = math.huge, -math.huge
					local loR, hiR = math.huge, -math.huge
					for _, p in ipairs(pts) do
						local q = p - target
						local depth = dist - q:Dot(dir)
						if depth > 0.01 then
							local au, ar = q:Dot(up) / depth, q:Dot(right) / depth
							if au < loU then loU = au end
							if au > hiU then hiU = au end
							if ar < loR then loR = ar end
							if ar > hiR then hiR = ar end
						end
					end
					-- the angular imbalance, walked back into studs at this distance
					cu += (hiU + loU) * 0.5 * dist
					cr += (hiR + loR) * 0.5 * dist
				end

				local target = up * cu + right * cr
				cam.CFrame = CFrame.lookAt(target + dir * dist, target)
			end
			viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(frame)
			frame()

			-- staggered, so ten turntables are not one machine wearing ten faces
			table.insert(rigs, { model = rig, phase = index * 0.62 })
		end

		--==[ the label and the button ]======================================

		local nm = UIKit.outlined(body, skin.name:upper(), 19, T.cream, 2.4)
		nm.Position = UDim2.fromOffset(8, 166)
		nm.Size = UDim2.new(1, -16, 0, 26)
		nm.TextXAlignment = Enum.TextXAlignment.Center
		nm.ZIndex = 13

		local rar = UIKit.label(body, skin.rarity:upper(), 12, rcol)
		rar.Position = UDim2.fromOffset(8, 190)
		rar.Size = UDim2.new(1, -16, 0, 16)
		rar.TextXAlignment = Enum.TextXAlignment.Center
		rar.ZIndex = 13

		--[[
			TWO WAYS TO PAY, side by side, and the pair is the shop's own: GREEN is
			cash and GOLD is Robux, everywhere in this game.

			The cash button does double duty as the ownership control -- it is the one
			that says EQUIP and WEARING once the skin is yours, and it takes the whole
			width back when the Robux button retires. Two live-looking buttons where
			one of them is already the answer is a misread the shop's own tabs are
			coloured apart to avoid.

			Every branch is refused again on the server; this half exists so a card
			feels dead rather than broken, and so a player who cannot afford it is TOLD
			rather than left pressing a button that does nothing.
		]]
		local HALF = UDim2.new(0.5, -18, 0, 40)
		local FULL = UDim2.new(1, -24, 0, 40)

		local btnHolder, btnCap, recolour = UIKit.button(body, "EQUIP",
			HALF, T.green, function()
				local c = cards[skin.id]
				if c.owned then
					EquipReq:FireServer(skin.id)
				elseif eventSkin(skin.id) then
 shell:Toast("Unlock this skin during the HALLOWEEN EVENT",false)
 elseif c.price > 0 then
					if cashNow() >= c.price then
						BuyReq:FireServer(skin.id)
					else
						shell:Toast(("%s costs $%s"):format(skin.name,
							Upgrades.short(c.price)), false)
					end
				end
			end)
		btnHolder.Position = UDim2.fromOffset(12, 208)
		-- lifted over the stage (11-12), or the card's own viewport draws over its
		-- buy button
		for _, d in ipairs(btnHolder:GetDescendants()) do
			if d:IsA("GuiObject") then d.ZIndex = d.ZIndex + 6 end
		end
		btnHolder.ZIndex = 16
		btnCap.TextSize = 17

		local robuxHolder, robuxCap = UIKit.button(body,
			("R$ %d"):format(Skins.robuxPriceOf(skin.id)),
			HALF, T.gold, function()
				if cards[skin.id].owned or eventSkin(skin.id) then return end
				RobuxReq:FireServer(skin.id)
			end)
		robuxHolder.AnchorPoint = Vector2.new(1, 0)
		robuxHolder.Position = UDim2.new(1, -12, 0, 208)
		for _, d in ipairs(robuxHolder:GetDescendants()) do
			if d:IsA("GuiObject") then d.ZIndex = d.ZIndex + 6 end
		end
		robuxHolder.ZIndex = 16
		robuxCap.TextSize = 17

		cards[skin.id] = {
			edge = edge, name = nm, cap = btnCap, recolour = recolour,
			rim = rimPart, rcol = rcol, owned = false,
			price = Skins.priceOf(skin.id),
			cashBtn = btnHolder, robuxBtn = robuxHolder, robuxCap = robuxCap,
			half = HALF, full = FULL,
			pass = Skins.passOf(skin.id),
		}
	end

	for i, skin in ipairs(Skins.List) do makeCard(skin, i) end

	--[[
		ONLY THE STANDS YOU CAN SEE ARE ALLOWED TO RENDER.

		A ViewportFrame is its own render pass whether or not it happens to be
		scrolled out of the window -- ClipsDescendants hides it, it does not stop it
		drawing. Ten of them was affordable on that basis alone; twenty is not, and
		the roster doubled on 2026-08-14.

		So a stand is switched off unless its card overlaps the scroller's window,
		with a card's height of slack either side so one never pops in at the edge.
		That holds the live count at about six however long the roster gets.

		The rigs keep TURNING while hidden -- twenty CFrame writes a frame is
		nothing, and a stand that froze would jump when it scrolled back in.
	]]
	local function cull()
		local top = list.AbsolutePosition.Y
		local bottom = top + list.AbsoluteSize.Y
		for _, e in ipairs(stands) do
			local y = e.card.AbsolutePosition.Y
			local h = e.card.AbsoluteSize.Y
			e.vp.Visible = (y + h > top - h) and (y < bottom + h)
		end
	end
	list:GetPropertyChangedSignal("CanvasPosition"):Connect(cull)
	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(cull)
	-- and on the way in, because the panel is built long before it is first opened
	holder:GetPropertyChangedSignal("Visible"):Connect(function()
		if holder.Visible then cull() end
	end)
	cull()

	--==[ what is owned, and what is on ]======================================

	--[[
		Read straight off the player's own ATTRIBUTES rather than plumbed through the
		slot machine's payload.

		Both of them replicate on their own, so this screen is right the moment it is
		built and right again the instant the server writes either -- with no remote
		of its own, and no ordering to get wrong between the two.
	]]
	local function refresh()
		local worn = plr:GetAttribute(Skins.Attr) or Skins.Default
		local cash = cashNow()
		local held = 0
		for _, skin in ipairs(Skins.List) do
			local c = cards[skin.id]
			if c then
				--[[
					⚠ `owns`, NOT the owned SET.

					`ownedSet` is the `SkinsOwned` string and nothing else, and a pass kit
					is deliberately never written into it -- so asking the set direct left a
					VIP looking at a LOCKED VIP card. There was no EQUIP button on it at
					all (see `robuxOnly` below, which hides the cash button outright for a
					pass kit): the only control was the Robux one, offering to sell them the
					pass they were already holding.

					`owns` is the function that branches on `pass`, and it is what the
					server's own equip handler checks against -- so reading anything else
					here is this screen disagreeing with the only side that decides.
				]]
				local have = Skins.owns(plr, skin.id)
				c.owned = have
				if have then held += 1 end

				--[[
					Whichever buttons are live take the whole width between them.

					Owned: the cash button is the EQUIP control and the Robux one retires.
					A PASS KIT: there is no cash price at all, so the Robux button is the
					whole card. Otherwise: both, side by side. Never a live button beside a
					hole, and never two where one is already the answer.
				]]
				local robuxOnly = c.pass ~= nil and not have
				c.robuxBtn.Visible = not have and not eventSkin(skin.id)
				c.cashBtn.Visible = not robuxOnly
				c.cashBtn.Size = if have or eventSkin(skin.id) then c.full else c.half
				c.robuxBtn.Size = if robuxOnly then c.full else c.half
				-- priced from Roblox at startup, so it can arrive after the card is built
				c.robuxCap.Text = ("R$ %d"):format(Skins.robuxPriceOf(skin.id))

				--[[
					⚠ WORN **AND** OWNED, in that order, because those two can now come
					apart. The choice persists in the profile and a PASS KIT's ownership
					does not -- so a refunded VIP still reads `Skin_Squeegee = VipKit`, and
					the bare `worn ==` test drew them a green WEARING card for a skin the
					server had already stopped putting on their squeegee. Falling through to
					the locked branch is what agrees with `SqueegeeSkinService.wanted`.
				]]
				if worn == skin.id and have then
					c.cap.Text = "WEARING"
					c.recolour(T.green)
					c.edge.Color = T.green
					c.edge.Thickness = 4
					c.name.TextColor3 = T.cream
				elseif have then
					c.cap.Text = "EQUIP"
					-- (a pass kit lands here too: owning the pass owns the kit)
					c.recolour(T.blue)
					c.edge.Color = c.rcol
					c.edge.Thickness = 3
					c.name.TextColor3 = T.cream
				else
					--[[
						A locked card wears its PRICE, not the word LOCKED.

						"Locked" tells a player they cannot have it; a price tells them what
						it would take, which is the only version of that sentence worth
						printing on a shop. Gold when it is within reach and slate when it is
						not, so the next thing you can actually afford is findable by colour
						alone down a list of twenty.
					]]
					-- A pass kit has no cash price, and `cash >= 0` is true for everybody --
					-- so without this a locked VIP card wore the full-colour treatment of
					-- one you could afford. It is never bought with cash.
					local afford = not eventSkin(skin.id) and c.pass == nil and cash >= c.price
					c.cap.Text = if eventSkin(skin.id) then "EVENT" else "$" .. Upgrades.short(c.price)
					-- green when you can pay it, slate when you cannot. The GOLD in this
					-- pair belongs to Robux and is never borrowed for cash.
					c.recolour(if afford then T.green else T.slate)
					c.edge.Color = if afford then c.rcol else LOCKED_LINE
					c.edge.Thickness = if afford then 2.6 else 2
					c.name.TextColor3 = if afford then T.cream
						else Color3.fromRGB(132, 150, 176)
				end
				-- the neon rim is the one part of a locked card that goes cold, so an
				-- owned skin reads at a glance from the colour under it
				if c.rim then
					c.rim.Color = if have then c.rcol else Color3.fromRGB(46, 58, 80)
				end
			end
		end
		tally.Text = ("COLLECTED  %d / %d"):format(held, #Skins.List)
		barFill.Size = UDim2.fromScale(held / math.max(1, #Skins.List), 1)
	end

	plr:GetAttributeChangedSignal(Skins.OwnedAttr):Connect(refresh)
	plr:GetAttributeChangedSignal(Skins.Attr):Connect(refresh)
 plr:GetAttributeChangedSignal("HalloweenOwned_Sweet"):Connect(refresh)
 plr:GetAttributeChangedSignal("HalloweenOwned_Spell"):Connect(refresh)
 plr:GetAttributeChangedSignal("HalloweenShopState"):Connect(refresh)
	--[[
		And on every pass a kit is gated behind.

		A pass kit is owned by holding the pass, and PassService mirrors that onto
		`Pass_<id>` -- so buying VIP has to light its card without anything here
		asking Roblox again. Hooked per distinct pass rather than per skin, since
		one pass could gate several kits later.
	]]
	do
		local Passes = require(Pack:WaitForChild("Passes"))
		local hooked: { [string]: boolean } = {}
		for _, sk in ipairs(Skins.List) do
			local p = sk.pass
			if p and not hooked[p] then
				hooked[p] = true
				plr:GetAttributeChangedSignal(Passes.attrName(p)):Connect(refresh)
			end
		end

		--[[
			⚠ THE PASS PRICE IS ASKED FOR HERE, ON THE CLIENT.

			It was fetched on the server first, which does not work: `setPassPrice`
			writes into a module table and a module table DOES NOT REPLICATE, so this
			side still read zero and the VIP card advertised "R$ 0". The server does
			not need the number at all -- it prompts by asset id and Roblox charges
			whatever the pass costs -- so the only copy that matters is this one.

			Asked rather than typed, so a price changed on the Dashboard cannot leave
			the card advertising the old one. Spawned, because GetProductInfo yields
			and a panel must not wait on the network to finish building; `refresh`
			redraws the caption when the answer lands.
		]]
		task.spawn(function()
			for p in pairs(hooked) do
				local pass = Passes.ById[p]
				local asset = pass and pass.assetId or 0
				if asset ~= 0 then
					local ok, info = pcall(function()
						return MarketplaceService:GetProductInfo(asset,
							Enum.InfoType.GamePass)
					end)
					if ok and type(info) == "table" and info.PriceInRobux then
						Skins.setPassPrice(p, info.PriceInRobux)
					else
						warn(("[SkinCase] could not price the %s pass: %s")
							:format(p, tostring(info)))
					end
				end
			end
			refresh()
		end)
	end
	--[[
		And on the WALLET, because affordability is half of what a card now shows.

		leaderstats.Cash may not exist yet when this panel is built -- it is created
		per player on the server and replicates in -- so the hook is armed when it
		arrives rather than assumed.
	]]
	local function watchCash()
		local ls = plr:FindFirstChild("leaderstats")
		local cash = ls and ls:FindFirstChild("Cash")
		if cash and cash:IsA("IntValue") then
			cash:GetPropertyChangedSignal("Value"):Connect(refresh)
			refresh()
			return true
		end
		return false
	end
	if not watchCash() then
		task.spawn(function()
			local ls = plr:WaitForChild("leaderstats", 30)
			if ls then
				ls:WaitForChild("Cash", 30)
				watchCash()
			end
		end)
	end
	refresh()

	--[[
		One RenderStepped for every turntable in the case, and it returns immediately
		while the panel is shut.

		A ViewportFrame whose ancestor is hidden does not render, so this screen costs
		one early return per frame when nobody is looking at it -- which is what makes
		ten stands affordable where the dealership could only afford one. (Its trucks
		are ~425 parts each; a squeegee is five.)
	]]
	local turn = 0
	RunService.RenderStepped:Connect(function(dt: number)
		if not holder.Visible then return end
		turn += dt * 0.7
		for _, r in ipairs(rigs) do
			r.model:PivotTo(CFrame.Angles(0, turn + r.phase, 0))
		end
	end)

	shell:_register("Skins", holder, size)
end

return SkinCase
