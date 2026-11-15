--!strict
--[[
	LeaderboardClient -- draws the three courtyard boards, on both faces.

	The server publishes one JSON string (see LeaderboardService) and this turns
	it into rows. Nothing is requested from here and nothing is sent back: the
	boards are a readout, and the paging arrows only move a local index.

	There are TWO SETS of three boards -- `Leaderboards.Yard` facing the depot
	spawn and `Leaderboards.Street` facing Maple Drive over the fence -- because a
	single row read from the far side is mostly fence. This draws the identical
	face into every copy it finds, and never counts them: it collects every
	SurfaceGui whose board model is named `Board_<id>`, wherever under the
	container that model sits. A third set would need no change here.

	The page index is per BOARD ID rather than per copy, so every copy of a board
	always agrees and either side's arrows turn both.

	THE WHOLE FACE IS BUILT HERE rather than authored into the place. These are
	drawn with UIKit -- the same widget set as the shop, the rail and the HUD -- so
	they inherit the black keyline, the two-hue ramp, the hard drop shadow and the
	shine strip that make everything else look like one product. Half of that kit
	is BEHAVIOUR: the nav arrows hover and press down into their own plinth, and
	signal connections do not survive being saved into a place file. Authoring
	only the PARTS and drawing at runtime is what buys the press feedback.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local Leaderboards = require(SealerUI:WaitForChild("Leaderboards"))
local UIKit = require(SealerUI:WaitForChild("UIKit"))

local player = Players.LocalPlayer
local T = UIKit.Theme

local TINT: { [string]: Color3 } = {
	Earned = T.gold,
	Rebirths = T.purple,
	Jobs = T.green,
}
local MEDAL = {
	Color3.fromRGB(255, 206, 56),
	Color3.fromRGB(214, 224, 236),
	Color3.fromRGB(226, 146, 78),
}

-- Canvas is 595 x 816 (a 12.4 x 17 panel at 48 px/stud). Everything below is
-- in those pixels; the row height is chosen first, for legibility at distance,
-- and Leaderboards.PageSize follows from what fits.
local ROW_H = 52
local ROW_PAD = 5

local page: { [string]: number } = {}
local latest: { [string]: { { n: string, v: number } } } = {}
local reachable = true
-- keyed on the SurfaceGui instance, so a face handed back by streaming is
-- rebuilt rather than remembered as already done
local chrome: { [Instance]: any } = {}

--==[ SMALL PARTS OF THE KIT ]================================================

local function shine(parent: GuiObject, inset: number, height: number, alpha: number)
	local g = Instance.new("Frame")
	g.Name = "Shine"
	g.BackgroundColor3 = T.white
	g.BackgroundTransparency = alpha
	g.BorderSizePixel = 0
	g.Position = UDim2.new(0, inset, 0, inset)
	g.Size = UDim2.new(1, -inset * 2, 0, height)
	g.ZIndex = 6
	g.Parent = parent
	UIKit.corner(g, math.floor(height * 0.5))
	return g
end

-- a hard shadow behind a body, as its SIBLING: a child always draws above its
-- parent whatever its ZIndex, so a shadow parented to what it shades is just a
-- dark rectangle sitting on top of it
local function shadowBehind(holder: GuiObject, radius: number, drop: number)
	local sh = Instance.new("Frame")
	sh.Name = "Shadow"
	sh.BackgroundColor3 = T.shadow
	sh.BackgroundTransparency = 0.42
	sh.BorderSizePixel = 0
	sh.Position = UDim2.new(0, 0, 0, drop)
	sh.Size = UDim2.fromScale(1, 1)
	sh.ZIndex = 1
	sh.Parent = holder
	UIKit.corner(sh, radius)
	return sh
end

local function display(parent: Instance, text: string, font: Enum.Font, px: number,
		colour: Color3, outline: number?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Text = text
	t.Font = font
	t.TextSize = px
	t.TextColor3 = colour
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.TextYAlignment = Enum.TextYAlignment.Center
	t.Parent = parent
	-- Contextual, or the stroke boxes the label's frame instead of edging the
	-- glyphs. See the note on UIKit.stroke.
	if outline then UIKit.stroke(t, outline, T.ink, true) end
	return t
end

--==[ THE FACE ]==============================================================

local render: (any) -> ()

--[[
	Built once per SurfaceGui: header, body well, footer, arrows.

	Only the ROWS are redrawn on a refresh. Rebuilding the arrows every sixty
	seconds would throw away UIKit's hover and press connections with them, and a
	button that resets itself mid-press is worse than one that never moves.
]]
local function buildChrome(board, gui: Instance)
	local tint = TINT[board.id] or T.blue
	for _, c in ipairs(gui:GetChildren()) do c:Destroy() end

	--[[
		The navy field is painted HERE rather than being the part's colour.

		The panel part is ink, because the one face of it anybody ever sees bare is
		the back, and that should read as the sign's own dark backing rather than as
		a blank screen. ZIndex 0 puts this behind every sibling.
	]]
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.BackgroundColor3 = T.navy
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.ZIndex = 0
	backdrop.Parent = gui

	--[ header ]--------------------------------------------------------------
	local head = Instance.new("Frame")
	head.Name = "Header"
	head.BackgroundTransparency = 1
	head.Position = UDim2.new(0, 16, 0, 10)
	head.Size = UDim2.new(1, -32, 0, 118)
	head.Parent = gui
	shadowBehind(head, 24, 7)

	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.BackgroundColor3 = tint
	banner.BorderSizePixel = 0
	banner.Size = UDim2.fromScale(1, 1)
	banner.ZIndex = 2
	banner.Parent = head
	UIKit.corner(banner, 24)
	UIKit.gradient(banner, 1.1)
	UIKit.stroke(banner, 3.5)
	shine(banner, 11, 14, 0.62)

	local title = display(banner, board.title, UIKit.Display, 50, T.cream, 3.5)
	title.Name = "Title"
	title.Position = UDim2.new(0, 10, 0, 6)
	title.Size = UDim2.new(1, -20, 0, 56)
	title.ZIndex = 8

	-- the caption sits on its own dark lozenge, so it reads as a subtitle rather
	-- than as a second, quieter heading
	local capPill = Instance.new("Frame")
	capPill.Name = "CaptionPill"
	capPill.BackgroundColor3 = T.navy
	capPill.BorderSizePixel = 0
	capPill.AnchorPoint = Vector2.new(0.5, 0)
	capPill.Position = UDim2.new(0.5, 0, 0, 66)
	capPill.Size = UDim2.new(1, -44, 0, 42)
	capPill.ZIndex = 8
	capPill.Parent = banner
	UIKit.corner(capPill, 21)
	UIKit.stroke(capPill, 3)
	local cap = display(capPill, board.caption, UIKit.Font, 24, T.cream)
	cap.Size = UDim2.fromScale(1, 1)
	cap.ZIndex = 9

	--[ body well ]-----------------------------------------------------------
	local well = Instance.new("Frame")
	well.Name = "Well"
	well.BackgroundColor3 = T.ink
	well.BackgroundTransparency = 0.55
	well.BorderSizePixel = 0
	well.Position = UDim2.new(0, 16, 0, 138)
	well.Size = UDim2.new(1, -32, 0, 590)
	well.Parent = gui
	UIKit.corner(well, 20)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.new(0, 10, 0, 10)
	body.Size = UDim2.new(1, -20, 1, -20)
	body.Parent = well
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, ROW_PAD)
	list.Parent = body

	--[ footer ]--------------------------------------------------------------
	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.BackgroundTransparency = 1
	footer.Position = UDim2.new(0, 16, 0, 738)
	footer.Size = UDim2.new(1, -32, 0, 68)
	footer.Parent = gui

	local function step(by: number)
		page[board.id] = (page[board.id] or 1) + by
		render(board)
	end
	local prev = UIKit.button(footer, "\u{25C0}", UDim2.fromOffset(96, 58), tint, function() step(-1) end)
	prev.Position = UDim2.new(0, 0, 0, 4)
	local nxt = UIKit.button(footer, "\u{25B6}", UDim2.fromOffset(96, 58), tint, function() step(1) end)
	nxt.AnchorPoint = Vector2.new(1, 0)
	nxt.Position = UDim2.new(1, 0, 0, 4)

	local pagePill = Instance.new("Frame")
	pagePill.Name = "PagePill"
	pagePill.BackgroundColor3 = T.navy
	pagePill.BorderSizePixel = 0
	pagePill.AnchorPoint = Vector2.new(0.5, 0)
	pagePill.Position = UDim2.new(0.5, 0, 0, 10)
	pagePill.Size = UDim2.new(0, 262, 0, 46)
	pagePill.Parent = footer
	UIKit.corner(pagePill, 23)
	UIKit.stroke(pagePill, 3)
	local pageLabel = display(pagePill, "", UIKit.Font, 26, T.cream)
	pageLabel.Name = "Page"
	pageLabel.Size = UDim2.fromScale(1, 1)

	local parts = { body = body, pageLabel = pageLabel }
	chrome[gui] = parts
	return parts
end

--==[ ROWS ]==================================================================

local function clearRows(body: Instance)
	for _, c in ipairs(body:GetChildren()) do
		if not c:IsA("UIListLayout") then c:Destroy() end
	end
end

local function notice(body: Instance, headline: string, sub: string)
	clearRows(body)
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, 180)
	f.Parent = body
	local a = display(f, headline, UIKit.Display, 34, T.slate, 2.5)
	a.Position = UDim2.new(0, 0, 0, 40)
	a.Size = UDim2.new(1, 0, 0, 44)
	local b = display(f, sub, UIKit.Font, 22, T.slate)
	b.Position = UDim2.new(0, 14, 0, 92)
	b.Size = UDim2.new(1, -28, 0, 56)
	b.TextWrapped = true
end

local function drawRow(body: Instance, board, rank: number, name: string, value: string)
	local tint = TINT[board.id] or T.blue
	local mine = name == player.Name
	local medal = MEDAL[rank]

	local row = Instance.new("Frame")
	row.Name = "Row" .. rank
	row.LayoutOrder = rank
	row.Size = UDim2.new(1, 0, 0, ROW_H)
	row.BorderSizePixel = 0
	row.BackgroundColor3 = if mine then tint else T.navy
	-- Only your own row and the podium carry a fill. Banding all ten turns the
	-- board into a stripy mess and buries the two rows that matter.
	row.BackgroundTransparency = if mine then 0.12 elseif medal then 0.55 else 0.82
	row.Parent = body
	UIKit.corner(row, 14)
	if mine or medal then UIKit.stroke(row, if mine then 3 else 2, T.ink) end

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 8, 0.5, 0)
	badge.Size = UDim2.fromOffset(if medal then 40 else 46, if medal then 40 else 32)
	badge.BackgroundColor3 = medal or T.ink
	badge.BackgroundTransparency = if medal then 0 else 0.35
	badge.BorderSizePixel = 0
	badge.Parent = row
	UIKit.corner(badge, if medal then 20 else 14)
	if medal then
		UIKit.stroke(badge, 2.5)
		UIKit.gradient(badge, 0.9)
	end
	local rankText = display(badge,
		if medal then tostring(rank) else Leaderboards.rankText(rank),
		if medal then UIKit.Display else UIKit.Font,
		if medal then 26 else 21,
		if medal then T.ink else T.slate)
	rankText.Size = UDim2.fromScale(1, 1)

	local nm = display(row, name, UIKit.Font, 29, T.cream, if mine then 2 else nil)
	nm.Name = "Name"
	nm.Position = UDim2.new(0, 62, 0, 0)
	nm.Size = UDim2.new(1, -232, 1, 0)
	nm.TextXAlignment = Enum.TextXAlignment.Left
	nm.TextTruncate = Enum.TextTruncate.AtEnd

	local val = display(row, value, UIKit.Display, 30, medal or tint, 2)
	val.Name = "Value"
	val.AnchorPoint = Vector2.new(1, 0)
	val.Position = UDim2.new(1, -14, 0, 0)
	val.Size = UDim2.new(0, 158, 1, 0)
	val.TextXAlignment = Enum.TextXAlignment.Right
end

--==[ RENDER ]================================================================

--[[
	Every screen showing this board, across every set.

	Matched on the MODEL name rather than on a path, so the sets can be foldered
	however the world wants them -- Yard/Street today, and any arrangement later --
	without this file knowing the layout.
]]
local function guisOf(id: string): { Instance }
	local root = workspace:FindFirstChild(Leaderboards.Container)
	local out = {}
	if not root then return out end
	local want = "Board_" .. id
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("SurfaceGui") then
			local panel = d.Parent
			local model = panel and panel.Parent
			if model and model.Name == want then out[#out + 1] = d end
		end
	end
	return out
end

function render(board)
	local rows = latest[board.id]
	local per = Leaderboards.PageSize
	local p = 1
	if rows and #rows > 0 then
		local pages = math.max(1, math.ceil(#rows / per))
		-- clamped here rather than at the button, so a refresh that shortens the
		-- list cannot leave somebody parked on a page that no longer exists
		p = math.clamp(page[board.id] or 1, 1, pages)
		page[board.id] = p
	end

	for _, gui in ipairs(guisOf(board.id)) do
		local parts = chrome[gui]
		if not parts or not parts.body.Parent then
			parts = buildChrome(board, gui)
		end
		local body, pageLabel = parts.body, parts.pageLabel

		if not reachable then
			notice(body, "RECORDS OFFLINE", "The board cannot reach the record books right now.")
			pageLabel.Text = "--"
		elseif not rows or #rows == 0 then
			notice(body, "NO ENTRIES YET", "Be the first name on this board.")
			pageLabel.Text = "0 of 0"
		else
			clearRows(body)
			local first, last = (p - 1) * per + 1, math.min(#rows, p * per)
			for rank = first, last do
				local e = rows[rank]
				drawRow(body, board, rank, e.n, Leaderboards.display(board, e.v))
			end
			pageLabel.Text = ("%d - %d of %d"):format(first, last, #rows)
		end
	end
end

local function renderAll()
	for _, board in ipairs(Leaderboards.List) do render(board) end
end

--==[ DATA ]==================================================================

local function absorb(raw: string)
	if raw == "" then return end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(data) ~= "table" then return end
	reachable = data.ok ~= false
	if type(data.boards) == "table" then
		for _, board in ipairs(Leaderboards.List) do
			local rows = data.boards[board.id]
			if type(rows) == "table" then latest[board.id] = rows end
		end
	end
end

--==[ WIRING ]================================================================

task.spawn(function()
	local payload = SealerUI:WaitForChild(Leaderboards.DataName, 30) :: StringValue?
	local root = workspace:WaitForChild(Leaderboards.Container, 30)
	if not root then
		warn("[Leaderboards] no workspace." .. Leaderboards.Container .. " -- nothing to draw on.")
		return
	end

	for _, board in ipairs(Leaderboards.List) do page[board.id] = 1 end

	--[[
		Streaming is on and these boards stand twenty-odd studs from the spawn, so
		on a real client they routinely do not exist yet when this first runs.
		Redrawing when a face turns up is what builds it and connects its arrows --
		see buildChrome, which is keyed on the SurfaceGui.
	]]
	root.DescendantAdded:Connect(function(d)
		if d:IsA("SurfaceGui") then task.defer(renderAll) end
	end)

	if payload then
		absorb(payload.Value)
		payload:GetPropertyChangedSignal("Value"):Connect(function()
			absorb(payload.Value)
			renderAll()
		end)
	else
		reachable = false
	end
	renderAll()
end)
