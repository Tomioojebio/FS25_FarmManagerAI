FMACompatibility = {}

function FMACompatibility.inspect(vehicle)
    local result={autoloaders={},externalBusy=false,courseplay=false,warnings={}}
    result.courseplay=type(vehicle.getCpStartableJob)=="function"
    for _,object in ipairs(FMAWorld.children(vehicle)) do
        local found=false
        for key,spec in pairs(object) do
            if type(key)=="string" and type(spec)=="table" and key:sub(1,5)=="spec_" and key:lower():find("autoload",1,true) then
                result.autoloaders[#result.autoloaders+1]={object=object,key=key,spec=spec}
                found=true
                if spec.isLoading==true or spec.isUnloading==true or spec.isUnloadingRunning==true then result.externalBusy=true end
            end
        end
        if found then result.warnings[#result.warnings+1]="Autoloader: náklad řídí jeho vlastní mód" end
        if object.ad and (object.ad.isActive==true or FMAUtil.call(object.ad.stateModule,"getIsActive")==true) then result.externalBusy=true end
    end
    return result
end

-- Legacy compatibility helper. Main fieldwork now starts through Courseplay public API.
function FMACompatibility.preparedCourseplayJob(vehicle,task,farmId)
    if FMAUtil.call(vehicle,'hasCpCourse')~=true then return nil end
    local x,z=FMAUtil.call(vehicle,'cpGetFieldPosition')
    if not x or not z or not task.x or (x-task.x)^2+(z-task.z)^2>9 then return nil end
    if FMAUtil.call(vehicle,'cpIsFieldBoundaryDetectionRunning')==true then return nil end
    local spec=vehicle.spec_cpAIFieldWorker
    local job=spec and (task.resumeAtLast and spec.cpJobStartAtLastWp or spec.cpJobStartAtFirstWp)
    if not job or not job.fieldWorkTask then return nil end
    -- false = keep Courseplay's native GIANTS drive-to phase before CP fieldwork.
    job:applyCurrentState(vehicle,g_currentMission,farmId,false,false)
    local p=job.cpJobParameters
    p.fieldPosition:setPosition(task.x,task.z)
    local course=FMAUtil.call(vehicle,'getFieldWorkCourse')
    local ix=task.resumeAtLast and FMAUtil.call(vehicle,'getCpLastRememberedWaypointIx') or 1
    local wx,_,wz=FMAUtil.call(course,'getWaypointPosition',ix or 1)
    p.startPosition:setPosition(wx or task.x,wz or task.z)
    return job
end

function FMACompatibility.environment()
    local rows={}
    for name,loaded in pairs(g_modIsLoaded or {}) do
        if loaded then
            local lower=name:lower()
            if lower:find("autoload",1,true) or lower:find("courseplay",1,true) or lower:find("precisionfarming",1,true) or lower:find("autodrive",1,true) then
                rows[#rows+1]=name
            end
        end
    end
    table.sort(rows)
    return rows
end
