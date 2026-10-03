-- Cooperative traffic arbitration for Farm Manager owned jobs.
-- The base game / Courseplay still do the actual path finding and obstacle avoidance.
-- This layer prevents several managed vehicles from being released into the same yard
-- target at once and can yield selected transit jobs when two managed vehicles get too close.
FMATraffic = {}

function FMATraffic.new()
    return {zones={},vehicleState={},yieldCount=0,blockedStarts=0,lastLaunchAt=-1000000,peakTransit=0}
end

function FMATraffic.priority(role)
    local p={player=1000,emergency=950,harvester=900,activeUnloader=850,bunkerDelivery=820,bunkerPusher=780,bunkerCompactor=720,
        refill=700,baleDelivery=690,service=685,assembly=680,returning=640,fieldWorker=600,route=560,waiting=200}
    return p[role] or 500
end

function FMATraffic.taskRole(task)
    if not task then return "waiting" end
    if task.kind=="support" then return "activeUnloader" end
    if task.kind=="bunkerDelivery" then return "bunkerDelivery" end
    if task.kind=="bunker" or task.kind=="bunkerApproach" or task.kind=="bunkerYield" then return "bunkerPusher" end
    if task.kind=="refill" then return "refill" end
    if task.kind=="baleDelivery" then return "baleDelivery" end
    if task.kind=="service" then return "service" end
    if task.kind=="assemble" or task.kind=="unloaderAssemble" then return "assembly" end
    if task.kind=="return" then return "returning" end
    if task.kind=="route" then return "route" end
    if task.kind=="field" and task.operation=="harvest" then return "harvester" end
    if task.kind=="field" then return "fieldWorker" end
    return "waiting"
end

function FMATraffic.isTransitTask(task)
    if not task then return false end
    return task.kind=="assemble" or task.kind=="unloaderAssemble" or task.kind=="route" or task.kind=="return" or
        task.kind=="refill" or task.kind=="headerTransport" or task.kind=="baleDelivery" or task.kind=="forageDelivery" or
        task.kind=="livestockMixDrive" or task.kind=="livestockFeedDeliver" or task.kind=="bunkerApproach" or task.kind=="bunkerDelivery" or
        task.kind=="service" or task.kind=="futureStage" or task.kind=="supportStage"
end

function FMATraffic.zoneId(x,z,cell)
    if x==nil or z==nil then return nil end
    local size=math.max(5,tonumber(cell) or 18)
    local gx=math.floor(x/size)
    local gz=math.floor(z/size)
    return tostring(gx)..":"..tostring(gz)
end

function FMATraffic.reserve(state,zoneId,vehicleKey,role,now,ttl)
    if not state or not zoneId then return true,nil end
    local current=state.zones[zoneId]
    local priority=FMATraffic.priority(role)
    if current and current.expires>(now or 0) and current.vehicleKey~=vehicleKey then return false,current end
    state.zones[zoneId]={vehicleKey=vehicleKey,role=role,priority=priority,expires=(now or 0)+(ttl or 15000)}
    return true,state.zones[zoneId]
end

function FMATraffic.release(state,vehicleKey)
    if not state then return end
    for id,z in pairs(state.zones) do if z.vehicleKey==vehicleKey then state.zones[id]=nil end end
    state.vehicleState[vehicleKey]=nil
end

function FMATraffic.clean(state,now)
    if not state then return end
    for id,z in pairs(state.zones) do if z.expires<=(now or 0) then state.zones[id]=nil end end
end

local function activePosition(active)
    if not active or not active.vehicle or not active.vehicle.object then return nil,nil end
    return FMAUtil.position(active.vehicle.object)
end

function FMATraffic.related(a,b)
    if not a or not b then return false end
    local ta,tb=a.task or {},b.task or {}
    if ta.parentGroup and tb.parentGroup and ta.parentGroup==tb.parentGroup then return true end
    if ta.harvesterKey and b.vehicle and ta.harvesterKey==b.vehicle.key then return true end
    if tb.harvesterKey and a.vehicle and tb.harvesterKey==a.vehicle.key then return true end
    local aBunker=ta.kind and tostring(ta.kind):find("bunker",1,true)~=nil
    local bBunker=tb.kind and tostring(tb.kind):find("bunker",1,true)~=nil
    if aBunker and bBunker and ta.bunkerIndex~=nil and ta.bunkerIndex==tb.bunkerIndex then return true end
    return false
end

-- Gate a newly started travel job. This is intentionally conservative only around the
-- departure area and the target cell; it does not replace the navigation system.
local function reserveChoke(controller,state,record,role,x,z,ttl)
    if not x or not z then return true,nil end
    local radius=math.max(10,(controller.settings and controller.settings.trafficCellSize) or 18)
    local best=nil;local bestD=radius*radius
    for i,p in ipairs(controller.digitalMap and controller.digitalMap.chokePoints or {}) do
        local dx=x-p.x;local dz=z-p.z;local d=dx*dx+dz*dz
        if d<=bestD then best={index=i,point=p};bestD=d end
    end
    if not best then return true,nil end
    local id='choke:'..tostring(best.point.id or best.index)
    local ok,current=FMATraffic.reserve(state,id,record.key,role,controller.now or 0,ttl or 30000)
    if not ok then return false,'Úzké místo / bránu právě používá jiná souprava' end
    return true,nil
end

function FMATraffic.canStart(controller,record,target,task,ttl)
    if not controller or not record or not controller.settings or controller.settings.trafficSafety==false then return true,nil end
    local state=controller.traffic or FMATraffic.new();controller.traffic=state
    FMATraffic.clean(state,controller.now or 0)
    local role=FMATraffic.taskRole(task)
    local transit=0
    for _,other in pairs(controller.active or {}) do if other and FMATraffic.isTransitTask(other.task) then transit=transit+1 end end
    state.peakTransit=math.max(state.peakTransit or 0,transit)
    local maxTransit=controller.settings.trafficMaxTransit
    if maxTransit and transit>=maxTransit then
        state.blockedStarts=(state.blockedStarts or 0)+1
        return false,"Dopravní síť je vytížená · čeká "..tostring(transit).." přejezdů"
    end
    local spacing=(controller.settings.trafficLaunchIntervalSeconds or 0)*1000
    local now=controller.now or 0
    if spacing>0 and now-(state.lastLaunchAt or -1000000)<spacing then
        state.blockedStarts=(state.blockedStarts or 0)+1
        return false,"Postupné vypouštění flotily · čeká na bezpečný rozestup startů"
    end
    local sep=controller.settings.trafficStartSeparation or 14
    local rx,rz=FMAUtil.position(record.object)
    local chokeOk,chokeWhy=reserveChoke(controller,state,record,role,rx,rz,ttl)
    if not chokeOk then state.blockedStarts=(state.blockedStarts or 0)+1;return false,chokeWhy end
    if target and target.x and target.z then
        local targetChokeOk,targetChokeWhy=reserveChoke(controller,state,record,role,target.x,target.z,ttl)
        if not targetChokeOk then FMATraffic.release(state,record.key);state.blockedStarts=(state.blockedStarts or 0)+1;return false,targetChokeWhy end
    end
    for _,other in pairs(controller.active or {}) do
        if other.vehicle and other.vehicle.key~=record.key and not FMATraffic.related({task=task,vehicle=record},other) then
            local ox,oz=activePosition(other)
            if rx and ox then
                local d=math.sqrt((rx-ox)^2+(rz-oz)^2)
                if d<sep and FMATraffic.isTransitTask(other.task) then
                    state.blockedStarts=(state.blockedStarts or 0)+1
                    return false,"Čeká na uvolnění prostoru u výjezdu ("..math.floor(d).." m)"
                end
            end
        end
    end
    if target and target.x and target.z then
        local zone=FMATraffic.zoneId(target.x,target.z,controller.settings.trafficCellSize)
        local ok,current=FMATraffic.reserve(state,"target:"..zone,record.key,role,controller.now or 0,ttl or 30000)
        if not ok then
            state.blockedStarts=(state.blockedStarts or 0)+1
            return false,"Cílový prostor používá jiná souprava"
        end
        state.vehicleState[record.key]={zone="target:"..zone,role=role,taskId=task and task.id,target=target}
    end
    -- Do not consume the global launch spacing merely because validation passed.
    -- Several callers still need to create/validate/start an AI job after this gate.
    -- If that later step fails, treating it as a launch serialises the whole farm even
    -- though no vehicle moved (the old diagnostics showed blockedStarts with peakTransit=0).
    return true,nil
end

function FMATraffic.markStarted(controller,record,task)
    if not controller or not record or not controller.settings or controller.settings.trafficSafety==false then return end
    local state=controller.traffic or FMATraffic.new();controller.traffic=state
    if FMATraffic.isTransitTask(task) then
        state.lastLaunchAt=controller.now or 0
        state.successfulStarts=(state.successfulStarts or 0)+1
    end
end

-- Emergency yielding is intentionally limited to short travel jobs where a retry is safe.
-- Fieldwork, combine-unloader and bunker choreography remain under Courseplay/base-game control.
function FMATraffic.canEmergencyYield(active)
    if not active or not active.task then return false end
    local k=active.task.kind
    return k=="assemble" or k=="unloaderAssemble" or k=="route"
end

function FMATraffic.update(controller)
    if not controller or not controller.settings or controller.settings.trafficSafety==false then return end
    local list={}
    for job,a in pairs(controller.active or {}) do
        if a and a.vehicle and a.vehicle.object then list[#list+1]={job=job,active=a} end
    end
    local limit=controller.settings.trafficEmergencyDistance or 8
    for i=1,#list do
        for j=i+1,#list do
            local aa,bb=list[i].active,list[j].active
            if not FMATraffic.related(aa,bb) and (FMATraffic.canEmergencyYield(aa) or FMATraffic.canEmergencyYield(bb)) then
                local ax,az=activePosition(aa);local bx,bz=activePosition(bb)
                if ax and bx then
                    local d=math.sqrt((ax-bx)^2+(az-bz)^2)
                    if d<limit then
                        local pa=FMATraffic.priority(FMATraffic.taskRole(aa.task))
                        local pb=FMATraffic.priority(FMATraffic.taskRole(bb.task))
                        local loserJob,loser
                        if pa<pb then loserJob,loser=list[i].job,aa
                        elseif pb<pa then loserJob,loser=list[j].job,bb
                        elseif tostring(aa.vehicle.key)>tostring(bb.vehicle.key) then loserJob,loser=list[i].job,aa
                        else loserJob,loser=list[j].job,bb end
                        if FMATraffic.canEmergencyYield(loser) and not loser.trafficYield then
                            loser.trafficYield=true
                            loser.stopReason="TRAFFIC_YIELD"
                            local state=controller.traffic or FMATraffic.new();controller.traffic=state
                            state.yieldCount=(state.yieldCount or 0)+1
                            FMAUtil.log("DOPRAVA: "..tostring(loser.vehicle.name).." uvolňuje prostor jiné soupravě")
                            FMAAI.stop(loserJob)
                            return
                        end
                    end
                end
            end
        end
    end
end

function FMATraffic.onYieldStopped(controller,active)
    local task=active and active.task
    local retry=((controller.settings and controller.settings.trafficRetrySeconds) or 6)*1000
    if active and active.vehicle then
        FMATraffic.release(controller.traffic,active.vehicle.key)
        active.vehicle.busy=false
        controller.reservations[active.vehicle.key]=nil
    end
    if not task then return true end
    if task.kind=="assemble" then
        if active.assemblyPlan and active.assemblyPlan.tool then controller.implementReservations[active.assemblyPlan.tool.key]=nil end
        local parent=controller.tasks[task.parentTaskId]
        if parent then parent.state="pending";parent.phase="ČEKÁ NA PROVOZ";parent.reason="Souprava dává přednost jinému stroji";parent.retryAt=(controller.now or 0)+retry end
        return true
    end
    if task.kind=="unloaderAssemble" then
        if active.transportAssemblyPlan and active.transportAssemblyPlan.tool then controller.implementReservations[active.transportAssemblyPlan.tool.key]=nil end
        local parent=controller.tasks[task.parentTaskId]
        if parent then parent.state="pending";parent.phase="ČEKÁ NA PROVOZ";parent.reason="Odvozní souprava dává přednost provozu";parent.retryAt=(controller.now or 0)+retry end
        return true
    end
    if task.kind=="route" and task.route then
        task.route.phase="idle";task.route.retryAt=(controller.now or 0)+retry;task.route.reason="Čeká na průjezd"
        return true
    end
    return false
end

function FMATraffic.playerTakeover(controller)
    controller.playerTakeovers=controller.playerTakeovers or {}
    local toStop={}
    -- Explicit player control always overrides worker ownership, including if a
    -- stale AI bit remains true.  Safely drop manager ownership on handover.
    for job,a in pairs(controller.active or {}) do
        local state=FMAGameNative and FMAGameNative.operatorState(a.vehicle.object) or {manual=false,mode='IDLE'}
        if state.manual then
            a.playerTakeover=true
            a.stopReason='PLAYER_TAKEOVER'
            controller.playerTakeovers[a.vehicle.key]={task=a.task,taskId=a.task and a.task.id,vehicle=a.vehicle,vehicleKey=a.vehicle.key,mode='PLAYER'}
            toStop[#toStop+1]=job
        end
    end
    for _,job in ipairs(toStop) do FMAAI.stop(job) end

    for key,take in pairs(controller.playerTakeovers) do
        local record=(controller.vehicleByKey and controller.vehicleByKey[key]) or take.vehicle
        if record then take.vehicle=record end
        local object=record and record.object
        local state=FMAGameNative and FMAGameNative.operatorState(object) or {manual=false,aiActive=false,entered=false,mode='MISSING'}
        local task=(take.taskId and controller.tasks and controller.tasks[take.taskId]) or take.task
        if task then take.task=task end
        if state.manual then
            take.mode='PLAYER'
            if task then task.state='running';task.phase='RUČNÍ ČLEN ČETY';task.reason='Řízení převzal majitel · četa zůstává zachována' end
            if record then record.busy=true;record.operatorMode='PLAYER' end
        elseif state.aiActive then
            -- H/Courseplay was re-enabled while the owner remains in the cab. Keep the
            -- crew membership but do not start a competing FarmManager job.
            take.mode=state.mode
            if task then task.state='running';task.phase='AI ŘÍZENÁ MAJITELEM';task.reason='Stroj řídí '..(state.mode=='COURSEPLAY' and 'Courseplay' or 'AI pomocník FS25')..' · četa pokračuje' end
            if record then record.busy=true;record.operatorMode=state.mode end
        elseif not state.entered then
            if task and (task.phase=='RUČNÍ ČLEN ČETY' or task.phase=='AI ŘÍZENÁ MAJITELEM') then
                task.state='pending';task.phase='NÁVRAT DO AUTOMATIKY';task.reason=nil;task.retryAt=(controller.now or 0)+1500
            end
            controller.playerTakeovers[key]=nil
            if record then record.busy=false;record.operatorMode='IDLE' end
            controller:notify((record and record.name or key)..' vrácen Farm Manageru')
        end
    end
end
