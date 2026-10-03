-- Small, read-only snapshot exported during play for the Windows Live Monitor.
-- No HTTP, remote commands, savegame edits or reading arbitrary files.
FMALiveTelemetry={VERSION='0.20.48.0',FILE='FS25_FarmManagerAI_LIVE.txt',INTERVAL_MS=5000}
local function clean(value)
    local s=tostring(value==nil and '-' or value)
    return s:gsub('[\r\n\t]',' '):sub(1,220)
end
local function put(rows,...)
    local out={}
    for i=1,select('#',...) do out[i]=clean(select(i,...)) end
    rows[#rows+1]=table.concat(out,' | ')
end
function FMALiveTelemetry.snapshot(c)
    c=c or {}
    local rows={}
    put(rows,'FMA LIVE',FMALiveTelemetry.VERSION,'ms='..tostring(math.floor(c.now or 0)),
        'AUTO='..tostring(c.settings and c.settings.enabled==true),'paused='..tostring(c.runtimePaused==true))
    put(rows,'OWN_DRIVER','active='..tostring(FMAUtil.count(c.ownDriveSessions or {})))
    for key,session in pairs(c.ownDriveSessions or {}) do
        put(rows,'OWN_VEHICLE',key,session.kind,session.id,'goal='..clean(session.goal and session.goal.x)..','..clean(session.goal and session.goal.z),
            'reverse='..clean(session.reverse),'moved='..clean(session.travelled),'passes='..clean(session.passes))
    end
    for id,gate in pairs(c.assemblyCircuits or {}) do
        put(rows,'ASSEMBLY_CIRCUIT',id,'rig='..clean(gate.signature),
            'failed='..clean(gate.failures),'halted='..clean(gate.halted),
            'reference='..clean(gate.startedX)..','..clean(gate.startedZ))
    end
    put(rows,'SUMMARY','vehicles='..tostring(#(c.vehicles or {})), 'active='..tostring(FMAUtil.count(c.active or {})),
        'reserved='..tostring(FMAUtil.count(c.reservations or {})), 'wait='..clean(c.waitReason))
    if FMAParkingManager then
        put(rows,'PARKING','bays='..clean(FMAUtil.count(c.parkingBays or {})),
            'facilities='..clean(#(c.parkingFacilities or {})),
            'organize='..clean(c.parkingOrganize),'leases='..clean(FMAUtil.count(c.parkingLeases or {})))
        local rowsCount=0
        for id,b in pairs(c.parkingBays or {}) do
            if rowsCount>=32 then break end
            rowsCount=rowsCount+1
            put(rows,'PARK_BAY',id,b.kind,b.role,b.site,'x='..clean(b.x),'z='..clean(b.z),
                'reserved='..clean(c.parkingLeases and c.parkingLeases[id]))
        end
    end
    for _,t in pairs(c.tasks or {}) do
        put(rows,'ORDER',t.id,t.state,t.phase,t.reason,'main='..clean(t.preferredVehicleName),
            'tool='..clean(t.preferredImplementName),'field='..clean(t.fieldId))
        if FMAJobBrief and FMAJobBrief.reason then
            put(rows,'ORDER_BRIEF',t.id,FMAJobBrief.reason(c,t))
        end
    end
    -- Cross-module observability: distinguish a planned crew, a physical AI job,
    -- a backoff, a broken subsystem and an unverified field state. The export is
    -- read-only and never triggers game actions or alters the player's save.
    put(rows,'RECORDER',FMABlackBox and FMABlackBox.summary(c) or 'missing','error='..clean(c.recorderError))
    put(rows,'HEALTH','subsystemFaults='..clean(FMAUtil.count(c.subsystemFaults or {})),
        'lastRuntimeError='..clean(c.lastRuntimeError),'reloadHold='..clean(c.vehicleReloadHold))
    for name,err in pairs(c.subsystemFaults or {}) do
        put(rows,'FAULT',name,err)
    end
    local fieldIds={}
    for _,t in pairs(c.tasks or {}) do
        put(rows,'GATE',t.id,'retryAt='..clean(t.retryAt),
            'attempts='..clean(t.attempts),'blocked='..clean(t.blockedByEquipment),
            'verified='..clean(t.awaitingWorldVerification),'started='..clean(t.fieldworkStartedAt))
        if t.fieldId~=nil then fieldIds[tostring(t.fieldId)]=true end
        if t.workEvidence and FMAWorkEvidence then
            local e=t.workEvidence
            local vehicle=c.vehicleByKey and c.vehicleByKey[e.vehicleKey]
            local row=vehicle and FMAWorkEvidence.measure(vehicle,t.operation)
            put(rows,'PHYSICAL_WORK',t.id,'vehicle='..clean(e.vehicleKey),
                'mode='..clean(e.mode),'startLitres='..clean(e.first),
                'minimumLitres='..clean(e.minimum),'consumedLitres='..clean(e.consumed),
                'currentLitres='..clean(row and row.level),
                'capacity='..clean(row and row.capacity or e.capacity),
                'movedMetres='..clean(e.observedMove),
                'verified='..clean(select(1,FMAWorkEvidence.verify(t,nil))))
        end
    end
    for _,field in ipairs(c.fields or {}) do
        if fieldIds[tostring(field.id)] then
            put(rows,'FIELD_TRUTH',field.id,'valid='..clean(field.valid),
                'alive='..clean(field.alive),'ready='..clean(field.ready),
                'bare='..clean(field.bare),'needsLime='..clean(field.needsLime),
                'needsPlow='..clean(field.needsPlow),'needsFertilize='..clean(field.needsFertilize),
                'needsWeed='..clean(field.needsWeed))
        end
    end
    for id,plan in pairs(c.assemblyPlans or {}) do
        put(rows,'ASSEMBLY',id,plan.phase,plan.state,plan.reason)
    end
    for _,entry in pairs(c.serviceQueue or {}) do
        put(rows,'SERVICE',entry.name or entry.key or entry.id,entry.state,entry.reason,entry.damage)
    end
    for id,session in pairs(c.bunkerDeliverySessions or {}) do
        put(rows,'BUNKER_DELIVERY',id,session.phase,session.state,session.reason)
    end
    for _,v in ipairs(c.vehicles or {}) do
        local obj=v.object
        local mode='IDLE'
        if obj and FMAUtil.call(obj,'getIsAIActive')==true then mode='FS_AI' end
        if obj and FMAUtil.call(obj,'getIsCpFieldWorkActive')==true then mode='CP_FIELDWORK' end
        local x,z=v.x,v.z
        if obj and FMAUtil.position then
            local a,b=FMAUtil.position(obj);x=a or x;z=b or z
        end
        local extra=''
        if v.isGrainCombine and obj then
            local cutter=FMAHeaderTransport and FMAHeaderTransport.attachedCutter and FMAHeaderTransport.attachedCutter(obj)
            local carrier=FMAHeaderTransport and FMAHeaderTransport.attachedCarrier and FMAHeaderTransport.attachedCarrier(v)
            local stored=carrier and FMAHeaderTransport.cutterOnCarrier and FMAHeaderTransport.cutterOnCarrier(c,carrier)
            local can=FMAUtil.call(obj,'getCanStartCpFieldWork')
            extra='cutter='..clean(cutter and FMAUtil.name(cutter) or '-')..
                ';carrier='..clean(carrier and carrier.name or '-')..
                ';stored='..clean(stored and stored.name or '-')..';cpEligible='..clean(can)
        end
        put(rows,'VEHICLE',v.name,v.key,'x='..clean(x),'z='..clean(z),mode,
            'busy='..clean(v.busy),'reservation='..clean(c.reservations and c.reservations[v.key]),extra)
    end
    for _,a in pairs(c.active or {}) do
        if a.task then
            put(rows,'JOB',a.task.id,a.task.kind,a.task.phase,
                'vehicle='..clean(a.vehicle and a.vehicle.name),
                'running='..clean(a.job and a.job.isRunning),
                'start='..clean(a.start),'accepted='..clean(a.dispatchVerified),'moved='..clean(a.physicalMotionVerified),'stop='..clean(a.stopReason))
        end
    end
    for i,market in ipairs(c.marketRows or {}) do
        if i>24 then break end
        put(rows,'MARKET',FMAWorld.fillName(market.fillType),
            'stock='..clean(market.level),'capacity='..clean(market.capacity),
            'sellPer1000='..clean(market.best and market.best.price*1000),
            'observedHighPer1000='..clean((market.priceHigh or 0)*1000),
            'pressure='..clean(market.pressure))
    end
    for id,roles in pairs(c.preparedSupport or {}) do
        for slot,role in pairs(roles or {}) do
            put(rows,'HAULAGE',id,'slot='..clean(slot),role.state,
                'vehicle='..clean(role.record and role.record.name),
                'failures='..clean(role.stageFailureCount),
                'retryAt='..clean(role.retryAt),role.reason)
        end
    end
    for key,session in pairs(c.haulageCycles or {}) do
        local level=FMAHaulageCycle and FMAHaulageCycle.cargo and FMAHaulageCycle.cargo(session.record,session.fillType)
        put(rows,'HAULAGE_CYCLE',key,session.state,session.phase,'litres='..clean(level),
            'before='..clean(session.before),'attempts='..clean(session.attempts),'reason='..clean(session.reason))
    end
    for key,v in pairs(c.stageRouteFailures or {}) do
        put(rows,'ROAD_BACKOFF',key,'count='..clean(v.count),'retryAt='..clean(v.retryAt),'reason='..clean(v.reason))
    end
    -- Live monitor exposes dependencies and routing progress, not only generic FAIL.
    for id,session in pairs(c.refillSessions or {}) do
        if session.manual then
            local req=session.requirement or {}
            local live=FMARefillManager and FMARefillManager.liveMaterial and
                FMARefillManager.liveMaterial(session.vehicle,req)
            local fill=live and live.level or FMAUtil.call(req.object,'getFillUnitFillLevel',req.fillUnitIndex)
            put(rows,'WAIT_MATERIAL',id,'station='..clean(session.station and session.station.name),
                'manualDrive='..clean(session.needsDriver),'level='..clean(fill),
                'fillType='..clean(req.fillType),'capacity='..clean(live and live.capacity or req.capacity),
                'threshold='..clean(math.min(0.20,c.settings.refillBeforeWork or 0.25)))
        end
    end
    for _,t in pairs(c.tasks or {}) do
        if t.manualRefillVehicleKey and t.manualRefillRequirement then
            local v=c.vehicleByKey and c.vehicleByKey[t.manualRefillVehicleKey]
            local stat=FMARefillManager and FMARefillManager.liveMaterial and
                FMARefillManager.liveMaterial(v,t.manualRefillRequirement)
            put(rows,'MATERIAL_WATCH',t.id,'vehicle='..clean(v and v.name),
                'level='..clean(stat and stat.level),'ratio='..clean(stat and stat.ratio),
                'fillType='..clean(t.manualRefillRequirement.fillType),'phase='..clean(t.phase))
        end
        if t.headerTransportPlan and t.headerTransportPlan.outboundTries then
            put(rows,'HEADER_ROUTE',t.id,'attempt='..clean(t.headerTransportPlan.outboundTries),
                'candidateCount='..clean(#(t.headerTransportPlan.outboundCandidates or {})),
                'reason='..clean(t.reason))
        end
    end
    return table.concat(rows,'\n')..'\n'
end
function FMALiveTelemetry.write(c)
    if not FMAOpsLog or not FMAOpsLog.writePortable then return false,'Export unavailable' end
    local content=FMALiveTelemetry.snapshot(c)
    local path,ok=FMAOpsLog.writePortable(FMALiveTelemetry.FILE,content)
    FMALiveTelemetry.lastPath=path
    FMALiveTelemetry.lastOk=ok
    return ok,path or 'Cannot write live snapshot'
end
