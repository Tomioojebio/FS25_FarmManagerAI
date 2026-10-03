FMAProcurement = {}

function FMAProcurement.hasCapability(controller,operationOrCap)
    local def=FMACatalog and FMACatalog.operations and FMACatalog.operations[operationOrCap]
    local cap=def and def.cap or operationOrCap
    for _,v in ipairs(controller.vehicles or {}) do if v.capabilities and v.capabilities[cap] then return true end end
    if def and FMAAssembler and FMAAssembler.hasPotential and FMAAssembler.hasPotential(controller,operationOrCap) then return true end
    if cap=="transport" and FMAAssembler and FMAAssembler.hasPotential and FMAAssembler.hasPotential(controller,"supply") then return true end
    return false
end

function FMAProcurement.hasForTask(controller,task)
    if not controller or not task or not task.operation then return false end
    -- A grain combine towing its header trailer with the cutter physically secured on it
    -- is a complete, serviceable harvesting chain. The bare combine intentionally has no
    -- direct harvest capability until the cutter is attached at the field, so the generic
    -- selector alone must never turn this real chain into a false "buy a harvester" alert.
    if task.operation=="harvest" and controller.settings and controller.settings.headerTransport
        and FMAHeaderTransport and FMAHeaderTransport.preloadedChain
        and FMAHeaderTransport.preloadedChain(controller,task) then return true end
    local vehicle,_,kind=FMAPlanner.chooseVehicle(task,controller.vehicles or {},controller.reservations or {},controller.excluded or {})
    if vehicle or kind=="busy" or kind=="configuration" then return true end
    return FMAAssembler and FMAAssembler.hasPotentialForTask and FMAAssembler.hasPotentialForTask(controller,task) or false
end

function FMAProcurement.audit(controller)
    local required={transport='Odvozní souprava'}
    local readyHarvest=false
    for _,f in ipairs(controller.fields or {}) do if f.ready then readyHarvest=true break end end
    if readyHarvest then required.harvest='Sklizňová technika' end
    local hasAnimals=false
    for _,p in pairs(g_currentMission.placeableSystem and g_currentMission.placeableSystem.placeables or {}) do
        if FMAUtil.owner(p)==controller.farmId and p.spec_husbandry then hasAnimals=true;break end
    end
    if hasAnimals then required.transport='Univerzální sypký/kapalný odvoz' end
    -- A cooperative should know the whole forage/bale chain before the first swath is on the ground.
    local managesGrass=false
    for _,f in ipairs(controller.fields or {}) do
        local p=controller.policies and controller.policies[f.id]
        if f.grass or (p and p.crop=='GRASS') then managesGrass=true break end
    end
    if managesGrass then
        required.mow='Sekačka'
        required.ted='Obraceč'
        required.windrow='Shrnovač'
        required.bale='Lis'
        required.baleCollect='Sběr balíků'
    end
    for cap,label in pairs(required) do
        if not FMAProcurement.hasCapability(controller,cap) then
            local operation=cap=='transport' and 'supply' or cap
            controller:equipmentIssue(operation,'Fleet Manager · '..label)
        end
    end
    -- Current queue has priority over long-range forecasting. Expose missing equipment
    -- immediately on the owner/job screens so the player knows what to buy before pressing START.
    local seen={}
    for _,task in pairs(controller.tasks or {}) do
        if task.operation and task.state~="done" and not seen[task.operation] then
            seen[task.operation]=true
            if not FMAProcurement.hasForTask(controller,task) then
                controller:equipmentIssue(task.operation,task.label)
            end
        end
    end

    if controller.settings.harvestTeams and not FMACourseplay.available() then
        controller:issue('courseplay','Courseplay doporučen pro plnou autonomii sklizně','Nainstaluj Courseplay z oficiálního ModHubu. Bez něj zůstane nativní práce polí, ale koordinovaný odvoz, balíky a jámy jsou omezené.',90)
    end
end
