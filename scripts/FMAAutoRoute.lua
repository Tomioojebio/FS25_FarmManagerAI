-- Optional Universal Autoload adapter. Drives with the game's navigation.
-- Loading/unloading is performed by UAL, never by editing cargo or physics here.
FMAAutoRoute = {}

function FMAAutoRoute.tool(vehicle)
    local found
    for _,tool in ipairs(FMAWorld.children(vehicle)) do
        local spec=tool.spec_universalAutoload
        if spec and spec.isAutoloadAvailable and not spec.autoloadDisabled and
            type(tool.ualStartLoad)=="function" and type(tool.ualStopLoad)=="function" and
            type(tool.ualGetFillUnitFillLevel)=="function" then
            if found then return nil,"Použij jeden autoload přívěs v soupravě" end
            found=tool
        end
    end
    if not found then return nil,"Trasa vyžaduje aktivní Universal Autoload s rozhraním ual*" end
    return found
end

function FMAAutoRoute.unloadAPI()
    local env=FS25_UniversalAutoload
    local api=env and env.UniversalAutoload
    if api and type(api.startUnloading)=="function" then return api end
    return nil
end

function FMAAutoRoute.record(controller,side)
    local player=FMAUtil.call(g_currentMission.playerSystem,"getLocalPlayer") or g_localPlayer
    local vehicle=FMAUtil.call(player,"getCurrentVehicle") or g_currentMission.controlledVehicle
    if not vehicle then controller:notify("Sedni do soupravy s Universal Autoload");return end
    vehicle=FMAUtil.call(vehicle,"getRootVehicle") or vehicle
    if FMAUtil.owner(vehicle)~=controller.farmId then return end
    local tool,why=FMAAutoRoute.tool(vehicle)
    if not tool then controller:notify(why);return end
    if not FMAAutoRoute.unloadAPI() then controller:notify("Tato verze UAL nemá dostupné rozhraní pro kontrolované vykládání");return end
    local key=FMAWorld.vehicleKey(vehicle)
    if controller.reservations[key] then controller:notify("Nejprve vypni správce a zastav trasu");return end
    local x,z=FMAUtil.position(vehicle)
    local land=FMAUtil.call(g_farmlandManager,"getFarmlandAtWorldPosition",x,z)
    local owner=land and (FMAUtil.owner(land) or FMAUtil.call(g_farmlandManager,"getFarmlandOwner",land.id))
    if owner~=controller.farmId then controller:notify("Nakládací a vykládací bod musí být na tvém pozemku");return end
    local dx,_,dz=localDirectionToWorld(vehicle.rootNode,0,0,1)
    local angle=MathUtil.getYRotationFromDirection(dx,dz)
    local route=controller.routes[key] or {key=key,enabled=false}
    route[side]={x=x,z=z,angle=angle};route.phase="idle";route.enabled=false
    controller.routes[key]=route
    controller:notify((side=="load" and "Nakládací" or "Vykládací").." bod uložen · "..FMAUtil.name(vehicle))
end

function FMAAutoRoute.fail(controller,route,reason)
    local vehicle=route.vehicle
    if vehicle then
        local tool=FMAAutoRoute.tool(vehicle.object)
        if tool then pcall(tool.ualStopLoad,tool) end
        vehicle.busy=false
    end
    route.enabled=false;route.phase="blocked";route.reason=reason
    controller.reservations[route.key]=nil
    controller:issue("route:"..route.key,"Trasa autoloaderu",reason,95)
    controller:notify("Trasa zastavena · "..reason)
end

function FMAAutoRoute.drive(controller,route,record,side)
    local point=route[side]
    if not point or not point.x or not point.z then return false,"Chybí bod "..side end
    local land=FMAUtil.call(g_farmlandManager,"getFarmlandAtWorldPosition",point.x,point.z)
    local owner=land and (FMAUtil.owner(land) or FMAUtil.call(g_farmlandManager,"getFarmlandOwner",land.id))
    if owner~=controller.farmId then return false,"Změnilo se vlastnictví pozemku trasy" end
    local vehicle=record.object
    if FMAUtil.owner(vehicle)~=controller.farmId or (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle))==true or FMAUtil.call(vehicle,"getIsAIActive")==true then return false,"Stroj už někdo ovládá" end
    local trafficTask={id="route:"..route.key,kind="route",route=route,label="Autoload trasa"}
    if FMATraffic and FMATraffic.canStart then
        local free,wait=FMATraffic.canStart(controller,record,point,trafficTask,45000)
        if not free then route.phase="idle";route.reason=wait;route.retryAt=controller.now+((controller.settings.trafficRetrySeconds or 6)*1000);return true,wait end
    end
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=point.x,z=point.z,angle=point.angle or 0,tolerance=7})
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,moveWhy or "Souprava nepodporuje autonomní navigaci" end
    route.phase=side=="load" and "toLoad" or "toUnload"
    route.vehicle=record;route.since=controller.now
    local task={id="route:"..route.key,kind="route",route=route,label="Autoload trasa",state="running"}
    controller.reservations[record.key]=task.id;record.busy=true
    controller.active[job]={job=job,task=task,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,trafficTarget=point,transferMethod=moveMethod}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then
        if job.isRunning then pcall(FMAAI.stop,job) end
        controller.active[job]=nil;controller.reservations[record.key]=nil
        if FMATraffic then FMATraffic.release(controller.traffic,record.key) end
        return false,tostring(err)
    end
    return true
end

function FMAAutoRoute.dispatch(controller)
    for key,route in pairs(controller.routes) do
        if route.enabled and (route.phase==nil or route.phase=="idle") and (route.retryAt or 0)<=controller.now then
            for _,record in ipairs(controller.vehicles) do
                if record.key==key and not record.busy and not record.lowFuel and not controller.excluded[key] and not controller.reservations[key] then
                    local tool,why=FMAAutoRoute.tool(record.object)
                    if not tool or not FMAAutoRoute.unloadAPI() then FMAAutoRoute.fail(controller,route,why or "Neznámé rozhraní UAL");return false end
                    local ok,reason=FMAAutoRoute.drive(controller,route,record,"load")
                    if not ok then FMAAutoRoute.fail(controller,route,reason) end
                    return ok
                end
            end
        end
    end
    return false
end

function FMAAutoRoute.onStopped(controller,active,message)
    local route=active.task.route
    if not controller.settings.enabled or not route.enabled then route.phase="idle";return end
    if active.stopReason then FMAAutoRoute.fail(controller,route,active.stopReason);return end
    local side=route.phase=="toLoad" and "load" or "unload"
    local x,z=FMAUtil.position(active.vehicle.object)
    local p=route[side]
    if not x or not p or (x-p.x)^2+(z-p.z)^2>36 then FMAAutoRoute.fail(controller,route,"AI nedojela k bodu "..side);return end
    route.phase=side=="load" and "loading" or "unloading"
    route.since=controller.now;route.operationStarted=false;route.lastCount=nil;route.lastChange=controller.now
    controller.reservations[route.key]="route:"..route.key
    active.vehicle.busy=true
end

function FMAAutoRoute.update(controller)
    if not controller.settings.enabled then return end
    for _,route in pairs(controller.routes) do
        if route.enabled and (route.phase=="loading" or route.phase=="unloading") then
            local record=route.vehicle
            local vehicle=record and record.object
            local tool=vehicle and FMAAutoRoute.tool(vehicle)
            if not vehicle or not tool or FMAUtil.owner(vehicle)~=controller.farmId or (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle))==true or FMAUtil.call(vehicle,"getIsAIActive")==true then
                FMAAutoRoute.fail(controller,route,"Souprava změněna nebo převzata jiným řidičem")
            elseif (FMAUtil.call(vehicle,"getLastSpeed") or 0)<0.5 then
                local count=tool:ualGetFillUnitFillLevel(1) or 0
                if count~=route.lastCount then route.lastCount=count;route.lastChange=controller.now end
                if not route.operationStarted then
                    if route.phase=="loading" then tool:ualStartLoad()
                    else
                        local api=FMAAutoRoute.unloadAPI()
                        if api then api.startUnloading(tool,false,false)
                        else FMAAutoRoute.fail(controller,route,"Rozhraní UAL pro vykládání není dostupné") end
                    end
                    route.operationStarted=true
                end
                if route.phase=="loading" and (FMAUtil.call(tool,"ualIsFull")==true or controller.now-route.lastChange>=20000) then
                    tool:ualStopLoad()
                    if count>0 then
                        local ok,why=FMAAutoRoute.drive(controller,route,record,"unload")
                        if not ok then FMAAutoRoute.fail(controller,route,why) end
                    else
                        route.phase="idle";route.retryAt=controller.now+120000
                        controller.reservations[route.key]=nil;record.busy=false
                    end
                elseif route.phase=="unloading" and count==0 and controller.now-route.since>2000 then
                    route.phase="idle";route.retryAt=controller.now+15000;route.cycles=(route.cycles or 0)+1
                    controller.reservations[route.key]=nil;record.busy=false
                elseif controller.now-route.since>120000 then
                    FMAAutoRoute.fail(controller,route,"Nakládání / vykládání nepokročilo. Ověř místo, filtr a prostor kolem přívěsu.")
                end
            elseif controller.now-route.since>30000 then
                FMAAutoRoute.fail(controller,route,"Souprava se u obslužného bodu nezastavila")
            end
        end
    end
end

function FMAAutoRoute.stopAll(controller)
    for _,route in pairs(controller.routes) do
        if route.vehicle then
            local tool=FMAAutoRoute.tool(route.vehicle.object)
            if tool then pcall(tool.ualStopLoad,tool) end
        end
        route.phase="idle";route.operationStarted=false
        controller.reservations[route.key]=nil
    end
end
