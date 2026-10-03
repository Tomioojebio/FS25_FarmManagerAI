-- Contract regressions for the 0.8.1 / 0.10.3 merge. These use engine doubles.
return function(test,eq)
local function fixture()
    local c=FMAController.new();c.farmId=1;c.initialized=true;c.supported=true;c.settings.enabled=true;c.now=10000
    c.loose={};c.notify=function(self,text)self.lastMessage=text end
    return c
end
local function record(key)
    local o={ownerFarmId=1,uniqueId=key or 'v',posX=0,posZ=0}
    return {object=o,key=key or 'v',name=key or 'Vehicle',x=0,z=0,capabilities={}}
end
local function task()return {id='field:5:foragePickup',kind='field',fieldId='5',operation='foragePickup',label='Pickup',priority=50,state='running'} end
local function triggerFixture()
    local o={getFillUnitAllowsFillType=function()return true end,getFillUnitSupportsToolType=function()return true end}
    local trigger={setIsLoading=function()end,getSupportAILoading=function()return true end,
        getIsFillTypeSupported=function()return true end,getAllowsActivation=function()return true end,
        source={getIsFillAllowedToFarm=function(_,farmId)return farmId==1 end},fillableObjects={[10]={object=o,fillUnitIndex=2}}}
    return o,trigger
end

test('live status renders even without AUTO and does not mistake carrier for cutter',function()
    local c=fixture();c.settings.enabled=false
    local combine=record('lexion');combine.name='LEXION 6900';combine.isGrainCombine=true
    local state=FMALiveTelemetry.snapshot({now=12000,settings={enabled=false},vehicles={combine},tasks={a={id='field:32:harvest',state='pending',operation='harvest',phase='ASSEMBLE'}},active={},reservations={}})
    assert(state:find('AUTO=false',1,true));assert(state:find('LEXION 6900',1,true))
    assert(state:find('field:32:harvest',1,true));assert(state:find('cutter=-',1,true))
end)
test('a single unloader cannot be assigned to two unfinished harvest crews',function()
    local c=fixture();local r=record('6r');local t1={id='field:32:harvest'};local t2={id='field:7:harvest'}
    c.preparedSupport={[t1.id]={[1]={record=r,state='WAITING_FIELD'}},[t2.id]={[1]={state='NEEDED'}}}
    eq(FMAFleetCoordinator.ownCrewVehicle(c,t2,r),false)
    eq(FMAFleetCoordinator.ownCrewVehicle(c,t1,r),true)
    c.preparedSupport[t1.id][1].state='BLOCKED'
    eq(FMAFleetCoordinator.ownCrewVehicle(c,t2,r),true)
end)
test('road AI cannot block crew after four attempts at distinct goals',function()
    local c=fixture();local r=record('6r');c.now=10000
    for i=1,4 do FMAFleetCoordinator.noteStageRouteFailure(c,r,'goal invalid',false) end
    local locked=FMAFleetCoordinator.roadBackoff(c,r);eq(locked,false)
    FMAFleetCoordinator.noteStageRouteFailure(c,r,'all goals exhausted',true)
    locked=FMAFleetCoordinator.roadBackoff(c,r);eq(locked,true)
    c.now=10100;r.x=40;r.object.posX=40
    locked=FMAFleetCoordinator.roadBackoff(c,r);eq(locked,false)
end)
test('generic recovery must not reset parent fieldwork for a failed support stage',function()
    local c=fixture();local t={id='field:32:harvest',state='running',phase='PRÁCE',operation='harvest'}
    c.tasks={[t.id]=t}
    local a={stopReason='RECOVERY_REROUTE',task={id='supportStage:'..t.id..':1',kind='supportStage',parentTaskId=t.id}}
    eq(FMARecovery.onStopped(c,a),false)
    eq(t.state,'running');eq(t.phase,'PRÁCE')
end)
test('registered numeric index does not disguise an unknown job class',function()
    local ok=FMAJobs.ensureType({jobTypeIndex=1})
    eq(ok,false)
end)
test('shared start gate prevents physical jobs while AUTO is off',function()
    local c=fixture();c.settings.enabled=false
    local r=record();local j=FMAJobs.create('GOTO');j.vehicle=r.object
    local old=FMAJobs.controller;FMAJobs.controller=c
    local calls=0;local ok=pcall(FMAJobs.start,{startJob=function()calls=calls+1 end},j,1)
    FMAJobs.controller=old;eq(ok,false);eq(calls,0)
end)
test('unknown termination is not a successful harvest',function()eq(FMAJobs.outcome(nil),'unknown')end)
test('courseplay fieldwork uses public starter and waits for runtime confirmation',function()
    local c=fixture();local r=record('cpv');local t=task();t.operation='harvest';t.id='field:32:harvest';t.label='Harvest'
    local job={isRunning=false};r.object.hasCpCourse=function()return true end;r.object.updateAIFieldWorkerImplementData=function()end
    r.object.getCanStartCpFieldWork=function()return true end;r.object.spec_cpAIFieldWorker={cpJobStartAtFirstWp=job}
    r.object.startCpAtFirstWp=function()return true end
    local got=FMACourseplay.startFieldwork(c,r,t);eq(got,job);eq(job.fmaCourseplayPublicStart,true)
end)
test('remote Courseplay fieldwork is staged by native transfer before direct CP start',function()
    local c=fixture();c.settings.enabled=true;c.settings.fieldStageRadius=180;c.settings.fieldStageAttempts=5
    local r=record('x9');r.x=900;r.z=-740;r.object.posX=900;r.object.posZ=-740
    local t=task();t.id='field:32:harvest';t.kind='field';t.operation='harvest';t.label='Sklizeň';t.x=115;t.z=-174;t.fieldId='32'
    c.fieldsById={['32']={x=115,z=-174,object={polygonPoints={}}}};c.tasks={[t.id]=t};c.vehicleByKey={[r.key]=r};c.vehicles={r}
    local oldTransfer=FMAAI.createTransferJob
    local started=0
    FMAAI.createTransferJob=function(_,_,target) assert(target.x~=nil and target.z~=nil);return {isRunning=false,setValues=function()end},nil,'GIANTS_GOTO' end
    local oldStart=FMAJobs.start;FMAJobs.start=function()started=started+1 end
    local ok=FMACourseplay.stageFieldwork(c,t,r)
    FMAAI.createTransferJob=oldTransfer;FMAJobs.start=oldStart
    eq(ok,true);eq(started,1);eq(t.state,'preparing');assert(t.phase:find('PŘEJEZD K POLI',1,true)~=nil)
end)

test('manual Courseplay fieldwork is adopted instead of rejected as busy',function()
    local c=fixture();c.settings.enabled=true
    local r=record('x9');r.x=120;r.z=-175;r.object.posX=120;r.object.posZ=-175
    local t=task();t.id='field:32:harvest';t.kind='field';t.operation='harvest';t.state='pending';t.x=115;t.z=-174;t.preferredVehicleKey='x9';t.ownerApproved=true;c.tasks={[t.id]=t};c.vehicles={r};c.vehicleByKey={x9=r}
    r.object.getIsAIActive=function()return true end;r.object.getIsEntered=function()return true end
    r.object.getIsCpFieldWorkActive=function()return true end;r.object.getIsCpActive=function()return true end
    r.object.hasCpCourse=function()return true end;r.object.cpGetFieldPosition=function()return 115,-174 end
    FMACourseplay.adoptExistingFieldwork(c)
    eq(t.state,'running');eq(t.phase,'PRÁCE · COURSEPLAY (PŘEVZATO)');assert(t.fieldworkStartedAt~=nil)
end)


test('manual Courseplay overrides a stale manager path block for the same crew',function()
    local c=fixture();c.settings.enabled=true
    local r=record('x9');r.x=120;r.z=-175;r.object.posX=120;r.object.posZ=-175
    local t=task();t.id='field:32:harvest';t.kind='field';t.operation='harvest';t.state='blocked';t.reason='nebyla nalezena žádná cesta';t.x=115;t.z=-174;t.preferredVehicleKey='x9';t.ownerApproved=true;c.tasks={[t.id]=t};c.vehicles={r};c.vehicleByKey={x9=r}
    r.object.getIsAIActive=function()return true end;r.object.getIsEntered=function()return true end
    r.object.getIsCpFieldWorkActive=function()return true end;r.object.getIsCpActive=function()return true end
    r.object.hasCpCourse=function()return true end;r.object.cpGetFieldPosition=function()return 115,-174 end
    FMACourseplay.adoptExistingFieldwork(c)
    eq(t.state,'running');eq(t.reason,'Dispečink převzal již běžící pracovní job bez jeho restartu');assert(t.fieldworkStartedAt~=nil)
end)

test('existing manual Courseplay course on the requested field is reused',function()
    local c=fixture();local r=record('x9');local t=task();t.id='field:32:harvest';t.operation='harvest';t.x=115;t.z=-174
    local oldLoaded,oldAI=g_modIsLoaded,AIUtil;g_modIsLoaded={FS25_Courseplay=true};AIUtil={hasCutterOnTrailerAttached=function()return false end}
    r.object.hasCpCourse=function()return true end;r.object.cpGetFieldPosition=function()return 115,-174 end;r.object.getCpSettings=function()return {} end
    local ready,waiting=FMAFieldQuality.ensureCourse(c,t,r)
    g_modIsLoaded,AIUtil=oldLoaded,oldAI
    eq(ready,true);eq(waiting,false);eq(t.qualityCourseReady,true);eq(t.courseVehicleKey,'x9')
end)

test('courseplay start is not counted as fieldwork until CP confirms active',function()
    local c=fixture();local r=record('cpv');local t=task();t.operation='harvest';t.id='field:32:harvest';t.label='Harvest'
    local job={isRunning=false};c.active[job]={job=job,task=t,vehicle=r,start=c.now,lastProgress=c.now,startPendingCp=true}
    r.object.getIsCpFieldWorkActive=function()return false end
    FMACourseplay.confirmPendingFieldwork(c);eq(t.fieldworkStartedAt,nil);eq(c.active[job].startPendingCp,true)
    r.object.getIsCpFieldWorkActive=function()return true end;r.object.getJob=function()return job end
    FMACourseplay.confirmPendingFieldwork(c);eq(c.active[job].startPendingCp,false);assert(t.fieldworkStartedAt~=nil);eq(t.state,'running')
end)
test('manual relocation reopens only path blocked task for same vehicle',function()
    local c=fixture();local r=record('moved');c.vehicleByKey={moved=r};c.vehicles={r}
    local t=task();t.id='field:32:harvest';t.state='blocked';t.vehicleKey='moved';t.reason='nebyla nalezena žádná cesta';c.tasks={[t.id]=t}
    c.jobFailures[t.id]={vehicleKey='moved',reason='No path found',blocked=true,retryAt=999999}
    local oldMission=g_currentMission
    g_currentMission.vehicleSystem={getVehicles=function()return {r.object} end};g_currentMission.placeableSystem={placeables={}}
    r.object.posX=20;r.object.posZ=0
    c.worldRegistry={vehicles={moved={key='moved',object=r.object,rootKey='moved',x=0,z=0}},placeables={},revision=0,lastScan=-100000}
    FMAWorldRegistry.update(c,true)
    g_currentMission=oldMission
    eq(t.state,'pending');eq(c.jobFailures[t.id],nil)
end)

test('full cargo is distinguished from completion',function()
    local old=AIMessageErrorIsFull;AIMessageErrorIsFull={}
    eq(FMAJobs.outcome({isa=function(_,class)return class==AIMessageErrorIsFull end}),'full')
    AIMessageErrorIsFull=old
end)
test('repeated job failure backs off and eventually blocks',function()
    local c=fixture();local t=task();local r=record()
    FMAJobs.fail(c,t,r,'test');eq(FMAJobs.mayStart(c,t.id),false)
    c.now=40000;eq(FMAJobs.mayStart(c,t.id),true)
    FMAJobs.fail(c,t,r,'test');c.now=100000;FMAJobs.fail(c,t,r,'test');c.now=999999
    eq(FMAJobs.mayStart(c,t.id),false)
end)
test('error in one completion callback does not skip another vehicle',function()
    local c=fixture();local j1,j2={},{};local processed=0
    c.active[j1]={vehicle=record('a'),task=task()};c.active[j2]={vehicle=record('b'),task=task()}
    c.handleJobStopped=function(self,j)processed=processed+1;self.active[j]=nil;if j==j1 then error('expected completion fixture') end end
    c:onJobStopped(j1,{});c:onJobStopped(j2,{})
    c:drainStoppedJobs();eq(processed,2);eq(next(c.active),nil)
end)
test('synchronous stop notification is deferred until dispatcher transaction ends',function()
    local c=fixture();local j={};local calls=0
    c:onJobStopped(j,{})
    c.active[j]={vehicle=record(),task=task()}
    c.handleJobStopped=function(self,job)calls=calls+1;self.active[job]=nil end
    eq(calls,0);c:drainStoppedJobs();eq(calls,1)
end)
test('owner pause does not create a false job failure',function()
    local c=fixture();c.settings.enabled=false;local j={};local t=task();local r=record()
    c.active[j]={task=t,vehicle=r};c.reservations[r.key]=t.id
    c:handleJobStopped(j,nil);eq(t.state,'paused');eq(next(c.jobFailures),nil);eq(c.reservations[r.key],nil)
end)
test('player takeover cancels a stationary refill and its reservation',function()
    local c=fixture();local r=record();r.object.getIsEntered=function()return true end
    local t=task();local stopped=false
    c.refillSessions.x={vehicle=r,parent=t,requirement={object={},fillUnitIndex=1,fillType=1},trigger={setIsLoading=function(_,state)stopped=state==false end}}
    c.reservations[r.key]='fill';r.busy=true
    FMALifecycle.update(c);eq(stopped,true);eq(next(c.refillSessions),nil);eq(r.busy,false);eq(t.state,'paused')
end)
test('foreign attached implement prevents the whole assembly from starting',function()
    local c=fixture();local r=record();r.object.getAttachedImplements=function()return {{object={ownerFarmId=2}}} end
    eq(FMALifecycle.allowed(c,r,false),false)
end)
test('preflight retains stationary reservations and clears only abandoned ones',function()
    local c=fixture();local r=record();local other=record('other');c.vehicles={r,other}
    c.refillSessions.x={vehicle=r,parent=task()};c.reservations[r.key]='refill';c.reservations.other='abandoned'
    c:reconcileRuntimeState();eq(c.reservations[r.key],'refill');eq(c.reservations.other,nil);eq(r.busy,true)
end)
test('preflight retains a header carrier through work on the field',function()
    local c=fixture();local t=task();t.headerTransportReady=true;t.headerTransportPlan={carrier={key='carrier'}}
    c.tasks[t.id]=t;c.implementReservations.carrier=t.id
    c:reconcileRuntimeState();eq(c.implementReservations.carrier,t.id)
end)
test('preflight rejects missing native AI without enabling AUTO',function()
    local c=fixture();c.settings.enabled=false;local old=g_currentMission.aiSystem;g_currentMission.aiSystem=nil
    local ok=c:preflightAutomation();g_currentMission.aiSystem=old
    eq(ok,false);eq(c.settings.enabled,false)
end)
test('preflight accepts a loaded empty farm without inventing work',function()
    local c=fixture();local ok,report=c:preflightAutomation();eq(ok,true);eq(report.pending,0)
end)
test('issue counter separates technical faults from normal farm actions',function()
    local c=fixture();c.issues={}
    c:issue('runtime','Runtime fault','boom',100)
    c:issue('fuel:v','Low fuel','refill',95)
    c:issue('mapProfile','Map profile','generic mode',35)
    local counts=c:issueCounts()
    eq(counts.error,1);eq(counts.action,1);eq(counts.info,0);eq(counts.warning,1);eq(counts.total,3)
end)
test('target-map AUTO keeps running when optional Courseplay transfer bridge is broken',function()
    local c=fixture();c.settings.enabled=false;c.settings.preferCourseplay=true;c.mapProfile={active=true}
    local oldAvailable=FMACourseplay.available;local oldEnsure=FMATransfer.ensureRegistered;local oldStatus=FMATransfer.runtimeStatus
    FMACourseplay.available=function()return true end
    FMATransfer.ensureRegistered=function()return false,'bridge missing' end
    FMATransfer.runtimeStatus=function()return {vehicleReady=false} end
    local ok,report=c:preflightAutomation()
    FMACourseplay.available=oldAvailable;FMATransfer.ensureRegistered=oldEnsure;FMATransfer.runtimeStatus=oldStatus
    eq(ok,true);eq(#report.errors,0);assert(#report.warnings>0)
end)
test('unknown operation is rejected before indexing its capability',function()
    local v,why=FMAPlanner.chooseVehicle({operation='notRegistered'},nil,nil,nil)
    eq(v,nil);assert(why)
end)
test('a waiting delivery keeps other field jobs out of the same field',function()
    local c=fixture();local t=task();t.state='waiting';c.tasks[t.id]=t
    eq(FMALifecycle.fieldBusy(c,{id='other',fieldId='5'}),true)
    eq(FMALifecycle.fieldBusy(c,t),false)
end)
test('completed traffic retry clears its age for a later journey',function()
    local c=fixture();local r=record();local t=task();local calls=0
    FMALifecycle.defer(c,'wait',r,t,function()calls=calls+1;return true end,'occupied')
    c.now=c.now+6000;FMALifecycle.update(c)
    eq(calls,1);eq(t.trafficWaitingSince,nil);eq(next(c.deferred),nil)
end)
test('traffic timeout blocks without launching a vehicle',function()
    local c=fixture();local r=record();local t=task();local calls=0
    FMALifecycle.defer(c,'wait',r,t,function()calls=calls+1;return true end,'occupied')
    c.now=c.now+300001;FMALifecycle.update(c);eq(calls,0);eq(t.state,'blocked');eq(c.reservations[r.key],nil)
end)
test('attachment completion waits for the real root vehicle',function()
    local c=fixture();local r=record();local t=task();local attached=false;local calls=0
    local tool={key='implement',name='Tool',object={ownerFarmId=1,getRootVehicle=function()return attached and r.object or {} end}}
    FMAAssembler.confirm(c,t,{power=r,tool=tool},function()calls=calls+1 end)
    FMAAssembler.update(c);eq(calls,0);eq(c.reservations[r.key],t.id)
    attached=true;FMAAssembler.update(c);eq(calls,1);eq(c.reservations[r.key],nil)
end)
test('full forage load resumes the same field and machine after delivery',function()
    local c=fixture();local t=task();local r=record();t.resumeAfterDelivery=true
    c.forageStages['5']='windrowed';eq(FMAForageCoordinator.resumeAfterDelivery(c,t,r),true)
    eq(t.state,'pending');eq(t.resumeAtLast,true);eq(t.preferredVehicleKey,r.key);eq(c.forageStages['5'],'windrowed')
end)
test('fuel is never mistaken for bulk cargo',function()
    local o={spec_dischargeable={dischargeNodes={{fillUnitIndex=2}}}}
    eq(FMAModHubAdapter.cargoUnit(o,1),false);eq(FMAModHubAdapter.cargoUnit(o,2),true)
end)
test('nearby refill point cannot remotely fill an out of range tank',function()
    local o,t=triggerFixture();t.fillableObjects={}
    eq(FMARefillManager.canLoad(t,o,2,1,1),false)
end)
test('wrong tank in the trigger cannot authorize another fill unit',function()
    local o,t=triggerFixture();eq(FMARefillManager.canLoad(t,o,1,1,1),false)
end)
test('a real permitted trigger authorizes the exact tank',function()
    local old=ToolType;ToolType={TRIGGER=1};local o,t=triggerFixture()
    eq(FMARefillManager.canLoad(t,o,2,1,1),true);ToolType=old
end)
test('occupied loading trigger cannot be stolen by the manager',function()
    local o,t=triggerFixture();t.isLoading=true;eq(FMARefillManager.canLoad(t,o,2,1,1),false)
end)
test('farm access to loading source is checked at arrival',function()
    local o,t=triggerFixture();eq(FMARefillManager.canLoad(t,o,2,1,2),false)
end)
test('bale store rejects an unverified bale type and insufficient capacity',function()
    local c=fixture();c.settings.baleStorageReserve=0
    c.baleStorages={{x=1,z=1,free=2,storedFillTypes={},object={getObjectStorageSupportsFillType=function()return true end}}}
    eq(FMABaleStorage.find(c,record(),{}),nil);eq(FMABaleStorage.find(c,record(),{[1]=3}),nil)
end)
test('empty bale loader without confirmed storage intake is not success',function()
    local c=fixture();local t=task();local r=record();local storage={name='Store',object={spec_objectStorage={numStoredObjects=5}}}
    c.baleUnloadSessions.v={record=r,parent=t,loader={spec_baleLoader={},getLoadedBales=function()return {}end},storage=storage,start=c.now,expectedBales=2,storedBefore=5}
    FMABaleStorage.update(c);assert(c.baleUnloadSessions.v);eq(t.state,'running')
    c.now=c.now+45001;FMABaleStorage.update(c);eq(c.baleUnloadSessions.v,nil);eq(t.state,'blocked')
end)
test('confirmed bale storage intake resumes a partly collected field',function()
    local c=fixture();c.settings.autoReturn=false;local t=task();t.resumeAfterDelivery=true
    c.baleUnloadSessions.v={record=record(),parent=t,loader={spec_baleLoader={},getLoadedBales=function()return {}end},storage={name='Store',object={spec_objectStorage={numStoredObjects=7}}},start=c.now,expectedBales=2,storedBefore=5}
    FMABaleStorage.update(c);eq(t.state,'pending');eq(t.resumeAtLast,true);eq(c.baleUnloadSessions.v,nil)
end)
test('bunker discharge outside the real inner area is forbidden',function()
    local old=getWorldTranslation;getWorldTranslation=function()return 30,0,30 end
    local b={object={bunkerSiloArea={inner={sx=0,sz=0,wx=10,wz=0,hx=0,hz=20}}}}
    eq(FMABunkerCoordinator.insideDischarge(b,{getCanDischargeToGround=function()return true end},{node=1}),false)
    getWorldTranslation=old
end)
test('bunker discharge requires actual permission to tip on ground',function()
    local old=getWorldTranslation;getWorldTranslation=function()return 5,0,10 end
    local b={object={bunkerSiloArea={inner={sx=0,sz=0,wx=10,wz=0,hx=0,hz=20}}}}
    eq(FMABunkerCoordinator.insideDischarge(b,{getCanDischargeToGround=function()return false end},{node=1}),false)
    getWorldTranslation=old
end)
test('growing crop defers lime until crop is removed',function()
    local cfg=FMAState.new().settings
    eq(FMAPlanner.nextOperation({valid=true,alive=true,needsLime=true,needsFertilize=false,needsWeed=false,bare=false},{enabled=true,crop='WHEAT'},cfg),nil)
end)
test('joint type fallback accepts ModHub implement when optional callback is nil',function()
    local old=AttacherJoints;AttacherJoints={getAttacherJointCompatibility=function()return nil end}
    local a={spec_attacherJoints={attacherJoints={{jointType=2}}},getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end}
    local t={spec_attachable={inputAttacherJoints={{jointType=2}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end}
    local j=FMAAssembler.findJointPair(a,t,1);eq(j,1);AttacherJoints=old
end)
test('explicit false attachment compatibility still rejects pair',function()
    local old=AttacherJoints;AttacherJoints={getAttacherJointCompatibility=function()return false end}
    local a={spec_attacherJoints={attacherJoints={{jointType=2}}},getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end}
    local t={spec_attachable={inputAttacherJoints={{jointType=2}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end}
    eq(FMAAssembler.findJointPair(a,t,1),nil);AttacherJoints=old
end)
test('task procurement sees owned bare combine plus detached cutter',function()
    local c=fixture();local combine=record('lexion');combine.isGrainCombine=true;combine.object.spec_attacherJoints={attacherJoints={{jointType=1}}};combine.object.getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end
    local cutterObj={ownerFarmId=1,spec_cutter={fruitTypeIndices={7}},spec_attachable={inputAttacherJoints={{jointType=1}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end}
    local cutter={object=cutterObj,key='header',name='Header',capabilities={harvest=true},harvestFruits={[7]=true}}
    c.vehicles={combine};c.loose={cutter}
    eq(FMAAssembler.hasPotentialForTask(c,{operation='harvest',kind='field',fruitIndex=7}),true)
end)
test('preflight does not invent purchase when owned equipment can be assembled',function()
    local c=fixture();c.settings.enabled=false
    local combine=record('lexion');combine.isGrainCombine=true;combine.object.spec_attacherJoints={attacherJoints={{jointType=1}}};combine.object.getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end
    local cutterObj={ownerFarmId=1,spec_cutter={fruitTypeIndices={7}},spec_attachable={inputAttacherJoints={{jointType=1}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end}
    c.vehicles={combine};c.loose={{object=cutterObj,key='header',name='Header',capabilities={harvest=true},harvestFruits={[7]=true}}}
    c.tasks.h={id='h',state='pending',operation='harvest',kind='field',fruitIndex=7,label='Harvest'}
    local ok,report=c:preflightAutomation();eq(ok,true);eq(report.missingEquipment,0)
end)
test('diagnostic event history stays bounded',function()
    local c=fixture();for i=1,350 do FMADiagnostics.event(c,'test',i,'fixture') end
    eq(#c.journal,300);eq(c.journal[1].id,'51')
end)

test('independent haulage attachment confirmation does not block harvest parent',function()
    local c=fixture();local parent={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',state='pending'};c.tasks[parent.id]=parent
    local r=record('6r');local tool={key='wagon',name='Wagon',object={ownerFarmId=1,getRootVehicle=function()return r.object end}}
    local called=0
    FMAAssembler.confirm(c,parent,{power=r,tool=tool},function()called=called+1 end,true,'haulage:'..parent.id..':1')
    FMAAssembler.update(c)
    eq(called,1);eq(parent.state,'pending')
end)

test('staging grain haulage does not hold the combine in the yard',function()
    local c=fixture();local parent={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',state='pending'};c.tasks[parent.id]=parent
    c.preparedSupport={[parent.id]={[1]={state='STAGING',record=record('6r')}}}
    local preparing,why=FMAFleetCoordinator.preflightHarvest(c,parent,{isForageHarvester=false})
    eq(preparing,false);eq(why,nil)
end)

test('forage harvester waits until its prepared escort reaches the field',function()
    local c=fixture();local parent={id='field:6:foragePickup',kind='field',fieldId='6',operation='foragePickup',state='pending'};c.tasks[parent.id]=parent
    c.preparedSupport={[parent.id]={[1]={state='STAGING',record=record('6r')}}}
    local preparing,why=FMAFleetCoordinator.preflightHarvest(c,parent,{isForageHarvester=true})
    eq(preparing,true);eq(why,nil)
end)

test('waiting field haulage remains a live reservation without a running AI job',function()
    local c=fixture();local r=record('6r');c.preparedSupport={h={[1]={state='WAITING_FIELD',record=r}}}
    local vehicles=FMALifecycle.liveReservations(c);eq(vehicles[r.key],true)
end)

test('pending harvest prepares an already assembled transporter before main machine work',function()
    local c=fixture();local parent={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',state='pending',expectedFillType=10,priority=90,ownerApproved=true};c.tasks[parent.id]=parent
    local r=record('6r');r.capabilities.transport=true;r.transportFillTypes={[10]=true};r.capacity=20000;r.busy=false;r.lowFuel=false;c.vehicles={r}
    local old=FMAFleetCoordinator.startStageToField;local called=0
    FMAFleetCoordinator.startStageToField=function(_,p,rec,slot)called=called+1;eq(p,parent);eq(rec,r);eq(slot,1);return true end
    local started=FMAFleetCoordinator.preparePendingHarvestCrew(c,parent)
    FMAFleetCoordinator.startStageToField=old
    eq(started,true);eq(called,1)
end)

test('haulage assembly prefers a field tractor over a closer telehandler',function()
    local c=fixture();local old=AttacherJoints;AttacherJoints={getAttacherJointCompatibility=function()return nil end}
    local toolObj={ownerFarmId=1,spec_attachable={inputAttacherJoints={{jointType=2}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end}
    local tool={object=toolObj,key='wagon',name='Wagon',x=0,z=0,capabilities={transport=true},transportFillTypes={[10]=true}}
    local tele=record('tele');tele.x=1;tele.z=0;tele.hasAttacherJoints=true;tele.vehicleTypeName='teleHandler';tele.transportFillTypes={};tele.object.spec_attacherJoints={attacherJoints={{jointType=2}}};tele.object.getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end
    local tractor=record('tractor');tractor.x=20;tractor.z=0;tractor.hasAttacherJoints=true;tractor.vehicleTypeName='tractor';tractor.transportFillTypes={};tractor.object.spec_attacherJoints={attacherJoints={{jointType=2}}};tractor.object.getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end
    c.vehicles={tele,tractor};c.loose={tool}
    local plan=FMAFleetCoordinator.findTransportAssembly(c,{expectedFillType=10},10,1)
    AttacherJoints=old
    eq(plan.power.key,'tractor')
end)


test('busy owned haulage is WAITING, not missing equipment',function()
    local c=fixture();local old=AttacherJoints;AttacherJoints={getAttacherJointCompatibility=function()return true end}
    local wagonObj={ownerFarmId=1,spec_attachable={inputAttacherJoints={{jointType=2}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end}
    local wagon={object=wagonObj,key='wagon',name='Wagon',capabilities={transport=true},transportFillTypes={[10]=true}}
    local tractor=record('6r');tractor.hasAttacherJoints=true;tractor.busy=true;tractor.object.spec_attacherJoints={attacherJoints={{jointType=2}}};tractor.object.getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end
    c.vehicles={tractor};c.loose={wagon}
    local ok,power,tool,state=FMAFleetCoordinator.hasTransportPotential(c,{expectedFillType=10},10,1)
    AttacherJoints=old
    eq(ok,true);eq(power.key,'6r');eq(tool.key,'wagon');eq(state,'assembly')
end)

test('readiness audit reports own tractor and trailer instead of purchase',function()
    local c=fixture();local old=AttacherJoints;AttacherJoints={getAttacherJointCompatibility=function()return true end}
    local wagonObj={ownerFarmId=1,spec_attachable={inputAttacherJoints={{jointType=2}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end}
    local wagon={object=wagonObj,key='wagon',name='AW',capabilities={transport=true},transportFillTypes={[10]=true}}
    local tractor=record('6r');tractor.hasAttacherJoints=true;tractor.object.spec_attacherJoints={attacherJoints={{jointType=2}}};tractor.object.getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end
    local combine=record('lexion');combine.capabilities.harvest=true;combine.isGrainCombine=true;combine.harvestFruits={[7]=true}
    c.vehicles={tractor,combine};c.loose={wagon};c.fieldsById={['32']={valid=true,ready=true}}
    c.tasks.h={id='h',state='pending',operation='harvest',kind='field',fieldId='32',fruitIndex=7,expectedFillType=10,label='Harvest',priority=90}
    local audit=c:buildReadinessAudit();AttacherJoints=old
    eq(audit.h.state,'SERVICEABLE');eq(audit.h.support,'ASSEMBLE');eq(audit.h.supportVehicle,'6r');eq(audit.h.supportTool,'AW')
end)

test('stale lime task is cancelled before dispatch through living crop',function()
    local c=fixture();c.fieldsById={['5']={valid=true,alive=true,needsLime=true}}
    local ok,why=c:taskStillCurrent({kind='field',fieldId='5',operation='lime'})
    eq(ok,false);assert(tostring(why):find('živý porost',1,true)~=nil)
end)

test('field fingerprint change clears stale manual machine selections',function()
    local old={x={id='x',state='pending',fingerprint='old',preferredVehicleKey='v',preferredVehicleName='V',preferredImplementKey='i',preferredImplementName='I'}}
    local merged=FMAPlanner.merge(old,{{id='x',state='pending',fingerprint='new',x=1,z=2}},100)
    eq(merged.x.fingerprint,'new');eq(merged.x.preferredVehicleKey,nil);eq(merged.x.preferredImplementKey,nil);eq(merged.x.state,'pending')
end)


test('farm brain scales pre-harvest haulage for a large field',function()
    local c=fixture();c.settings.maxUnloaders=3;c.fieldsById={['32']={areaHa=18}}
    eq(FMAFarmBrain.supportCount(c,{operation='harvest',fieldId='32'}),3)
end)

test('forage harvester plans at least two haulage units on a useful field',function()
    local c=fixture();c.settings.maxUnloaders=3;c.fieldsById={['6']={areaHa=4}}
    eq(FMAFarmBrain.supportCount(c,{operation='foragePickup',fieldId='6'}),2)
end)

test('failed vehicle is excluded so AUTO can choose a replacement',function()
    local a=record('a');local b=record('b');a.capabilities.harvest=true;b.capabilities.harvest=true;a.isGrainCombine=true;b.isGrainCombine=true;a.harvestFruits={[7]=true};b.harvestFruits={[7]=true};a.x=1;b.x=20
    local t={operation='harvest',fruitIndex=7,x=0,z=0,failedVehicleKeys={a=true}}
    local v=FMAPlanner.chooseVehicle(t,{a,b},{},{})
    eq(v.key,'b')
end)

test('recovery converts an AUTO failure into a retry with another machine',function()
    local c=fixture();c.settings.recoveryEnabled=true;c.settings.maxRecoveryCycles=3
    local t={id='x',label='Work',state='running',priority=50,operation='plow',kind='field'};local r=record('bad');r.capabilities.plow=true
    local alt=record('good');alt.capabilities.plow=true;c.vehicles={r,alt}
    local failure={count=1,blocked=false}
    eq(FMARecovery.noteFailure(c,t,r,'blocked road',failure),true)
    eq(t.state,'pending');eq(t.failedVehicleKeys.bad,true);eq(failure.blocked,false)
end)

test('owner pinned machine is never silently replaced',function()
    local c=fixture();c.settings.recoveryEnabled=true;c.settings.maxRecoveryCycles=3
    local t={id='x',label='Work',state='running',priority=50,ownerPinnedVehicle=true};local r=record('bad')
    eq(FMARecovery.noteFailure(c,t,r,'blocked road',{count=1}),false)
end)

test('digital farm map includes fields homes and taught approach points',function()
    local c=fixture();c.fields={{id='5',name='Pole 5',x=100,z=100}};c.homePositions={v={x=1,z=2}};c.toolHomes={};c.learnedPoints={P1={x=5,z=6,role='DVŮR'}};c.mapProfile={}
    local map=FMAFarmBrain.buildDigitalMap(c)
    assert(#map.zones>=3)
end)

test('preventive service audit does not use a damaged tractor for long work by preference',function()
    local c=fixture();c.settings.preventiveServiceDamage=0.60;c.settings.criticalServiceDamage=0.85
    local v=record('v');v.damage=0.7;c.vehicles={v};FMAFarmBrain.serviceAudit(c)
    eq(v.serviceState,'PREVENTIVE');eq(#c.serviceQueue,1)
end)

test('critical service machine is rejected for a new task',function()
    local v=record('v');v.capabilities.plow=true;v.damage=0.9
    local ok,why=FMAPlanner.vehicleMatches({operation='plow',criticalServiceDamage=0.85},v,{}, {})
    eq(ok,false);eq(why,'service')
end)

test('farm brain predicts next forage crew from current mowing workflow',function()
    local c=fixture();c.settings.forageMode=3
    eq(FMAFarmBrain.nextOperationHint(c,{operation='mow'}),'windrow')
    eq(FMAFarmBrain.nextOperationHint(c,{operation='windrow'}),'foragePickup')
end)

test('prepared future crew is adopted by the real task when it appears',function()
    local c=fixture();local r=record('next');r.busy=true;c.vehicles={r};c.reservations.next='futureWait:p'
    c.preparedNextCrew={p={fieldId='5',operation='windrow',record=r,state='WAITING_FIELD'}}
    c.tasks.n={id='n',fieldId='5',operation='windrow',state='pending'}
    FMAFarmBrain.adoptPreparedNext(c)
    eq(c.tasks.n.preferredVehicleKey,'next');eq(c.reservations.next,nil);eq(r.busy,false);eq(next(c.preparedNextCrew),nil)
end)

test('strategy mode changes machine scoring without hardcoding brands',function()
    local v=record('v');v.capabilities.plow=true;v.workWidth=8;v.powerKW=250;v.requiredPowerKW=100;v.mass=12
    local fast=FMAPlanner.vehicleScore({operation='plow',kind='field',x=0,z=0,strategyMode=1},v)
    local economy=FMAPlanner.vehicleScore({operation='plow',kind='field',x=0,z=0,strategyMode=2},v)
    assert(fast~=economy)
end)

test('map UI exposes teach actions without adding another global key binding',function()
    local c=fixture();c.page=10;c.digitalMap={zones={},chokePoints={}};c.learnedPoints={};c.learnedRoutes={};c.settings.teachRole=1
    local rows=FMAHud.rows(c);eq(rows[1].object.mapAction,'role');eq(rows[2].object.mapAction,'point')
    local found={};for _,row in ipairs(rows) do if row.object and row.object.mapAction then found[row.object.mapAction]=true end end
    assert(found.route and found.parkVehicle and found.parkTool and found.organize)
end)


test('learned field route is oriented toward the requested field approach',function()
    local c=fixture();c.settings.learnedApproachRadius=35
    c.learnedRoutes={R1={id='R1',role='POLE',points={{x=0,z=0},{x=50,z=0},{x=100,z=0}}}}
    local pts=FMATeach.routeTo(c,{x=1,z=0},{x=102,z=0},'POLE')
    assert(pts and #pts>=2);assert(pts[#pts].x>=90)
end)

test('traffic reserves taught gate choke point for one convoy at a time',function()
    local c=fixture();c.settings.trafficSafety=true;c.settings.trafficLaunchIntervalSeconds=0;c.settings.trafficStartSeparation=0
    c.digitalMap={chokePoints={{id='gate',x=10,z=0,kind='BRÁNA'}}}
    local a=record('a');a.object.posX=10;a.object.posZ=0;local b=record('b');b.object.posX=10;b.object.posZ=1
    local ok=FMATraffic.canStart(c,a,{x=50,z=0},{id='a',kind='route'},30000);eq(ok,true)
    local ok2=FMATraffic.canStart(c,b,{x=60,z=0},{id='b',kind='route'},30000);eq(ok2,false)
end)

test('long job raises the proactive fuel threshold before departure',function()
    local oldFillType=FillType;FillType=FillType or {};FillType.DIESEL=FillType.DIESEL or 999
    local tool={spec_fillUnit={fillUnits={{supportedFillTypes={[FillType.DIESEL]=true}}}},getFillUnits=function(self)return self.spec_fillUnit.fillUnits end,getFillUnitCapacity=function()return 100 end,getFillUnitFillLevel=function()return 30 end}
    local root={getAttachedImplements=function()return {{object=tool}} end};tool.getRootVehicle=function()return root end
    local r={object=root};local req=FMARefillManager.requirement(r,{operation='plow',etaMinutes=120},{refillBeforeWork=0.25,refillTarget=0.85,fuelBeforeWork=0.12,fuelTarget=0.90})
    assert(req and req.isFuel==true);assert(req.forecastMinutes==120)
    FillType=oldFillType
end)

test('critical damaged machine enters service queue and taught service point is usable',function()
    local c=fixture();c.settings.criticalServiceDamage=0.85;c.settings.preventiveServiceDamage=0.6
    local v=record('v');v.damage=0.9;v.object.getRepairPrice=function()return 100 end;v.object.repairVehicle=function()end;c.vehicles={v}
    c.digitalMap={zones={{id='s',kind='SERVIS',x=20,z=0}}}
    FMAFarmBrain.serviceAudit(c);eq(c.serviceQueue[1].state,'CRITICAL');eq(FMAServiceManager.findPoint(c,v).id,'s')
end)

test('future crew uses assembler when the next implement is detached',function()
    local c=fixture();c.settings.autoAssemble=true;c.preparedNextCrew={};c.futureTasks={}
    local parent={id='p',fieldId='5',operation='mow',priority=70};c.tasks.p=parent
    local power=record('tractor');local tool={key='rake',name='Rake'};local plan={power=power,tool=tool}
    local oldFind=FMAAssembler.findPlan;local oldStart=FMAAssembler.startDrive
    FMAAssembler.findPlan=function()return plan end;local called=0;FMAAssembler.startDrive=function(_,future,p)called=called+1;eq(p,plan);eq(future.futurePrep,true);return true end
    local synthetic={id='future:p:windrow',kind='field',fieldId='5',operation='windrow',label='Future'}
    local ok=FMAFarmBrain.startFutureAssembly(c,parent,synthetic,plan)
    FMAAssembler.findPlan=oldFind;FMAAssembler.startDrive=oldStart
    eq(ok,true);eq(called,1);eq(c.preparedNextCrew.p.state,'ASSEMBLING')
end)

test('owner can approve a machinery purchase request from manager page',function()
    local c=fixture();local need={label='Lis',detail='Need baler',approved=false};c.page=6;c.purchaseNeeds={bale=need};c.issues={};c.supported=true;c.scan=function()end
    for i,row in ipairs(FMAHud.rows(c)) do if row.object and row.object.purchase==need then c.selection=i;break end end
    FMAHud.select(c);eq(need.approved,true);eq(need.status,'APPROVED')
end)

test('digital map exposes taught service gate and route endpoints',function()
    local c=fixture();c.fields={};c.homePositions={};c.toolHomes={};c.mapProfile={};c.learnedPoints={S={x=1,z=2,role='SERVIS'},G={x=3,z=4,role='BRÁNA'}};c.learnedRoutes={R={role='POLE',label='Road',points={{x=0,z=0},{x=100,z=0}}}}
    local map=FMAFarmBrain.buildDigitalMap(c);local kinds={};for _,z in ipairs(map.zones) do kinds[z.kind]=true end
    eq(kinds['SERVIS'],true);eq(kinds['BRÁNA'],true);eq(kinds['TRASA'],true)
end)

test('decision blackbox keeps rejection reasons on task selection',function()
    local bad=record('bad');bad.capabilities.plow=true;bad.busy=true
    local good=record('good');good.capabilities.plow=true;good.x=10
    local t={id='x',operation='plow',kind='field',x=0,z=0}
    local v=FMAPlanner.chooseVehicle(t,{bad,good},{},{})
    eq(v.key,'good');assert(t.selectionAudit and #t.selectionAudit==2);eq(t.selectionAudit[1].reason,'busy')
end)

test('purchase approval survives request rebuild during the same session',function()
    local c=fixture();c.approvedPurchases={harvest=true};c.purchaseNeeds={};c.issues={}
    local oldRecommend=FMACatalog.recommend;FMACatalog.recommend=function()return {} end
    c:equipmentIssue('harvest','Pole 7')
    FMACatalog.recommend=oldRecommend
    eq(c.purchaseNeeds.harvest.approved,true);eq(c.purchaseNeeds.harvest.status,'APPROVED')
end)

test('service and future staging count as managed transit',function()
    eq(FMATraffic.isTransitTask({kind='service'}),true)
    eq(FMATraffic.isTransitTask({kind='futureStage'}),true)
end)


test('unknown dynamic trailer fill mask remains usable instead of causing false purchase',function()
    local trailer=record('aw');trailer.capabilities.transport=true;trailer.transportFillTypes={}
    eq(FMAFleetCoordinator.supportsTransportFillType(trailer,101),true)
end)

test('known incompatible trailer fill mask is still rejected',function()
    local trailer=record('aw');trailer.capabilities.transport=true;trailer.transportFillTypes={[202]=true}
    eq(FMAFleetCoordinator.supportsTransportFillType(trailer,101),false)
end)

test('detached owned trailer with unknown fill mask can form harvest support assembly',function()
    local c=fixture();c.reservations={};c.implementReservations={};c.excluded={}
    local tractor=record('6r');tractor.hasCombine=false;tractor.hasAttacherJoints=true;tractor.busy=false;tractor.lowFuel=false;tractor.damage=0;tractor.wear=0;tractor.vehicleTypeName='tractor'
    tractor.object.spec_attacherJoints={attacherJoints={{jointType=1,jointIndex=0}}}
    tractor.object.getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end
    local trailer=record('aw');trailer.capabilities.transport=true;trailer.transportFillTypes={};trailer.busy=false;trailer.damage=0;trailer.wear=0
    trailer.object.spec_attachable={inputAttacherJoints={{jointType=1}}}
    trailer.object.getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end
    c.vehicles={tractor};c.loose={trailer}
    local parent={id='field:32:harvest',operation='harvest',preferredSupportKeys={},preferredSupportToolKeys={}}
    local old=AttacherJoints;AttacherJoints=nil
    local plan=FMAFleetCoordinator.findTransportAssembly(c,parent,101,1)
    AttacherJoints=old
    assert(plan);eq(plan.power.key,'6r');eq(plan.tool.key,'aw')
end)

test('unknown configurable cargo body remains usable when fill API is inconclusive',function()
    local cargo={ownerFarmId=1,spec_trailer={},spec_dischargeable={},spec_fillUnit={fillUnits={{supportedFillTypes={}}}},
        getFillUnits=function(self)return self.spec_fillUnit.fillUnits end,
        getFillUnitSupportsFillType=function()return false end,
        getAttachedImplements=function()return {} end}
    local root={ownerFarmId=1,getAttachedImplements=function()return {{object=cargo}} end}
    local transport={object=root,key='root',name='6R + wagon',capabilities={transport=true},transportFillTypes={}}
    eq(FMAFleetCoordinator.supportsTransportFillType(transport,101),true)
end)

test('explicit cargo fill table still rejects a different crop',function()
    local cargo={ownerFarmId=1,spec_trailer={},spec_dischargeable={dischargeNodes={{fillUnitIndex=1}}},spec_fillUnit={fillUnits={{supportedFillTypes={[202]=true}}}},
        getFillUnits=function(self)return self.spec_fillUnit.fillUnits end,getAttachedImplements=function()return {} end}
    local root={ownerFarmId=1,getAttachedImplements=function()return {{object=cargo}} end}
    local transport={object=root,key='root',name='tractor train',capabilities={transport=true},transportFillTypes={}}
    eq(FMAFleetCoordinator.supportsTransportFillType(transport,101),false)
end)

test('already assembled transport root is preferred without searching for a loose wagon',function()
    local c=fixture();c.excluded={};c.reservations={}
    local cargo={ownerFarmId=1,spec_trailer={},spec_dischargeable={},spec_fillUnit={fillUnits={{supportedFillTypes={}}}},
        getFillUnits=function(self)return self.spec_fillUnit.fillUnits end,getFillUnitSupportsFillType=function()return false end,getAttachedImplements=function()return {} end}
    local rootObj={ownerFarmId=1,getAttachedImplements=function()return {{object=cargo}} end}
    local root={object=rootObj,key='6r',name='6R 250 + AW',capabilities={transport=true},transportFillTypes={},busy=false,lowFuel=false,capacity=30000}
    c.vehicles={root}
    local free=FMAFleetCoordinator.freeTransporters(c,101)
    eq(#free,1);eq(free[1].key,'6r')
end)

test('preloaded combine header carrier cutter chain is detected as serviceable',function()
    local c=fixture();c.reservations={}
    local carrierObj={ownerFarmId=1,uniqueId='carrier',spec_dynamicMountAttacher={},getAttachedImplements=function()return {} end}
    local combineObj={ownerFarmId=1,uniqueId='lexion',getAttachedImplements=function()return {{object=carrierObj}} end}
    local cutterObj={ownerFarmId=1,uniqueId='convio',spec_cutter={}}
    local combine={object=combineObj,key='lexion',name='LEXION 6900',isGrainCombine=true,busy=false}
    local cutter={object=cutterObj,key='convio',name='CONVIO FLEX 1080',mountedCarrier=carrierObj,harvestFruits={[7]=true},capabilities={harvest=true}}
    c.vehicles={combine};c.loose={cutter}
    local chain=FMAHeaderTransport.preloadedChain(c,{id='field:32:harvest',operation='harvest',fruitIndex=7})
    assert(chain);eq(chain.record.key,'lexion');eq(chain.carrier.key,'carrier');eq(chain.cutter.key,'convio')
end)

test('readiness audit treats a preloaded header chain as serviceable even when bare combine capability is false',function()
    local c=fixture();c.settings.headerTransport=true;c.reservations={};c.implementReservations={};c.excluded={}
    local carrierObj={ownerFarmId=1,uniqueId='carrier2',spec_dynamicMountAttacher={},getAttachedImplements=function()return {} end}
    local combineObj={ownerFarmId=1,uniqueId='lexion2',getAttachedImplements=function()return {{object=carrierObj}} end}
    local cutterObj={ownerFarmId=1,uniqueId='convio2',spec_cutter={}}
    c.vehicles={{object=combineObj,key='lexion2',name='LEXION 6900',isGrainCombine=true,busy=false,capabilities={harvest=false}}}
    c.loose={{object=cutterObj,key='convio2',name='CONVIO FLEX 1080',mountedCarrier=carrierObj,harvestFruits={[7]=true},capabilities={harvest=true}}}
    c.fieldsById={['32']={valid=true,ready=true}}
    c.tasks={['field:32:harvest']={id='field:32:harvest',label='32 · Sklizeň',kind='field',fieldId='32',operation='harvest',fruitIndex=7,state='pending',priority=90}}
    local audit=c:buildReadinessAudit();local row=audit['field:32:harvest']
    eq(row.state,'SERVICEABLE');eq(row.main,'PRELOADED');eq(row.vehicle,'LEXION 6900');eq(row.tool,'CONVIO FLEX 1080')
end)

test('assembly begins from an outer staging point at least eight metres from the tool',function()
    local power={object={ownerFarmId=1,posX=0,posZ=0},key='tractor'}
    local tool={object={ownerFarmId=1,posX=1,posZ=0},key='tool'}
    local list=FMAAssembler.alignmentCandidates({power=power,tool=tool},{assemblyStagingDistance=4})
    assert(#list>=1);eq(list[1].mode,'staging')
    local d=math.sqrt((list[1].x-1)^2+(list[1].z-0)^2)
    assert(d>=7.99)
end)

test('input source mirrors global player rebuild and keeps a raw Alt fallback',function()
    local fh=assert(io.open('scripts/main.lua','r'));local src=fh:read('*a');fh:close()
    assert(not src:find('PlayerInputComponent.registerGlobalPlayerActionEvents=Utils.overwrittenFunction',1,true))
    assert(src:find('function listener:keyEvent',1,true))
    assert(src:find('SAFE ESC',1,true))
    assert(not src:find('beginActionEventsModification,g_inputBinding,"PLAYER"',1,true))
    assert(not src:find('beginActionEventsModification,g_inputBinding,"VEHICLE"',1,true))
end)

test('assembly recovery hands stalled hitch approach back to assembler without fleet rotation',function()
    local c=fixture();c.settings.recoveryEnabled=true;c.active={}
    local job={isRunning=true};local stopped=false
    local r=record('tractor');local t={id='assemble:field:5:lime',kind='assemble',phase='PŘÍPRAVA'}
    c.active[job]={job=job,task=t,vehicle=r,start=0,lastProgress=0,recoveryStage=0}
    c.now=33000
    local old=FMAAI.stop;FMAAI.stop=function(j)eq(j,job);stopped=true end
    FMARecovery.update(c);FMAAI.stop=old
    eq(stopped,true);eq(c.active[job].stopReason,'ASSEMBLY_RETRY')
end)


test('generic failover never blacklists a tractor because of an assembly manoeuvre',function()
    local c=fixture();c.settings.recoveryEnabled=true
    local r=record('tractor');local t={id='assemble:field:5:lime',kind='assemble',failedVehicleKeys={}}
    local handled=FMARecovery.noteFailure(c,t,r,'yard approach failed',{count=1})
    eq(handled,false);eq(t.failedVehicleKeys.tractor,nil)
end)

test('assembly has several native staging choices around one implement',function()
    local p={power={x=0,z=0},tool={x=10,z=10}}
    local pts=FMAAssembler.stagingCandidates(p,{assemblyStagingDistance=10})
    assert(#pts>=5)
    for _,pt in ipairs(pts) do eq(pt.mode,'staging') end
end)


test('dynamic mounted cutter is part of the physical attachment tree',function()
    local cutter={ownerFarmId=1,uniqueId='convio',spec_cutter={}}
    local carrier={ownerFarmId=1,uniqueId='n60',spec_dynamicMountAttacher={dynamicMountedObjects={[cutter]={}}},getAttachedImplements=function()return {} end}
    local combine={ownerFarmId=1,uniqueId='lexion',getAttachedImplements=function()return {{object=carrier}} end}
    local children=FMAWorld.children(combine);local found={}
    for _,o in ipairs(children) do found[o]=true end
    eq(found[combine],true);eq(found[carrier],true);eq(found[cutter],true)
end)

test('dynamic header trailer chain exposes harvest capability to the main selector',function()
    local oldMission,oldFill,oldFruit,oldAI=g_currentMission,g_fillTypeManager,g_fruitTypeManager,AIUtil
    local cutter={ownerFarmId=1,uniqueId='convio',spec_attachable={},spec_cutter={fruitTypeIndices={7}},getRootVehicle=function(self)return self end}
    local carrier={ownerFarmId=1,uniqueId='n60',spec_attachable={},spec_dynamicMountAttacher={dynamicMountedObjects={[cutter]={}}},getAttachedImplements=function()return {} end,getRootVehicle=function(self)return self end}
    local combine={ownerFarmId=1,uniqueId='lexion',spec_motorized={motor={peakMotorPower=300}},spec_enterable={},spec_attacherJoints={},spec_combine={fillUnitIndex=1},
        getAttachedImplements=function()return {{object=carrier}} end,getRootVehicle=function(self)return self end,getUniqueId=function()return self.uniqueId end,
        getFillUnits=function()return {[1]={supportedFillTypes={}}} end,getFillUnitCapacity=function()return 10000 end,getFillUnitFillLevel=function()return 0 end}
    local vehicles={combine,carrier,cutter}
    g_currentMission={vehicleSystem={getVehicles=function()return vehicles end}}
    g_fillTypeManager={getFillTypeByIndex=function()return nil end};g_fruitTypeManager={}
    AIUtil={hasCutterOnTrailerAttached=function(v)return v==combine end}
    local roots,loose=FMAWorld.vehicles(1)
    g_currentMission, g_fillTypeManager, g_fruitTypeManager, AIUtil=oldMission,oldFill,oldFruit,oldAI
    eq(#roots,1);eq(roots[1].key,'lexion');eq(roots[1].capabilities.harvest,true);eq(roots[1].harvestFruits[7],true);eq(roots[1].headerOnCarrier,true);eq(#loose,0)
end)

test('nested 6R trailer train is a ready harvest transporter',function()
    local oldOwner=FMAUtil.owner
    local body={ownerFarmId=1,uniqueId='aw',spec_attachable={},spec_trailer={},spec_dischargeable={dischargeNodes={{fillUnitIndex=1}}},spec_fillUnit={fillUnits={[1]={supportedFillTypes={[101]=true}}}},
        getFillUnits=function(self)return self.spec_fillUnit.fillUnits end,getFillUnitCapacity=function()return 22000 end,getFillUnitFillLevel=function()return 0 end,getFillUnitFillType=function()return 0 end,getAttachedImplements=function()return {} end}
    local chassis={ownerFarmId=1,uniqueId='hts',spec_attachable={},spec_trailer={},spec_dischargeable={dischargeNodes={}},getAttachedImplements=function()return {{object=body}} end}
    local frontWeight={ownerFarmId=1,uniqueId='weight',spec_attachable={},spec_weight={},getAttachedImplements=function()return {} end}
    local tractor={ownerFarmId=1,uniqueId='6r',spec_motorized={motor={peakMotorPower=220}},spec_enterable={},spec_attacherJoints={},
        getAttachedImplements=function()return {{object=chassis},{object=frontWeight}} end,getUniqueId=function()return '6r' end}
    local children=FMAWorld.children(tractor);local rec={object=tractor,key='6r',name='6R 250',capabilities={transport=true},transportFillTypes={[101]=true},capacity=22000,busy=false,lowFuel=false}
    local c=fixture();c.vehicles={rec};c.excluded={};c.reservations={}
    local free=FMAFleetCoordinator.freeTransporters(c,101)
    eq(#children,4);eq(#free,1);eq(free[1].key,'6r')
    FMAUtil.owner=oldOwner
end)

test('front ballast does not block a free compatible rear work joint',function()
    local oldAttacher=AttacherJoints;AttacherJoints={getAttacherJointCompatibility=function()return true end}
    local weight={ownerFarmId=1,name='Front weight',spec_weight={}}
    local tractor={ownerFarmId=1,spec_attacherJoints={attacherJoints={{jointType=1,jointIndex=0},{jointType=2,jointIndex=0}}},
        getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end,getAttachedImplements=function()return {{object=weight}} end,getIsAttachingAllowed=function()return true end}
    local toolObj={ownerFarmId=1,spec_attachable={inputAttacherJoints={{jointType=2}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end,isAttachAllowed=function()return true end}
    local tool={object=toolObj,key='cult',capabilities={cultivate=true}}
    eq(FMAAssembler.hasBlockingAttachment({object=tractor},tool,{operation='cultivate'}),false)
    AttacherJoints=oldAttacher
end)

test('Courseplay harvest enables automatic cutter attachment only for header-on-carrier chain',function()
    local oldLoaded,oldAI=g_modIsLoaded,AIUtil
    g_modIsLoaded={FS25_Courseplay=true};AIUtil={hasCutterOnTrailerAttached=function()return true end}
    local value=false
    local setting={getValue=function()return value end,setValue=function(_,v)value=v end}
    local vehicle={getCpSettings=function()return {automaticCutterAttach=setting} end}
    local ok=FMAFieldQuality.prepareCourseplayVehicle(vehicle,{operation='harvest',id='field:32:harvest'})
    g_modIsLoaded,AIUtil=oldLoaded,oldAI
    eq(ok,true);eq(value,true)
end)

test('Courseplay-owned header carrier bypass is detectable',function()
    local oldLoaded,oldAI=g_modIsLoaded,AIUtil
    g_modIsLoaded={FS25_Courseplay=true};AIUtil={hasCutterOnTrailerAttached=function()return true end}
    eq(FMAFieldQuality.courseplayOwnsHeaderTransport({}, {operation='harvest'}),true)
    g_modIsLoaded,AIUtil=oldLoaded,oldAI
end)

test('failed traffic validation does not consume launch spacing',function()
    local c={settings={trafficSafety=true,trafficCellSize=18,trafficStartSeparation=1,trafficLaunchIntervalSeconds=2.5,trafficMaxTransit=20},traffic=FMATraffic.new(),active={},now=10000}
    local a={key='a',object={posX=0,posZ=0}};local b={key='b',object={posX=100,posZ=0}}
    eq(select(1,FMATraffic.canStart(c,a,{x=200,z=0},{kind='return'},30000)),true)
    FMATraffic.release(c.traffic,'a')
    c.now=10500;eq(select(1,FMATraffic.canStart(c,b,{x=300,z=0},{kind='return'},30000)),true)
    eq(c.traffic.lastLaunchAt,-1000000)
end)

test('successful field completion requests an immediate live field rescan',function()
    local c=fixture();c.settings.autoReturn=false;c.settings.scanSeconds=12;c.elapsed=0
    local j={};local t={id='field:32:harvest',kind='field',operation='harvest',fieldId='32',state='running'};local r=record('lexion')
    c.active[j]={job=j,task=t,vehicle=r};c.reservations[r.key]=t.id
    local oldOutcome,oldRemember,oldMark=FMAJobs.outcome,FMAFieldQuality.rememberWindrow,FMAFieldQuality.markCompleted
    FMAJobs.outcome=function()return 'success' end;FMAFieldQuality.rememberWindrow=function()end;FMAFieldQuality.markCompleted=function()end
    c:handleJobStopped(j,nil)
    FMAJobs.outcome,FMAFieldQuality.rememberWindrow,FMAFieldQuality.markCompleted=oldOutcome,oldRemember,oldMark
    eq(c.elapsed,12000);eq(c.diagnosticDirty,true)
end)


test('failed harvest support staging rotates to another field approach instead of permanent block',function()
    local c=fixture();local parent={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',label='Sklizeň',state='pending'}
    c.tasks[parent.id]=parent;c.preparedSupport={[parent.id]={[1]={id='haulage:'..parent.id..':1',slot=1,state='STAGING',stageCandidateCursor=1}}}
    local r=record('6r');local active={task={kind='supportStage',parentTaskId=parent.id,slotIndex=1},vehicle=r,outcome='error',stopReason='cíl není dosažitelný'}
    eq(FMAFleetCoordinator.onSupportStageStopped(c,active),true)
    local role=c.preparedSupport[parent.id][1]
    eq(role.state,'NEEDED');eq(role.stageFailureCount,1);eq(role.stageCandidateCursor,2);eq(parent.state,'pending')
end)

test('stalled harvest support recovery releases STAGING state for a new approach',function()
    local c=fixture();local parent={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',label='Sklizeň',state='pending'}
    c.tasks[parent.id]=parent;c.preparedSupport={[parent.id]={[1]={id='haulage:'..parent.id..':1',slot=1,state='STAGING',stageCandidateCursor=1}}}
    local r=record('6r');local active={stopReason='RECOVERY_REROUTE',task={id='supportStage:'..parent.id..':1',kind='supportStage',parentTaskId=parent.id,slotIndex=1},vehicle=r}
    -- Generic recovery must not own staging or rewrite the main fieldwork task.
    eq(FMARecovery.onStopped(c,active),false)
    local role=c.preparedSupport[parent.id][1]
    eq(role.state,'STAGING')
    eq(FMAFleetCoordinator.onSupportStageStopped(c,active),true)
    eq(role.state,'NEEDED');eq(role.stageCandidateCursor,2)
    eq(parent.state,'pending')
end)


test('Courseplay transfer job keeps the conventional skipped GIANTS task at index one',function()
    local fh=assert(io.open('scripts/FMATransfer.lua','r'));local src=fh:read('*a');fh:close()
    assert(src:find('CpAIJob.setupTasks(self,isServer)',1,true))
    assert(src:find('self.transferTask=FMAAITaskTransfer',1,true))
    assert(src:find('self.isDirectStart=true',1,true))
    assert(src:find('PathfinderController',1,true));assert(src:find('findPathToGoal',1,true))
end)

test('unified transfer helper prefers native FS25 GoTo for normal map travel',function()
    local oldTransfer,oldCourseplay,oldGoto,oldCreate=FMATransfer,FMACourseplay,AIJobGoTo,FMAAI.createRegisteredJob
    local cpCalled=false;local native={isRunning=false,getIsAvailableForVehicle=function()return true end,applyCurrentState=function()end,
        positionAngleParameter={setPosition=function()end,setAngle=function()end},setValues=function()end,validate=function()return true end,getIsStartable=function()return true end}
    FMATransfer={createJob=function()cpCalled=true;return {isRunning=false} end}
    FMACourseplay={available=function()return true end};AIJobGoTo={}
    FMAAI.createRegisteredJob=function()return native end
    local c=fixture();local r=record('tractor');r.object.startCpWithStrategy=function()end;r.object.getCpSettings=function()return {} end
    local job,why,method=FMAAI.createTransferJob(c,r,{x=10,z=20})
    eq(job,native);eq(why,nil);eq(method,'GIANTS_GOTO');eq(cpCalled,false);eq(job.fmaAuxiliaryTransfer,true)
    FMAAI.createRegisteredJob=oldCreate;FMATransfer,FMACourseplay,AIJobGoTo=oldTransfer,oldCourseplay,oldGoto
end)

test('precision direct hitch approach may prefer Courseplay local steering',function()
    local oldTransfer,oldCourseplay,oldGoto=FMATransfer,FMACourseplay,AIJobGoTo
    local wanted={isRunning=false};local called=false
    FMATransfer={createJob=function(c,r,t)called=true;return wanted end};FMACourseplay={available=function()return true end};AIJobGoTo={}
    local c=fixture();local r=record('tractor');r.object.startCpWithStrategy=function()end;r.object.getCpSettings=function()return {} end
    local job,why,method=FMAAI.createTransferJob(c,r,{x=10,z=20,directApproach=true})
    eq(called,true);eq(job,wanted);eq(why,nil);eq(method,'COURSEPLAY_DIRECT_APPROACH');eq(job.fmaAuxiliaryTransfer,true)
    FMATransfer,FMACourseplay,AIJobGoTo=oldTransfer,oldCourseplay,oldGoto
end)

test('Courseplay bridge initialization failure falls back to registered native GoTo instead of freezing the farm',function()
    local oldTransfer,oldCourseplay,oldGoto=FMATransfer,FMACourseplay,AIJobGoTo
    local nativeCreated=false
    FMATransfer={createJob=function()return nil,'CP environment missing' end}
    FMACourseplay={available=function()return true end}
    AIJobGoTo={}
    local oldCreate=FMAAI.createRegisteredJob
    local native={positionAngleParameter={setPosition=function()end,setAngle=function()end},getIsAvailableForVehicle=function()return true end,applyCurrentState=function()end,setValues=function()end,validate=function()return true end,getIsStartable=function()return true end}
    FMAAI.createRegisteredJob=function()nativeCreated=true;return native end
    local c=fixture();local r=record('tractor');r.object.startCpWithStrategy=function()end;r.object.getCpSettings=function()return {} end
    local job,why,method=FMAAI.createTransferJob(c,r,{x=10,z=20})
    eq(job,native);eq(why,nil);eq(method,'GIANTS_GOTO');eq(nativeCreated,true)
    FMAAI.createRegisteredJob=oldCreate;FMATransfer,FMACourseplay,AIJobGoTo=oldTransfer,oldCourseplay,oldGoto
end)

test('Courseplay transfer resolves private classes through Courseplay mod environment',function()
    local fh=assert(io.open('scripts/FMATransfer.lua','r'));local src=fh:read('*a');fh:close()
    assert(src:find('g_modManager.CP_MOD_NAME',1,true))
    assert(src:find('candidate[modName]',1,true))
    assert(src:find('tableIndexEnvironment',1,true))
    assert(src:find('customEnvironment',1,true))
    assert(src:find('env[name]',1,true))
end)

test('Courseplay transfer registration retries after load-order delay',function()
    local fh=assert(io.open('scripts/FMAController.lua','r'));local src=fh:read('*a');fh:close()
    assert(src:find('transferRegistrationElapsed',1,true))
    assert(src:find('FMATransfer.ensureRegistered(self)',1,true))
    assert(src:find('transfer.registered',1,true))
end)

test('Courseplay transfer handles trailer-only obstacle at start without disabling collisions',function()
    local fh=assert(io.open('scripts/FMATransfer.lua','r'));local src=fh:read('*a');fh:close()
    assert(src:find('onPathfindingObstacleAtStart',1,true))
    assert(src:find('ignoreTrailerAtStartRange',1,true))
    assert(not src:find('collisionMask(0)',1,true))
end)

test('operational travel modules no longer create raw AIJobGoTo jobs',function()
    local modules={'FMABaleStorage.lua','FMAFleetCoordinator.lua','FMABunkerCoordinator.lua','FMAServiceManager.lua','FMAAssembler.lua','FMAHeaderTransport.lua','FMARefillManager.lua','FMAAutoRoute.lua','FMALivestockCoordinator.lua','FMAFarmBrain.lua','FMAReturnManager.lua'}
    for _,name in ipairs(modules) do
        local fh=assert(io.open('scripts/'..name,'r'));local src=fh:read('*a');fh:close()
        assert(not src:find('createRegisteredJob("GOTO"',1,true),name..' still starts native GoTo directly')
        assert(not src:find("createRegisteredJob('GOTO'",1,true),name..' still starts native GoTo directly')
    end
end)

test('sold combine is missing even when a cutter remains and replacement combine restores serviceability',function()
    local oldAttacher=AttacherJoints;AttacherJoints={getAttacherJointCompatibility=function()return true end}
    local cutterObj={ownerFarmId=1,spec_cutter={fruitTypeIndices={7}},spec_attachable={inputAttacherJoints={{jointType=1}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end,isAttachAllowed=function()return true end}
    local cutter={object=cutterObj,key='header',name='NorthStar',capabilities={harvest=true},harvestFruits={[7]=true},requiredPowerKW=100}
    local tractor={object={ownerFarmId=1,spec_attacherJoints={attacherJoints={{jointType=1}}},getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end},key='tractor',isGrainCombine=false,hasCombine=false,capabilities={}}
    local c=fixture();c.vehicles={tractor};c.loose={cutter};c.excluded={};c.reservations={};c.implementReservations={}
    local task={operation='harvest',kind='field',fruitIndex=7}
    eq(FMAProcurement.hasForTask(c,task),false)
    local combineObj={ownerFarmId=1,spec_combine={},spec_attacherJoints={attacherJoints={{jointType=1}}},getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end,getIsAttachingAllowed=function()return true end}
    c.vehicles[#c.vehicles+1]={object=combineObj,key='combine',name='New combine',isGrainCombine=true,hasCombine=true,capabilities={},powerKW=300,busy=false,lowFuel=false}
    eq(FMAProcurement.hasForTask(c,task),true)
    AttacherJoints=oldAttacher
end)

test('missing harvest main machine recommends harvester category rather than another cutter',function()
    local oldStore=g_storeManager
    g_storeManager={getItems=function()return {
        {name='Cheap Header',price=10000,showInStore=true,categoryNames={'CUTTERS'}},
        {name='Real Combine',price=250000,showInStore=true,categoryNames={'HARVESTERS'}}
    } end}
    local c=fixture();c.vehicles={{isGrainCombine=false}};c.purchaseNeeds={};c.approvedPurchases={};c.issues={}
    c:equipmentIssue('harvest','32 · Sklizeň')
    local need=c.purchaseNeeds.harvest;assert(need);eq(#need.candidates,1);eq(need.candidates[1].name,'Real Combine')
    assert(need.detail:find('Chybí vlastní sklízecí mlátička',1,true))
    g_storeManager=oldStore
end)

test('missing harvest main blocks support staging until replacement exists',function()
    local fh=assert(io.open('scripts/FMAController.lua','r'));local src=fh:read('*a');fh:close()
    local block=assert(src:find('task.phase="DOKOUPIT TECHNIKU"',1,true))
    local stage=assert(src:find('preparePendingHarvestCrew',block,true))
    assert(block<stage)
    assert(src:find('task.blockedByEquipment=true',1,true))
    assert(src:find('NOVÁ TECHNIKA ROZPOZNÁNA',1,true))
end)

test('Courseplay fieldwork uses its public external mod start path',function()
    local fh=assert(io.open('scripts/FMAAI.lua','r'));local ai=fh:read('*a');fh:close()
    assert(ai:find('FMACourseplay.startFieldwork(controller,record,task)',1,true))
    fh=assert(io.open('scripts/FMACourseplay.lua','r'));local cp=fh:read('*a');fh:close()
    assert(cp:find("startCpAtFirstWp",1,true))
    assert(cp:find("cp.publicStart",1,true))
    assert(cp:find("cp.fieldworkConfirmed",1,true))
end)

test('Courseplay transfer recovers task vehicle and rotates invalid goal nodes',function()
    local fh=assert(io.open('scripts/FMATransfer.lua','r'));local src=fh:read('*a');fh:close()
    assert(src:find('jobVehicle(self.job)',1,true))
    assert(src:find('goalNodeInvalid==true',1,true))
    assert(src:find('transferGoalCandidates',1,true))
    assert(src:find('nextGoalCandidate',1,true))
end)

test('workshop scan targets the FS25 selling trigger instead of the building root',function()
    local fh=assert(io.open('scripts/FMAFarmBrain.lua','r'));local src=fh:read('*a');fh:close()
    assert(src:find('spec_workshop',1,true))
    assert(src:find('sellingPoint.sellTriggerNode',1,true))
    assert(src:find('workshopPose(p)',1,true))
end)

test('grain combine may start while harvest haulage is temporarily blocked',function()
    local c=fixture();c.preparedSupport={};c.settings.harvestTeams=true;c.settings.maxUnloaders=3;c.now=1000;c.issues={}
    c.issue=function(self,id,title,detail,priority) self.issues[id]={title=title,detail=detail,priority=priority} end
    local parent={id='field:32:harvest',kind='field',operation='harvest',fieldId=32,label='32 · Sklizeň'}
    c.preparedSupport[parent.id]={[1]={state='BLOCKED',reason='Chybí odvoz'}}
    local combine={isForageHarvester=false}
    local preparing,why=FMAFleetCoordinator.preflightHarvest(c,parent,combine)
    eq(preparing,false);eq(why,nil)
end)

test('forage harvester still waits for a blocked escort',function()
    local c=fixture();c.preparedSupport={};c.settings.harvestTeams=true;c.settings.maxUnloaders=3;c.now=1000
    local parent={id='field:9:forage',kind='field',operation='foragePickup',fieldId=9,label='9 · Řezanka'}
    c.preparedSupport[parent.id]={[1]={state='BLOCKED',reason='Chybí odvoz'}}
    local forage={isForageHarvester=true}
    local preparing,why=FMAFleetCoordinator.preflightHarvest(c,parent,forage)
    eq(preparing,false);eq(why,'Chybí odvoz')
end)



test('automatic lime assembly rejects a telehandler and keeps a real tractor',function()
    local oldAttacher=AttacherJoints
    AttacherJoints={getAttacherJointCompatibility=function()return true end}
    local function power(key,class,x)
        local o={ownerFarmId=1,posX=x,posZ=0,spec_attacherJoints={attacherJoints={{jointType=1}}},
            getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end,
            getIsAttachingAllowed=function()return true end}
        return {object=o,key=key,name=key,x=x,z=0,machineClass=class,powerKW=180,busy=false,lowFuel=false,capabilities={}}
    end
    local toolObj={ownerFarmId=1,posX=1,posZ=0,spec_sprayer={},spec_attachable={inputAttacherJoints={{jointType=1}}},
        getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end,isAttachAllowed=function()return true end}
    local tool={object=toolObj,key='K105',name='K105',x=1,z=0,capabilities={lime=true},requiredPowerKW=10,damage=0,wear=0}
    local c=fixture();c.excluded={};c.reservations={};c.implementReservations={};c.loose={tool}
    c.vehicles={power('Multifarmer 44.9','telehandler',0),power('CRYSTAL HD 170','tractor',20)}
    local plan=assert(FMAAssembler.findPlan(c,{id='field:5:lime',kind='field',operation='lime',x=1,z=0}))
    eq(plan.power.key,'CRYSTAL HD 170')
    AttacherJoints=oldAttacher
end)

test('dynamic mounted X9 header is found on its attached carrier even when loose list is empty',function()
    local cutter={ownerFarmId=1,uniqueId='hd50f',spec_cutter={fruitTypeIndices={7}},getAttachedImplements=function()return {} end}
    local carrier={ownerFarmId=1,uniqueId='hdht52',spec_dynamicMountAttacher={dynamicMountedObjects={[cutter]={}}},getAttachedImplements=function()return {} end}
    local combine={ownerFarmId=1,uniqueId='x9',spec_combine={},getAttachedImplements=function()return {{object=carrier}} end}
    local c=fixture();c.reservations={};c.implementReservations={};c.loose={}
    c.vehicles={{object=combine,key='x9',name='X9 1100',isGrainCombine=true,busy=false}}
    local chain=FMAHeaderTransport.preloadedChain(c,{id='field:32:harvest',operation='harvest',fruitIndex=7})
    assert(chain);eq(chain.record.key,'x9');eq(chain.carrier.key,'hdht52');eq(chain.cutter.key,'hd50f')
end)

test('readiness sees dynamic X9 header chain even while Courseplay is active',function()
    local oldAvailable=FMACourseplay.available;FMACourseplay.available=function()return true end
    local cutter={ownerFarmId=1,uniqueId='hd50f2',name='HD50F',spec_cutter={fruitTypeIndices={7}},getAttachedImplements=function()return {} end}
    local carrier={ownerFarmId=1,uniqueId='hdht522',spec_dynamicMountAttacher={dynamicMountedObjects={[cutter]={}}},getAttachedImplements=function()return {} end}
    local combine={ownerFarmId=1,uniqueId='x92',spec_combine={},getAttachedImplements=function()return {{object=carrier}} end}
    local c=fixture();c.settings.headerTransport=true;c.reservations={};c.implementReservations={};c.excluded={};c.loose={}
    c.vehicles={{object=combine,key='x92',name='X9 1100',isGrainCombine=true,busy=false,capabilities={harvest=false}}}
    c.fieldsById={['32']={valid=true,ready=true}}
    c.tasks={['field:32:harvest']={id='field:32:harvest',label='32 · Sklizeň',kind='field',fieldId='32',operation='harvest',fruitIndex=7,state='pending',priority=90}}
    local audit=c:buildReadinessAudit();local row=audit['field:32:harvest']
    FMACourseplay.available=oldAvailable
    eq(row.state,'SERVICEABLE');eq(row.main,'PRELOADED');eq(row.vehicle,'X9 1100');eq(row.tool,'HD50F')
end)

test('coarse assembly staging advances to the precision approach with the same tractor',function()
    local c=fixture();c.implementReservations={};c.tasks={}
    local parent={id='field:5:lime',label='5 · Vápnění',kind='field',operation='lime',state='assembling',priority=70}
    c.tasks[parent.id]=parent
    local plan={power={key='crystal',name='CRYSTAL HD 170'},tool={key='k105',name='K105'}}
    local active={task={parentTaskId=parent.id,alignmentMode='staging',assemblyAttempt=1},assemblyPlan=plan,vehicle=plan.power}
    local oldStart=FMAAssembler.startDrive;local seen
    FMAAssembler.startDrive=function(controller,p,pplan,attempt) seen={p=p,plan=pplan,attempt=attempt};return true end
    FMAAssembler.onStopped(c,active,nil);FMAAssembler.startDrive=oldStart
    assert(seen);eq(seen.p,parent);eq(seen.plan,plan);eq(seen.attempt,2);eq(parent.assemblyAttempt,2)
end)

test('precision hitch approach bypasses global pathfinding and stays slow',function()
    local fh=assert(io.open('scripts/FMATransfer.lua','r'));local src=fh:read('*a');fh:close()
    assert(src:find('self.fmaDirectApproach=false',1,true))
    assert(src:find('if self.directApproach then',1,true))
    assert(src:find('local allowedSpeed=math.min(self.recoveryReverse and 2.2 or 2.8',1,true))
    assert(src:find('self:checkProximitySensors(not self.recoveryReverse)',1,true))
    fh=assert(io.open('scripts/FMAAssembler.lua','r'));src=fh:read('*a');fh:close()
    assert(src:find('directApproach=precise',1,true))
    assert(src:find('probeRadius=precise and nil',1,true))
end)

test('assembly route failure keeps the selected pair instead of rotating through the fleet',function()
    local c=fixture();c.implementReservations={};c.issues={};c.tasks={}
    c.issue=function(self,id,title,detail,priority)self.issues[id]={detail=detail}end
    local parent={id='field:5:lime',label='5 · Vápnění',kind='field',operation='lime',state='assembling',priority=70}
    c.tasks[parent.id]=parent
    local plan={power={key='crystal',name='CRYSTAL HD 170'},tool={key='k105',name='K105'}}
    local active={task={parentTaskId=parent.id,alignmentMode='staging',assemblyAttempt=1},assemblyPlan=plan,vehicle=plan.power,stopReason='No path'}
    FMAAssembler.onStopped(c,active,nil)
    eq(parent.preferredVehicleKey,'crystal');eq(parent.preferredImplementKey,'k105');eq(parent.state,'blocked')
end)


test('without native store metadata autonomous class stays unknown instead of guessing from filename',function()
    local oldStore=g_storeManager;g_storeManager=nil
    local cls=FMAWorld.machineClass({configFileName='data/vehicles/merlo/multifarmer449/multifarmer449.xml'})
    g_storeManager=oldStore
    eq(cls,'unknown')
end)

test('vehicle reset resolves the replacement runtime object by stable uniqueId',function()
    local oldSystem=g_currentMission.vehicleSystem
    local old={uniqueId='vehicleX9',ownerFarmId=1,posX=10,posZ=20,isDeleted=true}
    local replacement={uniqueId='vehicleX9',ownerFarmId=1,posX=900,posZ=-700}
    g_currentMission.vehicleSystem={vehicleByUniqueId={vehicleX9=replacement},vehicles={replacement},getVehicles=function(self)return self.vehicles end}
    local record={key='vehicleX9',object=old,name='X9 1100',x=10,z=20}
    local ok,changed=FMAWorld.refreshRecordObject(record)
    eq(ok,true);eq(changed,true);eq(record.object,replacement);eq(record.x,900);eq(record.z,-700)
    g_currentMission.vehicleSystem=oldSystem
end)

test('lifecycle holds dispatch while GIANTS vehicle reload is running',function()
    local oldSystem=g_currentMission.vehicleSystem
    local c=fixture();c.settings.scanSeconds=12;c.vehicles={};c.loose={}
    g_currentMission.vehicleSystem={isReloadRunning=true,vehicleByUniqueId={},vehicles={}}
    FMALifecycle.syncRuntimeObjects(c)
    eq(c.vehicleReloadHold,true);assert(tostring(c.waitReason):find('resetuje',1,true)~=nil)
    g_currentMission.vehicleSystem=oldSystem
end)

test('stale active job is discarded and task requeued after vehicle object reload',function()
    local oldSystem=g_currentMission.vehicleSystem
    local c=fixture();c.settings.scanSeconds=12;c.traffic=FMATraffic.new();c.loose={};c.routes={};c.playerTakeovers={};c.jobFailures={}
    local old={uniqueId='vehicleX9',ownerFarmId=1,posX=0,posZ=0,isDeleted=true,getIsEntered=function()return false end,getIsAIActive=function()return false end,getAttachedImplements=function()return {} end}
    local replacement={uniqueId='vehicleX9',ownerFarmId=1,posX=850,posZ=-650,getIsEntered=function()return false end,getIsAIActive=function()return false end,getAttachedImplements=function()return {} end}
    local record={key='vehicleX9',name='X9 1100',object=old,x=0,z=0,busy=true}
    local t={id='field:32:harvest',kind='field',operation='harvest',state='running',phase='PRÁCE',vehicleKey='vehicleX9',qualityCourseReady=true,courseVehicleKey='vehicleX9'}
    local job={isRunning=false}
    c.tasks={[t.id]=t};c.vehicles={};c.active={[job]={job=job,task=t,vehicle=record}};c.reservations.vehicleX9=t.id;c.homePositions={vehicleX9={x=25,z=-460}}
    g_currentMission.vehicleSystem={isReloadRunning=false,vehicleByUniqueId={vehicleX9=replacement},vehicles={replacement},getVehicles=function(self)return self.vehicles end}
    FMALifecycle.syncRuntimeObjects(c)
    eq(c.active[job],nil);eq(c.reservations.vehicleX9,nil);eq(t.state,'pending');eq(t.phase,'OBNOVA PO RESETU STROJE');eq(t.qualityCourseReady,nil)
    eq(c.homePositions.vehicleX9.x,25);eq(c.homePositions.vehicleX9.z,-460)
    g_currentMission.vehicleSystem=oldSystem
end)

test('reset of staged harvest support sends the same stable vehicle back through staging',function()
    local oldSystem=g_currentMission.vehicleSystem
    local c=fixture();c.settings.scanSeconds=12;c.traffic=FMATraffic.new();c.loose={};c.routes={};c.playerTakeovers={};c.jobFailures={}
    local old={uniqueId='vehicle6R',ownerFarmId=1,posX=130,posZ=-171,isDeleted=true}
    local replacement={uniqueId='vehicle6R',ownerFarmId=1,posX=900,posZ=-700}
    local r={key='vehicle6R',name='6R 250',object=old,x=130,z=-171,busy=true}
    local parent={id='field:32:harvest',kind='field',operation='harvest',state='pending',phase='ODVOZ'}
    c.tasks={[parent.id]=parent};c.vehicles={};c.preparedSupport={[parent.id]={[1]={id='haulage',state='WAITING_FIELD',record=r,fieldId='32'}}};c.reservations.vehicle6R='haulage'
    g_currentMission.vehicleSystem={isReloadRunning=false,vehicleByUniqueId={vehicle6R=replacement},vehicles={replacement},getVehicles=function(self)return self.vehicles end}
    FMALifecycle.syncRuntimeObjects(c)
    local role=c.preparedSupport[parent.id][1]
    eq(role.state,'NEEDED');eq(role.record.object,replacement);eq(c.reservations.vehicle6R,nil);eq(parent.state,'pending')
    g_currentMission.vehicleSystem=oldSystem
end)


test('FS25 store category is authoritative for autonomous machine class',function()
    local oldStore=g_storeManager
    g_storeManager={getItemByXMLFilename=function(_,xml)
        if xml=='merlo.xml' then return {name='Multifarmer 44.9',categoryName='TELEHANDLERS',categoryNames={'TELEHANDLERS'}} end
        if xml=='tractor.xml' then return {name='6R 250',categoryName='TRACTORS_L',categoryNames={'TRACTORS_L'}} end
    end}
    local merlo={configFileName='merlo.xml',spec_motorized={},spec_enterable={},spec_attacherJoints={}}
    local tractor={configFileName='tractor.xml',spec_motorized={},spec_enterable={},spec_attacherJoints={}}
    eq(FMAWorld.machineClass(merlo),'telehandler')
    eq(FMAWorld.machineClass(tractor),'tractor')
    eq(FMAWorld.isAutoFieldPowerAllowed({machineClass='telehandler',capabilities={}},'lime'),false)
    eq(FMAWorld.isAutoFieldPowerAllowed({machineClass='tractor',capabilities={}},'lime'),true)
    g_storeManager=oldStore
end)

test('unknown autonomous power unit is rejected instead of guessed as tractor',function()
    eq(FMAWorld.isAutoFieldPowerAllowed({machineClass='unknown',capabilities={}},'sow'),false)
end)

test('assembled native capability remains valid for self propelled field machine',function()
    eq(FMAWorld.isAutoFieldPowerAllowed({machineClass='selfPropelledField',capabilities={fertilize=true}},'fertilize'),true)
end)

test('field order can never be verified complete before fieldwork actually started',function()
    local c=fixture();c.fieldsById={['32']={valid=true,ready=false}}
    local t={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',label='32 · Sklizeň'}
    local ok,why=c:verifyFieldOrderComplete(t);eq(ok,false);assert(why:find('nespustila',1,true))
end)

test('field order remains open when FS25 still reports the operation needed',function()
    local c=fixture();c.fieldsById={['32']={valid=true,ready=true}}
    local t={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',label='32 · Sklizeň',fieldworkStartedAt=100}
    local ok,why=c:verifyFieldOrderComplete(t);eq(ok,false);assert(why:find('stále',1,true))
end)

test('field order verifies only after live FS25 state no longer needs operation',function()
    local c=fixture();c.fieldsById={['32']={valid=true,ready=false,bare=true}}
    local t={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',label='32 · Sklizeň',fieldworkStartedAt=100,workEvidence={mode='mechanical',observedMove=75}}
    local ok=c:verifyFieldOrderComplete(t);eq(ok,true)
end)

test('enterprise never displays HOTOVO for unstarted field order',function()
    local fh=assert(io.open('scripts/FMAEnterprise.lua','r'));local src=fh:read('*a');fh:close()
    assert(src:find("task.kind=='field' and (not task.fieldworkStartedAt or task.awaitingWorldVerification==true)",1,true))
    assert(src:find("return 'OVĚŘENÍ'",1,true))
end)

test('FS25 ESC must never be modified by the manager',function()
    local fh=assert(io.open('scripts/main.lua','r'));local src=fh:read('*a');fh:close()
    assert(not src:find('FMAMenuPage.install',1,true))
    assert(not src:find('g_inGameMenu:addPage',1,true))
    assert(not src:find('Gui.registerMenuInput=',1,true))
    assert(not src:find('guardedInput("liveMenuRebind"',1,true))
end)

test('preloaded Courseplay header chain bypasses custom outbound transport',function()
    local fh=assert(io.open('scripts/FMAController.lua','r'));local src=fh:read('*a');fh:close()
    local p=assert(src:find('local cpOwns=FMAFieldQuality',1,true))
    local q=assert(src:find('FMAHeaderTransport.startPreloadedOutbound',p,true))
    assert(p<q);assert(src:find('task.preferredVehicleKey=chain.record.key',p,true))
end)

test('native store identity preserves exact game category and title',function()
    local oldStore=g_storeManager
    g_storeManager={getItemByXMLFilename=function()return {name='K105',categoryName='FERTILIZERSPREADERS',categoryNames={'FERTILIZERSPREADERS'}} end}
    local id=FMAGameNative.storeIdentity({configFileName='k105.xml'})
    eq(id.name,'K105');eq(id.primaryCategory,'FERTILIZERSPREADERS');eq(id.source,'FS25_STORE')
    g_storeManager=oldStore
end)

test('seated player is not a takeover while FS helper is active',function()
    local v={getIsEntered=function()return true end,getIsAIActive=function()return true end}
    local state=FMAGameNative.operatorState(v)
    eq(state.manual,false);eq(state.mode,'FS_AI')
end)

test('seated player is not a takeover while Courseplay is active',function()
    local v={getIsEntered=function()return true end,getIsAIActive=function()return true end,getIsCpActive=function()return true end}
    local state=FMAGameNative.operatorState(v)
    eq(state.manual,false);eq(state.mode,'COURSEPLAY')
end)

test('traffic takeover does not stop an active helper just because player sits in cab',function()
    local c=fixture();local r=record('cab');r.object.getIsEntered=function()return true end;r.object.getIsAIActive=function()return true end
    local j={};local t=task();c.active[j]={vehicle=r,task=t};local old=FMAAI.stop;local stops=0;FMAAI.stop=function()stops=stops+1 end
    FMATraffic.playerTakeover(c);FMAAI.stop=old
    eq(stops,0);eq(next(c.playerTakeovers),nil)
end)

test('manual takeover keeps persistent harvest crew and its manual unloader',function()
    local c=fixture();c.settings.maxUnloaders=3;c.fieldsById={}
    local h=record('harv');h.capabilities.harvest=true;h.harvesterCapacity=12000;h.object.getIsEntered=function()return true end;h.object.getIsAIActive=function()return false end
    local u=record('haul');u.capabilities.transport=true;u.capacity=20000;u.busy=true;u.object.getIsEntered=function()return true end;u.object.getIsAIActive=function()return false end
    local t={id='field:32:harvest',kind='field',fieldId='32',operation='harvest',label='Harvest',state='paused',ownerApproved=true}
    t.crewId='harvest:32:harv';c.tasks[t.id]=t;c.vehicles={h,u};c.vehicleByKey={harv=h,haul=u};c.harvestTelemetry={harv={fill=1000,capacity=12000,rate=10,time=c.now}}
    c.crewAssignments[t.crewId]={id=t.crewId,taskId=t.id,taskRef=t,fieldId='32',harvesterKey='harv',unloaderKeys={'haul'}}
    FMAFleetCoordinator.planHarvestTeams(c)
    local g=c.workgroups[t.crewId];assert(g);eq(g.operatorMode,'PLAYER');eq(#g.unloaders,1);eq(g.unloaders[1].key,'haul')
end)

test('live registry updates scattered vehicle position without treating movement as map rebuild',function()
    local c=fixture();c.settings.scanSeconds=12;c.settings.brainSeconds=5;c.vehicleByKey={}
    local v={ownerFarmId=1,uniqueId='move',posX=0,posZ=0,getRootVehicle=function(self)return self end,getIsEntered=function()return false end,getIsAIActive=function()return false end}
    local r={object=v,key='move',name='Mover',x=0,z=0,capabilities={}};c.vehicleByKey.move=r;c.vehicles={r}
    local oldVS=g_currentMission.vehicleSystem;local oldPS=g_currentMission.placeableSystem
    g_currentMission.vehicleSystem={vehicles={v},getVehicles=function(self)return self.vehicles end,vehicleByUniqueId={move=v}}
    g_currentMission.placeableSystem={placeables={}}
    c.worldRegistry=FMAWorldRegistry.new();eq(FMAWorldRegistry.update(c,true),true)
    c.now=c.now+2000;v.posX=245;v.posZ=-311
    eq(FMAWorldRegistry.update(c,false),false);eq(r.x,245);eq(r.z,-311)
    g_currentMission.vehicleSystem=oldVS;g_currentMission.placeableSystem=oldPS
end)

test('live registry notices a newly constructed placeable and requests remap',function()
    local c=fixture();c.settings.scanSeconds=12;c.settings.brainSeconds=5;c.vehicleByKey={}
    local oldVS=g_currentMission.vehicleSystem;local oldPS=g_currentMission.placeableSystem
    g_currentMission.vehicleSystem={vehicles={},getVehicles=function(self)return self.vehicles end,vehicleByUniqueId={}}
    g_currentMission.placeableSystem={placeables={}}
    c.worldRegistry=FMAWorldRegistry.new();FMAWorldRegistry.update(c,true);c.elapsed=0;c.brainElapsed=0;c.worldChanged=false
    local p={ownerFarmId=1,id=77,posX=50,posZ=80,spec_silo={}}
    g_currentMission.placeableSystem.placeables={p};c.now=c.now+2000
    eq(FMAWorldRegistry.update(c,false),true);eq(c.worldChanged,true);assert(c.elapsed>=c.settings.scanSeconds*1000);assert(c.brainElapsed>=c.settings.brainSeconds*1000)
    g_currentMission.vehicleSystem=oldVS;g_currentMission.placeableSystem=oldPS
end)

-- 0.20.2 regressions reproduced from the clean Carpathian LEXION save.
test('N60 cutter trailer never inherits HARVEST from the CONVIO it transports',function()
    local cutter={ownerFarmId=1,uniqueId='convio1080',spec_cutter={fruitTypeIndices={7}},spec_attachable={}}
    local carrier={ownerFarmId=1,uniqueId='n60',spec_attachable={},spec_dynamicMountAttacher={dynamicMountedObjects={[cutter]={}}}}
    local carrierProfile=FMAWorld.toolProfile(carrier)
    local cutterProfile=FMAWorld.toolProfile(cutter)
    eq(carrierProfile.capabilities.harvest,nil)
    eq(cutterProfile.capabilities.harvest,true)
    eq(cutterProfile.harvestFruits[7],true)
    eq(FMAAssembler.toolSupports({operation='harvest',fruitIndex=7},carrierProfile),false)
    eq(FMAAssembler.toolSupports({operation='harvest',fruitIndex=7},cutterProfile),true)
end)

test('AW transport chassis does not become a fertilizer spreader through its load',function()
    local spreader={ownerFarmId=1,uniqueId='spread',spec_sprayer={},spec_fillUnit={fillUnits={{supportedFillTypes={}}}}}
    local chassis={ownerFarmId=1,uniqueId='aw',spec_attachable={},spec_trailer={},getAttachedImplements=function()return {{object=spreader}}end}
    local chassisProfile=FMAWorld.toolProfile(chassis)
    eq(chassisProfile.capabilities.fertilize,nil)
    eq(FMAAssembler.toolSupports({operation='fertilize'},chassisProfile),false)
    -- A forged/inherited capability may not bypass the selected object itself.
    chassisProfile.capabilities.fertilize=true
    eq(FMAAssembler.toolSupports({operation='fertilize'},chassisProfile),false)
end)

test('mounted CONVIO on detached N60 remains separately discoverable for retrieval',function()
    local oldMission=g_currentMission
    local cutter={ownerFarmId=1,uniqueId='convio',spec_attachable={},spec_cutter={fruitTypeIndices={7}},
        getRootVehicle=function(self)return self end,getAttachedImplements=function()return {}end}
    local carrier={ownerFarmId=1,uniqueId='n60',spec_attachable={},spec_dynamicMountAttacher={dynamicMountedObjects={[cutter]={}}},
        getRootVehicle=function(self)return self end,getAttachedImplements=function()return {}end}
    cutter.getDynamicMountObject=function()return carrier end
    local tractor={ownerFarmId=1,uniqueId='tractor',spec_motorized={motor={peakMotorPower=200}},spec_enterable={},
        getRootVehicle=function(self)return self end,getAttachedImplements=function()return {}end}
    g_currentMission={vehicleSystem={getVehicles=function()return {tractor,carrier,cutter}end}}
    local vehicles,loose=FMAWorld.vehicles(1)
    g_currentMission=oldMission
    eq(#vehicles,1)
    local seen={}
    for _,rec in ipairs(loose) do seen[rec.key]=rec end
    assert(seen.n60 and seen.convio)
    eq(seen.n60.capabilities.harvest,nil)
    eq(seen.convio.capabilities.harvest,true)
    eq(seen.convio.mountedCarrier,carrier)
    eq(seen.convio.transported,true)
end)

test('GIANTS hitch planning tolerates an owned mounted cutter without attaching it remotely',function()
    local oldAttacher=AttacherJoints
    AttacherJoints={getAttacherJointCompatibility=function()return true end}
    local carrier={ownerFarmId=1,uniqueId='carrier'}
    local cutter={ownerFarmId=1,spec_cutter={},spec_attachable={inputAttacherJoints={{jointType=1,node=2}}},
        getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end,
        getDynamicMountObject=function()return carrier end,isAttachAllowed=function()return false end}
    local combine={ownerFarmId=1,spec_attacherJoints={attacherJoints={{jointType=1,node=1,jointIndex=0}}},
        getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end}
    eq(FMAAssembler.findJointPair(combine,cutter,1),1)
    AttacherJoints=oldAttacher
end)

test('a remote combine may never unmount a CONVIO cutter from its carrier',function()
    local oldPosition,oldAttacher=getWorldTranslation,AttacherJoints
    local carrier={ownerFarmId=1,uniqueId='n60'}
    local releaseCalls=0
    local cutter={ownerFarmId=1,spec_cutter={},spec_attachable={inputAttacherJoints={{jointType=1,node=2}}},
        getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end,
        getDynamicMountObject=function()return carrier end,isAttachAllowed=function()return false end,
        unmountDynamic=function()releaseCalls=releaseCalls+1 end}
    local combine={ownerFarmId=1,spec_attacherJoints={attacherJoints={{jointType=1,node=1,jointIndex=0}}},
        getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end}
    getWorldTranslation=function(node) if node==1 then return 0,0,0 end return 100,0,100 end
    AttacherJoints={getAttacherJointCompatibility=function()return true end}
    local success,reason=FMAAssembler.attach({farmId=1},{power={object=combine},tool={object=cutter}})
    getWorldTranslation,AttacherJoints=oldPosition,oldAttacher
    eq(success,false);eq(releaseCalls,0)
    assert(tostring(reason):find('přistavit',1,true)~=nil)
end)

test('weed operation accepts native mechanical weeder without a sprayer specialization',function()
    local tool={object={spec_weeder={}},capabilities={weed=true}}
    eq(FMAAssembler.toolSupports({operation='weed'},tool),true)
    local wrong={object={spec_trailer={}},capabilities={weed=true}}
    eq(FMAAssembler.toolSupports({operation='weed'},wrong),false)
end)

test('unmounting a cutter at real hitch distance still needs native attach confirmation',function()
    local oldPosition,oldAttacher=getWorldTranslation,AttacherJoints
    local carrier={ownerFarmId=1,uniqueId='n60'}
    local mounted=carrier
    local cutter={ownerFarmId=1,spec_cutter={},spec_attachable={inputAttacherJoints={{jointType=1,node=2}}},
        getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end,
        getDynamicMountObject=function()return mounted end,isAttachAllowed=function()return mounted==nil end,
        unmountDynamic=function() mounted=nil end}
    local attached=false
    local combine={ownerFarmId=1,spec_attacherJoints={attacherJoints={{jointType=1,node=1,jointIndex=0}}},
        getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end,
        attachImplementFromInfo=function()attached=true;return true end}
    getWorldTranslation=function(node) if node==1 then return 0,0,0 end return 1,0,1 end
    AttacherJoints={getAttacherJointCompatibility=function()return true end,
        updateVehiclesInAttachRange=function()return combine,1,cutter,1 end}
    local success=FMAAssembler.attach({farmId=1},{power={object=combine},tool={object=cutter}})
    getWorldTranslation,AttacherJoints=oldPosition,oldAttacher
    eq(success,true);eq(attached,true);eq(mounted,nil)
end)

-- Operations cannot be inferred from machinery simply being hauled as cargo.
test('the operational implement tree excludes a CONVIO dynamically loaded on N60',function()
    local cutter={uniqueId='header',spec_cutter={}}
    local carrier={uniqueId='carrier',spec_attachable={},spec_dynamicMountAttacher={dynamicMountedObjects={[cutter]=true}}}
    local combine={uniqueId='lexion',spec_motorized={},getAttachedImplements=function()return {{object=carrier}} end}
    local all=FMAWorld.children(combine)
    local operational=FMAWorld.operationalChildren(combine)
    local fullCargo=false;for _,v in ipairs(all) do if v==cutter then fullCargo=true end end
    eq(fullCargo,true)
    eq(#operational,2);eq(operational[1],combine);eq(operational[2],carrier)
end)

test('an actually attached combine cutter is an operational implement',function()
    local cutter={uniqueId='header',spec_cutter={}}
    local combine={uniqueId='lexion',getAttachedImplements=function()return {{object=cutter}} end}
    local out=FMAWorld.operationalChildren(combine)
    eq(#out,2);eq(out[2],cutter)
end)

test('GIANTS native fieldwork is never marked started without helper confirmation',function()
    local c=fixture();local r=record('combine');r.object.getIsAIActive=function()return false end
    local t={id='field:32:harvest',kind='field',fieldId=32,state='starting',operation='harvest',label='Harvest'}
    local job={isRunning=false};local stopped=false
    c.active={[job]={job=job,task=t,vehicle=r,start=0,startPendingNative=true}}
    c.onJobStopped=function(self,j)stopped=(j==job) end
    c.now=9001
    FMACourseplay.confirmPendingFieldwork(c)
    eq(t.fieldworkStartedAt,nil);eq(stopped,true)
end)

test('GIANTS native fieldwork is marked running after the actual job is active',function()
    local c=fixture();local r=record('combine')
    local job={isRunning=true}
    r.object.getIsAIActive=function()return true end
    r.object.getJob=function()return job end
    local t={id='field:32:harvest',kind='field',fieldId=32,state='starting',operation='harvest',label='Harvest'}
    c.active={[job]={job=job,task=t,vehicle=r,start=7000,startPendingNative=true}}
    FMACourseplay.confirmPendingFieldwork(c)
    eq(t.state,'running');eq(t.fieldworkStartedAt,c.now)
end)

test('an auxiliary assembly cannot remain falsely STARTED when no FS helper accepts it',function()
    local c=fixture();local r=record('tractor');r.object.getIsAIActive=function()return false end
    local j={isRunning=false};local done=false
    local t={id='assemble:field:5:lime',kind='assemble',label='Assemble'}
    c.active={[j]={job=j,task=t,vehicle=r,start=0}}
    c.now=14000;c.onJobStopped=function(self,job)done=job==j end
    FMAJobs.verifyAuxiliaryStarts(c)
    eq(done,true);eq(c.active[j].dispatchVerified,true)
end)

test('an auxiliary assembly confirmed by live FS25 AI is kept active',function()
    local c=fixture();local r=record('tractor')
    local j={isRunning=true};r.object.getJob=function()return j end
    c.active={[j]={job=j,task={id='assemble:field:5:lime',kind='assemble'},vehicle=r,start=0}}
    c.now=14000;FMAJobs.verifyAuxiliaryStarts(c)
    eq(c.active[j].dispatchVerified,true);eq(c.active[j].stopReason,nil)
end)

test('harvest AUTO assembles bare LEXION before staging its unloader',function()
    local c=fixture();c.vehicles={{key='lexion',isGrainCombine=true,capabilities={},harvestFruits={[1]=true},busy=false}}
    local t={operation='harvest',fruitIndex=1}
    eq(FMAFleetCoordinator.mainHarvesterReady(c,t),false)
    c.vehicles[1].capabilities.harvest=true
    eq(FMAFleetCoordinator.mainHarvesterReady(c,t),true)
    c.vehicles[1].busy=true
    eq(FMAFleetCoordinator.mainHarvesterReady(c,t),false)
end)

test('a cutter intended for another crop is not readiness for the current harvest',function()
    local c=fixture();c.vehicles={{key='lexion',isGrainCombine=true,capabilities={harvest=true},harvestFruits={[2]=true}}}
    eq(FMAFleetCoordinator.mainHarvesterReady(c,{operation='harvest',fruitIndex=1}),false)
end)

test('a manually pinned LEXION does not trigger support dispatch for an unrelated combine',function()
    local c=fixture();c.vehicles={{key='combineA',isGrainCombine=true,capabilities={harvest=true},harvestFruits={[1]=true}}}
    eq(FMAFleetCoordinator.mainHarvesterReady(c,{operation='harvest',preferredVehicleKey='combineB',fruitIndex=1}),false)
end)

-- 0.20.3: fixed after reviewing the actual LEXION/CONVIO + CRYSTAL save and input diagnostics.
test('a tractor has one exclusive unfinished assembly owner across native GoTo steps',function()
    local c=fixture()
    local p1={id='field:5:lime',preferredVehicleKey='crystal',preferredImplementKey='k105'}
    local p2={id='field:6:fertilize',preferredVehicleKey='crystal',preferredImplementKey='zats'}
    local plan1={power={key='crystal'},tool={key='k105'}}
    local plan2={power={key='crystal'},tool={key='zats'}}
    eq(FMAAssembler.acquireLease(c,p1,plan1),true)
    eq(c.assemblyLeases.crystal,p1.id)
    eq(FMAAssembler.acquireLease(c,p2,plan2),false)
    eq(c.assemblyLeases.crystal,p1.id)
    FMAAssembler.releaseLease(c,p1,plan1)
    eq(FMAAssembler.acquireLease(c,p2,plan2),true)
end)

test('a second work order cannot select a tractor leased to the first work order',function()
    local c=fixture();c.assemblyLeases={crystal='field:5:lime'};c.assemblyToolLeases={k105='field:5:lime'}
    local r=record('crystal');r.machineClass='tractor';r.object.spec_attacherJoints={}
    local tool={key='zats',object={spec_attachable={}},requiredPowerKW=0}
    local wanted={id='field:6:fertilize',operation='fertilize'}
    eq(FMAAssembler.isPowerCandidate(c,wanted,r,tool),false)
    wanted.id='field:5:lime'
    eq(FMAAssembler.isPowerCandidate(c,wanted,r,tool),true)
end)

test('finished or blocked assembly releases stale equipment leases',function()
    local c=fixture();c.tasks={['field:5:lime']={state='blocked'}}
    c.assemblyLeases={crystal='field:5:lime'};c.assemblyToolLeases={k105='field:5:lime'}
    FMAAssembler.update(c)
    eq(c.assemblyLeases.crystal,nil);eq(c.assemblyToolLeases.k105,nil)
end)

test('staging uses real hitch axis before a blind ring around K105',function()
    local oldDirection=localDirectionToWorld
    local oldWorld=getWorldTranslation
    localDirectionToWorld=function()return 0,0,1 end
    getWorldTranslation=function()return 100,0,200 end
    local p={power={object={posX=100,posZ=215}},tool={object={posX=100,posZ=200}},input={node=123},inputIndex=1}
    local positions=FMAAssembler.stagingCandidates(p,{assemblyStagingDistance=10})
    localDirectionToWorld=oldDirection;getWorldTranslation=oldWorld
    eq(positions[1].label,'hitchAxis')
    eq(positions[1].x,100);eq(positions[1].z,210)
end)

test('header on a carrier is not misclassified as attached to the harvester',function()
    local cutter={spec_cutter={}}
    local carrier={spec_dynamicMountAttacher={dynamicMountedObjects={[cutter]=true}}}
    local harvester={getAttachedImplements=function()return {{object=carrier}} end}
    eq(FMAHeaderTransport.attachedCutter(harvester),nil)
    harvester.getAttachedImplements=function()return {{object=cutter}} end
    eq(FMAHeaderTransport.attachedCutter(harvester),cutter)
end)


-- 0.20.9: verify an actual clickable, task-first interface rather than a
-- purely decorative mouse handler. The native ESC remains strictly off-limits.
test('clickable terminal opens cursor without ever mutating player camera',function()
    local previousInput=g_inputBinding;local previousMission=g_currentMission;local previousGui=g_gui
    local shown=false
    local calls={}
    g_inputBinding={getShowMouseCursor=function()return shown end,
        setShowMouseCursor=function(_,v)shown=v;calls[#calls+1]=v end}
    local cameraA={isRotatable=true};local cameraB={isRotatable=false}
    g_currentMission={controlledVehicle={spec_enterable={cameras={cameraA,cameraB}}}}
    g_gui={getIsGuiVisible=function()return false end,getIsDialogVisible=function()return false end}
    local c={visible=false}
    FMAHud.setVisible(c,true)
    eq(c.visible,true);eq(shown,true);eq(c.fmaMouseOwned,true)
    eq(cameraA.isRotatable,true);eq(cameraB.isRotatable,false)
    FMAHud.setVisible(c,false)
    eq(shown,false);eq(cameraA.isRotatable,true);eq(cameraB.isRotatable,false)
    eq(#calls,2)
    g_inputBinding=previousInput;g_currentMission=previousMission;g_gui=previousGui
end)

test('clickable terminal never hides an existing Courseplay cursor',function()
    local previousInput=g_inputBinding;local previousGui=g_gui
    local calls=0
    g_inputBinding={getShowMouseCursor=function()return true end,
        setShowMouseCursor=function()calls=calls+1 end}
    g_gui={getIsGuiVisible=function()return false end}
    local c={visible=false}
    FMAHud.setVisible(c,true);eq(c.fmaMouseOwned,false)
    FMAHud.setVisible(c,false);eq(calls,0)
    g_inputBinding=previousInput;g_gui=previousGui
end)

test('nine home cards are the real rendered navigation',function()
    eq(#FMAHud.cards,9)
    local seen={}
    for _,card in ipairs(FMAHud.cards) do seen[card.label]=true end
    for _,caption in ipairs({'POLNÍ PRÁCE','SKLIZEŇ','ZVÍŘATA','SILÁŽ','TECHNIKA','PROBLÉMY'}) do
        assert(seen[caption])
    end
    local d=FMAHud.cardGeometry()
    for i=1,9 do
        local x,y,w,h=FMAHud.cardRect(d,i)
        assert(x>=d.x and x+w<=d.x+d.w)
        assert(y>d.y+0.12 and y+h<d.top-0.149)
    end
end)

test('card-click opens only the category without starting a machine',function()
    local oldGui,oldInput=g_gui,Input
    g_gui={getIsGuiVisible=function()return false end,getIsDialogVisible=function()return false end}
    Input={MOUSE_BUTTON_LEFT=1}
    local t={id='field:32:harvest',kind='field',label='32 · Sklizeň',operation='harvest',priority=40,state='pending'}
    local f={id='field:6:fertilize',kind='field',label='6 · Hnojení',operation='fertilize',priority=55,state='pending'}
    local c={visible=true,fmaMouseMode=true,fmaCardHome=true,supported=true,page=1,selection=1,tasks={[t.id]=t,[f.id]=f},settings={enabled=false},
        notify=function()end,vehicles={},loose={},fields={},excluded={},conditions={}}
    local d=FMAHud.cardGeometry()
    local x,y,w,h=FMAHud.cardRect(d,3)
    eq(FMAHud.mouseEvent(c,x+w/2,y+h/2,true,false,1),true)
    eq(c.page,9);eq(c.fmaCardFilter,'harvest');eq(c.fmaCardHome,false)
    local rows=FMAHud.rows(c)
    eq(#rows,1);eq(rows[1].object.task,t)
    eq(t.ownerApproved,nil);eq(t.ownerRequested,nil)
    x,y,w,h=FMAHud.cardRect(d,1)
    eq(FMAHud.mouseEvent(c,x+w/2,y+h/2,true,false,1),true)
    eq(c.focusTaskId,t.id);eq(c.fmaTaskListMode,false)
    eq(t.ownerApproved,nil);eq(t.ownerRequested,nil)
    local detail=FMAHud.rows(c)
    eq(detail[1].object.slot,'simpleStart');eq(detail[2].object.slot,'simpleStop')
    eq(FMAHud.mouseEvent(c,d.backX+0.02,d.backY+0.02,true,false,1),true)
    eq(c.fmaTaskListMode,true)
    eq(FMAHud.mouseEvent(c,d.backX+0.02,d.backY+0.02,true,false,1),true)
    eq(c.fmaCardHome,true)
    g_gui=oldGui;Input=oldInput
end)

test('card pages permit non-destructive paging and ignore unrelated mouse clicks',function()
    local oldGui,oldInput=g_gui,Input
    g_gui={getIsGuiVisible=function()return false end,getIsDialogVisible=function()return false end}
    Input={MOUSE_BUTTON_LEFT=1,MOUSE_BUTTON_RIGHT=3}
    local tasks={}
    for i=1,14 do tasks[tostring(i)]={id=tostring(i),kind='field',label='Zakázka '..i,operation='harvest',state='pending',priority=i} end
    local c={visible=true,fmaMouseMode=true,fmaCardHome=false,fmaCardFilter='harvest',supported=true,page=9,fmaTaskListMode=true,selection=1,tasks=tasks,settings={enabled=false}}
    local d=FMAHud.cardGeometry()
    eq(FMAHud.mouseEvent(c,d.x+0.04,d.y+0.29,true,false,3),false)
    eq(FMAHud.mouseEvent(c,d.nextX+0.02,d.nextY+0.01,true,false,1),true)
    eq(c.fmaCardOffset,6)
    eq(FMAHud.mouseEvent(c,d.prevX+0.02,d.prevY+0.01,true,false,1),true)
    eq(c.fmaCardOffset,0)
    g_gui=oldGui;Input=oldInput
end)

test('card HUD never blocks native ESC and does not require Alt+P',function()
    local src=assert(io.open('scripts/FMAHud.lua','r')):read('*a')
    assert(not src:find('Alt+P',1,true))
    assert(not src:find('PROVÉST · ALT+P',1,true))
    local oldGui=g_gui
    g_gui={getIsGuiVisible=function()return true end}
    local c={visible=true,fmaMouseMode=true,fmaCardHome=true,selection=1}
    eq(FMAHud.mouseEvent(c,0.4,0.4,true,false,1),false)
    FMAHud.setVisible(c,true);eq(c.visible,true)
    g_gui=oldGui
end)

test('new card terminal renders only gameplay and never overlays ESC',function()
    local saved={}
    for _,key in ipairs({'g_gui','RenderText','setTextAlignment','setTextBold','setTextColor','renderText'}) do saved[key]=_G[key] end
    local seen=0
    RenderText={ALIGN_LEFT=0};setTextAlignment=function()end;setTextBold=function()end;setTextColor=function()end
    renderText=function(x,y,size,caption) assert(type(caption)=='string');seen=seen+1 end
    local overlay={setPosition=function()end,setDimension=function()end,setColor=function()end,render=function()end}
    local c={visible=true,page=3,selection=1,fmaCardHome=true,settings={enabled=false},vehicles={},loose={},tasks={},
        active={},reservations={},issues={},issueCounts=function()return {error=0,action=0,warning=0} end}
    g_gui={getIsGuiVisible=function()return false end,getIsDialogVisible=function()return false end}
    FMAHud.draw(c,overlay);local before=seen;assert(seen>=18)
    g_gui={getIsGuiVisible=function()return true end,getIsDialogVisible=function()return false end}
    FMAHud.draw(c,overlay);eq(seen,before)
    for k,v in pairs(saved) do _G[k]=v end
    if saved.g_gui==nil then g_gui=nil end
    if saved.RenderText==nil then RenderText=nil end
end)

-- 0.20.9 end-to-end regression scenarios from the latest Carpathian runtime logs.
test('field entrance sampler spreads around the field instead of retrying one corner',function()
    local c=fixture();c.fieldsById={['32']={x=0,z=0,object={polygonPoints={1,2,3,4,5,6,7,8}}}}
    local r=record('6r');r.x=120;r.z=0
    local saved=getWorldTranslation
    local points={{100,0},{70,70},{0,100},{-70,70},{-100,0},{-70,-70},{0,-100},{70,-70}}
    getWorldTranslation=function(index)return points[index][1],0,points[index][2] end
    local result=FMAFleetCoordinator.fieldWaitingCandidates(c,{fieldId='32',id='field:32:harvest'},r)
    getWorldTranslation=saved
    assert(#result>=12,'Not enough independent field entry points')
    local left,right,near,far=false,false,false,false
    for _,p in ipairs(result) do
        if p.x < -80 then left=true end
        if p.x > 80 then right=true end
        if p.z < -80 then near=true end
        if p.z > 80 then far=true end
    end
    assert(left and right and near and far,'Candidate positions need all four sides')
end)

test('fallback field entrance sampler still yields distant goals without polygon data',function()
    local c=fixture();c.fieldsById={['32']={x=100,z=-200,object={}}}
    local points=FMAFleetCoordinator.fieldWaitingCandidates(c,{fieldId='32'},record('6r'))
    assert(#points>=8,'Fallback must not provide one invalid target only')
end)

test('public lime source is discovered when no own AI fill trigger exists',function()
    local c=fixture();c.mapProfile={active=true,loadingStations={{name='Stanice s vápnem',owner=0,x=945,z=-88,fillTypes={},ai=false}}}
    local old=FillType;FillType=FillType or {};FillType.LIME=FillType.LIME or 5555
    local original=g_currentMission.storageSystem
    g_currentMission.storageSystem={getLoadingStations=function()return {} end}
    local req={fillType=FillType.LIME,object={},fillUnitIndex=1,level=0,capacity=1000}
    local parent={id='field:5:lime',operation='lime'}
    local station,why=FMARefillManager.findStation(c,record('crystal'),req,parent)
    eq(why,nil);eq(station.manual,true);assert(station.name:find('váp',1,true))
    assert((station.x-945)^2+(station.z+88)^2>=19*19,'Must stage away from building center')
    parent.manualSupplyCursor=11
    local nextStation=FMARefillManager.findStation(c,record('crystal'),req,parent)
    eq(nextStation.waitIndex,11);eq(nextStation.preferCourseplay,true)
    g_currentMission.storageSystem=original;FillType=old
end)

test('manual public lime loading keeps order alive and resumes on actual fill increase',function()
    local c=fixture();local r=record('crystal');local parent={id='field:5:lime',state='assembling',operation='lime',kind='field'}
    c.tasks={[parent.id]=parent};c.settings.enabled=true;c.settings.refillBeforeWork=0.25
    local material={fillLevel=0,getFillUnitFillLevel=function(self)return self.fillLevel end}
    local req={object=material,fillUnitIndex=1,fillType=5555,capacity=1000,level=0}
    local station={manual=true,name='Stanice s vápnem',x=0,z=0,waitIndex=1,
        waitPoints={{x=0,z=0},{x=10,z=0}}}
    local a={task={parentTaskId=parent.id,requirement=req,station=station},vehicle=r}
    FMARefillManager.onStopped(c,a,nil)
    eq(parent.state,'waiting');eq(parent.phase,'ČEKÁ NA RUČNÍ NALOŽENÍ')
    assert(c.refillSessions[parent.id] and c.refillSessions[parent.id].manual)
    material.fillLevel=350
    FMARefillManager.update(c)
    eq(parent.state,'pending');eq(parent.manualSupplyCursor,nil)
    eq(c.refillSessions[parent.id],nil);eq(c.reservations[r.key],nil)
end)

test('public supply source rotates away from inaccessible waiting points',function()
    local c=fixture();local r=record('crystal')
    local parent={id='field:5:lime',state='assembling',kind='field',operation='lime'}
    c.tasks={[parent.id]=parent}
    local s={manual=true,name='Stanice s vápnem',x=200,z=0,waitIndex=1,waitPoints={{x=100,z=0},{x=90,z=0}}}
    local a={task={parentTaskId=parent.id,requirement={object={},fillUnitIndex=1,fillType=5555,level=0},station=s},
        vehicle=r,stopReason='No path found'}
    FMARefillManager.onStopped(c,a,nil)
    eq(parent.state,'pending');eq(parent.manualSupplyCursor,2)
    s.waitIndex=2;FMARefillManager.onStopped(c,a,nil)
    eq(parent.state,'waiting');eq(parent.phase,'RUČNÍ PŘISTAVENÍ KE ZDROJI')
    assert(c.refillSessions[parent.id] and c.refillSessions[parent.id].needsDriver)
end)

test('multifunction silo manual loading is found without AI supported fill list',function()
    local c=fixture();local r=record('puma');r.object.posX=10;r.object.posZ=20
    local ft=7321
    local manual={getIsFillTypeSupported=function(_,requested)return requested==ft end}
    c.mapProfile={loadingStations={{name='Multifunkční plnicí silo',owner=1,x=60,z=80,
        object=manual,fillTypes={},ai=false}}}
    local original=g_currentMission.storageSystem
    g_currentMission.storageSystem={getLoadingStations=function()return {} end}
    local req={fillType=ft,object={},fillUnitIndex=1,level=0,capacity=1000}
    local station,why=FMARefillManager.findStation(c,r,req,{id='field:6:fertilize'})
    g_currentMission.storageSystem=original
    eq(why,nil);eq(station.manual,true);eq(station.name,'Multifunkční plnicí silo')
    eq(station.source.evidence,'station-contract')
    assert((station.x-60)^2+(station.z-80)^2>=19*19)
end)

test('real storage inventory allows manual loading at owned multifruit silo',function()
    local c=fixture();local ft=7322;local station={owningPlaceable={}}
    c.mapProfile={loadingStations={{name='Farma multifruit',object=station,owner=1,
        x=30,z=50,fillTypes={},ai=false}},storages={{object=station.owningPlaceable,
        fillByType={[ft]={fillType=ft,level=10000,capacity=20000}}}}}
    local sources=FMARefillManager.manualSupplySources(c,{fillType=ft},record('v'))
    eq(#sources,1);eq(sources[1].evidence,'placeable-inventory')
end)

test('empty multifunction silo is recognized from its supported type metadata',function()
    local c=fixture();local ft=7323
    local station={owningPlaceable={spec_silo={storages={{getIsFillTypeSupported=function(_,value)return value==ft end}}}}}
    c.mapProfile={loadingStations={{name='Prázdné multifruit silo',owner=1,x=40,z=80,object=station,
        fillTypes={},ai=false}},storages={}}
    local sources=FMARefillManager.manualSupplySources(c,{fillType=ft},record('v'))
    eq(#sources,1);eq(sources[1].evidence,'placeable-silo-type')
end)

test('manual loading prioritizes a taught safe filling point over generic radial guesses',function()
    local c=fixture();c.learnedPoints={A={role='PLNIČKA',x=66,z=88,angle=1},
        B={role='NÁŘADÍ',x=65,z=88,angle=3},C={role='PLNIČKA',x=950,z=900,angle=3}}
    local points=FMARefillManager.manualWaitingPoints({x=60,z=80},c)
    eq(points[1].x,66);eq(points[1].z,88);eq(points[1].angle,1)
    eq(points[1].taught,true)
    eq(#points,17)
end)

test('inaccessible public filler falls back to another compatible source',function()
    local c=fixture();local r=record('crystal');local t={id='field:5:lime',state='assembling'}
    c.tasks={[t.id]=t}
    local sources={{name='První silo'}, {name='Druhé silo'}}
    local station={manual=true,name='První silo',waitIndex=1,sourceIndex=1,sources=sources,
        waitPoints={{x=100,z=0}}}
    local active={task={parentTaskId=t.id,requirement={object={},fillUnitIndex=1,fillType=123,level=0},station=station},
        vehicle=r,stopReason='No path found'}
    FMARefillManager.onStopped(c,active,nil)
    eq(t.state,'pending');eq(t.phase,'DOPLNĚNÍ · JINÝ ZDROJ')
    eq(t.manualSupplySourceCursor,2);eq(t.manualSupplyCursor,1)
    assert(not c.refillSessions[t.id]);assert(t.reason:find('Druhé silo',1,true))
end)

test('manual supply rejects unrelated unknown product sources instead of guessing',function()
    local c=fixture();c.mapProfile={loadingStations={{name='Nesouvisející silo',owner=0,x=10,z=10,
        fillTypes={},object={getIsFillTypeSupported=function()return false end}}}}
    local sources=FMARefillManager.manualSupplySources(c,{fillType=8374},record('v'))
    eq(#sources,0)
end)

test('header transport rotates to other physical targets and never teleports cutter',function()
    local savedStage=FMAHeaderTransport.startGoTo
    local savedTargets=FMAFleetCoordinator.fieldWaitingCandidates
    local c=fixture();local parent={id='field:32:harvest',fieldId='32',operation='harvest'}
    local r=record('lexion');local carrier=record('n60');local plan={carrier=carrier,fieldStage={x=30,z=0}}
    local seen={};FMAFleetCoordinator.fieldWaitingCandidates=function()return {{x=10,z=0},{x=20,z=0}} end
    FMAHeaderTransport.startGoTo=function(_,_,_,_,goal)
        seen[#seen+1]={x=goal.x,z=goal.z,cp=goal.preferCourseplay}
        return true
    end
    for i=1,4 do
        local ok=FMAHeaderTransport.retryFieldOutbound(c,parent,r,plan,'No path found')
        eq(ok,true)
    end
    assert(seen[1].x~=seen[2].x and seen[2].x~=seen[3].x)
    eq(seen[4].cp,true)
    FMAHeaderTransport.startGoTo=savedStage
    FMAFleetCoordinator.fieldWaitingCandidates=savedTargets
end)

test('manual relocation resets stranded trailer route and invalidates stale header stage plan',function()
    local c=fixture();local r=record('moved');r.object.posX=25;r.object.posZ=0
    local t={id='field:32:harvest',kind='field',state='blocked',operation='harvest',vehicleKey='moved',
        reason='GIANTS i Courseplay odmítly alternativní cíle u pole',
        headerTransportPlan={carrier={key='carrier'},cutterKey='cutter',outboundTries=32}}
    c.tasks={[t.id]=t};c.implementReservations={carrier=t.id,cutter=t.id}
    c.preparedSupport={[t.id]={[1]={record=r,state='BLOCKED',retryAt=999999,stageFailureCount=32}}}
    c.stageRouteFailures={moved={retryAt=999999,count=99}}
    c.worldRegistry={vehicles={moved={key='moved',object=r.object,rootKey='moved',x=0,z=0}},placeables={},revision=0,lastScan=-100000}
    local oldVehicle=g_currentMission.vehicleSystem;local oldPlace=g_currentMission.placeableSystem
    g_currentMission.vehicleSystem={getVehicles=function()return {r.object} end}
    g_currentMission.placeableSystem={placeables={}}
    FMAWorldRegistry.update(c,true)
    g_currentMission.vehicleSystem=oldVehicle;g_currentMission.placeableSystem=oldPlace
    eq(t.state,'pending');eq(t.headerTransportPlan,nil)
    eq(c.implementReservations.carrier,nil);eq(c.implementReservations.cutter,nil)
    eq(c.preparedSupport[t.id][1].state,'NEEDED')
    eq(c.stageRouteFailures.moved,nil)
end)

test('a refused harvest completion verification cannot become success through Lua or-true fallback',function()
    local a=assert(io.open('scripts/FMAHeaderTransport.lua','r')):read('*a')
    local b=assert(io.open('scripts/FMAReturnManager.lua','r')):read('*a')
    assert(not a:find('or true,nil',1,true));assert(not b:find('or true,nil',1,true))
    assert(a:find('if controller.verifyFieldOrderComplete then',1,true))
end)


test('preloaded combine carrier cutter chain is procurement-serviceable',function()
    local src=assert(io.open('scripts/FMAProcurement.lua','r')):read('*a')
    assert(src:find('FMAHeaderTransport.preloadedChain(controller,task)',1,true))
    local controllerSrc=assert(io.open('scripts/FMAController.lua','r')):read('*a')
    assert(controllerSrc:find('preloadedServiceable=FMAHeaderTransport.preloadedChain(self,task)~=nil',1,true))
end)

test('preloaded cutter is visible in operator adapter list',function()
    local src=assert(io.open('scripts/FMAHud.lua','r')):read('*a')
    assert(src:find('adaptér je fyzicky na podvozku a připojí se u pole',1,true))
    assert(src:find('rows[#rows+1]=chain.cutter',1,true))
end)

test('preparation is never announced as fieldwork already running',function()
    local src=assert(io.open('scripts/FMAHud.lua','r')):read('*a')
    assert(src:find('ještě se připravuje',1,true))
    assert(not src:find('task.label.." už probíhá"',1,true))
end)


test('quarter-tank refuel policy and automatic unloader threshold are retained',function()
    eq(FMAState.defaults.fuelBeforeWork,0.25)
    eq(FMAState.defaults.unloaderCall,0.80)
end)

test('repeat status notifications do not spam the operator log',function()
    local saved=FMAUtil.log;local called=0
    FMAUtil.log=function()called=called+1 end
    local c=FMAController.new();c.now=20000
    c:notify('Čeká na doplnění');c.now=21000;c:notify('Čeká na doplnění')
    eq(called,1)
    c.now=30000;c:notify('Čeká na doplnění');eq(called,2)
    FMAUtil.log=saved
end)

test('telemetry records the blocked gate, actual field status and runtime fault',function()
    local c={now=30000,settings={enabled=true},tasks={x={id='field:32:harvest',state='blocked',fieldId='32',
        retryAt=32000,attempts=2,reason='No path'}},vehicles={},active={},reservations={},fields={{id='32',valid=true,ready=true}},
        subsystemFaults={['fleet.support']='failed'}}
    local output=FMALiveTelemetry.snapshot(c)
    assert(output:find('GATE | field:32:harvest',1,true))
    assert(output:find('FIELD_TRUTH | 32',1,true))
    assert(output:find('FAULT | fleet.support | failed',1,true))
end)

test('font unsupported glyphs are absent from the HUD',function()
    local file=assert(io.open('scripts/FMAHud.lua','r'));local source=file:read('*a');file:close()
    assert(not source:find('★',1,true))
    assert(not source:find('‹',1,true))
end)

end
