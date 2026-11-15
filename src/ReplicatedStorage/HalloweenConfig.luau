local C={}
C.PlaceId=138676726700999

C.EndUTC=1793577600

C.HomePlaces={
[140010128837133]=true,
[130455840259328]=true,
[120014184236770]=true,
[126526085744847]=true
}

C.DefaultHome=120014184236770

function C.available(now) 
return now<C.EndUTC
 end

function C.reward(area,smallest,largest)
 if largest<=smallest then 
return 5
 end
 local fraction=(math.sqrt(math.max(0,area))-math.sqrt(smallest))/(math.sqrt(largest)-math.sqrt(smallest))
 return math.clamp(5+math.floor(15*fraction+.5),5,20)
end
return C
