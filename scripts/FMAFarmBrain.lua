-- Proactive cooperative dispatcher. This module does not drive vehicles directly;
-- it plans roles, ETAs and priorities ahead of the physical managers.
FMAFarmBrain = {VERSION='0.20.13.0'}

FMAFarmBrain.strategyLabels={[0]='VYVÁŽENÝ',[1]='MAX VÝKON',[2]='ÚSPORNÝ',[3]='ŠETŘIT TECHNIKU'}
FMAFarmBrain.roleLabels={main='HLAVNÍ STROJ',haulage='ODVOZ',header='ADAPTÉR',bunker='JÁMA',bales='BALÍKY',service='SERVIS',supply='ZÁSOBOVÁNÍ',waiting='ČEKÁNÍ',yard='DVŮR'}
FMAFarmBrain.recipes={
    harvest={roles={'main','header','haulage'},follow={'strawRecovery'},weather=true},
    foragePickup={roles={'main','haulage','bunker'},follow={'compact'},weather=true},
    mow={roles={'main'},follow={'ted','windrow','bale','baleCollect'},weather=true},
    ted={roles={'main'},follow={'windrow'},weather=true},
    windrow={roles={'main'},follow={'bale','foragePickup'},weather=true},
    bale={roles={'main'},follow={'baleCollect'}},
    baleCollect={roles={'main','bales'}},
    sow={roles={'main','supply'},follow={'roll'}},
    fertilize={roles={'main','supply'}}, lime={roles={'main','supply'}}, weed={roles={'main','supply'}},
    plow={roles={'main'}},cultivate={roles={'main'}},stone={roles={'main'}},roll={roles={'main'}},
    supply={roles={'haulage'}},mixFeed={roles={'main','supply'}}
}

local speeds={harvest=7.5,foragePickup=10,mow=14,ted=15,windrow=14,bale=11,baleCollect=16,
    sow=12,fertilize=16,lime=16,weed=16,roll=13,plow=9,cultivate=12,stone=8}

local function polygonAreaHa(field)
    if not field then return 0 end
    if (field.areaHa or 0)>0 then return field.areaHa end
    local object=field.object
    local pts={}
    for _,node in ipairs(object and object.polygonPoints or {}) do
        if getWorldTranslation then
            local ok,x,_,z=pcall(getWorldTranslation,node)
            if ok and x and z then pts[#pts+1]={x=x,z=z} end
        end
    end
    if #pts<3 then return 0 end
    local area=0;local j=#pts
    for i=1,#pts do area=area+(pts[j].x*pts[i].z-pts[i].x*pts[j].z);j=i end
    return math.abs(area)*0.5/10000
end

function FMAFarmBrain.fieldAreaHa(field)
    return polygonAreaHa(field)
end

function FMAFarmBrain.weatherState(controller)
    local env=g_currentMission and g_currentMission.environment
    local hour=env and math.floor((env.dayTime or 0)/3600000)%24 or 12
    local raining=FMAWorld and FMAWorld.raining and FMAWorld.raining() or false
    local daylightRisk=hour>=18 or hour<6
    local status=raining and 'DÉŠŤ' or daylightRisk and 'KRÁTKÉ DENNÍ OKNO' or 'STABILNÍ'
    return {raining=raining,hour=hour,daylightRisk=daylightRisk,status=status}
end

function FMAFarmBrain.strategyLabel(settings)
    return FMAFarmBrain.strategyLabels[tonumber(settings and settings.strategyMode) or 0] or 'VYVÁŽENÝ'
end

function FMAFarmBrain.estimateTaskMinutes(controller,task,vehicle)
    if not task then return 0 end
    local field=task.fieldId and controller.fieldsById and controller.fieldsById[task.fieldId] or nil
    local area=polygonAreaHa(field)
    local width=vehicle and tonumber(vehicle.workWidth) or 0
    if width<=0 then width=6 end
    local speed=speeds[task.operation] or 12
    local efficiency=0.76
    local work=0
    if area>0 and task.kind=='field' then
        local haPerHour=math.max(0.15,width*speed*efficiency/10)
        work=area/haPerHour*60
    else work=10 end
    local distance=vehicle and FMAUtil.distance(vehicle,task) or 0
    local travel=distance/math.max(4.0,(controller.settings and controller.settings.roadSpeedEstimateMps) or 7.0)/60
    return math.max(2,work+travel)
end

function FMAFarmBrain.supportCount(controller,task)
    if not task or (task.operation~='harvest' and task.operation~='foragePickup') then return 0 end
    local maxN=math.max(1,math.min(controller.settings.maxUnloaders or 3,4))
    local field=controller.fieldsById and controller.fieldsById[task.fieldId]
    local area=polygonAreaHa(field)
    local n=1
    if task.operation=='foragePickup' then
        if area>=2.5 and maxN>=2 then n=2 end
        if area>=10 and maxN>=3 then n=3 end
    else
        if area>=7 and maxN>=2 then n=2 end
        if area>=16 and maxN>=3 then n=3 end
    end
    return math.min(maxN,n)
end

local function zone(out,id,kind,name,x,z,radius,source,angle)
    if not x or not z then return end
    out[#out+1]={id=tostring(id),kind=kind,name=name or kind,x=x,z=z,radius=radius or 12,source=source or 'scan',angle=angle}
end

local function placeablePosition(p)
    if not p then return nil,nil end
    local x,z=FMAUtil.position(p)
    if x then return x,z end
    if p.rootNode then return FMAUtil.position({rootNode=p.rootNode}) end
    return nil,nil
end

local function nodePose(node)
    if not node or node==0 or not getWorldTranslation then return nil,nil,nil end
    local ok,x,_,z=pcall(getWorldTranslation,node)
    if not ok or not x or not z then return nil,nil,nil end
    local angle=nil
    if localDirectionToWorld and MathUtil and MathUtil.getYRotationFromDirection then
        local okDir,dx,_,dz=pcall(localDirectionToWorld,node,0,0,1)
        if okDir and dx and dz then angle=MathUtil.getYRotationFromDirection(dx,dz) end
    end
    return x,z,angle
end

local function workshopPose(placeable)
    if not placeable then return nil,nil,nil end
    -- FS25 PlaceableWorkshop creates VehicleSellingPoint and exposes sellTriggerNode.
    -- That node is the real vehicle interaction area; the placeable root can be inside
    -- the workshop building and is not necessarily a valid Courseplay goal.
    local candidates={}
    local ws=placeable.spec_workshop
    if ws and ws.sellingPoint then candidates[#candidates+1]=ws.sellingPoint.sellTriggerNode end
    local selling=placeable.spec_vehicleSellingPoint
    if selling then
        candidates[#candidates+1]=selling.sellTriggerNode
        if selling.sellingPoint then candidates[#candidates+1]=selling.sellingPoint.sellTriggerNode end
    end
    local vw=placeable.spec_vehicleWorkshop
    if vw then
        candidates[#candidates+1]=vw.sellTriggerNode or vw.triggerNode
        if vw.sellingPoint then candidates[#candidates+1]=vw.sellingPoint.sellTriggerNode end
    end
    for _,node in ipairs(candidates) do
        local x,z,a=nodePose(node)
        if x and z then return x,z,a end
    end
    return placeablePosition(placeable)
end

local function appendInfrastructure(controller,zones)
    local mission=g_currentMission
    local ps=mission and mission.placeableSystem
    for i,p in ipairs(ps and ps.placeables or {}) do
        local x,z=placeablePosition(p)
        if x and z then
            if p.spec_workshop or p.spec_vehicleSellingPoint or p.spec_vehicleWorkshop then
                local sx,sz,sa=workshopPose(p)
                zone(zones,'workshop:'..i,'SERVIS',FMAUtil.name(p) or 'Servis / dílna',sx or x,sz or z,16,'runtime',sa)
            end
            if p.spec_silo and FMAUtil.owner(p)==controller.farmId then zone(zones,'ownedSilo:'..i,'SKLAD',FMAUtil.name(p) or 'Vlastní sklad',x,z,15,'runtime') end
            if p.spec_bunkerSilo and FMAUtil.owner(p)==controller.farmId then zone(zones,'ownedBunker:'..i,'JÁMA',FMAUtil.name(p) or 'Silážní jáma',x,z,18,'runtime') end
        end
    end
    -- Once a live atlas exists, it is the single source for load/unload nodes.
    -- Do not insert an old placeable-root duplicate: findZone() would otherwise
    -- accidentally select that wall/roof location before the true GIANTS AI goal.
    if not controller.worldAtlas then
        local storage=mission and mission.storageSystem
        for i,station in pairs(FMAUtil.call(storage,'getLoadingStations') or {}) do
            local own=station.owningPlaceable
            local x,z=placeablePosition(own or station)
            if x and z then zone(zones,'loading:'..tostring(i),'PLNIČKA',FMAUtil.name(own or station) or 'Nakládka / plnění',x,z,12,'unverifiedRoot') end
        end
        for i,station in pairs(FMAUtil.call(storage,'getUnloadingStations') or {}) do
            local own=station.owningPlaceable
            local x,z=placeablePosition(own or station)
            if x and z then zone(zones,'unloading:'..tostring(i),'VYKLÁDKA',FMAUtil.name(own or station) or 'Vykládka',x,z,12,'unverifiedRoot') end
        end
    end
    for id,r in pairs(controller.learnedRoutes or {}) do
        local pts=r.points or {}
        if #pts>0 then
            local a,b=pts[1],pts[#pts]
            zone(zones,'routeStart:'..id,'TRASA',tostring(r.label or id)..' · začátek',a.x,a.z,8,'teach')
            if b~=a then zone(zones,'routeEnd:'..id,'TRASA',tostring(r.label or id)..' · konec',b.x,b.z,8,'teach') end
        end
    end
end

function FMAFarmBrain.findZone(controller,kind,near)
    local best,bestD=nil,math.huge
    for _,z in ipairs(controller.digitalMap and controller.digitalMap.zones or {}) do
        if z.kind==kind then
            local d=0
            if near and near.x and near.z then local dx=z.x-near.x;local dz=z.z-near.z;d=dx*dx+dz*dz end
            if d<bestD then best,bestD=z,d end
        end
    end
    return best
end

local function classifyInfrastructure(placeable)
    if not placeable or not FMAGameNative or not FMAGameNative.placeableIdentity then return nil end
    local identity=FMAGameNative.placeableIdentity(placeable)
    if identity.kind=='WORKSHOP' then return 'SERVIS' end
    if identity.kind=='WEIGH_STATION' then return 'VÁHA' end
    if identity.kind=='WASH_STATION' then return 'MYČKA' end
    return nil
end

function FMAFarmBrain.buildDigitalMap(controller)
    local zones={}
    for key,pos in pairs(controller.homePositions or {}) do zone(zones,'vehicle:'..key,'PARKING','Stání stroje',pos.x,pos.z,8,'learnedHome') end
    for key,pos in pairs(controller.toolHomes or {}) do zone(zones,'tool:'..key,'NÁŘADÍ','Stání nářadí',pos.x,pos.z,7,'learnedHome') end
    for _,field in ipairs(controller.fields or {}) do zone(zones,'field:'..field.id,'POLE',field.name or ('Pole '..field.id),field.x,field.z,25,'field') end
    local profile=controller.mapProfile or {}
    local mp=profile.active and profile or (controller.worldAtlas or {})
    for i,b in ipairs(mp.bunkers or {}) do local x,z=FMAUtil.position(b.object or b);zone(zones,'bunker:'..i,'JÁMA',b.name or ('Silážní jáma '..i),x or b.x,z or b.z,18,'map') end
    for i,s in ipairs(mp.storages or {}) do local x,z=FMAUtil.position(s.object or s);zone(zones,'storage:'..i,'SKLAD',s.name or 'Sklad',x or s.x,z or s.z,15,'map') end
    for i,p in ipairs(mp.productions or {}) do local x,z=FMAUtil.position(p.object or p);zone(zones,'production:'..i,'VÝROBA',p.name or 'Výroba',x or p.x,z or p.z,15,'map') end
    for i,h in ipairs(mp.husbandries or {}) do local x,z=FMAUtil.position(h.object or h);zone(zones,'husbandry:'..i,'CHOV',h.name or 'Chov',x or h.x,z or h.z,15,'map') end
    for i,p in pairs((g_currentMission and g_currentMission.placeableSystem and g_currentMission.placeableSystem.placeables) or {}) do
        local role=classifyInfrastructure(p)
        if role then local x,z=FMAUtil.position(p);if x and z then zone(zones,'infra:'..role..':'..i,role,FMAUtil.name(p) or role,x,z,14,'map') end end
    end
    for id,p in pairs(controller.learnedPoints or {}) do zone(zones,'learned:'..id,p.role or 'PŘÍJEZD',p.label or ('Naučený bod '..id),p.x,p.z,p.radius or 14,'teach') end
    appendInfrastructure(controller,zones)
    -- Engine loading/unloading stations exist on EVERY supported map.  Their
    -- coordinates are observed reference points, never automatically validated
    -- drive destinations. The actual job must still test a physical approach.
    for _,station in ipairs((controller.worldAtlas and controller.worldAtlas.allLoading) or {}) do
        zone(zones,station.id,'PLNIČKA',station.name,station.x,station.z,12,'runtime:'..station.pointSource)
    end
    for _,station in ipairs((controller.worldAtlas and controller.worldAtlas.allUnloading) or {}) do
        zone(zones,station.id,'VYKLÁDKA',station.name,station.x,station.z,12,'runtime:'..station.pointSource)
    end
    -- Grid index bounds choke-point detection for large mod maps. Previously
    -- O(number-of-zones^2) each scan: 1,000 stations => 1M distance tests.
    -- Only the 3x3 neighboring cells can be within the 18m choke radius.
    local choke={};local chokeSeen={};local grid={};local cell=18
    local function cellKey(gx,gz) return tostring(gx)..':'..tostring(gz) end
    for i,z in ipairs(zones) do
        local gx,gz=math.floor(z.x/cell),math.floor(z.z/cell)
        local k=cellKey(gx,gz);grid[k]=grid[k] or {};grid[k][#grid[k]+1]=i
    end
    for i,z in ipairs(zones) do
        local count=0;local gx,gz=math.floor(z.x/cell),math.floor(z.z/cell)
        for dx=-1,1 do for dz=-1,1 do
            for _,j in ipairs(grid[cellKey(gx+dx,gz+dz)] or {}) do
                if i~=j then
                    local rx=z.x-zones[j].x;local rz=z.z-zones[j].z
                    if rx*rx+rz*rz<cell*cell then count=count+1 end
                end
            end
        end end
        local explicit=z.kind=='BRÁNA' or z.kind=='DVŮR'
        if explicit or count>=3 then
            local key=string.format('%.0f:%.0f',z.x/8,z.z/8)
            if not chokeSeen[key] then chokeSeen[key]=true;choke[#choke+1]=z end
        end
    end
    controller.digitalMap={zones=zones,chokePoints=choke,updatedAt=controller.now or 0}
    return controller.digitalMap
end

local function readinessOf(controller,task)
    local row={taskId=task.id,label=task.label,state='WAIT',roles={},eta=0}
    local v,why,kind=FMAPlanner.chooseVehicle(task,controller.vehicles or {},controller.reservations or {},controller.excluded or {})
    if v then row.state='READY';row.main=v.name;row.eta=FMAFarmBrain.estimateTaskMinutes(controller,task,v)
    elseif kind=='busy' then row.state='WAIT';row.reason=why
    elseif FMAAssembler and FMAAssembler.hasPotentialForTask and FMAAssembler.hasPotentialForTask(controller,task) then row.state='ASSEMBLE';row.reason='Vlastní souprava se dá sestavit'
    else row.state='MISSING';row.reason=why end
    if task.operation=='harvest' or task.operation=='foragePickup' then
        row.requiredSupport=FMAFarmBrain.supportCount(controller,task)
        local prepared=controller.preparedSupport and controller.preparedSupport[task.id] or {}
        local n=0;for _,r in pairs(prepared) do if r.state=='WAITING_FIELD' or r.state=='READY' or r.state=='STAGING' or r.state=='ACTIVE' or r.state=='ASSEMBLING' then n=n+1 end end
        row.preparedSupport=n
    end
    return row
end

function FMAFarmBrain.buildShiftPlan(controller)
    local plan={generatedAt=controller.now or 0,rows={},strategy=FMAFarmBrain.strategyLabel(controller.settings),weather=FMAFarmBrain.weatherState(controller)}
    for _,task in ipairs(FMAPlanner.queue(controller.tasks or {})) do
        if task.state~='done' then
            local row=readinessOf(controller,task)
            task.etaMinutes=row.eta;task.strategyMode=controller.settings.strategyMode or 0
            task.longJob=(row.eta or 0)>=30
            local recipe=FMAFarmBrain.recipes[task.operation]
            task.recipeRoles=recipe and recipe.roles or {'main'}
            plan.rows[#plan.rows+1]=row
        end
    end
    controller.shiftPlan=plan
    return plan
end

function FMAFarmBrain.applyPriorities(controller)
    local weather=FMAFarmBrain.weatherState(controller)
    for _,task in pairs(controller.tasks or {}) do
        task.basePriority=task.basePriority or task.priority or 50
        local p=task.basePriority
        local recipe=FMAFarmBrain.recipes[task.operation]
        if task.ownerRequested then p=p+100 end
        if controller.settings.weatherPriority~=false then
            if recipe and recipe.weather and not weather.raining and weather.daylightRisk then p=p+25 end
            if task.operation=='harvest' and not weather.raining then p=p+10 end
        end
        task.priority=p
        task.strategyMode=controller.settings.strategyMode or 0
    end
end

function FMAFarmBrain.planProactiveCrews(controller)
    if not controller.settings.enabled or not controller.settings.proactivePlanning then return false end
    local started=false
    for _,task in ipairs(FMAPlanner.queue(controller.tasks or {})) do
        if (task.state=='pending' or task.state=='assembling' or task.state=='waiting') and (task.operation=='harvest' or task.operation=='foragePickup') and FMAFleetCoordinator then
            local need=FMAFarmBrain.supportCount(controller,task)
            for slot=1,need do
                local ok=FMAFleetCoordinator.preparePendingHarvestCrew(controller,task,slot)
                if ok then return true end
            end
        end
    end
    return started
end

function FMAFarmBrain.dryRun(controller)
    local report={errors={},warnings={},tasks=0,roles=0}
    FMAFarmBrain.buildShiftPlan(controller)
    for _,row in ipairs((controller.shiftPlan and controller.shiftPlan.rows) or {}) do
        report.tasks=report.tasks+1
        if row.state=='MISSING' then report.warnings[#report.warnings+1]=row.label..' · '..tostring(row.reason or 'chybí technika') end
        if row.requiredSupport then
            report.roles=report.roles+row.requiredSupport+1
            if row.preparedSupport<row.requiredSupport then report.warnings[#report.warnings+1]=row.label..' · odvoz '..row.preparedSupport..'/'..row.requiredSupport..' bude připraven před startem' end
        else report.roles=report.roles+1 end
    end
    if controller.settings.autoService~=false and #(controller.serviceQueue or {})>0 and not FMAFarmBrain.findZone(controller,'SERVIS') then report.warnings[#report.warnings+1]='Servisní plán čeká: mapa nemá rozpoznaný workshop ani naučený bod SERVIS' end
    report.ok=#report.errors==0
    controller.brainDryRun=report
    return report
end


local function hasWindrowForTask(task)
    if not task or not task.fruitIndex or not g_fruitTypeManager then return false end
    local fruit=FMAUtil.call(g_fruitTypeManager,'getFruitTypeByIndex',task.fruitIndex)
    if not fruit then return false end
    local ix=fruit.windrowFillTypeIndex or fruit.windrowFillType
    if FillType and ix==FillType.UNKNOWN then return false end
    return ix~=nil and ix~=0
end

function FMAFarmBrain.nextOperationHint(controller,parent)
    if not parent or not parent.operation then return nil end
    if parent.operation=='mow' then
        local mode=FMAForageCoordinator and FMAForageCoordinator.mode(controller) or 3
        if mode==1 and FMAProcurement and FMAProcurement.hasCapability(controller,'ted') then return 'ted' end
        return 'windrow'
    elseif parent.operation=='ted' then return 'windrow'
    elseif parent.operation=='windrow' then
        local mode=FMAForageCoordinator and FMAForageCoordinator.mode(controller) or 3
        return mode==3 and 'foragePickup' or 'bale'
    elseif parent.operation=='harvest' and controller.settings.strawRecovery and hasWindrowForTask(parent) then
        if FMAProcurement and FMAProcurement.hasCapability(controller,'bale') then return 'bale' end
        return 'foragePickup'
    elseif parent.operation=='bale' then return 'baleCollect' end
    return nil
end

function FMAFarmBrain.startFutureStage(controller,parent,operation,record)
    if not record or not record.object then return false,'Chybí stroj pro přesun' end
    local holder={fieldId=parent.fieldId,id='future:'..parent.id..':'..operation}
    local candidates=FMAFleetCoordinator and FMAFleetCoordinator.fieldWaitingCandidates(controller,holder,record) or {}
    if #candidates==0 then return false,'Chybí bezpečný čekací bod pro další četu' end
    for _,target in ipairs(candidates) do
        local t={id='futureStage:'..parent.id..':'..operation,kind='futureStage',operation=operation,parentTaskId=parent.id,fieldId=parent.fieldId,label='Předstih · '..operation,state='running',x=target.x,z=target.z,priority=(parent.priority or 50)-2}
        local free,wait=true,nil
        if FMATraffic and FMATraffic.canStart then free,wait=FMATraffic.canStart(controller,record,target,t,45000) end
        if free then
            local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=target.x,z=target.z,angle=target.angle or 0,tolerance=6})
            if job then
                controller.preparedNextCrew=controller.preparedNextCrew or {}
                controller.preparedNextCrew[parent.id]={parentTaskId=parent.id,fieldId=parent.fieldId,operation=operation,record=record,state='STAGING',target=target,reason='Přesun k poli předem'}
                controller.reservations[record.key]=t.id;record.busy=true
                controller.active[job]={job=job,task=t,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,trafficTarget=target,transferMethod=moveMethod}
                local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
                if ok then controller:notify(record.name..' se předem připravuje na '..tostring(operation)..' u pole '..tostring(parent.fieldId));return true end
                controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;controller.preparedNextCrew[parent.id]=nil
                if FMATraffic then FMATraffic.release(controller.traffic,record.key) end
                return false,tostring(err)
            end
            if FMATraffic then FMATraffic.release(controller.traffic,record.key) end
            if moveWhy then wait=moveWhy end
        end
    end
    return false,'Čekací bod další čety není AI dosažitelný'
end

function FMAFarmBrain.onFutureAssemblyConfirmed(controller,future,plan)
    local parent=controller.tasks and controller.tasks[future.sourceParentId]
    if not parent then
        plan.power.busy=false;controller.reservations[plan.power.key]=nil
        if controller.futureTasks then controller.futureTasks[future.id]=nil end
        return
    end
    local role=controller.preparedNextCrew and controller.preparedNextCrew[parent.id]
    if role then role.state='READY';role.record=plan.power;role.tool=plan.tool;role.reason='Další souprava předem zapřažena' end
    if controller.futureTasks then controller.futureTasks[future.id]=nil end
    local ok,why=FMAFarmBrain.startFutureStage(controller,parent,future.operation,plan.power)
    if not ok and role then role.state='BLOCKED';role.reason=why end
end

function FMAFarmBrain.onFutureAssemblyFailed(controller,future,plan,reason)
    local parent=controller.tasks and controller.tasks[future.sourceParentId]
    local role=parent and controller.preparedNextCrew and controller.preparedNextCrew[parent.id]
    if role then role.state='BLOCKED';role.reason=tostring(reason);role.retryAt=(controller.now or 0)+15000 end
    if plan and plan.power then controller.reservations[plan.power.key]=nil;plan.power.busy=false end
    if plan and plan.tool then controller.implementReservations[plan.tool.key]=nil end
    if controller.futureTasks then controller.futureTasks[future.id]=nil end
    FMADiagnostics.event(controller,'brain.futureAssembly.failed',future.id,tostring(reason))
end

function FMAFarmBrain.startFutureAssembly(controller,parent,synthetic,plan)
    controller.futureTasks=controller.futureTasks or {};controller.futureTasks[synthetic.id]=synthetic
    synthetic.futurePrep=true;synthetic.sourceParentId=parent.id;synthetic.state='future';synthetic.assemblyAttempt=synthetic.assemblyAttempt or 1
    controller.preparedNextCrew[parent.id]={parentTaskId=parent.id,fieldId=parent.fieldId,operation=synthetic.operation,record=plan.power,tool=plan.tool,state='ASSEMBLING',reason='Další souprava se zapřahá předem'}
    local dist=FMAUtil.distance(plan.power,plan.tool)
    if dist<=(controller.settings.autoAttachMaxDistance or 6) then
        local ok=FMAAssembler.attach(controller,plan)
        if ok then
            FMAAssembler.confirm(controller,synthetic,plan,function()FMAFarmBrain.onFutureAssemblyConfirmed(controller,synthetic,plan) end,true,'futureAttach:'..synthetic.id,function(reason)FMAFarmBrain.onFutureAssemblyFailed(controller,synthetic,plan,reason) end)
            return true
        end
    end
    local ok,why=FMAAssembler.startDrive(controller,synthetic,plan,synthetic.assemblyAttempt)
    if not ok then FMAFarmBrain.onFutureAssemblyFailed(controller,synthetic,plan,why) end
    return ok,why
end

function FMAFarmBrain.retryFutureAssemblies(controller)
    for id,future in pairs(controller.futureTasks or {}) do
        if future.futurePrep and future.state=='future' and (future.retryAt or 0)<=(controller.now or 0) then
            local parent=controller.tasks and controller.tasks[future.sourceParentId]
            if not parent then controller.futureTasks[id]=nil
            else
                local plan=FMAAssembler and FMAAssembler.findPlan and FMAAssembler.findPlan(controller,future)
                if plan then
                    local role=controller.preparedNextCrew and controller.preparedNextCrew[parent.id]
                    if role then role.state='ASSEMBLING';role.reason='Opravný nájezd předpřipravené soupravy' end
                    return FMAAssembler.startDrive(controller,future,plan,future.assemblyAttempt or 1)
                end
            end
        end
    end
    return false
end

function FMAFarmBrain.prepareNextCrew(controller)
    if not controller.settings.enabled or not controller.settings.proactivePlanning then return false end
    controller.preparedNextCrew=controller.preparedNextCrew or {}
    for _,a in pairs(controller.active or {}) do
        local parent=a.task
        if parent and parent.kind=='field' and not controller.preparedNextCrew[parent.id] then
            local op=FMAFarmBrain.nextOperationHint(controller,parent)
            if op and op~='baleCollect' then
                local synthetic={id='future:'..parent.id..':'..op,kind='field',fieldId=parent.fieldId,operation=op,label='Předstih '..op,x=parent.x,z=parent.z,crop=parent.crop,fruitIndex=parent.fruitIndex,strategyMode=controller.settings.strategyMode or 0,criticalServiceDamage=controller.settings.criticalServiceDamage or 0.85}
                local record=FMAPlanner.chooseVehicle(synthetic,controller.vehicles or {},controller.reservations or {},controller.excluded or {})
                if record then return FMAFarmBrain.startFutureStage(controller,parent,op,record) end
                if controller.settings.autoAssemble and FMAAssembler and FMAAssembler.findPlan then
                    local plan=FMAAssembler.findPlan(controller,synthetic)
                    if plan then return FMAFarmBrain.startFutureAssembly(controller,parent,synthetic,plan) end
                end
            end
        end
    end
    return false
end

function FMAFarmBrain.onFutureStageStopped(controller,active)
    local parentId=active.task.parentTaskId
    local role=controller.preparedNextCrew and controller.preparedNextCrew[parentId]
    if not role then return true end
    if active.stopReason then
        role.state='BLOCKED';role.reason=active.stopReason;controller.reservations[active.vehicle.key]=nil;active.vehicle.busy=false
        return true
    end
    role.state='WAITING_FIELD';role.reason='Další četa čeká připravená u pole';role.record=active.vehicle
    controller.reservations[active.vehicle.key]='futureWait:'..parentId;active.vehicle.busy=true
    controller:notify(active.vehicle.name..' čeká jako další četa u pole '..tostring(role.fieldId))
    return true
end

function FMAFarmBrain.adoptPreparedNext(controller)
    for parentId,role in pairs(controller.preparedNextCrew or {}) do
        local found=nil
        for _,task in pairs(controller.tasks or {}) do
            if task.fieldId==role.fieldId and task.operation==role.operation and task.state=='pending' then found=task;break end
        end
        if found and role.record and role.state=='WAITING_FIELD' then
            controller.reservations[role.record.key]=nil;role.record.busy=false
            found.preferredVehicleKey=role.record.key;found.preferredVehicleName=role.record.name;found.ownerPinnedVehicle=false
            found.phase='PŘEDPŘIPRAVENO';found.reason='Další četa už čekala u pole'
            controller.preparedNextCrew[parentId]=nil
            if controller.traffic then FMATraffic.release(controller.traffic,role.record.key) end
            FMADiagnostics.event(controller,'brain.adopt',found.id,role.record.name)
        end
    end
end

function FMAFarmBrain.cancelPreparedNext(controller)
    for parentId,role in pairs(controller.preparedNextCrew or {}) do
        if role.record then controller.reservations[role.record.key]=nil;role.record.busy=false;if controller.traffic then FMATraffic.release(controller.traffic,role.record.key) end end
        controller.preparedNextCrew[parentId]=nil
    end
    for id,future in pairs(controller.futureTasks or {}) do
        if future.futurePrep then controller.futureTasks[id]=nil end
    end
end

function FMAFarmBrain.serviceAudit(controller)
    controller.serviceQueue={}
    local preventive=controller.settings.preventiveServiceDamage or 0.60
    local critical=controller.settings.criticalServiceDamage or 0.85
    for _,v in ipairs(controller.vehicles or {}) do
        local d=v.damage or 0
        if d>=critical then
            v.serviceState='CRITICAL';controller.serviceQueue[#controller.serviceQueue+1]={vehicle=v,state='CRITICAL',priority=100}
            controller:issue('serviceCritical:'..v.key,v.name..' · SERVIS PŘED DALŠÍ PRACÍ','Poškození '..math.floor(d*100+0.5)..' %. Manager stroj pro nové zakázky nepoužije a hledá náhradu.',96)
        elseif d>=preventive then
            v.serviceState='PREVENTIVE';controller.serviceQueue[#controller.serviceQueue+1]={vehicle=v,state='PREVENTIVE',priority=70}
            controller:issue('servicePreventive:'..v.key,v.name..' · preventivní servis','Poškození '..math.floor(d*100+0.5)..' %. Pro dlouhé směny bude Manager preferovat zdravější techniku.',70)
        else v.serviceState='OK' end
    end
    table.sort(controller.serviceQueue,function(a,b)return a.priority>b.priority end)
    return controller.serviceQueue
end

function FMAFarmBrain.update(controller)
    FMAFarmBrain.buildDigitalMap(controller)
    FMAFarmBrain.serviceAudit(controller)
    FMAFarmBrain.applyPriorities(controller)
    FMAFarmBrain.buildShiftPlan(controller)
    FMAFarmBrain.adoptPreparedNext(controller)
    if controller.settings.enabled then FMAFarmBrain.retryFutureAssemblies(controller);FMAFarmBrain.planProactiveCrews(controller);FMAFarmBrain.prepareNextCrew(controller) end
end

function FMAFarmBrain.writeDiagnostics(controller,f)
    local p=controller.shiftPlan or FMAFarmBrain.buildShiftPlan(controller)
    f:write('\nFARM BRAIN / SHIFT PLAN\n')
    f:write('strategy=',tostring(p.strategy),' weather=',tostring(p.weather and p.weather.status),' hour=',tostring(p.weather and p.weather.hour),' zones=',tostring(controller.digitalMap and #(controller.digitalMap.zones or {}) or 0),' chokePoints=',tostring(controller.digitalMap and #(controller.digitalMap.chokePoints or {}) or 0),' serviceQueue=',tostring(#(controller.serviceQueue or {})),'\n')
    for parentId,role in pairs(controller.preparedNextCrew or {}) do f:write('futureCrew ',tostring(parentId),' op=',tostring(role.operation),' state=',tostring(role.state),' vehicle=',tostring(role.record and role.record.name or 'AUTO'),'\n') end
    for _,row in ipairs(p.rows or {}) do
        f:write(tostring(row.taskId),' state=',tostring(row.state),' etaMin=',tostring(math.floor((row.eta or 0)+0.5)),' main=',tostring(row.main or 'AUTO'),' support=',tostring(row.preparedSupport or 0),'/',tostring(row.requiredSupport or 0),' reason=',tostring(row.reason or ''),'\n')
    end
end
