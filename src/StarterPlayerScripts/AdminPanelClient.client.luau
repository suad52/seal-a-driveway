--!strict
--[[
	AdminPanelClient -- a desk for handing things out from inside the game.

	F2 opens it, for whoever the SERVER lets in. The id list below is a courtesy so
	the panel does not appear for people it would only refuse: it decides whether
	the UI is built, and NOTHING ELSE. Every grant is authorised on the server
	against its own copy of that list -- see UpgradeService's ADMINS -- because an
	id checked on a client is a suggestion, not a permission. Deleting this whole
	file would not let anybody grant themselves a penny.

	WHY A TEXT BOX AND NOT A LIST OF BUTTONS. What gets handed out is decided case
	by case: a player who lost a session wants their levels back, a contest winner
	wants cash, a bug report might be worth a skin. A grid of preset buttons would
	be wrong for all three, and the payload the server accepts is small enough to
	type. "Tank=16, Blade=20" is both the shortest way to say it and the shape the
	server already understands.

	The server answers with what actually happened -- "they already have all of
	that", "queued, they get it on their next join" -- and that answer is printed
	verbatim rather than being turned into a tick. This panel moves other people's
	progress around; it should never be the thing that decides it went well.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local plr = Players.LocalPlayer

-- Mirrors UpgradeService.ADMINS. Out of step, the worst that happens is a panel
-- that opens and is refused, or one that never opens for somebody entitled to it.
local ADMINS: { [number]: boolean } = {
	[1210700083] = true,   -- IsABigBot, the owner
	[139112508]  = true,   -- Endey678
	[3159364800] = true,   -- sooad_sooad
	[254153724]  = true,   -- imad166
}
if not ADMINS[plr.UserId] then return end

local Pack = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(Pack:WaitForChild("UIKit"))
-- the palette lives on UIKit itself; there is no separate Theme module
local T = UIKit.Theme

local remotes = Pack:WaitForChild("Remotes")
local AdminGrant = remotes:WaitForChild("AdminGrant", 30)
if not (AdminGrant and AdminGrant:IsA("RemoteFunction")) then
	warn("[AdminPanel] no AdminGrant RemoteFunction -- is the server build current?")
	return
end

local gui = Instance.new("ScreenGui")
gui.Name = "AdminPanel"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 50
gui.Enabled = false
gui.Parent = plr:WaitForChild("PlayerGui")

local holder, content, root = UIKit.panel(gui, UDim2.fromScale(0.42, 0.62),
	UDim2.fromScale(0.5, 0.5), "ADMIN DESK", T.purple)
UIKit.closeButton(root, function() gui.Enabled = false end)
local list = UIKit.scroller(content, 10)

--[[
	One labelled text box. UIKit has no field of its own -- nothing else in the
	game asks the player to type -- so this is the smallest thing that behaves.
]]
local function field(name: string, placeholder: string, order: number): TextBox
	--[[
		Z 8 AND 9, copied from UIKit.toggle rather than left at the default.

		A panel is not a flat surface: UIKit.panel lays a well and a backdrop inside
		the frame it hands back, and both sit above ZIndex 1. Raw instances parented
		into it therefore render BEHIND the panel and are perfectly invisible -- which
		is exactly what these five fields did on their first run, while the GRANT
		button beside them showed up fine because UIKit.button sets its own.
	]]
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 58)
	row.BackgroundTransparency = 1
	row.ZIndex = 8
	row.LayoutOrder = order
	row.Parent = list

	local cap = UIKit.label(row, name, 15, T.slate)
	cap.Size = UDim2.new(1, 0, 0, 18)
	cap.TextXAlignment = Enum.TextXAlignment.Left
	cap.ZIndex = 9

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 0, 34)
	box.Position = UDim2.fromOffset(0, 22)
	box.ZIndex = 9
	box.BackgroundColor3 = T.ink
	box.BackgroundTransparency = 0.15
	box.TextColor3 = T.cream
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = T.slate
	box.Font = Enum.Font.Gotham
	box.TextSize = 17
	box.ClearTextOnFocus = false
	box.Text = ""
	box.Parent = row
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = box
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = box
	return box
end

local who      = field("PLAYER", "exact Roblox username", 1)
local cashBox  = field("CASH", "e.g. 1000000", 2)
local upBox    = field("UPGRADES", "e.g. Tank=16, Blade=20", 3)
local rbBox    = field("REBIRTHS", "raise to, e.g. 5", 4)
local skinBox  = field("SKINS", "skin ids, comma separated", 5)

local status = UIKit.label(list, "", 15, T.slate)
status.Size = UDim2.new(1, 0, 0, 44)
status.TextWrapped = true
status.ZIndex = 9
status.LayoutOrder = 7

-- "Tank=16, Blade=20" -> { Tank = 16, Blade = 20 }. Silently ignores anything
-- malformed; the server clamps every level to its own track anyway, and an
-- unknown track id simply matches nothing there.
local function parseUpgrades(text: string): { [string]: number }
	local out: { [string]: number } = {}
	for id, lv in text:gmatch("(%a+)%s*=%s*(%d+)") do
		out[id] = tonumber(lv) :: number
	end
	return out
end

local function parseList(text: string): { string }
	local out: { string } = {}
	for word in text:gmatch("[^,%s]+") do out[#out + 1] = word end
	return out
end

local busy = false
UIKit.button(list, "GRANT", UDim2.new(1, 0, 0, 46), T.purple, function()
	if busy then return end
	local target = (who.Text:gsub("^%s*(.-)%s*$", "%1"))
	if target == "" then
		status.Text = "Name a player first."
		status.TextColor3 = T.red
		return
	end

	local payload: { [string]: any } = {}
	local cash = tonumber(cashBox.Text)
	if cash and cash > 0 then payload.cash = math.floor(cash) end
	local ups = parseUpgrades(upBox.Text)
	if next(ups) ~= nil then payload.upgrades = ups end
	local rb = tonumber(rbBox.Text)
	if rb then payload.rebirths = math.floor(rb) end
	local skins = parseList(skinBox.Text)
	if #skins > 0 then payload.skins = skins end

	if next(payload) == nil then
		status.Text = "Nothing filled in."
		status.TextColor3 = T.red
		return
	end

	busy = true
	status.Text = ("Sending to %s..."):format(target)
	status.TextColor3 = T.slate
	-- pcall because InvokeServer rethrows anything the handler throws, and a dead
	-- panel with no explanation is the worst outcome for a tool used this rarely
	local ok, res, msg = pcall(function()
		return (AdminGrant :: RemoteFunction):InvokeServer(target, payload)
	end)
	busy = false
	if not ok then
		status.Text = "Failed: " .. tostring(res)
		status.TextColor3 = T.red
		return
	end
	status.Text = tostring(msg)
	status.TextColor3 = if res then T.green else T.red
	if res then
		-- Cleared only on success, and only the amounts. The NAME stays, because
		-- the common next action is giving the same person something else.
		cashBox.Text, upBox.Text, rbBox.Text, skinBox.Text = "", "", "", ""
	end
end).LayoutOrder = 6

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.F2 then
		gui.Enabled = not gui.Enabled
	elseif input.KeyCode == Enum.KeyCode.Escape and gui.Enabled then
		gui.Enabled = false
	end
end)

print("[AdminPanel] ready -- F2 opens the admin desk")
