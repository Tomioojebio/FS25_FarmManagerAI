-- Precision field-work layer. Generates Courseplay courses defensively so the farm manager
-- can choose headlands, overlap and row geometry instead of relying on an arbitrary helper line.
-- On the Carpathian profile precision work fails closed if Courseplay/course generation is unavailable; we never fake coverage.
FMAFieldQuality = {}

local function settingValue(s, fallback)
    if not s then return fallback end
    local v=FMAUtil.call(s,'getValue')
    if v==nil then return fallback end
    return v
end

local function setSetting(s,value)
    if not s then return false end
    if type(value)=='number' and type(s.setFloatValue)=='function' then
        local ok=pcall(s.setFloatValue,s,value,nil,true);if ok then return true end
    end
    if type(s.setValue)=='function' then local ok=pcall(s.setValue,s,value);if ok then return true end end
    if type(value)=='boolean' and type(s.setBoolValue)=='function' then local ok=pcall(s.setBoolValue,s,value);if ok then return true end end
    return false
end


-- Configure vehicle-side Courseplay options that belong to the real workflow, not
-- just to course geometry. Courseplay 8.1.0.3 has a dedicated header-attachment
-- task for a cutter riding on an attached header trailer, but its strategy stops
-- when automaticCutterAttach is disabled. Farm Manager enables it for harvest.
function FMAFieldQuality.prepareCourseplayVehicle(vehicle,task,controller)
    if not vehicle or not task or task.operation~='harvest' then return true end
    local headerOnCarrier=FMAWorld and FMAWorld.courseplayHeaderTransportState and FMAWorld.courseplayHeaderTransportState(vehicle)==true
    if not headerOnCarrier then return true end
    local settings=FMAUtil.call(vehicle,'getCpSettings')
    if not settings or not settings.automaticCutterAttach then
        return false,'Courseplay nemá dostupné nastavení automatického nasazení adaptéru'
    end
    local before=settingValue(settings.automaticCutterAttach,nil)
    if before~=true then
        setSetting(settings.automaticCutterAttach,true)
        local after=settingValue(settings.automaticCutterAttach,nil)
        if after~=true then return false,'Courseplay nelze přepnout na automatické nasazení adaptéru' end
        if controller and FMADiagnostics then FMADiagnostics.event(controller,'cp.autoCutterAttach',task.id or '?','enabled') end
    end
    return true
end

function FMAFieldQuality.courseMatchesTask(vehicle,task,maxDistance)
    if not vehicle or not task or FMAUtil.call(vehicle,'hasCpCourse')~=true then return false end
    local fx,fz=FMAUtil.call(vehicle,'cpGetFieldPosition')
    if not fx or not fz or not task.x or not task.z then return false end
    local dx,dz=fx-task.x,fz-task.z
    return dx*dx+dz*dz <= (maxDistance or 120)^2
end

function FMAFieldQuality.courseplayOwnsHeaderTransport(vehicle,task)
    return task and task.operation=='harvest' and FMACourseplay and FMACourseplay.available and FMACourseplay.available()
        and FMAWorld and FMAWorld.courseplayHeaderTransportState and FMAWorld.courseplayHeaderTransportState(vehicle)==true
end

local function baseFallback(controller,task,vehicle,why)
    if controller and controller.settings and controller.settings.reliabilityFallback~=false
        and not FMAFieldQuality.courseplayOwnsHeaderTransport(vehicle,task) then
        task.baseAIFallback=true
        task.qualityWarning=tostring(why or 'Courseplay není připraven')
        if FMADiagnostics and FMADiagnostics.event then FMADiagnostics.event(controller,'course.fallback',task.id,task.qualityWarning) end
        return true,false,'Záložní základní AI · '..task.qualityWarning
    end
    return false,false,why
end

function FMAFieldQuality.headlandCount(workWidth,turningRadius,settings)
    workWidth=math.max(0.5,tonumber(workWidth) or 3)
    turningRadius=math.max(5,tonumber(turningRadius) or 7)
    local factor=(settings and settings.headlandSafetyFactor) or 1.35
    local minimum=(settings and settings.minHeadlands) or 2
    local maximum=(settings and settings.maxHeadlands) or 6
    return math.floor(FMAUtil.clamp(math.ceil((turningRadius*factor)/workWidth),minimum,maximum))
end

function FMAFieldQuality.configure(vehicle,task,controller)
    local cpOk,cpWhy=FMAFieldQuality.prepareCourseplayVehicle(vehicle,task,controller)
    if not cpOk then return nil,cpWhy end
    if type(vehicle.getCourseGeneratorSettings)~='function' then return nil,'Courseplay generátor nastavení není na stroji dostupný' end
    local ok,spec=pcall(vehicle.getCourseGeneratorSettings,vehicle)
    if not ok or not spec then return nil,'Courseplay nastavení kurzu nelze načíst' end
    if type(vehicle.validateCourseGeneratorSettings)=='function' then pcall(vehicle.validateCourseGeneratorSettings,vehicle) end
    local width=settingValue(spec.workWidth,3)
    local radius=settingValue(spec.turningRadius,7)
    local n=FMAFieldQuality.headlandCount(width,radius,controller.settings)
    -- Vehicle-independent turning clearance: a wide seeder, mower, plow,
    -- sprayer, rake or combine needs room on the SAME field perimeter.
    -- Derived from the LIVE CP work width / turning radius, never model names.
    -- Three headlands are a conservative minimum for wide/large turning rigs,
    -- not proof that the AI knows every tree or adjacent fence.
    if width>=6 or radius>=9 then
        n=math.min(tonumber(controller.settings.maxHeadlands) or 6,math.max(3,n))
    end
    setSetting(spec.numberOfHeadlands,n)
    setSetting(spec.headlandOverlapPercent,controller.settings.coverageOverlapPercent or 8)
    setSetting(spec.evenRowWidth,true)
    setSetting(spec.autoRowAngle,true)
    setSetting(spec.rowsToSkip,0)
    setSetting(spec.bypassIslands,true)
    setSetting(spec.nIslandHeadlands,1)
    setSetting(spec.sharpenCorners,true)
    setSetting(spec.headlandsWithRoundCorners,1)
    setSetting(spec.fieldMargin,0)
    -- Use perimeter-first on all operations with a physically wide machine.
    -- This is a route generation preference; actual work is still validated.
    local headlandFirst=task.operation=='harvest' or task.operation=='mow'
        or task.operation=='windrow' or n>=3
    setSetting(spec.startOnHeadland,headlandFirst)
    return spec,nil,{workWidth=width,turningRadius=radius,headlands=n,headlandFirst=headlandFirst}
end

function FMAFieldQuality.copyRememberedWindrow(controller,task,record)
    if not controller.settings.windrowCourseReuse then return false end
    if task.operation~='bale' and task.operation~='foragePickup' then return false end
    local course=controller.windrowCourses and controller.windrowCourses[task.fieldId]
    if not course or type(record.object.cpCopyCourse)~='function' then return false end
    local ok=pcall(record.object.cpCopyCourse,record.object,course)
    if ok then
        task.qualityCourseReady=true
        task.reason='Používá přesnou osu řádků po shrnovači'
        return true
    end
    return false
end

function FMAFieldQuality.ensureCourse(controller,task,record)
    if not controller.settings.precisionFieldwork or not controller.settings.preferCourseplay then return true,false end
    if not FMACourseplay.available() then
        return baseFallback(controller,task,record.object,'Pro tuto polní práci chybí aktivní Courseplay')
    end
    local vehicle=record.object
    local cpOk,cpWhy=FMAFieldQuality.prepareCourseplayVehicle(vehicle,task,controller)
    if not cpOk then return false,false,cpWhy end
    if task.qualityCourseReady and task.courseVehicleKey==record.key and FMAUtil.call(vehicle,'hasCpCourse')==true then return true,false end
    -- If the player/Courseplay already generated a course for this exact field, reuse it.
    -- FarmManager is an orchestrator, not a second course generator fighting the user's CP state.
    if FMAFieldQuality.courseMatchesTask(vehicle,task,140) then
        task.qualityCourseReady=true;task.courseVehicleKey=record.key;task.baseAIFallback=nil
        task.reason='Použit existující Courseplay kurz pro toto pole'
        if FMADiagnostics then FMADiagnostics.event(controller,'course.reuse',task.id,record.name or record.key) end
        return true,false,task.reason
    end
    if controller.qualityCoursePending[task.id] then return false,true,'Courseplay zjišťuje hranici pole' end
    if FMAUtil.call(vehicle,'cpIsFieldBoundaryDetectionRunning')==true then return false,true,'Courseplay už zjišťuje jiné pole' end
    local cpSpec=vehicle.spec_cpAIFieldWorker
    local generator=cpSpec and cpSpec.cpJob and cpSpec.cpJob.courseGeneratorInterface
    if not generator or type(vehicle.cpDetectFieldBoundary)~='function' or type(generator.startGeneration)~='function' then
        return baseFallback(controller,task,vehicle,'Souprava nemá dostupné rozhraní generátoru Courseplay')
    end
    local cpHeaderOwned=FMAFieldQuality.courseplayOwnsHeaderTransport(vehicle,task)
    if FMAUtil.call(vehicle,'getCanStartCpFieldWork')~=true and not cpHeaderOwned then return baseFallback(controller,task,vehicle,'Courseplay neumí polní práci této soupravy') end
    local spec,why,info=FMAFieldQuality.configure(vehicle,task,controller)
    if not spec then return false,false,why end
    local followRows=task.operation=='bale' or task.operation=='foragePickup'
    local rowCourse=followRows and controller.windrowCourses[task.fieldId]
    if followRows and not rowCourse then
        return false,false,'Chybí ověřený kurz řádků ze shrnování/sklizně; sběrač nesmí odhadnout jinou stopu'
    end
    local session={controller=controller,task=task,record=record,start=controller.now,active=true}
    controller.qualityCoursePending[task.id]=session
    controller.reservations[record.key]=task.id;record.busy=true;task.state='preparing'
    local function finish(course,reason)
        if controller.qualityCoursePending[task.id]~=session then return end
        controller.qualityCoursePending[task.id]=nil;session.active=false
        if controller.reservations[record.key]==task.id then controller.reservations[record.key]=nil end
        record.busy=false
        task.qualityCourseReady=course~=nil;task.courseVehicleKey=course and record.key or nil
        task.state=course and 'pending' or 'blocked';task.reason=reason;task.retryAt=0
        if course then controller:notify(task.label..' · kurz připraven pro '..record.name)
        else FMAJobs.fail(controller,task,record,reason or 'Courseplay nevytvořil kurz') end
    end
    local function detected(_,_,polygon,islands)
        if not session.active or controller.qualityCoursePending[task.id]~=session then return end
        local policy=controller.policies[task.fieldId]
        if not FMALifecycle.allowed(controller,record,false) or controller.excluded[record.key] or (policy and policy.enabled==false) or (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle))==true or FMAUtil.call(vehicle,'getIsAIActive')==true then
            finish(nil,'Příprava kurzu přerušena změnou řízení');return
        end
        if not polygon then finish(nil,'Courseplay nenašel hranici pole');return end
        local ok,err=xpcall(function()
            if rowCourse then
                vehicle:cpCopyCourse(rowCourse);finish(FMAUtil.call(vehicle,'getFieldWorkCourse'))
            else
                generator:startGeneration({x=task.x,z=task.z},vehicle,spec,nil,function(course) finish(course,course and nil or 'Generátor nevytvořil sjízdný kurz') end,polygon,islands)
            end
        end,FMADiagnostics.trace)
        if not ok then finish(nil,err) end
    end
    local ok,err=pcall(vehicle.cpDetectFieldBoundary,vehicle,task.x,task.z,session,detected)
    if not ok then finish(nil,tostring(err));return false,false,tostring(err) end
    return false,true,'Courseplay připravuje hranici a trasu'
end

function FMAFieldQuality.update(c)
    for id,s in pairs(c.qualityCoursePending or {}) do
        if c.now-s.start>120000 or not c.settings.enabled or (FMAGameNative and FMAGameNative.isManuallyControlled(s.record.object))==true then
            s.active=false;c.qualityCoursePending[id]=nil
            if c.reservations[s.record.key]==id then c.reservations[s.record.key]=nil end
            s.record.busy=false;s.task.state='blocked';s.task.reason='Příprava kurzu přerušena nebo překročila 120 s'
            FMAJobs.fail(c,s.task,s.record,s.task.reason)
        end
    end
end

function FMAFieldQuality.cancelAll(c)
    for id,s in pairs(c.qualityCoursePending or {}) do
        s.active=false;s.record.busy=false
        if c.reservations[s.record.key]==id then c.reservations[s.record.key]=nil end
        s.task.state='paused';s.task.reason='Příprava kurzu pozastavena'
    end
    c.qualityCoursePending={}
end

function FMAFieldQuality.rememberWindrow(controller,task,vehicle)
    if not task or not controller.settings.windrowCourseReuse then return end
    -- A windrow can be created explicitly by a windrower or implicitly by a combine
    -- that lays straw.  Remember both field-work centerline sets.  The forage chain only
    -- consumes this memory when it actually schedules a bale/pickup pass, so keeping a
    -- harvest course for crops without a recoverable windrow is harmless.
    if task.operation~='windrow' and task.operation~='harvest' then return end
    if not vehicle or type(vehicle.getFieldWorkCourse)~='function' then return end
    local course=FMAUtil.call(vehicle,'getFieldWorkCourse')
    if not course then return end
    local copy=course
    if type(course.copy)=='function' then local ok,c=pcall(course.copy,course);if ok and c then copy=c end end
    controller.windrowCourses[task.fieldId]=copy
    if task.operation=='windrow' then
        controller:notify('Pole '..tostring(task.fieldId)..' · uložen přesný střed řádků pro lis/sběrač')
    else
        controller:notify('Pole '..tostring(task.fieldId)..' · uložen kurz sklizně pro přesný sběr slámy')
    end
end

function FMAFieldQuality.markCompleted(controller,task)
    if controller.settings.qualityAudit and task and task.kind=='field' and task.id then controller.qualityRecent=controller.qualityRecent or {};controller.qualityRecent[task.id]=controller.now or 0 end
end

function FMAFieldQuality.isRecentRework(controller,taskId)
    local t=controller.qualityRecent and controller.qualityRecent[taskId]
    return t~=nil and controller.now-t<300000
end
