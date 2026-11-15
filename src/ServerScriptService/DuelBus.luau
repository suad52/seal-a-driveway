--!strict
--[[
	DuelBus -- how DuelServer borrows the Squeegee Battle arena for a 1v1.

	One function, one provider, and the same shape as EventBus: the file that OWNS
	a thing registers how to run it, and the file that WANTS it asks through here.
	Neither has to require the other, which matters more than usual in this case --
	DuelServer and SqueegeeBattleServer are both Scripts, and a Script cannot be
	required at all.

	WHY THE DUEL DOES NOT IMPLEMENT SQUEEGEE BATTLE ITSELF

	Because it already exists, and it is a thousand lines of arena, canvas, grid,
	stroke validation, ownership buffer, renderer and results screen that two
	players would be running a second, worse copy of. The brief for this mode is
	literally "utilises the existing squeegee combat mechanics" -- so it uses them,
	rather than a re-implementation that would drift out of step with the arena the
	same players see in the scheduled event.

	What a duel changes about a match is exactly two things: WHO is in it (a fixed
	pair rather than whoever opted in) and WHAT IT PAYS (the duel purse, to the
	winner, instead of the placing table to everybody). Both are arguments.

	THE ONE REAL CONSTRAINT, AND IT IS WORTH SAYING OUT LOUD

	There is exactly ONE arena, and the scheduled event owns it. So at most one
	Squeegee Battle duel can be running at a time, and none at all while the
	scheduled event is mid-match. `runDuel` answers false in that case rather than
	queueing -- two players standing in the depot waiting an unknown number of
	minutes for an arena is worse than being told to pick another mode, and
	DuelServer turns the false into exactly that sentence.

	The two sealing modes have no such limit: they build their own ground. See
	DuelArena.
]]

local DuelBus = {}

-- Returns (ran, paid): whether the match happened at all, and how much actually
-- landed in the winner's wallet. The second half matters -- see runDuel.
type Runner = (a: Player, b: Player, prize: number) -> (boolean, number)

local duel: Runner? = nil

--[[
	Registered by SqueegeeBattleServer at startup.

	`run` must BLOCK for the whole match -- DuelServer is holding the duel's slot,
	the two players' saved positions and its own state machine open across the
	call, exactly as EventHandler holds a scheduler slot across runBattle. It must
	return false without touching either player if it cannot run at all, and true
	only once both are home again.

	It is also responsible for PAYING: it has the score, and the score is the only
	thing that decides a winner. `prize` is what the winner gets, already gated and
	frozen by DuelEconomy -- the arena does not get a say in the sum, only in who
	it goes to, and in whether the match ended in a state worth paying for at all.

	So it reports back what it MOVED rather than what it was handed. A duel that
	ended with somebody having walked out pays nothing, and DuelServer must not
	spend one of the pair's three allowances on it.
]]
function DuelBus.provideDuel(run: Runner)
	duel = run
end

--[[
	Run one 1v1 in the arena. Blocks for the whole match.

	First return false means it could not be run at all -- no provider, the arena is
	busy, or one of the two stopped being eligible between the accept and here --
	and the caller still owns both players and has to tell them so.

	Second return is what actually reached a wallet, which is not always `prize`:
	zero if somebody left, if the match errored, or if the caller passed zero
	because the purse was gated. The caller spends its allowance on THAT.
]]
function DuelBus.runDuel(a: Player, b: Player, prize: number): (boolean, number)
	local r = duel
	if not r then return false, 0 end
	return r(a, b, prize)
end

--[[
	Whether a duel could be started right now, asked WITHOUT starting one.

	DuelServer checks this at the CHALLENGE and again at the ACCEPT, so a player is
	told the arena is busy before they send the card rather than after their
	opponent has agreed to a match that cannot happen. Two refusals of one thing,
	because a scheduled event can open in the twenty seconds between them.
]]
local ready: (() -> boolean)? = nil

function DuelBus.provideReady(fn: () -> boolean)
	ready = fn
end

function DuelBus.arenaFree(): boolean
	local f = ready
	if not f then return false end
	return f()
end

return DuelBus
