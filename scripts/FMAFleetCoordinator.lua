-- Coordinated harvesting and fleet sizing. Pure calculations are kept separate from engine calls.
FMAFleetCoordinator = {}


local function hasAnyKey(t)
    for _ in pairs(t or {}) do return true end
    return false
end

function FMAFleetCoordinator.supportsTransportFillType(record,fillType)
    if not record or not record.capabilities or not record.capabilities.transport then return false end
    if fillType==nil then return true end
    if record.transportFillTypes and record.transportFillTypes[fillType]==true then return true end

    -- Configurable/ModHub trailers often expose a usable dischargeable cargo body but
    -- getFillUnitSupportsFillType() returns false until the exact configuration/fill unit
    -- is active. Treat a populated supportedFillTypes table as authoritative; an empty
    -- or missing table is UNKNOWN, not an explicit rejection. This is important for
    -- already assembled tractor+trailer trains discovered from the live attachment tree.
    local sawCargo=false
    local sawAuthoritativeTable=false
    local sawUnknownCargo=false
    for _,obj in ipairs(FMAWorld.children(record.object)) do
        local units=FMAUtil.call(obj,"getFillUnits") or (obj.spec_fillUnit and obj.spec_fillUnit.fillUnits) or {}
        for i,unit in pairs(units) do
            local cargo=((obj.spec_trailer and obj.spec_dischargeable) or (FMAModHubAdapter and FMAModHubAdapter.isAttachableTransport(obj)))
            if cargo and (not FMAModHubAdapter or FMAModHubAdapter.cargoUnit(obj,i)) then
                sawCargo=true
                local tableKnown=hasAnyKey(unit and unit.supportedFillTypes or nil)
                if tableKnown then
                    sawAuthoritativeTable=true
                    if unit.supportedFillTypes[fillType]==true then return true end
                else
                    local supports=FMAUtil.call(obj,"getFillUnitSupportsFillType",i,fillType)
                    if supports==true then return true end
                    sawUnknownCargo=true
                end
            end
        end
        -- Some trailers only expose trailer/dischargeable until their configurable fill
        -- volume is materialized. They are still a real cargo body; keep them usable as
        -- an unknown-compatible transporter rather than inventing a missing purchase.
        if ((obj.spec_trailer and obj.spec_dischargeable) or (FMAModHubAdapter and FMAModHubAdapter.isAttachableTransport(obj))) and next(units)==nil then
            sawCargo=true;sawUnknownCargo=true
        end
    end
    if sawCargo and sawUnknownCargo then return true end
    if sawAuthoritativeTable then return false end
    -- Capability=transport came from the live attached tree but the fill API supplied no
    -- decisive metadata. Fail open for an EMPTY transport body; the actual CP/base-game
    -- job validation remains the final authority before work begins.
    return sawCargo or not hasAnyKey(record.transportFillTypes)
end

function FMAFleetCoordinator.requiredUnloaders(fillRateLps, cycleSeconds, trailerCapacity, maxUnloaders)
    local rate=math.max(0,tonumber(fillRateLps) or 0)
    local cycle=math.max(1,tonumber(cycleSeconds) or 1)
    local capacity=math.max(1,tonumber(trailerCapacity) or 1)
    local n=math.ceil(rate*cycle/capacity)
    if rate>0 then n=math.max(1,n) else n=1 end
    return math.max(1,math.min(tonumber(maxUnloaders) or 3,n))
end


local function crewId(task,harvesterKey)
    return 'harvest:'..tostring(task and task.fieldId or '?')..':'..tostring(harvesterKey or 'unknown')
end

function FMAFleetCoordinator.registerCrew(controller,task,harvester,job)
    if not controller or not task or not harvester then return nil end
    controller.crewAssignments=controller.crewAssignments or {}
    local id=task.crewId or crewId(task,harvester.key)
    task.crewId=id
    local crew=controller.crewAssignments[id] or {id=id,unloaderKeys={},createdAt=controller.now or 0}
    crew.taskId=task.id;crew.taskRef=task;crew.fieldId=task.fieldId;crew.harvesterKey=harvester.key;crew.job=job or crew.job
    crew.operation=task.operation;crew.updatedAt=controller.now or 0
    controller.crewAssignments[id]=crew
    return crew
end

function FMAFleetCoordinator.rememberCrewUnloader(controller,groupOrTask,record)
    if not controller or not record then return end
    local id=groupOrTask and (groupOrTask.id or groupOrTask.crewId)
    if groupOrTask and groupOrTask.parentTask and groupOrTask.parentTask.crewId then id=groupOrTask.parentTask.crewId end
    if groupOrTask and groupOrTask.task and groupOrTask.task.crewId then id=groupOrTask.task.crewId end
    local crew=id and controller.crewAssignments and controller.crewAssignments[id]
    if not crew and groupOrTask and groupOrTask.parentTask then crew=FMAFleetCoordinator.registerCrew(controller,groupOrTask.parentTask,groupOrTask.harvester) end
    if not crew then return end
    crew.unloaderKeys=crew.unloaderKeys or {}
    for _,key in ipairs(crew.unloaderKeys) do if key==record.key then return end end
    crew.unloaderKeys[#crew.unloaderKeys+1]=record.key
end

local function crewUnloaderRecords(controller,crew)
    local out,seen={},{}
    for _,key in ipairs(crew and crew.unloaderKeys or {}) do
        local record=controller.vehicleByKey and controller.vehicleByKey[key]
        if record and not seen[key] then out[#out+1]=record;seen[key]=true end
    end
    return out,seen
end

function FMAFleetCoordinator.operatorMode(record)
    if not record or not record.object then return 'MISSING' end
    return (FMAGameNative and FMAGameNative.operatorState(record.object).mode) or 'IDLE'
end

function FMAFleetCoordinator.shouldCallUnloader(fillRatio, fillRateLps, capacity, distanceMeters, settings)
    local ratio=FMAUtil.clamp(fillRatio or 0,0,1)
    local threshold=settings.unloaderCall or 0.80
    if ratio>=threshold then return true end
    local rate=tonumber(fillRateLps) or 0
    if rate<=0 or not capacity or capacity<=0 then return false end
    local secondsToFull=((1-ratio)*capacity)/rate
    local eta=(math.max(0,tonumber(distanceMeters) or 0)/(settings.unloaderApproachSpeed or 7.5))+(settings.unloaderLeadSeconds or 30)
    return secondsToFull<=eta
end

function FMAFleetCoordinator.sample(controller)
    controller.harvestTelemetry=controller.harvestTelemetry or {}
    for _,v in ipairs(controller.vehicles or {}) do
        if v.capabilities.harvest then
            local key=v.key;local now=controller.now or 0
            local old=controller.harvestTelemetry[key]
            local cap=math.max(v.harvesterCapacity or 0,0)
            local fill=0
            for _,tool in ipairs(FMAWorld.children(v.object)) do
                if tool.spec_combine then
                    for i in pairs(FMAUtil.call(tool,"getFillUnits") or {}) do fill=fill+(FMAUtil.call(tool,"getFillUnitFillLevel",i) or 0) end
                end
            end
            local x,z=FMAUtil.position(v.object);v.x=x or v.x;v.z=z or v.z
            local rate=0
            if old and now>old.time then rate=math.max(0,(fill-old.fill)/((now-old.time)/1000)) end
            controller.harvestTelemetry[key]={time=now,fill=fill,capacity=cap,rate=rate,x=v.x,z=v.z}
        end
    end
end

function FMAFleetCoordinator.freeTransporters(controller, fillType)
    local result={}
    for _,v in ipairs(controller.vehicles or {}) do
        if v.capabilities.transport and not v.busy and not controller.excluded[v.key] and not controller.reservations[v.key] and not v.lowFuel then
            if FMAFleetCoordinator.supportsTransportFillType(v,fillType) then result[#result+1]=v end
        end
    end
    table.sort(result,function(a,b) return (a.capacity or 0)>(b.capacity or 0) end)
    return result
end


-- PRE-HARVEST CREW PREPARATION -------------------------------------------------
-- Real farm logistics do not wait for the combine to be completely ready before
-- preparing haulage.  A faster tractor + trailer can be assembled and sent to a
-- safe waiting point at the field while the combine/header chain is still being
-- prepared.  These roles are reserved independently from the parent field task.
local function supportRole(controller,parent,slot)
    controller.preparedSupport=controller.preparedSupport or {}
    local byTask=controller.preparedSupport[parent.id]
    if not byTask then byTask={};controller.preparedSupport[parent.id]=byTask end
    local role=byTask[slot]
    if not role then
        role={id='haulage:'..parent.id..':'..tostring(slot),slot=slot,state='NEEDED',parentTaskId=parent.id,fieldId=parent.fieldId}
        byTask[slot]=role
    end
    return role
end

local function roleReservationId(parent,slot)
    return 'supportWait:'..parent.id..':'..tostring(slot)
end

-- Persistent-in-session circuit breaker. A single 6R must not be sent against
-- impossible field-entry goals dozens of times, nor rotated between two fields
-- when it is already part of the first harvest crew.
function FMAFleetCoordinator.roadBackoff(c,record)
    if not c or not record or not record.key then return false end
    local e=c.stageRouteFailures and c.stageRouteFailures[record.key]
    if not e then return false end
    local x,z=record.x,record.z
    if record.object and FMAUtil.position then
        local px,pz=FMAUtil.position(record.object);x=px or x;z=pz or z
    end
    local moved=x and z and e.x and e.z and ((x-e.x)^2+(z-e.z)^2)>=25*25
    if moved or (c.now or 0)>=(e.retryAt or 0) then
        c.stageRouteFailures[record.key]=nil
        if moved then
            for _,roles in pairs(c.preparedSupport or {}) do
                for _,role in pairs(roles) do
                    if role.record and role.record.key==record.key and role.state=='BLOCKED' then
                        role.stageFailureCount=0;role.stageCandidateCursor=1
                        role.state='NEEDED';role.retryAt=0
                    end
                end
            end
        end
        return false
    end
    return true, 'Silniční AI opakovaně odmítla cíl; další pokus až po přesunu stroje nebo vypršení ochranné pauzy'
end

function FMAFleetCoordinator.ownCrewVehicle(c,parent,record)
    if not record or not record.key then return false end
    for taskId,roles in pairs(c.preparedSupport or {}) do
        if taskId~=parent.id then
            local former=c.tasks and c.tasks[taskId]
            -- A cancelled/unselected job must not indefinitely confiscate the
            -- only grain-trailer tractor from an explicitly approved harvest.
            local inactive=former and (former.ownerStopRequested==true or former.state=='done' or former.state=='cancelled'
                or (c.settings and c.settings.selectedJobsOnly and former.ownerApproved~=true))
            if not inactive then
            for _,role in pairs(roles or {}) do
                if role.record and role.record.key==record.key and
                    (role.state=='ASSEMBLING' or role.state=='READY' or role.state=='STAGING' or
                     role.state=='WAITING_FIELD' or role.state=='ACTIVE' or role.state=='PLAYER' or role.state=='PAUSED') then
                    return false
                end
            end
            end
        end
    end
    return true
end

function FMAFleetCoordinator.noteStageRouteFailure(c,record,reason,exhausted)
    if not c or not record or not record.key then return nil end
    c.stageRouteFailures=c.stageRouteFailures or {}
    local e=c.stageRouteFailures[record.key]
    if e and (c.now or 0)-(e.last or 0)>600000 then e=nil end
    if not e then e={count=0};c.stageRouteFailures[record.key]=e end
    e.count=e.count+1;e.last=c.now or 0
    local x,z=record.x,record.z
    if record.object and FMAUtil.position then
        local px,pz=FMAUtil.position(record.object);x=px or x;z=pz or z
    end
    e.x=x;e.z=z;e.reason=reason
    -- A circuit breaker is only meaningful once alternate entry points and both
    -- GIANTS/CP pathfinding have been attempted; 4 errors do not mean 4 routes.
    if exhausted then e.retryAt=(c.now or 0)+180000 end
    return e
end

function FMAFleetCoordinator.getPreparedRole(controller,parent,slot)
    return controller.preparedSupport and controller.preparedSupport[parent.id] and controller.preparedSupport[parent.id][slot]
end

local function appendCandidate(list,seen,x,z,angle,label)
    if not x or not z then return end
    local k=string.format('%.1f:%.1f',x,z)
    if seen[k] then return end
    seen[k]=true;list[#list+1]={x=x,z=z,angle=angle or 0,label=label or 'okraj pole'}
end

-- Build several edge-side waiting points and let the Courseplay transfer pathfinder choose a
-- reachable one.  The point is deliberately outside the field polygon so an
-- early haulage unit does not drive through standing crop while waiting.
function FMAFleetCoordinator.fieldWaitingCandidates(controller,parent,record)
    local field=controller.fieldsById and controller.fieldsById[parent.fieldId]
    local result,seen={},{}
    if not field then return result end
    local fx,fz=field.x,field.z
    if FMATeach and FMATeach.bestApproach and fx and fz then
        local learned=FMATeach.bestApproach(controller,{x=fx,z=fz},'POLE')
        if learned then appendCandidate(result,seen,learned.x,learned.z,learned.angle,'naučené čekací místo') end
    end
    local object=field.object
    local polygon={}
    for _,node in ipairs(object and object.polygonPoints or {}) do
        if getWorldTranslation then
            local ok,x,_,z=pcall(getWorldTranslation,node)
            if ok and x and z then polygon[#polygon+1]={x=x,z=z} end
        end
    end
    local offset=math.max(8,tonumber(controller.settings.harvestFieldWaitDistance) or 12)
    local rx,rz=record and record.x,record and record.z
    if #polygon>0 and fx and fz then
        -- Spread entry candidates around the WHOLE field. Sorting the nearest 12
        -- polygon vertices only explores one blocked fence/corner repeatedly.
        local sectors={}
        for _,p in ipairs(polygon) do
            local dx,dz=p.x-fx,p.z-fz
            local len=math.sqrt(dx*dx+dz*dz)
            if len>1 then
                local slope=math.abs(dz)/(math.abs(dx)+0.000001)
                local index
                if slope<0.5 then index=dx>=0 and 1 or 5
                elseif slope>2 then index=dz>=0 and 3 or 7
                elseif dx>=0 then index=dz>=0 and 2 or 8
                else index=dz>=0 and 4 or 6 end
                if not sectors[index] or len>sectors[index].radius then
                    sectors[index]={point=p,radius=len}
                end
            end
        end
        local spread={}
        for _,entry in pairs(sectors) do spread[#spread+1]=entry.point end
        table.sort(spread,function(a,b)
            if rx and rz then return (a.x-rx)^2+(a.z-rz)^2<(b.x-rx)^2+(b.z-rz)^2 end
            return (a.x-fx)^2+(a.z-fz)^2<(b.x-fx)^2+(b.z-fz)^2
        end)
        for _,p in ipairs(spread) do
            local dx,dz=p.x-fx,p.z-fz;local len=math.sqrt(dx*dx+dz*dz)
            if len>0.1 then
                dx,dz=dx/len,dz/len
                local x,z=p.x+dx*offset,p.z+dz*offset
                local angle=0
                if MathUtil and MathUtil.getYRotationFromDirection then angle=MathUtil.getYRotationFromDirection(fx-x,fz-z) end
                appendCandidate(result,seen,x,z,angle,'čekací bod u pole')
                -- A point directly behind a boundary hedge may be impassable. A
                -- farther stand-off is a different physical target, not the same retry.
                appendCandidate(result,seen,p.x+dx*(offset+24),p.z+dz*(offset+24),angle,'delší příjezd mimo kraj')
            end
        end
    end
    -- Conservative fallback if this map does not expose polygon nodes.
    if fx and fz then
        local dx,dz=(rx or fx+1)-fx,(rz or fz)-fz;local len=math.sqrt(dx*dx+dz*dz)
        if len<0.1 then dx,dz,len=1,0,1 end;dx,dz=dx/len,dz/len
        local x,z=fx+dx*(offset+28),fz+dz*(offset+28)
        local angle=0;if MathUtil and MathUtil.getYRotationFromDirection then angle=MathUtil.getYRotationFromDirection(fx-x,fz-z) end
        appendCandidate(result,seen,x,z,angle,'záložní čekací bod')
        -- Maps without polygon nodes still need physically distinct long approaches.
        for _,side in ipairs({{1,0},{0,1},{-1,0},{0,-1},{1,1},{-1,1},{-1,-1},{1,-1}}) do
            local length=math.sqrt(side[1]^2+side[2]^2)
            for _,radius in ipairs({offset+42,offset+85}) do
                local tx=fx+side[1]/length*radius;local tz=fz+side[2]/length*radius
                local a=0
                if MathUtil and MathUtil.getYRotationFromDirection then a=MathUtil.getYRotationFromDirection(fx-tx,fz-tz) end
                appendCandidate(result,seen,tx,tz,a,'vzdálenější nájezd u pole')
            end
        end
    end
    return result
end

function FMAFleetCoordinator.launchStageLeg(controller,parent,record,slot,toolRecord,target,guidePoints,guideIndex,finalTarget)
    local role=supportRole(controller,parent,slot)
    if not FMAFleetCoordinator.ownCrewVehicle(controller,parent,record) then
        return false,'Odvozní souprava patří jiné rozpracované sklizni'
    end
    local cooled,why=FMAFleetCoordinator.roadBackoff(controller,record)
    if cooled then role.state='BLOCKED';role.retryAt=controller.stageRouteFailures[record.key].retryAt;role.reason=why;return false,why end
    local trafficTask={id='supportStage:'..parent.id..':'..tostring(slot),kind='supportStage',operation='supply',parentTaskId=parent.id,targetFieldId=parent.fieldId}
    local trafficOk=true;local trafficWhy=nil
    if FMATraffic and FMATraffic.canStart then trafficOk,trafficWhy=FMATraffic.canStart(controller,record,target,trafficTask,60000) end
    if not trafficOk then role.state='WAIT_TRAFFIC';role.reason=trafficWhy;role.retryAt=controller.now+((controller.settings.trafficRetrySeconds or 6)*1000);return false,trafficWhy end
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=target.x,z=target.z,angle=target.angle or 0,tolerance=6,preferCourseplay=target.preferCourseplay})
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,moveWhy or 'Odvozní traktor neumí autonomní přejezd' end
    local task={id=trafficTask.id,kind='supportStage',operation='supply',label='Odvoz čeká u pole '..tostring(parent.fieldId),
        parentTaskId=parent.id,targetFieldId=parent.fieldId,slotIndex=slot,priority=(parent.priority or 90)+12,state='running',x=target.x,z=target.z,
        guidePoints=guidePoints,guideIndex=guideIndex,finalTarget=finalTarget}
    role.state='STAGING';role.record=record;role.tool=toolRecord;role.target=finalTarget or target
    role.reason=guidePoints and ('Ověřená naučená trasa · bod '..tostring(guideIndex)..'/'..tostring(#guidePoints)) or 'Přejezd na čekací místo u pole'
    controller.reservations[record.key]=task.id;record.busy=true
    controller.active[job]={job=job,task=task,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,trafficTarget=target,transferMethod=moveMethod}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;role.state='NEEDED';role.reason=tostring(err);if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(err) end
    return true,nil
end

function FMAFleetCoordinator.startStageToField(controller,parent,record,slot,toolRecord)
    if not record or not record.object then return false,'Chybí odvozní traktor' end
    if not FMAFleetCoordinator.ownCrewVehicle(controller,parent,record) then return false,'Odvozní souprava má jinou sklizňovou četu' end
    local role=supportRole(controller,parent,slot)
    if role.state=='STAGING' or role.state=='WAITING_FIELD' or role.state=='ACTIVE' or role.state=='PLAYER' then return true,nil end
    -- Physical position takes precedence over a guessed field-centre waypoint.
    -- The actual harvester may have moved hundreds of metres from field centre.
    if FMAHaulageCycle and FMAHaulageCycle.nearField then
        local group={harvester=nil,fieldId=parent.fieldId,parentTask=parent}
        for _,g in pairs(controller.workgroups or {}) do
            if g.parentTask and g.parentTask.id==parent.id then group=g;break end
        end
        if group.harvester and FMAHaulageCycle.nearField(controller,group,record) then
            role.record=record;role.tool=toolRecord;role.state='WAITING_FIELD'
            role.reason='Vozidlo už stojí vedle pracujícího kombajnu · bez dalšího přejezdu'
            controller.reservations[record.key]=roleReservationId(parent,slot);record.busy=true
            if FMADiagnostics then FMADiagnostics.event(controller,'crew.alreadyNearHarvester',parent.id,record.name) end
            return true,nil
        end
    end
    local candidates=FMAFleetCoordinator.fieldWaitingCandidates(controller,parent,record)
    if #candidates==0 then return false,'Nelze určit čekací místo odvozce u pole' end
    local from={x=record.x,z=record.z}
    local cursor=((math.max(1,tonumber(role.stageCandidateCursor) or 1)-1)%#candidates)+1
    for offset=0,#candidates-1 do
        local index=((cursor+offset-1)%#candidates)+1
        local target=candidates[index]
        local guide=FMATeach and FMATeach.routeTo and FMATeach.routeTo(controller,from,target,'POLE') or nil
        local driveTarget=guide and guide[1] or target
        -- GIANTS tries the first sweep; after exhausting independent targets
        -- use Courseplay's pathfinder with fresh destinations, not the failed goal.
        local cpSweep=(role.stageFailureCount or 0)>=#candidates
        local drive={x=driveTarget.x,z=driveTarget.z,angle=driveTarget.angle,preferCourseplay=cpSweep}
        local started,why=FMAFleetCoordinator.launchStageLeg(controller,parent,record,slot,toolRecord,drive,guide,guide and 1 or nil,target)
        if started then
            role.stageCandidateCursor=index;role.stageCandidateCount=#candidates
            controller:notify(record.name..' + '..tostring(toolRecord and toolRecord.name or 'vůz')..' jedou čekat k poli '..tostring(parent.fieldId)..(guide and ' po naučené trase' or ''))
            return true,nil
        end
        role.reason=why
    end
    role.stageCandidateCursor=(cursor%#candidates)+1
    return false,role.reason or 'AI nenašla dosažitelné čekací místo u pole'
end

function FMAFleetCoordinator.onSupportStageStopped(controller,active)
    local parent=controller.tasks[active.task.parentTaskId]
    local slot=active.task.slotIndex or 1
    if not parent then return true end
    local role=supportRole(controller,parent,slot)
    if active.stopReason or active.outcome and active.outcome~='success' then
        role.stageFailureCount=(role.stageFailureCount or 0)+1
        role.stageCandidateCursor=(tonumber(role.stageCandidateCursor) or 1)+1
        role.reason=active.stopReason or 'Přejezd odvozce k poli nebyl dokončen'
        local available=math.max(1,tonumber(role.stageCandidateCount) or #FMAFleetCoordinator.fieldWaitingCandidates(controller,parent,active.vehicle))
        -- At most two complete sweeps: native GIANTS and then Courseplay over
        -- all distinct approach points. Never retry the same invalid node blindly.
        local exhausted=role.stageFailureCount >= math.min(available*2,8)
        local circuit=FMAFleetCoordinator.noteStageRouteFailure(controller,active.vehicle,role.reason,exhausted)
        if exhausted then
            role.state='BLOCKED';role.retryAt=(circuit and circuit.retryAt) or ((controller.now or 0)+180000)
            role.reason='Vyčerpány alternativní cíle u pole ('..tostring(role.stageFailureCount)..'); změň stanoviště nebo nauč příjezd'
            controller:issue('crew:'..role.id,'Odvoz pole '..tostring(parent.fieldId),role.reason,94)
        else
            role.state='NEEDED';role.retryAt=(controller.now or 0)+1500
            if parent.state=='pending' or parent.state=='waiting' then
                parent.phase='ODVOZ · HLEDÁ OBJÍŽĎKU';parent.reason='Zkouší alternativní čekací místo '..tostring(role.stageFailureCount+1)..'/'..tostring(math.min(available*2,8))
            end
            FMADiagnostics.event(controller,'crew.reroute',role.id,'attempt='..tostring(role.stageFailureCount)..'/'..tostring(math.min(available*2,8))..' | '..tostring(role.reason))
        end
        return true
    end
    local guide=active.task.guidePoints;local index=active.task.guideIndex
    if guide and index then
        local nextIndex=index+1
        if nextIndex<=#guide then
            role.state='READY';active.vehicle.busy=false;controller.reservations[active.vehicle.key]=nil
            local ok,why=FMAFleetCoordinator.launchStageLeg(controller,parent,active.vehicle,slot,role.tool,guide[nextIndex],guide,nextIndex,active.task.finalTarget)
            if ok then return true end
            role.state='BLOCKED';role.reason=why;return true
        elseif active.task.finalTarget then
            local x,z=FMAUtil.position(active.vehicle.object);local t=active.task.finalTarget
            if x and ((x-t.x)^2+(z-t.z)^2)>7*7 then
                role.state='READY';active.vehicle.busy=false;controller.reservations[active.vehicle.key]=nil
                local ok,why=FMAFleetCoordinator.launchStageLeg(controller,parent,active.vehicle,slot,role.tool,t,nil,nil,nil)
                if ok then return true end
                role.state='BLOCKED';role.reason=why;return true
            end
        end
    end
    if controller.stageRouteFailures and active.vehicle then controller.stageRouteFailures[active.vehicle.key]=nil end
    role.stageFailureCount=0
    role.state='WAITING_FIELD';role.record=active.vehicle;role.reason='Připraven u pole'
    controller.reservations[active.vehicle.key]=roleReservationId(parent,slot);active.vehicle.busy=true
    controller:notify(active.vehicle.name..' čeká připravený u pole '..tostring(parent.fieldId))
    return true
end

function FMAFleetCoordinator.releasePreparedForWork(controller,parent,record)
    local roles=controller.preparedSupport and controller.preparedSupport[parent.id]
    if not roles then return end
    for _,role in pairs(roles) do
        if role.record and role.record.key==record.key then
            controller.reservations[record.key]=nil;record.busy=false;role.state='ACTIVE';role.reason='Přidělen ke sklizni'
            if controller.traffic then FMATraffic.release(controller.traffic,record.key) end
            return
        end
    end
end

-- A support truck must not starve the MAIN harvesting machine while it still
-- needs its cutter picked up. This is a prerequisite check, not a promise that
-- GIANTS can route to the cutter: attachment and physical navigation remain
-- separately confirmed by the actual engine.
function FMAFleetCoordinator.mainHarvesterReady(controller,task)
    if not task or task.operation~='harvest' then return true end
    -- Transport-ready combine + carrier + cutter is a valid MAIN harvesting asset even
    -- before the cutter is mechanically attached to the combine. Support staging may
    -- proceed, but fieldwork still waits for the header workflow to attach and confirm it.
    if controller and controller.settings and controller.settings.headerTransport
        and FMAHeaderTransport and FMAHeaderTransport.preloadedChain
        and FMAHeaderTransport.preloadedChain(controller,task) then return true end
    for _,v in ipairs(controller.vehicles or {}) do
        local pinned=task.preferredVehicleKey==nil or task.preferredVehicleKey==v.key
        local fruitOk=task.fruitIndex==nil or (v.harvestFruits and v.harvestFruits[task.fruitIndex]==true)
        if pinned and fruitOk and v.isGrainCombine and v.capabilities and v.capabilities.harvest
            and not v.busy and not v.lowFuel and not (controller.excluded and controller.excluded[v.key])
            and not (controller.reservations and controller.reservations[v.key]) then return true end
    end
    return false
end

function FMAFleetCoordinator.preparePendingHarvestCrew(controller,parent,slot)
    if not controller.settings.harvestTeams or not parent or parent.kind~='field' then return false,nil end
    if controller.settings.selectedJobsOnly and parent.ownerApproved~=true then return false,'Zakázka nebyla schválena' end
    if parent.operation~='harvest' and parent.operation~='foragePickup' then return false,nil end
    slot=math.max(1,tonumber(slot) or 1);local role=supportRole(controller,parent,slot)
    if role.state=='ASSEMBLING' or role.state=='STAGING' or role.state=='WAITING_FIELD' or role.state=='ACTIVE' or role.state=='PLAYER' then return false,nil end
    if (role.state=='BLOCKED' or role.state=='WAIT_TRAFFIC') and (role.retryAt or 0)>controller.now then return false,role.reason end
    if role.state=='WAIT_TRAFFIC' and (role.retryAt or 0)<=controller.now then role.state='NEEDED' end
    if role.state=='BLOCKED' and (role.retryAt or 0)<=controller.now then role.state='NEEDED' end
    local fillType=FMAFleetCoordinator.transportFillType(parent)
    local ready=FMAFleetCoordinator.freeTransporters(controller,fillType)
    for _,record in ipairs(ready) do
        if FMAFleetCoordinator.transporterMatchesSelection(parent,record,slot) and FMAFleetCoordinator.ownCrewVehicle(controller,parent,record) then
            local cooling=FMAFleetCoordinator.roadBackoff(controller,record)
            if cooling then return false,'Odvozní traktor čeká po chybných cílech AI' end
            role.record=record;role.state='READY';role.reason='Hotová odvozní souprava nalezena'
            local started,why=FMAFleetCoordinator.startStageToField(controller,parent,record,slot,nil)
            if started then return true,nil end
            role.state='BLOCKED';role.reason=why;role.retryAt=controller.now+15000;return false,why
        end
    end
    local started,why=FMAFleetCoordinator.startTransportAssembly(controller,parent,nil,fillType,slot,true)
    if started then role.state='ASSEMBLING';role.reason='Traktor jede pro odvozní vůz';return true,nil end
    role.state='BLOCKED';role.reason=why;role.retryAt=controller.now+30000
    return false,why
end

function FMAFleetCoordinator.planHarvestTeams(controller)
    controller.workgroups=controller.workgroups or {}
    controller.crewAssignments=controller.crewAssignments or {}
    local nextGroups,represented={},{}

    local function buildGroup(task,harvester,job,crew)
        local field=controller.fieldsById[task.fieldId]
        local fruit=field and FMAUtil.call(g_fruitTypeManager,'getFruitTypeByIndex',field.fruitIndex)
        local fillType=task.expectedFillType or (fruit and (fruit.fillTypeIndex or fruit.fillType))
        if harvester.isForageHarvester and FillType and FillType.CHAFF then fillType=FillType.CHAFF end
        local telemetry=controller.harvestTelemetry and controller.harvestTelemetry[harvester.key] or {}
        local transporters=FMAFleetCoordinator.freeTransporters(controller,fillType)
        local averageCap=transporters[1] and math.max(1,transporters[1].capacity or 1) or 1
        local tripSeconds=controller.settings.defaultHaulCycleSeconds or 360
        local count=FMAFleetCoordinator.requiredUnloaders(telemetry.rate or 0,tripSeconds,averageCap,controller.settings.maxUnloaders or 3)
        if (telemetry.capacity or 0)<100 then count=math.max(1,count) end
        local hx,hz=FMAUtil.position(harvester.object);harvester.x=hx or harvester.x;harvester.z=hz or harvester.z
        local state=job and 'ACTIVE' or FMAFleetCoordinator.operatorMode(harvester)
        if state=='IDLE' then state=string.upper(tostring(task.state or 'WAIT')) end
        local group={id=crew.id,fieldId=task.fieldId,harvester=harvester,job=job,fillType=fillType,required=count,unloaders={},state=state,parentTask=task,operatorMode=FMAFleetCoordinator.operatorMode(harvester)}
        local persisted,present=crewUnloaderRecords(controller,crew)
        for _,u in ipairs(persisted) do
            if FMAFleetCoordinator.ownCrewVehicle(controller,task,u) then group.unloaders[#group.unloaders+1]=u end
        end

        -- Running support stays in the same persistent crew even when control of another
        -- member changes hands between FarmManager, player, native FS AI and Courseplay.
        for _,running in pairs(controller.active or {}) do
            if running.task and running.task.kind=='support' and running.task.harvesterKey==harvester.key and running.vehicle and not present[running.vehicle.key] then
                group.unloaders[#group.unloaders+1]=running.vehicle;present[running.vehicle.key]=true
            end
        end
        local prepared=controller.preparedSupport and controller.preparedSupport[task.id]
        if prepared then
            for slot=1,(controller.settings.maxUnloaders or 3) do
                local role=prepared[slot]
                if role and role.record and not present[role.record.key] and (role.state=='ASSEMBLING' or role.state=='READY' or role.state=='STAGING' or role.state=='WAITING_FIELD' or role.state=='ACTIVE' or role.state=='PLAYER' or role.state=='PAUSED') then
                    group.unloaders[#group.unloaders+1]=role.record;present[role.record.key]=true
                end
            end
        end
        -- Owner selections first, then free AUTO candidates. Persist selected keys so a
        -- later manual takeover does not make the dispatcher invent a replacement crew.
        for slot=1,(controller.settings.maxUnloaders or 3) do
            if #group.unloaders>=count then break end
            local hasChoice=(task.preferredSupportKeys and task.preferredSupportKeys[slot]) or (task.preferredSupportToolKeys and task.preferredSupportToolKeys[slot])
            if hasChoice then
                for _,u in ipairs(transporters) do
                    if not present[u.key] and FMAFleetCoordinator.transporterMatchesSelection(task,u,slot) then
                        group.unloaders[#group.unloaders+1]=u;present[u.key]=true;break
                    end
                end
            end
        end
        for _,u in ipairs(transporters) do
            if #group.unloaders>=count then break end
            if not present[u.key] and FMAFleetCoordinator.ownCrewVehicle(controller,task,u) then group.unloaders[#group.unloaders+1]=u;present[u.key]=true end
        end
        crew.required=count;crew.fillType=fillType;crew.updatedAt=controller.now or 0;crew.taskRef=task
        for _,u in ipairs(group.unloaders) do FMAFleetCoordinator.rememberCrewUnloader(controller,group,u) end
        return group
    end

    -- First refresh crews with actively managed harvest jobs.
    for job,a in pairs(controller.active or {}) do
        if a.task and a.task.kind=='field' and (a.task.operation=='harvest' or (a.task.operation=='foragePickup' and a.vehicle and a.vehicle.hasCombine)) then
            local crew=FMAFleetCoordinator.registerCrew(controller,a.task,a.vehicle,job)
            local group=buildGroup(a.task,a.vehicle,job,crew)
            nextGroups[group.id]=group;represented[group.id]=true
        end
    end

    -- Then keep existing crews alive independently of the AI job. This is the critical
    -- human-in-the-loop behavior: taking the combine or an unloader manually must not
    -- dissolve the team, and starting H/CP again must not create duplicate members.
    local remove={}
    for id,crew in pairs(controller.crewAssignments or {}) do
        if not represented[id] then
            local task=(controller.tasks and controller.tasks[crew.taskId]) or crew.taskRef
            local harvester=controller.vehicleByKey and controller.vehicleByKey[crew.harvesterKey]
            local finished=not task or task.state=='done' or task.state=='cancelled'
            local ownerHeld=task and (task.ownerStopRequested==true
                or (controller.settings.selectedJobsOnly and task.ownerApproved~=true))
            if finished or not harvester then
                remove[#remove+1]=id
            elseif ownerHeld then
                -- STOP pauses the whole crew but keeps its actual tractor/trailer
                -- identities. The next explicit START revives that SAME team.
                crew.pausedByOwner=true;crew.updatedAt=controller.now or 0
            elseif task.operation=='harvest' or task.operation=='foragePickup' then
                crew.pausedByOwner=nil
                local group=buildGroup(task,harvester,nil,crew)
                nextGroups[id]=group
            end
        end
    end
    for _,id in ipairs(remove) do controller.crewAssignments[id]=nil end

    for id,group in pairs(nextGroups) do
        if #group.unloaders<group.required then
            controller:issue('team:'..id,'Sklizňová skupina · chybí odvoz',
                'Potřeba '..group.required..' odvozce/ů, v četě '..#group.unloaders..'. Četa zůstává zachována i při ručním převzetí člena.',92)
        end
    end
    controller.workgroups=nextGroups
end

function FMAFleetCoordinator.hasSupportForGroup(controller,groupId)
    for _,a in pairs(controller.active or {}) do if a.task and a.task.kind=='support' and a.task.parentGroup==groupId then return true end end
    return false
end

function FMAFleetCoordinator.dispatchSupport(controller)
    if not controller.settings.enabled or not controller.settings.harvestTeams or not FMACourseplay.available() then return false end
    for _,group in pairs(controller.workgroups or {}) do
        if FMAHaulageCycle and FMAHaulageCycle.harvesterWorking(group) and
            (not group.harvester.isForageHarvester) and
            (not controller.settings.selectedJobsOnly or
            (group.parentTask and group.parentTask.ownerApproved==true)) then
            local tele=controller.harvestTelemetry and controller.harvestTelemetry[group.harvester.key] or {}
            local capacity=tele.capacity or 0
            local ratio=capacity>0 and (tele.fill or 0)/capacity or 1
            local first=group.unloaders[1]
            if not first and group.parentTask then
                local started=FMAFleetCoordinator.startTransportAssembly(controller,group.parentTask,group.harvester,group.fillType,1)
                if started then return true end
            end
            if first then
                local distance=FMAUtil.distance(first,group.harvester)
                -- Register Courseplay's unloader strategy BEFORE the combine reaches 80 %.
                -- Courseplay owns the actual 80 % rendezvous. Until its worker is
                -- registered the combine only reports 'no idle unloader found'.
                local call=group.harvester.isForageHarvester or FMAHaulageCycle.harvesterWorking(group)
                if call then
                    local destination=nil
                    local forageToBunker=group.harvester and group.harvester.isForageHarvester and controller.settings.bunkerAutomation and controller.settings.bunkerDeliveryAutomation
                    if group.fillType and not forageToBunker then destination=select(1,FMALogistics.bestDestination(controller.farmId,nil,group.fillType,controller.settings.autoSellOutputs==true)) end
                    if not destination and not forageToBunker then
                        controller:issue('crewDestination:'..group.id,'Odvoz sklizně bez cíle','Není ověřené vlastní silo pro materiál; prodej vyžaduje schválení.',88)
                        return false
                    end
                    for i,record in ipairs(group.unloaders) do
                        if FMAUtil.count(controller.reservations)>=controller.settings.maxWorkers then break end
                        local preparedRole=nil
                        local roles=controller.preparedSupport and controller.preparedSupport[group.parentTask.id]
                        if roles then for _,r in pairs(roles) do if r.record and r.record.key==record.key and r.state=='WAITING_FIELD' then preparedRole=r;break end end end
                        local cycling=controller.haulageCycles and controller.haulageCycles[record.key]
                        local available=not cycling and ((not controller.reservations[record.key] and not record.busy) or preparedRole~=nil)
                        if available and not (FMAGameNative and FMAGameNative.isManuallyControlled(record.object)) and FMAJobs.mayStart(controller,'support:'..group.id..':'..record.key) then
                            local near=FMAHaulageCycle.nearField(controller,group,record)
                            if not near then
                                -- Courseplay rejects start when unloader is far from the
                                -- field. Physically stage it first; do not poison the CP job.
                                if preparedRole then preparedRole.state='READY' end
                                local staged,why=FMAFleetCoordinator.startStageToField(controller,group.parentTask,record,i,preparedRole and preparedRole.tool)
                                if not staged and controller.issue then
                                    controller:issue('crewApproach:'..group.id,'Odvoz se přistavuje',tostring(why),80)
                                end
                                return staged
                            end
                            if preparedRole then FMAFleetCoordinator.releasePreparedForWork(controller,group.parentTask,record) end
                            local task={id='support:'..group.id..':'..record.key,kind='support',operation='supply',parentGroup=group.id,
                                label='Odvoz '..group.fieldId..' #'..i,state='running',priority=91,attempts=1,x=group.harvester.x,z=group.harvester.z,harvesterKey=group.harvester.key,fieldId=group.fieldId,fillType=group.fillType,forageBunker=forageToBunker==true}
                            if controller.supportAttachmentByVehicle then task.managedAttachment=controller.supportAttachmentByVehicle[record.key] end
                            local field=controller.fieldsById[group.fieldId]
                            local job,why,waiting=FMACourseplay.startCombineUnloader(controller,record,field or {x=group.harvester.x,z=group.harvester.z},destination,forageToBunker)
                            if job then
                                controller.reservations[record.key]=task.id;record.busy=true
                                controller.active[job]={job=job,task=task,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,
                                    startPendingUnloader=job.fmaCourseplayPublicStart==true}
                                FMAFleetCoordinator.rememberCrewUnloader(controller,group,record)
                                controller:notify('Odvozce '..record.name..' přidělen ke sklizni pole '..group.fieldId)
                            else
                                if not waiting then FMAJobs.fail(controller,task,record,why) end
                            end
                        end
                    end
                    return true
                end
            end
        end
    end
    return false
end


local function transportCargo(record,expectedFillType)
    local level,capacity=0,0
    if not record or not record.object then return 0,0 end
    for _,o in ipairs(FMAWorld.children(record.object)) do
        local units=FMAUtil.call(o,'getFillUnits') or (o.spec_fillUnit and o.spec_fillUnit.fillUnits) or {}
        for i,_ in pairs(units) do
            local ft=FMAUtil.call(o,'getFillUnitFillType',i)
            local l=FMAUtil.call(o,'getFillUnitFillLevel',i) or 0
            local supports=expectedFillType==nil or ft==expectedFillType or FMAUtil.call(o,'getFillUnitSupportsFillType',i,expectedFillType)==true
            if supports and (not FillType or ft~=FillType.DIESEL) then
                level=level+l
                capacity=capacity+(FMAUtil.call(o,'getFillUnitCapacity',i) or (units[i] and units[i].capacity) or 0)
            end
        end
    end
    return level,capacity
end

function FMAFleetCoordinator.updateSupport(controller)
    -- Full forage trailers waiting for the single-lane bunker entrance stay reserved
    -- and are retried instead of being accidentally sent back to the chopper full.
    controller.forageBunkerWaits=controller.forageBunkerWaits or {}
    for key,w in pairs(controller.forageBunkerWaits) do
        if (w.retryAt or 0)<=controller.now then
            controller.forageBunkerWaits[key]=nil
            local record=w.active and w.active.vehicle
            if record then controller.reservations[key]=nil;record.busy=false end
            local expired=controller.now-(w.started or controller.now)>300000
            local ok,why
            if expired then
                if record then FMAJobs.fail(controller,w.active.task,record,'Čekání s plným vozem na jámu překročilo 5 minut');FMATraffic.release(controller.traffic,key) end
                ok=true
            else ok,why=FMABunkerCoordinator.beginSupportDelivery(controller,w.active,w.fillType) end
            if not ok and record then
                controller.forageBunkerWaits[key]={active=w.active,fillType=w.fillType,started=w.started or controller.now,retryAt=controller.now+((controller.settings.trafficRetrySeconds or 6)*1000),reason=why}
                controller.reservations[key]='bunkerWait:'..key;record.busy=true
            end
        end
    end
    -- Forage trailers are not sent to a normal sell/storage station. Once almost
    -- full, the CP escort is stopped cleanly and the bunker coordinator takes over
    -- the physical trip, entry, unloading and exit. Another free escort can then
    -- be assigned to the chopper while this one is away.
    for job,a in pairs(controller.active or {}) do
        if a.task and a.task.kind=='support' and a.task.forageBunker and not a.bunkerRequested then
            local level,capacity=transportCargo(a.vehicle,a.task.fillType)
            a.task.cargoLevel=level;a.task.cargoCapacity=capacity
            local ratio=capacity>1 and level/capacity or 0
            local leaveAt=math.max(0.80,math.min(0.96,(controller.settings.unloaderCall or 0.80)+0.08))
            if ratio>=leaveAt then
                a.bunkerRequested=true;a.task.phase='ODJEZD DO SILÁŽNÍ JÁMY';a.task.reason='Náklad '..math.floor(ratio*100)..' %'
                FMAUtil.log('SILÁŽNÍ LINKA: '..tostring(a.vehicle.name)..' odjíždí od řezačky s '..math.floor(ratio*100)..' %')
                FMAAI.stop(job)
                return true
            end
        end
    end
    return false
end

function FMAFleetCoordinator.onSupportStopped(controller,active)
    if not active or not active.task or active.task.kind~='support' then return false end
    if not active.task.forageBunker and FMAHaulageCycle then
        if FMAHaulageCycle.queue(controller,active) then return true end
        -- A stopped helper with an empty trailer is NOT completion of a harvest.
        -- Keep the crew and let dispatch reacquire the helper if harvest continues.
        active.task.state='waiting';active.task.phase='ODVOZ · ČEKÁ NA KOMBAJN'
        return true
    end
    if active.stopReason and not active.bunkerRequested then return false end
    if active.task.forageBunker and (active.bunkerRequested or (active.task.cargoLevel or 0)>1) and FMABunkerCoordinator then
        local level,capacity=transportCargo(active.vehicle,active.task.fillType)
        local ratio=capacity>1 and level/capacity or 0
        if level>1 and (active.bunkerRequested or ratio>=0.50) then
            local ok,why=FMABunkerCoordinator.beginSupportDelivery(controller,active,active.task.fillType)
            if ok then return true end
            controller.forageBunkerWaits=controller.forageBunkerWaits or {}
            controller.forageBunkerWaits[active.vehicle.key]={active=active,fillType=active.task.fillType,started=controller.now,retryAt=(controller.now or 0)+((controller.settings.trafficRetrySeconds or 6)*1000),reason=why}
            controller.reservations[active.vehicle.key]='bunkerWait:'..active.vehicle.key;active.vehicle.busy=true
            active.task.state='waiting';active.task.phase='ČEKÁ NA VJEZD DO JÁMY';active.task.reason=tostring(why or 'Čeká na silážní jámu')
            controller:notify(active.vehicle.name..' čeká s plným vozem na uvolnění silážní jámy')
            return true
        end
    end
    return false
end

-- Assemble a detached trailer behind a free tractor before harvesting starts.
-- This is separate from the field implement assembler because the harvester remains
-- the parent job while the transporter is only a supporting member of the team.
function FMAFleetCoordinator.transportFillType(task)
    if not task then return nil end
    if task.expectedFillType then return task.expectedFillType end
    if not task.fruitIndex then return nil end
    local fruit=FMAUtil.call(g_fruitTypeManager,'getFruitTypeByIndex',task.fruitIndex)
    return fruit and (fruit.fillTypeIndex or fruit.fillType) or nil
end

function FMAFleetCoordinator.transporterMatchesSelection(parent,record,slotIndex)
    if not parent or not record then return false end
    local wantedPower=parent.preferredSupportKeys and parent.preferredSupportKeys[slotIndex]
    local wantedTool=parent.preferredSupportToolKeys and parent.preferredSupportToolKeys[slotIndex]
    if wantedPower and record.key~=wantedPower then return false end
    if wantedTool then
        local found=false
        for _,object in ipairs(FMAWorld.children(record.object)) do
            if FMAWorld.vehicleKey(object)==wantedTool then found=true;break end
        end
        if not found then return false end
    end
    return true
end

function FMAFleetCoordinator.rememberPreparedSupport(controller,parent,plan)
    if not plan or not plan.power or not plan.tool then return end
    controller.supportAttachmentByVehicle=controller.supportAttachmentByVehicle or {}
    controller.supportAttachmentByVehicle[plan.power.key]={toolKey=plan.tool.key,toolName=plan.tool.name,toolObject=plan.tool.object,powerKey=plan.power.key,
        toolHome=controller.toolHomes and controller.toolHomes[plan.tool.key],staging=FMAAssembler.approachPoint(plan.power,plan.tool,controller.settings)}
    local i=plan.slotIndex or 1
    parent.preferredSupportKeys=parent.preferredSupportKeys or {};parent.preferredSupportNames=parent.preferredSupportNames or {}
    parent.preferredSupportKeys[i]=plan.power.key;parent.preferredSupportNames[i]=plan.power.name
    parent.preferredSupportToolKeys=parent.preferredSupportToolKeys or {};parent.preferredSupportToolNames=parent.preferredSupportToolNames or {}
    parent.preferredSupportToolKeys[i]=plan.tool.key;parent.preferredSupportToolNames[i]=plan.tool.name
end

function FMAFleetCoordinator.hasTransportPotential(controller,parent,fillType,slotIndex)
    slotIndex=slotIndex or 1
    local wantedPower=parent and parent.preferredSupportKeys and parent.preferredSupportKeys[slotIndex]
    local wantedTool=parent and parent.preferredSupportToolKeys and parent.preferredSupportToolKeys[slotIndex]
    -- Already assembled transport counts even when currently busy/reserved. Procurement
    -- must distinguish WAITING from genuinely missing equipment.
    for _,record in ipairs(controller.vehicles or {}) do
        if (wantedPower==nil or record.key==wantedPower) and record.capabilities and record.capabilities.transport
            and FMAFleetCoordinator.supportsTransportFillType(record,fillType) then
            if wantedTool==nil or FMAFleetCoordinator.transporterMatchesSelection(parent,record,slotIndex) then return true,record,nil,'assembled' end
        end
    end
    for _,tool in ipairs(controller.loose or {}) do
        if tool.capabilities and tool.capabilities.transport and FMAFleetCoordinator.supportsTransportFillType(tool,fillType)
            and (wantedTool==nil or wantedTool==tool.key) then
            for _,power in ipairs(controller.vehicles or {}) do
                if not power.hasCombine and power.hasAttacherJoints and (wantedPower==nil or wantedPower==power.key)
                    and FMAAssembler.findJointPair(power.object,tool.object,controller.farmId) then
                    return true,power,tool,'assembly'
                end
            end
        end
    end
    return false,nil,nil,'missing'
end

function FMAFleetCoordinator.previewTransport(controller,parent,slotIndex)
    local fillType=FMAFleetCoordinator.transportFillType(parent)
    local ready=FMAFleetCoordinator.freeTransporters(controller,fillType)
    for _,record in ipairs(ready) do
        if FMAFleetCoordinator.transporterMatchesSelection(parent,record,slotIndex or 1) then
            return {state='READY',vehicle=record,tool=nil,reason='Hotová odvozní souprava'}
        end
    end
    local plan=FMAFleetCoordinator.findTransportAssembly(controller,parent,fillType,slotIndex or 1)
    if plan then return {state='ASSEMBLE',vehicle=plan.power,tool=plan.tool,reason='Lze sestavit z vlastní techniky'} end
    local exists,power,tool=FMAFleetCoordinator.hasTransportPotential(controller,parent,fillType,slotIndex or 1)
    if exists then return {state='WAIT',vehicle=power,tool=tool,reason='Vlastní odvoz existuje, ale je právě obsazený / rezervovaný'} end
    return {state='MISSING',reason='Chybí kompatibilní traktor + odvozní vůz'}
end

function FMAFleetCoordinator.findTransportAssembly(controller,parent,fillType,slotIndex)
    slotIndex=slotIndex or 1
    local wantedPower=parent.preferredSupportKeys and parent.preferredSupportKeys[slotIndex]
    local wantedTool=parent.preferredSupportToolKeys and parent.preferredSupportToolKeys[slotIndex]
    local best,bestScore
    local audit={}
    parent.supportSelectionAudit=parent.supportSelectionAudit or {};parent.supportSelectionAudit[slotIndex]=audit
    local function note(name,key,ok,reason,score)
        if #audit<30 then audit[#audit+1]={name=name,key=key,ok=ok,reason=reason,score=score} end
    end
    for _,tool in ipairs(controller.loose or {}) do
        if tool.capabilities and tool.capabilities.transport then
            local fillOk=FMAFleetCoordinator.supportsTransportFillType(tool,fillType)
            if controller.implementReservations[tool.key] then
                note(tool.name,tool.key,false,'vůz rezervovaný pro jinou práci')
            elseif not fillOk then
                note(tool.name,tool.key,false,'náklad / fillType nepotvrzen jako kompatibilní')
            elseif wantedTool~=nil and wantedTool~=tool.key then
                note(tool.name,tool.key,false,'majitel vybral jiný vůz')
            else
                local paired=false
                for _,power in ipairs(controller.vehicles or {}) do
                    local reason=nil
                    if power.hasCombine then reason='není tahač'
                    elseif not power.hasAttacherJoints then reason='nemá použitelný závěs'
                    elseif power.busy then reason='obsazený'
                    elseif power.lowFuel then reason='málo paliva'
                    elseif controller.excluded[power.key] then reason='vyloučený majitelem'
                    elseif controller.reservations[power.key] then reason='rezervovaný pro jinou práci'
                    elseif parent.failedVehicleKeys and parent.failedVehicleKeys[power.key] then reason='vyřazen po neúspěšném nájezdu'
                    elseif wantedPower~=nil and wantedPower~=power.key then reason='majitel vybral jiný tahač'
                    end
                    if not reason then
                        local jointIndex,inputIndex,joint,input=FMAAssembler.findJointPair(power.object,tool.object,controller.farmId)
                        if jointIndex then
                            paired=true
                            local score=FMAUtil.distance(power,tool)+(power.damage or 0)*70+(power.wear or 0)*20
                            local vt=string.lower(tostring(power.vehicleTypeName or ''))
                            if vt:find('telehandler',1,true) or vt:find('loader',1,true) or vt:find('skid',1,true) then score=score+250 end
                            if vt:find('tractor',1,true) then score=score-30 end
                            local hp=tonumber(power.powerHP) or 0
                            if hp>0 then score=score+math.abs(math.min(hp,450)-220)*0.03 end
                            note(power.name..' + '..tool.name,power.key..'+'..tool.key,true,'kompatibilní odvozní souprava',score)
                            if not best or score<bestScore then best={power=power,tool=tool,jointIndex=jointIndex,inputIndex=inputIndex,joint=joint,input=input,slotIndex=slotIndex};bestScore=score end
                        else
                            note(power.name..' + '..tool.name,power.key..'+'..tool.key,false,'závěsy nejsou kompatibilní')
                        end
                    else
                        note(power.name..' + '..tool.name,power.key..'+'..tool.key,false,reason)
                    end
                end
                if not paired and #(controller.vehicles or {})==0 then note(tool.name,tool.key,false,'není dostupný tahač') end
            end
        end
    end
    return best
end

function FMAFleetCoordinator.startTransportAssembly(controller,parent,harvester,fillType,slotIndex,independent)
    local plan=FMAFleetCoordinator.findTransportAssembly(controller,parent,fillType,slotIndex or 1)
    if not plan then return false,"Chybí volný kompatibilní traktor + odvozní vůz pro sklizňovou skupinu" end
    local role=independent and supportRole(controller,parent,slotIndex or 1) or nil
    if role then role.record=plan.power;role.tool=plan.tool;role.state='ASSEMBLING';role.reason='Traktor jede pro odvozní vůz' end
    FMAReturnManager.captureHomes(controller)
    local function rememberAndStage()
        FMAFleetCoordinator.rememberPreparedSupport(controller,parent,plan)
        if independent then
            role.state='READY';role.reason='Odvozní vůz zapřažen'
            local started,why=FMAFleetCoordinator.startStageToField(controller,parent,plan.power,slotIndex or 1,plan.tool)
            if not started then role.state='BLOCKED';role.reason=why;role.retryAt=controller.now+15000 end
        end
    end
    if FMAUtil.distance(plan.power,plan.tool)<=(controller.settings.autoAttachMaxDistance or 6) then
        local ok,why=FMAAssembler.attach(controller,plan)
        if ok then
            local function failed(reason)
                if independent then role.state='BLOCKED';role.reason=tostring(reason);role.retryAt=controller.now+15000 end
            end
            FMAAssembler.confirm(controller,parent,plan,rememberAndStage,independent,independent and role.id or nil,failed);return true
        end
        FMAUtil.log("Odvozní vůz nebyl připojen napoprvé: "..tostring(why))
    end
    parent.supportAssemblyAttempts=parent.supportAssemblyAttempts or {}
    local supportAttempt=math.max(1,tonumber(parent.supportAssemblyAttempts[slotIndex or 1]) or 1)
    local point=FMAAssembler.approachPoint(plan.power,plan.tool,controller.settings,plan,supportAttempt);if not point then return false,"Nelze určit polohu odvozního vozu" end
    local trafficTask={id='unloaderAssemble:'..parent.id..':'..plan.power.key,kind='unloaderAssemble',operation='supply',parentTaskId=parent.id}
    if FMATraffic and FMATraffic.canStart then
        local free,wait=FMATraffic.canStart(controller,plan.power,point,trafficTask,30000)
        if not free then
            if independent then role.state='WAIT_TRAFFIC';role.reason=wait;role.retryAt=controller.now+((controller.settings.trafficRetrySeconds or 6)*1000)
            else parent.state='pending';parent.phase='ČEKÁ NA PROVOZ';parent.reason=wait;parent.retryAt=controller.now+((controller.settings.trafficRetrySeconds or 6)*1000) end
            return true,wait
        end
    end
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,plan.power,{x=point.x,z=point.z,angle=point.angle or 0,tolerance=4})
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end;return false,moveWhy or "Odvozní traktor neumí dojet k vozu" end
    local task={id='unloaderAssemble:'..parent.id..':'..plan.power.key,kind='unloaderAssemble',operation='supply',label='Příprava odvozu · '..plan.power.name,
        parentTaskId=parent.id,harvesterKey=harvester and harvester.key,slotIndex=slotIndex or 1,independent=independent==true,priority=(parent.priority or 90)+11,state='running',assemblyAttempt=supportAttempt}
    if not independent then parent.state='assembling';parent.reason='Příprava odvozní soupravy '..plan.power.name..' + '..plan.tool.name end
    controller.reservations[plan.power.key]=task.id;controller.implementReservations[plan.tool.key]=task.id;plan.power.busy=true
    controller.active[job]={job=job,task=task,vehicle=plan.power,transportAssemblyPlan=plan,start=controller.now,lastProgress=controller.now,x=plan.power.x,z=plan.power.z,fill=plan.power.fillTotal,transferMethod=moveMethod,trafficTarget=point}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then
        controller.active[job]=nil;controller.reservations[plan.power.key]=nil;controller.implementReservations[plan.tool.key]=nil;plan.power.busy=false
        if independent then role.state='BLOCKED';role.reason=tostring(err);role.retryAt=controller.now+15000 else parent.state='pending' end
        if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end;return false,tostring(err)
    end
    controller:notify(plan.power.name..' jede pro odvozní vůz '..plan.tool.name)
    return true
end

function FMAFleetCoordinator.onTransportAssemblyStopped(controller,active,message)
    local plan=active.transportAssemblyPlan;local parent=controller.tasks[active.task.parentTaskId]
    if plan then controller.implementReservations[plan.tool.key]=nil end
    if not parent or not plan then return end
    if active.stopReason then
        if active.task.independent then
            local role=supportRole(controller,parent,active.task.slotIndex or plan.slotIndex or 1)
            role.state='BLOCKED';role.reason=active.stopReason;role.retryAt=controller.now+15000
            controller:issue('crew:'..role.id,'Odvoz pole '..tostring(parent.fieldId),role.reason,96)
        else parent.state='blocked';parent.reason=active.stopReason end
        return
    end
    local ok,why=FMAAssembler.attach(controller,plan)
    if ok then
        local independent=active.task.independent==true
        local role=independent and supportRole(controller,parent,active.task.slotIndex or plan.slotIndex or 1) or nil
        FMAAssembler.confirm(controller,parent,plan,function()
            FMAReturnManager.captureHomes(controller)
            FMAFleetCoordinator.rememberPreparedSupport(controller,parent,plan)
            if independent then
                role.state='READY';role.record=plan.power;role.tool=plan.tool;role.reason='Odvozní vůz zapřažen'
                local started,stageWhy=FMAFleetCoordinator.startStageToField(controller,parent,plan.power,active.task.slotIndex or plan.slotIndex or 1,plan.tool)
                if not started then role.state='BLOCKED';role.reason=stageWhy;role.retryAt=controller.now+15000 end
            end
        end,independent,independent and role.id or nil,function(reason)
            if independent then role.state='BLOCKED';role.reason=tostring(reason);role.retryAt=controller.now+15000 end
        end)
    else
        local slot=active.task.slotIndex or plan.slotIndex or 1
        parent.supportAssemblyAttempts=parent.supportAssemblyAttempts or {}
        parent.supportAssemblyAttempts[slot]=(active.task.assemblyAttempt or parent.supportAssemblyAttempts[slot] or 1)+1
        if active.task.independent then
            local role=supportRole(controller,parent,slot)
            role.state='BLOCKED';role.reason='Příprava odvozu selhala: '..tostring(why)..' · další nájezd '..tostring(parent.supportAssemblyAttempts[slot]);role.retryAt=controller.now+5000
            controller:issue('crew:'..role.id,'Odvoz pole '..tostring(parent.fieldId),role.reason,96)
        else
            parent.state='blocked';parent.reason='Příprava odvozu selhala: '..tostring(why);controller:issue(parent.id,parent.label,parent.reason,96)
        end
    end
end

function FMAFleetCoordinator.preflightHarvest(controller,parent,harvester)
    if not controller.settings.harvestTeams or (parent.operation~='harvest' and parent.operation~='foragePickup') then return false,nil end
    FMAFleetCoordinator.registerCrew(controller,parent,harvester,nil)
    local prepared=FMAFleetCoordinator.getPreparedRole(controller,parent,1)
    if prepared then
        if prepared.state=='WAITING_FIELD' or prepared.state=='ACTIVE' or prepared.state=='PLAYER' then return false,nil end
        if prepared.state=='ASSEMBLING' or prepared.state=='READY' or prepared.state=='STAGING' or prepared.state=='WAIT_TRAFFIC' then
            -- Grain combine has its own tank and may start while the faster haulage
            -- unit is still approaching. A forage harvester must wait for an escort.
            if harvester and harvester.isForageHarvester then return true,nil end
            return false,nil
        end
        if prepared.state=='BLOCKED' then
            -- A grain combine has its own tank. Missing/failed haulage is an operational
            -- warning, not a reason to keep the combine parked forever. A forage harvester
            -- has no buffer and therefore still requires its escort before starting.
            if harvester and harvester.isForageHarvester then return false,prepared.reason or 'Odvozní četa není připravena' end
            return false,nil
        end
    end
    local fillType=harvester.isForageHarvester and FillType and FillType.CHAFF or FMAFleetCoordinator.transportFillType(parent)
    local ready=FMAFleetCoordinator.freeTransporters(controller,fillType)
    for _,record in ipairs(ready) do
        if FMAFleetCoordinator.transporterMatchesSelection(parent,record,1) then return false,nil end
    end
    -- No ready selected/AUTO transport: physically build tractor + trailer before the harvester leaves.
    local started,why=FMAFleetCoordinator.startTransportAssembly(controller,parent,harvester,fillType,1)
    if started then return true,nil end
    if #ready>0 and not ((parent.preferredSupportKeys and parent.preferredSupportKeys[1]) or (parent.preferredSupportToolKeys and parent.preferredSupportToolKeys[1])) then
        return false,nil
    end
    if harvester and not harvester.isForageHarvester then
        controller:issue('harvestHaulage:'..tostring(parent.id),parent.label..' · odvoz zatím není připraven',
            tostring(why or 'Kombajn zahájí sklizeň a při naplnění zásobníku počká na odvoz.'),70)
        return false,nil
    end
    return false,why or 'Před sklizní není připraven vhodný traktor s odvozním vozem'
end


function FMAFleetCoordinator.cancelWaits(controller)
    for key,w in pairs(controller.forageBunkerWaits or {}) do
        local record=w.active and w.active.vehicle
        if record then record.busy=false;controller.reservations[key]=nil;if controller.traffic then FMATraffic.release(controller.traffic,key) end end
        controller.forageBunkerWaits[key]=nil
    end
    for taskId,roles in pairs(controller.preparedSupport or {}) do
        for _,role in pairs(roles) do
            if role.record then
                controller.reservations[role.record.key]=nil;role.record.busy=false
                if controller.traffic then FMATraffic.release(controller.traffic,role.record.key) end
            end
            role.state='PAUSED';role.reason='Automatika vypnuta majitelem'
        end
    end
end
