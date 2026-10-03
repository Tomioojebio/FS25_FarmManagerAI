-- Progressive recovery and automatic fail-over. Never teleports or force-attaches a vehicle.
FMARecovery={VERSION='0.20.16.0'}

local recoverableKinds={assemble=true,unloaderAssemble=true,supportStage=true,route=true,["return"]=true,refill=true,headerTransport=true,baleDelivery=true,forageDelivery=true,livestockMixDrive=true,livestockFeedDeliver=true,bunkerApproach=true,bunkerDelivery=true}

function FMARecovery.isRecoverable(active)
    return active and active.task and recoverableKinds[active.task.kind]==true
end


function FMARecovery.hasAlternative(c,task,record)
    if not c or not task then return false end
    local probe={}
    for k,v in pairs(task) do probe[k]=v end
    probe.failedVehicleKeys={}
    for k,v in pairs(task.failedVehicleKeys or {}) do probe.failedVehicleKeys[k]=v end
    if record and record.key then probe.failedVehicleKeys[record.key]=true end
    for _,candidate in ipairs(c.vehicles or {}) do
        if not (record and candidate.key==record.key) and not candidate.busy then
            local ok=FMAPlanner and FMAPlanner.vehicleMatches and FMAPlanner.vehicleMatches(probe,candidate,c.reservations or {},c.excluded or {})
            if ok==true then return true end
        end
    end
    return false
end

-- Machines can be pre-hitched when the savegame is opened. We may adopt exactly
-- ONE physically connected tool only if its stable per-tool parking position
-- was previously learned; never infer a parking bay from a random yard spot.
function FMARecovery.findKnownAttachment(c,task,record)
    if not c or not record or not record.object or not (record.capabilities or {})[task.operation] then return nil end
    local attached={}
    for _,object in ipairs(FMAWorld.operationalChildren(record.object)) do
        if object~=record.object and FMAUtil.call(object,'getAttacherVehicle')==record.object then
            attached[#attached+1]=object
        end
    end
    if #attached~=1 then return nil end
    local object=attached[1]
    local key=FMAWorld.vehicleKey(object)
    local home=c.toolHomes and c.toolHomes[key]
    if not home or not home.x or not home.z or FMAUtil.owner(object)~=c.farmId then return nil end
    if task.preferredImplementKey and task.preferredImplementKey~=key then return nil end
    -- A previously attached rear weight, drawbar or transport trailer is not
    -- automatically the plough/seeder simply because it is the only child.
    -- Validate the REAL tool's FS25 specialization as in regular assembly.
    local profile=FMAWorld.toolProfile and FMAWorld.toolProfile(object)
    if not profile or not FMAAssembler or not FMAAssembler.toolSupports(task,profile) then return nil end
    return {toolKey=key,toolName=FMAUtil.name(object),toolObject=object,
        powerKey=record.key,toolHome=home}
end

function FMARecovery.noteFailure(c,task,record,reason,failure)
    if not c or not task or not c.settings or not c.settings.recoveryEnabled then return false end
    -- Only the main fieldwork dispatcher is allowed to swap the main machine.
    -- Assembly, fill, haulage, return, and livestock have specialist state machines.
    if task.kind~='field' or not task.operation or not record or not record.key then return false end
    local category,transient=FMAExperience.classify(reason)
    if not transient then return false end
    local maxCycles=math.max(0,math.min(8,c.settings.maxRecoveryCycles or 3))
    if (task.recoveryCount or 0)>=maxCycles then return false end
    if task.ownerPinnedVehicle==true or task.ownerPinnedImplement==true then return false end
    -- Before considering another tractor, physically return any tool that OUR
    -- assembler attached to the failed one. Never release its reservation or
    -- requeue the field order while it is still on the first tractor.
    local attachment=task.managedAttachment
    if not attachment then
        attachment=FMARecovery.findKnownAttachment(c,task,record)
        if attachment then
            task.managedAttachment=attachment
            if FMADiagnostics then FMADiagnostics.event(c,'handover.adoptKnownTool',task.id,attachment.toolKey) end
        end
    end
    if attachment and attachment.powerKey==record.key and attachment.toolObject
        and FMAReturnManager and FMAReturnManager.isAttachedToVehicle(record.object,attachment) then
        local started,why=FMAReturnManager.beginRecovery(c,task,record,reason)
        if started then
            if failure then failure.blocked=false;failure.retryAt=math.huge end
            task.recoveryCount=(task.recoveryCount or 0)+1
            return true
        end
        -- A transfer is not permission to abandon an attached implement.
        task.state='blocked';task.phase='BLOKACE / VÝMĚNA SOUPRAVY'
        task.reason='Nářadí stále visí na původním traktoru: '..tostring(why)
        c:issue('recovery:'..task.id,task.label,task.reason,99)
        if failure then failure.blocked=true end
        return true
    end
    -- A pre-existing / manually attached implement has no managed bay/lease.
    -- We must not assign its tractor or attached tool elsewhere blindly.
    if record.object and FMAWorld and FMAWorld.children then
        for _,tool in ipairs(FMAWorld.children(record.object)) do
            if FMAUtil.call(tool,'getAttacherVehicle')==record.object and tool~=record.object then
                task.state='blocked';task.phase='BLOKACE / NEŘÍZENÉ NÁŘADÍ'
                task.reason='Na traktoru zůstává nářadí mimo evidenci automatického zapřahání. Nauč jeho stání, nebo ho bezpečně odpoj.'
                if failure then failure.blocked=true end
                c:issue('recovery:'..task.id,task.label,task.reason,99)
                return true
            end
        end
    end
    local alternative=FMARecovery.hasAlternative(c,task,record)
    if not alternative then
        local retries=task.sameVehicleRetryCount or 0
        if retries>=1 or category~='ROUTE' and category~='TRAFFIC' and category~='START' then return false end
        task.sameVehicleRetryCount=retries+1
        task.recoveryCount=(task.recoveryCount or 0)+1
        task.state='pending';task.phase='OBNOVA / DRUHÝ POKUS'
        task.reason='Jiná vhodná souprava není volná · po prodlevě jeden kontrolovaný pokus: '..tostring(reason)
        task.retryAt=(c.now or 0)+30000
        if failure then failure.blocked=false;failure.retryAt=task.retryAt end
        c:issue('recovery:'..task.id,task.label..' · omezený opakovaný pokus',task.reason,78)
        if FMADiagnostics then FMADiagnostics.event(c,'recovery.retryOnce',task.id,reason) end
        return true
    end
    task.recoveryCount=(task.recoveryCount or 0)+1
    task.failedVehicleKeys=task.failedVehicleKeys or {}
    task.failedVehicleKeys[record.key]=true
    if task.preferredVehicleKey==record.key then task.preferredVehicleKey=nil;task.preferredVehicleName=nil end
    task.state='pending';task.phase='OBNOVA / NÁHRADNÍ STROJ'
    task.reason='Selhalo '..tostring(record.name or record.key)..' ('..category..') · zkouším jinou dostupnou soupravu: '..tostring(reason)
    task.retryAt=(c.now or 0)+math.min(45000,5000*task.recoveryCount)
    if failure then failure.blocked=false;failure.retryAt=task.retryAt end
    c:issue('recovery:'..task.id,task.label..' · alternativní souprava',task.reason,88)
    if FMADiagnostics then FMADiagnostics.event(c,'recovery.failover',task.id,tostring(record.name or record.key)..' | '..tostring(reason)) end
    return true
end

-- Invoked only AFTER live FS25 confirmed that the implement is detached near
-- its bay AND the old tractor physically reached its own parking place.
function FMARecovery.handoverCompleted(c,parent,record,returnTask)
    if not parent or not record then return end
    local tool=returnTask and returnTask.attachment
    parent.failedVehicleKeys=parent.failedVehicleKeys or {}
    parent.failedVehicleKeys[record.key]=true
    if parent.preferredVehicleKey==record.key then parent.preferredVehicleKey=nil;parent.preferredVehicleName=nil end
    if tool and tool.toolKey then
        parent.preferredImplementKey=tool.toolKey
        parent.preferredImplementName=tool.toolName
    end
    parent.managedAttachment=nil
    parent.forceHandoverImplement=true
    parent.assemblyAttempt=1
    parent.stagingCandidateCursor=1
    parent.retryAt=(c.now or 0)+3500
    parent.state='pending';parent.phase='VÝMĚNA · DRUHÝ VOLNÝ TRAKTOR'
    parent.reason='Nářadí vráceno · první traktor zaparkoval · hledám jiný kompatibilní traktor'
    if c.jobFailures then
        local f=c.jobFailures[parent.id]
        if f then f.blocked=false;f.retryAt=parent.retryAt end
    end
    if FMAExperience and FMAExperience.handover then FMAExperience.handover(c,parent,record.key,true,'Fyzicky potvrzené vrácení') end
    if FMADiagnostics then FMADiagnostics.event(c,'handover.complete',parent.id,record.key..' => '..tostring(parent.preferredImplementKey)) end
    c:notify(parent.label..' · první tahač zaparkoval, předávám nářadí druhému')
end

-- Restart recovery. A saved journal is NOT proof of a completed move: recheck
-- the two real objects and both bays against the live world before resuming.
-- A blocked checkpoint is deliberately not driven again until its physical
-- state has been corrected (or the owner resolves the obstruction).
function FMARecovery.restoreJournal(c)
    if not c.handoverJournal then return end
    for id,row in pairs(c.handoverJournal) do
        local parent=c.tasks and c.tasks[id]
        if not parent then
            parent={id=id,kind='field',operation=row.operation,label='Obnova předání nářadí',state='handover',priority=94}
            c.tasks[id]=parent
        end
        local alreadyRunning=c.pendingHandovers and c.pendingHandovers[id]~=nil or false
        for _,a in pairs(c.active or {}) do
            if a.task and a.task.purpose=='handover' and a.task.parentTaskId==id then alreadyRunning=true;break end
        end
        for _,s in pairs(c.pendingDetaches or {}) do
            if s.task and s.task.purpose=='handover' and s.task.parentTaskId==id then alreadyRunning=true;break end
        end
        for _,s in pairs(c.deferred or {}) do
            if s.parent and s.parent.id==id and s.record and s.record.key==row.vehicle then alreadyRunning=true;break end
        end
        if not alreadyRunning then
            c.handoverLeases=c.handoverLeases or {}
            c.handoverLeases[row.tool]=id
            local record=c.vehicleByKey and c.vehicleByKey[row.vehicle]
            local toolObject=FMAWorld and FMAWorld.resolveVehicle and FMAWorld.resolveVehicle(row.tool)
            local toolHome=c.toolHomes and c.toolHomes[row.tool]
            local home=c.homePositions and c.homePositions[row.vehicle]
            local reason=nil
            if not record or not toolObject then reason='Původní traktor nebo nářadí není v živém registru FS25'
            elseif not toolHome or not home then reason='Chybí uložené fyzické stanoviště nářadí nebo traktoru'
            elseif FMAUtil.owner(toolObject)~=c.farmId then reason='Nářadí změnilo vlastníka'
            end
            if not reason then
                local attachment={toolKey=row.tool,toolName=FMAUtil.name(toolObject),toolObject=toolObject,
                    powerKey=row.vehicle,toolHome=toolHome}
                parent.managedAttachment=attachment
                local attacher=FMAUtil.call(toolObject,'getAttacherVehicle')
                local onOriginal=FMAReturnManager.isAttachedToVehicle(record.object,attachment)
                local tx,tz=FMAUtil.position(toolObject)
                local vx,vz=FMAUtil.position(record.object)
                local tolerance=math.max(4,math.min(12,c.settings.parkTolerance or 8))
                local toolAtHome=not attacher and tx and ((tx-toolHome.x)^2+(tz-toolHome.z)^2)<=tolerance*tolerance
                local tractorAtHome=vx and ((vx-home.x)^2+(vz-home.z)^2)<=tolerance*tolerance
                if toolAtHome and tractorAtHome then
                    FMAReturnManager.handoverCompleted(c,{parentTask=parent,attachment=attachment},record)
                elseif row.stage=='blocked' then
                    reason='Předchozí předání bylo zablokováno: '..tostring(row.reason or '')
                elseif not c.settings.enabled then
                    parent.state='handover';parent.phase='OBNOVA ČEKÁ NA ZAPNUTÍ'
                elseif FMAGameNative and FMAGameNative.isManuallyControlled(record.object) then
                    parent.state='handover';parent.phase='OBNOVA ČEKÁ NA MAJITELE'
                elseif attacher and not onOriginal then
                    reason='Nářadí má jiný tahač než uložené předání'
                elseif onOriginal then
                    local started,why=FMAReturnManager.beginRecovery(c,parent,record,row.reason)
                    if not started then reason='Předání po načtení nelze obnovit: '..tostring(why) end
                elseif toolAtHome then
                    local transfer={id='handover:'..tostring(id)..':'..row.vehicle,kind='return',purpose='handover',
                        parentTask=parent,parentTaskId=id,operation=parent.operation,
                        label='Doparkování po načtení',originalKey=row.vehicle,
                        attachment=attachment,home=home,priority=parent.priority,state='pending'}
                    c.handoverJournal[id].stage='detached'
                    parent.state='handover';parent.phase='OBNOVA · DOPARKOVÁNÍ TRAKTORU'
                    local started,why=FMAReturnManager.startDrive(c,record,home,transfer,'vehicleHome')
                    if not started then reason='Doparkování po načtení nelze zahájit: '..tostring(why) end
                else reason='Nářadí není připojené ani bezpečně odložené na svém místě' end
            end
            if reason then
                parent.state='blocked';parent.phase='BLOKACE / OBNOVA PŘEDÁNÍ';parent.reason=reason
                if row.stage~='blocked' then row.stage='blocked';row.reason=reason end
                c:issue('handover:'..id,'Nedokončené předání po načtení',reason,99)
            end
        end
    end
end

function FMARecovery.onStopped(c,active)
    if not active or (active.stopReason~='RECOVERY_REROUTE' and active.stopReason~='NAV_REVERSE') then return false end
    local task=active.task
    if active.stopReason=='NAV_REVERSE' then
        local started,why=false,'Navigace pro úhybný manévr není k dispozici'
        if FMANavigation and FMANavigation.beginEscape then started,why=FMANavigation.beginEscape(c,active) end
        if started then return true end
        if FMADiagnostics then FMADiagnostics.event(c,'navigation.reverseUnavailable',task and task.id or '?',tostring(why)) end
        active.stopReason='RECOVERY_REROUTE'
    end
    if task and task.kind=='return' and task.purpose=='handover' then
        local attempts=(task.handoverReroutes or 0)+1
        task.handoverReroutes=attempts
        -- The old tractor keeps its own implement; route recovery must never
        -- release the field order and send a second tractor before detaching.
        if attempts<=1 then
            local started,why=FMAReturnManager.startDrive(c,active.vehicle,task.target,task,task.phase)
            if started then
                if FMADiagnostics then FMADiagnostics.event(c,'handover.retryRoute',task.id,tostring(attempts)) end
                return true
            end
            FMAReturnManager.handoverFailed(c,task,'Přejezd po opakovaném pokusu: '..tostring(why))
        else
            FMAReturnManager.handoverFailed(c,task,'Opakovaně neprůjezdná fyzická cesta k nářadí / parkovišti')
        end
        return true
    end
    -- The harvest-crew coordinator alone handles a failed support-stage job.
    -- Updating the parent task here previously reset active/manual work and
    -- turned one path failure into two competing retries.
    if task and task.kind=='supportStage' then return false end
    local parent=task.parentTaskId and c.tasks[task.parentTaskId] or task
    -- Bound repeated retries even when no other vehicle/route is available.
    -- A blocked task is preferable to endless tractor movement in the farmyard.
    if parent and task.kind~='assemble' and task.kind~='unloaderAssemble' then
        parent.routeRecoveryCount=(parent.routeRecoveryCount or 0)+1
        if parent.routeRecoveryCount>math.max(1,math.min(8,c.settings.maxRecoveryCycles or 3)) then
            parent.state='blocked';parent.phase='BLOKACE / TRASA'
            parent.reason='Všechny bezpečné pokusy o jiný nájezd vyčerpány ('..tostring(parent.routeRecoveryCount-1)..'). Potřebuji volný vjezd nebo naučený bod.'
            c:issue('recovery:'..tostring(parent.id),parent.label or 'Přejezd',parent.reason,98)
            if FMADiagnostics then FMADiagnostics.event(c,'recovery.exhausted',parent.id,parent.reason) end
            return true
        end
    end
    if active.assemblyPlan and active.assemblyPlan.tool then c.implementReservations[active.assemblyPlan.tool.key]=nil end
    if active.transportAssemblyPlan and active.transportAssemblyPlan.tool then c.implementReservations[active.transportAssemblyPlan.tool.key]=nil end
    if parent then
        parent.state='pending';parent.phase='OBNOVA TRASY';parent.reason='Stroj se nepohnul · nový nájezd / jiný přístup';parent.retryAt=(c.now or 0)+2500
        if task.kind=='supportStage' then
            local slot=task.slotIndex or 1
            local roles=c.preparedSupport and c.preparedSupport[parent.id]
            local role=roles and roles[slot]
            if role then
                role.state='NEEDED';role.retryAt=(c.now or 0)+2500
                role.stageFailureCount=(role.stageFailureCount or 0)+1
                role.stageCandidateCursor=(tonumber(role.stageCandidateCursor) or 1)+1
                role.reason='Stání při přejezdu · Manager zkusí jiný příjezd k poli'
            end
            parent.phase='ODVOZ · OBNOVA TRASY'
            parent.reason='Odvoz se nepohnul · zkouší se jiné čekací místo u pole'
        elseif task.kind=='unloaderAssemble' then
            local slot=task.slotIndex or 1
            parent.supportAssemblyAttempts=parent.supportAssemblyAttempts or {}
            parent.supportAssemblyAttempts[slot]=(parent.supportAssemblyAttempts[slot] or task.assemblyAttempt or 1)+1
            if parent.supportAssemblyAttempts[slot]>3 and active.vehicle and active.vehicle.key then
                parent.failedVehicleKeys=parent.failedVehicleKeys or {}
                parent.failedVehicleKeys[active.vehicle.key]=true
                if parent.preferredSupportKeys and parent.preferredSupportKeys[slot]==active.vehicle.key then parent.preferredSupportKeys[slot]=nil;parent.preferredSupportNames[slot]=nil end
                parent.supportAssemblyAttempts[slot]=1
                parent.phase='OBNOVA ODVOZU · JINÝ TRAKTOR'
                parent.reason='Tři nájezdy k odvoznímu vozu selhaly · Manager zkusí jiný tahač'
            end
        else
            parent.assemblyAttempt=(parent.assemblyAttempt or 1)+1
            if task.kind=='assemble' and parent.assemblyAttempt>3 and active.vehicle and active.vehicle.key then
                parent.failedVehicleKeys=parent.failedVehicleKeys or {}
                if parent.ownerPinnedVehicle~=true then
                    parent.failedVehicleKeys[active.vehicle.key]=true
                    parent.preferredVehicleKey=nil;parent.preferredVehicleName=nil
                    parent.assemblyAttempt=1
                    parent.phase='OBNOVA · JINÝ STROJ'
                    parent.reason='Tři různé nájezdy selhaly · Manager zkusí jiný vhodný tahač'
                end
            end
        end
    end
    FMADiagnostics.event(c,'recovery.reroute',task.id,tostring(active.vehicle and active.vehicle.name or '?'))
    return true
end

function FMARecovery.update(c)
    if not c.settings.recoveryEnabled then return end
    local defaultSoft=(c.settings.recoveryProbeSeconds or 20)*1000
    local defaultReroute=(c.settings.recoveryRerouteSeconds or 43)*1000
    local defaultFailover=(c.settings.recoveryFailoverSeconds or 85)*1000
    for job,a in pairs(c.active or {}) do
        if job.isRunning and a and a.vehicle then
            local idle=(c.now or 0)-(a.lastProgress or a.start or c.now or 0)
            local fastAssembly=a.task and (a.task.kind=='assemble' or a.task.kind=='unloaderAssemble' or a.task.kind=='supportStage')
            -- Heading/steering angle is NOT movement. Read actual world positions.
            local soft=fastAssembly and 15000 or defaultSoft
            local reroute=fastAssembly and 32000 or defaultReroute
            local failover=fastAssembly and 65000 or defaultFailover
            if idle>=soft and (a.recoveryStage or 0)<1 then
                a.recoveryStage=1;a.task.phase='OBNOVA · ZJIŠTĚN STROJ BEZ POHYBU'
                FMADiagnostics.event(c,'recovery.probe',a.task.id,a.vehicle.name..' idle='..math.floor(idle/1000)..'s')
            end
            if idle>=reroute and (a.recoveryStage or 0)<2 and FMARecovery.isRecoverable(a) then
                a.recoveryStage=2
                -- Assembly owns its tractor/tool pair and alignment candidates. Generic
                -- recovery must never turn a difficult hitch manoeuvre into random fleet
                -- rotation. Stop only the current approach and let FMAAssembler advance
                -- to the next physical pose using the same pair.
                if a.task and (a.task.kind=='assemble' or a.task.kind=='unloaderAssemble') then
                    a.stopReason='ASSEMBLY_RETRY'
                else
                    -- Reversing is attempted only if all six physics probes
                    -- confirm free space; otherwise reroute with existing AI.
                    a.stopReason='NAV_REVERSE'
                end
                if FMANavigation and FMANavigation.hazard then FMANavigation.hazard(c,a,'POSITION_STALL') end
                FMAAI.stop(job)
                return
            end
            if idle>=failover and (a.recoveryStage or 0)<3 and a.task.kind=='field' then
                a.recoveryStage=3;a.stopReason='Stroj se opakovaně nepohybuje · výměna pracovní soupravy';FMAAI.stop(job)
                return
            end
        end
    end
end

function FMARecovery.writeDiagnostics(c,f)
    f:write('\nRECOVERY / FAILOVER\n')
    for _,task in pairs(c.tasks or {}) do
        if (task.recoveryCount or 0)>0 then f:write(task.id,' recoveryCount=',tostring(task.recoveryCount),' failedVehicles=',tostring(FMAUtil.count(task.failedVehicleKeys or {})),' phase=',tostring(task.phase),'\n') end
    end
end
