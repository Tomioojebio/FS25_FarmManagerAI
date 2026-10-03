-- All native jobs must be created by the GIANTS factory. Direct .new() omits
-- jobTypeIndex and leaves AIJobVehicle.lastJob impossible to serialize.
FMAJobs = {}

function FMAJobs.create(name)
    local manager=g_currentMission and g_currentMission.aiJobTypeManager
    assert(manager and manager.createJob and manager.getJobTypeIndexByName,"Chybí registr typů AI úloh")
    local index=manager:getJobTypeIndexByName(name)
    assert(index~=nil,"Hra nemá registrovanou AI úlohu "..tostring(name))
    local job=manager:createJob(index)
    assert(job and job.jobTypeIndex==index,"AI úloha nemá platný registrovaný typ "..tostring(name))
    job.fmaManaged=true
    return job
end

function FMAJobs.ensureType(job)
    local manager=g_currentMission and g_currentMission.aiJobTypeManager
    if not manager or not job then return false,"Chybí registr / AI úloha" end
    -- Serialization resolves the class, not just the cached numeric index.
    local index=FMAUtil.call(manager,"getJobTypeIndex",job)
    local entry=index and FMAUtil.call(manager,"getJobTypeByIndex",index)
    if not entry or not entry.name then return false,"Neznámá třída AI úlohy; start odmítnut kvůli ukládání" end
    job.jobTypeIndex=index
    return true,entry.name
end

-- A refusal before any path calculation is not a map or navigation failure.
-- CpAIJob:getIsStartable distinguishes NO_PERMISSION/VEHICLE_IN_USE;
-- the older dispatcher incorrectly treated all such refusals as bad roads.
function FMAJobs.startRejection(vehicle,engine,state)
    local occupied=vehicle and FMAUtil.call(vehicle,'getIsInUse')==true
    local ai=vehicle and FMAUtil.call(vehicle,'getIsAIActive')==true
    local entered=vehicle and FMAGameNative and FMAGameNative.operatorState(vehicle).manual==true
    if occupied or ai or entered then
        return 'BUSY','Stroj je obsazený / AI dosud neuvolnila řízení (start='..tostring(state)..')'
    end
    if state~=nil and AIJobFieldWork then
        if state==AIJobFieldWork.START_ERROR_NO_PERMISSION then return 'PERMISSION','Chybí oprávnění najímat pracovníka' end
        if state==AIJobFieldWork.START_ERROR_VEHICLE_IN_USE then return 'BUSY','Stroj je blokovaný jako právě používaný' end
    end
    return 'START','Rozhraní '..tostring(engine)..' odmítlo start (stav '..tostring(state)..')'
end
function FMAJobs.isNavigationEvidence(a,reason)
    if not a or a.dispatchRejected==true then return false end
    local s=string.lower(tostring(reason or ''))
    for _,word in ipairs({'start=', 'stav 4', 'převzetí', 'nepotvrd', 'obsazen', 'oprávněn', 'vehicle in use', 'permission', 'start rejected', 'úloha není'}) do
        if string.find(s,word,1,true) then return false end
    end
    -- No physical movement + generic cancellation is not proof of a wall.
    return a.physicalMotionVerified==true or string.find(s,'cíl není dosažiteln',1,true)~=nil or string.find(s,'brání objekt',1,true)~=nil
end

function FMAJobs.start(aiSystem,job,farmId)
    local valid,why=FMAJobs.ensureType(job)
    assert(valid,why)
    local vehicle=FMAUtil.call(job,"getVehicle") or FMAUtil.call(job.vehicleParameter,"getVehicle")
    assert(vehicle and FMAUtil.owner(vehicle)==farmId,"Vozidlo AI není ověřeným majetkem farmy")
    assert(not (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle)),"Stroj převzal hráč")
    assert(FMAUtil.call(vehicle,"getIsAIActive")~=true,"Stroj už řídí jiný pracovník")
    assert(not FMACompatibility.inspect(vehicle).externalBusy,"Stroj řídí jiný mód")
    local c=FMAJobs.controller
    if c then
        assert(c.settings.enabled and not c.shuttingDown,"Manager je pozastavený")
        local money=FMAWorld.money(farmId)
        assert(money and money>=c.settings.reserve,"Není ověřena finanční rezerva")
    end
    if c then
        assert(FMALifecycle.allowed(c,{object=vehicle,key=FMAWorld.vehicleKey(vehicle)},false),"Změna řízení soupravy")
        if FMAControlAuthority then
            local allowed,reason=FMAControlAuthority.canLaunch(c,vehicle,job)
            assert(allowed,reason)
        end
    end
    job.fmaManaged=true
    local started,why=aiSystem:startJob(job,farmId)
    -- The GIANTS API may return nil for a normal asynchronous start. An explicit
    -- FALSE, however, is a rejected request, not a successfully sent worker.
    if started==false then error('FS25 odmítlo požadavek na spuštění AI: '..tostring(why)) end
    if c then
        local active=c.active and c.active[job]
        if active and job.fmaRoutePlan then
            active.learnedRoutePlan=job.fmaRoutePlan
            active.routeLegIndex=job.fmaRoutePlan.index
            active.trafficTarget=job.fmaLegTarget
        end
        local task=(active and active.task) or c.startingTask
        local record=(active and active.vehicle) or c.startingVehicle or {object=vehicle,key=FMAWorld.vehicleKey(vehicle),name=FMAUtil.name(vehicle)}
        if FMATraffic and FMATraffic.markStarted then FMATraffic.markStarted(c,record,task) end
        FMADiagnostics.event(c,'job.requestSent',tostring(job.jobTypeIndex),FMAUtil.name(vehicle))
    end
end

-- A request accepted by a Lua method does not prove the GIANTS helper took over.
-- Check auxiliary jobs and physical return legs after the engine update, not in the same frame as startJob().
-- Otherwise the dispatcher can tell the user that a tractor is moving while it has
-- never actually started a worker, leaving a permanent phantom reservation.
function FMAJobs.verifyAuxiliaryStarts(c)
    for job,a in pairs(c.active or {}) do
        local kind=a and a.task and a.task.kind
        local isTravel=a and (a.trafficTarget~=nil or a.transferMethod~=nil or
            kind=='assemble' or kind=='fieldStage' or kind=='return')
        local isBunker=kind=='bunker' and a and a.task and a.task.operation=='compact'
        if isBunker and not a.stopReason then
            local v=a.vehicle and a.vehicle.object
            local elapsed=(c.now or 0)-(a.start or 0)
            local x,z=nil,nil
            if v then x,z=FMAUtil.position(v) end
            if x and z then
                a.startX=a.startX or x;a.startZ=a.startZ or z
                if (x-a.startX)^2+(z-a.startZ)^2>=2.25*2.25 then
                    if not a.physicalMotionVerified and FMADiagnostics then
                        FMADiagnostics.event(c,'bunker.motionConfirmed',a.task.id,a.vehicle.name)
                    end
                    a.physicalMotionVerified=true
                end
            end
            local aiActive=v and FMAUtil.call(v,'getIsAIActive')==true
            local liveJob=v and FMAUtil.call(v,'getJob')
            local cpActive=v and (FMAUtil.call(v,'getIsCpActive')==true
                or (v.spec_cpAIWorker and v.spec_cpAIWorker.isActive==true))
            -- getJob() is the actual GIANTS AI job. Do not count a CP RPC as acceptance.
            if not a.dispatchVerified then
                if (aiActive and liveJob==job) or (aiActive and job.isRunning==true) then
                    a.dispatchVerified=true
                    a.task.state='running'
                    a.task.phase='HUTNĚNÍ · AI OPRAVDU PŘEVZALA TRAKTOR'
                    if a.task.parentTask then
                        a.task.parentTask.state='running'
                        a.task.parentTask.phase='HUTNĚNÍ · GIANTS / COURSEPLAY'
                    end
                    if FMADiagnostics then FMADiagnostics.event(c,'bunker.aiConfirmed',a.task.id,a.vehicle.name) end
                elseif elapsed>10000 then
                    a.dispatchRejected=true;a.dispatchVerified=true
                    a.stopReason='Courseplay pouze odeslal start · GIANTS do 10 s nepotvrdilo převzetí AI (motor='..tostring(FMAUtil.call(v,'getIsMotorStarted'))..', cp='..tostring(cpActive)..')'
                    if FMADiagnostics then FMADiagnostics.event(c,'bunker.aiStartRejected',a.task.id,a.stopReason) end
                    if job.isRunning then FMAAI.stop(job) else c:onJobStopped(job,nil) end
                end
            elseif not a.physicalMotionVerified and elapsed>35000 then
                local bunker=c.bunkers and c.bunkers[a.task.bunkerIndex]
                local compact=bunker and (bunker.object and bunker.object.compactedPercent or bunker.compactedPercent)
                if compact and compact>(a.startCompaction or compact)+0.15 then
                    a.physicalMotionVerified=true
                else
                    a.stopReason='AI hutnění sice převzala, ale traktor za 35 s fyzicky nepopojel ani nezvýšil zhutnění'
                    if FMADiagnostics then FMADiagnostics.event(c,'bunker.stalled',a.task.id,a.stopReason) end
                    if job.isRunning then FMAAI.stop(job) else c:onJobStopped(job,nil) end
                end
            end
            if FMADiagnostics and not a.bunkerMotorSnapshot and elapsed>3500 then
                a.bunkerMotorSnapshot=true
                FMADiagnostics.event(c,'bunker.motorObserved',a.task.id,
                    'started='..tostring(FMAUtil.call(v,'getIsMotorStarted'))..' ai='..tostring(aiActive)..' cp='..tostring(cpActive))
            end
        end
        if isTravel and not a.stopReason then
            local v=a.vehicle and a.vehicle.object
            local elapsed=(c.now or 0)-(a.start or 0)
            local x,z=nil,nil
            if v then x,z=FMAUtil.position(v) end
            if x and z then
                -- A permanent anchor is needed: the usual watchdog changes a.x/a.z
                -- while sampling progress, which would otherwise erase movement proof.
                a.startX=a.startX or x
                a.startZ=a.startZ or z
                local travel2=(x-a.startX)^2+(z-a.startZ)^2
                if travel2>=2.25*2.25 then
                    if not a.physicalMotionVerified then
                        a.physicalMotionVerified=true
                        if FMADiagnostics then FMADiagnostics.event(c,'transfer.motionConfirmed',
                            a.task and a.task.id or '?',a.vehicle and a.vehicle.name or '?') end
                    end
                end
            end
            if not a.dispatchVerified then
                local liveJob=v and FMAUtil.call(v,'getJob')
                local aiActive=v and FMAUtil.call(v,'getIsAIActive')==true
                if liveJob==job or (job.isRunning==true and aiActive) then
                    a.dispatchVerified=true
                    if FMADiagnostics then FMADiagnostics.event(c,'job.engineAccepted',
                        a.task and a.task.id or '?',a.vehicle and a.vehicle.name or '?') end
                elseif elapsed>12000 then
                    a.dispatchVerified=true -- verification completed; outcome was REJECTED, not accepted
                    a.dispatchRejected=true
                    a.stopReason='FS25 nepotvrdilo převzetí pomocného přejezdu do 12 s'
                    if FMADiagnostics then FMADiagnostics.event(c,'job.startRejected',
                        a.task and a.task.id or '?',a.vehicle and a.vehicle.name or '?') end
                    if job.isRunning then FMAAI.stop(job) else c:onJobStopped(job,nil) end
                end
            end
            -- A worker visibly in the cab can be running the engine job while
            -- never moving an inch. Mark this as a stalled START, not successful work.
            if a.dispatchVerified and not a.physicalMotionVerified and elapsed>23000
                    and not a.stopReason then
                local goal=a.trafficTarget
                local atTarget=goal and x and goal.x and goal.z and
                    (x-goal.x)^2+(z-goal.z)^2<=4*4
                if not atTarget then
                    a.stopReason='AI převzala stroj, ale ten se do 23 s nerozjel; opraví se nájezd nebo se zvolí jiná souprava'
                    if FMADiagnostics then FMADiagnostics.event(c,'transfer.noPhysicalMovement',
                        a.task and a.task.id or '?',a.vehicle and a.vehicle.name or '?') end
                    if job.isRunning then FMAAI.stop(job) else c:onJobStopped(job,nil) end
                end
            end
        end
    end
end

local function isMessage(message,class)
    return class~=nil and message~=nil and FMAUtil.call(message,"isa",class)==true
end

function FMAJobs.outcome(message)
    if isMessage(message,AIMessageSuccessFinishedJob) then return "success" end
    if isMessage(message,AIMessageSuccessStoppedByUser) then return "cancelled" end
    if isMessage(message,AIMessageErrorIsFull) then return "full" end
    if message==nil then return "unknown" end
    return "error"
end

function FMAJobs.message(message)
    return tostring(FMAUtil.call(message,"getMessage") or (message and message.name) or "AI skončila bez potvrzení výsledku")
end

function FMAJobs.mayStart(c,id)
    local failure=c.jobFailures and c.jobFailures[id]
    if not failure then return true end
    return not failure.blocked and (c.now or 0)>=failure.retryAt
end

function FMAJobs.fail(c,task,record,reason)
    if not task then return end
    c.diagnosticDirty=true
    c.desktopSnapshotDue=math.min(c.desktopSnapshotDue or math.huge,(c.now or 0)+1000)
    c.jobFailures=c.jobFailures or {}
    local failure=c.jobFailures[task.id] or {count=0}
    failure.count=failure.count+1;failure.reason=tostring(reason)
    if FMAExperience and FMAExperience.note then FMAExperience.note(c,task,record,false,reason) end
    failure.retryAt=(c.now or 0)+math.min(300000,30000*2^(failure.count-1))
    failure.blocked=failure.count>=(c.settings.maxAttempts or 3)
    failure.label=task.label;failure.vehicleKey=record and record.key
    c.jobFailures[task.id]=failure
    if FMARecovery and FMARecovery.noteFailure and FMARecovery.noteFailure(c,task,record,failure.reason,failure) then
        if FMADiagnostics then FMADiagnostics.event(c,"job.failed.recoverable",task.id,failure.reason) end
        return
    end
    task.state="blocked";task.reason=failure.reason;task.retryAt=failure.retryAt
    local failureClass,advice=FMAExperience.advice(failure.reason)
    failure.category=failureClass;failure.advice=advice
    task.phase='BLOKACE / '..failureClass
    c:issue(task.id,task.label,failure.reason..' | '..advice,task.priority or 95)
    if FMADiagnostics then FMADiagnostics.event(c,"job.failed",task.id,failure.reason) end
end

function FMAJobs.stopMotor(record)
    local v=record and record.object
    if v and not (FMAGameNative and FMAGameNative.isManuallyControlled(v)) and FMAUtil.call(v,"getIsAIActive")~=true and v.stopMotor then
        v:stopMotor()
    end
end

function FMAJobs.repairLastJobs(c)
    -- Repair only known native job classes, never delete another mod's job.
    for _,v in ipairs(c.vehicles or {}) do
        local spec=v.object.spec_aiJobVehicle
        local job=spec and spec.lastJob
        if job and job.jobTypeIndex==nil then
            local ok,why=FMAJobs.ensureType(job)
            if ok then FMADiagnostics.event(c,"save.repair",v.key,why)
            else c:issue("save:"..v.key,v.name.." · neplatná poslední AI úloha",why,100) end
        end
    end
end
