-- Automatic bale destination. Only real owned FS25 ObjectStorage triggers are
-- considered. Actual bale fill types are checked before a collector is sent to
-- a storage, so hay/straw/silage bales are not intentionally mixed into an
-- incompatible destination.
FMABaleStorage = {}

local function placeables()
    local ps=g_currentMission and g_currentMission.placeableSystem
    return (ps and ps.placeables) or FMAUtil.call(ps,'getPlaceables') or {}
end

local function baleLoader(root)
    for _,o in ipairs(FMAWorld.children(root)) do if o.spec_baleLoader then return o end end
end

local function loaderLevel(loader)
    if not loader or not loader.spec_baleLoader then return 0 end
    local loaded=FMAUtil.call(loader,'getLoadedBales')
    if type(loaded)=='table' then local n=0;for _ in pairs(loaded) do n=n+1 end;if n>0 then return n end end
    local ix=loader.spec_baleLoader.fillUnitIndex
    return (ix and FMAUtil.call(loader,'getFillUnitFillLevel',ix)) or 0
end

local function baleFillType(bale)
    return bale and (FMAUtil.call(bale,'getFillType') or bale.fillType or (bale.spec_bale and bale.spec_bale.fillType)) or nil
end

local function loaderTypes(loader)
    local types={}
    if not loader then return types end
    local loaded=FMAUtil.call(loader,'getLoadedBales')
    if type(loaded)=='table' then
        for _,b in pairs(loaded) do local ft=baleFillType(b);if ft then types[ft]=(types[ft] or 0)+1 end end
    end
    return types
end

local function storageSupports(storage,fillType)
    if not storage or not fillType then return false end
    local p=storage.object;local spec=p and p.spec_objectStorage
    if p and type(p.getObjectStorageSupportsFillType)=='function' then
        local ok,value=pcall(p.getObjectStorageSupportsFillType,p,fillType)
        if ok and value~=nil then return value==true end
    end
    local supported=spec and spec.supportedFillTypes
    if type(supported)=='table' then
        if supported[fillType]~=nil then return supported[fillType]==true or supported[fillType]==fillType end
        for _,ft in pairs(supported) do if ft==fillType then return true end end
        return false
    end
    return false
end

local function allSupported(storage,fillTypes)
    if next(fillTypes or {})==nil then return false end
    for ft,count in pairs(fillTypes or {}) do if count>0 and not storageSupports(storage,ft) then return false end end
    return true
end

local function typeSummary(fillTypes)
    local rows={};for ft,count in pairs(fillTypes or {}) do rows[#rows+1]={name=FMAWorld.fillName(ft),count=count} end
    table.sort(rows,function(a,b)return tostring(a.name)<tostring(b.name) end)
    local parts={};for _,r in ipairs(rows) do parts[#parts+1]=r.name..' '..r.count..'×' end
    return #parts>0 and table.concat(parts,' · ') or 'typ balíků nezjištěn'
end

function FMABaleStorage.scan(controller)
    controller.baleStorages={}
    if not controller.settings.baleStorageAutomation then return end
    for _,p in pairs(placeables()) do
        local spec=p.spec_objectStorage
        if spec and spec.supportsBales~=false and FMAUtil.owner(p)==controller.farmId then
            local node=spec.objectTriggerNode or p.rootNode
            local x,z=FMAUtil.position(p)
            if node and node~=0 and getWorldTranslation then local ok,tx,_,tz=pcall(getWorldTranslation,node);if ok then x,z=tx,tz end end
            local count=tonumber(spec.numStoredObjects) or 0
            if type(spec.storedObjects)=='table' then count=0;for _ in pairs(spec.storedObjects) do count=count+1 end end
            local nativeSummary=FMAUtil.call(p,'getObjectStorageObjectInfos')
            if type(nativeSummary)=='table' then
                local summed=0
                for _,group in pairs(nativeSummary) do
                    if type(group)=='table' then
                        summed=summed+(tonumber(group.count or group.numObjects or group.numStoredObjects) or 0)
                    end
                end
                if summed>0 then count=summed end
            end
            local cap=tonumber(spec.capacity) or 250
            local storedTypes={}
            for _,obj in pairs(spec.storedObjects or {}) do
                local candidate=obj.object or obj
                local ft=baleFillType(candidate);if ft then storedTypes[ft]=(storedTypes[ft] or 0)+1 end
            end
            controller.baleStorages[#controller.baleStorages+1]={object=p,name=FMAUtil.name(p),x=x,z=z,node=node,count=count,capacity=cap,
                free=math.max(0,cap-count),storedFillTypes=storedTypes,nativeObjectInfos=nativeSummary,
                physicallyRetrievable=type(p.removeAbstractObjectsFromStorage)=='function',
                supportsBales=spec.supportsBales~=false}
        end
    end
end

function FMABaleStorage.find(controller,record,fillTypes)
    local best,bestScore=nil,math.huge
    local reserve=controller.settings.baleStorageReserve or 0
    local incoming=0;for _,count in pairs(fillTypes or {}) do incoming=incoming+count end
    for _,s in ipairs(controller.baleStorages or {}) do
        if s.free>=incoming+reserve and s.x and s.z and allSupported(s,fillTypes) then
            local d=FMAUtil.distance(record,s) or 999999
            local same=0
            if controller.settings.baleSortByFillType~=false then for ft,count in pairs(fillTypes or {}) do if count>0 and (s.storedFillTypes[ft] or 0)>0 then same=same+1 end end end
            -- Prefer a compatible nearby store; when sorting is enabled, already-used
            -- storage for the same bale type receives a meaningful bonus.
            local score=d-same*250-(math.min(s.free,1000)*0.02)
            if score<bestScore then best=s;bestScore=score end
        end
    end
    return best
end

function FMABaleStorage.beginDelivery(controller,active,retryWait)
    if not controller.settings.baleStorageAutomation then return false,'Automatické ukládání balíků je vypnuté' end
    local record=active.vehicle;local loader=record and baleLoader(record.object)
    if not loader or loaderLevel(loader)<=0 then return false,'Sběrač nemá naložené balíky' end
    local fillTypes=loaderTypes(loader)
    if next(fillTypes)==nil and active.task then fillTypes=active.task.baleFillTypes or {} end
    local storage=FMABaleStorage.find(controller,record,fillTypes)
    if not storage then
        controller:issue('baleStorage:'..tostring(active.task.fieldId),'Balíky · chybí kompatibilní sklad',
            typeSummary(fillTypes)..' · nenalezen vlastní ObjectStorage s podporou těchto balíků a bezpečnou volnou kapacitou. Manager je nevyhodí do náhodné kolny.',92)
        return false,'Chybí kompatibilní sklad balíků'
    end
    local task={id='baleDelivery:'..tostring(active.task.fieldId)..':'..record.key,kind='baleDelivery',operation='baleCollect',fieldId=active.task.fieldId,
        label='Balíky → '..storage.name,parentTask=active.task,storage=storage,loader=loader,state='running',priority=82,baleFillTypes=fillTypes,baleTypeSummary=typeSummary(fillTypes)}
    if controller.settings.trafficSafety and FMATraffic then
        local okTraffic,why=FMATraffic.canStart(controller,record,{x=storage.x,z=storage.z},task,90000)
        if not okTraffic then
            controller.baleDeliveryWaits=controller.baleDeliveryWaits or {}
            controller.baleDeliveryWaits[record.key]={active=active,readyAt=(controller.now or 0)+math.max(1500,(controller.settings.trafficRetrySeconds or 6)*1000),reason=why}
            controller.reservations[record.key]='baleDeliveryWait:'..record.key;record.busy=true
            if not retryWait then controller:notify(record.name..' čeká s balíky na volný příjezd ke skladu') end
            return true,'WAITING_TRAFFIC'
        end
    end
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=storage.x,z=storage.z,angle=0,tolerance=controller.settings.baleStorageTolerance or 12})
    if not job then if controller.traffic then FMATraffic.release(controller.traffic,record.key) end;return false,moveWhy or 'Sběrač neumí autonomní přesun do skladu' end
    controller.reservations[record.key]=task.id;record.busy=true
    controller.active[job]={job=job,task=task,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,transferMethod=moveMethod,trafficTarget={x=storage.x,z=storage.z}}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;if controller.traffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(err) end
    controller:notify(record.name..' veze '..task.baleTypeSummary..' do '..storage.name)
    return true
end

function FMABaleStorage.onStopped(controller,active)
    local t=active.task;local record=active.vehicle;local loader=t.loader
    if active.stopReason then
        controller.reservations[record.key]=nil;record.busy=false;if controller.traffic then FMATraffic.release(controller.traffic,record.key) end
        controller:issue(t.id,t.label,active.stopReason,90);return
    end
    local x,z=FMAUtil.position(record.object)
    if not x or not t.storage or ((x-t.storage.x)^2+(z-t.storage.z)^2)>(controller.settings.baleStorageTolerance or 12)^2 then
        controller.reservations[record.key]=nil;record.busy=false;if controller.traffic then FMATraffic.release(controller.traffic,record.key) end
        controller:issue(t.id,t.label,'Sběrač nedojel do spouště skladu balíků',90);return
    end
    if FMAUtil.owner(t.storage.object)~=controller.farmId then FMAJobs.fail(controller,t,record,'Sklad změnil majitele');return end
    local triggers=loader.spec_baleLoader and loader.spec_baleLoader.baleUnloadTriggers
    if not triggers or triggers[t.storage.object]==nil then
        FMAJobs.fail(controller,t,record,'Sběrač nevjel do skutečné vykládací spouště skladu');return
    end
    local bales=FMAUtil.call(loader,'getLoadedBales') or {}
    if #bales==0 then FMAJobs.fail(controller,t,record,'Naložené balíky nelze ověřit');return end
    for _,bale in ipairs(bales) do
        if FMAUtil.call(t.storage.object,'getObjectStorageCanStoreObject',bale,true)~=true then
            FMAJobs.fail(controller,t,record,'Sklad nepřijímá tento balík / je plný');return
        end
    end
    local started=false
    if type(loader.startAutomaticBaleUnloading)=='function' and FMAUtil.call(loader,'getIsAutomaticBaleUnloadingAllowed')==true then
        started=pcall(loader.startAutomaticBaleUnloading,loader)
    end
    if not started then FMAJobs.fail(controller,t,record,'Sběrač zatím nemůže bezpečně spustit automatické vyložení');return end
    controller.reservations[record.key]=t.id;record.busy=true
    controller.baleUnloadSessions[record.key]={record=record,loader=loader,parent=t.parentTask,storage=t.storage,start=controller.now,started=started,baleFillTypes=t.baleFillTypes,expectedBales=#bales,storedBefore=t.storage.object.spec_objectStorage.numStoredObjects or #t.storage.object.spec_objectStorage.storedObjects}
    controller:notify(record.name..' vykládá '..t.baleTypeSummary..' do '..t.storage.name)
end

function FMABaleStorage.update(controller)
    for key,w in pairs(controller.baleDeliveryWaits or {}) do
        if (w.readyAt or 0)<=controller.now then
            local record=w.active and w.active.vehicle
            controller.baleDeliveryWaits[key]=nil
            if record then controller.reservations[key]=nil;record.busy=false end
            local ok,why=FMABaleStorage.beginDelivery(controller,w.active,true)
            if not ok and record then
                controller.reservations[key]=nil;record.busy=false
                controller:issue('baleDeliveryWait:'..key,'Balíky · čekání na sklad',tostring(why or 'Přejezd do skladu se nepodařilo znovu spustit'),90)
            end
        end
    end
    for key,s in pairs(controller.baleUnloadSessions or {}) do
        local level=loaderLevel(s.loader)
        local spec=s.storage.object.spec_objectStorage
        local stored=(spec.numStoredObjects or #(spec.storedObjects or {}))-s.storedBefore
        if level<=0.01 and stored>=s.expectedBales then
            controller.baleUnloadSessions[key]=nil;controller.reservations[key]=nil;s.record.busy=false
            if controller.traffic then FMATraffic.release(controller.traffic,key) end
            local resumed=FMAForageCoordinator.resumeAfterDelivery(controller,s.parent,s.record)
            if not resumed and s.parent then controller.forageStages[tostring(s.parent.fieldId)]='collected';s.parent.state='cooldown';s.parent.reason='Balíky uloženy · kontrola pole';s.parent.retryAt=controller.now+30000 end
            controller:notify(s.record.name..' uložil balíky do '..s.storage.name)
            local ok=resumed or controller.settings.autoReturn and FMAReturnManager and FMAReturnManager.begin(controller,{task=s.parent,vehicle=s.record})
            if not ok and s.parent then s.parent.state='done';s.parent.reason='Balíky uloženy' end
        elseif controller.now-s.start>45000 then
            controller.baleUnloadSessions[key]=nil;controller.reservations[key]=nil;s.record.busy=false
            if controller.traffic then FMATraffic.release(controller.traffic,key) end
            if s.parent then s.parent.state='blocked';s.parent.reason='Vykládání balíků ve skladu nebylo dokončeno' end
            controller:issue('baleUnload:'..key,'Balíky · '..s.storage.name,'Automatické vyložení se nedokončilo. Zkontroluj polohu sběrače a typ skladu.',92)
        end
    end
end


function FMABaleStorage.cancelAll(controller)
    for key,w in pairs(controller.baleDeliveryWaits or {}) do
        local record=w.active and w.active.vehicle
        if record then record.busy=false;controller.reservations[key]=nil;if controller.traffic then FMATraffic.release(controller.traffic,key) end end
        controller.baleDeliveryWaits[key]=nil
    end
    for key,s in pairs(controller.baleUnloadSessions or {}) do
        FMALifecycle.cancelSession(controller,controller.baleUnloadSessions,key,s,'Pozastaveno majitelem během vykládání balíků')
    end
end
