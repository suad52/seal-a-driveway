--!strict
--[[
	RigController -- one player's client-side handle on the sealcoating truck.

	Three jobs, all of which have to be here rather than on the server:

	  Driving. Whoever sits in the seat owns the truck's physics, so they are the
	  only one who can change a motor and have it take effect this frame. A
	  server setting the same hubs would land a round trip late, which on a
	  vehicle is the difference between steering and wrestling.

	  Moving parts. The beacons, agitator, reel and gauge needle are anchored
	  rather than welded -- see TruckBuilder -- and get re-framed off the chassis
	  here. Every client runs this for every truck, so a rig someone else is
	  driving still has its beacons turning.

	  The hose, which it owns outright.

	Shared state is not here. The tank level and who is holding the wand live on
	the server as attributes, because two players working one truck have to agree
	about them.
]]

-- Only for armed(), which reads whether the stock vehicle controls came on.
-- StarterPlayer rather than PlayerScripts on purpose: this place's PlayerModule
-- runs in place under StarterPlayer and is never copied into PlayerScripts.
local StarterPlayer = game:GetService("StarterPlayer")

local Config = require(script.Parent.Config)
local HoseRig = require(script.Parent.HoseRig)
local SoundKit = require(script.Parent.SoundKit)
local RigMarker = require(script.Parent.RigMarker)

local RigController = {}
RigController.__index = RigController

local REEL_RADIUS = 1.42   -- studs; matches the drawn coil

--[[
	How much hose has to be left on the drum for a pull to be allowed.

	The rope is built AT self.hoseMax, so a pull made at exactly that distance is
	legal but taut on its first frame -- the player is stood at the stop before
	they have taken a step. A stud of margin means the hose always comes off the
	reel with somewhere to go.
]]
local DEPLOY_MARGIN = 1.0

--[[
	How high the locator plate floats over the chassis.

	MARKER_LIFT is what it uses before a truck has been measured -- and for a
	truck that has streamed out, where there is nothing left to measure.
	MARKER_CLEAR is the gap left above whatever the rig's own bounding box turns
	out to be: a stock rig stands 7.0 studs over its Base and a Cistern carries a
	bigger barrel on top of that, so the height is taken from the vehicle rather
	than written down. See _bind.
]]
local MARKER_LIFT = 9.2
local MARKER_CLEAR = 2.2

local function approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

function RigController.new(player: Player, fxParent: Instance)
	local self = setmetatable({
		player = player,
		hose = HoseRig.new(fxParent),
		--[[
			The plate that says where you left the truck.

			Held out here rather than inside the bind because it has to survive one:
			a rig far enough away to be worth signposting is a rig this client may no
			longer have a model for at all. See _marker.
		]]
		marker = RigMarker.new(fxParent),
		markerLift = MARKER_LIFT,
		--[[
			The rig's name, REMEMBERED rather than read, for that same reason.

			You always witness your own truck arrive -- it is delivered to the bay or
			to where you are standing -- so by the time one is far enough away to have
			streamed out, its name has already been seen once.
		]]
		rigName = nil :: string?,

		model = nil :: Model?,
		base = nil :: BasePart?,
		seat = nil :: VehicleSeat?,
		outlet = nil :: BasePart?,
		drives = {} :: { HingeConstraint },
		steers = {} :: { HingeConstraint },
		dynamics = {} :: { BasePart },
		rotors = {} :: { BasePart },
		engine = nil :: Sound?,
		pump = nil :: Sound?,

		driving = false,
		wakeClock = 0,
		-- The driver's inputs after smoothing. VehicleSeat hands them over as steps;
		-- these are what the servo and the hub motors actually see. See _drive.
		steerAt = 0,
		driveAt = 0,
		-- the spawned rig's own numbers, stamped on the model by TruckServer;
		-- Config is only the fallback for a rig with no catalogue entry
		topSpeed = Config.TruckTopSpeed,
		hoseMax = Config.HoseMaxLength,
		tankMax = Config.TankCapacity,
		-- Already multiplied out; see where they are read below. Config is the whole
		-- answer for a rig that carries no brakes of its own, which is most of them.
		brake = Config.TruckBrake,
		brakeEase = Config.TruckBrakeEase,
		-- How much faster than the pail's baseline this truck's pump moves sealer.
		-- Deliberately not called `pump`: that name is already the pump SOUND two
		-- fields up, and the two would have quietly overwritten each other.
		pumpRate = 1,
		beaconAngle = 0,
		agitatorAngle = 0,
		--[[
			The front squeegee bar. Starts parked, because a rig called up with its
			blade already on the road would scrub the bay floor on the way out.

			`bladeCF` is where the rubber actually is, derived from the same hinge and
			the same angle the visible parts are re-framed from -- so the line the
			simulation sweeps and the line the player can see cannot drift apart.
		]]
		bladeAngle = math.rad(Config.TruckBladeRaise),
		bladePivot = nil :: Vector3?,
		bladeCF = nil :: CFrame?,
		bladeDown = false,
		--[[
			The spray bar's line, which hangs off the same hinge point and does NOT
			swing with the blade. See _animate for why it is authored rather than
			derived from bladeCF.
		]]
		pourCF = nil :: CFrame?,
		wandRig = nil :: Model?,
		-- The wand is out but the truck is further off than the hose is long, so
		-- there is no hose. See _runHoseOut; the HUD reads it off State.
		wandFar = false,
		-- keeps `dynamics` honest against a truck that is still replicating; see _bind
		late = nil :: RBXScriptConnection?,
		-- How the driver got into the seat, which is not something the default
		-- controls reliably survive. See "THE SEAT YOU CANNOT DRIVE".
		seatHum = nil :: Humanoid?,
		seatWatch = nil :: RBXScriptConnection?,
		reseats = 0,
	}, RigController)

	return self
end

--==[ FINDING YOUR OWN RIG ]==================================================

--[[
	There can be several trucks parked at once -- one per player -- so "the rig"
	is not simply the first model in Workspace called SealcoatRig. It used to be
	exactly that, from when the server kept one rig for the whole session; with a
	rig each, that binds you to whoever spawned first, and you get their beacons,
	their gauge, and your hose paying out of their reel.

	POLLED from Update rather than driven by ChildAdded, and that is the whole
	point. Calling up a different truck destroys one model and creates another in
	the same server frame, and the two halves can reach a client in either order:
	a signal-driven claim that arrives while the old model is still bound drops
	the new one on the floor and then waits forever for an event that has already
	happened. Rebinding is rare and a sweep of Workspace's direct children costs
	nothing beside a frame of the sealer simulation -- and it cannot wedge,
	because whatever it misses this frame it picks up on the next.
]]
function RigController:_mine(): Model?
	local id = self.player.UserId
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name == "SealcoatRig" and child:IsA("Model")
			and child:GetAttribute("OwnerUserId") == id then
			return child :: Model
		end
	end
	return nil
end

--[[
	Commit to a model, or refuse and leave everything nil for the next frame.

	Nothing in here may yield. It is called from Update now, and the WaitForChild
	calls this used to open with would have stalled the whole client's frame loop
	on a model that never finished replicating. A part that has not arrived yet
	is simply "not ready", and the poll above tries again in sixteen
	milliseconds.

	The lists are built locally and only assigned once every piece has been
	found, so a refused attempt cannot leave half a truck bound.
]]
function RigController:_bind(model: Model): boolean
	local theBase = model:FindFirstChild("Base") :: BasePart?
	local theSeat = model:FindFirstChild("Seat") :: VehicleSeat?
	local drivesFolder = model:FindFirstChild("Drives")
	local steersFolder = model:FindFirstChild("Steers")
	if not (theBase and theSeat and drivesFolder and steersFolder) then return false end

	--[[
		Every slot has to RESOLVE, not just some of them.

		These folders hold one ObjectValue per hub -- four driven, two steered -- and
		under StreamingEnabled an ObjectValue can arrive before the HingeConstraint
		it points at, in which case `.Value` reads nil and the loop below silently
		skips it. The old test was `#drives == 0`, so one resolved hub out of four
		was a successful bind -- and binding is a ONE-SHOT: `Update` only looks for a
		model while `self.model` is nil, so a truck that bound short stayed short for
		the rest of the session. A quarter of the torque on the same five tonnes is a
		vehicle that answers the throttle and barely moves, which is indistinguishable
		from "I cannot drive it" and comes and goes with how the map happened to
		stream that time.

		Refusing costs nothing: the poll in Update tries again in sixteen
		milliseconds, and it cannot wedge -- whatever has not replicated this frame
		has by some later one.
	]]
	local function hubs(folder: Instance): ({ HingeConstraint }, number)
		local found: { HingeConstraint } = {}
		local slots = 0
		for _, v in ipairs(folder:GetChildren()) do
			if v:IsA("ObjectValue") then
				slots += 1
				if v.Value then table.insert(found, v.Value :: HingeConstraint) end
			end
		end
		return found, slots
	end
	local drives, driveSlots = hubs(drivesFolder)
	local steers, steerSlots = hubs(steersFolder)
	if #drives == 0 or #steers == 0 then return false end
	if #drives < driveSlots or #steers < steerSlots then return false end

	local dynamics: { BasePart } = {}
	local rotors: { BasePart } = {}
	local pivot: Vector3? = nil
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("RigPos") then
			table.insert(dynamics, d)
			if string.find(d.Name, "BeaconRotor") then table.insert(rotors, d) end
			-- Every swinging blade piece shares one RigPos -- the hinge -- so reading
			-- it off whichever turns up first is reading the hinge itself. Taken from
			-- the part rather than recomputed from Config because `dynamic` rebases it
			-- off the chassis, and a second copy of that arithmetic is a second thing
			-- to get wrong.
			if not pivot and string.find(d.Name, "Blade") then
				pivot = d:GetAttribute("RigPos") :: Vector3
			end
		end
	end

	self.model = model
	self.base = theBase
	self.seat = theSeat
	self.outlet = model:FindFirstChild("ReelOutlet") :: BasePart?
	self.drives, self.steers = drives, steers
	self.dynamics, self.rotors = dynamics, rotors
	self.bladePivot = pivot

	--[[
		AND THE LIST HAS TO HEAL, for the same reason RemoteToolsClient's does.

		The sweep above was a snapshot. A rig is 480-odd descendants and does not
		arrive in one piece, while this function commits on the first frame that has
		a Base, a Seat and the two constraint folders -- so on a rig called up
		MID-SESSION, which is every rig anybody ever buys, it routinely runs with
		most of the truck still in flight.

		Measured on a Bantam Dart called up in a live session: SIX of the twelve made
		the list. The other six were BladeRubber, BladeSkirt, the far BladeArm,
		AgitatorVane, GaugeNeedle and ReelCoilLine -- and because they are ANCHORED,
		being left out does not make them lag or trail. Nothing ever moves them
		again. They stand where they were built, in the bay, while the truck drives
		away: half a squeegee left behind in the garage, and it is your own.

		The hinge is picked up here too. It is read off the first blade piece to turn
		up, so a snapshot with no blade in it leaves bladePivot nil -- and with no
		pivot there is no bladeCF, which means the bar sweeps nothing and the truck
		lays no coat at all.

		One connection per bind, dropped in _release, and nothing per frame.
	]]
	if self.late then self.late:Disconnect() end
	self.late = model.DescendantAdded:Connect(function(d)
		-- a rebind has its own connection and its own lists; appending to the ones
		-- this closure remembers would be writing into a truck that has gone
		if self.model ~= model then return end
		--[[
			THE OUTLET HEALS TOO, and it has to be caught ABOVE the RigPos gate.

			ReelOutlet is cosmetic -- it never moves, so it carries no RigPos -- which
			meant the guard on the next line stepped straight over it and self.outlet
			stayed exactly as the bind snapshot left it. Nil, on any rig that bound
			before its rear end had replicated, FOR THE REST OF THE SESSION.

			That is a dead wand, not a late one. _runHoseOut returns false on its first
			line without an outlet, so the hose never deploys; DrivewayClient gates the
			trigger on `deployed`, so the wand comes out of the dock, poses in the
			player's hands, and sprays nothing at all. Nothing anywhere says why, and
			re-equipping cannot fix it -- SetWand also returns early on a nil outlet.

			Same failure the note above documents for the twelve dynamic parts, in the
			same place, for the same reason: the bind commits on Base + Seat + the two
			constraint folders, and a rig is 480-odd descendants that do not arrive
			together. It is worst on a truck called up MID-SESSION, which is every
			truck anybody ever buys.

			SetWand is re-run because the wand is very often already in their hand by
			now -- they walked up, pressed E, and have been holding a dead one since.
		]]
		if not self.outlet and d:IsA("BasePart") and d.Name == "ReelOutlet" then
			self.outlet = d :: BasePart
			if self.wandRig then self:SetWand(self.wandRig) end
		end
		if not (d:IsA("BasePart") and d:GetAttribute("RigPos")) then return end
		table.insert(self.dynamics, d)
		if string.find(d.Name, "BeaconRotor") then table.insert(self.rotors, d) end
		if not self.bladePivot and string.find(d.Name, "Blade") then
			self.bladePivot = d:GetAttribute("RigPos") :: Vector3
		end
	end)

	-- the rig's own catalogue figure, off the model TruckServer stamped it onto,
	-- so a Longline really does pull 84 and a Dart does not
	self.topSpeed = (model:GetAttribute("TopSpeed") :: number?) or Config.TruckTopSpeed
	self.hoseMax = (model:GetAttribute("HoseMax") :: number?) or Config.HoseMaxLength
	self.tankMax = (model:GetAttribute("TankCapacity") :: number?) or Config.TankCapacity
	self.pumpRate = (model:GetAttribute("Pump") :: number?) or 1
	--[[
		The brakes, MULTIPLIED OUT HERE so the drive loop stays two reads of a number
		rather than two reads and two multiplies at 60Hz.

		Multipliers on Config rather than absolute figures, so a retune of the global
		brake still moves every truck together and a rig only ever states how it
		differs. Absent is 1, which is every truck on the cash ladder -- see
		Rigs.brake for why the pass truck is not, and the Cyberseal's own entry
		there for the arithmetic behind its two numbers.
	]]
	self.brake = Config.TruckBrake * ((model:GetAttribute("Brake") :: number?) or 1)
	self.brakeEase = Config.TruckBrakeEase
		* ((model:GetAttribute("BrakeEase") :: number?) or 1)

	--[[
		Where the locator plate rides, taken from THIS truck rather than typed in: a
		Cistern carries a barrel a Dart does not, and one fixed height would put the
		tag inside it. Floored at MARKER_LIFT because a model still streaming in
		measures short, and a tag through the roof for a frame is a tag that flicks.
	]]
	local bbCF, bbSize = model:GetBoundingBox()
	self.markerLift = math.max(
		(bbCF.Position.Y + bbSize.Y * 0.5) - theBase.Position.Y + MARKER_CLEAR,
		MARKER_LIFT)
	self.rigName = (model:GetAttribute("RigName") :: string?) or self.rigName

	-- A player can pull the wand off the reel before the model has finished
	-- replicating, in which case SetWand found no outlet and did nothing. Now
	-- that there is one, run the hose out for real.
	if self.wandRig then self:SetWand(self.wandRig) end

	local engine = SoundKit.create("TruckEngine", theBase)
	engine.Volume = 0
	self.engine = engine

	local pump = SoundKit.create("PumpIdle", theBase)
	pump.Volume = 0
	self.pump = pump
	return true
end

-- Let go of a truck that has been stored, swapped or destroyed. The hose has to
-- come in with it or it keeps drawing itself to a reel that no longer exists.
function RigController:_release()
	self.hose:Stow()
	if self.late then self.late:Disconnect() self.late = nil end
	self.model, self.base, self.seat, self.outlet = nil, nil, nil, nil
	self.drives, self.steers, self.dynamics, self.rotors = {}, {}, {}, {}
	self.engine, self.pump = nil, nil
	self.driving = false
end

--==[ WAND ]==================================================================

--[[
	Run the hose out, or refuse to -- AND REFUSING IS THE POINT (2026-08-12,
	owner: "it teleports you back").

	Deploy builds a RopeConstraint at the full length of the reel between the
	truck's outlet and the player's root. A rope that is created ALREADY
	over-length is resolved by the solver on its very first frame, and the end it
	moves is the light one: the player. So taking the wand out anywhere beyond the
	hose's reach dragged them back toward the truck, instantly and without warning
	-- a teleport, from the only side that matters.

	The distance is therefore asked BEFORE the rope exists rather than left for
	the solver to discover. Out of reach, nothing is built and nothing moves the
	player; `wandFar` carries the refusal to the HUD, which says so, and
	DrivewayClient holds the trigger shut for as long as it stands -- there is no
	hose, so there is nothing to spray with.

	The test is against the player's root and not the wand's rig, for the reason
	Deploy measures the same way: an unposed wand sits at the world origin.
]]
function RigController:_runHoseOut(): boolean
	local outlet, wandRig = self.outlet, self.wandRig
	if not outlet or not wandRig then return false end
	if self.hose.deployed then return true end

	local hoseEnd = wandRig:FindFirstChild("HoseEnd") :: BasePart?
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (hoseEnd and root and character) then return false end

	if (outlet.Position - (root :: BasePart).Position).Magnitude
		> self.hoseMax - DEPLOY_MARGIN then
		self.wandFar = true
		return false
	end

	self.wandFar = false
	self.hose:Deploy(outlet, hoseEnd :: BasePart, root :: BasePart,
		{ character :: Instance, self.model :: Instance, self.hose.folder }, self.hoseMax)
	SoundKit.play("ReelClick", outlet, 0.12)
	return true
end

-- Called when the wand tool is equipped or put away. Handing the rig the wand's
-- own rig model is enough for it to find the coupling and run the hose out.
function RigController:SetWand(wandRig: Model?)
	self.wandRig = wandRig
	if not wandRig then self.wandFar = false end
	local outlet = self.outlet
	if not outlet then return end

	if wandRig then
		self:_runHoseOut()
	elseif self.hose.deployed then
		self.hose:BeginRetract()
		SoundKit.play("ValveThunk", outlet, 0.06)
	end
end

--==[ THE SEAT YOU CANNOT DRIVE ]=============================================

--[[
	Roblox's own vehicle controls do not always come on, and when they do not the
	rig is dead in the cab: you are sitting in it, the engine is running, the
	beacons are turning, and W does nothing at all.

	The stock PlayerModule arms its VehicleController from one event, and only
	when the seat arrives as the SECOND argument:

		Humanoid.Seated:Connect(function(active, seatPart)
			if active and seatPart and seatPart:IsA("VehicleSeat") then ...

	and `Humanoid.Seated` does not reliably carry it. The weld is made on the
	SERVER -- the Drive prompt sits you, because that is where the ownership
	check has to be -- so this client is told two separate things, that it is
	seated and what it is seated on, and they do not always land together. Sit
	first and the event fires with a NIL seat, the VehicleController is never
	enabled, and nothing ever writes Throttle or Steer. There is no second
	chance: the event does not fire again when the weld catches up, it just
	fills `Humanoid.SeatPart` in quietly behind it.

	Measured in a live session, entering the same rig through the prompt over and
	over: `Seated(true, nil)` on some entries and `Seated(true, Seat)` on others.
	On a nil one, holding W and A for five seconds left `seat.ThrottleFloat` and
	`seat.SteerFloat` at 0.00 and moved the truck 0.03 studs -- while
	`Humanoid.MoveDirection` still read 1.00. The keys were arriving. They had
	nowhere to go. Getting out and back in cleared it, which is exactly what
	"sometimes you cannot drive at all" looks like from the driver's seat.

	Unparking is what turns a rare race into a common one: the prompt calls
	setParked(false) and Sit in the same server frame, so the weld is queued in
	behind ~170 parts coming back into the physics solver.

	The cure is to sit down again from HERE. A Sit issued on this client builds
	the weld in this datamodel first, so the humanoid cannot enter the seat
	without one -- `Seated(true, Seat)`, every time -- and the PlayerModule arms
	itself off that. It costs one frame out of the chair, at a standstill, on the
	frame you climbed in.

	It puts nobody in a seat who was not already in it: the seat is read off
	`Humanoid.SeatPart`, which IS the weld the server has already made. The
	ownership check TruckServer runs before that weld exists is untouched.
]]

--[[
	⚠ THE HEAL ABOVE IS ALSO A WAY TO THROW A PLAYER OUT OF THEIR OWN TRUCK, and
	that is what the two constants under this note and the check at the top of
	_reseat are for. Reported 2026-08-12: "sometimes when I drive and get out then
	try getting back in, it spam kicks me out and eventually lets me in and does
	not let me drive."

	Every word of that is this function. It ejects the driver on purpose -- that is
	how it re-fires Seated with a seat -- and then it has to get them back in. The
	way back in waited TEN FRAMES for `seat.Occupant` to clear, and that is not a
	local fact: the client sets Sit false, the SERVER unwelds, and the cleared
	Occupant comes back over the wire. It is a full round trip. Ten frames is 167
	ms at 60 fps and less at any lower frame rate, which is inside the ping of a
	real session -- so on a live server the loop regularly ran out, `return`ed, and
	left the player standing beside their own truck having just climbed into it.

	Then it repeats, which is the "spam": they press the prompt again, the entry
	races again, this fires again, out they go again. Three of those and
	RESEAT_LIMIT is spent, so the fourth entry sticks -- unhealed, because the
	budget is gone, which is exactly the state this whole block exists to prevent.
	"Eventually lets me in and does not let me drive" is the budget running out.

	Three changes, and the first is the one that matters:

	  1. ASK WHETHER ANYTHING IS ACTUALLY BROKEN before ejecting anybody. A nil
	     seat in the event is a PROXY for "the controls did not arm", and the
	     proxy is not the fact. The fact is readable -- see armed() -- so it is
	     read, a few frames later, once the PlayerModule has had its turn. Most
	     entries turn out to be fine and are now left alone entirely.
	  2. Budget the wait in SECONDS, not frames, because it is a round trip.
	  3. NEVER end this function with the player out of the seat. If the wait
	     expires, sit them down anyway. A driver back in a truck they cannot steer
	     is a bug; a driver standing in the road watching their truck is a worse
	     one, and it is the one they reported.
]]
-- Consecutive heals before this gives up, so a fix that is not fixing anything
-- cannot become a driver flickering in and out of the seat. Any entry that
-- arrives with its seat -- healed or not -- hands the budget back.
local RESEAT_LIMIT = 3
-- Seconds to let the unweld go to the server and the cleared Occupant come back.
-- Sized for a bad connection rather than a good one: the cost of overshooting is
-- that a heal takes a moment longer, and the cost of undershooting was the bug.
local RESEAT_ROUNDTRIP = 2.0
-- Frames to let the PlayerModule handle the same Seated event we did before
-- asking it whether it armed itself. It runs on the same signal, so this is
-- only ever about connection order.
local ARM_GRACE = 4

--[[
	Did the stock vehicle controls actually come on?

	This place runs the InputContext PlayerModule, which keeps the vehicle
	bindings in one instance whose Enabled IS the answer -- it goes true when the
	controller arms on a seated event and false when the driver gets out. It is
	the same property the diagnosis of the original bug was made from.

	nil, not false, when the answer cannot be had: an older PlayerModule has no
	such instance, and "I cannot tell" has to be distinguishable from "it is off"
	by the one caller, which treats unknown as the old unconditional behaviour.
	The lookup is FindFirstChild all the way down for the reason the note in
	AfkClient gives -- PlayerScripts has no copy of PlayerModule in this place, so
	a textbook path finds nothing and a WaitForChild on it never returns.
]]
local function armed(): boolean?
	local pm = StarterPlayer:FindFirstChild("PlayerModule")
	local contexts = pm and pm:FindFirstChild("InputContexts")
	local vehicle = contexts and contexts:FindFirstChild("VehicleContext")
	if not (vehicle and vehicle:IsA("InputContext")) then return nil end
	return vehicle.Enabled
end

function RigController:_reseat(hum: Humanoid)
	self.reseats += 1
	task.spawn(function()
		--[[
			THE CHEAPEST FIX IS NOT DOING IT. Give the PlayerModule its few frames on
			the same event, then ask whether the controls came on anyway -- they very
			often do, and an eject-and-re-seat on a seat that is working is pure cost
			to the player and the whole of the report this note is under.

			The budget is handed back, because nothing was wrong: a run of healthy
			entries must never spend down the allowance that a genuinely broken one
			needs.
		]]
		for _ = 1, ARM_GRACE do
			if not (hum.Parent and hum.Sit) then return end
			task.wait()
		end
		if armed() == true then
			self.reseats = 0
			return
		end
		--[[
			SeatPart is the thing the event failed to hand over, so it is worth
			waiting for rather than guessing at: it lands with the weld, a beat
			behind the Sit that fired this. Standing up before it does is an answer
			too, and the commonest one -- half a second is many times longer than
			this has ever taken.
		]]
		local seat: VehicleSeat? = nil
		for _ = 1, 30 do
			if not (hum.Parent and hum.Sit) then return end
			local sp = hum.SeatPart
			if sp then
				-- an ordinary Seat has no throttle to be missing; leave it alone
				if not sp:IsA("VehicleSeat") then return end
				seat = sp
				break
			end
			task.wait()
		end
		if not seat then return end
		local s = seat :: VehicleSeat

		hum.Sit = false
		--[[
			Getting up is not instant, and it is not LOCAL either -- the unweld goes to
			the server and the cleared Occupant comes back, so how long this takes is
			the player's ping and not this machine's frame rate. Waited in seconds for
			that reason; the ten frames this used to allow were inside the round trip
			of any real connection. See the note over RESEAT_ROUNDTRIP.
		]]
		local deadline = os.clock() + RESEAT_ROUNDTRIP
		while os.clock() < deadline do
			task.wait()
			if not (hum.Parent and hum.Health > 0 and s.Parent) then return end
			if s.Occupant == nil and not hum.Sit then
				--[[
					UNLESS THEY ASKED TO GET OUT.

					This loop is watching for the eject two lines up to land, and a driver
					who left of their own accord looks identical from here: a free seat and
					a standing humanoid. The Shell's EXIT button sets this attribute before
					it clears Sit, and it is the only thing that can tell the two apart --
					without it, pressing EXIT inside this window is answered by being sat
					straight back down, and "I cannot get out of the truck" is the report.
				]]
				if hum:GetAttribute("LeavingSeat") then return end
				s:Sit(hum)
				return
			end
		end
		--[[
			Out of patience, and the player is STILL OUT OF THE SEAT. Sit them down
			anyway rather than returning.

			This is the line the bug report was about. Returning here leaves somebody
			standing beside a truck they just climbed into, with nothing on screen to
			say why and nothing to do but press the prompt again -- which races again,
			and lands here again. Whatever is wrong, being in the seat is the state
			they asked for.

			Guarded on the seat being free, because Sit on an occupied seat is how you
			throw out whoever took it while we were waiting.
		]]
		if hum.Parent and hum.Health > 0 and s.Parent and s.Occupant == nil
			and not hum:GetAttribute("LeavingSeat") then
			s:Sit(hum)
		end
	end)
end

--[[
	One connection, re-made whenever the character is.

	Polled from Update rather than hung off CharacterAdded for the same reason
	_mine is: it costs one FindFirstChildOfClass and a comparison beside a frame
	of the sealer simulation, and it cannot wedge -- a character that turns up
	between two frames is watched on the second one.
]]
function RigController:_watchSeat()
	local character = self.player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if hum == self.seatHum then return end

	if self.seatWatch then self.seatWatch:Disconnect() self.seatWatch = nil end
	self.seatHum = hum
	self.reseats = 0
	if not hum then return end

	self.seatWatch = hum.Seated:Connect(function(active, seatPart)
		if not active then return end
		if seatPart ~= nil then
			-- proof the controls armed themselves off this entry
			self.reseats = 0
			return
		end
		if self.reseats < RESEAT_LIMIT then self:_reseat(hum) end
	end)
end

--==[ DRIVING ]===============================================================

--[[
	What this rig will do.

	Read through a call rather than off self.topSpeed directly because two things
	need the same answer -- the steering ease below and the motor target -- and the
	cab gauge scales its dial off the same TopSpeed attribute this was built from.
]]
function RigController:_top(): number
	return self.topSpeed
end

function RigController:_drive(dt: number)
	local seat, base = self.seat, self.base
	if not seat or not base then return end

	local occupant = seat.Occupant
	local character = self.player.Character
	self.driving = occupant ~= nil and character ~= nil and occupant.Parent == character
	if not self.driving then
		--[[
			GET OUT AND THE TRUCK STOPS -- and it has to be told to, not just meant to.

			These two lines used to be the whole branch, and clearing them is only half
			the job: `driveAt` is the TARGET, and the loop that copies it into the hinge
			motors is below this early return. So stepping out left every drive motor
			holding the last AngularVelocity and MotorMaxTorque it had been given, and a
			hinge motor does not care whether anyone is sitting down -- it keeps driving
			the wheels at whatever it was last told. The rig was not coasting on its own
			momentum; it was still being driven, by a truck nobody was in.

			The comment that used to be here had the reasoning right -- "cleared rather
			than left standing, or climbing back into a rig you jumped out of at speed
			would hand the hubs that old target on the first frame" -- it just never
			reached the hubs.

			Braked rather than freewheeled, on the same terms as lifting off the
			throttle: zero target, brake torque, which is what the coasting path below
			does for a driver who has stopped pressing anything. An empty rig is the
			same case as a stationary one with somebody in it.

			The steers are straightened for the same reason -- a truck abandoned on full
			lock kept its knuckles turned, so it did not stop so much as circle.
		]]
		self.steerAt, self.driveAt = 0, 0
		self.wakeClock = 0
		for _, h in ipairs(self.drives) do
			h.AngularVelocity = 0
			h.MotorMaxTorque = self.brake
		end
		for _, h in ipairs(self.steers) do
			h.TargetAngle = 0
		end
		return
	end

	local speed = base.AssemblyLinearVelocity.Magnitude

	--[[
		Steering lock is bled off as the rig picks up speed. At walking pace you
		want everything the knuckles have to jockey into a driveway; at road speed
		the same stick deflection would put a tall loaded truck on its side.
	]]
	local top = self:_top()
	local ease = 1 - (1 - Config.TruckSteerEase) * math.clamp(speed / top, 0, 1)
	local lock = Config.TruckSteerMax * ease
	--[[
		The input is ramped, the servo is not slowed.

		seat.Steer off a keyboard is -1, 0 or 1, so writing it straight into
		TargetAngle made the knuckles a square wave -- full lock inside a frame,
		straight again the moment the key came up, and no such thing as a small
		correction. See Config.TruckSteerSmooth for why this is the input's job
		rather than the servo's.
	]]
	self.steerAt += (seat.SteerFloat - self.steerAt)
		* (1 - math.exp(-Config.TruckSteerSmooth * dt))
	for _, h in ipairs(self.steers) do
		h.TargetAngle = -self.steerAt * lock
	end

	--[[
		Off the throttle the hubs are still told to hold zero rather than freewheel,
		so the rig parks where you left it instead of rolling off down the camber --
		but it is asked to SLOW to zero, not pinned there.

		Writing the target straight in put 40,000 of torque into wheels still doing
		road speed, which stopped the truck dead against its own springs and set it
		rocking until the energy bled out. Both halves of the cure are in Config:
		TruckBrakeEase ramps the target down, and TruckHoldSpeed drops the brake to a
		holding fraction once the rig is essentially stopped, so six motors and six
		springs are not left arguing about a truck that has already parked.
	]]
	local throttle = seat.ThrottleFloat
	local want = -throttle * (top / Config.WheelRadius)
	local coasting = math.abs(throttle) < 0.05
	local respond = if coasting then self.brakeEase else Config.TruckDriveEase
	self.driveAt += (want - self.driveAt) * (1 - math.exp(-respond * dt))

	local torque = Config.TruckTorque
	local brake = self.brake
	if coasting then
		-- full brake while there is speed to lose, a lighter hold once there is not
		local hold = Config.TruckHoldFrac
		brake *= hold + (1 - hold) * math.clamp(speed / Config.TruckHoldSpeed, 0, 1)
	end
	for _, h in ipairs(self.drives) do
		h.AngularVelocity = self.driveAt
		h.MotorMaxTorque = if coasting then brake else torque
	end

	--[[
		A settled assembly goes to sleep, and writing a new target into a motor is
		not by itself a wake-up -- not even with a driver sitting in it. Without
		this the first press of the throttle on a rig that has been parked for a
		moment does nothing at all, which reads as the truck being broken.

		One nudge flips it awake and it stays awake while it is moving. The rate
		limit is what stops the nudge accumulating into real upward velocity if
		the rig is ever held asleep against something.
	]]
	local first = self.drives[1]
	if first and not first.Active
		and (not coasting or math.abs(seat.SteerFloat) > 0.05) then
		self.wakeClock -= dt
		if self.wakeClock <= 0 then
			self.wakeClock = 0.25
			base.AssemblyLinearVelocity += Vector3.new(0, 0.05, 0)
		end
	else
		self.wakeClock = 0
	end
end

--==[ MOVING PARTS ]==========================================================

function RigController:_animate(dt: number, tankFrac: number)
	local base, seat = self.base, self.seat
	if not base or not seat then return end

	-- A rig that has been called out of the bay is a rig at work, so the beacons
	-- and the agitator simply run. There is no longer a switch for them to be on
	-- the wrong side of.
	self.beaconAngle = (self.beaconAngle + dt * 7.5) % (math.pi * 2)
	self.agitatorAngle = (self.agitatorAngle
		+ Config.AgitatorRPM * math.pi / 30 * dt) % (math.pi * 2)

	--[[
		The front bar swings toward whatever the server says.

		The attribute is the server's, and that is the entire game-pass gate: a
		client can draw the bar wherever it likes, but it cannot put it DOWN, and
		nothing seals unless it is actually down.

		`bladeDown` is deliberately not the same thing as the attribute. It only
		turns true once the swing has almost finished, so a bar still folding out
		over the kerb does not lay coat through the air on its way.
	]]
	local wantDown = self.model ~= nil
		and (self.model :: Model):GetAttribute("BladeDown") == true
	self.bladeAngle = approach(self.bladeAngle,
		if wantDown then 0 else math.rad(Config.TruckBladeRaise),
		Config.TruckBladeEase, dt)
	self.bladeDown = wantDown and self.bladeAngle < math.rad(4)
	if self.bladePivot then
		local hinge = base.CFrame * CFrame.new(self.bladePivot)
			* CFrame.fromAxisAngle(Vector3.xAxis, self.bladeAngle)
		self.bladeCF = hinge * CFrame.new(0, -Config.TruckBladeSink, -Config.TruckBladeReach)
	end

	--[[
		And the spray bar, which is a FIXED nozzle on the nose.

		Deliberately not taken off bladeCF, though it would have been one line. Two
		reasons, and the second is the one that matters:

		The bar parks by swinging up about the hinge, so a pour aimed off that frame
		would wander a stud and a half forward and two studs up the moment somebody
		raised the rubber -- the pour would move because a DIFFERENT control was
		touched.

		And the blade is a game pass. Most players never own it, so for most players
		bladeCF is permanently the parked pose: a pour derived from it would spray
		from wherever the folded-up bar happens to sit, and would be a pour whose
		aim was decided by a purchase they did not make. This one is plumbing every
		rig has, so it is placed where every rig has it.

		The hinge POINT is still shared -- it is the authored spot on the bumper --
		and the sink with it, which is what puts the bead on the deck rather than in
		the air. Only the swing is left out. `bladePivot` is read off the built part
		rather than from Config so a rig assembled differently still answers for
		itself; Config is the fallback for one with no bar built at all.
	]]
	local pourPivot = self.bladePivot or Config.TruckBladePivot
	self.pourCF = base.CFrame * CFrame.new(pourPivot
		+ Vector3.new(0, -Config.TruckBladeSink, -Config.TruckPourReach))

	-- The drum angle is read straight off how much hose is out, so it winds the
	-- right way in both directions without any bookkeeping.
	local reelAngle = -self.hose.paidOut / REEL_RADIUS
	-- The dial reads the tank now rather than pump pressure: with the PTO gone,
	-- how much sealer is left is the only number on the rig worth a needle.
	local needleAngle = math.rad(-125 + 250 * math.clamp(tankFrac, 0, 1))

	local baseCF = base.CFrame
	for _, p in ipairs(self.dynamics) do
		local pos = p:GetAttribute("RigPos") :: Vector3?
		local rot = p:GetAttribute("RigRot") :: CFrame?
		local axis = p:GetAttribute("SpinAxis") :: Vector3?
		if pos and rot and axis then
			local angle = 0
			local name = p.Name
			if string.find(name, "Beacon") then
				angle = self.beaconAngle
			elseif string.find(name, "Agitator") then
				angle = self.agitatorAngle
			elseif string.find(name, "Reel") then
				angle = reelAngle
			elseif string.find(name, "Gauge") then
				angle = needleAngle
			elseif string.find(name, "Blade") then
				angle = self.bladeAngle
			end
			p.CFrame = baseCF * CFrame.new(pos) * CFrame.fromAxisAngle(axis, angle) * rot
		end
	end

	-- The lamp brightening as the mirror comes round is most of what sells a
	-- rotating beacon; a lamp that just blinks reads as a warning light.
	local sweep = math.abs(math.sin(self.beaconAngle))
	for _, rotor in ipairs(self.rotors) do
		local light = rotor:FindFirstChildOfClass("PointLight")
		if light then
			--[[
				Was 0.8 + 2.6 * sweep, which is a floodlight.

				That range is what a beacon needs to read at NIGHT, and this place is
				permanently at ClockTime 14 -- so it never read as a sweeping lamp, it
				just washed the whole cab amber and blew out against the bloom. The
				sweep still swings by a factor of five, which is what sells the rotation;
				it simply does it between dim and dimmer against a bright sky.
			]]
			light.Brightness = 0.12 + 0.5 * sweep
		end
		rotor.Transparency = 0
	end

	--[ audio ]--------------------------------------------------------------
	local engine, pump = self.engine, self.pump
	if engine then
		local want = if seat.Occupant then 0.42 else 0
		engine.Volume = approach(engine.Volume, want, 3.5, dt)
		engine.PlaybackSpeed = 0.72 + 0.55
			* math.clamp(base.AssemblyLinearVelocity.Magnitude / self:_top(), 0, 1)
		if engine.Volume > 0.005 and not engine.IsPlaying then engine:Play() end
		if engine.Volume <= 0.005 and engine.IsPlaying then engine:Stop() end
	end
	if pump then
		-- steady idle: the pump is simply running, and it is the sound that tells
		-- you the rig is live without having to look at it
		pump.Volume = 0.24
		pump.PlaybackSpeed = 0.95
		if not pump.IsPlaying then pump:Play() end
	end
end

--==[ WHERE YOU LEFT IT ]=====================================================

--[[
	The tag over your own truck, and the one thing in this file that runs whether
	or not there is a truck bound.

	That is not a nicety. This place has StreamingEnabled, so a rig far enough
	away to be worth a signpost is exactly the rig this client may no longer hold
	a model for -- and a marker driven off self.model would switch itself off at
	precisely the distance it exists to cover. TruckServer therefore publishes the
	chassis position onto the PLAYER, which never streams out; the model is simply
	the better answer whenever there is one.

	Hidden while you are sitting in it, which is what "after you get out" means --
	the truck you are driving is not the one you have lost. Asked of the seat
	rather than of self.driving, which is set further down the same frame and
	would therefore be answering about the last one.
]]
function RigController:_marker(dt: number)
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

	local seat = self.seat
	local occupant = seat and seat.Occupant
	local aboard = occupant ~= nil and character ~= nil and occupant.Parent == character

	local at: Vector3? = nil
	if not aboard and root then
		local base = self.base
		if base and base.Parent then
			at = base.Position + Vector3.new(0, self.markerLift, 0)
		else
			local spot = self.player:GetAttribute("RigMarkerAt")
			if typeof(spot) == "Vector3" then
				-- The chassis position as of the last time the server looked, which for
				-- a truck standing where you left it is still exactly where it is.
				at = (spot :: Vector3) + Vector3.new(0, MARKER_LIFT, 0)
			else
				-- No rig at all. The name goes with it, or the next one called up wears
				-- the last one's label for the frame before it binds.
				self.rigName = nil
			end
		end
	end

	self.marker:Update(dt, at, self.rigName, if root then root.Position else nil)
end

--==[ TICK ]==================================================================

function RigController:Update(dt: number)
	-- Before anything else, and outside the bind: a driver can be sitting in a
	-- rig this client has not finished binding, and the one event that arms the
	-- throttle fires once and does not come back. See "THE SEAT YOU CANNOT
	-- DRIVE".
	self:_watchSeat()

	-- Stored, swapped, or destroyed out from under us.
	if self.model and not self.model.Parent then self:_release() end

	-- Unbound: look for one of mine. This is also the first bind of the session.
	local bound = self.model ~= nil
	if not bound then
		local found = self:_mine()
		bound = found ~= nil and self:_bind(found :: Model)
	end

	-- Before the bail-out and not after it: the tag has to go on pointing at a
	-- truck this client no longer holds. See _marker.
	self:_marker(dt)
	if not bound then return end

	local model, base = self.model :: Model, self.base
	if not base or not base.Parent then
		self:_release()
		return
	end

	-- Re-read rather than trusting the figure taken at bind time: the Bucket
	-- Capacity track scales the truck's drum too, so buying a level while the rig
	-- is parked outside moves this, and a stale ceiling would leave the gauge
	-- reading full at two thirds.
	self.tankMax = (model:GetAttribute("TankCapacity") :: number?) or self.tankMax

	local tank = (model:GetAttribute("Tank") :: number?) or 0
	self:_drive(dt)
	self:_animate(dt, tank / self.tankMax)
	--[[
		A refused pull is retried every frame, so walking back toward the truck runs
		the hose out the moment it will reach -- with the reel's own click, exactly as
		if they had pulled it there in the first place. Without this, being told "too
		far" would be a dead end that only holstering and re-drawing could clear.

		Before hose:Update rather than after, so the frame that deploys is also the
		frame the hose is first drawn on.
	]]
	if self.wandRig and not self.hose.deployed then self:_runHoseOut() end
	self.hose:Update(dt)
end

--==[ READOUT ]===============================================================

function RigController:State()
	local model = self.model
	local tank = if model then ((model:GetAttribute("Tank") :: number?) or 0) else 0

	--[[
		How far the player is standing from their own truck.

		Here rather than in the HUD because this is the object that already holds the
		chassis: the Shell would otherwise have to go and find a model in Workspace by
		owner id every frame to answer it. Infinite when there is no rig, so a caller
		comparing against a radius reads "not near" without a nil check.
	]]
	local distance = math.huge
	local base = self.base
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if base and base.Parent and root then
		distance = (base.Position - root.Position).Magnitude
	end

	return {
		present = model ~= nil,
		distance = distance,
		rigName = if model then model:GetAttribute("RigName") else nil,
		tank = tank,
		tankFrac = tank / self.tankMax,
		tankMax = self.tankMax,
		--[[
			The drum's length LESS the coil that never pulls straight, because that is
			the scale hoseOut below is on.

			self.hoseMax is the real physical length and has to stay that way -- the
			rope constraint is built at it and _runHoseOut refuses a pull against it --
			but handing the raw figure to a readout paired it with a numerator that has
			MIN_SLACK taken off. paidOut is capped at maxLength, so Out() can only ever
			reach maxLength - MIN_SLACK: on a 96-stud reel the HUD sat at "92/96" with
			the hose pulled as far as the rope physically allows, and Interface's bar
			stopped at 96% for the same reason. Two scales, one fraction.
		]]
		hoseMax = math.max(0, self.hoseMax - HoseRig.MinSlack),
		pump = self.pumpRate,
		-- what the server says, and what the bar has actually got round to doing
		bladeWanted = model ~= nil and model:GetAttribute("BladeDown") == true,
		bladeDown = self.bladeDown,
		bladeCF = self.bladeCF,
		--[[
			The spray bar. The server's attribute rather than anything remembered
			here, for the same reason the blade reads that way: the tank is the
			server's number and the valve has to be shut by whoever can see it run
			dry. A client that latched its own copy would go on pouring from an empty
			drum.

			There is no `pourWanted`/`pouring` split to make here -- unlike the bar,
			nothing has to swing out of the way first, so the valve is simply open or
			shut.
		]]
		pouring = model ~= nil and model:GetAttribute("Pouring") == true,
		pourCF = self.pourCF,
		driverSeat = self.seat,
		refilling = model ~= nil and model:GetAttribute("Refilling") == true,
		-- Parked close enough to the depot pump to take a fill, whether or not
		-- anyone is holding the nozzle. `refilling` cannot answer that -- it only
		-- goes true once a fill is already running -- so this is what lets the HUD
		-- say the truck is in the wrong place BEFORE the player holds the button.
		atPump = model ~= nil and model:GetAttribute("AtPump") == true,
		driving = self.driving,
		deployed = self.hose.deployed,
		-- The wand is in hand with the hose still on the drum, because the truck is
		-- further away than the reel is long. See _runHoseOut.
		wandFar = self.wandFar and self.wandRig ~= nil,
		-- what is off the drum, not HoseRig's internal paid-out figure -- see
		-- HoseRig:Out for why those are different numbers
		hoseOut = self.hose:Out(),
		hoseChord = self.hose.chord,
		tension = self.hose.tension,
	}
end

function RigController:Destroy()
	if self.late then self.late:Disconnect() self.late = nil end
	if self.seatWatch then self.seatWatch:Disconnect() self.seatWatch = nil end
	self.hose:Destroy()
	self.marker:Destroy()
end

return RigController
