local Pack=game.ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config=require(Pack.Config)
local RobotConfig=require(Pack.RobotConfig)
local M={}
function M.stamp(surface,position)
	local g=surface.grid
	local lx,lz=surface:ToLocal(position)
	local radius=RobotConfig.Radius
	local ax,ay=g:WorldToCell(lx-radius,lz-radius)
	local bx,by=g:WorldToCell(lx+radius,lz+radius)
	local x0,y0=math.max(0,math.floor(ax)),math.max(0,math.floor(ay))
	local x1,y1=math.min(g.W-1,math.ceil(bx)),math.min(g.H-1,math.ceil(by))
	for y=y0,y1 do for x=x0,x1 do
			local i=y*g.W+x
			local wx,wz=g:CellToWorld(x,y)
			if (wx-lx)^2+(wz-lz)^2<=radius^2 and buffer.readu8(g.mask,i)==1 and buffer.readu8(g.paint,i)==0 then
				local j=i*4
				local old=buffer.readf32(g.sealed,j)
				g.sealedFrac+=1-math.min(1,old/Config.SealedThreshold)
				if buffer.readu8(g.counted,i)==0 then g.sealedCount+=1;buffer.writeu8(g.counted,i,1) end
				g.loose=math.max(0,g.loose-buffer.readf32(g.liquid,j)*g.cellArea)
				for _,name in ipairs({"liquid","film","delta","vx","vy","ripple","rvel"}) do buffer.writef32(g[name],j,0) end
				buffer.writef32(g.sealed,j,1);buffer.writef32(g.gloss,j,Config.GlossSettle)
			end
		end end
	local chunk=Config.ChunkCells
	for cy=math.max(0,math.floor(y0/chunk)),math.min(g.CH-1,math.floor(y1/chunk)) do
		for cx=math.max(0,math.floor(x0/chunk)),math.min(g.CW-1,math.floor(x1/chunk)) do
			buffer.writeu8(g.dirty,cy*g.CW+cx,1)
			g.anyDirty=true
		end
	end
end
function M.bind(findSurface,wantSurface)
	local remote=Pack:WaitForChild("RobotRemote")
	local target,version
	remote.OnClientEvent:Connect(function(action,slab,position,v)
		if action=="Target" then target=slab;version=position;if slab then wantSurface(slab) end
		elseif action=="Stamp" and slab==target and v==version then
			local s=findSurface(slab)
			if s and s.ready and not s.completed then M.stamp(s,position) end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(.5)
			if target then
				local s=findSurface(target)
				if not s or not s.ready then wantSurface(target) else
					remote:FireServer("Ready",target,version)
					if not s.completed then
						local coverage=s:Coverage()
						Pack.Remotes.ReportCoverage:FireServer(target,coverage)
						if coverage>=Config.CompleteAt then Pack.Remotes.DrivewayComplete:FireServer(target,0) end
					end
				end
			end
		end
	end)
	return function(slab) return slab==target end
end
return M
