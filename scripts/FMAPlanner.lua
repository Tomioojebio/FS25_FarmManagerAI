-- Pure planning: no engine calls, no vehicle, money, crop or inventory mutations.
FMAPlanner = {}

function FMAPlanner.nextOperation(field, policy, settings)
    if policy.enabled == false then return nil,"Pole vyřazeno ze správy" end
    if not field.valid then return nil,field.reason or "Stav pole se nepodařilo ověřit" end
    if field.grass then
        if field.ready then return "mow" end
        -- Lime, plowing and stones are soil operations. Do not send a tractor
        -- through a standing forage crop just because the field-info panel says
        -- the soil will need lime later. Weed/fertilizer remain valid crop care.
        if field.needsWeed and settings.cropCare then return "weed" end
        if field.needsFertilize and settings.cropCare then return "fertilize" end
        return nil,"Pícnina roste · půdní práce až po sklizni"
    end
    if field.ready then return "harvest" end
    if field.alive then
        if field.needsWeed and settings.cropCare then return "weed" end
        if field.needsFertilize and settings.cropCare then return "fertilize" end
        if field.needsRoll and settings.cropCare then return "roll" end
        return nil,"Porost roste · vápnění/orba/kameny až po sklizni"
    end
    if not field.bare then return nil,"Nestandardní nebo neurčený stav; kontrola majitelem" end
    if field.needsLime and settings.cropCare then return "lime" end
    if field.needsPlow then return "plow" end
    if field.needsStone and settings.cropCare then return "stone" end
    if not field.prepared then return "cultivate" end
    if not policy.crop or policy.crop == "" then return nil,"Vyber plodinu pro další setí" end
    return "sow"
end

function FMAPlanner.makeTask(field, op, crop)
    local def = FMACatalog.operations[op]
    return {id="field:"..field.id..":"..op, kind="field", fieldId=field.id, operation=op,
        crop=crop, priority=def.priority, label=field.name.." · "..def.label,
        state="pending", phase="PLÁN", attempts=0, x=field.x, z=field.z, fingerprint=field.fingerprint}
end

function FMAPlanner.merge(oldTasks, proposals, now)
    local nextTasks = {}
    for id, task in pairs(oldTasks) do
        if task.state == "running" or task.state == "assembling" or task.state == "returning" or task.state == "handover" or task.state == "paused" or task.state == "preparing" or task.state == "waiting" then nextTasks[id] = task end
    end
    for _, candidate in ipairs(proposals) do
        local old = oldTasks[candidate.id]
        if old ~= nil then
            local mutable=old.state~="running" and old.state~="assembling" and old.state~="preparing" and old.state~="waiting" and old.state~="returning" and old.state~="handover"
            local fingerprintChanged=mutable and old.fingerprint~=nil and candidate.fingerprint~=nil and old.fingerprint~=candidate.fingerprint
            if mutable then
            for _,key in ipairs({"x","z","fruitIndex","crop","source","destination","available","free","fillType","allowPublicDestination","isSale","requiresSaleApproval","saleQuantity","marketAlternatives","marketProposal","pricePerLiter","mixturePlan","mixtureFillType","needed","husbandry","fingerprint"}) do
                if not (key=="destination" and old.marketTargetPinned==true) then old[key]=candidate[key] end
            end
            -- Deficit work orders reflect live reality. A newly inaccessible husbandry
            -- source/trigger must immediately revoke a formerly runnable SUPPLY job;
            -- otherwise an old approved delivery can be sent to a now invalid goal.
            -- Conversely, equipment/trigger purchased by the player can reopen it.
            -- Preserve explicit owner STOP and do not mutate an already active AI job.
            local dynamicCare=candidate.id:sub(1,15)=='livestock:care:'
            local dynamicBunker=candidate.kind=='bunkerWorkOrder'
            if dynamicCare or dynamicBunker then
                old.label=candidate.label or old.label
                old.priority=candidate.priority or old.priority
                old.bunkerIndex=candidate.bunkerIndex
                old.bunkerKey=candidate.bunkerKey
                old.compactBefore=candidate.compactBefore
                old.fillBefore=candidate.fillBefore
                old.kind=candidate.kind
                old.operation=candidate.operation
                if candidate.state=='blocked' and old.ownerStopRequested~=true then
                    old.state='blocked';old.reason=candidate.reason
                    old.phase=candidate.phase;old.blockedByIntegration=candidate.blockedByIntegration==true
                    old.retryAt=0
                elseif candidate.state=='pending' and old.state=='blocked' and old.blockedByIntegration==true and old.ownerStopRequested~=true then
                    old.state='pending';old.reason=nil;old.blockedByIntegration=nil
                    old.phase=candidate.phase;old.retryAt=0;old.attempts=0
                end
            end
            if old.marketTargetPinned and old.marketAlternatives then
                local valid=false
                for _,p in ipairs(old.marketAlternatives) do
                    if p.station==old.destination and p.accessible then valid=true;break end
                end
                if not valid then old.marketTargetPinned=nil;old.destination=candidate.destination end
            end
            -- Reconsider a previously impossible animal delivery after the player
            -- buys equipment or a new ModHub map trigger appears. Retain approval;
            -- NEVER auto-start a task that the owner explicitly stopped.
            if old.blockedByIntegration and candidate.state=='pending' and not old.ownerStopRequested then
                old.state='pending';old.kind=candidate.kind;old.operation=candidate.operation
                old.phase=candidate.phase;old.reason=nil;old.blockedByIntegration=nil
                old.retryAt=0;old.attempts=0
            elseif candidate.kind=='livestockNeed' and old.state=='blocked' then
                old.reason=candidate.reason;old.phase=candidate.phase
            end
            if fingerprintChanged then
                -- The live field changed under the queued job. Never keep a stale manual
                -- machine/header choice that may no longer match the new crop/state.
                old.state="pending";old.phase="PLÁN";old.reason=nil;old.retryAt=0;old.attempts=0;old.failures=0;old.verificationAttempts=0;old.confirmedAiWorkFinish=nil
                old.preferredVehicleKey=nil;old.preferredVehicleName=nil
                if not old.forceHandoverImplement then old.preferredImplementKey=nil;old.preferredImplementName=nil end
                old.preferredCarrierKey=nil;old.preferredCarrierName=nil
                old.preferredSupportKeys=nil;old.preferredSupportNames=nil
                old.preferredSupportToolKeys=nil;old.preferredSupportToolNames=nil
            end
            end
            candidate = old
            if old.state == "done" and (old.retryAt or 0) <= now then
                old.state="pending"; old.attempts=0
            elseif old.state == "cooldown" and (old.retryAt or 0) <= now then
                old.state="pending"
            end
        end
        nextTasks[candidate.id] = candidate
    end
    return nextTasks
end

function FMAPlanner.queue(tasks)
    local result = {}
    for _, task in pairs(tasks) do result[#result+1]=task end
    table.sort(result,function(a,b)
        if (a.ownerRequested==true) ~= (b.ownerRequested==true) then return a.ownerRequested==true end
        if a.priority == b.priority then return a.id < b.id end
        return a.priority > b.priority
    end)
    return result
end

function FMAPlanner.vehicleMatches(task,v,reservations,excluded)
    local def=FMACatalog.operations[task.operation]
    if not def or not v or not v.capabilities[def.cap] then return false,"capability" end
    if task.failedVehicleKeys and task.failedVehicleKeys[v.key] then return false,"recoveryExcluded" end
    if v.busy or excluded[v.key] or reservations[v.key] or v.lowFuel then return false,"busy" end
    if (v.damage or 0)>=(task.criticalServiceDamage or 0.90) then return false,"service" end
    if task.ownerPinnedVehicle~=true and FMAWorld and FMAWorld.isAutoFieldPowerAllowed and not FMAWorld.isAutoFieldPowerAllowed(v,task.operation) then return false,"machineRole" end
    if task.operation=="sow" and v.sowingFruit~=task.crop then return false,"crop" end
    if task.operation=="harvest" then
        if v.isForageHarvester==true then return false,"machineType" end
        if v.isGrainCombine==false and v.hasCombine==true then return false,"machineType" end
        if v.harvestFruits[task.fruitIndex]~=true then return false,"fruit" end
    end
    if (v.requiredPowerKW or 0)>0 and (v.powerKW or 0)>0 and v.powerKW < v.requiredPowerKW*1.05 then return false,"power" end
    if task.kind=="supply" and task.fillType~=nil then
        local supports=(FMAFleetCoordinator and FMAFleetCoordinator.supportsTransportFillType and FMAFleetCoordinator.supportsTransportFillType(v,task.fillType))
            or (v.transportFillTypes and v.transportFillTypes[task.fillType]==true)
        if not supports then return false,"fill" end
    end
    if v.readyOperations and v.readyOperations[task.operation]==false then return false,"material" end
    return true
end

function FMAPlanner.vehicleScore(task,v,experience)
    local score=FMAUtil.distance(v,task)
    score=score+(v.damage or 0)*80+(v.wear or 0)*25
    local req=v.requiredPowerKW or 0
    local power=v.powerKW or 0
    if req>0 and power>0 then
        local reserve=(power-req)/math.max(req,1)
        if reserve<0.05 then score=score+500
        else score=score+math.abs(reserve-0.35)*18 end
    end
    local width=v.workWidth or 0
    if task.kind=="field" and width>0 then score=score-math.min(width,18)*1.8 end
    local mass=v.mass or 0
    if task.operation=="plow" or task.operation=="cultivate" or task.operation=="stone" or task.operation=="compact" then
        score=score-math.min(mass,30)*0.7
        -- For heavy draft work a front ballast that is already fitted is useful, but it
        -- never becomes a mandatory purchase/attachment. Existing ballast is simply a
        -- positive selection factor and remains attached while a rear implement is used.
        if v.hasBallast then score=score-18 end
    elseif task.operation=="fertilize" or task.operation=="lime" or task.operation=="weed" or task.operation=="roll" then
        score=score+math.min(mass,30)*0.15
    end
    local mode=tonumber(task.strategyMode) or 0
    if mode==1 then -- max performance
        score=score-math.min(width,24)*3.0-math.min(power/25,18)
    elseif mode==2 then -- economy: avoid unnecessary mass/power and long deadhead
        score=score+math.min(mass,35)*0.45+math.max(0,power-req*1.25)*0.03
    elseif mode==3 then -- preserve machinery condition
        score=score+(v.damage or 0)*220+(v.wear or 0)*140
    end
    if task.longJob and (v.damage or 0)>=(task.preventiveServiceDamage or 0.60) then score=score+180 end
    if FMAExperience and FMAExperience.penalty then score=score+FMAExperience.penalty(experience,task,v) end
    return score
end

function FMAPlanner.chooseVehicle(task, vehicles, reservations, excluded,experience)
    if not task or not FMACatalog or not FMACatalog.operations then return nil,"Neplatný úkol","configuration" end
    local definition=FMACatalog.operations[task.operation]
    if not definition then return nil,"Neznámá operace: "..tostring(task.operation),"configuration" end
    vehicles=vehicles or {};reservations=reservations or {};excluded=excluded or {}
    local cap=definition.cap
    local best, distance, found, ready = nil, math.huge, false, false
    task.selectionAudit={}
    if task.preferredVehicleKey then
        for _,v in ipairs(vehicles) do
            if v.key==task.preferredVehicleKey then
                local ok,why=FMAPlanner.vehicleMatches(task,v,reservations,excluded)
                task.selectionAudit[#task.selectionAudit+1]={key=v.key,name=v.name,ok=ok,reason=why or 'preferred',score=ok and FMAPlanner.vehicleScore(task,v,experience) or nil}
                if ok then return v end
                if why=="busy" then return nil,"Majitelem vybraný stroj je právě obsazený / bez paliva", "busy" end
                if why=="power" then return nil,"Majitelem vybraná souprava nemá dostatečný výkon", "configuration" end
                if why=="machineType" or why=="machineRole" then return nil,"Majitelem vybraný typ stroje není určený pro tuto práci", "configuration" end
                return nil,"Majitelem vybraný stroj není v aktuální konfiguraci připravený", "configuration"
            end
        end
    end
    for _, v in ipairs(vehicles) do
        if v and v.capabilities and v.capabilities[cap] then
            found=true
            if not v.busy and not excluded[v.key] and not reservations[v.key] then ready=true end
            local ok,why=FMAPlanner.vehicleMatches(task,v,reservations,excluded)
            local d=ok and FMAPlanner.vehicleScore(task,v,experience) or nil
            task.selectionAudit[#task.selectionAudit+1]={key=v.key,name=v.name,ok=ok,reason=why,score=d}
            if ok then
                if best == nil or d < distance then best,distance=v,d end
            end
        end
    end
    if best then return best end
    if not found then return nil,"Chybí připravená souprava", "equipment" end
    if not ready then return nil,"Vhodné stroje pracují, jsou vyřazeny nebo potřebují palivo", "busy" end
    return nil,"Zkontroluj zvolenou plodinu / adaptér / podporu nákladu", "configuration"
end

function FMAPlanner.canDispatch(settings, now, money, activeCount)
    if not settings.enabled then return false,"Správce vypnut" end
    if activeCount >= settings.maxWorkers then return false,"Limit pracovníků" end
    if money == nil then return false,"Nelze ověřit rozpočet" end
    if money < settings.reserve then return false,"Dosažena finanční rezerva" end
    return true
end
