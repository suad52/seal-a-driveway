--!strict
--[[
	Tutorial -- "is this player still being taught?", asked in one place.

	THIS MODULE WRITES NOTHING. The flag is DepotGate's: it sets TutorialDone the
	moment the first driveway is sealed AND the first upgrade is bought, and
	UpgradeService persists it under that key. This is the read side, and it
	exists because four unrelated systems now have to ask the question -- the two
	special events, their shared countdown and the payout -- and every one of them
	was a bare GetAttribute away from getting it subtly wrong.

	WHY inProgress IS NOT SIMPLY `not isDone`, WHICH IS THE WHOLE OF THIS FILE.

	TutorialDone arrives from the DataStore a moment AFTER the client does. The
	note over UpgradeService's PROFILE_READY says so in as many words, and it is
	the reason that attribute exists at all: for the first second or two of every
	session a veteran of five hundred driveways reads exactly like somebody who
	has never held a squeegee. Anything that suppresses a feature off a bare
	`not isDone` suppresses it for them too.

	So the answer has THREE states, not two -- done, not done, and not known yet --
	and the two predicates below differ only in which way they resolve the third.
	Which one to reach for is decided by what is being gated:

	  inProgress   for taking something AWAY (the sky, a countdown, a multiplier).
	               Not knowing reads as NOT in the tutorial, so the worst case is
	               a returning player briefly KEEPS a bonus they are entitled to.

	  isDone       for letting somebody IN (the battle invitation, and the seat it
	               leads to). Strictly `== true`, so not knowing reads as not
	               eligible: the worst case is a returning player waits a second
	               for an invitation, rather than a first-timer being teleported
	               six thousand studs out of their tutorial.

	Anything DRAWN off this wants neither on its first frame -- it wants to draw
	nothing at all until the answer exists, or it flickers whichever predicate it
	picked. That is what `await` is for; see GoldenHourClient and
	SqueegeeBattleClient, which both hold their first paint behind it.

	The flag only ever goes false -> true. It survives a rebirth (deliberately --
	see DrivewayServer) and nothing in the game clears it, so no caller has to
	handle a player becoming ineligible again half way through something.
]]

local Tutorial = {}

-- DepotGate's, and UpgradeService persists it. The name is load-bearing in
-- every saved profile -- see the note over DepotGate's own copy of it.
Tutorial.DoneAttr = "TutorialDone"
-- UpgradeService's "stop waiting for me". True once the profile has landed OR
-- the read has failed for good, which is why it is the honest test for "the
-- answer is knowable" rather than "the answer is yes".
Tutorial.ReadyAttr = "ProfileLoaded"

local DONE = Tutorial.DoneAttr
local READY = Tutorial.ReadyAttr

--[[
	Has this player finished the tutorial, so far as anyone can tell right now?

	Explicitly `== true` for the reason Passes.owns gives about itself: the
	attribute may be nil because it has not replicated yet, and "not yet" must
	read as "no" rather than as anything else. Use this to let somebody IN.
]]
function Tutorial.isDone(plr: Player?): boolean
	return plr ~= nil and plr:GetAttribute(DONE) == true
end

--[[
	Is the answer knowable at all yet?

	Exposed because a countdown or a sunset wants to draw NOTHING until this is
	true, rather than pick one of the two answers and correct itself a second
	later in front of the player.
]]
function Tutorial.known(plr: Player?): boolean
	if not plr then return false end
	-- Done implies known: a flag that is already true came from somewhere.
	return plr:GetAttribute(READY) == true or plr:GetAttribute(DONE) == true
end

--[[
	Is this player positively, knowably still in the tutorial? Use this to take
	something AWAY -- see the three-state note at the top.
]]
function Tutorial.inProgress(plr: Player?): boolean
	if not plr then return false end
	if plr:GetAttribute(DONE) == true then return false end
	return plr:GetAttribute(READY) == true
end

--[[
	Yield until the answer exists, then hand it back.

	Twenty seconds is the budget SectionGateClient and LuckyBoardClient already
	allow, and it is well past UpgradeService's own worst case (five GetAsync
	tries with the backoff capped at 2s). It RETURNS on the timeout rather than
	giving up: a session where ProfileLoaded never arrives is broken in its own
	way, and a caller left waiting forever would answer that by silently
	withholding the feature for the rest of it.
]]
function Tutorial.await(plr: Player, timeout: number?): boolean
	local budget = timeout or 20
	local t0 = os.clock()
	while plr.Parent and not Tutorial.known(plr) and os.clock() - t0 < budget do
		task.wait(0.2)
	end
	return Tutorial.inProgress(plr)
end

--[[
	Re-ask whenever the answer could have moved -- which is BOTH attributes.

	The finish is the obvious one. The profile landing is the one that gets
	forgotten, and it is the only signal a returning player gets: their
	TutorialDone arrives already true, and an attribute that arrives true never
	fires its own change signal on the client that was waiting for it.
]]
function Tutorial.onChanged(plr: Player, fn: () -> ()): { RBXScriptConnection }
	return {
		plr:GetAttributeChangedSignal(DONE):Connect(fn),
		plr:GetAttributeChangedSignal(READY):Connect(fn),
	}
end

return Tutorial
