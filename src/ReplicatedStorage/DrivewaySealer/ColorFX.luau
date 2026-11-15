-- Local, bounded visual effects. No server calls or simulation writes.
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local VisualFX = {}
VisualFX.__index = VisualFX

function VisualFX.new(pack, player)
	local Surface = require(pack:WaitForChild("DrivewaySurface"))
	local SlabTint = require(pack:WaitForChild("SlabTint"))
	local Sections = require(pack:WaitForChild("Sections"))
	local Config = require(pack:WaitForChild("Config"))
	local self = setmetatable({alive=true, selected={}, connections={}, pool={}, clock=0,
		surfaces=setmetatable({}, {__mode="kv"}), originals=setmetatable({}, {__mode="k"}),
		meshes=setmetatable({}, {__mode="k"}), slabs=setmetatable({}, {__mode="k"}), rng=Random.new()}, VisualFX)
	self.Surface = Surface
	self.oldNew = Surface.new
	self.newHook = function(...)
		local surface = self.oldNew(...)
		if self.alive and surface then self.surfaces[surface.slab] = surface end
		return surface
	end
	Surface.new = self.newHook
	local function trackMesh(instance)
		if instance.Name == "SealerLiquidMesh" and instance:IsA("MeshPart")
			and instance:FindFirstAncestor("SealerVisuals") then
			self.meshes[instance] = true
			self:_Reflect(instance, true)
		end
	end
	local visuals = workspace:FindFirstChild("SealerVisuals")
	if visuals then for _,instance in ipairs(visuals:GetDescendants()) do trackMesh(instance) end end
	self.connections[#self.connections+1] = workspace.DescendantAdded:Connect(trackMesh)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true
	local function refreshFilter() params.FilterDescendantsInstances = CollectionService:GetTagged(Sections.Tag) end
	refreshFilter()
	self.connections[#self.connections+1] = CollectionService:GetInstanceAddedSignal(Sections.Tag):Connect(refreshFilter)
	self.connections[#self.connections+1] = CollectionService:GetInstanceRemovedSignal(Sections.Tag):Connect(refreshFilter)
	self.connections[#self.connections+1] = RunService.Heartbeat:Connect(function(dt)
		if not self.alive or not self.selected.sparkles then return end
		self.clock += dt
		if self.clock < .25 then return end
		self.clock = 0 -- No catch-up bursts on a slow frame.
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return end
		for _,slot in ipairs(self.pool) do
			local angle = self.rng:NextNumber(0,math.pi*2)
			local radius = self.rng:NextNumber(1,8)
			local origin = root.Position + Vector3.new(math.cos(angle)*radius,8,math.sin(angle)*radius)
			local hit = workspace:Raycast(origin,Vector3.new(0,-22,0),params)
			if not hit then continue end
			local slab = hit.Instance
			local coated = SlabTint.isSealed(slab)
			local height = .12
			if not coated then
				local surface = self.surfaces[slab]
				if surface and surface.ready then
					local grid = surface.grid
					local lx,lz = surface:ToLocal(hit.Position)
					local x,y = grid:WorldToCell(lx,lz)
					x,y = math.round(x),math.round(y)
					if x>=0 and y>=0 and x<grid.W and y<grid.H then
						local i = y*grid.W+x
						if buffer.readu8(grid.mask,i)==1 then
							local d = buffer.readf32(grid.liquid,i*4)+buffer.readf32(grid.film,i*4)
							coated = d>.05 or buffer.readf32(grid.sealed,i*4)>.2
							if d>.05 then height = Config.LiquidMaxHeight+.08 end
						end
					end
				end
			end
			if coated then
				slot.part.CFrame = CFrame.new(hit.Position+hit.Normal*height)
				slot.emitter:Emit(1)
			end
		end
	end)
	return self
end

function VisualFX:_Reflect(part, enabled)
	if not self.alive or not part.Parent then return end
	require(script.Parent.GraveyardRoadStyle).apply(part,enabled and self.selected.id=="witchbrew")
	local target = enabled and self.selected.reflectance
	if target then
		if self.originals[part] == nil then self.originals[part] = part.Reflectance end
		part.Reflectance = target
	elseif self.originals[part] ~= nil then
		part.Reflectance = self.originals[part]
		self.originals[part] = nil
	end
end

function VisualFX:StyleSlab(slab, sealed)
	if not self.alive then return end
	self.slabs[slab] = if sealed then true else nil
	self:_Reflect(slab,sealed)
end

function VisualFX:Select(palette)
	if not self.alive then return end
	self.selected = palette
	self.clock = 0
	for part in pairs(self.meshes) do self:_Reflect(part,true) end
	for slab in pairs(self.slabs) do self:_Reflect(slab,true) end
	if palette.sparkles and not self.folder then
		self.folder = Instance.new("Folder")
		self.folder.Name = "AsphaltColorFX"
		self.folder.Parent = workspace
		for i=1,4 do
			local part = Instance.new("Part")
			part.Name = "SparkleAnchor"..i
			part.Size = Vector3.new(.05,.05,.05)
			part.Transparency = 1
			part.Anchored = true
			part.CanCollide,part.CanTouch,part.CanQuery,part.CastShadow = false,false,false,false
			part.Parent = self.folder
			local attachment = Instance.new("Attachment")
			attachment.Parent = part
			local emitter = Instance.new("ParticleEmitter")
			emitter.Name = "AsphaltSparkles"
			emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			emitter.Rate = 0
			emitter.Enabled = false
			emitter.LockedToPart = false
			emitter.LightEmission = .85
			emitter.LightInfluence = .15
			emitter.Lifetime = NumberRange.new(.45,.85)
			emitter.Speed = NumberRange.new(.05,.25)
			emitter.Rotation = NumberRange.new(0,360)
			emitter.RotSpeed = NumberRange.new(-20,20)
			emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(.3,.22),NumberSequenceKeypoint.new(1,0)})
			emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,1),NumberSequenceKeypoint.new(.2,.1),NumberSequenceKeypoint.new(1,1)})
			emitter.Parent = attachment
			self.pool[i] = {part=part,emitter=emitter}
		end
	end
	for _,slot in ipairs(self.pool) do
		slot.emitter:Clear()
		if palette.sparkles then
			slot.emitter.Color = if palette.lut then palette.sequence else ColorSequence.new({
				ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),
				ColorSequenceKeypoint.new(1,Color3.new(palette.sheen.X,palette.sheen.Y,palette.sheen.Z)),
			})
		end
	end
end

function VisualFX:Destroy()
	if not self.alive then return end
	self.alive = false
	if self.Surface.new == self.newHook then self.Surface.new = self.oldNew end
	for _,connection in ipairs(self.connections) do connection:Disconnect() end
	for part,value in pairs(self.originals) do if part.Parent then part.Reflectance = value end end
	if self.folder then self.folder:Destroy() end
	table.clear(self.pool)
	table.clear(self.originals)
end
return VisualFX
