local Config = {}

Config.World = "1"
Config.StateAttribute = "SkipRoadState"
Config.MaxDistance = 160
Config.QuoteSeconds = 120

Config.Tiers = {
	{ price = 99, productId = 3724106565, maxArea = 2500 },
	{ price = 129, productId = 3724106767, maxArea = 12000 },
	{ price = 199, productId = 3724106928, maxArea = math.huge },
}

function Config.tierOf(slab, size)
    local override = slab:GetAttribute("SkipRoadTier")

    if type(override) == "number" and override % 1 == 0 and Config.Tiers[override] then
        return override, size.X * size.Z
    end

    local area = slab:GetAttribute("SkipRoadArea")

    if type(area) ~= "number" or area ~= area or area <= 0 or area == math.huge then
        area = size.X * size.Z
    end

    for index, tier in ipairs(Config.Tiers) do
        if area <= tier.maxArea then
            return index, area
        end
    end

    return 3, area
end

function Config.isProduct(productId)
    for _, tier in ipairs(Config.Tiers) do
        if tier.productId == productId then
            return true
        end
    end

    return false
end

return Config
