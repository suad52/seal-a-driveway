local C = {}
C.EventId = "Stellar_20261021"
C.StartAt = 1792540800 -- 2026-10-21 00:00 UTC
C.EndAt = 1793491200 -- 2026-11-01 00:00 UTC; 11 days
C.ProductId = 3721165759
C.Price = 49
C.Icon = "rbxassetid://83812755979506"
C.Store = "StellarRewards_v1"
C.BaseMax = {Tank=14, Refill=14, Blade=15, Pour=16, Speed=14}
C.Tasks = {
 play={name="Play for 20 minutes",target=1200},
 roads={name="Finish 10 roads",target=10},
 upgrades={name="Buy 2 upgrades",target=2},
 spin={name="Use Spinwheel 1 time",target=1},
 friend={name="Play together with 1 friend",target=1},
 golden={name="Participate in Golden Hour",target=1},
 color={name="Change Asphalt colour 1 time",target=1},
}
C.Pairs = {
 {"roads","color"},{"upgrades","friend"},{"spin","golden"},
 {"roads","upgrades"},{"color","spin"},{"friend","golden"},
 {"roads","friend"},{"upgrades","color"},{"spin","roads"},
 {"golden","upgrades"},{"friend","color"},
}
function C.day(now,testDay)
 if now<C.StartAt or now>=C.EndAt then return nil end
 if type(testDay)=="number" and testDay%1==0 and C.Pairs[testDay] then return testDay end
 return math.floor((now-C.StartAt)/86400)+1
end
function C.tasks(day)
 local pair=C.Pairs[day]
 return pair and {"play",pair[1],pair[2]} or {}
end
return C
