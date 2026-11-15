--!strict
--[[
	Leaderboards -- the three boards in the depot courtyard, defined once.

	This is the single registry, the same shape as Sections.List: the server
	reads it to know which OrderedDataStore to write and which attribute to write
	into it, and the client reads it to know which board to draw the answer on.
	Adding a fourth board is an entry here plus a slab in the world -- nothing in
	either of the other two files names a board.

	WHY THESE THREE STATS AND NOT leaderstats.

	`Cash` is a wallet: it goes DOWN every time somebody buys an upgrade, so a
	board built on it ranks players who have not spent anything. `Q_Earned` is the
	lifetime total, only ever incremented -- by DrivewayServer when a job pays and
	by AfkService when the yard does -- which is what "most money earned" means.
	Same reasoning for jobs: `Q_Sealed` is incremented once per driveway finished
	and is never reset, not even by a rebirth, while leaderstats.Sealed is rebuilt
	from nothing every join.

	All three already persist through UpgradeService's profile, so a board can
	never disagree with the number the player sees on their own HUD.
]]

local Leaderboards = {}

-- How many places each board ranks. OrderedDataStore pages cap at 100 per
-- request, so this is also one GetSortedAsync page and no pagination.
Leaderboards.TopN = 100
--[[
	Rows drawn at once; the board pages through TopN / PageSize screens.

	10 rather than 20. The board is read from several studs away across a
	courtyard -- and from the far side of a fence -- so the row height is set by
	legibility at distance and the count falls out of it, not the other way round.
	Twenty rows on the original panel left each one 28 pixels tall: fine with your
	nose against it, a grey smear from anywhere else. Ten rows on the shorter
	panel gives 52, which carries 28-30pt names.

	The cost is ten pages instead of five to walk the whole hundred, which is the
	honest trade for a board you can actually read. It also makes the paging read
	cleanly -- ten exact pages, "91 - 100 of 100" on the last one.
]]
Leaderboards.PageSize = 10

-- Where the server publishes the answer, and where the boards live.
Leaderboards.DataName = "LeaderboardData"   -- StringValue under SealerUI
Leaderboards.Container = "Leaderboards"     -- Folder in Workspace

export type Board = {
	id: string,
	title: string,
	caption: string,
	attr: string,
	store: string,
	money: boolean?,
}

--[[
	The store names are versioned and must never be reused for a different stat.

	An OrderedDataStore key is a UserId and its value is whatever was last written
	there; point a board at an existing name and it inherits that history under a
	new heading. If a stat's MEANING ever changes -- Q_Earned starting to count
	something else, say -- bump the _v and the board starts clean rather than
	ranking two different quantities against each other.
]]
Leaderboards.List = {
	{
		id = "Earned",
		title = "TOP EARNERS",
		caption = "LIFETIME MONEY EARNED",
		attr = "Q_Earned",
		store = "SealerLB_Earned_v1",
		money = true,
	},
	{
		id = "Rebirths",
		title = "MOST REBIRTHS",
		caption = "LAPS OF THE NEIGHBOURHOOD",
		attr = "Rebirths",
		store = "SealerLB_Rebirths_v1",
	},
	{
		id = "Jobs",
		title = "MOST JOBS",
		caption = "DRIVEWAYS SEALED",
		attr = "Q_Sealed",
		store = "SealerLB_Jobs_v1",
	},
} :: { Board }

Leaderboards.ById = {} :: { [string]: Board }
for _, b in ipairs(Leaderboards.List) do
	Leaderboards.ById[b.id] = b
end

--[[
	What this player would be ranked on right now.

	Floored and clamped at zero because an OrderedDataStore value has to be a
	signed integer: a fractional or negative write throws, and the throw would
	take the whole publish pass down with it rather than skipping one player.
]]
function Leaderboards.valueOf(plr: Player, board: Board): number
	local v = plr:GetAttribute(board.attr)
	if type(v) ~= "number" or v ~= v then return 0 end
	return math.max(0, math.floor(v))
end

-- The board's own name for a rank, so the client never hardcodes "#".
function Leaderboards.rankText(rank: number): string
	return "#" .. rank
end

--[[
	How a value reads on the board.

	Money is abbreviated and counts are not, and the split is deliberate: $8.25M
	is the number a player wants for a wallet, but "1.84K jobs" is a worse answer
	than "1,840" -- a job count is something you compare exactly against your own,
	and rounding it to three significant figures makes ranks 40 and 41 read as a
	tie. Rebirths never get near a thousand and come out unchanged either way.
]]
local function commas(n: number): string
	local s = tostring(math.floor(n))
	local k
	repeat
		s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end

function Leaderboards.display(board: Board, value: number): string
	if board.money then
		local Upgrades = require(script.Parent:WaitForChild("Upgrades"))
		return "$" .. Upgrades.short(value)
	end
	return commas(value)
end

return Leaderboards
