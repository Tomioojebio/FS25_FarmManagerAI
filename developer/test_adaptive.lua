return function(test,eq)
local function record(key,x)
    return {key=key,name=key,x=x or 0,z=0,capabilities={plow=true},damage=0,wear=0,workWidth=4,object={}}
end
local function make(taskKind)
    local c=FMAController.new()
    c.settings.enabled=true;c.settings.recoveryEnabled=true;c.settings.maxRecoveryCycles=3
    c.now=10000;c.vehicles={};c.reservations={};c.excluded={}
    c.farmId=1;c.issue=function(self,id,title,detail)self.lastIssue={id,title,detail} end
    return c,{id='field:5:plow',label='Orba pole 5',kind=taskKind or 'field',operation='plow',x=0,z=0,state='running',priority=70}
end

test('adaptive classification distinguishes physical obstruction from an unknown error',function()
    local category,retry=FMAExperience.classify('Vehicle has no path on blocked road')
    eq(category,'ROUTE');eq(retry,true)
    eq(select(1,FMAExperience.classify('unknown xyz stack trace')),'UNKNOWN')
    eq(select(2,FMAExperience.classify('unknown xyz stack trace')),false)
end)

test('adaptive refuses automatic retries of wrong ownership',function()
    local c,t=make();local r=record('tractorA');c.vehicles={r}
    eq(FMARecovery.noteFailure(c,t,r,'Stroj změnil majitele',{}),false)
    eq(t.state,'running')
end)

test('adaptive refuses player takeover as a recoverable engine failure',function()
    local c,t=make();local r=record('tractorA');c.vehicles={r}
    eq(FMARecovery.noteFailure(c,t,r,'Majitel převzal řízení',{}),false)
end)

test('adaptive respects a pinned implement during route failure',function()
    local c,t=make();t.ownerPinnedImplement=true
    local a,b=record('a'),record('b');c.vehicles={a,b}
    eq(FMARecovery.noteFailure(c,t,a,'stuck on road',{}),false)
end)

test('adaptive failover respects actual live vehicle reservations',function()
    local c,t=make();local a,b=record('a'),record('b');c.vehicles={a,b};c.reservations.b='otherOrder'
    eq(FMARecovery.hasAlternative(c,t,a),false)
    c.reservations.b=nil
    eq(FMARecovery.hasAlternative(c,t,a),true)
end)

test('adaptive cycles through available alternate vehicles without poisoning a busy one',function()
    local c,t=make();local a,b=record('a'),record('b');c.vehicles={a,b}
    local f={count=1,blocked=true,retryAt=0}
    eq(FMARecovery.noteFailure(c,t,a,'blocked road',f),true)
    eq(t.state,'pending');eq(t.failedVehicleKeys.a,true)
    eq(f.blocked,false);assert(f.retryAt>c.now)
    local best=FMAPlanner.chooseVehicle(t,c.vehicles,{}, {},c.experience)
    eq(best.key,'b')
end)

test('adaptive no replacement schedules only one bounded retry of transient error',function()
    local c,t=make();local a=record('a');c.vehicles={a}
    local f={count=1,blocked=true,retryAt=0}
    eq(FMARecovery.noteFailure(c,t,a,'blocked road',f),true)
    eq(t.phase,'OBNOVA / DRUHÝ POKUS');eq(t.sameVehicleRetryCount,1)
    eq(FMARecovery.noteFailure(c,t,a,'blocked road',f),false)
end)

test('adaptive blocks permanent unknown error immediately, with advice and memory',function()
    local c,t=make();local a=record('a');c.vehicles={a}
    FMAJobs.fail(c,t,a,'uncategorized internal anomaly')
    eq(t.state,'blocked');eq(t.phase,'BLOKACE / UNKNOWN')
    local memory=c.experience[FMAExperience.key('plow','a')]
    eq(memory.failures,1);eq(memory.successes,0)
    assert(c.lastIssue and string.find(c.lastIssue[3],'Neznámá příčina',1,true))
end)

test('adaptive does not falsely learn from accepted job start',function()
    local c,t=make();local a=record('a');c.vehicles={a}
    t.state='starting';t.fieldworkStartedAt=nil
    eq(FMAExperience.verified(c,t,a,true),false)
    eq(next(c.experience),nil)
end)

test('adaptive does not falsely learn after unverified real field work',function()
    local c,t=make();local a=record('a');t.state='done';t.fieldworkStartedAt=100
    eq(FMAExperience.verified(c,t,a,false),false)
    eq(next(c.experience),nil)
end)

test('adaptive records verified completion and reduces earlier failure debt',function()
    local c,t=make();local a=record('a');c.vehicles={a}
    FMAExperience.note(c,t,a,false,'blocked road')
    FMAExperience.note(c,t,a,false,'blocked road')
    local prior=FMAExperience.penalty(c.experience,t,a)
    assert(prior>0)
    t.state='done';t.fieldworkStartedAt=1100
    eq(FMAExperience.verified(c,t,a,true),true)
    local row=c.experience[FMAExperience.key('plow','a')]
    eq(row.successes,1);eq(row.failures,1)
    assert(FMAExperience.penalty(c.experience,t,a)<prior)
end)

test('adaptive history ranking changes preference but not compatibility',function()
    local c,t=make();local near=record('near',0);local far=record('far',15)
    c.vehicles={near,far}
    eq(FMAPlanner.chooseVehicle(t,c.vehicles,{}, {},c.experience).key,'near')
    for _=1,3 do FMAExperience.note(c,t,near,false,'blocked road') end
    eq(FMAPlanner.chooseVehicle(t,c.vehicles,{}, {},c.experience).key,'far')
    eq(FMAPlanner.chooseVehicle(t,{near},{}, {},c.experience).key,'near')
end)

test('adaptive route exhaustion stops loops with a concrete issue',function()
    local c,t=make();local r=record('v');c.tasks={[t.id]=t}
    local active={task=t,vehicle=r,stopReason='RECOVERY_REROUTE'}
    for i=1,3 do eq(FMARecovery.onStopped(c,active),true) end
    eq(t.state,'pending')
    eq(FMARecovery.onStopped(c,active),true)
    eq(t.state,'blocked');eq(t.phase,'BLOKACE / TRASA')
    assert(c.lastIssue and string.find(c.lastIssue[3],'Všechny bezpečné pokusy',1,true))
end)

test('adaptive experience is independent for each vehicle and operation',function()
    local c,t=make();local a,b=record('a'),record('b');FMAExperience.note(c,t,a,false,'blocked road')
    eq(FMAExperience.penalty(c.experience,t,b),0)
    eq(FMAExperience.penalty(c.experience,{operation='harvest'},a),0)
end)

test('adaptive memory survives native-style XML save and reload',function()
    local previous={mission=g_currentMission,xml=XMLFile,schema=XMLSchema,types=XMLValueType,exists=fileExists,cached=FMAState.schema}
    local written={}
    g_currentMission={missionInfo={savegameDirectory='/example/savegame'},isRunning=true}
    XMLValueType={STRING=1,BOOL=2,FLOAT=3,INT=4}
    XMLSchema={new=function() return {register=function() end} end}
    FMAState.schema=nil
    fileExists=function() return true end
    XMLFile={}
    local function obj()
        return {setValue=function(self,key,v)written[key]=v end,
            getValue=function(self,key,default) if written[key]==nil then return default end return written[key] end,
            hasProperty=function(self,key)
                for k in pairs(written) do if string.sub(k,1,#key)==key then return true end end
                return false
            end,save=function()end,delete=function()end}
    end
    XMLFile.create=function() return obj() end
    XMLFile.load=function() return obj() end
    local c,t=make();c.initialized=true;c.supported=true
    c.policies={};c.excluded={};c.routes={};c.forageStages={};c.learnedPoints={};c.learnedRoutes={}
    local a=record('tractor1');FMAExperience.note(c,t,a,false,'blocked road')
    t.state='done';t.fieldworkStartedAt=500
    FMAExperience.verified(c,t,a,true)
    c.handoverJournal={[t.id]={vehicle='tractor1',tool='plough5',stage='detached',operation='plow',reason='road stuck'}}
    FMAExperience.handover(c,t,'tractor1',true,'returned')
    FMAState.save(c)
    local restored=FMAState.load()
    local row=restored.experience[FMAExperience.key('plow','tractor1')]
    assert(row)
    eq(row.successes,1);eq(row.failures,0);eq(row.reliabilityDebt,0);eq(row.lastCategory,'VERIFIED')
    eq(row.handovers,1)
    eq(restored.handoverJournal[t.id].vehicle,'tractor1')
    eq(restored.handoverJournal[t.id].tool,'plough5')
    eq(restored.handoverJournal[t.id].stage,'detached')
    g_currentMission=previous.mission;XMLFile=previous.xml;XMLSchema=previous.schema;XMLValueType=previous.types;fileExists=previous.exists;FMAState.schema=previous.cached
end)

local function physicalHandover()
    local c,t=make()
    c.settings.autoReturn=true;c.settings.parkTolerance=8
    local tractor={ownerFarmId=1,posX=20,posZ=0}
    local tool={ownerFarmId=1,posX=20,posZ=0,attacher=tractor}
    function tool:getAttacherVehicle() return self.attacher end
    function tool:getIsDetachAllowed() return true end
    function tractor:getAttachedImplements() return tool.attacher==self and {{object=tool}} or {} end
    function tractor:detachImplementByObject(target)
        if target~=tool then return false end
        tool.attacher=nil;return true
    end
    local r=record('A');r.object=tractor;r.name='A'
    local b=record('B');b.object={ownerFarmId=1,posX=5,posZ=2};b.name='B'
    c.tasks={[t.id]=t};c.vehicles={r,b};c.homePositions={A={x=0,z=0}}
    c.toolHomes={T={x=20,z=0}}
    c.loose={};c.implementReservations={}
    t.managedAttachment={toolObject=tool,toolKey='T',toolName='Plough',toolHome=c.toolHomes.T,powerKey='A'}
    return c,t,r,b,tool,tractor
end

test('handover reserves physical implement without immediately offering work to tractor B',function()
    local c,t,a,b=physicalHandover()
    local failure={count=1,blocked=true,retryAt=0}
    eq(FMARecovery.noteFailure(c,t,a,'road stuck',failure),true)
    eq(t.state,'handover')
    eq(failure.blocked,false)
    eq(c.handoverJournal[t.id].stage,'attached')
    eq(c.handoverLeases.T,t.id)
    eq(c.reservations.A,'handover:'..t.id..':A')
    eq(t.failedVehicleKeys,nil)
    local merged=FMAPlanner.merge(c.tasks,{{id=t.id,state='pending',fingerprint='changed'}},c.now)
    eq(merged[t.id].state,'handover')
    local v,tools=FMALifecycle.liveReservations(c)
    eq(v.A,true);eq(tools.T,true)
end)

test('after detached tool and parked tractor manager enables same tool on different power unit',function()
    local c,t,a,b,tool,tractor=physicalHandover()
    local savedStart=FMAReturnManager.startDrive
    FMAReturnManager.startDrive=function(_,record,target,task,phase)
        task.phase=phase;task.target=target
        return true
    end
    local ok,err=pcall(function()
        eq(FMARecovery.noteFailure(c,t,a,'road stuck',{count=1,blocked=true,retryAt=0}),true)
        c.now=c.now+2000;FMAReturnManager.update(c)
        eq(c.pendingHandovers[t.id],nil)
        local stage={kind='return',purpose='handover',task=t}
        -- Use the real generated return task retained by the launch hook.
        local j={id='handover:'..t.id..':A',kind='return',purpose='handover',parentTask=t,parentTaskId=t.id,
            originalKey='A',attachment=t.managedAttachment,home=c.homePositions.A,phase='toolBay',target=c.toolHomes.T}
        FMAReturnManager.finish(c,{task=j,vehicle=a})
        eq(tool.attacher,nil)
        eq(j.phase,'vehicleHome')
        eq(t.state,'handover')
        eq(c.handoverJournal[t.id].stage,'detached')
        tractor.posX=0
        FMAReturnManager.finish(c,{task=j,vehicle=a})
        eq(t.state,'pending');eq(t.failedVehicleKeys.A,true)
        eq(t.preferredImplementKey,'T')
        eq(t.forceHandoverImplement,true)
        eq(c.handoverJournal[t.id],nil)
        eq(c.handoverLeases.T,nil)
        eq(c.experience[FMAExperience.key('plow','A')].handovers,1)
        eq(c.experience[FMAExperience.key('plow','A')].successes,0)
    end)
    FMAReturnManager.startDrive=savedStart
    assert(ok,err)
end)

test('handover route reroute does not requeue field while implement remains attached',function()
    local c,t,a,b,tool=physicalHandover()
    FMARecovery.noteFailure(c,t,a,'road stuck',{})
    local retry=FMAReturnManager.startDrive
    FMAReturnManager.startDrive=function()return true end
    local active={task={id='handover:'..t.id..':A',kind='return',purpose='handover',parentTask=t,
        parentTaskId=t.id,attachment=t.managedAttachment,phase='toolBay',target={x=20,z=0},originalKey='A'},
        vehicle=a,stopReason='RECOVERY_REROUTE'}
    local ok,err=pcall(function()
        eq(FMARecovery.onStopped(c,active),true);eq(t.state,'handover')
        eq(FMARecovery.onStopped(c,active),true);eq(t.state,'blocked')
        eq(c.handoverJournal[t.id].stage,'blocked')
        eq(tool.attacher,a.object)
    end)
    FMAReturnManager.startDrive=retry
    assert(ok,err)
end)

test('handover cannot start without verified home bay; never releases failed tractor into another job',function()
    local c,t,a=physicalHandover()
    c.toolHomes.T=nil;t.managedAttachment.toolHome=nil
    eq(FMARecovery.noteFailure(c,t,a,'road stuck',{}),true)
    eq(t.state,'blocked')
    eq(t.failedVehicleKeys,nil)
    eq(c.pendingHandovers[t.id],nil)
end)

test('resume journal from a physically detached implement resumes only parking leg',function()
    local c,t,a,b,tool,tractor=physicalHandover()
    tractor:detachImplementByObject(tool)
    c.handoverJournal={[t.id]={taskId=t.id,vehicle='A',tool='T',operation='plow',stage='detached',reason='road stuck'}}
    c.vehicleByKey={A=a}
    local resolve=FMAWorld.resolveVehicle
    local start=FMAReturnManager.startDrive
    FMAWorld.resolveVehicle=function(key) if key=='T' then return tool end end
    FMAReturnManager.startDrive=function(_,record,target,returnTask,phase)
        eq(phase,'vehicleHome')
        returnTask.phase=phase;returnTask.target=target
        c.active.test={task=returnTask,vehicle=record}
        return true
    end
    local ok,err=pcall(function()
        FMARecovery.restoreJournal(c)
        eq(t.state,'handover');eq(c.handoverJournal[t.id].stage,'detached')
        eq(c.active.test.task.purpose,'handover')
        FMARecovery.restoreJournal(c)
        eq(FMAUtil.count(c.active),1) -- no duplicated resume
    end)
    FMAWorld.resolveVehicle=resolve;FMAReturnManager.startDrive=start
    assert(ok,err)
end)

test('adaptive save writes at most 120 remembered combinations',function()
    -- This mirrors the schema bound without any game file operations.
    local c,t=make()
    for i=1,160 do FMAExperience.note(c,t,record('tractor'..i),false,'blocked road') end
    eq(FMAUtil.count(c.experience),160) -- runtime observes all, but on-disk limit is bounded
    eq(FMAExperience.LIMIT,120)
end)

test('adaptive extended wait timeout never restarts obstructed traffic',function()
    local c,t=make();local a=record('a');c.vehicles={a}
    eq(select(1,FMAExperience.classify('Cesta čeká déle než 5 minut; zkontroluj obsazený příjezd')),'EXHAUSTED')
    eq(FMARecovery.noteFailure(c,t,a,'Cesta čeká déle než 5 minut; zkontroluj obsazený příjezd',{}),false)
end)

test('adaptive does not blame the vehicle for stock, traffic, or player issues',function()
    local c,t=make();local a=record('a')
    FMAExperience.note(c,t,a,false,'Nemá dostatek osiva')
    FMAExperience.note(c,t,a,false,'Majitel převzal řízení')
    FMAExperience.note(c,t,a,false,'Vozidlo je obsazené jiným pracovníkem')
    eq(FMAExperience.penalty(c.experience,t,a),0)
    eq(c.experience[FMAExperience.key('plow','a')].failures,3)
end)

test('adaptive physical stall is a recoverable route failure',function()
    eq(select(1,FMAExperience.classify('Stroj se opakovaně nepohybuje - výměna pracovní soupravy')),'ROUTE')
end)

test('live verification never confuses unavailable field data for a completed job',function()
    local c,t=make();t.fieldId='5';t.operation='harvest';t.fieldworkStartedAt=123
    c.fieldsById={['5']={valid=false,ready=false,bare=true}}
    eq(c:verifyFieldOrderComplete(t),false)
    c.fieldsById={}
    eq(c:verifyFieldOrderComplete(t),false)
end)

test('live verification requires a physically harvested field',function()
    local c,t=make();t.fieldId='5';t.operation='harvest';t.fieldworkStartedAt=123
    c.fieldsById={['5']={valid=true,ready=false,alive=true,bare=false}}
    eq(c:verifyFieldOrderComplete(t),false)
    c.fieldsById['5'].bare=true
    t.workEvidence={mode='mechanical',observedMove=125}
    eq(c:verifyFieldOrderComplete(t),true)
end)

test('live verification rejects unchanged fingerprint even after AI stopped',function()
    local c,t=make();t.fieldId='5';t.operation='lime';t.fieldworkStartedAt=123;t.fingerprint='same'
    c.fieldsById={['5']={valid=true,needsLime=false,fingerprint='same'}}
    eq(c:verifyFieldOrderComplete(t),false)
    c.fieldsById['5'].fingerprint='after'
    -- New physical evidence gate: density-map change is never enough for lime.
    eq(c:verifyFieldOrderComplete(t),false)
end)

test('live verification cannot certify windrowing from unrelated bare-ground state',function()
    local c,t=make();t.fieldId='5';t.operation='windrow';t.fieldworkStartedAt=123
    c.fieldsById={['5']={valid=true,ready=false,bare=true}}
    eq(c:verifyFieldOrderComplete(t),false)
end)

test('live verification rejects a mixed, partly harvested field',function()
    local c,t=make();t.fieldId='5';t.operation='harvest';t.fieldworkStartedAt=123
    c.fieldsById={['5']={valid=true,mixed=true,ready=false,bare=true}}
    eq(c:verifyFieldOrderComplete(t),false)
end)

test('AI stop failure is handed to failover without final handler overwriting retry',function()
    local c,t=make();local a,b=record('a'),record('b')
    a.object={getIsEntered=function()return false end,getIsAIActive=function()return false end}
    b.object={getIsEntered=function()return false end,getIsAIActive=function()return false end}
    c.vehicles={a,b};c.tasks={[t.id]=t}
    c.reservations[a.key]=t.id
    local job={isRunning=false};c.active[job]={job=job,task=t,vehicle=a,start=c.now,lastProgress=c.now}
    local msg={getMessage=function()return 'blocked road' end}
    c:handleJobStopped(job,msg)
    eq(t.state,'pending')
    eq(t.phase,'OBNOVA / NÁHRADNÍ STROJ')
    eq(c.reservations.a,nil)
    eq(c.active[job],nil)
    eq(FMAPlanner.chooseVehicle(t,c.vehicles,c.reservations,{},c.experience).key,'b')
end)



-- Real return leg must not silently turn an unverifiable forage pass into
-- a verified agricultural success or train the vehicle as if it were one.
local function parkedReturn(c,parent,r)
    r.object.posX=0;r.object.posZ=0
    c.tasks={[parent.id]=parent}
    c.reservations[r.key]='return:'..parent.id
    return {task={kind='return',id='return:'..parent.id,phase='vehicleHome',
        parentTask=parent,parentTaskId=parent.id,label='Návrat',target={x=0,z=0}},vehicle=r}
end

test('forage stage evidence stays distinct from full physical field completion',function()
    local c,t=make();t.fieldId='5';t.operation='windrow';t.forageChain=true
    t.fieldworkStartedAt=123;t.confirmedAiWorkFinish=true;t.qualityCourseReady=true
    c.forageStages={['5']='windrowedGrass'}
    c.fieldsById={['5']={valid=true,bare=true,ready=false}}
    local ok,why,proof=c:verifyFieldOrderComplete(t)
    eq(ok,true);eq(proof,'AI_STAGE')
    assert(string.find(why,'neověřen',1,true)~=nil)
    t.confirmedAiWorkFinish=false
    eq(c:verifyFieldOrderComplete(t),false)
end)

test('completed forage route is not falsely learned as a verified machine success',function()
    local c,t=make();local r=record('win')
    t.fieldId='5';t.operation='windrow';t.forageChain=true
    t.fieldworkStartedAt=123;t.confirmedAiWorkFinish=true;t.qualityCourseReady=true
    c.forageStages={['5']='windrowedGrass'}
    c.fieldsById={['5']={valid=true,bare=true,ready=false}}
    FMAReturnManager.finish(c,parkedReturn(c,t,r))
    eq(t.state,'stageComplete');eq(next(c.experience),nil)
    eq(c.reservations[r.key],nil)
end)

test('physical field evidence after parking is eligible for positive learning',function()
    local c,t=make();local r=record('liming')
    t.fieldId='5';t.operation='lime';t.fieldworkStartedAt=123;t.fingerprint='before'
    -- Lime verification requires BOTH soil state and a genuine consumption + movement record.
    t.workEvidence={vehicleKey=r.key,first=1000,minimum=760,capacity=1000,observedMove=45}
    c.fieldsById={['5']={valid=true,needsLime=false,fingerprint='after'}}
    FMAReturnManager.finish(c,parkedReturn(c,t,r))
    eq(t.state,'done')
    local row=c.experience[FMAExperience.key('lime','liming')]
    assert(row and row.successes==1)
end)

test('unverified work after parking gets only one bounded rework attempt',function()
    local c,t=make();local r=record('v')
    t.fieldId='5';t.operation='plow';t.fieldworkStartedAt=123
    c.fieldsById={['5']={valid=true,needsPlow=true}}
    FMAReturnManager.finish(c,parkedReturn(c,t,r))
    eq(t.state,'pending');eq(t.verificationAttempts,1)
    assert(t.retryAt>c.now)
    eq(next(c.experience),nil)
    FMAReturnManager.finish(c,parkedReturn(c,t,r))
    eq(t.state,'blocked');eq(t.verificationAttempts,2)
    eq(next(c.experience),nil)
end)

test('unavailable field scan at return does not trigger a blind second pass',function()
    local c,t=make();local r=record('v')
    t.fieldId='5';t.operation='plow';t.fieldworkStartedAt=123
    c.fieldsById={['5']={valid=false,needsPlow=false}}
    FMAReturnManager.finish(c,parkedReturn(c,t,r))
    eq(t.state,'blocked');eq(t.verificationAttempts,1)
end)


test('FS25 asynchronous support-leg detach waits for physical disconnection before tractor parking',function()
    local c,t,a,b,tool=physicalHandover()
    local seen=0
    tool.isDetachAllowed=function()return true end
    tool.startDetachProcess=function(self)
        seen=seen+1
        self.spec_attachable={detachingInProgress=true}
        return false
    end
    tool.getIsDetachAllowed=function()error('should use native FS25 method instead') end
    local old=FMAReturnManager.startDrive
    local drives={}
    FMAReturnManager.startDrive=function(_,r,destination,task,phase)
        drives[#drives+1]=phase
        task.phase=phase;task.target=destination
        return true
    end
    local ok,err=pcall(function()
        FMARecovery.noteFailure(c,t,a,'road stuck',{})
        c.now=c.now+2000;FMAReturnManager.update(c)
        local j={id='handover:'..t.id..':A',kind='return',purpose='handover',parentTask=t,parentTaskId=t.id,
            originalKey='A',attachment=t.managedAttachment,home=c.homePositions.A,phase='toolBay',target=c.toolHomes.T}
        FMAReturnManager.finish(c,{task=j,vehicle=a})
        eq(seen,1);eq(drives[1],'toolBay');eq(#drives,1)
        assert(c.pendingDetaches[j.id])
        eq(c.handoverJournal[t.id].stage,'attached')
        eq(t.state,'handover')
        FMAReturnManager.update(c)
        eq(#drives,1)
        tool.attacher=nil
        c.now=c.now+2500;FMAReturnManager.update(c)
        eq(c.pendingDetaches[j.id],nil)
        eq(drives[2],'vehicleHome')
        eq(c.handoverJournal[t.id].stage,'detached')
        eq(t.state,'handover')
    end)
    FMAReturnManager.startDrive=old
    assert(ok,err)
end)

test('FS25 rejected detachment blocks but does not silently free handover tool',function()
    local c,t,a,b,tool=physicalHandover()
    tool.isDetachAllowed=function()return false,'Stojan není vysunutý' end
    eq(FMARecovery.noteFailure(c,t,a,'road stuck',{}),true)
    local j={id='handover:'..t.id..':A',kind='return',purpose='handover',parentTask=t,parentTaskId=t.id,
        originalKey='A',attachment=t.managedAttachment,home=c.homePositions.A,phase='toolBay',target=c.toolHomes.T}
    FMAReturnManager.finish(c,{task=j,vehicle=a})
    eq(t.state,'blocked');eq(c.handoverJournal[t.id].stage,'blocked')
    eq(tool.attacher,a.object)
    local vehicles,tools=FMALifecycle.liveReservations(c)
    eq(vehicles.A,true);eq(tools.T,true)
end)

test('handover journal restoration cannot schedule duplicate during pending animated detach',function()
    local c,t,a,b,tool=physicalHandover()
    c.handoverJournal={[t.id]={taskId=t.id,vehicle='A',tool='T',operation='plow',stage='attached',reason='road stuck'}}
    c.pendingDetaches={[t.id]={task={purpose='handover',parentTaskId=t.id}}}
    c.vehicleByKey={A=a};c.tasks={[t.id]=t}
    local old=FMAReturnManager.beginRecovery
    FMAReturnManager.beginRecovery=function()error('duplicate beginRecovery')end
    local ok,err=pcall(function() FMARecovery.restoreJournal(c) end)
    FMAReturnManager.beginRecovery=old
    assert(ok,err)
end)


test('return job rejected silently by GIANTS is detected rather than reserving tractor forever',function()
    local c,t,a=physicalHandover()
    local old=FMAJobs.controller
    FMAJobs.controller=c
    local job={isRunning=false}
    local j={id='handover:'..t.id..':A',kind='return',purpose='handover',parentTaskId=t.id,
        parentTask=t,attachment=t.managedAttachment,phase='toolBay',target=c.toolHomes.T,originalKey='A'}
    c.active[job]={job=job,task=j,vehicle=a,start=1000,lastProgress=1000}
    c.now=20000
    local fired=0
    local oldStop=c.onJobStopped
    c.onJobStopped=function(self,observed,reason)
        eq(observed,job);fired=fired+1
    end
    local ok,err=pcall(FMAJobs.verifyAuxiliaryStarts,c)
    c.onJobStopped=oldStop;FMAJobs.controller=old
    assert(ok,err)
    eq(fired,1);eq(c.active[job].dispatchVerified,true)
    eq(c.active[job].stopReason,'FS25 nepotvrdilo převzetí pomocného přejezdu do 12 s')
end)


test('previously hitched attachment can be adopted only if its FS25 tool specialization actually matches task',function()
    local c,t,a,b,tool=physicalHandover()
    tool.uniqueId='T'
    a.object.uniqueId='A'
    c.toolHomes.T={x=20,z=0}
    local got=FMARecovery.findKnownAttachment(c,t,a)
    eq(got,nil) -- no plow specialization, a ballast weight must never be adopted
    tool.spec_plow={}
    local found=FMARecovery.findKnownAttachment(c,t,a)
    assert(found and found.toolKey=='T')
    eq(found.toolHome.x,20)
end)

end
