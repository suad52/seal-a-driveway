--!strict
--[[
	UIKit -- the cartoon widget set the whole interface is drawn with.

	Every control here is the same four ideas, which is what makes a set of
	separately-built panels look like one product:

	  * a thin black keyline on everything, round-joined
	  * a two-hue vertical ramp -- fill into a warmer fill, never into black
	  * a hard drop shadow offset straight down
	  * a pale shine strip across the top

	Buttons additionally sit on a darker plinth and physically drop into it when
	pressed. That press is the only motion in the kit that is not decorative --
	it is the click feedback.
]]

local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
-- only to keep UIKit.onFit from hooking a camera that cannot exist; see there
local RunService = game:GetService("RunService")

local Console = require(game:GetService("ReplicatedStorage"):WaitForChild("SealerUI"):WaitForChild("ConsoleControls"))

local UIKit = {}

local T = {
	navy      = Color3.fromRGB(28, 64, 126),
	blue      = Color3.fromRGB(58, 166, 255),
	blueDark  = Color3.fromRGB(38, 124, 216),
	blueLight = Color3.fromRGB(130, 214, 255),
	panel     = Color3.fromRGB(72, 180, 255),
	panelDeep = Color3.fromRGB(46, 138, 226),
	cream     = Color3.fromRGB(255, 250, 226),
	white     = Color3.fromRGB(255, 255, 255),
	green     = Color3.fromRGB(80, 224, 112),
	greenDark = Color3.fromRGB(46, 176, 84),
	red       = Color3.fromRGB(255, 84, 96),
	redDark   = Color3.fromRGB(206, 46, 62),
	gold      = Color3.fromRGB(255, 206, 56),
	goldDark  = Color3.fromRGB(242, 152, 26),
	purple    = Color3.fromRGB(178, 108, 255),
	teal      = Color3.fromRGB(52, 226, 214),
	slate     = Color3.fromRGB(104, 126, 156),
	ink       = Color3.fromRGB(14, 16, 28),
	shadow    = Color3.fromRGB(8, 10, 20),
}
UIKit.Theme = T
UIKit.Font    = Enum.Font.FredokaOne
UIKit.Display = Enum.Font.LuckiestGuy

--==[ the window ]============================================================

local DESIGN_W, DESIGN_H = 1280, 720
local FIT_FLOOR = 0.45

local fitNow = 1
local viewNow = Vector2.new(DESIGN_W, DESIGN_H)
local fitHooks: { (number, Vector2) -> () } = {}
local watching = false

local function refit()
	local cam = workspace.CurrentCamera
	local v = if cam then cam.ViewportSize else viewNow

	if v.X < 200 or v.Y < 200 then return end
	viewNow = v
	fitNow = math.clamp(math.min(v.X / DESIGN_W, v.Y / DESIGN_H), FIT_FLOOR, 1)
	for _, fn in ipairs(fitHooks) do fn(fitNow, viewNow) end
end

local function watchWindow()
	if watching then return end
	watching = true
	local conn: RBXScriptConnection? = nil
	local function hook()
		if conn then conn:Disconnect() end
		local cam = workspace.CurrentCamera
		conn = if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(refit) else nil
		refit()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hook)
	hook()
end

-- Told the current answer on the way in, so a block is built and fitted in one
-- place and never needs a first pass of its own.
function UIKit.onFit(fn: (number, Vector2) -> ())
	-- There is no window on the server. Nothing there requires this file today,
	-- but a module that quietly hooks a camera is a nasty thing to inherit.
	if not RunService:IsClient() then return end
	watchWindow()
	table.insert(fitHooks, fn)
	fn(fitNow, viewNow)
end

--==[ primitives ]============================================================

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
	return c
end
UIKit.corner = corner

local function stroke(inst: Instance, thickness: number?, color: Color3?, contextual: boolean?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2.5
	s.Color = color or T.ink
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.ApplyStrokeMode = contextual and Enum.ApplyStrokeMode.Contextual or Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end
UIKit.stroke = stroke

local WARM = 0.125 -- yellow: the direction a highlight leans and a shadow leans off

local function shift(h: number, amount: number): number
	-- Signed shortest path from this hue to yellow, so a positive `amount` always
	-- means "toward the light" wherever on the wheel the fill happens to sit. A
	-- fill that is ALREADY yellow has no toward, so it highlights into lemon and
	-- shades into orange, which is the ramp gold wants anyway.
	local d = ((WARM - h + 1.5) % 1) - 0.5
	local dir = (math.abs(d) < 0.06 or d >= 0) and 1 or -1
	return (h + dir * amount) % 1
end

function UIKit.ramp(c: Color3, strength: number?): (Color3, Color3)
	local k = strength or 1
	local h, s, v = Color3.toHSV(c)
	local top = Color3.fromHSV(shift(h, 0.032 * k),
		math.clamp(s * (1 - 0.16 * k), 0, 1), math.clamp(v * (1 + 0.19 * k), 0, 1))
	local bot = Color3.fromHSV(shift(h, -0.030 * k),
		math.clamp(s * (1 + 0.14 * k), 0, 1), math.clamp(v * (1 - 0.22 * k), 0, 1))
	return top, bot
end

-- A deeper, hue-shifted version of a fill: the plinth under a button, which has
-- to read as the same piece of plastic in shadow rather than as a black slab.
function UIKit.deepen(c: Color3, amount: number): Color3
	local h, s, v = Color3.toHSV(c)
	return Color3.fromHSV(shift(h, -0.042),
		math.clamp(s * 1.16, 0, 1), math.clamp(v * (1 - amount), 0, 1))
end

local function gradient(inst: GuiObject, strength: number?)
	local top, bot = UIKit.ramp(inst.BackgroundColor3, strength)
	local base = Color3.new(math.max(top.R, bot.R), math.max(top.G, bot.G), math.max(top.B, bot.B))
	inst.BackgroundColor3 = base
	local function ratio(a: number, b: number): number
		return b > 0.004 and math.clamp(a / b, 0, 1) or 0
	end
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(ratio(top.R, base.R), ratio(top.G, base.G), ratio(top.B, base.B))),
		ColorSequenceKeypoint.new(1, Color3.new(ratio(bot.R, base.R), ratio(bot.G, base.G), ratio(bot.B, base.B))),
	})
	g.Parent = inst
	return g
end
UIKit.gradient = gradient

function UIKit.retint(inst: GuiObject, col: Color3, strength: number?): Color3
	local old = inst:FindFirstChildOfClass("UIGradient")
	if old then old:Destroy() end
	inst.BackgroundColor3 = col
	gradient(inst, strength)
	return inst.BackgroundColor3
end

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255,  92,  92)),
	ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 172,  52)),
	ColorSequenceKeypoint.new(0.34, Color3.fromRGB(252, 232,  74)),
	ColorSequenceKeypoint.new(0.50, Color3.fromRGB(104, 232, 124)),
	ColorSequenceKeypoint.new(0.66, Color3.fromRGB( 76, 198, 255)),
	ColorSequenceKeypoint.new(0.83, Color3.fromRGB(158, 124, 255)),
	ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 118, 208)),
})

function UIKit.rainbow(inst: Instance, period: number?): UIGradient
	local old = inst:FindFirstChildOfClass("UIGradient")
	if old then old:Destroy() end
	if inst:IsA("GuiObject") then
		inst.BackgroundColor3 = Color3.new(1, 1, 1)
	elseif inst:IsA("UIStroke") then
		inst.Color = Color3.new(1, 1, 1)
	end
	local g = Instance.new("UIGradient")
	g.Color = RAINBOW
	g.Parent = inst
	TweenService:Create(g, TweenInfo.new(period or 6, Enum.EasingStyle.Linear,
		Enum.EasingDirection.InOut, -1), { Rotation = 360 }):Play()
	return g
end

function UIKit.dropShadow(holder: GuiObject, radius: number, drop: number, z: number?)
	local sh = Instance.new("Frame")
	sh.Name = "DropShadow"
	sh.BackgroundColor3 = T.shadow
	sh.BackgroundTransparency = 0.46
	sh.BorderSizePixel = 0
	sh.AnchorPoint = Vector2.new(0.5, 0.5)
	sh.Position = UDim2.new(0.5, 0, 0.5, drop)
	sh.Size = UDim2.new(1, 4, 1, 4)
	sh.ZIndex = z or 1
	corner(sh, radius + 2)
	sh.Parent = holder
	return sh
end

function UIKit.shadowed(parent: Instance, size: UDim2, position: UDim2, anchor: Vector2,
		radius: number, drop: number)
	local container = Instance.new("Frame")
	container.Name = "Shadowed"
	container.BackgroundTransparency = 1
	container.Size = size
	container.Position = position
	container.AnchorPoint = anchor
	container.Parent = parent

	local sh = Instance.new("Frame")
	sh.Name = "Shadow"
	sh.BackgroundColor3 = T.shadow
	sh.BackgroundTransparency = 0.46
	sh.BorderSizePixel = 0
	sh.Position = UDim2.fromOffset(-2, drop)
	sh.Size = UDim2.new(1, 4, 1, 4)
	sh.ZIndex = 2
	corner(sh, radius)
	sh.Parent = container

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundColor3 = T.panel
	body.BorderSizePixel = 0
	body.Size = UDim2.fromScale(1, 1)
	body.ZIndex = 3
	body.Parent = container
	corner(body, radius)

	return container, body
end

function UIKit.vignette(parent: GuiObject, radius: number, rotation: number?, strength: number?)
	local v = Instance.new("Frame")
	v.Name = "Vignette"
	v.BackgroundColor3 = T.ink
	v.BorderSizePixel = 0
	v.Size = UDim2.fromScale(1, 1)
	v.ZIndex = parent.ZIndex
	corner(v, radius)
	local g = Instance.new("UIGradient")
	g.Rotation = rotation or 90
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 1 - (strength or 0.3)),
	})
	g.Parent = v
	v.Parent = parent
	return v
end

function UIKit.stripes(parent: GuiObject, radius: number, rotation: number?, strength: number?)
	local s = Instance.new("Frame")
	s.Name = "Stripes"
	s.BackgroundColor3 = Color3.new(1, 1, 1)
	s.BorderSizePixel = 0
	s.Size = UDim2.fromScale(1, 1)
	s.ZIndex = parent.ZIndex
	corner(s, radius)

	local keys = {}
	local bands, dip = 12, strength or 0.055
	for i = 0, bands do
		keys[i + 1] = NumberSequenceKeypoint.new(i / bands,
			if i % 2 == 0 then 1 else 1 - dip)
	end
	local g = Instance.new("UIGradient")
	g.Rotation = rotation or 34
	g.Transparency = NumberSequence.new(keys)
	g.Parent = s
	s.Parent = parent
	return s
end

-- Four moulded studs, one per corner. The cheapest single detail that stops a
-- rounded rectangle reading as a rounded rectangle.
function UIKit.rivets(parent: GuiObject, inset: number, d: number, colour: Color3?, z: number?)
	for _, c in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
		local r = Instance.new("Frame")
		r.Name = "Rivet"
		r.AnchorPoint = Vector2.new(c[1], c[2])
		r.Position = UDim2.new(c[1], c[1] == 0 and inset or -inset,
			c[2], c[2] == 0 and inset or -inset)
		r.Size = UDim2.fromOffset(d, d)
		r.BackgroundColor3 = colour or T.blueLight
		r.BorderSizePixel = 0
		r.ZIndex = z or (parent.ZIndex + 1)
		r.Parent = parent
		corner(r, math.floor(d / 2))
		stroke(r, 2)
		gradient(r, 1.25)
	end
end

-- the pale sheen across the top of a moulded surface
local function gloss(parent: GuiObject, inset: number, radius: number, height: number)
	local g = Instance.new("Frame")
	g.Name = "Gloss"
	g.BackgroundColor3 = Color3.new(1, 1, 1)
	g.BackgroundTransparency = 0.78
	g.BorderSizePixel = 0
	g.Position = UDim2.new(0, inset, 0, inset)
	g.Size = UDim2.new(1, -inset * 2, height, -inset * 2)
	g.ZIndex = parent.ZIndex + 1
	corner(g, radius)
	g.Parent = parent
	return g
end
UIKit.gloss = gloss

function UIKit.label(parent: Instance, text: string, size: number, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = UIKit.Font
	l.Text = text
	l.TextSize = size
	l.TextWrapped = true
	l.ClipsDescendants = true
	l.TextColor3 = color or T.white
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.RichText = true
	l.Parent = parent
	-- contextual, or the stroke draws a box round the label's invisible rectangle
	-- instead of an edge on the letters
	stroke(l, math.max(1.4, size * 0.085), T.ink, true)
	return l
end

--==[ panel backdrop ]========================================================

local MOTES = 7

function UIKit.backdrop(container: GuiObject, well: GuiObject, tint: Color3, radius: number)

	gradient(well, 0.85)

	-- Woven rather than striped: two bands at opposing angles read as texture,
	-- where one reads as a barcode. Both are UIGradients, so they cost no parts.
	UIKit.stripes(well, radius, 34, 0.07)
	UIKit.stripes(well, radius, -68, 0.045)
	UIKit.vignette(well, radius, 90, 0.34)

	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0)
	glow.BackgroundColor3 = Color3.new(1, 1, 1):Lerp(tint, 0.35)
	glow.BackgroundTransparency = 0.86
	glow.BorderSizePixel = 0
	glow.Position = UDim2.new(0.5, 0, 0, 6)
	glow.Size = UDim2.new(1, -28, 0.58, 0)
	glow.ZIndex = 5
	glow.Parent = well
	corner(glow, 140)
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(0.55, 0.72),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = glow

	local drifts: { Tween } = {}
	for i = 1, MOTES do
		local d = 7 + (i % 3) * 5
		local mote = Instance.new("Frame")
		mote.Name = "Mote"
		mote.AnchorPoint = Vector2.new(0.5, 0.5)
		mote.BackgroundColor3 = Color3.new(1, 1, 1):Lerp(tint, 0.5)
		mote.BackgroundTransparency = 0.72
		mote.BorderSizePixel = 0
		mote.Size = UDim2.fromOffset(d, d)
		mote.ZIndex = 5
		mote.Parent = well
		corner(mote, math.floor(d / 2))

		-- spread across the width, and staggered up the height so they are not a row
		local x = 0.08 + (i - 1) * (0.84 / (MOTES - 1))
		local from = 0.94 - (i % 4) * 0.2
		mote.Position = UDim2.fromScale(x, from)

		local rise = TweenService:Create(mote,
			TweenInfo.new(9 + i * 1.7, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
			{ Position = UDim2.fromScale(x + 0.03, 0.03) })
		local breathe = TweenService:Create(mote,
			TweenInfo.new(2.4 + i * 0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.94 })
		drifts[#drifts + 1] = rise
		drifts[#drifts + 1] = breathe
	end

	for _, side in ipairs({ 0, 1 }) do
		local glint = Instance.new("Frame")
		glint.Name = "Glint"
		glint.AnchorPoint = Vector2.new(side, 1)
		glint.BackgroundColor3 = tint
		-- Faint and very round. At 0.88 with a 110 radius the bloom had a readable
		-- rounded-rectangle edge on its inner side, which makes it a shape sitting on
		-- the panel rather than light pooling in the corner.
		glint.BackgroundTransparency = 0.93
		glint.BorderSizePixel = 0
		glint.Position = UDim2.new(side, side == 0 and 2 or -2, 1, -2)
		glint.Size = UDim2.fromOffset(230, 150)
		glint.ZIndex = 5
		glint.Parent = well
		corner(glint, 999)
		local g = Instance.new("UIGradient")
		-- fading UP and INWARD, so the bloom hugs the corner it belongs to
		g.Rotation = side == 0 and -35 or 215
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0.15),
		})
		g.Parent = glint
	end

	local rim = Instance.new("Frame")
	rim.Name = "Rim"
	rim.BackgroundTransparency = 1
	rim.Position = UDim2.fromOffset(3, 3)
	rim.Size = UDim2.new(1, -6, 1, -6)
	rim.ZIndex = 5
	rim.Parent = well
	corner(rim, math.max(2, radius - 3))
	local rimLine = stroke(rim, 2.4, Color3.new(1, 1, 1):Lerp(tint, 0.55))
	rimLine.Transparency = 0.74
	drifts[#drifts + 1] = TweenService:Create(rimLine,
		TweenInfo.new(2.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.26 })

	-- the light sweeping across the face, the slowest thing on the panel
	UIKit.sheen(well, 7.5, 5)

	local function wake()
		for _, t in ipairs(drifts) do
			if container.Visible then t:Play() else t:Pause() end
		end
	end
	container:GetPropertyChangedSignal("Visible"):Connect(wake)
	wake()
end

--==[ panel ]=================================================================

function UIKit.panel(parent: Instance, size: UDim2, position: UDim2, title: string?, accent: Color3?)
	-- Dropped further than it was (9), because the accent ring below now covers
	-- the first 7px of it on every side -- a shadow you cannot see is a panel
	-- lying flat on the screen.
	local container, root = UIKit.shadowed(parent, size, position, Vector2.new(0.5, 0.5), 22, 16)
	container.Name = "PanelHolder"
	root.Name = "Panel"
	root.BackgroundColor3 = T.panel
	stroke(root, 3)
	gradient(root, 0.9)
	-- the frame catches the light, the well below sits in shadow
	gloss(root, 8, 16, 0.30)

	local tint = accent or T.blue

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.new(1, 14, 1, 14)
	ring.BackgroundColor3 = tint
	ring.BorderSizePixel = 0
	ring.ZIndex = 2
	ring.Parent = container
	corner(ring, 29)
	stroke(ring, 3)
	gradient(ring, 1.2)

	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.BackgroundColor3 = T.panelDeep:Lerp(tint, 0.16)
	inner.BorderSizePixel = 0
	inner.Position = UDim2.fromOffset(10, 10)
	inner.Size = UDim2.new(1, -20, 1, -20)
	inner.ZIndex = 5
	inner.Parent = root
	corner(inner, 16)
	stroke(inner, 2, T.blueDark)
	-- everything that makes the well look lit rather than printed; see backdrop
	UIKit.backdrop(container, inner, tint, 16)

	-- a hairline of the accent along the top of the well, under the title bar
	local band = Instance.new("Frame")
	band.Name = "AccentBand"
	band.BackgroundColor3 = tint
	band.BorderSizePixel = 0
	band.Position = UDim2.fromOffset(14, 4)
	band.Size = UDim2.new(1, -28, 0, 4)
	band.ZIndex = 5
	band.Parent = inner
	corner(band, 2)

	-- studs on the well rather than the frame: the frame's top right corner is
	-- where closeButton parks itself
	UIKit.rivets(inner, 13, 11, T.blueLight, 6)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(0, title and 26 or 8)
	content.Size = UDim2.new(1, 0, 1, title and -34 or -16)
	content.ZIndex = 6
	content.Parent = inner

	if title then
		local bar = Instance.new("Frame")
		bar.Name = "TitleBar"
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.new(0.5, 0, 0, 2)
		bar.Size = UDim2.new(0, 0, 0, 46)
		bar.AutomaticSize = Enum.AutomaticSize.X
		bar.BackgroundColor3 = accent or T.blue
		bar.BorderSizePixel = 0
		bar.ZIndex = 8
		bar.Parent = root
		corner(bar, 14)
		stroke(bar, 3.2)
		gradient(bar, 1.3)
		-- moulded like a button cap rather than printed like a caption
		gloss(bar, 6, 10, 0.44)
		-- the title catches the light too, a beat out of step with the well's own
		-- sweep so the two never travel together
		UIKit.sheen(bar, 5.5, 8)

		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 26)
		pad.PaddingRight = UDim.new(0, 26)
		pad.Parent = bar

		local t = UIKit.label(bar, title:upper(), 26, T.cream)
		t.Font = UIKit.Display
		t.AutomaticSize = Enum.AutomaticSize.X
		t.Size = UDim2.new(0, 0, 1, 0)
		t.TextXAlignment = Enum.TextXAlignment.Center
		t.ZIndex = 9
	end

	-- the container is what callers show, hide and tween
	Console.watchPanel(container)
	return container, content, root
end

--==[ buttons ]===============================================================

local LIFT = 5

function UIKit.button(parent: Instance, text: string, size: UDim2, base: Color3?, onClick: (() -> ())?)
	local col = base or T.green

	local holder = Instance.new("Frame")
	holder.Name = "Button"
	holder.BackgroundTransparency = 1
	holder.Size = size
	holder.ZIndex = 10
	holder.Parent = parent

	-- under the plinth rather than under the cap: the shadow belongs to the whole
	-- control, so it stays put while the cap drops into the plinth
	UIKit.dropShadow(holder, 13, 6, 9)

	local plinth = Instance.new("Frame")
	plinth.Name = "Plinth"
	plinth.BackgroundColor3 = UIKit.deepen(col, 0.30)
	plinth.BorderSizePixel = 0
	plinth.Position = UDim2.fromOffset(0, LIFT)
	plinth.Size = UDim2.new(1, 0, 1, -LIFT)
	plinth.ZIndex = 10
	plinth.Parent = holder
	corner(plinth, 13)
	stroke(plinth, 2.4)

	local cap = Instance.new("TextButton")
	cap.Name = "Cap"
	cap.AutoButtonColor = false
	cap.BackgroundColor3 = col
	cap.BorderSizePixel = 0
	cap.Size = UDim2.new(1, 0, 1, -LIFT)
	cap.Position = UDim2.fromOffset(0, 0)
	cap.Font = UIKit.Display
	cap.Text = text
	cap.TextSize = 22
	cap.TextColor3 = T.white
	cap.ZIndex = 11
	cap.Parent = holder
	corner(cap, 13)
	stroke(cap, 2.4)
	gradient(cap)
	-- The same shine the hotbar keys wear. It used to have to ride OVER the
	-- caption, because a TextButton draws its own text and there was no instance to
	-- sit under; the caption is its own label now, so this is back to being a
	-- highlight on the moulding with the words on top of it.
	local sheen = gloss(cap, 7, 10, 0.40)
	sheen.BackgroundTransparency = 0.85
	-- The light streak that crosses a shop card in every mobile game ever made,
	-- now on every button in this one. Given the GLOSS's ZIndex rather than one of
	-- its own so it stays under the caption -- the face label sits at sheen.ZIndex
	-- + 1, and a streak over the type washes out its top third.
	UIKit.sheen(cap, 4.4, sheen.ZIndex)

	cap.TextTransparency = 1

	local face = Instance.new("TextLabel")
	face.Name = "Face"
	face.BackgroundTransparency = 1
	face.Size = UDim2.fromScale(1, 1)
	-- above the sheen, which is itself cap.ZIndex + 1
	face.ZIndex = sheen.ZIndex + 1
	face.Parent = cap
	-- Contextual so the edge lands on the glyphs, and thin -- the same 9% of text
	-- size the chip captions use, enough to separate the type from the fill
	-- without reading as a second keyline.
	stroke(face, 2.0, T.ink, true)

	local function mirror()
		face.Text = cap.Text
		face.Font = cap.Font
		face.TextSize = cap.TextSize
		face.TextColor3 = cap.TextColor3
		face.TextXAlignment = cap.TextXAlignment
		face.TextYAlignment = cap.TextYAlignment
	end
	mirror()
	for _, prop in ipairs({ "Text", "Font", "TextSize", "TextColor3",
		"TextXAlignment", "TextYAlignment" }) do
		cap:GetPropertyChangedSignal(prop):Connect(mirror)
	end
	-- read the colour back AFTER the ramp has lifted it, or the hover tween
	-- would keep resetting the cap to the unlifted shade and it would flicker
	local restCol = cap.BackgroundColor3


	local down, over = false, false
	local function seat()
		TweenService:Create(cap, TweenInfo.new(0.07), {
			Position = UDim2.fromOffset(0, if down then LIFT elseif over then -3 else 0),
		}):Play()
	end
	cap.MouseButton1Down:Connect(function() down = true seat() end)
	cap.MouseButton1Up:Connect(function() down = false seat() end)
	cap.MouseEnter:Connect(function()
		over = true
		seat()
		TweenService:Create(cap, TweenInfo.new(0.1), { BackgroundColor3 = restCol:Lerp(Color3.new(1,1,1), 0.16) }):Play()
	end)
	cap.MouseLeave:Connect(function()
		over, down = false, false
		seat()
		TweenService:Create(cap, TweenInfo.new(0.12), { BackgroundColor3 = restCol }):Play()
	end)
	if onClick then cap.Activated:Connect(onClick); Console.bindButton(cap, onClick) end

	local function recolour(c: Color3)
		restCol = UIKit.retint(cap, c)
		plinth.BackgroundColor3 = UIKit.deepen(c, 0.30)
	end

	return holder, cap, recolour
end

-- round icon button, used for the side rail and window close crosses
function UIKit.iconButton(parent: Instance, glyph: string, diameter: number, base: Color3?, onClick: (() -> ())?)
	local holder, cap = UIKit.button(parent, glyph, UDim2.fromOffset(diameter, diameter), base or T.blue, onClick)
	for _, d in ipairs(holder:GetDescendants()) do
		if d:IsA("UICorner") then d.CornerRadius = UDim.new(0.5, 0) end
	end
	cap.TextSize = math.floor(diameter * 0.46)
	return holder, cap
end

function UIKit.closeButton(panel: GuiObject, onClose: () -> ())
	Console.registerClose(panel, onClose)
	local holder = UIKit.iconButton(panel, "X", 44, T.red, onClose)
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Position = UDim2.new(1, 6, 0, -10)
	holder.ZIndex = 20
	-- GuiObject only: UICorner, UIStroke and UIGradient are all in here too and
	-- none of them has a ZIndex
	for _, d in ipairs(holder:GetDescendants()) do
		if d:IsA("GuiObject") then d.ZIndex = 21 end
	end
	return holder
end

--==[ currency pill ]=========================================================

function UIKit.pill(parent: Instance, glyph: string, value: string, tint: Color3?)
	local container, root = UIKit.shadowed(parent, UDim2.fromOffset(224, 54),
		UDim2.new(), Vector2.new(0, 0), 16, 5)
	container.Name = "Pill"
	root.BackgroundColor3 = T.panel
	stroke(root, 2.8)
	gradient(root, 0.95)
	gloss(root, 6, 11, 0.38)

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 6, 0.5, 0)
	badge.Size = UDim2.fromOffset(42, 42)
	badge.BackgroundColor3 = tint or T.gold
	badge.BorderSizePixel = 0
	badge.ZIndex = 6
	badge.Parent = root
	corner(badge, 21)
	stroke(badge, 2.2)
	gradient(badge, 1.2)

	local g = UIKit.label(badge, glyph, 22, T.navy)
	g.Size = UDim2.fromScale(1, 1)
	g.TextXAlignment = Enum.TextXAlignment.Center
	g.ZIndex = 7

	local val = UIKit.label(root, value, 26, T.white)
	val.Name = "Value"
	val.Position = UDim2.fromOffset(56, 0)
	val.Size = UDim2.new(1, -66, 1, 0)
	val.TextXAlignment = Enum.TextXAlignment.Right
	val.ZIndex = 7

	return container, val
end

--==[ display text ]==========================================================

-- Bold text with a single hard outline, the way the stat readouts are drawn.
-- No panel behind it: the outline is what keeps it legible over the world.
function UIKit.outlined(parent: Instance, text: string, size: number, fill: Color3, thick: number?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = UIKit.Display
	l.Text = text
	l.TextSize = size
	l.TextColor3 = fill
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.RichText = true
	l.Parent = parent
	local s = Instance.new("UIStroke")
	s.Thickness = thick or math.max(2, size * 0.13)
	s.Color = T.ink
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = l
	return l
end

function UIKit.bigTitle(parent: Instance, text: string, size: number, fill: Color3): (TextLabel, Frame)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(10, size * 1.25)
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Parent = parent

	local function layer(col: Color3, strokeCol: Color3, thick: number, z: number): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Font = UIKit.Display
		l.Text = text
		l.TextSize = size
		l.TextColor3 = col
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Size = UDim2.fromOffset(0, size * 1.25)
		l.AutomaticSize = Enum.AutomaticSize.X
		l.ZIndex = z
		l.Parent = holder
		local s = Instance.new("UIStroke")
		s.Thickness = thick
		s.Color = strokeCol
		s.LineJoinMode = Enum.LineJoinMode.Round
		s.Parent = l
		return l
	end
	local front = layer(fill, T.ink, size * 0.13, 4)
	return front, holder
end

--==[ progress pill ]=========================================================

function UIKit.progressPill(parent: Instance, width: number)
	local root = Instance.new("Frame")
	root.Name = "Progress"
	root.Size = UDim2.fromOffset(width, 34)
	root.BackgroundColor3 = Color3.fromRGB(26, 64, 118)
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.Parent = parent
	corner(root, 17)
	stroke(root, 2.5)
	-- the empty part of the track is a groove, so it is lit from below
	UIKit.vignette(root, 17, 270, 0.34)

	local INSET = 4
	local groove = Instance.new("Frame")
	groove.Name = "Groove"
	groove.BackgroundTransparency = 1
	groove.Position = UDim2.fromOffset(INSET, INSET)
	groove.Size = UDim2.new(1, -INSET * 2, 1, -INSET * 2)
	groove.ZIndex = 2
	groove.Parent = root

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(86, 226, 255)
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = groove
	
	corner(fill, 999)
	gradient(fill, 1.1)
	-- and the filled part is a moulded bar, so it catches the light from above
	gloss(fill, 3, 7, 0.44)

	local l = UIKit.outlined(root, "", 19, T.white, 2.6)
	l.Size = UDim2.fromScale(1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.ZIndex = 4

	return root, fill, l
end

--==[ small chip button ]=====================================================

function UIKit.chip(parent: Instance, text: string, width: number, tint: Color3, onClick: (() -> ())?)
	local holder = Instance.new("Frame")
	holder.Name = "Chip"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(width, 38)
	holder.Parent = parent
	UIKit.dropShadow(holder, 11, 5, 1)

	local b = Instance.new("TextButton")
	b.Name = "Cap"
	b.AutoButtonColor = false
	b.Size = UDim2.fromScale(1, 1)
	b.BackgroundColor3 = tint
	b.BorderSizePixel = 0

	b.Text = ""
	b.ZIndex = 3
	b.Parent = holder
	corner(b, 11)
	-- One keyline only. A second UIStroke on the same instance is ignored, which
	-- is why the white border here always won and the black one never appeared.
	stroke(b, 2.2)
	gradient(b)

	local cap = Instance.new("TextLabel")
	cap.Name = "Label"
	cap.BackgroundTransparency = 1
	cap.Size = UDim2.fromScale(1, 1)
	cap.Font = UIKit.Display
	cap.Text = text
	cap.TextSize = 19
	cap.TextWrapped = true
	cap.ClipsDescendants = true
	cap.TextColor3 = T.white
	cap.ZIndex = 4
	cap.Parent = b
	-- Contextual, so the edge lands on the glyphs and not round the label's own
	-- invisible rectangle. Thin on purpose: enough to lift the type off the fill,
	-- not enough to read as a second outline beside the keyline.
	stroke(cap, 1.6, T.ink, true)

	local rest = b.BackgroundColor3
	b.MouseEnter:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.1), { BackgroundColor3 = rest:Lerp(Color3.new(1,1,1), 0.2) }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundColor3 = rest }):Play()
	end)
	b.MouseButton1Down:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.06), { Position = UDim2.fromOffset(0, 3) }):Play()
	end)
	local function up()
		TweenService:Create(b, TweenInfo.new(0.09), { Position = UDim2.fromOffset(0, 0) }):Play()
	end
	b.MouseButton1Up:Connect(up)
	b.MouseLeave:Connect(up)
	if onClick then b.Activated:Connect(onClick); Console.bindButton(b, onClick) end
	return holder
end

--==[ captions ]==============================================================

function UIKit.fitText(texts: { string }, maxWidth: number, hi: number, lo: number): number
	for size = hi, lo, -1 do
		local widest = 0
		for _, t in ipairs(texts) do
			widest = math.max(widest,
				TextService:GetTextSize(t, size, UIKit.Display, Vector2.new(9999, 9999)).X)
		end
		if widest <= maxWidth then return size end
	end
	return lo
end

--==[ square rail button ]====================================================

function UIKit.squareIcon(parent: Instance, glyph: string, box: number, tint: Color3,
	onClick: (() -> ())?, title: string?, titleSize: number?)
	local holder = Instance.new("Frame")
	holder.Name = "RailButton"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(box, box)
	holder.Parent = parent

	UIKit.dropShadow(holder, 17, 6, 1)

	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Size = UDim2.fromScale(1, 1)
	b.BackgroundColor3 = tint
	b.BorderSizePixel = 0
	b.Text = ""
	b.ZIndex = 3
	b.Parent = holder
	corner(b, 17)
	stroke(b, 2.5)
	gradient(b)

	-- the shine strip, which is the whole difference between a coloured square
	-- and a moulded plastic key
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.76
	shine.BorderSizePixel = 0
	shine.Position = UDim2.fromOffset(7, 6)
	shine.Size = UDim2.new(1, -14, 0, math.floor(box * 0.26))
	shine.ZIndex = 4
	shine.Parent = b
	corner(shine, 10)

	local ic = Instance.new("TextLabel")
	ic.Name = "Glyph"
	ic.BackgroundTransparency = 1
	ic.Font = Enum.Font.GothamBold
	ic.Text = glyph
	ic.TextColor3 = T.white
	ic.ZIndex = 5
	ic.Parent = b

	if title then

		local capSize = titleSize or 12
		local capH = math.floor(capSize * 1.35)
		local capBottom = 6
		local glyphTop = 5

		ic.Position = UDim2.fromOffset(0, glyphTop)
		ic.Size = UDim2.new(1, 0, 0, box - capH - capBottom - glyphTop)
		-- Bigger than it was: at 0.40 of an 82px key the pictogram was smaller than
		-- the word under it, which is backwards for the thing the eye lands on
		-- first. It has the height for it -- the band is 54px.
		ic.TextSize = math.floor(box * 0.52)

		local cap = UIKit.outlined(b, title, capSize, T.white, 2)
		cap.Name = "Title"
		cap.AnchorPoint = Vector2.new(0.5, 1)
		cap.Position = UDim2.new(0.5, 0, 1, -capBottom)
		cap.Size = UDim2.new(1, -8, 0, capH)
		cap.TextXAlignment = Enum.TextXAlignment.Center
		cap.TextYAlignment = Enum.TextYAlignment.Bottom
		cap.ZIndex = 6
	else
		ic.Size = UDim2.fromScale(1, 1)
		ic.TextSize = math.floor(box * 0.56)
	end

	local alert = Instance.new("Frame")
	alert.Name = "Alert"
	alert.AnchorPoint = Vector2.new(0.5, 0.5)
	alert.Position = UDim2.fromOffset(5, 5)
	alert.Size = UDim2.fromOffset(26, 26)
	alert.BackgroundColor3 = T.red
	alert.BorderSizePixel = 0
	alert.Visible = false
	alert.ZIndex = 8
	alert.Parent = holder
	corner(alert, 13)
	stroke(alert, 2.4)
	gradient(alert, 0.95)

	local bang = UIKit.outlined(alert, "!", 19, T.white, 2)
	bang.Size = UDim2.fromScale(1, 1)
	bang.Position = UDim2.fromOffset(0, -1)
	bang.TextXAlignment = Enum.TextXAlignment.Center
	bang.ZIndex = 9

	-- Its own UIScale, so the pulse cannot fight the press animation on the
	-- holder; a reversing infinite tween costs nothing while it is hidden.
	local pulse = Instance.new("UIScale")
	pulse.Parent = alert
	TweenService:Create(pulse, TweenInfo.new(0.62, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true), { Scale = 1.14 }):Play()

	local rest = b.BackgroundColor3
	b.MouseEnter:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.1), { BackgroundColor3 = rest:Lerp(Color3.new(1,1,1), 0.18) }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundColor3 = rest }):Play()
	end)
	b.MouseButton1Down:Connect(function()
		TweenService:Create(holder, TweenInfo.new(0.06), { Size = UDim2.fromOffset(box * 0.93, box * 0.93) }):Play()
	end)
	local function up()
		TweenService:Create(holder, TweenInfo.new(0.09), { Size = UDim2.fromOffset(box, box) }):Play()
	end
	b.MouseButton1Up:Connect(up)
	b.MouseLeave:Connect(up)
	if onClick then b.Activated:Connect(onClick); Console.bindButton(b, onClick) end

	return holder, alert
end

--==[ showpiece parts ]======================================================

function UIKit.sunburst(parent: GuiObject, rays: number, diameter: number, colour: Color3, z: number?)
	local hub = Instance.new("Frame")
	hub.Name = "Sunburst"
	hub.BackgroundTransparency = 1
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromOffset(diameter, diameter)
	hub.ZIndex = z or parent.ZIndex
	hub.Parent = parent

	for i = 1, rays do
		local r = Instance.new("Frame")
		r.Name = "Ray"
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.Position = UDim2.fromScale(0.5, 0.5)
		r.Size = UDim2.fromOffset(math.max(4, math.floor(diameter * 0.09)), diameter)
		r.BackgroundColor3 = colour
		r.BackgroundTransparency = 0.62
		r.BorderSizePixel = 0
		r.Rotation = (i - 1) * (180 / rays)
		r.ZIndex = hub.ZIndex
		r.Parent = hub
		-- tapered rather than a bar, so the fan reads as light and not as a wheel
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = r
	end

	TweenService:Create(hub, TweenInfo.new(26, Enum.EasingStyle.Linear,
		Enum.EasingDirection.InOut, -1), { Rotation = 180 }):Play()
	return hub
end

-- Idle breathing. The single biggest "this is alive" signal available, and it
-- costs one reversing tween per element.
function UIKit.bob(inst: GuiObject, amount: number?, period: number?): UIScale
	local s = inst:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	s.Parent = inst
	TweenService:Create(s, TweenInfo.new(period or 1.6, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true), { Scale = 1 + (amount or 0.045) }):Play()
	return s
end

function UIKit.sheen(inst: GuiObject, period: number?, z: number?)
	local s = Instance.new("Frame")
	s.Name = "Sheen"
	s.BackgroundColor3 = Color3.new(1, 1, 1)
	s.BorderSizePixel = 0
	s.Size = UDim2.fromScale(1, 1)
	s.ZIndex = z or (inst.ZIndex + 1)
	s.Parent = inst
	local c = inst:FindFirstChildOfClass("UICorner")
	corner(s, c and c.CornerRadius.Offset or 12)

	local g = Instance.new("UIGradient")
	g.Rotation = 18
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.42, 1),
		NumberSequenceKeypoint.new(0.5, 0.72),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Offset = Vector2.new(-1.4, 0)
	g.Parent = s
	task.spawn(function()
		local wait_ = period or 2.2
		while s.Parent do
			TweenService:Create(g, TweenInfo.new(wait_, Enum.EasingStyle.Quad,
				Enum.EasingDirection.InOut), { Offset = Vector2.new(1.4, 0) }):Play()
			task.wait(wait_ + 2 + math.random() * 3)
			g.Offset = Vector2.new(-1.4, 0)
		end
	end)
	return s
end

function UIKit.tag(parent: GuiObject, text: string, tint: Color3, z: number?)
	local r = Instance.new("Frame")
	r.Name = "Tag"
	r.AnchorPoint = Vector2.new(1, 0)
	r.Position = UDim2.new(1, -180, 0, 7)
	r.Size = UDim2.fromOffset(104, 23)
	r.Rotation = -6
	r.BackgroundColor3 = tint
	r.BorderSizePixel = 0
	r.ZIndex = z or (parent.ZIndex + 4)
	r.Parent = parent
	corner(r, 8)
	stroke(r, 2.2)
	gradient(r, 1.1)

	local l = UIKit.outlined(r, text, 13, T.white, 2)
	l.Size = UDim2.fromScale(1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.ZIndex = r.ZIndex + 1
	return r
end

function UIKit.coin(parent: GuiObject, d: number, tint: Color3?, z: number?): Frame
	local c = Instance.new("Frame")
	c.Name = "Coin"
	c.Size = UDim2.fromOffset(d, d)
	c.Position = UDim2.new(0.5, 0, 0.3, 0)
	c.BackgroundColor3 = tint or T.gold
	c.BorderSizePixel = 0
	c.ZIndex = z or (parent.ZIndex + 1)
	c.Parent = parent
	corner(c, math.floor(d / 2))
	stroke(c, 2.2)
	gradient(c, 1.15)
	
	if parent.Name == "Day3" then
		c.Position = UDim2.new(0.3, 0, 0.3, 0)
		
		local s = Instance.new("Frame")
		s.Name = "Skin"
		s.Size = UDim2.fromOffset(d, d)
		s.Position = UDim2.new(0.66, 0, 0.3, 0)
		s.BackgroundTransparency = 1
		s.ZIndex = z or (parent.ZIndex + 1)
		s.Parent = parent
		corner(s, math.floor(d / 2))
		
		local i = Instance.new("ImageLabel")
		i.BackgroundTransparency = 1
		i.Image = "rbxassetid://100487626616463"
		i.Size = UDim2.new(1, 0, 1, 0)
		i.ScaleType = Enum.ScaleType.Fit
		i.Parent = s
		--stroke(s, 2.2)
		--gradient(s, 1.15)
	elseif parent.Name == "Day7" then
		c:Destroy()
		
		local s = Instance.new("Frame")
		s.Name = "Skin"
		s.Size = UDim2.fromOffset(d, d)
		s.Position = UDim2.new(0.45, 0, 0.3, 0)
		s.BackgroundTransparency = 1
		s.ZIndex = z or (parent.ZIndex + 1)
		s.Parent = parent
		corner(s, math.floor(d / 2))
		stroke(c, 2.2)
		gradient(c, 1.15)
		
		local i = Instance.new("ImageLabel")
		i.BackgroundTransparency = 1
		i.Image = "rbxassetid://129999413073221"
		i.Size = UDim2.new(1, 0, 1, 0)
		i.ScaleType = Enum.ScaleType.Fit
		i.Parent = s
	end
	-- the inset face, which is what makes it read as struck metal
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.3, 0.5)
	face.Size = UDim2.fromOffset(math.floor(d * 0.68), math.floor(d * 0.68))
	face.BackgroundColor3 = (tint or T.gold):Lerp(Color3.new(1, 1, 1), 0.3)
	face.BorderSizePixel = 0
	face.ZIndex = c.ZIndex + 1
	face.Parent = c
	corner(face, math.floor(d * 0.34))

	local s = UIKit.outlined(c, "$", math.floor(d * 0.46), T.navy, 1.6)
	s.Size = UDim2.fromScale(1, 1)
	s.Position = UDim2.fromOffset(0, -1)
	s.TextXAlignment = Enum.TextXAlignment.Center
	s.ZIndex = c.ZIndex + 2
	return c
end

--==[ scrolling list ]========================================================

function UIKit.scroller(parent: Instance, padding: number?)
	local sc = Instance.new("ScrollingFrame")
	sc.Name = "List"
	sc.BackgroundTransparency = 1
	sc.BorderSizePixel = 0

	sc.Size = UDim2.new(1, 0, 1, -12)
	sc.Position = UDim2.fromOffset(0, 6)
	sc.CanvasSize = UDim2.new()
	sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sc.ScrollBarThickness = 8

	sc.VerticalScrollBarInset = Enum.ScrollBarInset.Always
	sc.ScrollBarImageColor3 = T.navy
	sc.ScrollBarImageTransparency = 0.3
	sc.ZIndex = 7
	sc.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, padding or 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = sc

	-- Top and bottom clear the stroke on their own. Left and right are the
	-- panel's side margin, moved in off the frame -- see the note on Size.
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 4)
	pad.Parent = sc

	return sc
end

--==[ toggle + slider, for the settings panel ]===============================

function UIKit.toggle(parent: Instance, text: string, on: boolean, onChange: (boolean) -> (),
	note: string?)
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.Size = UDim2.new(1, 0, 0, if note then 70 else 52)
	row.BackgroundColor3 = T.blueDark
	row.BorderSizePixel = 0
	row.ZIndex = 8
	row.Parent = parent
	corner(row, 13)
	stroke(row, 2.2)
	gradient(row, 0.5)

	local l = UIKit.label(row, text, 22, T.cream)
	l.Position = UDim2.fromOffset(16, if note then 8 else 0)
	l.Size = if note then UDim2.new(1, -130, 0, 26) else UDim2.new(1, -130, 1, 0)
	l.ZIndex = 9

	if note then
		-- Gold, because it is a caution rather than a caption: small enough to read
		-- as secondary, and it still carries the kit's ink keyline so it stays
		-- legible on the row's blue.
		local n = UIKit.label(row, note, 15, T.gold)
		n.Name = "Note"
		n.Position = UDim2.fromOffset(16, 36)
		n.Size = UDim2.new(1, -130, 0, 22)
		n.ZIndex = 9
	end

	local state = on
	local holder, cap, recolour
	holder, cap, recolour = UIKit.button(row, on and "ON" or "OFF", UDim2.fromOffset(86, 40), on and T.green or T.slate, function()
		state = not state
		cap.Text = state and "ON" or "OFF"
		recolour(state and T.green or T.slate)
		onChange(state)
	end)
	holder.AnchorPoint = Vector2.new(1, 0.5)
	holder.Position = UDim2.new(1, -12, 0.5, 0)
	return row
end

function UIKit.slider(parent: Instance, text: string, value: number, onChange: (number) -> ())
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.Size = UDim2.new(1, 0, 0, 68)
	row.BackgroundColor3 = T.blueDark
	row.BorderSizePixel = 0
	row.ZIndex = 8
	row.Parent = parent
	corner(row, 13)
	stroke(row, 2.2)
	gradient(row, 0.5)

	local l = UIKit.label(row, text, 20, T.cream)
	l.Position = UDim2.fromOffset(16, 4)
	l.Size = UDim2.new(1, -32, 0, 26)
	l.ZIndex = 9

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(16, 38)
	track.Size = UDim2.new(1, -32, 0, 16)
	track.BackgroundColor3 = T.navy
	track.BorderSizePixel = 0
	track.ZIndex = 9
	-- A Frame does not receive mouse-button input unless it is Active, and this one
	-- has to: the whole bar is the click target now, not just the knob.
	track.Active = true
	track.Parent = row
	corner(track, 8)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(math.clamp(value, 0, 1), 1)
	fill.BackgroundColor3 = T.green
	fill.BorderSizePixel = 0
	fill.ZIndex = 10
	fill.Parent = track
	corner(fill, 8)
	gradient(fill, 0.9)

	local knob = Instance.new("TextButton")
	knob.Name = "Knob"
	knob.Text = ""
	knob.AutoButtonColor = false
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(math.clamp(value, 0, 1), 0, 0.5, 0)
	knob.Size = UDim2.fromOffset(28, 28)
	knob.BackgroundColor3 = T.white
	knob.BorderSizePixel = 0
	knob.ZIndex = 11
	knob.Parent = track
	corner(knob, 14)
	stroke(knob, 2.2)

	local dragging = false
	local function apply(x: number)
		local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		fill.Size = UDim2.fromScale(rel, 1)
		knob.Position = UDim2.new(rel, 0, 0.5, 0)
		onChange(rel)
	end

	Console.slider(knob, function(delta)
		local value = math.clamp(fill.Size.X.Scale + delta, 0, 1)
		apply(track.AbsolutePosition.X + value * track.AbsoluteSize.X)
	end)

	local function onKnob(x: number): boolean
		return x >= knob.AbsolutePosition.X and x <= knob.AbsolutePosition.X + knob.AbsoluteSize.X
	end
	track.InputBegan:Connect(function(i)
		if i.UserInputType ~= Enum.UserInputType.MouseButton1
			and i.UserInputType ~= Enum.UserInputType.Touch then return end
		dragging = true
		if not onKnob(i.Position.X) then apply(i.Position.X) end
	end)
	-- Still needed: when the knob does swallow the press, the track never hears it.
	knob.MouseButton1Down:Connect(function() dragging = true end)
	game:GetService("UserInputService").InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end)
	game:GetService("UserInputService").InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			apply(i.Position.X)
		end
	end)
	return row
end

return UIKit
