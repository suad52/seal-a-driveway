local C = {}
C.Period = 20 * 60
C.Duration = 5 * 60
C.EndUTC = 1793577600 -- 2026-11-02 00:00:00 UTC (exclusive)
C.MinRadius, C.MaxRadius = 40, 80
C.BatchSize, C.MaxPerPlayer, C.Lifetime = 3, 9, 95
C.PickupRadius = 6
C.CoinAttribute = "PumpkinCoins"
function C.interval(players)
 return math.max(30, 60 - math.max(0, players - 1) * 5)
end
function C.window(now)
 if now >= C.EndUTC then return false, C.EndUTC, true end
 local start = math.floor(now / C.Period) * C.Period
 local active = now < start + C.Duration
 return active, math.min(if active then start + C.Duration else start + C.Period, C.EndUTC), false
end
return C
