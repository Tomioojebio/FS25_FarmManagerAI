-- Grain haulage is a complete cycle, not a one-shot Courseplay helper.
-- Courseplay services the combine; GIANTS AIJobDeliver is a guarded fallback if
-- an unloader stops carrying grain. Only real fill-level changes prove unloading.
FMAHaulageCycle = {}

local function live(c,key)
    return c and c.haulageCycles and c.haulageCycles[key]
end

local function report(c,s,event,detail)
    s.phase=event;s.reason=detail or ''
    if FMADiagnostics and FMADiagnostics.event then
        FMADiagnostics.event(c,'haulage.'..event,s.record and s.record.key or '?',s.reason)
    end
    c.diagnosticDirty=true
end

function FMAHaulageCycle.cargo(record,expected)
    local level,capacity,actual=0,0,nil
    if not record or not record.object then return 0,0,nil end
    -- Only transport cargo, NEVER tractor fuel / AdBlue / seed tanks / etc.
    for _,object in ipairs(FMAWorld.children(record.object)) do
        local cargo=(object.spec_dischargeable and object.spec_trailer) or
            (FMAModHubAdapter and FMAModHubAdapter.isAttachableTransport and FMAModHubAdapter.isAttachableTransport(object))
        if cargo then
            local units=FMAUtil.call(object,'getFillUnits') or (object.spec_fillUnit and object.spec_fillUnit.fillUnits) or {}
            for i,unit in pairs(units) do
                if not FMAModHubAdapter or not FMAModHubAdapter.cargoUnit or FMAModHubAdapter.cargoUnit(object,i) then
                    local ft=FMAUtil.call(object,'getFillUnitFillType',i)
                    local amount=tonumber(FMAUtil.call(object,'getFillUnitFillLevel',i)) or 0
                    local cap=tonumber(FMAUtil.call(object,'getFillUnitCapacity',i)) or tonumber(unit and unit.capacity) or 0
                    local match=expected==nil or ft==expected or (amount<1 and FMAUtil.call(object,'getFillUnitSupportsFillType',i,expected)==true)
                    if match and (not FillType or ft~=FillType.DIESEL) then
                        level=level+math.max(0,amount)
                        capacity=capacity+math.max(0,cap)
                        if amount>1 then actual=ft end
                    end
                end
            end
        end
    end
    return level,capacity,actual
end

function FMAHaulageCycle.harvesterWorking(group)
    if not group or not group.harvester or not group.harvester.object or not group.parentTask then return false end
    local t=group.parentTask
    if t.state=='done' or t.state=='cancelled' or t.state=='blocked' then return false end
    local v=group.harvester.object
    if FMAUtil.call(v,'getIsCpFieldWorkActive')==true then return true end
    -- Native fieldwork is verified by FMAController.confirmPendingFieldwork.
    return t.fieldworkStartedAt~=nil and FMAUtil.call(v,'getIsAIActive')==true
end

-- CP needs an unloader within 20 m of the field BORDER (not its centre).
-- A previously verified waiting point is useful, but is not by itself evidence
-- that it is near the field, especially on maps with unusual field centres.
function FMAHaulageCycle.nearField(c,group,record)
    if not c or not group or not record then return false end
    local x,z=FMAUtil.position(record.object)
    if not x or not z then return false end
    -- Once the combine is ACTUALLY working, a helper standing next to it is
    -- already at the real work site. The old border-only distance check sent a
    -- 6R parked 12 m from LEXION away to invalid, generated waiting points.
    if FMAHaulageCycle.harvesterWorking(group) then
        local hx,hz=FMAUtil.position(group.harvester.object)
        if hx and (x-hx)^2+(z-hz)^2<=18*18 then return true end
    end
    local field=c.fieldsById and c.fieldsById[group.fieldId]
    local points={}
    for _,node in ipairs(field and field.object and field.object.polygonPoints or {}) do
        if getWorldTranslation then
            local ok,nx,_,nz=pcall(getWorldTranslation,node)
            if ok and nx and nz then points[#points+1]={x=nx,z=nz} end
        end
    end
    if #points>=2 then
        local best=math.huge
        for i=1,#points do
            local a=points[i];local b=points[i%#points+1]
            local dx,dz=b.x-a.x,b.z-a.z
            local denom=dx*dx+dz*dz
            local t=denom>0.001 and math.max(0,math.min(1,((x-a.x)*dx+(z-a.z)*dz)/denom)) or 0
            local dd=(x-a.x-t*dx)^2+(z-a.z-t*dz)^2
            best=math.min(best,dd)
        end
        return best<=18*18 -- leave a small margin below CP's 20 m limit
    end
    -- Missing field polygon: use a REAL working harvester within the CP limit.
    -- An arbitrary field centre is never accepted as proof of a valid border.
    local hx,hz=FMAUtil.position(group.harvester and group.harvester.object)
    if not hx or not hz then return false end
    return (x-hx)^2+(z-hz)^2<=18*18
end

local function approved(c,parent)
    return parent and parent.state~='done' and parent.state~='cancelled' and parent.state~='blocked' and
        c.settings and c.settings.enabled and (not c.settings.selectedJobsOnly or parent.ownerApproved==true)
end

-- Queue a full trailer after CP stops; do not attempt to start another worker in
-- the same engine callback. A persistent-in-session lease blocks another job.
function FMAHaulageCycle.queue(c,active)
    local task=active and active.task
    local record=active and active.vehicle
    if not task or task.kind~='support' or task.forageBunker or not record then return false end
    local amount,cap,ft=FMAHaulageCycle.cargo(record,task.fillType)
    if amount<=1 then return false end
    if live(c,record.key) then return true end
    c.haulageCycles=c.haulageCycles or {}
    local session={record=record,parentTaskId=task.parentTaskId,groupId=task.parentGroup,slot=task.slotIndex or 1,
        fieldId=task.fieldId,fillType=ft or task.fillType,before=amount,capacity=cap,
        state='NEED_DELIVERY',createdAt=c.now or 0,nextTryAt=(c.now or 0)+2500,attempts=0}
    c.haulageCycles[record.key]=session
    c.reservations[record.key]='haulageCycle:'..record.key
    record.busy=true
    report(c,session,'NALOŽENO','Ve voze '..math.floor(amount)..' l; hledá ověřenou vykládku')
    return true
end

local function destinations(c,s)
    if FMALogistics and FMALogistics.destinationOptions then
        return FMALogistics.destinationOptions(c.farmId,nil,s.fillType,c.settings.autoSellOutputs==true)
    end
    local best=FMALogistics and FMALogistics.bestDestination(c.farmId,nil,s.fillType,c.settings.autoSellOutputs==true)
    return best and {best} or {}
end

local function startDelivery(c,s)
    local record=s.record
    if not record or not record.object then return false,'Souprava již není dostupná' end
    if FMAUtil.call(record.object,'getIsAIActive')==true then return nil,'Čeká na uvolnění předchozího AI pracovníka' end
    if FMAGameNative and FMAGameNative.isManuallyControlled(record.object) then return nil,'Majitel řídí odvozce' end
    local stations=destinations(c,s)
    if #stations==0 then return false,'Pro tento materiál není vlastní vhodné silo; prodej není povolen' end
    if AIJobDeliver==nil then return false,'Hra neposkytuje AIJobDeliver' end
    local lastReason='Není dostupná vykládací trasa'
    for _,destination in ipairs(stations) do
        if not (s.failedDestinations and s.failedDestinations[destination]) then
            local target=FMAWorldAtlas and FMAWorldAtlas.stationTarget and FMAWorldAtlas.stationTarget(destination,s.fillType)
            if target then
                local trafficOk,trafficReason=true,nil
                if FMATraffic and FMATraffic.canStart then
                    trafficOk,trafficReason=FMATraffic.canStart(c,record,target,
                        {id='haulageDelivery:'..record.key,kind='supportDelivery'},60000)
                end
                if trafficOk then
                    local job=FMAAI.createRegisteredJob('DELIVER',AIJobDeliver)
                    if job and FMAUtil.call(job,'getIsAvailableForVehicle',record.object)==true then
                        local ok,reason=pcall(function()
                            job:applyCurrentState(record.object,g_currentMission,c.farmId,false)
                            local x,z=FMAUtil.position(record.object)
                            if x and job.positionAngleParameter then job.positionAngleParameter:setPosition(x,z) end
                            job.unloadingStationParameter:setUnloadingStation(destination)
                            job.loopingParameter:setIsLooping(false)
                            job:setValues()
                            local valid,why=job:validate(c.farmId)
                            if valid~=true then error('Doručení odmítnuto: '..tostring(why)) end
                            local startable,state=job:getIsStartable(nil)
                            if startable~=true then error('AI nemůže vyjet: '..tostring(state)) end
                        end)
                        if ok then
                            local t={id='haulageDelivery:'..record.key,kind='supportDelivery',operation='supply',
                                parentTaskId=s.parentTaskId,fieldId=s.fieldId,label='Vykládka odvozce '..tostring(record.name),state='running'}
                            c.active[job]={job=job,task=t,vehicle=record,start=c.now,lastProgress=c.now,
                                x=record.x,z=record.z,trafficTarget=target,haulageSession=s}
                            c.reservations[record.key]=t.id;record.busy=true
                            local started,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,c.farmId)
                            if started then
                                s.state='DELIVERING';s.job=job;s.destination=destination;s.nextTryAt=0
                                report(c,s,'JEDE_VYSYPAT','AI vykládka spuštěna; potvrzení až po poklesu nákladu')
                                return true
                            end
                            c.active[job]=nil;c.reservations[record.key]='haulageCycle:'..record.key
                            lastReason=tostring(err)
                        else lastReason=tostring(reason) end
                    else lastReason='Souprava nepodporuje AIJobDeliver' end
                    s.failedDestinations=s.failedDestinations or {};s.failedDestinations[destination]=true
                    if FMATraffic then FMATraffic.release(c.traffic,record.key) end
                else
                    -- Congestion is temporary and must NOT blacklist a real silo.
                    return nil,trafficReason or 'Silo má obsazený příjezd'
                end
            else
                lastReason='Vykládka nemá ověřený AI nájezd'
                s.failedDestinations=s.failedDestinations or {};s.failedDestinations[destination]=true
            end
        end
    end
    return false,lastReason
end

function FMAHaulageCycle.onDeliveryStopped(c,active)
    local s=active and active.haulageSession or (active and active.vehicle and live(c,active.vehicle.key))
    if not s then return false end
    local remaining=FMAHaulageCycle.cargo(s.record,s.fillType)
    s.job=nil
    if remaining<=math.max(2,(s.before or 0)*0.05) then
        s.state='RETURN_FIELD';s.nextTryAt=(c.now or 0)+2500;s.attempts=0
        report(c,s,'VYSYPÁNO','Vyloženo '..math.floor(math.max(0,(s.before or 0)-remaining))..' l; návrat k poli')
    else
        s.state='NEED_DELIVERY';s.before=remaining
        s.attempts=(s.attempts or 0)+1
        s.failedDestinations=s.failedDestinations or {}
        if s.destination then s.failedDestinations[s.destination]=true end
        s.nextTryAt=(c.now or 0)+math.min(60000,5000*s.attempts)
        report(c,s,'NEDOVYLOŽENO','Vůz stále obsahuje '..math.floor(remaining)..' l; hledá jinou vykládku')
        if s.attempts>=4 then s.state='BLOCKED';report(c,s,'BLOKACE','Vykládka selhala 4x; plný vůz zůstává bezpečně rezervován') end
    end
    c.reservations[s.record.key]='haulageCycle:'..s.record.key;s.record.busy=true
    return true
end

function FMAHaulageCycle.update(c)
    for key,s in pairs(c.haulageCycles or {}) do
        if (c.now or 0)>=(s.nextTryAt or 0) and c.settings and c.settings.enabled then
            local record=s.record
            local parent=c.tasks and c.tasks[s.parentTaskId]
            if not record or not record.object then
                s.state='BLOCKED';report(c,s,'BLOKACE','Vozidlo zmizelo během odvozu')
            elseif c.excluded and c.excluded[key] then
                s.nextTryAt=(c.now or 0)+5000
            elseif FMAGameNative and FMAGameNative.isManuallyControlled(record.object) then
                s.nextTryAt=(c.now or 0)+5000
            elseif s.state=='NEED_DELIVERY' then
                local amount=FMAHaulageCycle.cargo(record,s.fillType)
                if amount<=2 then
                    s.state='RETURN_FIELD';s.nextTryAt=(c.now or 0)+2500
                    report(c,s,'VYSYPÁNO','Vůz byl vyložen ručně; pokračuje četa')
                else
                    local success,why=startDelivery(c,s)
                    if success~=true then
                        s.nextTryAt=(c.now or 0)+(success==nil and 6000 or 12000)
                        if success==false then
                            s.attempts=(s.attempts or 0)+1
                            if s.attempts>=4 then s.state='BLOCKED' end
                        end
                        report(c,s,s.state=='BLOCKED' and 'BLOKACE' or 'ČEKÁ_NA_VYKLÁDKU',why)
                    end
                end
            elseif s.state=='RETURN_FIELD' then
                if FMAUtil.call(record.object,'getIsAIActive')==true then
                    s.nextTryAt=(c.now or 0)+3000
                elseif approved(c,parent) and FMAFleetCoordinator and FMAFleetCoordinator.startStageToField then
                    local role=FMAFleetCoordinator.getPreparedRole(c,parent,s.slot or 1)
                    -- During delivery the old CP role is still ACTIVE; reset before
                    -- requesting the next physical stage, never teleport to the field.
                    if role and role.record and role.record.key==key then role.state='READY' end
                    c.reservations[key]=nil;record.busy=false
                    local started,why=FMAFleetCoordinator.startStageToField(c,parent,record,s.slot or 1,role and role.tool)
                    if started then
                        c.haulageCycles[key]=nil
                        report(c,s,'NAVRAT_K_POLI','Jede na skutečné čekací stanoviště, pak znovu k mlátičce')
                    else
                        c.reservations[key]='haulageCycle:'..key;record.busy=true
                        s.attempts=(s.attempts or 0)+1
                        s.nextTryAt=(c.now or 0)+math.min(60000,6000*s.attempts)
                        if s.attempts>=5 then s.state='BLOCKED' end
                        report(c,s,s.state=='BLOCKED' and 'BLOKACE' or 'ČEKÁ_NA_NÁVRAT',why)
                    end
                else
                    -- The approved field is complete/cancelled. No new harvest jobs.
                    c.reservations[key]=nil;record.busy=false;c.haulageCycles[key]=nil
                    report(c,s,'DOKONČENO','Pole již nepožaduje odvoz; souprava je volná')
                end
            end
        end
    end
end

-- CP can operate its own full->silo->return cycle. Watch its physical cargo
-- delta and intervene only after a sustained full/no-progress condition.
function FMAHaulageCycle.monitor(c)
    for _,a in pairs(c.active or {}) do
        if a.task and a.task.kind=='support' and not a.task.forageBunker and not a.haulageStopRequested then
            local level,cap=FMAHaulageCycle.cargo(a.vehicle,a.task.fillType)
            local now=c.now or 0
            local prev=a.haulageObservedFill
            if prev==nil or math.abs(level-prev)>math.max(2,cap*0.002) then
                a.haulageLastCargoChange=now
                a.haulageObservedFill=level
            end
            -- A full trailer may already be driving to a distant silo.
            -- A MOVING vehicle must not be interrupted merely because the
            -- unloading level has not yet started falling.
            local px,pz=FMAUtil.position(a.vehicle and a.vehicle.object)
            if px and pz then
                if a.haulagePosX and (px-a.haulagePosX)^2+(pz-a.haulagePosZ)^2>12*12 then
                    a.haulageLastCargoChange=now
                end
                a.haulagePosX=px;a.haulagePosZ=pz
            end
            if cap>100 and level/cap>=0.97 and
                now-(a.haulageLastCargoChange or a.start or now)>120000 then
                a.haulageStopRequested=true
                a.task.phase='PLNÝ VŮZ · PŘEPNUTÍ NA VYKLÁDKU'
                report(c,{record=a.vehicle},'CP_NEVYSYPAL','Plný náklad 120 s bez změny; bezpečné ukončení CP')
                FMAAI.stop(a.job)
            end
        end
    end
end
