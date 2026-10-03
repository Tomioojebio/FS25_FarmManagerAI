return function(test,eq)
local function machine(level,kind)
    local tool={spec_fillUnit={fillUnits={{capacity=1000}}},spec_sprayer=true}
    tool.getFillUnits=function(self)return self.spec_fillUnit.fillUnits end
    tool.getFillUnitFillType=function()return kind end
    tool.getFillUnitFillLevel=function()return level.value end
    tool.getFillUnitCapacity=function()return 1000 end
    local obj={posX=0,posZ=0,ownerFarmId=1}
    obj.getAttachedImplements=function()return {{object=tool}} end
    return {key='crystal',object=obj}
end
local oldFill=FillType
FillType={LIME=17,FERTILIZER=18,DIESEL=9}
test('25: lime staying 100 percent is not proof of field application',function()
    local level={value=1000};local r=machine(level,17)
    local task={id='field:5:lime',operation='lime'}
    FMAWorkEvidence.begin({now=1000},task,r)
    FMAWorkEvidence.sample({now=2000},task,r)
    local yes,why=FMAWorkEvidence.verify(task,r)
    eq(yes,false);assert(why:find('spotřebu',1,true))
end)
test('25: actual consumed lime validates physical application',function()
    local level={value=1000};local r=machine(level,17)
    local task={id='field:5:lime',operation='lime'}
    FMAWorkEvidence.begin({now=1000},task,r)
    level.value=777;r.object.posX=20
    FMAWorkEvidence.sample({now=12000},task,r)
    local yes=FMAWorkEvidence.verify(task,r)
    eq(yes,true);assert(task.workEvidence.observedMove>=19)
end)
test('25: other fluid may not be mistaken for lime',function()
    local level={value=1000};local r=machine(level,9)
    local task={id='field:5:lime',operation='lime'}
    eq(FMAWorkEvidence.measure(r,'lime'),nil)
    FMAWorkEvidence.begin({now=1000},task,r)
    eq(FMAWorkEvidence.verify(task,r),false)
end)
test('25: STOP targets the whole identified harvest crew, not other fields',function()
    local harvest={id='field:32:harvest',label='Sklizeň 32',crewId='harvest:32:LEXION',state='running'}
    local ha={id='support:harvest:32:LEXION:JD',kind='support',parentGroup=harvest.crewId}
    local other={id='support:other',kind='support',parentGroup='harvest:7:other'}
    local stopped={};local orig=FMAAI.stop
    FMAAI.stop=function(job) stopped[#stopped+1]=job end
    local a,b,d={isRunning=true},{isRunning=true},{isRunning=true}
    local controller={active={[a]={task=harvest},[b]={task=ha},[d]={task=other}},
      settings={selectedJobsOnly=true},externalFieldwork={},preparedSupport={},reservations={},
      notify=function()end}
    FMAHud.stopTask(controller,harvest)
    FMAAI.stop=orig
    eq(#stopped,2);eq(harvest.ownerStopRequested,true);eq(harvest.state,'paused')
    assert(stopped[1]~=d and stopped[2]~=d)
end)
test('25: wide combine requests at least three headlands',function()
    local value={};local function cell(n)
        return {getValue=function()return n end,setFloatValue=function(self,v)value[self]=v end,setValue=function(self,v)value[self]=v end}
    end
    local width,radius,head=cell(12),cell(8),cell(2)
    local spec={workWidth=width,turningRadius=radius,numberOfHeadlands=head}
    local vehicle={getCourseGeneratorSettings=function()return spec end}
    local saved=AIUtil;AIUtil=nil
    local configured,why,details=FMAFieldQuality.configure(vehicle,{operation='harvest'},{settings={minHeadlands=2,maxHeadlands=6}})
    AIUtil=saved
    assert(configured,tostring(why));eq(details.headlands,3);eq(value[head],3)
end)
test('25: verified lime needs physical travel as well as material consumption',function()
    local level={value=1000};local r=machine(level,17)
    local task={id='field:5:lime',operation='lime',fieldworkStartedAt=1000}
    FMAWorkEvidence.begin({now=1000},task,r)
    level.value=650;FMAWorkEvidence.sample({now=2000},task,r)
    eq(FMAWorkEvidence.verify(task,r),false)
    r.object.posZ=20;FMAWorkEvidence.sample({now=3000},task,r)
    eq(FMAWorkEvidence.verify(task,r),true)
end)
test('25: full spreader cannot satisfy world verification even if field shows needsLime false',function()
    local c=FMAController.new and FMAController.new() or {}
    local t={kind='field',id='field:5:lime',fieldId='5',operation='lime',fieldworkStartedAt=100,fingerprint='old'}
    c.fieldsById={['5']={valid=true,mixed=false,needsLime=false,fingerprint='changed'}}
    eq(select(1,FMAController.verifyFieldOrderComplete(c,t)),false)
    t.workEvidence={vehicleKey='crystal',first=1000,minimum=1000,capacity=1000,observedMove=200}
    eq(select(1,FMAController.verifyFieldOrderComplete(c,t)),false)
    t.workEvidence.minimum=440
    eq(select(1,FMAController.verifyFieldOrderComplete(c,t)),true)
end)
test('25: old completed route can be retraced only by same machine and attachment type',function()
    local vehicle={key='jd',object={posX=60,posZ=0}}
    local points={}
    for x=0,60,10 do points[#points+1]={x=x,z=0} end
    local route={vehicle='jd',footprint='SOLO',from=points[1],finish=points[#points],points=points}
    local c={navigationMap={routes={replay=route}}}
    local plan=FMAPathRunner.reverseObserved(c,vehicle,{x=0,z=0},{x=60,z=0})
    assert(plan and plan.source=='OBSERVED_REVERSE' and #plan.legs>=2)
    eq(FMAPathRunner.reverseObserved(c,{key='different',object=vehicle.object},{x=0,z=0},{x=60,z=0}),nil)
    route.points[4]={x=900,z=0}
    eq(FMAPathRunner.reverseObserved(c,vehicle,{x=0,z=0},{x=60,z=0}),nil)
end)
test('25: harvesting starts Courseplay unloader BEFORE bin reaches 80 percent',function()
    local origCP=FMACourseplay.available;local origUnloader=FMACourseplay.startCombineUnloader
    local origHarvest=FMAHaulageCycle.harvesterWorking;local origNear=FMAHaulageCycle.nearField
    local origDest=FMALogistics.bestDestination;local origManual=FMAGameNative.isManuallyControlled
    local origMay=FMAJobs.mayStart
    local hit=false;local job={fmaCourseplayPublicStart=true}
    FMACourseplay.available=function()return true end
    FMACourseplay.startCombineUnloader=function()hit=true;return job end
    FMAHaulageCycle.harvesterWorking=function()return true end
    FMAHaulageCycle.nearField=function()return true end
    FMALogistics.bestDestination=function()return {name='own silo'} end
    FMAGameNative.isManuallyControlled=function()return false end
    FMAJobs.mayStart=function()return true end
    local tractor={key='jd',name='JD',object={posX=0,posZ=0},busy=false}
    local harvester={key='lexion',name='LEXION',object={posX=6,posZ=0}}
    local parent={id='field:32:harvest',fieldId='32',ownerApproved=true}
    local crew={id='harvest:32:lexion',harvester=harvester,unloaders={tractor},parentTask=parent,fieldId='32',fillType=10}
    local c={settings={enabled=true,harvestTeams=true,selectedJobsOnly=true,maxWorkers=3,autoSellOutputs=false},
        workgroups={[crew.id]=crew},harvestTelemetry={lexion={fill=100,capacity=10000,rate=100}},
        fieldsById={['32']={x=6,z=0}},reservations={},preparedSupport={},active={},now=1000,
        farmId=1,notify=function()end,issue=function()end}
    local started=FMAFleetCoordinator.dispatchSupport(c)
    FMACourseplay.available=origCP;FMACourseplay.startCombineUnloader=origUnloader
    FMAHaulageCycle.harvesterWorking=origHarvest;FMAHaulageCycle.nearField=origNear
    FMALogistics.bestDestination=origDest;FMAGameNative.isManuallyControlled=origManual
    FMAJobs.mayStart=origMay
    eq(hit,true);eq(started,true);eq(c.active[job].vehicle.key,'jd')
end)
test('25: owner STOP preserves assigned crew IDs for explicit later START',function()
    local tid='field:32:harvest';local cid='harvest:32:lexion'
    local t={id=tid,kind='field',operation='harvest',fieldId='32',state='paused',ownerStopRequested=true,
        ownerApproved=false,crewId=cid}
    local combine={key='lexion',object={posX=0,posZ=0},name='LEXION'}
    local c={settings={selectedJobsOnly=true,maxUnloaders=1,maxWorkers=4},workgroups={},
        tasks={[tid]=t},fieldsById={['32']={x=0,z=0}},vehicles={combine},vehicleByKey={lexion=combine},active={},
        reservations={},preparedSupport={},crewAssignments={[cid]={id=cid,taskId=tid,taskRef=t,harvesterKey='lexion',unloaderKeys={'jd'}}},
        now=1000,issue=function()end,settings={selectedJobsOnly=true,maxUnloaders=1,maxWorkers=4}}
    FMAFleetCoordinator.planHarvestTeams(c)
    assert(c.crewAssignments[cid]);eq(c.crewAssignments[cid].unloaderKeys[1],'jd')
    eq(c.crewAssignments[cid].pausedByOwner,true)
    eq(next(c.workgroups),nil)
end)
FillType=oldFill
end
