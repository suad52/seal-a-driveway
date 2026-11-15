local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local pack = ReplicatedStorage:WaitForChild("DrivewaySealer", 20)
if not pack then warn("[AsphaltLab] DrivewaySealer not found"); return end
local Renderer = require(pack:WaitForChild("SurfaceRenderer"))
local SlabTint = require(pack:WaitForChild("SlabTint"))
local Sections = require(pack:WaitForChild("Sections"))
local Effects = require(pack:WaitForChild("Effects"))
local palettes = require(pack:WaitForChild("ColorPalettes"))
local paint = require(pack:WaitForChild("ColorPaint"))
local selected = palettes[1]
local visualFX = require(pack:WaitForChild("ColorFX")).new(pack, player)
local alive = true
local grids = setmetatable({}, {__mode="k"})
local effectColors = setmetatable({}, {__mode="k"})
local overlays = {}
local connections = {}
local originalNew, originalPaint = Renderer.new, Renderer.Paint
local originalCured, originalSet = SlabTint.curedColor, SlabTint.set
local originalStream, originalWand = Effects.newStream, Effects.newWandStream

local function color(v) return Color3.new(v.X,v.Y,v.Z) end
local function markGrids()
	for grid in pairs(grids) do grid:MarkAllDirty() end
end
local Surface = require(pack:WaitForChild("DrivewaySurface"))
local originalSetDetail = Surface.SetDetail
local originalBuildFlat = Surface._buildFlatOverlay
local originalDestroy = Surface.Destroy
local function isCasa(slab)
	local estate = workspace:FindFirstChild("EstateDistrict")
	local driveways = estate and estate:FindFirstChild("Driveways")
	return driveways ~= nil and slab == driveways:FindFirstChild("Drive_Casa")
end
local function seatCasaDecal(surface)
	if selected.lut and isCasa(surface.slab) and surface.decal then
		surface.decal.Parent = surface.slab
	end
end
Surface._buildFlatOverlay = function(self)
	originalBuildFlat(self)
	seatCasaDecal(self)
end
Surface.SetDetail = function(self, level)
	self._colorsRequestedDetail = level
	if self.decal and self.decal.Parent == self.slab and self.overlay then
		self.decal.Parent = self.overlay
	end
	if selected.lut and isCasa(self.slab) then
		level = Surface.Detail.Flat
	elseif level == Surface.Detail.Bare and selected.lut and SlabTint.isSealed(self.slab) then
		level = Surface.Detail.Flat
	end
	local result = originalSetDetail(self, level)
	seatCasaDecal(self)
	return result
end
Surface.Destroy = function(self)
	if self.decal and self.decal.Parent == self.slab then self.decal:Destroy() end
	return originalDestroy(self)
end
local function updateSlab(slab, sealed)
	visualFX:StyleSlab(slab, sealed)
	local old = slab:FindFirstChild("AsphaltLabRainbow")
	if old then old:Destroy() end
	local surface = visualFX.surfaces[slab]
	if surface then
		surface:SetDetail(surface._colorsRequestedDetail or surface.detail)
	end
end
local function refreshSlabs()
	for _, slab in ipairs(CollectionService:GetTagged(Sections.Tag)) do
		if slab:IsA("BasePart") and SlabTint.isSealed(slab) then
			-- Reapply appearance only. Never mark an unfinished slab as complete.
			originalSet(slab, true)
			updateSlab(slab, true)
		end
	end
end
local function updateEffect(instance)
	if not instance.Parent then return end
	if selected.id == "classic" then
		instance.Color = effectColors[instance]
	elseif selected.lut ~= nil then
		instance.Color = selected.sequence
	else
		instance.Color = ColorSequence.new(color(selected.liquid))
	end
end
local function rememberEffect(instance)
	if not effectColors[instance] then effectColors[instance] = instance.Color end
	updateEffect(instance)
end
local function registerStream(stream)
	for _, key in ipairs({"beam", "spatter", "mist", "splash"}) do
		if stream[key] then rememberEffect(stream[key]) end
	end
	return stream
end
local function newHook(...)
	local renderer = originalNew(...)
	grids[renderer.grid] = true
	return renderer
end
local function paintHook(self, x0,y0,x1,y1)
	grids[self.grid] = true
	if selected.id == "classic" then return originalPaint(self,x0,y0,x1,y1) end
	-- Original synchronous fallback prepares the relief without yielding.
	if not self.microX then originalPaint(self,x0,y0,x1,y1) end
	return paint(self,x0,y0,x1,y1,selected)
end
local function curedHook()
	if selected.id == "classic" then return originalCured() end
	return color(selected.sealed)
end
local function setHook(slab, sealed)
	originalSet(slab,sealed)
	updateSlab(slab,sealed)
end
local function streamHook(...) return registerStream(originalStream(...)) end
local function wandHook(...) return registerStream(originalWand(...)) end
Renderer.new, Renderer.Paint = newHook, paintHook
SlabTint.curedColor, SlabTint.set = curedHook, setHook
Effects.newStream, Effects.newWandStream = streamHook, wandHook

-- Catch streams already constructed before this LocalScript started.
local visuals = workspace:FindFirstChild("SealerVisuals")
if visuals then
	for _, instance in ipairs(visuals:GetDescendants()) do
		local parent = instance.Parent
		if (instance:IsA("Beam") or instance:IsA("ParticleEmitter")) and parent
			and (parent.Name == "PourImpact" or parent.Name == "SprayImpact" or parent.Name == "SprayMuzzle") then
			rememberEffect(instance)
		end
	end
end


local changed = Instance.new("BindableEvent")
local api = {Changed = changed.Event}
local testOverride
local function apply()
	local id = testOverride or player:GetAttribute("AsphaltColorEquipped") or "classic"
	local nextPalette = palettes[1]
	for _, p in ipairs(palettes) do if p.id == id then nextPalette = p; break end end
	if selected == nextPalette then return end
	selected = nextPalette
	visualFX:Select(selected)
	markGrids()
	refreshSlabs()
	for instance in pairs(effectColors) do updateEffect(instance) end
	changed:Fire(selected)
end
function api.SetTest(id) testOverride = id; apply() end
function api.ClearTest() testOverride = nil; apply() end
function api.Current() return selected end
player:GetAttributeChangedSignal("AsphaltColorEquipped"):Connect(function()
	testOverride = nil
	apply()
end)
CollectionService:GetInstanceRemovedSignal(Sections.Tag):Connect(function(slab)
	local overlay = overlays[slab]
	if overlay then overlay:Destroy(); overlays[slab] = nil end
end)
apply()
return api
