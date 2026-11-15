--!strict
--[[
	RebirthBus -- UpgradeService says "this player just rebirthed", DrivewayServer
	hears it. One sentence, and it replaces a guess.

	DrivewayServer used to INFER a rebirth from the Rebirths attribute changing,
	which is not the same fact and cost every player with a rebirth behind them
	their sealed record on every single join. The attribute also moves when the
	profile is restored, and GetAttributeChangedSignal is DEFERRED -- so the
	handler ran after markLoaded had set ProfileLoaded, and the guard that existed
	to tell a restore from a rebirth was reading a flag that had already flipped.
	A second guard comparing the count against the last seen value failed the same
	way: the baseline was captured before the restore, so 0 -> 3 looked like three
	rebirths at once.

	Measured from the recorder on 2026-08-11:

		restore-now      now=2  rb=3  loaded=nil
		load-done        now=2  rb=3  loaded=true
		rebirth-attr     now=2  rb=3  loaded=true  was=0 count=3 wipe=true
		SAVE             now=0

	No ordering makes an inference safe here, because the signal that carries it
	arrives at a time neither script chooses. So the rebirth is announced by the
	one place that actually performs it, and nothing else can be mistaken for it.

	Server-side on purpose: this is a fact about the ledger, and no client has any
	business firing it.
]]

local RebirthBus = {}

local ev = Instance.new("BindableEvent")

-- Fired with the Player, once, by UpgradeService's DoRebirth handler and by
-- nothing else.
RebirthBus.Event = ev.Event

function RebirthBus.fire(plr: Player)
	ev:Fire(plr)
end

return RebirthBus
