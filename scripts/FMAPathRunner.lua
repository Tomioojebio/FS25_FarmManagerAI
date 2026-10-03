-- Deterministic, verified multi-leg transit on paths physically observed in this
-- savegame.  This is NOT a navmesh generator and never steers/teleports vehicles.
-- GIANTS or CP executes each short leg; the Farm Manager advances only after
-- an engine-success stop AND an actual position check.
FMAPathRunner={VERSION='0.20.50.0',MAX_LEGS=160,LEG_METRES=32}
local R=FMAPathRunner
local function good(p)
    return p and type(p.x)=='number' and type(p.z)=='number' and p.x==p.x and p.z==p.z
end
local function d(a,b)
    if not good(a) or not good(b) then return math.huge end
    local dx,dz=a.x-b.x,a.z-b.z;return math.sqrt(dx*dx+dz*dz)
end
local function heading(from,to)
    if not good(from) or not good(to) then return 0 end
    local dx,dz=to.x-from.x,to.z-from.z
    if MathUtil and MathUtil.getYRotationFromDirection then
        return MathUtil.getYRotationFromDirection(dx,dz)
    end
    if math.atan2 then return math.atan2(dx,dz) end
    if math.atan then return math.atan(dx,dz) end
    return 0
end
-- Only reverse a TRULY WITNESSED path of the same vehicle and same attachment
-- class. Every gap must be short, otherwise the engine would cut across unknown
-- terrain (possibly straight through a tree). Never reverse a legacy, untyped
-- trace or transfer it to a wider trailer.
function R.reverseObserved(c,record,target,start)
    if not c or not c.navigationMap or not c.navigationMap.routes or not good(start) or not good(target) then return nil end
    local kind=FMAFarmSurvey and FMAFarmSurvey.classify(record.object) or 'UNKNOWN'
    for _,r in pairs(c.navigationMap.routes) do
        if r.vehicle==record.key and r.footprint==kind and kind~='UNKNOWN'
            and d(r.finish,start)<=10 and d(r.from,target)<=10 and type(r.points)=='table' and #r.points>=3 then
            local rev={};local prev=start;local goodTrace=true
            for i=#r.points,1,-1 do
                local p=r.points[i]
                if not good(p) or d(prev,p)>19 then goodTrace=false;break end
                if d(prev,p)>2 then rev[#rev+1]=p;prev=p end
            end
            if goodTrace and d(prev,target)<=19 and #rev<=18 then
                local legs={};local last=start
                for _,p in ipairs(rev) do
                    if d(last,p)>=6 then
                        legs[#legs+1]={x=p.x,z=p.z,angle=heading(last,p),tolerance=5,noRoutePlan=true}
                        last=p
                    end
                end
                legs[#legs+1]={x=target.x,z=target.z,angle=target.angle or heading(last,target),
                    tolerance=target.tolerance or 7,noRoutePlan=true}
                if #legs>=2 and #legs<=R.MAX_LEGS then
                    return {legs=legs,index=1,completeTarget=target,source='OBSERVED_REVERSE'}
                end
            end
        end
    end
end
function R.plan(c,record,target)
    if not c or not record or not record.object or not good(target) or target.noRoutePlan or target.directApproach or target.recoveryReverse then return nil end
    if not c.settings or c.settings.surveyEnabled==false or c.settings.navigationLearning==false or not FMAFarmSurvey then return nil end
    local x,z=FMAUtil.position(record.object)
    local start={x=x,z=z}
    if not good(start) or d(start,target)<34 then return nil end
    local reverse=R.reverseObserved(c,record,target,start)
    if reverse then return reverse end
    -- A farm parking slot or field boundary may lie off the public road.
    -- A bounded access leg must be driven and physically confirmed by GIANTS,
    -- never fabricated as an already verified stretch of road.
    local points,why=FMAFarmSurvey.plan(c,start,target,FMAFarmSurvey.classify(record.object),
        {maxRoadAccessMetres=32})
    if type(points)~='table' then return nil,why or 'CHYBÍ SPOJENÁ TRASA' end
    if #points<3 or d(points[1],start)>32 or d(points[#points],target)>32 then
        return nil,'CHYBÍ NAPOJENÍ NA SILNICI'
    end
    local legs={};local origin=start;local accum=0;local last=points[1]
    -- The first access hop is mandatory when the parked machine is not on road.
    -- No straight-line teleports: createTransferJob runs actual collision-aware
    -- engine navigation, with the normal watchdog and position gate.
    if d(start,points[1])>11 then
        legs[#legs+1]={x=points[1].x,z=points[1].z,
            angle=heading(start,points[1]),tolerance=6,noRoutePlan=true,
            roadAccess='ENTRY'}
        origin=points[1]
    end
    for i=2,#points do
        local p=points[i]
        if not good(p) or d(last,p)>19 then return nil end
        accum=accum+d(last,p);last=p
        if accum>=R.LEG_METRES then
            if d(origin,p)>=10 then
                legs[#legs+1]={x=p.x,z=p.z,angle=heading(origin,p),tolerance=7,noRoutePlan=true}
                origin=p
            end
            accum=0
        end
        if #legs>R.MAX_LEGS-2 then return nil end
    end
    if d(origin,target)<11 then
        -- Native navigation can handle the last few metres; avoid a nearly
        -- identical intermediate goal which could confuse ownership callbacks.
        if #legs>0 and d(legs[#legs],target)<11 then table.remove(legs) end
    end
    legs[#legs+1]={x=target.x,z=target.z,angle=target.angle or heading(origin,target),
        tolerance=target.tolerance or 8,probeRadius=target.probeRadius,noRoutePlan=true,
        roadAccess=d(points[#points],target)>11 and 'EXIT' or nil}
    if #legs<2 or #legs>R.MAX_LEGS then return nil end
    return {legs=legs,index=1,completeTarget=target}
end
-- AIJobVehicle and Courseplay may still own the vehicle for several frames
-- AFTER the stop callback. Never launch another segment from inside that callback:
-- it would be rejected as VEHICLE_IN_USE and would poison the road map.
local function release(c,item,why)
    if c.pendingRouteLegs then c.pendingRouteLegs[item.vehicle.key]=nil end
    if c.reservations and c.reservations[item.vehicle.key]==item.task.id then c.reservations[item.vehicle.key]=nil end
    item.vehicle.busy=false
    local task=item.task
    task.retryAt=(c.now or 0)+20000
    task.state='pending';task.phase='ČEKÁ NA OBNOVU TRASY';task.reason=why
    local parent=task.parentTaskId and c.tasks and c.tasks[task.parentTaskId]
    if parent then parent.state='pending';parent.retryAt=task.retryAt;parent.phase=task.phase;parent.reason=why end
    if FMADiagnostics and FMADiagnostics.event then FMADiagnostics.event(c,'route.legDeferredFailure',tostring(task.id),tostring(why)) end
end
function R.advance(c,a,outcome)
    local plan=a and a.learnedRoutePlan
    if not plan or not plan.legs or plan.index>=#plan.legs then return false end
    if outcome~='success' or a.stopReason or a.playerTakeover then return false end
    local at=plan.legs[plan.index]
    local x,z=FMAUtil.position(a.vehicle and a.vehicle.object)
    if not good({x=x,z=z}) or d({x=x,z=z},at)>math.max(7,tonumber(at.tolerance) or 7) then
        a.stopReason='Naučený úsek nepotvrzen polohou stroje; nepokračuji naslepo'
        return false
    end
    local nextIndex=plan.index+1
    c.pendingRouteLegs=c.pendingRouteLegs or {}
    -- Retain the reservation through the AI engine's asynchronous cleanup.
    c.reservations[a.vehicle.key]=a.task.id
    a.vehicle.busy=true
    a.task.state='preparing'
    a.task.phase='OVĚŘENÁ TRASA · čeká na uvolnění řízení '..tostring(nextIndex)..'/'..tostring(#plan.legs)
    c.pendingRouteLegs[a.vehicle.key]={task=a.task,vehicle=a.vehicle,plan=plan,
        nextIndex=nextIndex,fill=a.fill,after=(c.now or 0)+1500,deadline=(c.now or 0)+20000}
    if FMADiagnostics and FMADiagnostics.event then
        FMADiagnostics.event(c,'route.legReleased',tostring(a.task.id),tostring(nextIndex)..'/'..tostring(#plan.legs))
    end
    return true
end
function R.update(c)
    if not c or not c.pendingRouteLegs or not c.settings or not c.settings.enabled then return end
    for key,item in pairs(c.pendingRouteLegs) do
        local vehicle=item.vehicle and item.vehicle.object
        if not vehicle or not item.task or not item.plan or not item.plan.legs[item.nextIndex] then
            release(c,item,'Rozpracovaná trasa ztratila stroj nebo bod');
        elseif (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle)) then
            release(c,item,'Stroj převzal hráč během předání trasy')
        elseif (c.now or 0)>=item.deadline then
            release(c,item,'FS25 neuvolnilo řízení pro další úsek trasy')
        elseif (c.now or 0)>=item.after then
            -- Previous AI job can finish asynchronously after stop notification.
            if FMAUtil.call(vehicle,'getIsAIActive')==true or FMAUtil.call(vehicle,'getIsInUse')==true then
                item.after=(c.now or 0)+1200
            else
                local target=item.plan.legs[item.nextIndex]
                local job,reason,method=FMAAI.createTransferJob(c,item.vehicle,target)
                if not job then
                    item.after=(c.now or 0)+2500
                    item.lastReason=tostring(reason)
                else
                    local x,z=FMAUtil.position(vehicle)
                    local active={job=job,task=item.task,vehicle=item.vehicle,start=c.now,
                        lastProgress=c.now,x=x,z=z,fill=item.fill,trafficTarget=target,
                        transferMethod=method,learnedRoutePlan=item.plan,routeLegIndex=item.nextIndex}
                    c.active[job]=active
                    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,c.farmId)
                    if ok then
                        item.plan.index=item.nextIndex
                        item.task.phase='OVĚŘENÁ TRASA · úsek '..tostring(item.nextIndex)..'/'..tostring(#item.plan.legs)
                        item.task.reason='Probíhá skutečný AI přejezd'
                        c.pendingRouteLegs[key]=nil
                        if FMADiagnostics and FMADiagnostics.event then
                            FMADiagnostics.event(c,'route.legStarted',tostring(item.task.id),tostring(item.nextIndex)..'/'..tostring(#item.plan.legs))
                        end
                    else
                        c.active[job]=nil
                        item.after=(c.now or 0)+2500
                        item.lastReason=tostring(err)
                    end
                end
            end
        end
    end
end
