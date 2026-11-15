--!strict
--[[
	AfkBus -- how something that MOVES A PLAYER tells the yard to let go of them.

	The AFK yard is a visit: AfkService holds a plot for the player, pays them by
	the second, and AfkClient drives their character up and down a driveway with
	their own movement input sunk. Every route out of that clears one attribute
	and everything unwinds from it -- the sign, the rail button, dying, leaving.

	The Squeegee Battle is a route out that none of those cover. It teleports an
	opted-in player six thousand studs the OTHER way, into the arena, and until
	this file existed it did so without telling the yard: the visit stayed open,
	so the puppet kept walking the character back toward a driveway that was no
	longer under it, the movement sink kept the player's own keys swallowed, and
	the per-frame re-equip kept taking the squeegee out of their hands. From the
	inside that is a player who readied up, arrived, and could not move or paint.

	WHY IT ANSWERS A CFrame. Ending the visit is only half the job. A battle takes
	a snapshot so it can put everybody back where it found them, and where it
	finds an idler is a plot in the yard -- so restoring to it would land them in
	the yard with no visit, not earning and not being walked, with the yard's own
	LeavePad prompt a no-op because that prompt only ends a visit that exists. The
	yard already knows the right answer (where they were standing when they went
	idle, with its own fallback applied), so it hands it over rather than making
	the caller guess.

	One-way, like EventBus and RebirthBus, and for the same reason: the yard and
	the arena are two large systems that must not require each other. AfkService
	registers what it can do, whoever is moving the player asks for it.
]]

local AfkBus = {}

-- Ends the player's visit WITHOUT moving them -- the caller is doing that --
-- and answers where the yard would have sent them home to, or nil if they were
-- not in it.
type Release = (Player) -> CFrame?

local release: Release? = nil

function AfkBus.provide(fn: Release)
	release = fn
end

--[[
	"I am about to move this player; if the yard has them, let go."

	Safe to call for anybody -- nil back means they were not idling, which is the
	ordinary answer -- so a caller can ask unconditionally rather than testing the
	attribute first and then acting on it, which is two places to keep one rule.

	Wrapped, because this is called on the path that teleports players into a
	match: a throw inside the yard's own bookkeeping must not take the match down
	with it. A failure here costs the caller its return spot, and that is all.
]]
function AfkBus.wake(plr: Player): CFrame?
	local fn = release
	if not fn then return nil end
	local ok, home = pcall(fn, plr)
	if not ok then
		warn("[AfkBus] the yard would not release " .. plr.Name .. ": " .. tostring(home))
		return nil
	end
	return home
end

return AfkBus
