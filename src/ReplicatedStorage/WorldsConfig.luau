local Config = {}
Config.UnlockProductId = 3717286556
Config.Places = {
	Dev = {140010128837133, 130455840259328},
	Prod = {120014184236770, 126526085744847},
}

function Config.resolve(placeId) 
	if placeId == 138676726700999 then return "Prod", 3 end
	for environment, places in pairs(Config.Places) do
		for world, id in ipairs(places) do
			if placeId == id then return environment, world end
		end
	end
	return nil, nil
end

function Config.destination(placeId, world)
	if world ~= 1 and world ~= 2 then return nil end
	local environment = Config.resolve(placeId)
	return environment and Config.Places[environment][world] or nil
end

return Config
