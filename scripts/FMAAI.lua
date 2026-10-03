FMAAI = {}

-- FS25 saves the last AI job through AIJobVehicle. Jobs created or reused by external
-- mods must have a valid registered jobTypeIndex, otherwise the base-game save code can
-- dereference a missing job type. Always repair/verify it before a Farm Manager start.
function FMAAI.ensureJobType(job)
    local ok=FMAJobs.ensureType(job)
    return ok,ok and job.jobTypeIndex or nil
end

function FMAAI.createRegisteredJob(typeName)
    local ok,job=pcall(FMAJobs.create,typeName)
    if not ok then return nil,tostring(job) end
    return job,job.jobTypeIndex
end

function FMAAI.sanitizeVehicleJobHistory(controller)
    if not controller then return 0 end
    local repaired=0
    local seen={}
    local candidates={}
    -- Prefer the complete live vehicle list. A vehicle that was not classified by Farm Manager
    -- can still carry stale AIJobVehicle history and break the base-game save serializer.
    local all=g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles
    if all then
        for _,v in pairs(all) do
            if v and not seen[v] and FMAUtil.owner(v)==controller.farmId then
                seen[v]=true;candidates[#candidates+1]={object=v,name=FMAUtil.name(v)}
            end
        end
    end
    -- Test harnesses and early mission phases may not expose vehicleSystem yet.
    for _,record in ipairs(controller.vehicles or {}) do
        local v=record.object
        if v and not seen[v] then seen[v]=true;candidates[#candidates+1]={object=v,name=record.name or FMAUtil.name(v)} end
    end
    for _,record in ipairs(candidates) do
        local v=record.object
        local spec=v and v.spec_aiJobVehicle
        if spec and spec.lastJob then
            local ok=FMAAI.ensureJobType(spec.lastJob)
            if not ok then
                -- lastJob is only helper restart history; never sacrifice the career save for it.
                spec.lastJob=nil
                repaired=repaired+1
                FMAUtil.log("SAVE GUARD: odstraněna neplatná historie AI jobu u "..tostring(record.name))
            end
        end
        if spec and spec.job then
            local ok=FMAAI.ensureJobType(spec.job)
            if not ok then
                -- An active job with no registered type is exactly the state that made the
                -- FS25 serializer crash in the user's save. Stop it before saving; do not
                -- mutate the vehicle/job tables behind the AI system's back.
                if g_currentMission and g_currentMission.aiSystem and spec.job.isRunning then
                    pcall(g_currentMission.aiSystem.stopJob,g_currentMission.aiSystem,spec.job,AIMessageSuccessStoppedByUser.new())
                end
                repaired=repaired+1
                FMAUtil.log("SAVE GUARD: zastaven neplatný aktivní AI job u "..tostring(record.name))
            end
        end
    end
    controller.sanitizedJobHistory=(controller.sanitizedJobHistory or 0)+repaired
    return repaired
end

function FMAAI.start(controller,task,record)
    local vehicle=record.object
    if FMAUtil.owner(vehicle)~=controller.farmId then return nil,"Změnil se vlastník stroje" end
    if FMAUtil.call(vehicle,"getIsAIActive") or (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle)) then return nil,"Stroj již někdo ovládá" end
    if FMACompatibility.inspect(vehicle).externalBusy then return nil,"Stroj obsluhuje jiný mód / autoloader" end
    local job
    if task.kind=="field" then
        if task.operation=="harvest" or task.operation=="mow" then
            if FMAWorld.raining() then return nil,"Čeká na konec deště" end
        end
        if task.operation=="sow" then
            local fruit=FMAUtil.fruit(task.crop)
            local canPlant=FMAUtil.call(fruit,"getIsPlantableInPeriod",g_currentMission.missionInfo.growthMode,g_currentMission.environment.currentPeriod)
            if canPlant~=true then return nil,"Plodina není v ověřeném období setí" end
            if record.sowingFruit~=task.crop then return nil,"Na secím stroji zvol "..task.crop end
        end
        local field=controller.fieldsById[task.fieldId]
        if not field or not field.valid then return nil,"Pole není ověřeno" end
        if vehicle.updateAIFieldWorkerImplementData then vehicle:updateAIFieldWorkerImplementData() end
        if task.operation=='harvest' and (not record.isGrainCombine or not record.hasCutter) then
            return nil,'Kombajn nemá fyzicky dostupnou kompatibilní žací lištu; nejdřív ji musí převzít z podvozku nebo připojit'
        end
        if controller.settings.preferCourseplay and task.baseAIFallback~=true and FMAUtil.call(vehicle,'hasCpCourse')==true then
            local cpJob,cpWhy=FMACourseplay.startFieldwork(controller,record,task)
            if cpJob then return cpJob,'COURSEPLAY_PUBLIC_PENDING' end
            task.lastCourseplayStartError=cpWhy
        end
        if job==nil and controller.settings.precisionFieldwork and task.baseAIFallback~=true then
            -- A cutter riding on an attached header trailer specifically requires the
            -- Courseplay attach-header task; basic helper AI cannot replace that workflow.
            if FMAFieldQuality and FMAFieldQuality.courseplayOwnsHeaderTransport and FMAFieldQuality.courseplayOwnsHeaderTransport(vehicle,task) then
                return nil,"Courseplay kurz není připraven pro kombajn s adaptérem na podvozku"
            end
            if controller.settings.reliabilityFallback~=false then task.baseAIFallback=true
            else return nil,"Chybí připravený Courseplay kurz pro toto pole a soupravu" end
        end
        if job==nil then
            if AIJobFieldWork==nil then return nil,"Chybí rozhraní AIJobFieldWork" end
            job=FMAAI.createRegisteredJob("FIELDWORK",AIJobFieldWork)
            if not job then return nil,"Nelze vytvořit registrovaný AIJobFieldWork" end
            if not job:getIsAvailableForVehicle(vehicle) then return nil,"Základní AI neumí práci této soupravy" end
            job:applyCurrentState(vehicle,g_currentMission,controller.farmId,false)
            job.positionAngleParameter:setPosition(task.x,task.z)
            -- Preserve the player's chosen helper course settings and direction.
        end
    elseif task.kind=="supply" then
        if AIJobLoadAndDeliver==nil then return nil,"Chybí rozhraní dopravy" end
        if #FMACompatibility.inspect(vehicle).autoloaders>0 then return nil,"Autoloader vyžaduje vlastní nakládání; není sypký náklad" end
        if not task.source or not task.destination then return nil,"Zdroj nebo cíl zásobování chybí" end
        local sourceOwner=task.source.owningPlaceable and FMAUtil.owner(task.source.owningPlaceable)
        local destinationOwner=task.destination.owningPlaceable and FMAUtil.owner(task.destination.owningPlaceable)
        if sourceOwner~=controller.farmId then return nil,"Zásobování vyžaduje vlastní zdroj" end
        local isSale=task.destination.isSellingPoint==true and destinationOwner~=controller.farmId
        if isSale and (task.ownerApproved~=true or task.allowPublicDestination~=true) then
            return nil,"Prodej vyžaduje výslovné schválení konkrétní zakázky"
        end
        if destinationOwner~=controller.farmId and not isSale then return nil,"Cíl není vlastní sklad ani schválený prodej" end
        local free=FMAUtil.call(task.destination,"getFreeCapacity",task.fillType,controller.farmId)
        local available=FMAUtil.call(task.source,"getFillLevel",task.fillType,controller.farmId)
        if not available or available<100 or (record.capacity or 0)<=0 then
            return nil,"Není ověřena zásoba nebo kompatibilní kapacita přepravní soupravy"
        end
        -- Sale points do not have a storage capacity. Never interpret nil as zero.
        if not isSale and (free==nil or free<record.capacity) then
            return nil,"Vlastní silo nemá potvrzené místo na celý vůz"
        end
        if available<record.capacity then
            return nil,"LOAD_AND_DELIVER vyžaduje celý náklad; menší zbytek není potvrzen"
        end
        if isSale and task.saleQuantity and record.capacity>task.saleQuantity then
            return nil,"Vůz překračuje povolený prodejní přebytek; rezervní zásobu nelze prodat"
        end
        if isSale then
            local price=tonumber(FMAUtil.call(task.destination,'getEffectiveFillTypePrice',task.fillType))
            if not price or price<=0 then return nil,"Prodejní stanice nehlásí platnou cenu" end
        end
        job=FMAAI.createRegisteredJob("LOAD_AND_DELIVER",AIJobLoadAndDeliver)
        if not job then return nil,"Nelze vytvořit registrovaný AIJobLoadAndDeliver" end
        if not job:getIsAvailableForVehicle(vehicle) then return nil,"Souprava nepodporuje nativní dopravu" end
        job:applyCurrentState(vehicle,g_currentMission,controller.farmId,false)
        job.loadingStationParameter:setLoadingStation(task.source)
        job.unloadingStationParameter:setUnloadingStation(task.destination)
        job:updateFillTypes(task.source)
        job.fillTypeParameter:setFillTypeIndex(task.fillType)
        job.loopingParameter:setIsLooping(false)
        task.supplyStartLevel=available
        task.supplyStartDestinationLevel=not isSale and FMAUtil.call(task.destination,'getFillLevel',task.fillType,controller.farmId) or nil
        task.supplyStartMoney=isSale and FMAWorld.money(controller.farmId) or nil
    else
        return nil,"Nepodporovaný druh úkolu"
    end
    local typeOk=FMAAI.ensureJobType(job)
    if not typeOk then return nil,"AI job není zaregistrován v AIJobTypeManageru; start zablokován kvůli bezpečnému ukládání" end
    job:setValues()
    local valid,reason=job:validate(controller.farmId)
    if not valid then return nil,tostring(reason or "AI odmítla parametry") end
    local startable,state=job:getIsStartable(nil)
    if not startable then return nil,"AI odmítla start: "..tostring(state) end
    controller.pendingJob=job
    controller.startingTask=task
    controller.startingVehicle=record
    FMAJobs.start(g_currentMission.aiSystem,job,controller.farmId)
    controller.startingTask=nil
    controller.startingVehicle=nil
    controller.pendingJob=nil
    return job
end

function FMAAI.stop(job)
    if job and job.isRunning and g_currentMission and g_currentMission.aiSystem then
        g_currentMission.aiSystem:stopJob(job,AIMessageSuccessStoppedByUser.new())
    end
end

-- Unified transfer job. FS25 already has a native helper route engine for ordinary
-- point-to-point travel; use it first. Courseplay remains a precision/local fallback
-- (not a second road network) and is preferred only for a final direct hitch approach.
local function fmaNativeGoTo(controller,record,target)
    if AIJobGoTo==nil then return nil,"Chybí AIJobGoTo" end
    local job=FMAAI.createRegisteredJob("GOTO",AIJobGoTo)
    if not job then return nil,"Nelze vytvořit registrovaný AIJobGoTo" end
    if not job:getIsAvailableForVehicle(record.object) then return nil,"Stroj nepodporuje nativní autonomní přejezd" end
    job:applyCurrentState(record.object,g_currentMission,controller.farmId,false)
    job.positionAngleParameter:setPosition(target.x,target.z)
    job.positionAngleParameter:setAngle(target.angle or 0)
    job:setValues()
    local valid,why=job:validate(controller.farmId)
    if not valid then return nil,tostring(why or "AI odmítla cíl přejezdu") end
    local startable,state=job:getIsStartable(nil)
    if not startable then
        local category,details=FMAJobs.startRejection(record.object,'GIANTS_GOTO',state)
        return nil,category..': '..details
    end
    -- Transfer/staging jobs are internal steps of a larger FarmManager order. Suppress
    -- the base-game generic "work finished" toast; the dispatcher reports the real order.
    job.fmaAuxiliaryTransfer=true
    job.showNotification=function() end
    return job
end

-- CP transfer start rejections are about an unavailable API/vehicle job, not proof
-- that the physical road is blocked. Cache a short *runtime* circuit breaker per
-- vehicle. Fieldwork Courseplay jobs are unaffected.
FMAAI.cpTransferBackoff=setmetatable({}, {__mode='k'})
local function fmaCourseplayTransfer(controller,record,target)
    local v=record and record.object
    local t=controller and controller.now or 0
    local cached=v and FMAAI.cpTransferBackoff[v]
    if cached and t<cached.untilAt then
        return nil,'Courseplay transfer dočasně odmítnut ('..tostring(cached.reason)..'); používá se jiná AI cesta'
    end
    local cpLoaded=FMACourseplay and FMACourseplay.available and FMACourseplay.available()
    local cpCapable=cpLoaded and type(record.object.startCpWithStrategy)=="function" and type(record.object.getCpSettings)=="function"
    if not cpCapable or not FMATransfer or not FMATransfer.createJob then return nil,"Courseplay transfer není pro stroj dostupný" end
    local job,why=FMATransfer.createJob(controller,record,target)
    if job then
        job.fmaAuxiliaryTransfer=true
        job.showNotification=function() end
        if controller and FMADiagnostics then FMADiagnostics.event(controller,"transfer.cpSelected",record.name or record.key,string.format("%.1f,%.1f",target.x,target.z)) end
        return job
    end
    -- An immediate CP rejection is NOT a road hazard. Do not flood diagnostics
    -- with repeated rejected attempts or poison the learned navigation map.
    if v then FMAAI.cpTransferBackoff[v]={untilAt=t+120000,reason=tostring(why)} end
    if controller and FMADiagnostics then FMADiagnostics.event(controller,'transfer.cpRejected',record.name or record.key,tostring(why)) end
    if controller then controller.lastTransferFallbackReason=tostring(why) end
    return nil,why
end

function FMAAI.createTransferJob(controller,record,target)
    if not controller or not record or not record.object or not target or not target.x or not target.z then return nil,"Chybí stroj nebo cíl přejezdu" end

    -- An explicitly requested independent fallback MUST NOT silently return
    -- to GIANTS_GOTO when CP rejects. This was masked as a different attempt.
    if target.requireCourseplay==true then
        local cpJob,cpWhy=fmaCourseplayTransfer(controller,record,target)
        if cpJob then return cpJob,nil,'COURSEPLAY_REQUIRED_ALTERNATIVE' end
        return nil,'Courseplay opravdu neprevzal prejezd: '..tostring(cpWhy)
    end
    if target.recoveryReverse==true then
        local cpJob,cpWhy=fmaCourseplayTransfer(controller,record,target)
        if cpJob then return cpJob,nil,"COURSEPLAY_SAFE_REVERSE" end
        return nil,"Zpátečka vyžaduje skutečné řízení Courseplay: "..tostring(cpWhy)
    end
    -- Navigation memory is observation evidence, not an invented road network.
    -- Choose known safe arrival only inside the caller's actual tolerance.
    if FMANavigation and not target.directApproach and controller.settings.navigationLearning~=false then
        local known=FMANavigation.verifiedDestination(controller,record,target)
        if known then target=known end
        if FMANavigation.preferAlternative(controller,record,target) then
            target={x=target.x,z=target.z,angle=target.angle,tolerance=target.tolerance,probeRadius=target.probeRadius,preferCourseplay=true}
        end
    end
    -- The last metres to an implement are intentionally local/slow. Here CP's direct
    -- approach is useful; a global GIANTS route into an implement collision is not.
    if target.directApproach==true then
        local cpJob,cpWhy=fmaCourseplayTransfer(controller,record,target)
        if cpJob then return cpJob,nil,"COURSEPLAY_DIRECT_APPROACH" end
        local native,nativeWhy=fmaNativeGoTo(controller,record,target)
        if native then
            if controller and FMADiagnostics then FMADiagnostics.event(controller,"transfer.nativeFallback",record.name or record.key,"directApproach") end
            return native,nil,"GIANTS_GOTO_FALLBACK"
        end
        return nil,tostring(cpWhy or nativeWhy or "Přesný nájezd nelze zahájit")
    end

    -- Once a GIANTS waypoint has failed in live physics, try the independent CP
    -- planner before asking GIANTS to drive to a different point. An accepted AI job
    -- alone never proves a traversable route; the caller still verifies its arrival.
    if target.preferCourseplay==true then
        local cp,why=fmaCourseplayTransfer(controller,record,target)
        if cp then return cp,nil,"COURSEPLAY_ROUTE_ALTERNATIVE" end
        -- fmaCourseplayTransfer records the single rejection; no duplicate event.
    end

    -- A farm-yard graph learned by real driving can guide an otherwise impossible
    -- single long route. Every leg remains a real GIANTS AI job, never a teleport.
    local routeWhy=nil
    if FMAPathRunner and FMAPathRunner.plan then
        local plan,why=FMAPathRunner.plan(controller,record,target)
        routeWhy=why
        if plan then
            local first=plan.legs[1]
            local job,nativeWhy=fmaNativeGoTo(controller,record,first)
            local method='GIANTS_ROAD_LEG'
            if not job then
                -- A denied short leg may have a valid CP path. Do not replace it
                -- with the same distant, engine-accepted-but-stationary GoTo.
                job,nativeWhy=fmaCourseplayTransfer(controller,record,first)
                method='COURSEPLAY_ROAD_LEG'
            end
            if job then
                job.fmaRoutePlan=plan
                job.fmaLegTarget=first
                if FMADiagnostics then FMADiagnostics.event(controller,'route.mapRoadSelected',record.name or record.key,tostring(#plan.legs)..' legs') end
                return job,nil,method
            end
            if controller and FMADiagnostics then FMADiagnostics.event(controller,'route.legUnavailable',record.name or record.key,tostring(nativeWhy)) end
            return nil,'Silniční trasa existuje, ale první úsek odmítly obě AI: '..tostring(nativeWhy)
        end
    end
    -- A cross-map route with no verified road sequence must not silently be
    -- replaced by another kilometre-long GIANTS_GOTO that never moves.
    -- Give CP a single genuine attempt using its own physical pathfinder;
    -- otherwise return a precise blocked state to the dispatcher.
    local px,pz=FMAUtil.position(record.object)
    local remote=px and pz and ((target.x-px)^2+(target.z-pz)^2)>140*140
    if remote and controller.engineRoads and controller.engineRoads.hasCostmap
        and controller.settings and controller.settings.surveyEnabled~=false
        and controller.settings.navigationLearning~=false then
        local cp,cpWhy=fmaCourseplayTransfer(controller,record,target)
        if cp then return cp,nil,'COURSEPLAY_REMOTE_PATHFINDER' end
        return nil,'Vzdálený cíl nemá souvislou ověřenou silniční cestu ('..tostring(routeWhy)
            ..'); Courseplay odmítl samostatnou cestu: '..tostring(cpWhy)
    end

    -- Normal yard/road/field transfer: use the same GIANTS helper navigation the game
    -- already uses. This is also what Courseplay expects before its fieldwork takes over.
    local native,nativeWhy=fmaNativeGoTo(controller,record,target)
    if native then
        if controller and FMADiagnostics then FMADiagnostics.event(controller,"transfer.nativeSelected",record.name or record.key,string.format("%.1f,%.1f",target.x,target.z)) end
        return native,nil,"GIANTS_GOTO"
    end

    -- Fail over to our CP bridge only if the native helper cannot even create/start the route.
    local cpJob,cpWhy=fmaCourseplayTransfer(controller,record,target)
    if cpJob then return cpJob,nil,"COURSEPLAY_FALLBACK" end
    return nil,tostring(nativeWhy or cpWhy or "Stroj neumí autonomní přejezd")
end
