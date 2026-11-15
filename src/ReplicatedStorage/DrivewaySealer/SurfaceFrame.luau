local Frame = {}
function Frame.of(slab: BasePart): (CFrame, Vector3)
 local cf, size = slab.CFrame, slab.Size
 local surfaces = slab.Parent
 local park = surfaces and surfaces.Parent
 local zones = park and park.Parent
 local district = zones and zones.Parent
 local target = slab.Name == "Surface15" and surfaces and surfaces.Name == "Surfaces"
  and park and park.Name == "Park" and zones and zones.Name == "Zones"
  and district and district.Name == "NewZone" and district.Parent == workspace
 if target and size.X < size.Y and size.X < size.Z and math.abs(cf.RightVector.Y) > 0.99 then
  local up = cf.RightVector * (if cf.RightVector.Y > 0 then 1 else -1)
  local right = cf.UpVector
  cf = CFrame.fromMatrix(cf.Position, right, up, right:Cross(up))
  size = Vector3.new(size.Y, size.X, size.Z)
 end
 return cf, size
end
return Frame

