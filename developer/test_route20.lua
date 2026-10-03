return function(test,eq)
local function stub(obj,key,val)
    local old=obj[key];obj[key]=val
    return function()obj[key]=old end
end

test('road20: AI-system splines are read from real mission and costmap metadata',function()
    local oldMission,oldI3D,oldLength,oldPos=g_currentMission,I3DUtil,getSplineLength,getSplinePosition
    local restoreAtlas=stub(FMAWorldAtlas,'identity',function() return 'route_fixture' end)
    local restoreEvent=stub(FMADiagnostics,'event',function() end)
    g_currentMission={aiSystem={roadSplines={102},getNavigationMap=function()return 7 end}, missionInfo={mapId='route_fixture'}}
    I3DUtil={getIsSpline=function(_,node) return node==102 end}
    -- In the FS25 API this check is called as I3DUtil.getIsSpline(node)
    I3DUtil.getIsSpline=function(node)return node==102 end
    getSplineLength=function()return 90 end
    getSplinePosition=function(_,t)return t*90,0,0 end
    local c={}
    local ok,roads=FMAEngineRoads.scan(c)
    assert(ok and roads.hasCostmap and roads.splineCount==1 and #roads.edges==18)
    assert(#FMAEngineRoads.near(c,{x=0,z=0},40)>=8)
    g_currentMission,I3DUtil,getSplineLength,getSplinePosition=oldMission,oldI3D,oldLength,oldPos
    restoreAtlas();restoreEvent()
end)

test('road20: measured AI splines are navigable for solo while unrecorded trailers cannot infer clearance',function()
    local edges={}
    for i=0,14 do edges[#edges+1]={ax=i*5,az=0,bx=(i+1)*5,bz=0} end
    local c={farmSurvey={edges={},center={x=0,z=0}},engineRoads={hasCostmap=true,edges=edges},settings={surveyRadius=200},navigationMap={hazards={}}}
    local a=FMAFarmSurvey.plan(c,{x=0,z=0},{x=75,z=0},'SOLO')
    assert(a and #a>=12 and a[#a].x==75)
    local b=FMAFarmSurvey.plan(c,{x=0,z=0},{x=75,z=0},'TOWED')
    eq(b,nil)
end)

test('road20: route segments planned without teleport or indefinite number of waypoints',function()
    local original=FMAFarmSurvey.plan
    local points={}
    for i=0,16 do points[#points+1]={x=i*5,z=0} end
    FMAFarmSurvey.plan=function()return points end
    local c={settings={surveyEnabled=true,navigationLearning=true}}
    local record={object={posX=0,posZ=0}}
    local p=FMAPathRunner.plan(c,record,{x=80,z=0})
    assert(p and #p.legs>=2 and #p.legs<=FMAPathRunner.MAX_LEGS)
    assert(p.legs[1].noRoutePlan==true and p.legs[#p.legs].x==80)
    FMAFarmSurvey.plan=original
end)

test('road20: intermediate completion retains reservation and delays next job',function()
    local origMission=g_currentMission
    g_currentMission={aiSystem={}}
    local originalCreate=FMAAI.createTransferJob
    local originalStart=FMAJobs.start
    local originalEvent=FMADiagnostics.event
    local created,started=0,0
    FMAAI.createTransferJob=function()created=created+1;return {jobTypeIndex=1},nil,'GOTO' end
    FMAJobs.start=function()started=started+1 end
    FMADiagnostics.event=function()end
    local obj={posX=25,posZ=0,getIsInUse=function()return true end}
    local record={object=obj,key='test20',busy=false}
    local task={id='task20',kind='fieldStage',state='running'}
    local plan={legs={{x=25,z=0},{x=50,z=0}},index=1}
    local active={task=task,vehicle=record,learnedRoutePlan=plan}
    local c={now=10000,settings={enabled=true},active={},reservations={}}
    assert(FMAPathRunner.advance(c,active,'success')==true)
    assert(created==0 and started==0 and record.busy and c.reservations.test20=='task20')
    c.now=11000;FMAPathRunner.update(c);eq(created,0)
    c.now=12500;FMAPathRunner.update(c);eq(created,0)
    obj.getIsInUse=function()return false end
    c.now=14000;FMAPathRunner.update(c)
    eq(created,1);eq(started,1);eq(plan.index,2);eq(c.pendingRouteLegs.test20,nil)
    g_currentMission=origMission;FMAAI.createTransferJob=originalCreate;FMAJobs.start=originalStart;FMADiagnostics.event=originalEvent
end)

test('road20: a position-only engine stop cannot advance the measured route',function()
    local a={task={id='t'},vehicle={object={posX=200,posZ=0}},learnedRoutePlan={legs={{x=25,z=0},{x=50,z=0}},index=1}}
    eq(FMAPathRunner.advance({settings={enabled=true}},a,'success'),false)
    assert(tostring(a.stopReason):find('nepotvrzen',1,true))
end)

test('road20: engine release timeouts unblock the farm and preserve task for retry',function()
    local original=FMADiagnostics.event;FMADiagnostics.event=function()end
    local vehicle={object={posX=25,posZ=0},key='test20',busy=true}
    local task={id='t20',state='preparing'}
    local p={task=task,vehicle=vehicle,plan={legs={{x=25,z=0},{x=50,z=0}}},nextIndex=2,after=1,deadline=100}
    local c={now=120,settings={enabled=true},pendingRouteLegs={test20=p},reservations={test20='t20'}}
    FMAPathRunner.update(c)
    assert(task.state=='pending' and task.retryAt>120 and not vehicle.busy and c.reservations.test20==nil)
    FMADiagnostics.event=original
end)

test('road20: controller distinguishes start rejection from physical navigation obstacle',function()
    assert(FMAJobs.isNavigationEvidence({dispatchRejected=true,physicalMotionVerified=true},'brání objekt')==false)
    assert(FMAJobs.isNavigationEvidence({},'FS25 odmítlo start (stav 4)')==false)
    assert(FMAJobs.isNavigationEvidence({physicalMotionVerified=true},'brání objekt')==true)
    assert(FMAJobs.isNavigationEvidence({},'bez fyzického rozjezdu')==false)
end)

test('road20: engine-start BUSY does not rotate candidate field entry',function()
    local origNeed=FMACourseplay.needsFieldStaging
    local origCreate=FMAAI.createTransferJob
    FMACourseplay.needsFieldStaging=function()return true end
    FMAAI.createTransferJob=function()return nil,'BUSY: engine still in use' end
    local task={id='stage',label='Stage',operation='harvest',x=80,z=0,fieldStageAttempts=2}
    local c={now=55000,settings={fieldStageAttempts=5}}
    local started,why,method=FMACourseplay.stageFieldwork(c,task,{key='a'})
    assert(started and method=='WAIT' and task.fieldStageAttempts==2 and task.retryAt==67000)
    FMACourseplay.needsFieldStaging=origNeed;FMAAI.createTransferJob=origCreate
end)

end
