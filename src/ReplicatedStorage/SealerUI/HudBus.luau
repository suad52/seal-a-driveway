--!strict
--[[
	HudBus -- a one-slot client-side channel carrying the live job readout.

	DrivewayClient already assembles exactly the state a HUD needs each frame and
	hands it to Interface. Rather than recompute any of that (nearest surface,
	coverage, bucket level, rig state) the shell reads the same table from here.

	A plain module rather than attributes or a BindableEvent on purpose: this is
	purely local presentation, and attributes would replicate every field to the
	server sixty times a second for a number only this client ever draws.
]]

local HudBus = {}

export type State = {
	coverage: number?,
	value: number?,
	combo: number?,
	stroking: boolean?,
	laying: boolean?,
	name: string?,
	bucket: number?,
	rig: { [string]: any }?,
	fill: { [string]: any }?,
	mode: string?,
	hint: string?,
	tool: string?,
	loose: number?,
	looseAt: Vector3?,
}

HudBus.latest = {} :: State
HudBus.stamp = 0

export type Afk = {
	plot: number,
	coverage: number,
	perMinute: number,
}

HudBus.afk = nil :: Afk?

function HudBus.push(state: State, tool: string?)
	state.tool = tool
	HudBus.latest = state
	HudBus.stamp += 1
end

return HudBus
