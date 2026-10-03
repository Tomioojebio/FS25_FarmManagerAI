return function(test,eq)
local function fixture()
    local c=FMAController.new();c.farmId=1;c.initialized=true;c.settings.enabled=true;c.now=10000
    c.notify=function()end
    return c
end
local function record(key)
    return {key=key,name=key,object={ownerFarmId=1,uniqueId=key,posX=0,posZ=0},x=0,z=0,capabilities={transport=true}}
end
test('24: STOP order cannot be adopted again by a manually running CP worker',function()
    local c=fixture();c.settings.enabled=true;c.settings.selectedJobsOnly=true
    local r=record('harv');r.object.getIsAIActive=function()return true end
    r.object.getIsCpFieldWorkActive=function()return true end
    r.object.getIsCpActive=function()return true end
    r.object.hasCpCourse=function()return true end
    r.object.cpGetFieldPosition=function()return 10,20 end
    local t={id='field:32:harvest',kind='field',operation='harvest',state='paused',fieldId='32',x=10,z=20,preferredVehicleKey='harv',ownerStopRequested=true,ownerApproved=false}
    c.tasks={[t.id]=t};c.vehicleByKey={harv=r};c.vehicles={r}
    FMACourseplay.adoptExistingFieldwork(c)
    eq(t.state,'paused');eq(c.externalFieldwork.harv,nil)
end)

test('24: unloader near working combine is not re-routed to another invalid field point',function()
    local c=fixture();c.settings.enabled=true;c.settings.selectedJobsOnly=true
    local h=record('harv');h.object.posX=105;h.object.posZ=205;h.object.getIsCpFieldWorkActive=function()return true end
    local u=record('haul');u.x=114;u.z=211;u.object.posX=114;u.object.posZ=211
    local t={id='field:32:harvest',kind='field',state='running',operation='harvest',fieldId='32',ownerApproved=true}
    local group={harvester=h,parentTask=t,fieldId='32'}
    c.tasks={[t.id]=t};c.vehicles={u,h};c.fieldsById={['32']={x=500,z=500,object={polygonPoints={}}}}
    c.workgroups={[t.id]=group}
    eq(FMAHaulageCycle.nearField(c,group,u),true)
    local old=FMAAI.createTransferJob;FMAAI.createTransferJob=function() error('route must not start') end
    local ok=FMAFleetCoordinator.startStageToField(c,t,u,1,nil)
    FMAAI.createTransferJob=old
    eq(ok,true);eq(FMAFleetCoordinator.getPreparedRole(c,t,1).state,'WAITING_FIELD')
    assert(c.reservations.haul)
end)

test('24: combine unloader starts via vehicle-bound public Courseplay job',function()
    local c=fixture();local u=record('6r')
    local station={};local p={}
    local function setter()return {setPosition=function()end,setAngle=function()end} end
    p.fieldPosition=setter();p.startPosition=setter()
    p.useFieldUnload={setValue=function()end};p.useGiantsUnload={setValue=function()end}
    p.unloadingStation={setValue=function(self,id) self.id=id end,getUnloadingStation=function()return station end}
    local job={cpJobParameters=p,applyCurrentState=function()end}
    u.object.getCanStartCpCombineUnloader=function()return true end
    u.object.getCpCombineUnloaderJob=function()return job end
    u.object.getIsAIActive=function()return false end
    local calls=0
    u.object.startCpAtFirstWp=function()calls=calls+1;return true end
    local oldB=FMACourseplay.boundary;local oldN=NetworkUtil
    FMACourseplay.boundary=function()return true end
    NetworkUtil={getObjectId=function()return 99 end}
    local result,why=FMACourseplay.startCombineUnloader(c,u,{x=12,z=23},station,false)
    FMACourseplay.boundary=oldB;NetworkUtil=oldN
    eq(result,job);eq(calls,1);eq(job.fmaCourseplayPublicStart,true)
end)


test('24: adopted manual combine creates a persistent crew so a JD unloader may join',function()
    local c=fixture();c.settings.enabled=true;c.settings.selectedJobsOnly=true;c.crewAssignments={}
    local h=record('lexion');h.object.posX=10;h.object.posZ=20
    h.object.getIsAIActive=function()return true end
    h.object.getIsCpFieldWorkActive=function()return true end
    h.object.getIsCpActive=function()return true end
    h.object.hasCpCourse=function()return true end
    h.object.cpGetFieldPosition=function()return 10,20 end
    local t={id='field:32:harvest',kind='field',operation='harvest',state='pending',fieldId='32',x=10,z=20,
        preferredVehicleKey='lexion',ownerApproved=true}
    c.tasks={[t.id]=t};c.vehicles={h};c.vehicleByKey={lexion=h}
    FMACourseplay.adoptExistingFieldwork(c)
    eq(t.state,'running')
    assert(t.crewId and c.crewAssignments[t.crewId])
end)

test('24: unloader is confirmed only when the actual CP strategy is active',function()
    local c=fixture();c.now=12000
    local u=record('jd');local job={isRunning=false}
    u.object.getIsCpCombineUnloaderActive=function()return true end
    local t={id='support:harvest:jd',kind='support',state='running'}
    c.active={[job]={job=job,vehicle=u,task=t,start=10000,startPendingUnloader=true}}
    FMACourseplay.confirmPendingFieldwork(c)
    eq(c.active[job].startPendingUnloader,false)
    eq(t.phase,'ODVOZCE · COURSEPLAY PŘEVZAL')
end)

end
