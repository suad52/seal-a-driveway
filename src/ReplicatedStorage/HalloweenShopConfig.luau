local C={}
C.EndsAt=1793577600
C.PlaceId=138676726700999
C.Products={Squeegee=3718981560,PumpkinRescue=3718981645,Roll=3718981762}
C.Prices={Squeegee=2200,PumpkinRescue=1800,Roll=100}
C.Robux={Squeegee=129,PumpkinRescue=99,Roll=29}
C.ItemOwnedKey={Squeegee="Sweet",PumpkinRescue="PumpkinRescue"}
C.Rewards={{id="pumpkins",name="50 Pumpkins",chance=36},{id="tickets",name="3 Spin Tickets",chance=20},{id="cash100k",name="100K Cash",chance=15},{id="cash1m",name="1M Cash",chance=10},{id="helper",name="1 Helper Use",chance=8},{id="coat",name="1 Instant Coat Use",chance=5},{id="nightmares",name="Nightmares",chance=4},{id="spell",name="Spell",chance=2}}
C.DuplicatePumpkins=100
function C.pick(roll)
 local sum=0
 for _,r in ipairs(C.Rewards) do sum+=r.chance;if roll<=sum then return r end end
 error("Invalid roll")
end
return C