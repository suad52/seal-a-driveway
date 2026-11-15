--!strict
-- Sound bank. Everything here is a free Creator Store asset.

local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local SoundKit = {}

type Def = {
	id: number,
	volume: number,
	pitch: number?,
	looped: boolean?,
	rollOff: number?,
	-- which bus it plays on; "Sfx" when unset
	group: string?,
	-- skip it at preload. Music and the ambience bed are long, and holding the
	-- join on a minute and a half of audio to save a fade-in is a bad trade.
	stream: boolean?,
}

--[[
	Volume buses.

	Everything routes through one of these so the settings panel can move music
	and effects independently -- it could not before, because the Sound Effects
	slider wrote SoundService.Volume, which is the global master and ducked the
	music with it.

	Names are prefixed rather than plain "Music"/"Sfx": SoundService is a service
	with its own properties, and a child sharing a property name is a shadowing
	trap waiting to happen on any FindFirstChild-by-guess.
]]
local BUS_ROOT = "SealerAudio"

function SoundKit.bus(kind: string): SoundGroup
	local root = SoundService:FindFirstChild(BUS_ROOT)
	if not root then
		root = Instance.new("SoundGroup")
		root.Name = BUS_ROOT
		root.Volume = 1
		root.Parent = SoundService
	end
	local g = (root :: Instance):FindFirstChild(kind)
	if not g then
		g = Instance.new("SoundGroup")
		;(g :: SoundGroup).Name = kind
		;(g :: SoundGroup).Volume = 1
		;(g :: SoundGroup).Parent = root
	end
	return g :: SoundGroup
end

local Library: { [string]: Def } = {
	-- pouring
	PourLoop  = { id = 9117210574, volume = 0.60, pitch = 0.82, looped = true, rollOff = 65 },
	PourStart = { id = 9113846675, volume = 0.45, pitch = 0.80, rollOff = 55 },
	Splash    = { id = 9126175714, volume = 0.35, pitch = 1.05, rollOff = 40 },

	-- squeegee
	ScrapeLoop = { id = 9113597082, volume = 0.00, pitch = 1.00, looped = true, rollOff = 45 },
	WetLoop    = { id = 9125408271, volume = 0.00, pitch = 0.90, looped = true, rollOff = 45 },

	--[[
		wet layer

		Sealer is thick, cold and heavy, and almost nothing recorded sounds like
		it off the shelf. Everything here is a water or food-foley clip pitched
		well down, which is the cheap trick that turns a thin splash into
		something with body. Pitch is the load-bearing part of these definitions,
		not the choice of clip.

		SlushLoop rides the bead in front of the blade and is driven entirely from
		the pile volume; Squelch and Goop are the intermittent grabs on top of it,
		Goop being the heavier of the two.
	]]
	-- The continuous one, and the one that actually makes spreading sound wet: a
	-- squishy-shoe clip pitched right down reads as rubber dragging through
	-- something thick. It runs whenever there is sealer under the blade at all,
	-- not only once a bead has built up.
	WetSpread = { id = 9120650049, volume = 0.00, pitch = 0.55, looped = true, rollOff = 48 },
	Splat     = { id = 9117283124, volume = 0.32, pitch = 0.70, rollOff = 40 },
	Puddle    = { id = 9117944976, volume = 0.30, pitch = 0.75, rollOff = 42 },
	SlushLoop = { id = 9126206872, volume = 0.00, pitch = 0.72, looped = true, rollOff = 45 },
	Squelch   = { id = 9114519460, volume = 0.34, pitch = 0.62, rollOff = 40 },
	Goop      = { id = 9114887497, volume = 0.30, pitch = 0.55, rollOff = 40 },
	Glug      = { id = 9120564419, volume = 0.00, pitch = 0.70, looped = true, rollOff = 55 },
	Runoff    = { id = 9120590097, volume = 0.00, pitch = 0.80, looped = true, rollOff = 50 },
	Drip      = { id = 9126173766, volume = 0.30, pitch = 0.75, rollOff = 32 },
	TankSlosh = { id = 9120502487, volume = 0.35, pitch = 0.65, rollOff = 45 },

	--[[
		truck and wand

		The pump and the engine share one diesel loop at different pitches -- the
		pump really is driven off the same motor, so they should sit in the same
		register. Load is applied at runtime by nudging PlaybackSpeed, not by
		swapping clips.

		The wand shares the pail's pour samples outright. It is the same sealer
		arriving the same way, just more of it and out of a hose, so there is
		nothing for a separate clip to say.
	]]
	TruckEngine = { id = 71482635231754, volume = 0.42, pitch = 0.72, looped = true, rollOff = 95 },
	PumpIdle    = { id = 71482635231754, volume = 0.30, pitch = 1.05, looped = true, rollOff = 60 },
	ReelClick   = { id = 7381723941, volume = 0.16, pitch = 2.10, rollOff = 30 },
	ValveThunk  = { id = 7381723941, volume = 0.40, pitch = 0.42, rollOff = 45 },

	--[[
		money -- PARKED, NOTHING PLAYS THESE (2026-08-12, owner's call)

		CashBurst was the chime that fired once when a payment landed; CashLand was
		the little metallic tick each note made as it reached the counter, pitched
		right up so a few of them read as a shower of coins rather than a handful of
		chimes. Both on the Ui bus: they belonged to the interface rather than the
		world and did not roll off with distance.

		They were sized for an occasional lump payment, and money is paid by the STUD
		now -- every half second while the blade is down -- so the same sound landed
		continuously for as long as anybody was working. Halving them here and
		thinning the ticks in CashFx (both 2026-08-11) softened that without curing
		it; getting paid is silent now. CashFx is where they were played from and its
		header carries the reasoning.

		Left in the library rather than deleted: the ids, levels and pitches are the
		only record of what the sound WAS, and creation is lazy, so parking them
		costs nothing and putting the chime back is one call site in CashFx. Note the
		ids are shared -- 1347153667 is also `Ding` and 7381723941 is also `Pop` /
		`ReelClick` / `ValveThunk` -- so neither asset is orphaned by this.
	]]
	CashBurst = { id = 1347153667, volume = 0.20, pitch = 1.15, group = "Ui" },
	CashLand  = { id = 7381723941, volume = 0.07, pitch = 2.40, group = "Ui" },

	-- rewards
	Pop     = { id = 7381723941, volume = 0.45, pitch = 1.20 },
	Sparkle = { id = 4612374036, volume = 0.40, pitch = 1.00 },
	Ding    = { id = 1347153667, volume = 0.50, pitch = 1.00 },

	--[[
		TOOLS COMING OUT AND GOING AWAY

		One clip at two pitches rather than two clips. Pulling a tool out and
		putting it away are the same motion in opposite directions, and pitching
		the holster down reads as exactly that -- a second sample would only make
		them sound like unrelated events.
	]]
	EquipTool   = { id = 121062914999809, volume = 0.34, pitch = 1.18, rollOff = 30 },
	HolsterTool = { id = 121062914999809, volume = 0.20, pitch = 0.82, rollOff = 30 },
	-- the little metallic catch under the whoosh, so it lands on something
	EquipClick  = { id = 105224765745546, volume = 0.26, pitch = 1.05, rollOff = 30 },

	-- interface
	UiClick = { id = 89595070232351, volume = 0.32, group = "Ui" },
	UiBuy   = { id = 74354585591493, volume = 0.36, pitch = 1.05, group = "Ui" },
	UiDeny  = { id = 87047730068459, volume = 0.30, group = "Ui" },

	--[[
		THE WORLD BED

		A 36-second bird loop under everything. It is mixed low on purpose: this
		sits beneath the music and its whole job is to stop the map sounding like a
		vacuum between jobs.
	]]
	Ambience = { id = 9112831284, volume = 0.22, looped = true, stream = true },

	--[[
		MUSIC

		Five tracks, shuffled by AudioClient. Volumes are the track's own level;
		the Music bus is what the settings slider moves.
	]]
	MusicGarden  = { id = 138901430543017, volume = 0.55, group = "Music", stream = true },
	MusicMain    = { id = 125536723574585, volume = 0.55, group = "Music", stream = true },
	MusicHorizon = { id = 122209060222267, volume = 0.55, group = "Music", stream = true },
	MusicBeyond  = { id = 99678007903413,  volume = 0.55, group = "Music", stream = true },
	MusicDay     = { id = 87494453896821,  volume = 0.55, group = "Music", stream = true },
}

-- the shuffled playlist, in the order AudioClient should not assume
SoundKit.MusicTracks = { "MusicGarden", "MusicMain", "MusicHorizon", "MusicBeyond", "MusicDay" }
SoundKit.Library = Library

function SoundKit.create(name: string, parent: Instance?): Sound
	local def = SoundKit.Library[name]
	assert(def, "unknown sound: " .. name)
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = "rbxassetid://" .. def.id
	s.Volume = def.volume
	s.PlaybackSpeed = def.pitch or 1
	s.Looped = def.looped or false
	if def.rollOff then
		s.RollOffMaxDistance = def.rollOff
		s.RollOffMode = Enum.RollOffMode.InverseTapered
	end
	s.SoundGroup = SoundKit.bus(def.group or "Sfx")
	s.Parent = parent or SoundService
	return s
end

-- Fire-and-forget, with a little pitch scatter so repeats never sound machine-gunned.
function SoundKit.play(name: string, parent: Instance?, scatter: number?, volumeScale: number?)
	local s = SoundKit.create(name, parent)
	if scatter then
		s.PlaybackSpeed *= 1 + (math.random() * 2 - 1) * scatter
	end
	if volumeScale then
		s.Volume *= volumeScale
	end
	s:Play()
	Debris:AddItem(s, 12)
	return s
end

-- Preloading matters here: the first squeegee stroke is the moment the game has
-- to feel good, and a silent one does not.
function SoundKit.preload()
	local ContentProvider = game:GetService("ContentProvider")
	-- The holder has to be in the DataModel: PreloadAsync silently no-ops on
	-- instances that are not parented anywhere.
	local holder = Instance.new("Folder")
	holder.Name = "SealerPreload"
	holder.Parent = SoundService
	local list = {}
	for name, def in Library do
		if not def.stream then
			table.insert(list, SoundKit.create(name, holder))
		end
	end
	task.spawn(function()
		pcall(function() ContentProvider:PreloadAsync(list) end)
		holder:Destroy()
	end)
end

return SoundKit
