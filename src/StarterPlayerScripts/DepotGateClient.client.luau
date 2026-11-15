--!strict
--[[
	DepotGateClient -- takes this player's doors away once they have been earned.

	Both doors are server-owned and neither ever moves there; see DepotGate for why
	the change is local. Writing to a replicated instance from a client changes only
	this client's copy, which is exactly the per-player behaviour wanted: the player
	who sealed the apron walks out through a gap in the wall while anyone who has
	not still sees a shut gate.

	--[ why they are DELETED rather than opened ]------------------------------

	They used to swing and roll: the yard gate pivoted its two leaves through 104
	degrees, and the bay door lifted twelve slats one at a time into the header.
	Both animations are gone, and with them three separate replication bugs that
	all had the same shape and all presented as "the door just never opened".

	The shape: an animation has to know the pieces it is animating, so both doors
	enumerated instances at load -- the gate read LeafL and LeafR and measured a
	bounding box off each, the shutter collected its slats. Replication does not
	deliver a model and its contents together. The model arrives, the enumeration
	finds nothing or finds a half-built bounding box, and the animation then runs
	perfectly over the wrong data and latches itself as done. Every flag correct,
	nothing in the log, door shut. It broke only for players whose profile came
	back FAST -- an unrelated wait further up hid it the rest of the time -- so it
	looked intermittent and got worse the better the DataStore behaved.

	Deleting needs to know nothing about what is inside. It touches one instance,
	the one thing WaitForChild can actually promise, so there is nothing left to
	race. A door that has been earned is not scenery the player will look at again;
	it is a wall that should stop being in the way.

	Each door still keeps its own condition and neither knows about the other. As
	of 2026-08-11 both conditions happen to land together -- the depot apron stopped
	being a second stage, so DepotGate sets TutorialDone and DepotSealed in the same
	breath and the two doors come off the same frame. The pairing is deliberately
	NOT expressed here: tying them together on this side would mean unpicking it
	again the day a door earns its own condition back, and the server is the one
	place that decides what has been earned.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundKit = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("SoundKit"))

local plr = Players.LocalPlayer

-- Named for what it used to mean ("the depot apron is sealed"); it now means the
-- tutorial is finished. Kept because every saved profile stores it under this
-- key -- see the note over DepotGate's own ATTR.
local ATTR = "DepotSealed"        -- the yard gate goes
local TUT_DONE = "TutorialDone"   -- driveway sealed and an upgrade bought; the bay door goes

local hood = workspace:WaitForChild("Neighbourhood", 30)
local depot = hood and hood:WaitForChild("Depot", 30)
if not depot then return end

--[[
	Wait for the saved profile before anything is taken away.

	Both doors ask "has this player earned it" the moment the script runs, and the
	answer arrives from the DataStore a second or two after the client does.
	Without this the attribute is always nil at that point, so a returning player
	never takes the silent path -- the flag lands a moment later, the changed
	signal fires, and both doors announce themselves on every single rejoin. The
	progress was never lost, but the reveal replayed as if the tutorial had just
	been finished again.

	Same signal and the same timeout TutorialClient waits on, for the same reason;
	the timeout is what keeps a place with no DataStore access working.

	It also re-reads the attribute each turn rather than trusting the connection
	alone: the flag can land in the gap between the check above and the connect
	below, and a signal that already fired never fires again. Missing it used to
	cost the full twelve seconds of the timeout, which is most of the "sometimes
	it is just slow" this file was reported for.
]]
if not plr:GetAttribute("ProfileLoaded") then
	local ready = false
	local conn = plr:GetAttributeChangedSignal("ProfileLoaded"):Connect(function()
		ready = true
	end)
	local t0 = os.clock()
	while not ready and not plr:GetAttribute("ProfileLoaded") and os.clock() - t0 < 12 do
		task.wait(0.1)
	end
	conn:Disconnect()
end

--[[
	Take one thing away, whenever both halves of the answer happen to arrive.

	Three orderings are possible and none of them is worth reasoning about at the
	call site, so all three are handled here: the thing is already present and
	already earned (the returning player), the thing replicates in after the flag
	(a slow world), or the flag lands while the player stands there watching (the
	moment it is actually earned). Every path funnels through the same `take`, and
	Destroy on something already gone is a no-op, so re-entry costs nothing.

	`live` is only true on the last of those. A door earned while you are stood at
	it is worth hearing go; one that was earned last week is not, and playing the
	clunk on every rejoin is exactly the noise the profile wait above exists to
	prevent. The sound goes on the player rather than on the door because the door
	is about to stop existing and a Sound inside it would be destroyed mid-note.
]]
local function retire(container: Instance, name: string, attr: string)
	local function take(live: boolean)
		if plr:GetAttribute(attr) ~= true then return end
		local thing = container:FindFirstChild(name)
		if not thing then return end
		if live then
			local ch = plr.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then SoundKit.play("ValveThunk", hrp, 0.06, 0.9) end
		end
		thing:Destroy()
	end

	container.ChildAdded:Connect(function(c)
		if c.Name == name then take(false) end
	end)
	plr:GetAttributeChangedSignal(attr):Connect(function() take(true) end)
	take(false)
end

--[[
	The two doors, and the two signs that were telling you to open them.

	The notices go with their own door rather than being hidden in place, which is
	what the old code did and did badly -- the yard notice was guarded on being a
	BasePart and quietly stayed up for anyone whose sign was built as a model. A
	sign whose instruction has been carried out is the same kind of clutter the
	door is.
]]
retire(depot, "YardGate", ATTR)
retire(depot, "RollShutter", TUT_DONE)

local wall = depot:WaitForChild("YardWall", 30)
if wall then
	retire(wall, "Notice", ATTR)
	retire(wall, "TutorialNotice", TUT_DONE)
end
