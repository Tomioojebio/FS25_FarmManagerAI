-- Shared ownership and resource checks across driving and stationary phases.
FMALifecycle = {}

function FMALifecycle.allowed(c,r,allowAI)
    if not c.settings.enabled or c.shuttingDown then return false,'Automatika je pozastavena' end
    local v=r and r.object
    if not v or v.isDeleted or FMAUtil.owner(v)~=c.farmId then return false,'Změněné vlastnictví nebo odstraněný stroj' end
    if c.excluded and c.excluded[r.key] then return false,'Stroj vyřazen z automatizace majitelem' end
    if (FMAGameNative and FMAGameNative.isManuallyControlled(v))==true then return false,'Stroj převzal majitel' end
    if not allowAI and FMAUtil.call(v,'getIsAIActive')==true then return false,'Stroj převzal jiný pracovník' end
    for _,o in ipairs(FMAWorld.children(v)) do
        if FMAUtil.owner(o)~=c.farmId then return false,'Souprava obsahuje cizí nebo odstraněné nářadí' end
    end
    return true
end

local function recordOf(s)
    return s.record or s.vehicle or (s.plan and s.plan.power) or (s.active and s.active.vehicle)
end

function FMALifecycle.liveReservations(c)
    local vehicles,tools={},{}
    local function add(s)
        local r=recordOf(s)
        if r then vehicles[r.key]=true end
        local plan=s.plan or s.assemblyPlan or s.transportAssemblyPlan
        if plan and plan.tool then tools[plan.tool.key]=true end
        local header=s.headerPlan or (s.task and s.task.headerTransportPlan) or (plan and plan.carrier and plan)
        if header and header.carrier then tools[header.carrier.key]=true end
    end
    for _,a in pairs(c.active or {}) do add(a) end
    for _,name in ipairs({'attachSessions','refillSessions','headerWaits','livestockSessions','bunkerDeliverySessions',
            'baleUnloadSessions','baleDeliveryWaits','forageBunkerWaits','qualityCoursePending','cpBoundary','deferred'}) do
        for _,s in pairs(c[name] or {}) do add(s) end
    end
    for _,task in pairs(c.tasks or {}) do
        if task.headerTransportReady and task.headerTransportPlan then tools[task.headerTransportPlan.carrier.key]=true end
        if task.state=='handover' and task.managedAttachment and task.managedAttachment.toolKey then
            tools[task.managedAttachment.toolKey]=true
        end
    end
    for _,entry in pairs(c.handoverJournal or {}) do
        if entry.tool then tools[entry.tool]=true end
        if entry.vehicle then vehicles[entry.vehicle]=true end
    end
    for _,entry in pairs(c.pendingHandovers or {}) do
        if entry.record then vehicles[entry.record.key]=true end
        if entry.task and entry.task.attachment then tools[entry.task.attachment.toolKey]=true end
    end
    for _,entry in pairs(c.pendingDetaches or {}) do
        if entry.record then vehicles[entry.record.key]=true end
        if entry.task and entry.task.attachment then tools[entry.task.attachment.toolKey]=true end
    end
    for _,roles in pairs(c.preparedSupport or {}) do
        for _,role in pairs(roles) do
            if role.record and (role.state=='WAITING_FIELD' or role.state=='STAGING' or role.state=='ASSEMBLING' or role.state=='READY' or role.state=='ACTIVE') then vehicles[role.record.key]=true end
            if role.tool and role.tool.key then tools[role.tool.key]=true end
        end
    end
    for key,r in pairs(c.routes or {}) do
        if r.phase and r.phase~='idle' and r.phase~='blocked' then vehicles[key]=true end
    end
    if FMAControlAuthority then
        FMAControlAuthority.liveReservations(c,vehicles,tools)
    end
    return vehicles,tools
end

local function resetTaskAfterRuntimeReload(c,task,key)
    if not task then return end
    local parent=task.parentTask or (task.parentTaskId and c.tasks and c.tasks[task.parentTaskId]) or task
    -- A physical handover is journal-owned. Never make its parent dispatchable
    -- while the engine replaces a vehicle object: restoreJournal will rebind
    -- the actual implement/tractor and resume from the physical checkpoint.
    if c.handoverJournal and c.handoverJournal[parent.id] then
        parent.state='handover'
        parent.phase='OBNOVA PŘEDÁNÍ / RESET STROJE'
        parent.reason='FS25 změnilo objekt stroje · kontroluji skutečné připojení a polohu nářadí'
        parent.managedAttachment=nil
        return
    end
    local function resetOne(t)
        if not t then return end
        t.state='pending';t.phase='OBNOVA PO RESETU STROJE';t.reason='Stroj byl resetován / znovu načten · přepočítávám soupravu a trasu z aktuální polohy';t.retryAt=(c.now or 0)+1200
        t.vehicleKey=nil;t.failures=0;t.attempts=0;t.qualityCourseReady=nil;t.courseVehicleKey=nil;t.baseAIFallback=nil
        t.headerTransportReady=nil;t.headerTransportPlan=nil;t.managedAttachment=nil
        if t.failedVehicleKeys then t.failedVehicleKeys[key]=nil end
    end
    resetOne(parent)
    if task~=parent then resetOne(task) end
end

local function clearFailuresForVehicle(c,key)
    for id,f in pairs(c.jobFailures or {}) do
        if f and f.vehicleKey==key then c.jobFailures[id]=nil end
    end
end

local function rebindSessionRecord(c,session)
    if type(session)~='table' then return false,nil end
    local record=recordOf(session)
    if not record or not record.key then return false,nil end
    local ok,changed=FMAWorld.refreshRecordObject(record)
    if changed then return true,record.key end
    return false,nil
end

-- Reconcile every long-lived runtime reference after the GIANTS VehicleSystem reloads
-- a machine. This is intentionally keyed by uniqueId, not by object identity or position.
function FMALifecycle.syncRuntimeObjects(c)
    local system=g_currentMission and g_currentMission.vehicleSystem
    if not system then return false end
    if system.isReloadRunning==true then
        c.vehicleReloadHold=true
        c.vehicleReloadObserved=true
        c.waitReason='FS25 právě resetuje / znovu načítá techniku'
        return true
    end
    -- Real FS25 VehicleSystem always exposes vehicleByUniqueId. Lightweight test
    -- doubles and early mission boot may not; in that state there is no authoritative
    -- object-generation mapping to reconcile, so leave existing records untouched.
    if type(system.vehicleByUniqueId)~='table' then return false end
    local hadReload=c.vehicleReloadHold==true or c.vehicleReloadObserved==true
    c.vehicleReloadHold=false
    local changedKeys={}

    -- Current scan records may themselves outlive an engine reload for a few frames.
    for _,record in ipairs(c.vehicles or {}) do
        local ok,changed=FMAWorld.refreshRecordObject(record)
        if changed then changedKeys[record.key]=true end
    end
    for _,record in ipairs(c.loose or {}) do
        local ok,changed=FMAWorld.refreshRecordObject(record)
        if changed then changedKeys[record.key]=true end
    end

    -- A running job belongs to the OLD vehicle object. Never attempt to continue it on
    -- the replacement object; discard the stale job and re-plan from the current position.
    local removeJobs={}
    for job,a in pairs(c.active or {}) do
        local changed,key=rebindSessionRecord(c,a)
        if changed then
            removeJobs[#removeJobs+1]={job=job,active=a,key=key}
            changedKeys[key]=true
        end
    end
    for _,row in ipairs(removeJobs) do
        c.active[row.job]=nil
        c.reservations[row.key]=nil
        if c.traffic then FMATraffic.release(c.traffic,row.key) end
        if row.active and row.active.vehicle then row.active.vehicle.busy=false end
        resetTaskAfterRuntimeReload(c,row.active and row.active.task,row.key)
    end

    -- Stationary/assembly/refill sessions may also hold the old object. Cancel only the
    -- ephemeral session; the parent operation remains pending and is rebuilt from live data.
    for _,name in ipairs({'attachSessions','refillSessions','headerWaits','livestockSessions','bunkerDeliverySessions',
            'baleUnloadSessions','baleDeliveryWaits','forageBunkerWaits','qualityCoursePending','cpBoundary','deferred'}) do
        local collection=c[name] or {}
        local remove={}
        for id,session in pairs(collection) do
            local changed,key=rebindSessionRecord(c,session)
            if changed then remove[#remove+1]={id=id,session=session,key=key};changedKeys[key]=true end
        end
        for _,row in ipairs(remove) do
            local task=row.session.parent or row.session.task or (row.session.active and row.session.active.task)
            collection[row.id]=nil
            c.reservations[row.key]=nil
            if c.traffic then FMATraffic.release(c.traffic,row.key) end
            resetTaskAfterRuntimeReload(c,task,row.key)
        end
    end

    for taskId,roles in pairs(c.preparedSupport or {}) do
        for _,role in pairs(roles) do
            local r=role.record
            if r and r.key then
                local ok,changed=FMAWorld.refreshRecordObject(r)
                if changed then
                    changedKeys[r.key]=true;c.reservations[r.key]=nil;r.busy=false
                    if c.traffic then FMATraffic.release(c.traffic,r.key) end
                    role.state='NEEDED';role.reason='Odvozní stroj byl resetován · znovu se připraví z aktuální polohy';role.retryAt=(c.now or 0)+1200
                    local parent=c.tasks and c.tasks[taskId];if parent then resetTaskAfterRuntimeReload(c,parent,r.key) end
                end
            end
        end
    end

    local changedCount=0
    for key in pairs(changedKeys) do
        changedCount=changedCount+1
        c.reservations[key]=nil
        if c.routes and c.routes[key] then c.routes[key].phase='idle';c.routes[key].reason='Reset stroje · trasa bude znovu spočítána' end
        if c.playerTakeovers then c.playerTakeovers[key]=nil end
        clearFailuresForVehicle(c,key)
        if FMADiagnostics then FMADiagnostics.event(c,'vehicle.rebound',key,'runtime object rebound by uniqueId') end
    end
    if hadReload or changedCount>0 then
        c.vehicleReloadObserved=false
        c.elapsed=(c.settings.scanSeconds or 12)*1000
        c.diagnosticDirty=true
        if changedCount>0 and c.notify then c:notify('Reset techniky rozpoznán · '..tostring(changedCount)..' stroj(e) znovu navázány podle uniqueId') end
    end
    return changedCount>0
end

function FMALifecycle.prestartCheck(c,task,record)
    if c.vehicleReloadHold then return false,'FS25 právě resetuje / znovu načítá techniku' end
    if not record or not record.key then return false,'Chybí stabilní identita stroje' end
    local live=FMAWorld.resolveVehicle(record.key)
    if not live then return false,'Stroj není v živém registru VehicleSystem' end
    if live~=record.object then
        record.object=live;local x,z=FMAUtil.position(live);record.x=x or record.x;record.z=z or record.z
        return false,'Stroj byl právě znovu načten · čekám na nový scan a trasu'
    end
    local ok,why=FMALifecycle.allowed(c,record,false);if not ok then return false,why end
    if task and FMAWorld.requiresFieldTractor(task.operation) and task.ownerPinnedVehicle~=true and FMAWorld.isAutoFieldPowerAllowed(record,task.operation)~=true then
        return false,'Pro tuto polní operaci je vyžadován traktor, ne manipulátor / nakladač / silniční vozidlo'
    end
    return true
end

function FMALifecycle.cancelSession(c,collection,id,s,reason)
    local r=recordOf(s)
    if type(s.active)=="boolean" then s.active=false end
    if s.trigger and s.requirement then
        FMAUtil.call(s.trigger,'setIsLoading',false,s.requirement.object,s.requirement.fillUnitIndex,s.requirement.fillType)
    end
    local ing=s.loadingIngredient
    if ing and ing.point then FMAUtil.call(ing.point.trigger,'setIsLoading',false,s.object,s.fillUnitIndex,ing.fillType) end
    if s.tool and s.tool.setDischargeState then FMAUtil.call(s.tool,'setDischargeState',Dischargeable.DISCHARGE_STATE_OFF) end
    if s.loader and s.loader.spec_baleLoader and BaleLoader and BaleLoader.CHANGE_BUTTON_EMPTY_ABORT then
        FMAUtil.call(s.loader,'doStateChange',BaleLoader.CHANGE_BUTTON_EMPTY_ABORT)
    end
    local task=s.parent or s.task or (s.active and s.active.task)
    if task then
        task.state='paused';task.reason=reason
        local parent=task.parentTask or (task.parentTaskId and c.tasks[task.parentTaskId])
        if parent then parent.state='paused';parent.reason=reason end
        if reason=='Stroj převzal majitel' and r then
            local target=parent or task
            target.lastManualVehicleKey=r.key
            target.lastManualCheckAt=c.now or 0
        end
        if task.bunkerIndex and c.bunkerWorkState and c.bunkerWorkState[task.bunkerIndex] then c.bunkerWorkState[task.bunkerIndex].activeDeliveryKey=nil end
    end
    if s.plan and s.plan.tool then c.implementReservations[s.plan.tool.key]=nil end
    if r then
        c.reservations[r.key]=nil;r.busy=false
        if c.traffic then FMATraffic.release(c.traffic,r.key) end
        c:issue('control:'..r.key,r.name or 'Stroj',reason,100)
    end
    collection[id]=nil
    FMADiagnostics.event(c,'session.cancel',id,reason)
end

function FMALifecycle.update(c)
    FMALifecycle.syncRuntimeObjects(c)
    if c.vehicleReloadHold then return end
    for job,a in pairs(c.active or {}) do
        local ok,why=FMALifecycle.allowed(c,a.vehicle,true)
        if not ok and not a.stopReason then
            a.stopReason=why
            if a.vehicle and ((FMAGameNative and FMAGameNative.isManuallyControlled(a.vehicle.object))==true or c.excluded[a.vehicle.key]) then a.playerTakeover=true end
            FMAAI.stop(job)
        end
    end
    for _,name in ipairs({'attachSessions','refillSessions','headerWaits','livestockSessions','bunkerDeliverySessions',
            'baleUnloadSessions','baleDeliveryWaits','forageBunkerWaits','qualityCoursePending','cpBoundary','deferred'}) do
        local collection=c[name] or {}
        for id,s in pairs(collection) do
            local r=recordOf(s)
            local allowAI=name=='livestockSessions' and s.phase~='loading'
            local ok,why=FMALifecycle.allowed(c,r,allowAI)
            if ok and s.plan and s.plan.tool and FMAUtil.owner(s.plan.tool.object)~=c.farmId then ok=false;why='Nářadí změnilo majitele' end
            if ok and s.storage and FMAUtil.owner(s.storage.object)~=c.farmId then ok=false;why='Sklad změnil majitele' end
            if not ok then FMALifecycle.cancelSession(c,collection,id,s,why) end
        end
    end
    -- A staged harvest support unit is a real reservation even though it has no
    -- running AI job while waiting. If the player takes it over, release it cleanly.
    for taskId,roles in pairs(c.preparedSupport or {}) do
        for _,role in pairs(roles) do
            local r=role.record
            if r and role.state=='WAITING_FIELD' and (FMAGameNative and FMAGameNative.isManuallyControlled(r.object))==true then
                -- Manual driving is a control-mode change, not a crew failure. Keep the
                -- reservation so the dispatcher never allocates a duplicate unloader.
                r.busy=true;role.state='PLAYER';role.reason='Majitel řídí odvoz · stále člen čety'
                if c.issues then c.issues['crew:'..tostring(role.id)]=nil end
            elseif r and role.state=='PLAYER' then
                local state=FMAGameNative and FMAGameNative.operatorState(r.object) or {mode='IDLE',manual=false,aiActive=false}
                if state.manual then
                    r.busy=true;role.reason='Majitel řídí odvoz · stále člen čety'
                elseif state.aiActive then
                    r.busy=true;role.state='ACTIVE';role.reason='Odvoz znovu řídí '..tostring(state.mode)
                else
                    r.busy=true;role.state='WAITING_FIELD';role.reason='Vrácen Manageru · čeká u pole'
                end
            elseif r and c.excluded[r.key] and role.state=='WAITING_FIELD' then
                c.reservations[r.key]=nil;r.busy=false;role.state='PAUSED';role.reason='Stroj je ručně vyřazen z automatiky'
                if c.traffic then FMATraffic.release(c.traffic,r.key) end
            end
        end
    end

    -- Keep occupied zones leased through loading, unloading and slow journeys.
    for _,zone in pairs(c.traffic and c.traffic.zones or {}) do
        if c.reservations[zone.vehicleKey] then zone.expires=c.now+30000 end
    end
    for id,s in pairs(c.deferred or {}) do
        if c.now>=s.retryAt then
            c.deferred[id]=nil;c.reservations[s.record.key]=nil;s.record.busy=false
            if c.now-s.start>300000 then
                FMAJobs.fail(c,s.parent,s.record,'Cesta čeká déle než 5 minut; zkontroluj obsazený příjezd')
            else
                local ok,started,why=pcall(s.run)
                if not ok or not started then FMAJobs.fail(c,s.parent,s.record,tostring(ok and why or started))
                elseif not c.deferred[id] then s.parent.trafficWaitingSince=nil end
            end
        end
    end
end

-- A genuine short intervention by the owner is NOT a permanent task cancellation.
-- Reconcile against live player ownership, existing jobs and reserved sessions.
function FMALifecycle.resumeReleasedOrders(c)
    if not c or not c.settings or c.settings.enabled~=true then return 0 end
    local resumed=0
    for _,task in pairs(c.tasks or {}) do
        if task.state=='paused' and task.reason=='Stroj převzal majitel'
            and task.ownerApproved==true and task.ownerStopRequested~=true
            and (c.now or 0)-(task.lastManualCheckAt or 0)>=3000 then
            local key=task.lastManualVehicleKey or task.vehicleKey or task.preferredVehicleKey
            local record=key and c.vehicleByKey and c.vehicleByKey[key] or nil
            local object=record and record.object or (key and FMAWorld and FMAWorld.resolveVehicle and FMAWorld.resolveVehicle(key))
            local manuallyDriven=object and FMAGameNative and FMAGameNative.isManuallyControlled(object)==true
            local stillTaken=false
            for _,take in pairs(c.playerTakeovers or {}) do
                if take.taskId==task.id or take.task==task then stillTaken=true;break end
            end
            if not manuallyDriven and not stillTaken then
                local sessionStillPresent=false
                for _,a in pairs(c.active or {}) do
                    if a.task==task or a.task.parentTaskId==task.id then sessionStillPresent=true;break end
                end
                if not sessionStillPresent then
                    for _,name in ipairs({'attachSessions','refillSessions','headerWaits','qualityCoursePending','deferred'}) do
                        for _,s in pairs(c[name] or {}) do
                            if s.parent==task or s.task==task or (s.task and s.task.parentTaskId==task.id) then sessionStillPresent=true;break end
                        end
                        if sessionStillPresent then break end
                    end
                end
                if not sessionStillPresent then
                    task.state='pending';task.phase='OBNOVA PO UVOLNĚNÍ STROJE';task.reason=nil
                    task.retryAt=(c.now or 0)+1500;task.lastManualVehicleKey=nil
                    resumed=resumed+1
                    if FMADiagnostics then FMADiagnostics.event(c,'order.ownerReleased',task.id,'pending') end
                end
            end
        end
    end
    return resumed
end

function FMALifecycle.defer(c,id,record,parent,run,reason)
    c.deferred=c.deferred or {}
    local old=c.deferred[id]
    parent.trafficWaitingSince=parent.trafficWaitingSince or c.now
    c.deferred[id]={record=record,parent=parent,run=run,retryAt=c.now+6000,start=old and old.start or parent.trafficWaitingSince}
    c.reservations[record.key]=id;record.busy=true
    parent.state='waiting';parent.reason=reason or 'Čeká na uvolnění příjezdu'
    return true,'WAITING_TRAFFIC'
end

function FMALifecycle.fieldBusy(c,task)
    if not task.fieldId then return false end
    for _,other in pairs(c.tasks or {}) do
        if other~=task and other.fieldId==task.fieldId and
            (other.state=='running' or other.state=='preparing' or other.state=='assembling' or other.state=='waiting' or other.state=='returning' or other.state=='handover') then return true end
    end
    return false
end
