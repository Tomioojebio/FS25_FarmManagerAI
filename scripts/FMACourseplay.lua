-- Registered Courseplay jobs, with native travel to the work site and explicit
-- asynchronous boundary preparation. No dependency on CP's private globals.
FMACourseplay = {}

function FMACourseplay.available()
    return g_modIsLoaded and g_modIsLoaded.FS25_Courseplay==true
end

local function distanceSq(a,b)
    if not a or not b or not a.x or not a.z or not b.x or not b.z then return math.huge end
    local dx,dz=a.x-b.x,a.z-b.z
    return dx*dx+dz*dz
end

local function recordForKey(c,key)
    return key and c and c.vehicleByKey and c.vehicleByKey[key] or nil
end

function FMACourseplay.syncManagedHarvestSettings(c)
    -- Compatibility settings are synchronized even while AUTO is paused so a player
    -- can take over the same prepared crew and start Courseplay manually without
    -- inheriting a known-invalid header-trailer configuration.
    if not c or not c.settings or not FMACourseplay.available() then return end
    for _,task in pairs(c.tasks or {}) do
        if task and task.kind=='field' and task.operation=='harvest' and task.state~='done' then
            local record=recordForKey(c,task.preferredVehicleKey or task.vehicleKey)
            if record and record.object and FMAFieldQuality and FMAFieldQuality.prepareCourseplayVehicle then
                local ok,why=FMAFieldQuality.prepareCourseplayVehicle(record.object,task,c)
                if not ok then task.cpPreparationError=why else task.cpPreparationError=nil end
            end
        end
    end
end

local function cpTargetMatchesTask(vehicle,task)
    if FMAFieldQuality and FMAFieldQuality.courseMatchesTask then return FMAFieldQuality.courseMatchesTask(vehicle,task,170) end
    return false
end

-- A manually started H/Courseplay worker remains part of the same work order. The
-- dispatcher adopts the live FS25/CP state instead of treating the machine as "busy"
-- and trying to start a competing job.
function FMACourseplay.adoptExistingFieldwork(c)
    if not c or not c.settings or not c.settings.enabled then return end
    c.externalFieldwork=c.externalFieldwork or {}
    local activeManaged={}
    for _,a in pairs(c.active or {}) do if a and a.vehicle then activeManaged[a.vehicle.key]=true end end

    for _,record in ipairs(c.vehicles or {}) do
        if record and record.object and not activeManaged[record.key] then
            local state=FMAGameNative and FMAGameNative.operatorState(record.object) or {mode='IDLE',aiActive=false,manual=false,cpActive=false}
            local session=c.externalFieldwork[record.key]
            if state.aiActive then
                local best,bestD=nil,math.huge
                for _,task in pairs(c.tasks or {}) do
                    if task and task.kind=='field' and task.state~='done'
                        and task.ownerStopRequested~=true and (not c.settings.selectedJobsOnly or task.ownerApproved==true) then
                        local pinned=(task.preferredVehicleKey==record.key or task.vehicleKey==record.key)
                        local targetMatch=state.cpActive and cpTargetMatchesTask(record.object,task)
                        if pinned or targetMatch then
                            local d=distanceSq(record,task)
                            if targetMatch then d=0 end
                            if d<bestD then best,bestD=task,d end
                        end
                    end
                end
                if best then
                    best.vehicleKey=record.key
                    best.state='running'
                    best.phase=state.cpActive and 'PRÁCE · COURSEPLAY (PŘEVZATO)' or 'PRÁCE · FS AI (PŘEVZATO)'
                    best.reason='Dispečink převzal již běžící pracovní job bez jeho restartu'
                    best.fieldworkStartedAt=best.fieldworkStartedAt or c.now
                    if FMAWorkEvidence then FMAWorkEvidence.begin(c,best,record) end
                    best.fieldworkStartFingerprint=best.fieldworkStartFingerprint or best.fingerprint
                    best.awaitingWorldVerification=false
                    c.externalFieldwork[record.key]={taskId=best.id,mode=state.mode,started=c.now}
                    -- A manually launched LEXION may never have passed through
                    -- FMA's own job-start callback. Without this crew registration,
                    -- the dispatcher can report 'harvesting' but have NO unloaders.
                    if best.operation=='harvest' and FMAFleetCoordinator and FMAFleetCoordinator.registerCrew then
                        FMAFleetCoordinator.registerCrew(c,best,record,nil)
                    end
                    if not session and FMADiagnostics then FMADiagnostics.event(c,'fieldwork.adopt',best.id,(record.name or record.key)..' '..state.mode) end
                end
            elseif session then
                local task=c.tasks and c.tasks[session.taskId]
                if task and task.state=='running' and task.vehicleKey==record.key and state.manual
                    and task.ownerStopRequested~=true then
                    -- Keep the adoption session alive while the owner is physically driving.
                    -- When H/CP is enabled again the same crew is re-adopted; when the owner
                    -- leaves the cab the order returns to the dispatcher.
                    session.mode='PLAYER';task.phase='RUČNÍ ČLEN ČETY';task.reason='Majitel převzal volant · zakázka zůstává aktivní'
                else
                    c.externalFieldwork[record.key]=nil
                    if task and task.state=='running' and task.vehicleKey==record.key
                        and task.ownerStopRequested~=true then
                        task.state='cooldown';task.phase='OVĚŘENÍ SKUTEČNÉHO STAVU POLE'
                        task.reason='Externí AI/CP skončila · Dispečink ověřuje skutečný stav pole'
                        task.awaitingWorldVerification=true;task.retryAt=(c.now or 0)+1500
                        c.elapsed=(c.settings.scanSeconds or 12)*1000
                    end
                end
            end
        end
    end
end

function FMACourseplay.needsFieldStaging(c,record,task)
    if not c or not record or not task or task.kind~='field' then return false end
    if not record.x or not record.z or not task.x or not task.z then return false end
    -- A successful field-edge staging point is authoritative even on very large fields:
    -- distance to the field CENTER may still exceed 180 m although the machine is exactly
    -- where it should be. Only stage again if it moved materially away from that point.
    if task.fieldStageCompleteVehicleKey==record.key and task.fieldStageTarget then
        if distanceSq(record,task.fieldStageTarget)<=60*60 then return false end
        task.fieldStageCompleteVehicleKey=nil;task.fieldStageTarget=nil
    end
    local radius=(c.settings and c.settings.fieldStageRadius) or 180
    return distanceSq(record,task) > radius*radius
end

local function fieldStageCandidates(c,task,record)
    local list={}
    if FMAFleetCoordinator and FMAFleetCoordinator.fieldWaitingCandidates then
        list=FMAFleetCoordinator.fieldWaitingCandidates(c,task,record) or {}
    end
    if #list==0 and task.x and task.z then list[1]={x=task.x,z=task.z,angle=0,label='pole'} end
    -- Do not put the main machine on top of an already staged unloader.
    local roles=c.preparedSupport and c.preparedSupport[task.id]
    for _,candidate in ipairs(list) do
        local occupied=false
        for _,role in pairs(roles or {}) do
            if role and role.target and distanceSq(candidate,role.target)<18*18 then occupied=true;break end
        end
        if not occupied then return candidate,list end
    end
    return list[1],list
end

function FMACourseplay.stageFieldwork(c,task,record)
    if not FMACourseplay.needsFieldStaging(c,record,task) then
        task.fieldStageAttempts=0;task.fieldStageCompleteVehicleKey=record.key
        return false,nil,'NEAR_FIELD'
    end
    local first,list=fieldStageCandidates(c,task,record)
    if not first then return false,'Nelze určit bezpečný nástupní bod u pole' end
    local maxAttempts=(c.settings and c.settings.fieldStageAttempts) or 5
    local attempt=math.max(1,math.min(task.fieldStageAttempts or 1,maxAttempts))
    local target=list[attempt] or first
    local job,why,method=FMAAI.createTransferJob(c,record,{x=target.x,z=target.z,angle=target.angle or 0,tolerance=10,probeRadius=20})
    if not job then
        -- CP state VEHICLE_IN_USE or a failed start gate is NOT a bad approach
        -- to the field. Give the engine time to release the cab before retrying.
        if why and (tostring(why):find('BUSY:',1,true) or tostring(why):find('obsazen',1,true)) then
            task.state='pending';task.phase='ČEKÁ NA UVOLNĚNÍ AI';task.reason=tostring(why)
            task.retryAt=(c.now or 0)+12000
            return true,why,'WAIT'
        end
        return false,why or 'Hlavní stroj neumí autonomní přejezd k poli'
    end
    local stage={id='fieldStage:'..task.id,kind='fieldStage',operation=task.operation,label='Přejezd hlavního stroje · '..task.label,parentTaskId=task.id,state='running',x=target.x,z=target.z,stageAttempt=attempt,stageCount=#list}
    task.state='preparing';task.phase='PŘEJEZD K POLI · FS25 AI';task.reason='Hlavní stroj jede na ověřený nástupní bod '..attempt..'/'..math.max(#list,1)
    c.reservations[record.key]=stage.id;record.busy=true
    c.active[job]={job=job,task=stage,vehicle=record,start=c.now,lastProgress=c.now,x=record.x,z=record.z,fill=record.fillTotal,trafficTarget=target,transferMethod=method}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,c.farmId)
    if not ok then c.active[job]=nil;c.reservations[record.key]=nil;record.busy=false;return false,tostring(err) end
    if FMADiagnostics then FMADiagnostics.event(c,'field.stageStart',task.id,(record.name or record.key)..' '..tostring(method)) end
    return true,nil,method
end

function FMACourseplay.onFieldStageStopped(c,active)
    local parent=c.tasks and c.tasks[active.task.parentTaskId]
    if not parent then return true end
    if active.stopReason then
        -- Do not rotate field entry points if the engine never accepted the job.
        if FMAJobs and FMAJobs.isNavigationEvidence and not FMAJobs.isNavigationEvidence(active,active.stopReason) then
            parent.state='pending';parent.phase='ČEKÁ NA UVOLNĚNÍ AI';parent.reason=tostring(active.stopReason)
            parent.retryAt=(c.now or 0)+12000
            return true
        end
        local maxAttempts=(c.settings and c.settings.fieldStageAttempts) or 5
        local nextAttempt=(active.task.stageAttempt or 1)+1
        parent.fieldStageAttempts=nextAttempt
        if nextAttempt<=maxAttempts then
            parent.state='pending';parent.phase='HLEDÁ JINÝ NÁSTUP K POLI';parent.reason='První příjezd nebyl sjízdný · zkouším jiný okraj pole';parent.retryAt=(c.now or 0)+1200
        else
            parent.state='blocked';parent.phase='BLOKACE PŘEJEZDU';parent.reason='Ani po '..tostring(maxAttempts)..' ověřených nástupních bodech se hlavní stroj nedostal k poli: '..tostring(active.stopReason)
            c:issue(parent.id,parent.label,parent.reason,99)
        end
    else
        parent.fieldStageAttempts=0;parent.fieldStageCompleteVehicleKey=active.vehicle.key;parent.fieldStageTarget=active.trafficTarget or {x=active.task.x,z=active.task.z}
        parent.state='pending';parent.phase='U POLE · PŘEDÁNÍ COURSEPLAY';parent.reason=nil;parent.retryAt=(c.now or 0)+500
        if FMADiagnostics then FMADiagnostics.event(c,'field.stageDone',parent.id,active.vehicle.name or active.vehicle.key) end
    end
    c.elapsed=(c.settings.scanSeconds or 12)*1000
    return true
end

function FMACourseplay.boundary(c,record,x,z)
    local v=record.object
    local px,pz=FMAUtil.call(v,'cpGetFieldPosition')
    if px==x and pz==z and FMAUtil.call(v,'cpGetFieldPolygon')~=nil and FMAUtil.call(v,'cpIsFieldBoundaryDetectionRunning')~=true then return true end
    if type(v.cpDetectFieldBoundary)~='function' then return false,'Chybí rozhraní hranice pole CP' end
    c.cpBoundary=c.cpBoundary or {}
    if c.cpBoundary[record.key] or FMAUtil.call(v,'cpIsFieldBoundaryDetectionRunning')==true then return false,'Čekám na hranici pole CP',true end
    local s={record=record,start=c.now,x=x,z=z,id='boundary:'..record.key}
    c.cpBoundary[record.key]=s;c.reservations[record.key]=s.id;record.busy=true
    local ok,err=pcall(v.cpDetectFieldBoundary,v,x,z,s,function(session,_,polygon)
        if c.cpBoundary[record.key]~=session then return end
        session.finished=true;session.ok=polygon~=nil
    end)
    if not ok then s.finished=true;s.ok=false;s.error=tostring(err) end
    return false,'Courseplay zjišťuje hranici pole',true
end

function FMACourseplay.update(c)
    for key,s in pairs(c.cpBoundary or {}) do
        if s.finished or c.now-s.start>120000 or not c.settings.enabled or (FMAGameNative and FMAGameNative.isManuallyControlled(s.record.object))==true then
            c.cpBoundary[key]=nil
            if c.reservations[key]==s.id then c.reservations[key]=nil end
            s.record.busy=false
            if not s.ok then FMAJobs.fail(c,{id=s.id,label='Hranice pole Courseplay'},s.record,s.error or 'Detekce hranice nebyla dokončena') end
        end
    end
end

local function run(c,record,job)
    job:setValues()
    local valid,why=job:validate(c.farmId)
    if valid~=true then return nil,tostring(why or 'Courseplay odmítl parametry') end
    if FMAUtil.call(record.object,'cpIsFieldBoundaryDetectionRunning')==true then return nil,'Courseplay ještě zjišťuje hranici',true end
    if job.getCanStartJob and not job:getCanStartJob() then return nil,'Courseplay není připraven ke startu' end
    local startable,state=job:getIsStartable(nil)
    if not startable then return nil,'Courseplay odmítl start: '..tostring(state) end
    FMAJobs.start(g_currentMission.aiSystem,job,c.farmId)
    return job
end

local function guarded(fn)
    local ok,job,why,waiting=xpcall(fn,FMADiagnostics.trace)
    if not ok then return nil,tostring(job) end
    return job,why,waiting
end

-- Start fieldwork through Courseplay's public external-mod interface instead of
-- stealing its internal job object and starting it through our own AI layer.
-- This mirrors CpAIFieldWorker:startCpAtFirstWp()/startCpAtLastWp(): Courseplay
-- owns applyCurrentState, validation and the network AIJobStartRequestEvent.
function FMACourseplay.startFieldwork(c,record,task)
    return guarded(function()
        local v=record and record.object
        if not v then return nil,'Chybí pracovní stroj' end
        if FMAUtil.call(v,'hasCpCourse')~=true then return nil,'Courseplay nemá připravený kurz' end
        local prepOk,prepWhy=nil,nil
        if FMAFieldQuality and FMAFieldQuality.prepareCourseplayVehicle then prepOk,prepWhy=FMAFieldQuality.prepareCourseplayVehicle(v,task,c) end
        if prepOk==false then return nil,prepWhy end
        if FMACourseplay.needsFieldStaging(c,record,task) then return nil,'Hlavní stroj je příliš daleko od pole; nejdřív musí dokončit nativní FS25 přejezd' end
        if v.updateAIFieldWorkerImplementData then v:updateAIFieldWorkerImplementData() end
        if FMAUtil.call(v,'getCanStartCpFieldWork')~=true then return nil,'Courseplay nepovolil polní práci této soupravy' end
        local spec=v.spec_cpAIFieldWorker
        local resume=task and task.resumeAtLast==true
        local job=spec and (resume and spec.cpJobStartAtLastWp or spec.cpJobStartAtFirstWp)
        local starter=resume and v.startCpAtLastWp or v.startCpAtFirstWp
        if not job or type(starter)~='function' then return nil,'Courseplay veřejné rozhraní pro start práce není dostupné' end
        local ok,started=pcall(starter,v)
        if not ok then return nil,'Courseplay start vyvolal chybu: '..tostring(started) end
        if started~=true then return nil,'Courseplay veřejný start odmítl pracovní job' end
        job.fmaManaged=true
        job.fmaCourseplayPublicStart=true
        if FMADiagnostics then FMADiagnostics.event(c,'cp.publicStart',task and task.id or '?',record.name or record.key) end
        return job
    end)
end

function FMACourseplay.confirmPendingFieldwork(c)
    for job,a in pairs(c.active or {}) do
        if a and a.startPendingNative==true then
            local v=a.vehicle and a.vehicle.object
            local liveJob=v and FMAUtil.call(v,'getJob') or nil
            local aiActive=v and FMAUtil.call(v,'getIsAIActive')==true
            local accepted=(liveJob==job) or (job.isRunning==true and aiActive)
            if accepted then
                a.startPendingNative=false
                a.lastProgress=c.now
                a.task.state='running';a.task.phase='PRÁCE · FS25 AI'
                a.task.reason=nil
                a.task.fieldworkStartedAt=c.now
                if FMAWorkEvidence then FMAWorkEvidence.begin(c,a.task,a.vehicle) end
                a.task.fieldworkStartFingerprint=a.task.fingerprint
                a.task.awaitingWorldVerification=false
                if FMADiagnostics then FMADiagnostics.event(c,'fs.fieldworkConfirmed',a.task.id,a.vehicle.name) end
            elseif (c.now or 0)-(a.start or 0)>8000 then
                a.startPendingNative=false
                a.stopReason='FS25 nepotvrdil převzetí pracovní zakázky do 8 s'
                if FMADiagnostics then FMADiagnostics.event(c,'fs.fieldworkStartTimeout',a.task.id,a.vehicle.name) end
                if job.isRunning then FMAAI.stop(job) else c:onJobStopped(job,nil) end
            end
        end
        if a and a.startPendingUnloader==true then
            local v=a.vehicle and a.vehicle.object
            if v and FMAUtil.call(v,'getIsCpCombineUnloaderActive')==true then
                a.startPendingUnloader=false
                a.task.phase='ODVOZCE · COURSEPLAY PŘEVZAL'
                a.task.reason='Odvozce je napojený na aktivní Courseplay strategii'
                a.lastProgress=c.now
                if FMADiagnostics then FMADiagnostics.event(c,'cp.unloaderConfirmed',a.task.id,a.vehicle.name) end
            elseif (c.now or 0)-(a.start or 0)>15000 then
                a.startPendingUnloader=false
                a.stopReason='Courseplay nepotvrdil aktivní odvozní strategii do 15 s'
                if FMADiagnostics then FMADiagnostics.event(c,'cp.unloaderStartTimeout',a.task.id,a.vehicle.name) end
                if job.isRunning then FMAAI.stop(job) else c:onJobStopped(job,nil) end
            end
        end
        if a and a.startPendingCp==true then
            local v=a.vehicle and a.vehicle.object
            local liveJob=v and FMAUtil.call(v,'getJob') or nil
            local active=v and FMAUtil.call(v,'getIsCpFieldWorkActive')==true
            if active and (liveJob==nil or liveJob==job) then
                a.startPendingCp=false
                a.lastProgress=c.now
                a.x,a.z=FMAUtil.position(v)
                a.task.state='running';a.task.phase='PRÁCE · COURSEPLAY';a.task.reason=nil
                a.task.fieldworkStartedAt=c.now
                if FMAWorkEvidence then FMAWorkEvidence.begin(c,a.task,a.vehicle) end
                a.task.fieldworkStartFingerprint=a.task.fingerprint
                a.task.awaitingWorldVerification=false
                if FMADiagnostics then FMADiagnostics.event(c,'cp.fieldworkConfirmed',a.task.id,a.vehicle.name) end
                if c.notify then c:notify(a.task.label..' · Courseplay převzal '..a.vehicle.name) end
            elseif (c.now or 0)-(a.start or 0)>8000 then
                a.startPendingCp=false
                a.stopReason='Courseplay nepotvrdil převzetí polní práce do 8 s'
                if FMADiagnostics then FMADiagnostics.event(c,'cp.fieldworkStartTimeout',a.task.id,a.vehicle.name) end
                if job.isRunning then FMAAI.stop(job) else c:onJobStopped(job,nil) end
            end
        end
    end
end

function FMACourseplay.startBunker(c,record,x,z,task)
    return guarded(function()
        local v=record and record.object
        if not v or FMAUtil.call(v,'getCanStartCpBunkerSiloWorker')~=true then
            return nil,'Souprava nepodporuje CP práci v jámě' end
        if FMAUtil.call(v,'getIsAIActive')==true then
            return nil,'Courseplay již na stroji pracuje',true end
        -- Courseplay 8.1.0.3 provides a persistent registered bunker job for
        -- each tractor. A new temporary job bypasses its public start lifecycle.
        local job=FMAUtil.call(v,'getCpBunkerSiloWorkerJob')
        if not job or type(v.startCpAtFirstWp)~='function' then
            return nil,'Courseplay nevrátil vlastní úlohu hutnění ani veřejný start stroje' end
        if type(job.cpJobParameters)~='table' or not job.cpJobParameters.siloPosition
            or not job.cpJobParameters.startPosition then
            return nil,'Courseplay postrádá parametry startu silážní jámy' end
        local b=task and c.bunkers and c.bunkers[task.bunkerIndex]
        if not b or not b.geometry or not b.geometry.center then
            return nil,'Chybí skutečná geometrie vlastní jámy' end
        local sx,sz=b.geometry.center.x,b.geometry.center.z
        if type(sx)~='number' or type(sz)~='number' then
            return nil,'Neplatná poloha jámy' end
        -- The CP position selector must reference the actual silo area, NOT
        -- its roof/root or a generated 14-m outside point.
        local p=job.cpJobParameters
        p.siloPosition:setPosition(sx,sz)
        local px,pz=FMAUtil.position(v)
        if not px or not pz then return nil,'Neznámá skutečná poloha hutnicího stroje' end
        -- Start at the actual tractor position: driving to an artificial marker
        -- behind a bunker wall creates goalNodeInvalid in GIANTS/CP.
        p.startPosition:setPosition(px,pz)
        if p.startPosition.setAngle and v.rootNode and localDirectionToWorld
            and MathUtil and MathUtil.getYRotationFromDirection then
            local ok,dx,_,dz=pcall(localDirectionToWorld,v.rootNode,0,0,1)
            if ok and dx and dz then p.startPosition:setAngle(MathUtil.getYRotationFromDirection(dx,dz)) end
        end
        if p.stopWithCompactedSilo then p.stopWithCompactedSilo:setValue(true) end
        if g_bunkerSiloManager and g_bunkerSiloManager.getBunkerSiloAtPosition then
            local valid,recognized=g_bunkerSiloManager:getBunkerSiloAtPosition(sx,sz)
            if not valid or not recognized then
                return nil,'Courseplay na souřadnicích středu jámy nepoznává silážní prostor' end
        end
        -- Start the real engine, never a simulated motor flag. CP's public
        -- start only ENQUEUES the network AI request, it does not prove that
        -- the worker or motor took over. The watchdog verifies that separately.
        if FMAUtil.call(v,'getIsMotorStarted')~=true and type(v.startMotor)=='function'
            and (FMAUtil.call(v,'getCanMotorRun')~=false)
            and not (FMAGameNative and FMAGameNative.isManuallyControlled and FMAGameNative.isManuallyControlled(v)) then
            local motorOk,motorWhy=pcall(v.startMotor,v)
            if not motorOk then
                if FMADiagnostics then FMADiagnostics.event(c,'bunker.motorStartFailure',record.name or '?',tostring(motorWhy)) end
                return nil,'Nepodařilo se nastartovat motor pro hutnění: '..tostring(motorWhy)
            end
            if FMADiagnostics then FMADiagnostics.event(c,'bunker.motorRequested',record.name or '?','GIANTS startMotor') end
        end
        -- A shared startCpAtFirstWp() entry point is overwritten by SEVERAL CP
        -- specializations (fieldwork, unloader, bunker). It can return true for
        -- an entirely different job. Verify the job selected by CP itself first.
        -- A request for another job is not a physical bunker worker.
        if type(v.getCpStartableJob)=='function' then
            local okSelected,selected=pcall(v.getCpStartableJob,v,false)
            if not okSelected or selected~=job then
                if FMADiagnostics then FMADiagnostics.event(c,'bunker.cpWrongJob',record.name or '?',tostring(selected)) end
                return nil,'Courseplay vybral jinou úlohu než hutnění; zabraňuji falešnému startu'
            end
        end
        -- CP dispatch is asynchronous: return true only means requested.
        local ok,started=pcall(v.startCpAtFirstWp,v)
        if not ok or started~=true then
            return nil,'Courseplay zamítl veřejný start hutnění: '..tostring(started) end
        job.fmaManaged=true;job.fmaCourseplayPublicStart=true
        if FMADiagnostics then FMADiagnostics.event(c,'bunker.cpRequestSent',tostring(task.bunkerIndex),record.name or record.key) end
        return job
    end)
end

function FMACourseplay.startBales(c,record,x,z)
    return guarded(function()
        local v=record.object
        if FMAUtil.call(v,'getCanStartCpBaleFinder')~=true then return nil,'Souprava nepodporuje CP balíky' end
        if not FMAJobs.mayStart(c,'boundary:'..record.key) then return nil,'Detekce hranice čeká po chybě' end
        local ready,why,waiting=FMACourseplay.boundary(c,record,x,z)
        if not ready then return nil,why,waiting end
        local job=FMAJobs.create('BALE_FINDER_CP')
        job:applyCurrentState(v,g_currentMission,c.farmId,false)
        job.cpJobParameters.fieldPosition:setPosition(x,z)
        job.cpJobParameters.startPosition:setPosition(x,z)
        return run(c,record,job)
    end)
end

function FMACourseplay.startCombineUnloader(c,record,task,station,forageBunker)
    return guarded(function()
        local v=record.object
        if FMAUtil.call(v,'getCanStartCpCombineUnloader')~=true then return nil,'Souprava nepodporuje CP odvoz' end
        if not station and not forageBunker then return nil,'Odvoz nemá ověřený vykládací cíl' end
        if not FMAJobs.mayStart(c,'boundary:'..record.key) then return nil,'Detekce hranice čeká po chybě' end
        local ready,why,waiting=FMACourseplay.boundary(c,record,task.x,task.z)
        if not ready then return nil,why,waiting end
        -- CpAICombineUnloader owns a registered, vehicle-bound cpJob. A newly
        -- fabricated job can validate yet miss the vehicle-side CP start lifecycle.
        -- Use precisely the same public entry point as the user's H/CP command.
        local job=FMAUtil.call(v,'getCpCombineUnloaderJob') or
            (v.spec_cpAICombineUnloader and v.spec_cpAICombineUnloader.cpJob)
        if not job or type(v.startCpAtFirstWp)~='function' then
            return nil,'Courseplay nemá veřejný start odvozce na soupravě' end
        if FMAUtil.call(v,'getIsAIActive')==true then
            return nil,'Courseplay čeká na uvolnění předchozího pracovníka',true end
        job:applyCurrentState(v,g_currentMission,c.farmId,false,false)
        local p=job.cpJobParameters
        p.fieldPosition:setPosition(task.x,task.z)
        local vx,vz=FMAUtil.position(v)
        if not vx then return nil,'Nelze ověřit polohu odvozní soupravy pro Courseplay' end
        p.startPosition:setPosition(vx,vz)
        if p.startPosition.setAngle and v.rootNode and localDirectionToWorld and MathUtil and MathUtil.getYRotationFromDirection then
            local okDir,dx,_,dz=pcall(localDirectionToWorld,v.rootNode,0,0,1)
            if okDir and dx and dz then p.startPosition:setAngle(MathUtil.getYRotationFromDirection(dx,dz)) end
        end
        p.useFieldUnload:setValue(false);p.useGiantsUnload:setValue(not forageBunker)
        if forageBunker then
            local ok,started=pcall(v.startCpAtFirstWp,v)
            if not ok or started~=true then return nil,'Courseplay odmítl veřejný start odvozce: '..tostring(started) end
            job.fmaManaged=true;job.fmaCourseplayPublicStart=true
            return job
        end
        local id=NetworkUtil and NetworkUtil.getObjectId(station)
        if not id or not p.unloadingStation or not p.unloadingStation.setValue then return nil,'CP nedokáže zvolit vykládací stanici' end
        p.unloadingStation:setValue(id)
        if p.unloadingStation:getUnloadingStation()~=station then return nil,'CP nezahrnul cílovou stanici do dostupných voleb' end
        local ok,started=pcall(v.startCpAtFirstWp,v)
        if not ok or started~=true then return nil,'Courseplay odmítl veřejný start odvozce: '..tostring(started) end
        job.fmaManaged=true;job.fmaCourseplayPublicStart=true
        if FMADiagnostics then FMADiagnostics.event(c,'cp.unloaderPublicStart',record.key,tostring(task.x)..','..tostring(task.z)) end
        return job
    end)
end
