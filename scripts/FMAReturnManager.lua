-- Return-to-base lifecycle. A job is not considered finished until the assigned
-- machine is back at its learned home position and any implement that Farm Manager
-- attached for that job has been returned and detached close to its original bay.
-- Nothing is teleported: travel uses Courseplay pathfinding when available and detaching uses the game's
-- normal AttacherJoints API. Unknown/unsafe detach states fail closed.
FMAReturnManager = {}

-- A bunker work order is a parent of a physical CP worker and its return
-- task. Propagate the final parking result only after a real AI arrival.
local function finalizeBunkerOrderAfterParking(task,ok,reason)
    local work=task and (task.parentTask or nil)
    local root=work and work.kind=='bunker' and work.parentTask or nil
    if not root then return end
    if ok then
        root.state='done';root.phase='HUTNĚNÍ I PARKOVÁNÍ FYZICKY OVĚŘENO'
        root.reason='Zhutnění dosáhlo cíle a traktor dojel na své stání'
        root.returnFailed=nil
    else
        root.state='blocked';root.phase='HUTNĚNÍ DOKONČENO · NÁVRAT BLOKOVÁN'
        root.reason='Zhutnění ověřeno, ale parkování neproběhlo: '..tostring(reason)
        root.returnFailed=true
    end
end

local function pose(object)
    local x,z=FMAUtil.position(object)
    local angle=0
    if object and object.rootNode and object.rootNode~=0 and localDirectionToWorld and MathUtil and MathUtil.getYRotationFromDirection then
        local ok,dx,_,dz=pcall(localDirectionToWorld,object.rootNode,0,0,1)
        if ok and dx and dz then angle=MathUtil.getYRotationFromDirection(dx,dz) end
    end
    return x and {x=x,z=z,angle=angle} or nil
end

function FMAReturnManager.captureHomes(controller)
    controller.homePositions=controller.homePositions or {}
    controller.toolHomes=controller.toolHomes or {}
    for _,record in ipairs(controller.vehicles or {}) do
        if controller.homePositions[record.key]==nil and not record.busy then
            controller.homePositions[record.key]=pose(record.object)
        end
    end
    for _,tool in ipairs(controller.loose or {}) do
        if controller.toolHomes[tool.key]==nil and not controller.implementReservations[tool.key] then
            controller.toolHomes[tool.key]=pose(tool.object)
        end
    end
end

function FMAReturnManager.rememberAssembly(controller,parent,plan)
    if not parent or not plan or not plan.power or not plan.tool then return end
    FMAReturnManager.captureHomes(controller)
    local staging=FMAAssembler and FMAAssembler.approachPoint(plan.power,plan.tool,controller.settings) or nil
    parent.managedAttachment={
        toolKey=plan.tool.key,toolName=plan.tool.name,toolObject=plan.tool.object,
        powerKey=plan.power.key,toolHome=controller.toolHomes and controller.toolHomes[plan.tool.key] or pose(plan.tool.object),
        toolRecord=plan.tool,
        staging=staging
    }
end

function FMAReturnManager.isAttachedToVehicle(vehicle,attachment)
    if not vehicle or not attachment or not attachment.toolObject then return false end
    for _,entry in pairs(FMAUtil.call(vehicle,"getAttachedImplements") or {}) do
        if entry.object==attachment.toolObject then return true end
        for _,child in ipairs(FMAWorld.children(entry.object)) do if child==attachment.toolObject then return true end end
    end
    return false
end

function FMAReturnManager.detachManaged(controller,vehicle,attachment)
    if not attachment or not attachment.toolObject then return true end
    local tool=attachment.toolObject
    local attacher=FMAUtil.call(tool,"getAttacherVehicle")
    if not attacher then return true end
    if FMAUtil.owner(attacher)~=controller.farmId or not FMAReturnManager.isAttachedToVehicle(vehicle,attachment) then return false,"Nářadí je na jiné soupravě" end
    -- FS25 Attachable exposes isDetachAllowed() (without the getIs prefix).
    -- Retain the earlier spelling solely for older third-party specializations.
    local check=type(tool.isDetachAllowed)=='function' and 'isDetachAllowed' or 'getIsDetachAllowed'
    local allowed,warning=FMAUtil.call(tool,check)
    if allowed~=true then return false,tostring(warning or 'FS25 zatím nepovolilo bezpečné odpojení') end
    if type(tool.startDetachProcess)~='function' and type(attacher.detachImplementByObject)~='function' then
        return false,'Chybí bezpečné odpojovací rozhraní'
    end
    local ok,result
    if type(tool.startDetachProcess)=='function' then
        -- Handles FS25 support legs, parking stands and delayed animations.
        ok,result=pcall(tool.startDetachProcess,tool)
    else
        ok,result=pcall(attacher.detachImplementByObject,attacher,tool,false)
    end
    if not ok then return false,'FS25 odmítlo odpojení: '..tostring(result) end
    if FMAUtil.call(tool,'getAttacherVehicle')~=nil then
        if result==false and not (tool.spec_attachable and tool.spec_attachable.detachingInProgress) then
            return false,'FS25 nepovolilo zahájit odpojovací animaci'
        end
        return nil,'WAIT_DETACH'
    end
    return true
end

function FMAReturnManager.completeToolDrop(c,record,task)
    local parent=task.parentTask or (c.tasks and c.tasks[task.parentTaskId])
    if task.purpose=='handover' then
        local home=task.attachment and task.attachment.toolHome
        local tx,tz=FMAUtil.position(task.attachment and task.attachment.toolObject)
        local tolerance=math.max(4,math.min(12,c.settings.parkTolerance or 8))
        if not home or not tx or ((tx-home.x)^2+(tz-home.z)^2)>tolerance*tolerance then
            FMAReturnManager.handoverFailed(c,task,'Nářadí po odpojení není na bezpečně ověřeném stanovišti')
            return false
        end
        if parent then parent.state='handover';parent.phase='VÝMĚNA · TRAKTOR PARKUJE';parent.reason='Nářadí odpojeno · traktor jede zaparkovat' end
        if c.handoverJournal and c.handoverJournal[task.parentTaskId] then
            c.handoverJournal[task.parentTaskId].stage='detached'
        end
        if FMADiagnostics then FMADiagnostics.event(c,'handover.toolReturned',task.parentTaskId,tostring(task.attachment.toolKey)) end
    end
    c:notify(record.name..' odpojil '..tostring(task.attachment and task.attachment.toolName or 'nářadí')..' na svém místě')
    if FMAParkingManager then FMAParkingManager.release(c,task) end
    local home=task.home
    if FMAParkingManager and task.purpose~='handover' then
        local bay=FMAParkingManager.select(c,record,'vehicle')
        if bay and FMAParkingManager.reserve(c,bay,task) then home=bay;task.parkingWasTaught=true end
    end
    task.home=home
    local ok,why=FMAReturnManager.startDrive(c,record,home,task,'vehicleHome')
    if not ok and FMAParkingManager then FMAParkingManager.release(c,task) end
    if not ok then
        if task.purpose=='handover' then FMAReturnManager.handoverFailed(c,task,why)
        else
            if parent then parent.state='blocked';parent.reason='Návrat tahače selhal: '..tostring(why) end
            c:issue(task.id,task.label,tostring(why),82)
        end
    end
    return ok
end

function FMAReturnManager.startDrive(controller,record,target,task,phase)
    if not target or not target.x or not target.z then return false,"Chybí naučená parkovací poloha" end
    local vehicle=record and record.object
    if not vehicle or FMAUtil.owner(vehicle)~=controller.farmId then return false,"Stroj už není ve vlastnictví farmy" end
    if (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle))==true then return false,"Stroj převzal majitel" end
    if FMAControlAuthority then
        local allowed,reason=FMAControlAuthority.canStart(controller,record,task and task.id)
        if not allowed then return false,reason end
    end
    if FMATraffic and FMATraffic.canStart then
        local free,wait=FMATraffic.canStart(controller,record,target,task,45000)
        if not free then
            local started,why=FMALifecycle.defer(controller,task.id,record,task.parentTask or task,function()
                return FMAReturnManager.startDrive(controller,record,target,task,phase)
            end,wait)
            if task.purpose=='handover' and task.parentTask then
                task.parentTask.state='handover'
                task.parentTask.phase='VÝMĚNA · ČEKÁ NA BEZPEČNOU CESTU'
            end
            return started,why
        end
    end
    local tolerance=task.parkingBayId and 2.5 or ((phase=="toolBay") and 4 or 7)
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=target.x,z=target.z,angle=target.angle or 0,tolerance=tolerance})
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,moveWhy or "Stroj nepodporuje autonomní návrat" end
    task.phase=phase;task.state="running";task.target=target
    controller.reservations[record.key]=task.id;record.busy=true
    controller.active[job]={job=job,task=task,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,trafficTarget=target,transferMethod=moveMethod}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then
        controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false
        if FMATraffic then FMATraffic.release(controller.traffic,record.key) end
        return false,tostring(err)
    end
    return true
end

-- A failed tractor does not simply vanish from the work order. This is a
-- physical, two-leg handover, reusing the exact same native transfer API as a
-- normal return. Its field order remains HANDOVER (never PENDING) until BOTH
-- an actual detach at the home bay and the tractor's return are confirmed.
function FMAReturnManager.beginRecovery(c,parent,record,reason)
    if not c.settings.autoReturn then return false,'Předání nářadí vyžaduje zapnutý fyzický návrat' end
    local attachment=parent and parent.managedAttachment
    if not attachment or attachment.powerKey~=record.key or not attachment.toolObject then
        return false,'Není známé bezpečné nářadí k předání'
    end
    if not FMAReturnManager.isAttachedToVehicle(record.object,attachment) then
        return false,'Hra nepotvrzuje nářadí na původním tahači'
    end
    if not attachment.toolHome or not attachment.toolHome.x or not attachment.toolHome.z then
        return false,'Chybí ověřená výchozí poloha nářadí'
    end
    FMAReturnManager.captureHomes(c)
    local home=c.homePositions and c.homePositions[record.key]
    if not home or not home.x or not home.z then return false,'Chybí ověřené parkování původního traktoru' end
    if not FMALifecycle.allowed(c,record,true) then return false,'Původní traktor již nelze bezpečně převzít' end
    c.handoverLeases=c.handoverLeases or {}
    if c.handoverLeases[attachment.toolKey] and c.handoverLeases[attachment.toolKey]~=parent.id then
        return false,'Nářadí už má rezervaci jiné zakázky'
    end
    local task={id='handover:'..tostring(parent.id)..':'..tostring(record.key),kind='return',purpose='handover',
        operation=parent.operation,label='Výměna tahače · '..record.name,parentTaskId=parent.id,
        parentTask=parent,attachment=attachment,home=home,originalKey=record.key,
        failureReason=tostring(reason),priority=(parent.priority or 50)+15,state='pending'}
    c.handoverLeases[attachment.toolKey]=parent.id
    c.handoverJournal=c.handoverJournal or {}
    c.handoverJournal[parent.id]={taskId=parent.id,vehicle=record.key,tool=attachment.toolKey,
        operation=parent.operation,stage='attached',reason=tostring(reason)}
    parent.state='handover';parent.phase='VÝMĚNA · NÁŘADÍ DO STÁNÍ'
    parent.reason='Původní tahač odváží nářadí na ověřené stanoviště · '..tostring(reason)
    parent.handoverToolKey=attachment.toolKey
    -- AI_JOB_STOPPED is emitted while GIANTS may still be releasing the old
    -- helper. A transfer in the SAME event tick is frequently rejected; schedule
    -- its first start on a subsequent simulation tick instead of losing the tool.
    c.pendingHandovers=c.pendingHandovers or {}
    c.pendingHandovers[parent.id]={record=record,task=task,retryAt=(c.now or 0)+1500,attempts=0}
    c.reservations[record.key]=task.id;record.busy=true
    parent.phase='VÝMĚNA · UVOLNĚNÍ PŮVODNÍ AI'
    if FMADiagnostics then FMADiagnostics.event(c,'handover.begin',parent.id,record.name..' | '..tostring(reason)) end
    return true
end

function FMAReturnManager.update(c)
    for id,session in pairs(c.pendingDetaches or {}) do
        local tool=session.task.attachment and session.task.attachment.toolObject
        local record=session.record
        local parent=session.task.parentTask
        if not tool or not record or FMAUtil.owner(record.object)~=c.farmId
            or (FMAGameNative and FMAGameNative.isManuallyControlled(record.object))==true then
            c.pendingDetaches[id]=nil
            if session.task.purpose=='handover' then FMAReturnManager.handoverFailed(c,session.task,'Odpojení přerušeno / změna ovládání')
            elseif parent then parent.state='blocked';parent.reason='Přerušeno odpojení nářadí' end
        elseif FMAUtil.call(tool,'getAttacherVehicle')==nil then
            c.pendingDetaches[id]=nil
            FMAReturnManager.completeToolDrop(c,record,session.task)
        elseif (c.now or 0)>session.deadline then
            c.pendingDetaches[id]=nil
            if session.task.purpose=='handover' then FMAReturnManager.handoverFailed(c,session.task,'FS25 nepotvrdilo odpojení do 25 sekund')
            elseif parent then parent.state='blocked';parent.reason='FS25 nepotvrdilo odpojení do 25 sekund' end
        end
    end
    for id,pending in pairs(c.pendingHandovers or {}) do
        if (c.now or 0)>=(pending.retryAt or 0) then
            local task,record=pending.task,pending.record
            local allowed,why=FMALifecycle.allowed(c,record,true)
            if not allowed then
                c.pendingHandovers[id]=nil
                c.reservations[record.key]=nil;record.busy=false
                FMAReturnManager.handoverFailed(c,task,why)
            elseif FMAUtil.call(record.object,'getIsAIActive')==true then
                pending.attempts=(pending.attempts or 0)+1
                if pending.attempts>=6 then
                    c.pendingHandovers[id]=nil;c.reservations[record.key]=nil;record.busy=false
                    FMAReturnManager.handoverFailed(c,task,'FS25 neuvolnilo původní AI řízení po 12 sekundách')
                else pending.retryAt=(c.now or 0)+2000 end
            else
                c.reservations[record.key]=nil;record.busy=false
                local started,startWhy=FMAReturnManager.startDrive(c,record,task.attachment.toolHome,task,'toolBay')
                if started then
                    c.pendingHandovers[id]=nil
                    if task.parentTask then task.parentTask.state='handover';task.parentTask.phase='VÝMĚNA · NÁŘADÍ DO STÁNÍ' end
                else
                    pending.attempts=(pending.attempts or 0)+1
                    if pending.attempts>=3 then
                        c.pendingHandovers[id]=nil
                        FMAReturnManager.handoverFailed(c,task,startWhy)
                    else
                        pending.retryAt=(c.now or 0)+4000
                        c.reservations[record.key]=task.id;record.busy=true
                    end
                end
            end
        end
    end
end

function FMAReturnManager.handoverFailed(c,task,reason)
    local parent=task and (task.parentTask or c.tasks[task.parentTaskId])
    if parent then
        parent.state='blocked';parent.phase='BLOKACE / FYZICKÉ PŘEDÁNÍ'
        parent.reason='Výměna tahače nebyla bezpečně dokončena: '..tostring(reason)
        parent.handoverToolKey=nil
    end
    if task and task.attachment and c.handoverLeases then
        c.handoverLeases[task.attachment.toolKey]=nil
    end
    if parent and c.handoverJournal and c.handoverJournal[parent.id] then
        local row=c.handoverJournal[parent.id]
        row.stage='blocked';row.reason=tostring(reason):sub(1,240)
    end
    c:issue('handover:'..tostring(parent and parent.id or task and task.id),'Výměna soupravy',tostring(reason),99)
    if FMAExperience and FMAExperience.handover then FMAExperience.handover(c,parent,task and task.originalKey,false,reason) end
    if FMADiagnostics then FMADiagnostics.event(c,'handover.blocked',parent and parent.id or '?',tostring(reason)) end
end

function FMAReturnManager.handoverCompleted(c,task,record)
    local parent=task.parentTask or c.tasks[task.parentTaskId]
    if task.attachment and c.handoverLeases then c.handoverLeases[task.attachment.toolKey]=nil end
    if task.attachment and c.implementReservations and parent and c.implementReservations[task.attachment.toolKey]==parent.id then
        c.implementReservations[task.attachment.toolKey]=nil
    end
    if parent then
        if c.handoverJournal then c.handoverJournal[parent.id]=nil end
        parent.handoverToolKey=nil
        if FMARecovery and FMARecovery.handoverCompleted then FMARecovery.handoverCompleted(c,parent,record,task) end
    end
    FMAJobs.stopMotor(record)
    c:notify(record.name..' zaparkoval; nářadí je vráceno a připraveno pro druhý tahač')
end

function FMAReturnManager.begin(controller,active)
    if not controller.settings.autoReturn then return false,"Automatický návrat je vypnutý" end
    local parent=active.task
    local record=active.vehicle
    if not record or not record.object then return false,"Chybí návratový stroj" end
    FMAReturnManager.captureHomes(controller)
    local home=controller.homePositions and controller.homePositions[record.key]
    if not home then return false,"Pro stroj není naučená výchozí pozice" end
    local attachment=parent.managedAttachment
    local task={id="return:"..tostring(parent.id)..":"..record.key,kind="return",operation=parent.operation,
        label="Návrat · "..record.name,parentTaskId=parent.id,parentTask=parent,fieldId=parent.fieldId,attachment=attachment,
        home=home,priority=(parent.priority or 50)+1,state="pending"}
    parent.state="returning";parent.phase="NÁVRAT / PARKOVÁNÍ";parent.reason="Návrat techniky na farmu"
    local target=home;local phase="vehicleHome"
    local hasManagedTool=attachment and attachment.powerKey==record.key and FMAReturnManager.isAttachedToVehicle(record.object,attachment)
    if hasManagedTool then
        target=attachment.toolHome or attachment.staging or home;phase="toolBay"
        -- A tool bay stores the actual implement pose AND the tractor pose.
        -- It may only be reused with the exact taught tractor geometry.
        if FMAParkingManager then
            local toolRecord=attachment.toolRecord or {key=attachment.toolKey,object=attachment.toolObject}
            local bay=FMAParkingManager.select(controller,toolRecord,'tool',record.key)
            if bay and bay.driveX and bay.driveZ and FMAParkingManager.reserve(controller,bay,task) then
                target={x=bay.driveX,z=bay.driveZ,angle=bay.driveAngle or 0}
                task.expectedToolBay=bay
            end
        end
    elseif FMAParkingManager then
        local bay=FMAParkingManager.select(controller,record,'vehicle')
        if bay and FMAParkingManager.reserve(controller,bay,task) then target=bay;task.home=bay;task.parkingWasTaught=true end
    end
    local ok,why=FMAReturnManager.startDrive(controller,record,target,task,phase)
    if not ok and FMAParkingManager then FMAParkingManager.release(controller,task) end
    if ok then controller:notify(record.name.." se po dokončení vrací na farmu"..(task.parkingBayId and (' · stání '..task.parkingBayId) or '')) end
    return ok,why
end

function FMAReturnManager.finish(controller,active)
    local task=active.task;local record=active.vehicle
    local parent=task.parentTask or controller.tasks[task.parentTaskId]
    if active.stopReason then
        if FMAParkingManager then FMAParkingManager.release(controller,task) end
        if task.purpose=='handover' then FMAReturnManager.handoverFailed(controller,task,active.stopReason);return end
        -- A validated completed field MUST NOT be turned back into a failed
        -- agricultural operation because parking navigation was impossible.
        -- Try ONE physically mapped road approach close to the saved home,
        -- then retry the real parking point. Never teleport or fake parking.
        if task.phase~='toolBay' and not task.returnRoadTried and controller.settings.enabled and active.stopReason~='OWNER_STOP_SELECTED'
            and active.stopReason~='Pozastaveno majitelem' and not (parent and parent.ownerStopRequested)
            and controller.engineRoads and controller.engineRoads.edges
            and task.home and task.home.x and task.home.z then
            task.returnRoadTried=true
            local best,bestD=nil,35*35
            local px,pz=FMAUtil.position(record.object)
            for _,edge in ipairs(controller.engineRoads.edges) do
                for _,candidate in ipairs({{x=edge.ax,z=edge.az},{x=edge.bx,z=edge.bz}}) do
                    local d=(candidate.x-task.home.x)^2+(candidate.z-task.home.z)^2
                    if d<bestD and d>8*8 and (not px or (candidate.x-px)^2+(candidate.z-pz)^2>10*10) then
                        best,bestD=candidate,d
                    end
                end
            end
            if best then
                local started,why=FMAReturnManager.startDrive(controller,record,best,task,'roadApproach')
                if started then
                    if FMADiagnostics then FMADiagnostics.event(controller,'return.roadFallback',task.id,'road-near-home') end
                    return
                end
            end
        end
        if parent then
            parent.returnFailed=true
            parent.reason='Práce dokončena, ale návrat na farmu selhal: '..tostring(active.stopReason)
            parent.phase='PRÁCE HOTOVÁ · NEÚSPĚŠNÝ NÁVRAT'
            parent.state='done'
        end
        finalizeBunkerOrderAfterParking(task,false,active.stopReason)
        controller:issue(task.id,task.label,active.stopReason,80);return
    end
    if task.phase=='roadApproach' then
        local ok,why=FMAReturnManager.startDrive(controller,record,task.home,task,'vehicleHome')
        if not ok then
            task.returnRoadTried=true
            if parent then parent.returnFailed=true;parent.reason='Práce dokončena; poslední parkovací přejezd selhal: '..tostring(why);parent.state='done' end
            controller:issue(task.id,task.label,tostring(why),80)
        end
        return
    end
    local x,z=FMAUtil.position(record.object);local target=task.target
    local parkTolerance=task.parkingBayId and 2.8 or (controller.settings.parkTolerance or 8)
    if not x or not target or ((x-target.x)^2+(z-target.z)^2)>parkTolerance^2 then
        local reason="Stroj nedojel dost blízko k parkovacímu bodu"
        if task.purpose=='handover' then FMAReturnManager.handoverFailed(controller,task,reason);return end
        if parent then parent.state="blocked";parent.reason=reason end
        finalizeBunkerOrderAfterParking(task,false,reason)
        controller:issue(task.id,task.label,reason,80);return
    end
    -- A taught parking bay is not completed by mere proximity if the vehicle
    -- is facing the wrong way across a traffic lane or inside a shed.
    if task.parkingBayId and FMAParkingManager and FMAParkingManager.isAligned then
        local aligned=FMAParkingManager.isAligned(record.object,target)
        if aligned==false then
            FMAParkingManager.release(controller,task)
            local reason='Stroj je u stání, ale není natočen ve směru naučeného parkování'
            if parent then parent.returnFailed=true;parent.phase='PARKOVÁNÍ · NUTNÁ KOREKCE';parent.reason=reason end
            controller:issue(task.id,task.label,reason,75)
            return
        end
    end
    if task.phase=="toolBay" then
        if task.expectedToolBay then
            local tx,tz=FMAUtil.position(task.attachment and task.attachment.toolObject)
            local expected=task.expectedToolBay
            local radius=math.max(2.5,math.min(5,controller.settings.parkTolerance or 8))
            if not tx or (tx-expected.x)^2+(tz-expected.z)^2>radius*radius then
                if FMAParkingManager then FMAParkingManager.release(controller,task) end
                if parent then parent.state='blocked';parent.phase='ODSTAVENÍ NÁŘADÍ';parent.reason='Poloha odstavovaného nářadí neodpovídá naučenému místu' end
                controller:issue(task.id,task.label,'Odpojení zamítnuto: nářadí nestojí na naučeném stání',85)
                return
            end
        end
        local ok,why=FMAReturnManager.detachManaged(controller,record.object,task.attachment)
        if ok==nil and why=='WAIT_DETACH' then
            controller.pendingDetaches=controller.pendingDetaches or {}
            controller.pendingDetaches[task.id]={record=record,task=task,deadline=(controller.now or 0)+25000}
            controller.reservations[record.key]=task.id;record.busy=true
            if parent then parent.phase='VÝMĚNA / ČEKÁ NA ODPÍNACÍ ANIMACI' end
            return
        end
        if not ok then
            if task.purpose=='handover' then FMAReturnManager.handoverFailed(controller,task,why);return end
            if parent then parent.state="blocked";parent.reason="Odpojení po práci selhalo: "..tostring(why) end
            controller:issue(task.id,task.label,tostring(why),82);return
        end
        FMAReturnManager.completeToolDrop(controller,record,task)
        return
    end
    controller.reservations[record.key]=nil;record.busy=false
    if FMAParkingManager then FMAParkingManager.release(controller,task) end
    if task.purpose=='parking' then
        controller.homePositions=controller.homePositions or {}
        controller.homePositions[record.key]={x=target.x,z=target.z,angle=target.angle or 0}
        FMAJobs.stopMotor(record)
        controller:notify(record.name..' fyzicky zaparkoval na vybraném stání')
        controller.diagnosticDirty=true
        return
    end
    if task.purpose=='handover' then
        if task.attachment and FMAUtil.call(task.attachment.toolObject,'getAttacherVehicle') then
            FMAReturnManager.handoverFailed(controller,task,'Nářadí bylo před dokončením předání znovu zapřaženo');return
        end
        FMAReturnManager.handoverCompleted(controller,task,record)
        controller.elapsed=controller.settings.scanSeconds*1000
        return
    end
    if task.parkingWasTaught and target then
        controller.homePositions=controller.homePositions or {}
        controller.homePositions[record.key]={x=target.x,z=target.z,angle=target.angle or 0}
    end
    if parent then
        local verified,verifyWhy,proof=true,nil,nil
        if controller.verifyFieldOrderComplete then verified,verifyWhy,proof=controller:verifyFieldOrderComplete(parent) end
        if parent.kind=="field" and not verified then
            parent.verificationAttempts=(parent.verificationAttempts or 0)+1
            parent.completedFingerprint=nil;parent.awaitingWorldVerification=nil
            if parent.verificationAttempts<=1 and controller.fieldsById and controller.fieldsById[parent.fieldId]
                and controller.fieldsById[parent.fieldId].valid==true then
                parent.state="pending";parent.phase="OVĚŘENÍ / JEDINÉ OPAKOVÁNÍ";parent.reason=verifyWhy
                parent.retryAt=controller.now+30000
            else
                parent.state="blocked";parent.phase="BLOKACE / VÝSLEDEK NEOVĚŘEN";parent.reason=verifyWhy
            end
            controller:issue("verify:"..tostring(parent.id),parent.label.." · ověření výsledku",verifyWhy,92)
        elseif parent.kind=='field' and (proof=='AI_STAGE' or proof=='DELIVERY') then
            parent.state='stageComplete';parent.phase='ETAPA UKONČENA · BEZ ZÁRUKY POKRYTÍ'
            parent.reason=verifyWhy;parent.retryAt=controller.now+60000;parent.ownerRequested=nil;parent.awaitingWorldVerification=nil
        else
            parent.state="done";parent.phase="HOTOVO · OVĚŘENO FS25";parent.reason="Hotovo · skutečný stav ověřen, technika vrácena na farmu";parent.retryAt=controller.now+60000;parent.ownerRequested=nil;parent.awaitingWorldVerification=nil
            if proof=='WORLD' then
                if FMAForageCoordinator and (parent.operation=='mow' or parent.operation=='harvest') then FMAForageCoordinator.afterOperation(controller,parent) end
                if FMAExperience and FMAExperience.verified then FMAExperience.verified(controller,parent,record,true) end
            end
        end
    end
    finalizeBunkerOrderAfterParking(task,true)
    FMAJobs.stopMotor(record)
    controller:notify(record.name.." zaparkoval · připraven na další úkol")
    controller.elapsed=controller.settings.scanSeconds*1000
end
