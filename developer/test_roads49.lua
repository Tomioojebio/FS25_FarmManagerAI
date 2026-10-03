return function(test,eq)
local function fixture(length,width)
    local edges={}
    for x=0,length-5,5 do
        edges[#edges+1]={ax=x,az=0,bx=x+5,bz=0,maxWidth=width}
    end
    return {engineRoads={edges=edges,hasCostmap=true},farmSurvey={edges={}},settings={surveyRadius=230,surveyEnabled=true,navigationLearning=true},navigationMap={hazards={}}}
end

test('49: map-wide AISystem road path spans 1.2 km outside old 500 m yard limit',function()
    local c=fixture(1200)
    local p,why=FMAFarmSurvey.plan(c,{x=0,z=0},{x=1200,z=0},'SOLO')
    assert(p, tostring(why))
    assert(#p==241 and p[1].x==0 and p[#p].x==1200)
    assert(c.engineRoads.routeGraphs.SOLO.edgeCount==240)
end)

test('49: kilometres of waypoints produce finite GIANTS legs, never a kilometre jump',function()
    local c=fixture(1200)
    local record={object={posX=0,posZ=0},key='long-road'}
    local plan=FMAPathRunner.plan(c,record,{x=1200,z=0})
    assert(plan and #plan.legs>18 and #plan.legs<=FMAPathRunner.MAX_LEGS)
    for i=2,#plan.legs do
        local dx=plan.legs[i].x-plan.legs[i-1].x
        assert(dx>0 and dx<=50)
    end
    assert(plan.legs[#plan.legs].x==1200 and plan.legs[1].noRoutePlan)
end)

test('49: disconnected roads never become a made-up route through buildings',function()
    local c=fixture(60)
    for x=100,160,5 do c.engineRoads.edges[#c.engineRoads.edges+1]={ax=x,az=0,bx=x+5,bz=0} end
    local p,why=FMAEngineRoads.route(c,{x=0,z=0},{x=165,z=0},'SOLO')
    eq(p,nil)
    assert(tostring(why):find('NEMÁ_SPOJENÍ',1,true))
end)

test('49: road proximity never assumes access across unknown 30 m yard shortcut',function()
    local c=fixture(200)
    local p,why=FMAEngineRoads.route(c,{x=0,z=34},{x=200,z=0},'SOLO')
    eq(p,nil);eq(why,'START_NENÍ_U_SILNICE')
end)

test('49: unknown road width forbids guessing that a towable trailer fits',function()
    local c=fixture(160)
    local p,why=FMAEngineRoads.route(c,{x=0,z=0},{x=160,z=0},'TOWED')
    eq(p,nil);eq(why,'CHYBÍ_OVĚŘENÁ_ŠÍŘKA_PRO_SOUPRAVU')
    local c2=fixture(160,5)
    local safe=FMAEngineRoads.route(c2,{x=0,z=0},{x=160,z=0},'TOWED')
    assert(safe and #safe==33)
end)

test('49: previously blocked road segment is avoided, not declared safe again',function()
    local c=fixture(200)
    c.navigationMap.hazards['6:0']={failures=3}
    local p,why=FMAEngineRoads.route(c,{x=0,z=0},{x=200,z=0},'SOLO')
    eq(p,nil)
    assert(tostring(why):find('NEMÁ_SPOJENÍ',1,true))
end)

test('49: real spline junctions with sub-metre offset connect conservatively',function()
    local c=fixture(60)
    for x=0,55,5 do c.engineRoads.edges[x/5+1].id='ai:100:'..string.format('%d',x/5+1) end
    for x=0,55,5 do
        c.engineRoads.edges[#c.engineRoads.edges+1]={id='ai:200:'..string.format('%d',x/5+1),ax=60.6+x,az=0,bx=65.6+x,bz=0}
    end
    local connected,why=FMAEngineRoads.route(c,{x=0,z=0},{x=120.6,z=0},'SOLO')
    assert(connected and #connected>20,tostring(why))
    local g=fixture(60)
    for x=0,55,5 do g.engineRoads.edges[x/5+1].id='ai:100:'..string.format('%d',x/5+1) end
    for x=0,55,5 do g.engineRoads.edges[#g.engineRoads.edges+1]={id='ai:200:'..string.format('%d',x/5+1),ax=62+x,az=0,bx=67+x,bz=0} end
    local disconnected=FMAEngineRoads.route(g,{x=0,z=0},{x=122,z=0},'SOLO')
    eq(disconnected,nil)
end)

test('49: remote route without proven graph cannot fall back to blind GIANTS GoTo',function()
    local oldCp=FMACourseplay
    FMACourseplay={available=function()return false end}
    local c=fixture(40)
    local rec={key='fma-road-lexion',name='LEXION',object={posX=0,posZ=0}}
    local job,why=FMAAI.createTransferJob(c,rec,{x=800,z=0,tolerance=9})
    eq(job,nil)
    assert(tostring(why):find('Courseplay odmítl',1,true),tostring(why))
    FMACourseplay=oldCp
end)

test('49: road graph supports 3 km with bounded expansions and checkpoints',function()
    local c=fixture(3000)
    local p,why=FMAEngineRoads.route(c,{x=0,z=0},{x=3000,z=0},'SOLO')
    assert(p and #p==601,tostring(why))
    local r={key='far',object={posX=0,posZ=0}}
    local plan=FMAPathRunner.plan(c,r,{x=3000,z=0})
    assert(plan and #plan.legs<120 and #plan.legs>50)
end)

test('49: pending route legs only advance after real physical target arrival',function()
    local c=fixture(1200)
    local record={object={posX=0,posZ=0},key='long-road',busy=true}
    local plan=FMAPathRunner.plan(c,record,{x=1200,z=0})
    local task={id='field:64:harvest',kind='fieldStage',state='running'}
    local a={task=task,vehicle=record,learnedRoutePlan=plan}
    local controller={settings={enabled=true},now=12000,reservations={},pendingRouteLegs={}}
    eq(FMAPathRunner.advance(controller,a,'success'),false)
    assert(tostring(a.stopReason):find('nepotvrzen',1,true))
    a.stopReason=nil
    record.object.posX=plan.legs[1].x
    eq(FMAPathRunner.advance(controller,a,'success'),true)
    assert(controller.pendingRouteLegs['long-road'].nextIndex==2)
end)
end
