return function(test,eq)
local function fixture()
    local edges={}
    for x=0,195,5 do edges[#edges+1]={ax=x,az=0,bx=x+5,bz=0,maxWidth=5} end
    return {engineRoads={edges=edges,hasCostmap=true},settings={surveyEnabled=true,navigationLearning=true},
        navigationMap={hazards={}},farmSurvey={edges={}}}
end

test('50: default planner refuses unverified long off-road access',function()
    local c=fixture()
    local p,why=FMAEngineRoads.route(c,{x=0,z=20},{x=200,z=0},'SOLO')
    eq(p,nil);eq(why,'START_NENÍ_U_SILNICE')
end)

test('50: segment runner stages a yard entry and a field exit as physical legs',function()
    local c=fixture()
    local rec={key='tractor',object={posX=0,posZ=20}}
    local plan,why=FMAPathRunner.plan(c,rec,{x=200,z=20})
    assert(plan,tostring(why))
    eq(plan.legs[1].roadAccess,'ENTRY')
    eq(plan.legs[1].x,0);eq(plan.legs[1].z,0)
    eq(plan.legs[#plan.legs].roadAccess,'EXIT')
    eq(plan.legs[#plan.legs].x,200);eq(plan.legs[#plan.legs].z,20)
    assert(#plan.legs>=4 and #plan.legs<16)
    for _,leg in ipairs(plan.legs) do assert(leg.noRoutePlan==true) end
end)

test('50: access corridor fails closed beyond 32 metres',function()
    local c=fixture()
    local p,why=FMAEngineRoads.route(c,{x=0,z=33},{x=200,z=0},'SOLO',1000)
    eq(p,nil);eq(why,'START_NENÍ_U_SILNICE')
    local rec={key='tractor',object={posX=0,posZ=40}}
    local plan=FMAPathRunner.plan(c,rec,{x=200,z=0})
    eq(plan,nil)
end)

test('50: road-access stage may only advance after physical arrival',function()
    local c=fixture()
    local rec={key='tractor',object={posX=0,posZ=20},busy=true}
    local plan=assert(FMAPathRunner.plan(c,rec,{x=200,z=20}))
    local active={task={id='field:64:harvest',state='running'},vehicle=rec,learnedRoutePlan=plan}
    local controller={settings={enabled=true},now=10000,reservations={},pendingRouteLegs={}}
    eq(FMAPathRunner.advance(controller,active,'success'),false)
    assert(active.stopReason and active.stopReason:find('nepotvrzen'))
    active.stopReason=nil
    rec.object.posZ=0
    eq(FMAPathRunner.advance(controller,active,'success'),true)
    eq(controller.pendingRouteLegs.tractor.nextIndex,2)
end)

test('50: towed clearance remains mandatory even with access stage',function()
    local c=fixture()
    for _,e in ipairs(c.engineRoads.edges) do e.maxWidth=nil end
    local p,why=FMAEngineRoads.route(c,{x=0,z=20},{x=200,z=20},'TOWED',32)
    eq(p,nil);eq(why,'CHYBÍ_OVĚŘENÁ_ŠÍŘKA_PRO_SOUPRAVU')
end)

test('51: field access is a distinct short leg after the actual final road waypoint',function()
    local c=fixture()
    local rec={key='tractor',object={posX=0,posZ=20}}
    local plan=assert(FMAPathRunner.plan(c,rec,{x=201,z=31}))
    local roadEnd=plan.legs[#plan.legs-1]
    local fieldExit=plan.legs[#plan.legs]
    eq(roadEnd.roadAccess,'ROAD_END')
    eq(roadEnd.x,200);eq(roadEnd.z,0)
    eq(fieldExit.roadAccess,'EXIT')
    eq(fieldExit.x,201);eq(fieldExit.z,31)
    assert(math.sqrt((roadEnd.x-fieldExit.x)^2+(roadEnd.z-fieldExit.z)^2)<=32)
    assert(fieldExit.tolerance<=3)
end)

test('51: short five-metre yard entry requires real position change',function()
    local c=fixture()
    local rec={key='yard',object={posX=0,posZ=5},busy=true}
    local plan=assert(FMAPathRunner.plan(c,rec,{x=200,z=0}))
    eq(plan.legs[1].roadAccess,'ENTRY')
    assert(plan.legs[1].tolerance<3)
    local a={task={id='field:64:harvest',state='running'},vehicle=rec,learnedRoutePlan=plan}
    local controller={settings={enabled=true},now=1000,reservations={},pendingRouteLegs={}}
    eq(FMAPathRunner.advance(controller,a,'success'),false)
    assert(a.stopReason and a.stopReason:find('nepotvrzen',1,true))
    a.stopReason=nil;rec.object.posZ=0
    eq(FMAPathRunner.advance(controller,a,'success'),true)
    eq(controller.pendingRouteLegs.yard.nextIndex,2)
end)

test('51: last mile from road to field is not merged into a longer diagonal',function()
    local c=fixture()
    local rec={key='tractor',object={posX=0,posZ=20}}
    local plan=assert(FMAPathRunner.plan(c,rec,{x=200,z=20}))
    local before=plan.legs[#plan.legs-1]
    local final=plan.legs[#plan.legs]
    eq(before.x,200);eq(before.z,0)
    eq(final.roadAccess,'EXIT')
    eq(final.x,200);eq(final.z,20)
    assert(final.tolerance<=3)
end)

test('51: no road access may exceed the preexisting 32 metre fail-closed bound',function()
    local c=fixture()
    local rec={key='tractor',object={posX=0,posZ=20}}
    local plan=assert(FMAPathRunner.plan(c,rec,{x=200,z=31}))
    for i,leg in ipairs(plan.legs) do
        if leg.roadAccess=='ENTRY' or leg.roadAccess=='EXIT' then
            local prev=i==1 and {x=0,z=20} or plan.legs[i-1]
            assert(math.sqrt((prev.x-leg.x)^2+(prev.z-leg.z)^2)<=32)
        end
    end
end)
end
