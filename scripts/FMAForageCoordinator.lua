-- Sequential forage/straw workflow: one crew hands a clean field to the next.
-- Mow -> ted when required -> windrow -> bale/forage wagon -> storage/destination.
-- Following pickup machines reuse the windrower's exact Courseplay centerline when available.
FMAForageCoordinator = {}
FMAForageCoordinator.MODES={[0]='AUTO',[1]='SENO / BALÍKY',[2]='SENÁŽ / BALÍKY',[3]='VOLNÁ PÍCE'}

local function hasCapability(controller,op)
    local def=FMACatalog.operations[op];if not def then return false end
    for _,v in ipairs(controller.vehicles or {}) do if v.capabilities and v.capabilities[def.cap] and not controller.excluded[v.key] then return true end end
    if FMAAssembler and FMAAssembler.hasPotential then return FMAAssembler.hasPotential(controller,op) end
    return false
end

function FMAForageCoordinator.mode(controller)
    local m=math.floor(tonumber(controller.settings.forageMode) or 0)
    if m~=0 then return m end
    if hasCapability(controller,'foragePickup') then return 3 end
    if hasCapability(controller,'bale') then return hasCapability(controller,'ted') and 1 or 2 end
    return 3
end

function FMAForageCoordinator.modeLabel(settings)
    return FMAForageCoordinator.MODES[math.floor(tonumber(settings.forageMode) or 0)] or 'AUTO'
end

local function fruitHasWindrow(task)
    if not task or not task.fruitIndex or not g_fruitTypeManager then return false end
    local fruit=FMAUtil.call(g_fruitTypeManager,'getFruitTypeByIndex',task.fruitIndex)
    if not fruit then return false end
    local ix=fruit.windrowFillTypeIndex or fruit.windrowFillType
    if FillType and ix==FillType.UNKNOWN then return false end
    return ix~=nil and ix~=0
end

function FMAForageCoordinator.afterOperation(controller,task)
    if not controller.settings.autoForageChain or not task or not task.fieldId then return end
    local stage
    if task.operation=='mow' then stage='mowed'
    elseif task.operation=='ted' then stage='tedded'
    elseif task.operation=='windrow' then
        local previous=controller.forageStages[tostring(task.fieldId)]
        stage=previous=='tedded' and 'windrowedHay' or 'windrowedGrass'
    elseif task.operation=='bale' then stage='baled'
    elseif task.operation=='foragePickup' then stage='pickedUp'
    elseif task.operation=='harvest' and controller.settings.strawRecovery and fruitHasWindrow(task) then stage='strawReady' end
    if stage then controller.forageStages[tostring(task.fieldId)]=stage end
end

function FMAForageCoordinator.nextOperation(controller,field)
    if not controller.settings.autoForageChain then return nil end
    local id=tostring(field.id);local stage=controller.forageStages[id]
    if field.ready and (stage=='collected' or stage=='baledStored') then controller.forageStages[id]=nil;stage=nil end
    if stage=='mowed' then
        local mode=FMAForageCoordinator.mode(controller)
        if mode==1 and hasCapability(controller,'ted') then return 'ted','Po sečení: obracení na seno' end
        return 'windrow','Po sečení: shrnout do přesných řádků'
    elseif stage=='tedded' then return 'windrow','Po obracení: shrnout seno do řádků'
    elseif stage=='windrowed' or stage=='windrowedGrass' or stage=='windrowedHay' then
        local mode=FMAForageCoordinator.mode(controller)
        if mode==3 then return 'foragePickup','Řádky: sběr sběracím vozem' end
        return 'bale',mode==2 and 'Řádky: lisování pro senáž' or 'Řádky: lisování sena'
    elseif stage=='strawReady' then
        if hasCapability(controller,'bale') then return 'bale','Po sklizni: lisování slámy z řádků' end
        return 'foragePickup','Po sklizni: sběr slámy z řádků'
    end
    return nil
end

function FMAForageCoordinator.task(controller,field,op,reason)
    local def=FMACatalog.operations[op]
    local t={id='forage:'..tostring(field.id)..':'..op,kind='field',fieldId=tostring(field.id),operation=op,
        priority=(def and def.priority or 70)+2,label=field.name..' · '..(def and def.label or op),state='pending',attempts=0,
        x=field.x,z=field.z,reason=reason,forageChain=true}
    if op=='foragePickup' then
        local stage=controller.forageStages[tostring(field.id)]
        if FillType then
            if stage=='strawReady' then t.expectedFillType=FillType.STRAW
            elseif stage=='windrowedHay' then t.expectedFillType=FillType.DRYGRASS_WINDROW or FillType.DRYGRASS
            else t.expectedFillType=FillType.GRASS_WINDROW or FillType.GRASS end
        end
    end
    return t
end

function FMAForageCoordinator.proposals(controller)
    local out={}
    for _,field in ipairs(controller.fields or {}) do
        local p=controller.policies[field.id]
        if p and p.enabled~=false then
            local op,reason=FMAForageCoordinator.nextOperation(controller,field)
            if op then out[#out+1]=FMAForageCoordinator.task(controller,field,op,reason) end
        end
    end
    return out
end

local function loadedFillType(record)
    for _,o in ipairs(FMAWorld.children(record.object)) do
        for i,_ in pairs(FMAUtil.call(o,'getFillUnits') or (o.spec_fillUnit and o.spec_fillUnit.fillUnits) or {}) do
            local level=FMAUtil.call(o,'getFillUnitFillLevel',i) or 0
            local ft=FMAUtil.call(o,'getFillUnitFillType',i)
            if FMAModHubAdapter.cargoUnit(o,i) and level>1 and ft and (not FillType or ft~=FillType.DIESEL) then return ft,level end
        end
    end
end

function FMAForageCoordinator.beginDelivery(controller,active)
    if active.task.operation~='foragePickup' then return false end
    local record=active.vehicle;local ft=loadedFillType(record)
    if not ft then return false,'Sběrací vůz po práci nemá náklad' end
    -- Fermentable forage goes to an owned bunker first when the map exposes a compatible bunker.
    -- The bunker coordinator decides per actual vehicle whether the safer access is drive-through or reverse.
    if controller.settings.bunkerAutomation and controller.settings.bunkerDeliveryAutomation and FMABunkerCoordinator then
        local target=FMABunkerCoordinator.bestBunker(controller,ft,record)
        if target then
            local ok,why=FMABunkerCoordinator.beginForageDelivery(controller,active,ft)
            if ok then return true end
            if why and (why:find('rezervovaná',1,true) or why:find('Čeká na uvolnění',1,true)) then
                return FMALifecycle.defer(controller,'forageWait:'..record.key,record,active.task,function() return FMAForageCoordinator.beginDelivery(controller,active) end,why)
            end
            return false,why
        end
    end
    local destination=FMALogistics and FMALogistics.bestDestination(controller.farmId,nil,ft,false)
    if not destination then
        controller:issue('forageDest:'..tostring(active.task.fieldId),active.task.label..' · chybí cíl','Není nalezena vlastní AI vykládací stanice pro '..FMAWorld.fillName(ft)..'. Urči/skladuj materiál ručně.',94)
        return false,'Chybí vlastní cíl pro '..FMAWorld.fillName(ft)
    end
    if FMATraffic and FMATraffic.canStart then
        local dx,dz=FMAUtil.position(destination)
        local free,wait=FMATraffic.canStart(controller,record,{x=dx or record.x,z=dz or record.z},{id='forageDelivery:'..active.task.fieldId,kind='forageDelivery'},60000)
        if not free then return FMALifecycle.defer(controller,'forageWait:'..record.key,record,active.task,function() return FMAForageCoordinator.beginDelivery(controller,active) end,wait) end
    end
    if AIJobDeliver==nil then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,'Chybí AIJobDeliver' end
    local job=FMAAI.createRegisteredJob("DELIVER",AIJobDeliver)
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,'Nelze vytvořit registrovaný AIJobDeliver' end
    if not job:getIsAvailableForVehicle(record.object) then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,'Sběrací souprava nepodporuje AI doručení' end
    job:applyCurrentState(record.object,g_currentMission,controller.farmId,false)
    local x,z=FMAUtil.position(record.object);if x and z and job.positionAngleParameter then job.positionAngleParameter:setPosition(x,z) end
    job.unloadingStationParameter:setUnloadingStation(destination)
    job.loopingParameter:setIsLooping(false);job:setValues()
    local valid,why=job:validate(controller.farmId);if not valid then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(why or 'AI odmítla vykládku') end
    local startable,state=job:getIsStartable(nil);if not startable then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,'AI doručení nelze spustit: '..tostring(state) end
    local t={id='forageDelivery:'..active.task.fieldId..':'..record.key,kind='forageDelivery',operation='supply',fieldId=active.task.fieldId,
        label='Odvoz píce · pole '..active.task.fieldId,parentTask=active.task,state='running',priority=90}
    controller.reservations[record.key]=t.id;record.busy=true
    controller.active[job]={job=job,task=t,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(err) end
    active.task.state='running';active.task.reason='Odvoz materiálu do vlastního skladu / sila'
    controller:notify(record.name..' odváží '..FMAWorld.fillName(ft)..' do vlastního cíle')
    return true
end

function FMAForageCoordinator.onDeliveryStopped(controller,active)
    local parent=active.task.parentTask;local record=active.vehicle
    if active.stopReason then
        if parent then parent.state='blocked';parent.reason=active.stopReason end
        controller:issue(active.task.id,active.task.label,active.stopReason,92);return
    end
    if loadedFillType(record) then FMAJobs.fail(controller,parent,record,'Po doručení zůstal materiál ve voze');return end
    if FMAForageCoordinator.resumeAfterDelivery(controller,parent,record) then return end
    if parent then
        controller.forageStages[tostring(parent.fieldId)]='collected'
        parent.state='cooldown';parent.reason='Píce odvezena · kontrola pole';parent.retryAt=controller.now+30000
    end
    if controller.settings.autoReturn and FMAReturnManager then
        local ok,why=FMAReturnManager.begin(controller,{task=parent,vehicle=record})
        if ok then return end
        if why then FMAUtil.log('Návrat po odvozu píce: '..tostring(why)) end
    end
    if parent then parent.state='done';parent.reason='Píce odvezena' end
end

function FMAForageCoordinator.resumeAfterDelivery(c,parent,record)
    if not parent or not parent.resumeAfterDelivery then return false end
    parent.resumeAfterDelivery=nil;parent.resumeAtLast=true
    parent.state='pending';parent.reason='Náklad vyložen · pokračování od posledního bodu';parent.retryAt=c.now+3000
    parent.preferredVehicleKey=record.key
    if parent.kind=='field' then c.tasks[parent.id]=parent end
    c.reservations[record.key]=nil;record.busy=false
    c.elapsed=(c.settings.scanSeconds or 12)*1000
    return true
end
