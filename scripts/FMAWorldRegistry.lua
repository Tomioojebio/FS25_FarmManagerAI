-- Lightweight live-world registry. It does not replace FS25 state; it continuously mirrors
-- the authoritative VehicleSystem / PlaceableSystem so the dispatcher can survive resets,
-- moved equipment, manual attachment changes and newly constructed farm objects.
FMAWorldRegistry = {}

function FMAWorldRegistry.new()
    return {vehicles={},placeables={},revision=0,lastScan=-100000,structuralChanges=0,lastChangeText=nil}
end

local function pos(object)
    local x,z=FMAUtil.position(object)
    return x or 0,z or 0
end

local function ownedVehicleObjects(farmId)
    local system=g_currentMission and g_currentMission.vehicleSystem
    return FMAUtil.call(system,'getVehicles') or (system and system.vehicles) or (g_currentMission and g_currentMission.vehicles) or {}
end

local function vehicleSnapshot(farmId)
    local out={}
    for _,object in pairs(ownedVehicleObjects(farmId) or {}) do
        if object and not object.isDeleted and FMAUtil.owner(object)==farmId then
            local key=FMAWorld.vehicleKey(object)
            local root=FMAUtil.call(object,'getRootVehicle') or object
            local rootKey=FMAWorld.vehicleKey(root)
            local x,z=pos(object)
            local state=FMAGameNative.operatorState(object)
            out[key]={key=key,object=object,rootKey=rootKey,x=x,z=z,operator=state.mode,aiActive=state.aiActive,manual=state.manual}
        end
    end
    return out
end

local function placeableSnapshot()
    local out={}
    for _,p in pairs(FMAGameNative.placeables() or {}) do
        if p and not p.isDeleted then
            local key=FMAGameNative.placeableKey(p)
            if key then
                local x,z=pos(p)
                local identity=FMAGameNative.placeableIdentity(p)
                out[key]={key=key,object=p,x=x,z=z,owner=FMAUtil.owner(p),name=(identity.name~='' and identity.name or FMAUtil.name(p)),roles=identity.roles,kind=identity.kind,storeCategory=identity.storeCategory,storeSource=identity.storeSource}
            end
        end
    end
    return out
end

local function sameAssembly(a,b)
    return a and b and tostring(a.rootKey)==tostring(b.rootKey)
end

local function changedPlaceable(a,b)
    if not a or not b then return true end
    if a.object~=b.object then return true end
    local dx=(a.x or 0)-(b.x or 0);local dz=(a.z or 0)-(b.z or 0)
    return dx*dx+dz*dz>1
end


local function reopenAfterManualRelocation(controller,key,old,row)
    if not old or not row then return false end
    local dx=(row.x or 0)-(old.x or 0);local dz=(row.z or 0)-(old.z or 0)
    if dx*dx+dz*dz<100 then return false end
    -- A player physically moving a blocked machine changes the pathfinding start state.
    -- Clear only path/start failures tied to this vehicle; never erase unrelated agronomy faults.
    local reopened=false
    for id,failure in pairs(controller.jobFailures or {}) do
        if failure and failure.vehicleKey==key then
            local reason=tostring(failure.reason or ''):lower()
            if reason:find('cesta',1,true) or reason:find('path',1,true) or reason:find('nepohn',1,true) then
                controller.jobFailures[id]=nil;reopened=true
            end
        end
    end
    for _,task in pairs(controller.tasks or {}) do
        local uses=task and (task.vehicleKey==key or task.preferredVehicleKey==key)
        local reason=tostring(task and task.reason or ''):lower()
        if uses and task.state=='blocked' and (reason:find('cesta',1,true) or reason:find('path',1,true) or reason:find('nepohn',1,true) or reason:find('courseplay',1,true)) then
            task.state='pending';task.phase='OBNOVA PO RUČNÍM PŘESUNU';task.reason='Stroj změnil polohu · stará chyba trasy zahozena';task.retryAt=0
            task.failures=0;task.failedVehicleKeys=nil;task.fieldStageAttempts=0;task.fieldStageCompleteVehicleKey=nil;task.fieldStageTarget=nil
            if task.headerTransportPlan then
                local plan=task.headerTransportPlan
                if plan.carrier and controller.implementReservations and controller.implementReservations[plan.carrier.key]==task.id then controller.implementReservations[plan.carrier.key]=nil end
                if plan.cutterKey and controller.implementReservations and controller.implementReservations[plan.cutterKey]==task.id then controller.implementReservations[plan.cutterKey]=nil end
                task.headerTransportPlan=nil;task.headerTransportReady=nil
            end
            reopened=true
        end
    end
    if controller.stageRouteFailures then controller.stageRouteFailures[key]=nil end
    -- A blocked hauler is still assigned to the same crew. Moving it manually
    -- must clear the route cooldown BEFORE the next dispatcher scan, not 3 min later.
    for _,roles in pairs(controller.preparedSupport or {}) do
        for _,role in pairs(roles) do
            if role.record and role.record.key==key and role.state=='BLOCKED' then
                role.stageFailureCount=0;role.stageCandidateCursor=1
                role.state='NEEDED';role.retryAt=0;role.reason='Přesun stroje · hledání nového příjezdu'
                reopened=true
            end
        end
    end
    if reopened and FMADiagnostics then FMADiagnostics.event(controller,'world.manualRelocation',key,string.format('%.1f m',math.sqrt(dx*dx+dz*dz))) end
    return reopened
end

local function describeChanges(addedVehicles,removedVehicles,reloadedVehicles,assemblyChanges,addedPlaces,removedPlaces)
    local parts={}
    if addedVehicles>0 then parts[#parts+1]='nová technika '..addedVehicles end
    if removedVehicles>0 then parts[#parts+1]='odebraná technika '..removedVehicles end
    if reloadedVehicles>0 then parts[#parts+1]='reset/reload '..reloadedVehicles end
    if assemblyChanges>0 then parts[#parts+1]='změna souprav '..assemblyChanges end
    if addedPlaces>0 then parts[#parts+1]='nové objekty '..addedPlaces end
    if removedPlaces>0 then parts[#parts+1]='odebrané objekty '..removedPlaces end
    return table.concat(parts,' · ')
end

function FMAWorldRegistry.update(controller,force)
    controller.worldRegistry=controller.worldRegistry or FMAWorldRegistry.new()
    local reg=controller.worldRegistry
    local now=controller.now or 0
    if not force and now-(reg.lastScan or -100000)<1500 then return false end
    reg.lastScan=now

    local vehicles=vehicleSnapshot(controller.farmId)
    local places=placeableSnapshot()
    local addedVehicles,removedVehicles,reloadedVehicles,assemblyChanges=0,0,0,0
    local addedPlaces,removedPlaces=0,0

    for key,row in pairs(vehicles) do
        local old=reg.vehicles[key]
        if not old then addedVehicles=addedVehicles+1
        else
            if old.object~=row.object then reloadedVehicles=reloadedVehicles+1 end
            if not sameAssembly(old,row) then assemblyChanges=assemblyChanges+1 end
            reopenAfterManualRelocation(controller,key,old,row)
        end
        -- Keep the full FarmManager record synchronized every lightweight scan. This is
        -- what lets a machine be scattered anywhere on the map without a stale position.
        local record=controller.vehicleByKey and controller.vehicleByKey[key]
        if record then
            record.object=row.object;record.x=row.x;record.z=row.z
            record.operatorMode=row.operator;record.manualControl=row.manual;record.aiControlled=row.aiActive
        end
    end
    for key in pairs(reg.vehicles or {}) do if not vehicles[key] then removedVehicles=removedVehicles+1 end end

    for key,row in pairs(places) do
        local old=reg.placeables[key]
        if not old then addedPlaces=addedPlaces+1
        elseif changedPlaceable(old,row) then addedPlaces=addedPlaces+1;removedPlaces=removedPlaces+1 end
    end
    for key in pairs(reg.placeables or {}) do if not places[key] then removedPlaces=removedPlaces+1 end end

    reg.vehicles=vehicles;reg.placeables=places
    local structural=(addedVehicles+removedVehicles+reloadedVehicles+assemblyChanges+addedPlaces+removedPlaces)>0
    if structural then
        reg.revision=(reg.revision or 0)+1;reg.structuralChanges=(reg.structuralChanges or 0)+1
        reg.lastChangeText=describeChanges(addedVehicles,removedVehicles,reloadedVehicles,assemblyChanges,addedPlaces,removedPlaces)
        controller.worldChanged=true;controller.digitalMapDirty=true;controller.diagnosticDirty=true
        controller.elapsed=(controller.settings.scanSeconds or 12)*1000
        controller.brainElapsed=(controller.settings.brainSeconds or 5)*1000
        if controller.notify and reg.lastChangeText~='' and controller.lastWorldRegistryNotice~=reg.lastChangeText then
            controller.lastWorldRegistryNotice=reg.lastChangeText
            controller:notify('Živý scan světa · '..reg.lastChangeText)
        end
        if FMADiagnostics then FMADiagnostics.event(controller,'world.changed',tostring(reg.revision),reg.lastChangeText) end
    end
    return structural
end

function FMAWorldRegistry.operatorMode(controller,key)
    local row=controller and controller.worldRegistry and controller.worldRegistry.vehicles and controller.worldRegistry.vehicles[key]
    return row and row.operator or 'MISSING'
end


function FMAWorldRegistry.writeDiagnostics(controller,f)
    local reg=controller and controller.worldRegistry
    if not reg then return end
    local vc,pc=0,0;for _ in pairs(reg.vehicles or {}) do vc=vc+1 end;for _ in pairs(reg.placeables or {}) do pc=pc+1 end
    f:write('\nLIVE WORLD REGISTRY revision=',tostring(reg.revision or 0),' vehicles=',tostring(vc),' placeables=',tostring(pc),' changes=',tostring(reg.structuralChanges or 0),' last=',tostring(reg.lastChangeText or 'none'),'\n')
    local vkeys={};for key in pairs(reg.vehicles or {}) do vkeys[#vkeys+1]=key end;table.sort(vkeys)
    for _,key in ipairs(vkeys) do local v=reg.vehicles[key];f:write('VEH ',key,' root=',tostring(v.rootKey),' x=',tostring(v.x),' z=',tostring(v.z),' control=',tostring(v.operator),'\n') end
    local pkeys={};for key in pairs(reg.placeables or {}) do pkeys[#pkeys+1]=key end;table.sort(pkeys)
    for _,key in ipairs(pkeys) do local p=reg.placeables[key];f:write('OBJ ',key,' kind=',tostring(p.kind),' name=',tostring(p.name),' owner=',tostring(p.owner),' x=',tostring(p.x),' z=',tostring(p.z),' category=',tostring(p.storeCategory or '-'),' source=',tostring(p.storeSource or '-'),'\n') end
    f:write('CREW CONTROL\n')
    for id,crew in pairs(controller.crewAssignments or {}) do
        local h=controller.vehicleByKey and controller.vehicleByKey[crew.harvesterKey]
        f:write(id,' task=',tostring(crew.taskId),' field=',tostring(crew.fieldId),' harvester=',tostring(h and h.name or crew.harvesterKey),' control=',tostring(h and FMAFleetCoordinator.operatorMode(h) or 'MISSING'),' unloaders=')
        local rows={};for _,key in ipairs(crew.unloaderKeys or {}) do local r=controller.vehicleByKey and controller.vehicleByKey[key];rows[#rows+1]=tostring(r and r.name or key)..'['..tostring(r and FMAFleetCoordinator.operatorMode(r) or 'MISSING')..']' end
        f:write(table.concat(rows,','),'\n')
    end
end
