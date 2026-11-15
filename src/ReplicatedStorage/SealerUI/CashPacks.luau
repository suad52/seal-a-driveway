--!strict
--[[
	CashPacks -- buying cash outright, in fixed increments.

	ONE module for both sides, for the reason Passes and Boosts give about
	themselves: the shop draws the figure and the server pays it, and an amount
	written down in two places is one that will eventually disagree with itself.

	Each pack is a DEVELOPER PRODUCT, not a game pass, and that is what makes it a
	pack rather than an upgrade: there is no owned state, so it can be bought again
	and again, and the product IS the purchase -- the receipt cannot be ambiguous
	about what was asked for. That is the same shape the boosts and the skins have,
	and it is why all three are answered in the same place. See the grant in
	UpgradeService's ProcessReceipt.

	⚠ THE PRODUCT IDS ARE PLACEHOLDERS AND NOTHING IS ON SALE UNTIL THEY ARE REAL.
	A pack with `productId = 0` is drawn with a SOON pill that refuses to open a
	purchase dialog, exactly as an unlisted game pass is -- see Passes, which has
	carried the same rule since it shipped. Create the five products on the
	creator dashboard, paste the ids in below, and nothing else has to change: the
	server recognises whatever is in this list and the shop draws whatever is in
	this list.

	The AMOUNTS are a first pass and are meant to be argued with. They are sized
	off the economy as it stands -- a neighbourhood driveway pays about 1,350, and
	the upgrade ladder runs to ten million -- so the ladder below spans "a few
	jobs' worth" to "the top of a track", roughly doubling the cash per Robux as it
	climbs, which is the shape that makes the big pack the obvious one.
]]

local CashPacks = {}

export type Pack = {
	id: string,
	name: string,
	amount: number,
	productId: number,
	--[[
		What this product is MEANT to cost, in Robux.

		Not the price the shop draws -- that comes from GetProductInfo, because the
		dashboard is the only thing that actually decides what a player is charged and
		a figure typed in here would go stale the first time it is retuned. This is
		the number to CREATE the product with, kept beside the amount it buys so the
		two can be read together, and checked against the live price at startup so a
		price typed into the wrong product is caught rather than discovered.
	]]
	robux: number,
	blurb: string,
	-- What the shop prints on the ribbon, if anything. Nil for the quiet ones.
	ribbon: string?,
}

--[[
	The ladder. Order here is selling order in the shop.

	`amount` is FLAT -- see the note over the grant in UpgradeService about why no
	multiplier touches it.

	PRICED AGAINST WHAT THIS GAME ALREADY CHARGES, not against a genre habit. The
	anchors, all of them real prices in this place today:

		2x Reward (doubles a lump, floor 1,000)          20 R
		one upgrade rung, whatever it costs in cash       34 R
		Instant Coat, five minutes                        49 R
		2x Cash, permanent                                99 R
		Starter Rig -- the Dart, which costs 250,000 cash 199 R
		Permanent Cyberseal                              499 R

	And the cash side, which is what stops this being guesswork: the first rung of
	any track is 1,200-1,900, the LAST rungs run 9.5M to 87.5M, the four trucks are
	250K / 1.2M / 5M / 25M, and buying every rung in the game costs 252 MILLION. A
	neighbourhood driveway pays about 1,350.

	So the ladder below runs 1,000 cash per Robux at the bottom to about 10,000 at
	the top:

		Pocket Wad     25K     25 R    1,000 /R   ~18 driveways
		Bank Roll     100K     75 R    1,333 /R
		Briefcase     500K    199 R    2,513 /R   the Dart twice over
		Cash Pallet   2.5M    499 R    5,010 /R
		The Vault      10M    999 R   10,010 /R   ~4% of the whole ladder

	Two things that spread is deliberately answering. The top pack has to be worth
	climbing to or nobody climbs, which is why the rate rises tenfold across it --
	steeper than the 2-4x this genre usually runs. And the ceiling is high enough
	to carry it: 10M sounds enormous and is four percent of the full ladder, so
	even the biggest pack cannot buy the endgame. Cut the rate and the small packs
	stop being worth listing; raise the amounts and the late ladder stops mattering.

	The Briefcase is the one to watch when retuning: at 199 R it sits on the Starter
	Rig's price and hands over twice that truck's cash, which is the right way round
	only because the pass survives a rebirth and the cash does not.
]]
CashPacks.List = {
	{ id = "Wad",       name = "Pocket Wad",   amount = 25_000,    robux = 19,  productId = 3710203223,
	  blurb = "A few driveways' worth, straight into the wallet." },
	{ id = "Roll",      name = "Bank Roll",    amount = 100_000,   robux = 29,  productId = 3710203249,
	  blurb = "Enough to jump a whole upgrade track a rung or two." },
	{ id = "Case",      name = "Briefcase",    amount = 500_000,   robux = 129, productId = 3710203267,
	  blurb = "Half a million. Buy the truck instead of saving for it.",
	  ribbon = "POPULAR" },
	{ id = "Pallet",    name = "Cash Pallet",  amount = 2_500_000,  robux = 399, productId = 3710203315,
	  blurb = "Two and a half million, shrink-wrapped." },
	{ id = "Vault",     name = "The Vault",    amount = 10_000_000, robux = 699, productId = 3710203360,
	  blurb = "Ten million. The top of every ladder in the game.",
	  ribbon = "BEST VALUE" },
} :: { Pack }

CashPacks.ById = {} :: { [string]: Pack }
for _, pack in ipairs(CashPacks.List) do
	CashPacks.ById[pack.id] = pack
end

--[[
	Which pack a receipt is for, or nil.

	Nil for anything unrecognised is the whole point of the shape: a receipt this
	file cannot claim must fall through to the other sellers rather than be
	answered wrongly. Zero is never a match, so an unlisted pack cannot claim the
	receipts of a product that does not exist yet -- and every unlisted pack shares
	that id, which is exactly the collision this guard prevents.
]]
function CashPacks.byProduct(productId: number?): Pack?
	if not productId or productId == 0 then return nil end
	for _, pack in ipairs(CashPacks.List) do
		if pack.productId == productId then return pack end
	end
	return nil
end

--[[
	The amount, short enough to sit on a card: $25K, $2.5M.

	Here rather than in the shell because the SERVER says it too, in the toast that
	confirms the grant, and a purchase that is announced in one format and drawn in
	another reads as two different numbers.
]]
function CashPacks.short(amount: number): string
	if amount >= 1000000 then
		local m = amount / 1000000
		-- no trailing ".0" on the round ones: "$10M", not "$10.0M"
		return if m % 1 == 0 then ("$%dM"):format(m) else ("$%.1fM"):format(m)
	end
	if amount >= 1000 then
		local k = amount / 1000
		return if k % 1 == 0 then ("$%dK"):format(k) else ("$%.1fK"):format(k)
	end
	return ("$%d"):format(amount)
end

return CashPacks
