-- Physical-evidence-driven self recovery. A blocked order may reopen without
-- touching the menu only AFTER a real precondition changes. Waiting or
-- rescanning must never recreate the same failed drive-to in a tight loop.
FMASelfHealing={VERSION='0.20.48.0'}

local function pose(vehicle)
    if not vehicle or not vehicle.object or not FMAUtil or not FMAUtil.position then return nil,nil end
    return FMAUtil.position(vehicle.object)
end
local function dist2(ax,az,bx,bz)
    if not ax or not az or not bx or not bz then return 0 end
    return (ax-bx)^2+(az-bz)^2
end
local function vehicle(c,key)
    if not key then return nil end
    if c.vehicleByKey and c.vehicleByKey[key] then return c.vehicleByKey[key] end
    for _,v in ipairs(c.vehicles or {}) do if v.key==key then return v end end
end
local function controlsFree(c,v)
    if not v or v.busy or (c.reservations and c.reservations[v.key]) then return false end
    if FMAGameNative and FMAGameNative.isManuallyControlled
       and FMAGameNative.isManuallyControlled(v.object)==true then return false end
    if FMAUtil.call(v.object,'getIsAIActive')==true then return false end
    return true
end

-- Called at the end of every live world scan. No physical action here: the
-- dispatcher remains sole owner of job start and vehicle reservations.
function FMASelfHealing.scan(c)
    if not c or not c.settings or not c.settings.enabled or c.runtimePaused then return end
    c.selfHealingObserved=c.selfHealingObserved or {}
    for id,t in pairs(c.tasks or {}) do
        local key=t.selfHealingVehicleKey
        local relevant=t.kind=='field' and t.operation=='harvest' and
            (t.selfHealingCause=='stationaryStart' or t.phase=='KOMBAJN SE FYZICKY NEROZJEL')
        if relevant and t.ownerStopRequested~=true and t.ownerPinnedVehicle~=true then
            local v=vehicle(c,key or t.vehicleKey or t.preferredVehicleKey)
            local x,z=pose(v)
            if x and z then
                local observation=c.selfHealingObserved[id]
                if not observation or observation.key~=v.key then
                    observation={key=v.key,x=x,z=z};c.selfHealingObserved[id]=observation
                elseif t.state=='blocked' and controlsFree(c,v) and
                    dist2(x,z,observation.x,observation.z)>=8*8 and
                    (t.selfHealingCount or 0)<2 then
                    -- An actual reposition (by player/other safe means) changes
                    -- the problem. Rebuild the header-trailer approach plan,
                    -- without unmounting anything or inventing a new position.
                    t.selfHealingCount=(t.selfHealingCount or 0)+1
                    t.state='pending';t.phase='ZMĚNA POLOHY · NOVÉ OVĚŘENÍ SOUPRAVY'
                    t.reason='Kombajn změnil fyzické stanoviště · jediný nový řízený pokus'
                    t.retryAt=(c.now or 0)+3000
                    t.headerTransportPlan=nil;t.headerTransportReady=nil
                    t.selfHealingCause=nil
                    c.selfHealingObserved[id]={key=v.key,x=x,z=z}
                    for failureId in pairs(c.jobFailures or {}) do
                        if failureId:sub(1,#('header:'..id..':'))=='header:'..id..':' then
                            c.jobFailures[failureId]=nil
                        end
                    end
                    if FMADiagnostics then FMADiagnostics.event(c,'selfHealing.RELOCATED_HARVESTER',id,
                        tostring(v.name)..' retry '..tostring(t.selfHealingCount)..'/2') end
                end
            end
        else
            c.selfHealingObserved[id]=nil
        end
        -- The assembler has its own five-failure circuit breaker. That is a
        -- sensible STOP, but not a permanent one if the tractor has been
        -- physically moved away from the obstacle afterwards. Reopen without
        -- waiting for Alt+R; do not reset the breaker on timers or rescans.
        local circuit=c.assemblyCircuits and c.assemblyCircuits[id]
        if circuit and circuit.halted and t.state=='blocked'
           and t.ownerStopRequested~=true and (t.selfHealingAssemblyCount or 0)<2 then
            local key=t.preferredVehicleKey
            local v=vehicle(c,key)
            local x,z=pose(v)
            if controlsFree(c,v) and x and z and circuit.startedX and circuit.startedZ and
               dist2(x,z,circuit.startedX,circuit.startedZ)>=4*4 then
                t.selfHealingAssemblyCount=(t.selfHealingAssemblyCount or 0)+1
                t.state='pending';t.phase='OBNOVA ZAPŘAHÁNÍ · NOVÉ STANOVIŠTĚ'
                t.reason='Překážka / poloha soupravy se změnila · ověřím jiný skutečný nájezd'
                t.retryAt=(c.now or 0)+3000;t.assemblyAttempt=1
                t.stagingCandidateCursor=1
                circuit.halted=false;circuit.failures=0
                circuit.startedX=x;circuit.startedZ=z
                for failureId in pairs(c.jobFailures or {}) do
                    if failureId=='assemble:'..id then c.jobFailures[failureId]=nil end
                end
                if FMADiagnostics then FMADiagnostics.event(c,'selfHealing.RELOCATED_HITCH',
                    id,'physical move; retry '..tostring(t.selfHealingAssemblyCount)..'/2') end
            end
        end
    end
    -- A bunker that became safely accessible through a genuine vehicle
    -- relocation may release an ordinary route block automatically. A
    -- GEOFENCE/SAFETY failure cannot be forgiven by this mechanism.
    for index,ws in pairs(c.bunkerWorkState or {}) do
        if ws.blocked and ws.failedVehicleKey and ws.failedPose and
           not tostring(ws.lastError or ''):find('BEZPEČNOST:',1,true) and
           (ws.selfHealingCount or 0)<2 then
            local v=vehicle(c,ws.failedVehicleKey)
            local x,z=pose(v)
            if controlsFree(c,v) and dist2(x,z,ws.failedPose.x,ws.failedPose.z)>=8*8 then
                local b=c.bunkers and c.bunkers[index]
                local verified=false
                if b and FMAOwnDriver and FMAOwnDriver.planInsideBunker then
                    verified=FMAOwnDriver.planInsideBunker(c,v,b)~=nil
                end
                if not verified and b and FMABunkerCoordinator and FMABunkerCoordinator.safeWorkerStart then
                    verified=FMABunkerCoordinator.safeWorkerStart(b,v.object,true)==true or
                        FMABunkerCoordinator.safeWorkerStart(b,v.object,false)==true
                end
                if verified then
                    ws.selfHealingCount=(ws.selfHealingCount or 0)+1
                    ws.blocked=false;ws.failures=0;ws.retryAt=(c.now or 0)+3000
                    ws.ownFallbackDenied=nil;ws.failedVehicleUntil=nil
                    ws.phase='OBNOVENO PO SKUTEČNÉM PŘEMÍSTĚNÍ'
                    ws.failedPose={x=x,z=z}
                    if FMADiagnostics then FMADiagnostics.event(c,'selfHealing.RELOCATED_BUNKER',
                        tostring(index),tostring(v.name)..' retry '..tostring(ws.selfHealingCount)..'/2') end
                end
            end
        end
    end
end
