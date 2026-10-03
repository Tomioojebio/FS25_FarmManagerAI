-- Bunker-silo cooperative coordinator: delivery traffic, pusher/compactor arbitration and manual-cover handoff.
FMABunkerCoordinator = {}

local function centerAndEnds(b)
    local a=b and b.bunkerSiloArea
    a=a and (a.inner or a)
    if not a or not a.sx or not a.wx or not a.hx then return nil end
    local widthX=(a.wx-a.sx);local widthZ=(a.wz-a.sz)
    local width=math.sqrt(widthX*widthX+widthZ*widthZ)
    local frontX=a.sx+widthX*0.5;local frontZ=a.sz+widthZ*0.5
    local backX=a.hx+widthX*0.5;local backZ=a.hz+widthZ*0.5
    local dx=backX-frontX;local dz=backZ-frontZ;local len=math.sqrt(dx*dx+dz*dz)
    if len<0.5 then return nil end
    dx,dz=dx/len,dz/len
    local clearance=14
    return {front={x=frontX,z=frontZ},back={x=backX,z=backZ},dx=dx,dz=dz,length=len,width=width,
        frontOutside={x=frontX-dx*clearance,z=frontZ-dz*clearance},backOutside={x=backX+dx*clearance,z=backZ+dz*clearance},
        center={x=(frontX+backX)/2,z=(frontZ+backZ)/2}}
end

-- Hard geofence for CP and FMA-owned bunker movement. Coordinates are
-- projected onto the real bunker polygon, not the placeable root node.
-- A short area outside either mouth is permitted for entering/exiting.
function FMABunkerCoordinator.withinWorkEnvelope(b,x,z)
    local g=b and b.geometry
    if not g or not g.front or not g.dx or not g.dz or not g.length or not g.width
        or type(x)~='number' or type(z)~='number' or g.length<8 or g.width<3 then
        return false,'missing or invalid bunker geometry'
    end
    local ox,oz=x-g.front.x,z-g.front.z
    local along=ox*g.dx+oz*g.dz
    local side=math.abs(-ox*g.dz+oz*g.dx)
    local limit=(g.width*0.5)+5.0
    -- Physical staging/exit point is generated 14 m beyond the mouth.
    local outside=(along < -18 or along > g.length+18 or side>limit)
    return not outside,string.format('along=%.1f/%.1f lateral=%.1f/%.1f',along,g.length,side,limit)
end

-- A CP bunker worker is never allowed to start from a guessed position in
-- the courtyard. Reaching within 12 m of an entrance is NOT a verified start.
function FMABunkerCoordinator.safeWorkerStart(b,vehicle,fromFront)
    local g=b and b.geometry
    if not g or not g.frontOutside or not g.backOutside then return false,'Chybí skutečné vjezdy do jámy' end
    local x,z=FMAUtil.position(vehicle)
    if not x or not z then return false,'Neznámá poloha traktoru' end
    local gate=fromFront and g.frontOutside or g.backOutside
    local dx,dz=x-gate.x,z-gate.z
    local distance=math.sqrt(dx*dx+dz*dz)
    -- A wide 12 m radius can contain parked vehicles, sheds and silo walls.
    if distance>5.0 then return false,string.format('Neověřený příjezd k vjezdu: %.1f m',distance) end
    local inside,why=FMABunkerCoordinator.withinWorkEnvelope(b,x,z)
    if not inside then return false,'Mimo pracovní koridor: '..tostring(why) end
    local side=math.abs(-(x-g.front.x)*g.dz+(z-g.front.z)*g.dx)
    if side>g.width*.5+1 then return false,string.format('Mimo osu vjezdu: %.1f m',side) end
    if type(localDirectionToWorld)~='function' or not vehicle.rootNode then return false,'Nelze ověřit orientaci traktoru' end
    local ok,fx,_,fz=pcall(localDirectionToWorld,vehicle.rootNode,0,0,1)
    if not ok or not fx or not fz then return false,'Nelze ověřit orientaci traktoru' end
    local dot=fx*g.dx+fz*g.dz
    if not fromFront then dot=-dot end
    if dot<0.65 then return false,string.format('Traktor není natočen do vjezdu (%.2f)',dot) end
    return true,'Vjezd a směr fyzicky ověřeny'
end

local function accepted(b,fillType)
    if not b or not fillType then return false end
    if b.acceptedFillTypes and b.acceptedFillTypes[fillType]~=nil then return b.acceptedFillTypes[fillType]==true end
    return b.inputFillType==fillType
end

local function fillStateOk(b)
    if not b then return false end
    if BunkerSilo and BunkerSilo.STATE_FILL~=nil then return b.state==BunkerSilo.STATE_FILL end
    return false
end

local function roundedIndex(value)
    local n=tonumber(value) or 0
    return math.max(0,math.floor(n+0.5))
end

function FMABunkerCoordinator.fillRatio(controller,b)
    if not b then return nil end
    local capacity=b.capacityEstimate
    if (not capacity or capacity<=1) and b.geometry then
        local h=(controller and controller.settings and controller.settings.bunkerNominalHeight) or 4.0
        capacity=(b.geometry.width or 0)*(b.geometry.length or 0)*h*1000
        b.capacityEstimate=capacity
    end
    if capacity and capacity>1 then return FMAUtil.clamp((b.fillLevel or 0)/capacity,0,1.25) end
    return nil
end

function FMABunkerCoordinator.role(controller,index)
    local p=roundedIndex(controller.settings.bunkerPrimaryIndex)
    local n=roundedIndex(controller.settings.bunkerNextIndex)
    if p==index then return 'PŘÍJEM' end
    if n==index then return 'DALŠÍ' end
    return 'VOLNÁ'
end

function FMABunkerCoordinator.cycleSelection(controller,index)
    local p=roundedIndex(controller.settings.bunkerPrimaryIndex)
    local n=roundedIndex(controller.settings.bunkerNextIndex)
    if p==index then
        controller.settings.bunkerPrimaryIndex=n
        controller.settings.bunkerNextIndex=0
        controller:notify(n>0 and ('Silážní jáma '..n..' je nyní hlavní pro příjem') or 'Výběr hlavní silážní jámy vrácen na AUTO')
    elseif n==index then
        controller.settings.bunkerNextIndex=0
        controller:notify('Silážní jáma '..index..' už není další v pořadí')
    elseif p==0 then
        controller.settings.bunkerPrimaryIndex=index
        controller:notify('Silážní jáma '..index..' nastavena jako hlavní pro příjem')
    else
        controller.settings.bunkerNextIndex=index
        controller:notify('Silážní jáma '..index..' nastavena jako další po jámě '..p)
    end
end

local function targetReached(controller,b)
    local ratio=FMABunkerCoordinator.fillRatio(controller,b)
    return ratio~=nil and ratio>=(controller.settings.bunkerFillTarget or 0.90)
end

local function refreshBunker(controller,b)
    if not b or not b.object then return end
    b.fillLevel=b.object.fillLevel or b.fillLevel or 0
    b.compactedPercent=b.object.compactedPercent or b.compactedPercent or 0
    b.state=b.object.state
    b.canClose=FMAUtil.call(b.object,'getCanCloseSilo')==true
    b.fillRatio=FMABunkerCoordinator.fillRatio(controller,b)
end

local function workState(controller,index)
    controller.bunkerWorkState=controller.bunkerWorkState or {}
    local s=controller.bunkerWorkState[index]
    local b=controller.bunkers and controller.bunkers[index]
    if s and b and s.bunkerKey and s.bunkerKey~=b.key then s=nil end
    if not s then s={failures=0,retryAt=0,blocked=false,phase='IDLE'};controller.bunkerWorkState[index]=s end
    if b then s.bunkerKey=b.key end
    return s
end

local function promoteNext(controller,closedIndex)
    local primary=roundedIndex(controller.settings.bunkerPrimaryIndex)
    if primary~=closedIndex then return end
    local nextIndex=roundedIndex(controller.settings.bunkerNextIndex)
    controller.settings.bunkerPrimaryIndex=nextIndex
    controller.settings.bunkerNextIndex=0
    if nextIndex>0 then controller:notify('Silážní jáma '..closedIndex..' dosáhla cíle · další návozy přesměrovány do jámy '..nextIndex)
    else controller:notify('Silážní jáma '..closedIndex..' dosáhla cíle · další jáma bude zvolena automaticky') end
end

local function syncCampaign(controller)
    for i,b in ipairs(controller.bunkers or {}) do
        refreshBunker(controller,b)
        local ws=workState(controller,i)
        if targetReached(controller,b) then
            if not ws.intakeClosed then
                ws.intakeClosed=true;ws.phase='FINISH_COMPACTION';ws.targetReachedAt=controller.now
                promoteNext(controller,i)
            end
        elseif fillStateOk(b) then
            ws.intakeClosed=false
        end
    end
end

function FMABunkerCoordinator.bunkers(farmId)
    local out,seen={},{}
    local system=g_currentMission and g_currentMission.placeableSystem
    for _,place in pairs(FMAUtil.call(system,'getPlaceables') or (system and system.placeables) or {}) do
        if FMAUtil.owner(place)==farmId then
            local objects={}
            if place.spec_bunkerSilo and place.spec_bunkerSilo.bunkerSilo then objects[#objects+1]=place.spec_bunkerSilo.bunkerSilo end
            for _,b in ipairs(place.spec_multiBunkerSilo and place.spec_multiBunkerSilo.bunkerSilos or {}) do objects[#objects+1]=b end
            for _,b in ipairs(objects) do
                if not seen[b] then
                    seen[b]=true;local geo=centerAndEnds(b)
                    if geo then
                        local env=FS25_Courseplay;local manager=env and env.g_bunkerSiloManager
                        local wrapper=FMAUtil.call(manager,'getSiloWrapperByNode',b.interactionTriggerNode)
                        out[#out+1]={object=b,placeable=place,x=geo.center.x,z=geo.center.z,geometry=geo,wrapper=wrapper,
                            key=FMAWorld.vehicleKey(place)..':'..tostring(geo.center.x)..':'..tostring(geo.center.z),
                            fillLevel=b.fillLevel or 0,compactedPercent=b.compactedPercent or 0,state=b.state,
                            canClose=FMAUtil.call(b,'getCanCloseSilo')==true,inputFillType=b.inputFillType,acceptedFillTypes=b.acceptedFillTypes or {}}
                    end
                end
            end
        end
    end
    table.sort(out,function(a,b)return a.key<b.key end)
    return out
end

local function hasIncoming(controller,index)
    local chaff=FillType and FillType.CHAFF
    local selected=roundedIndex(controller.settings.bunkerPrimaryIndex)
    for _,a in pairs(controller.active or {}) do
        local t=a.task
        if t then
            if t.kind=='bunkerDelivery' and t.bunkerIndex==index then return true end
            if index==selected and chaff and t.expectedFillType==chaff and (t.operation=='foragePickup' or t.operation=='harvest') then return true end
        end
    end
    if index==selected and chaff then
        for _,t in pairs(controller.tasks or {}) do
            if t.state~='done' and t.state~='blocked' and t.expectedFillType==chaff and (t.operation=='foragePickup' or t.operation=='harvest') then return true end
        end
    end
    return false
end

function FMABunkerCoordinator.scan(controller)
    controller.bunkers=FMABunkerCoordinator.bunkers(controller.farmId,controller.settings.bunkerNominalHeight)
    syncCampaign(controller)
    for i,b in ipairs(controller.bunkers) do
        local compact=b.compactedPercent or 0
        local ratio=b.fillRatio or FMABunkerCoordinator.fillRatio(controller,b)
        local fillText=ratio and (math.floor(ratio*100+0.5)..'% odhad kapacity') or (math.floor(b.fillLevel or 0)..' l')
        local role=FMABunkerCoordinator.role(controller,i)
        local ws=workState(controller,i)
        if b.fillLevel>0 and compact<(controller.settings.bunkerTargetCompaction or 0.98)*100 then
            local phase=ws.phase or 'IDLE'
            controller:issue('bunker:'..i,'Silážní jáma '..i..' · '..role,
                'Zaplnění '..fillText..' · '..math.floor(b.fillLevel)..' l · zhutnění '..math.floor(compact)..' % · fáze '..phase..'. Cíl příjmu '..math.floor((controller.settings.bunkerFillTarget or 0.90)*100)..' %.',74)
        end
        if ws.intakeClosed and not b.canClose then
            controller:issue('bunker:finish:'..i,'Silážní jáma '..i..' · PŘÍJEM UZAVŘEN',
                'Dosažen cíl zaplnění. Další vozy jedou do následující jámy; tato jáma dokončuje nahrnutí a hutnění.',88)
        end
        if b.canClose and not hasIncoming(controller,i) then
            controller:issue('bunker:cover:'..i,'Silážní jáma '..i..' · PŘIPRAVENA K ZAKRYTÍ',
                'Navážení je ukončeno, FS25 hlásí 100% zhutnění a není zjištěn další příchozí materiál. Technika se vrátí/odstaví. Zakrytí provede majitel ručně.',100)
        end
    end
end

-- Filled silage bunkers are autonomous JOBS, not merely issue notifications.
-- Existing farms may be loaded with several un-compacted bunkers and NO
-- incoming forage deliveries. They must still appear on the order board.
function FMABunkerCoordinator.proposals(controller)
    local out={}
    if not controller.settings.bunkerAutomation then return out end
    for i,b in ipairs(controller.bunkers or {}) do
        local compact=tonumber(b.compactedPercent) or 0
        local level=tonumber(b.fillLevel) or 0
        if level>100 and compact<(controller.settings.bunkerTargetCompaction or 0.98)*100 and not b.canClose then
            local ws=workState(controller,i)
            local t={id='bunkerOrder:'..b.key,kind='bunkerWorkOrder',operation='compact',
                bunkerIndex=i,bunkerKey=b.key,priority=90,attempts=0,
                label='Silážní jáma '..i..' · hutnění '..math.floor(compact+0.5)..' %',
                phase='ČEKÁ NA VÝBĚR STROJE',state='pending',x=b.x,z=b.z,
                compactBefore=compact,fillBefore=level}
            if ws.blocked then
                t.state='blocked';t.reason=ws.lastError or 'Předchozí pokusy Courseplay selhaly';t.blockedByIntegration=true
            elseif not fillStateOk(b) then
                t.state='blocked';t.reason='Jáma není ve stavu příjmu, Courseplay nemůže bezpečně hutnit';t.blockedByIntegration=true
            end
            out[#out+1]=t
        end
    end
    return out
end

local function angle(dx,dz)
    return MathUtil and MathUtil.getYRotationFromDirection and MathUtil.getYRotationFromDirection(dx,dz) or 0
end


function FMABunkerCoordinator.deliveryPlan(controller,b,record)
    if not b or not b.geometry or not record then return nil,'Chybí geometrie silážní jámy' end
    local g=b.geometry;local vx,vz=FMAUtil.position(record.object)
    local df=vx and ((vx-g.frontOutside.x)^2+(vz-g.frontOutside.z)^2) or 0
    local db=vx and ((vx-g.backOutside.x)^2+(vz-g.backOutside.z)^2) or math.huge
    local fromFront=df<=db
    local entry=fromFront and g.frontOutside or g.backOutside
    local other=fromFront and g.backOutside or g.frontOutside
    local inwardX,inwardZ=fromFront and g.dx or -g.dx,fromFront and g.dz or -g.dz
    local front=fromFront and g.front or g.back
    local unload={x=front.x+inwardX*math.min(math.max(8,g.length*0.35),g.length*0.65),z=front.z+inwardZ*math.min(math.max(8,g.length*0.35),g.length*0.65)}
    local wrapper=b.wrapper
    if not wrapper or not wrapper.initialized or not wrapper.SIDE_MODES or wrapper.siloMode~=wrapper.SIDE_MODES.OPEN then
        return nil,'Automatický průjezd vyžaduje Courseplayem ověřenou otevřenou jámu; couvací vykládka zde není ověřena'
    end
    local through=true;local mode='driveThrough'
    local waitDistance=controller.settings.bunkerWaitDistance or 12
    local wait={x=entry.x-inwardX*waitDistance,z=entry.z-inwardZ*waitDistance}
    return {mode=mode,entry=entry,exit=through and other or entry,unload=unload,inwardX=inwardX,inwardZ=inwardZ,wait=wait}
end

function FMABunkerCoordinator.bestBunker(controller,fillType,record)
    syncCampaign(controller)
    local primary=roundedIndex(controller.settings.bunkerPrimaryIndex)
    local function candidate(i)
        local b=controller.bunkers and controller.bunkers[i]
        local ws=b and workState(controller,i) or nil
        if b and fillStateOk(b) and accepted(b.object,fillType) and b.geometry and not (ws and ws.intakeClosed) and not targetReached(controller,b) then return {index=i,bunker=b} end
        return nil
    end
    if primary>0 then
        local selected=candidate(primary)
        if selected then return selected end
        promoteNext(controller,primary)
        primary=roundedIndex(controller.settings.bunkerPrimaryIndex)
        if primary>0 then local selected=candidate(primary);if selected then return selected end end
    end
    local best,bestScore
    for i,b in ipairs(controller.bunkers or {}) do
        local row=candidate(i)
        if row then
            local ratio=FMABunkerCoordinator.fillRatio(controller,b) or 0
            local d=FMAUtil.distance(record,b) or 0
            local score=ratio*100000+d
            if not best or score<bestScore then best=row;bestScore=score end
        end
    end
    if best and roundedIndex(controller.settings.bunkerPrimaryIndex)==0 then controller.settings.bunkerPrimaryIndex=best.index end
    return best
end

local function startGoto(controller,record,task,point,dirX,dirZ)
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=point.x,z=point.z,angle=angle(dirX,dirZ),tolerance=5})
    if not job then return nil,moveWhy or 'Souprava nepodporuje autonomní přejezd' end
    controller.reservations[record.key]=task.id;record.busy=true
    controller.active[job]={job=job,task=task,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,transferMethod=moveMethod,trafficTarget=point}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;return nil,tostring(err) end
    return job
end

local function totalCargo(record)
    local total=0
    for _,o in ipairs(FMAWorld.children(record.object)) do
        for i,_ in pairs(FMAUtil.call(o,'getFillUnits') or (o.spec_fillUnit and o.spec_fillUnit.fillUnits) or {}) do
            local ft=FMAUtil.call(o,'getFillUnitFillType',i);local level=FMAUtil.call(o,'getFillUnitFillLevel',i) or 0
            if level>0 and (not FillType or ft~=FillType.DIESEL) then total=total+level end
        end
    end
    return total
end

local function dischargeTool(record,fillType)
    for _,o in ipairs(FMAWorld.children(record.object)) do
        if o.spec_dischargeable then
            for _,node in ipairs(o.spec_dischargeable.dischargeNodes or {}) do
                local ft=FMAUtil.call(o,'getDischargeFillType',node) or FMAUtil.call(o,'getFillUnitFillType',node.fillUnitIndex)
                local level=node.fillUnitIndex and (FMAUtil.call(o,'getFillUnitFillLevel',node.fillUnitIndex) or 0) or 0
                local ground=FMAUtil.call(o,'getCanDischargeToGround',node)
                if level>1 and (fillType==nil or ft==fillType) and ground==true then return o,node end
            end
        end
    end
    return nil
end

function FMABunkerCoordinator.yieldWorker(controller,index,plan)
    local count=0
    for job,a in pairs(controller.active or {}) do
        if a.task and a.task.kind=='bunker' and a.task.bunkerIndex==index then
            a.task.yieldForDelivery=true
            local g=controller.bunkers[index].geometry;local offset=(g.width or 12)+12
            a.task.yieldPoint={x=plan.entry.x+plan.inwardZ*offset,z=plan.entry.z-plan.inwardX*offset}
            FMAAI.stop(job);count=count+1
        end
    end
    return count>0
end

local function beginManagedDelivery(controller,parentActive,fillType,options)
    options=options or {}
    local record=parentActive.vehicle;local target=FMABunkerCoordinator.bestBunker(controller,fillType,record)
    if not target then return false,'Chybí vlastní silážní jáma přijímající '..FMAWorld.fillName(fillType) end
    local ws=workState(controller,target.index)
    ws.armed=true
    if ws.activeDeliveryKey and ws.activeDeliveryKey~=record.key then return false,'Silážní jáma je právě rezervovaná jinou soupravou' end
    local plan,why=FMABunkerCoordinator.deliveryPlan(controller,target.bunker,record);if not plan then ws.activeDeliveryKey=nil;return false,why end
    target.bunker.deliveryMode=plan.mode
    local zone='bunker:'..target.index..':delivery'
    local granted=not controller.settings.trafficSafety or select(1,FMATraffic.reserve(controller.traffic,zone,record.key,'bunkerDelivery',controller.now,180000))
    if not granted then ws.activeDeliveryKey=nil;return false,'Silážní jáma je právě rezervovaná jinou soupravou' end
    if FMABunkerCoordinator.yieldWorker(controller,target.index,plan) then
        FMATraffic.release(controller.traffic,record.key)
        return false,'Čeká na uvolnění vjezdu pracovníkem v jámě'
    end
    for _,a in pairs(controller.active or {}) do
        if a.task.bunkerIndex==target.index and (a.task.kind=='bunkerApproach' or a.task.kind=='bunkerYield') then
            FMATraffic.release(controller.traffic,record.key)
            return false,'Čeká na uvolnění vjezdu pracovníkem v jámě'
        end
    end
    ws.lastDeliveryAt=controller.now;ws.phase='DELIVERY';ws.activeDeliveryKey=record.key
    local fieldId=parentActive.task and parentActive.task.fieldId
    local task={id='bunkerDelivery:'..tostring(fieldId or 'support')..':'..record.key,kind='bunkerDelivery',operation='supply',label='Odvoz do silážní jámy '..target.index,
        parentTask=parentActive.task,bunkerIndex=target.index,bunkerObject=target.bunker.object,plan=plan,fillType=fillType,phase='approach',priority=99,state='running',
        returnToGroup=options.returnToGroup==true,parentGroup=options.parentGroup,harvesterKey=options.harvesterKey,fieldId=fieldId}
    local dirX,dirZ=plan.inwardX,plan.inwardZ
    local job,startWhy=startGoto(controller,record,task,plan.entry,dirX,dirZ)
    if not job then if controller.traffic then FMATraffic.release(controller.traffic,record.key) end;ws.activeDeliveryKey=nil;return false,startWhy end
    if parentActive.task then parentActive.task.state='running';parentActive.task.reason='Odvoz do jámy · režim '..(plan.mode=='driveThrough' and 'PRŮJEZD' or 'COUVÁNÍ') end
    controller:notify(record.name..' jede do silážní jámy '..target.index..' · '..(plan.mode=='driveThrough' and 'průjezdný režim' or 'couvací režim'))
    return true
end

function FMABunkerCoordinator.beginForageDelivery(controller,parentActive,fillType)
    return beginManagedDelivery(controller,parentActive,fillType,{returnToGroup=false})
end

function FMABunkerCoordinator.beginSupportDelivery(controller,supportActive,fillType)
    local task=supportActive and supportActive.task or nil
    return beginManagedDelivery(controller,supportActive,fillType,{returnToGroup=true,parentGroup=task and task.parentGroup,harvesterKey=task and task.harvesterKey})
end

local function releaseWorkZone(controller,index,vehicleKey)
    if controller.traffic and vehicleKey then FMATraffic.release(controller.traffic,vehicleKey) end
end

local function recordWorkFailure(controller,index,detail,vehicleKey)
    local s=workState(controller,index)
    s.failures=(s.failures or 0)+1
    s.lastError=tostring(detail or 'Práce v jámě skončila bez průběhu')
    s.failedVehicleKey=vehicleKey
    for _,v in ipairs(controller.vehicles or {}) do
        if v.key==vehicleKey then
            local x,z=FMAUtil.position(v.object)
            if x and z then s.failedPose={x=x,z=z} end
            break
        end
    end
    -- A CP geofence breach is a machine-safety fault, not a request to try
    -- the very same drive with another tractor. Explicit Alt+R is required.
    if s.lastError:find('BEZPEČNOST:',1,true) then
        s.blocked=true
        s.ownFallbackDenied=true
        s.phase='BEZPEČNOSTNÍ BLOKACE'
    end
    local delay=math.min(300000,60000*s.failures)
    s.retryAt=controller.now+delay
    if vehicleKey then
        s.failedVehicleUntil=s.failedVehicleUntil or {}
        s.failedVehicleUntil[vehicleKey]=controller.now+math.max(120000,delay)
    end
    if s.failures>=3 then s.blocked=true end
    releaseWorkZone(controller,index,vehicleKey)
    controller:issue('bunker:work:'..index,'Silážní jáma '..index..' · automatika pozastavena',
        s.lastError..(s.blocked and ' · 3 neúspěšné pokusy; Alt+R obnoví pokus.' or ' · další pokus nejdříve za '..math.floor(delay/1000)..' s.'),99)
end

function FMABunkerCoordinator.resetFailures(controller)
    controller.bunkerWorkState={}
end

-- When a compatible machine already stands next to a silo mouth, an extra
-- GIANTS GoTo to a geometrically guessed point is actively harmful. The 2026-10-03
-- live trace showed a XERION 11 m from the mouth but GoTo failed as unreachable.
-- Ask CP to start its actual silo worker directly; never claim success without
-- accepting the job and later observing real compaction.
local function startBunkerWorker(controller,b,index,vehicle,role,parent)
    -- An AI "success" event is not proof of arrival. In the October live
    -- recording XERION stopped >30m from the selected bunker, yet the old
    -- onStopped handler started CP at that wrong position. Check the ACTUAL
    -- position and heading at the point of transfer, including when invoked
    -- by a delayed job-stop callback.
    if not b or not b.geometry or not vehicle or not vehicle.object then
        return nil,'Po příjezdu se ztratila živá geometrie jámy nebo traktor'
    end
    -- The real 0.20.45 XERION trace showed CP starting at a physically valid
    -- REAR approach, immediately driving farther OUT of the back of the silo.
    -- Our CP bridge cannot prove its drive direction for that rear entry.
    -- Only hand over at the oriented FRONT entrance; otherwise the dispatch
    -- should choose the native, corridor-bounded inside driver or re-route.
    local frontOk,frontReason=FMABunkerCoordinator.safeWorkerStart(b,vehicle.object,true)
    if not frontOk then
        return nil,'Courseplay nemá ověřený přední vjezd/směr hutnění: '..tostring(frontReason)
    end
    local info={id='bunker:work:'..index,kind='bunker',operation='compact',bunkerIndex=index,
        label='Silážní jáma '..index..' · hutnění',state='starting',priority=86,
        role=role,x=b.x,z=b.z,parentTask=parent,parentTaskId=parent and parent.id}
    -- The parking manager captures a real free tractor's initial yard pose
    -- before its CP work; this remains a physical return destination.
    if FMAReturnManager and FMAReturnManager.captureHomes then
        pcall(FMAReturnManager.captureHomes,controller)
    end
    local job,why=FMACourseplay.startBunker(controller,vehicle,b.x,b.z,info)
    if not job then return nil,why or 'Courseplay nepřijal práci v silážní jámě' end
    controller.reservations[vehicle.key]=info.id
    vehicle.busy=true
    local physicalX,physicalZ=FMAUtil.position(vehicle.object)
    controller.active[job]={job=job,task=info,vehicle=vehicle,start=controller.now,
        lastProgress=controller.now,x=physicalX,z=physicalZ,fill=vehicle.fillTotal,
        startX=physicalX,startZ=physicalZ,
        startCompaction=b.compactedPercent or 0,startFill=b.fillLevel or 0}
    local ws=workState(controller,index)
    ws.active=true;ws.approaching=false;ws.vehicleKey=vehicle.key
    if parent and parent.ownerStopRequested~=true then
        parent.state='starting';parent.phase='COURSEPLAY · OVĚŘUJE ZAHÁJENÍ HUTNĚNÍ'
        parent.reason='Požadavek odeslán Courseplay · čeká se na start motoru, potvrzení AI a průjezd jámou'
    end
    if FMADiagnostics then FMADiagnostics.event(controller,'bunker.cpWorkerRequested',tostring(index),vehicle.name or vehicle.key) end
    return job
end

-- Only after a COMPACTION FINISHED event may a crew depart. If it is
-- physically inside the concrete bunker, first navigate to a real gate and
-- verify THAT leg before returning to the taught tractor bay. Never teleport.
local function departBunkerIfInside(controller,active)
    local t=active.task
    local b=controller.bunkers and controller.bunkers[t.bunkerIndex]
    local g=b and b.geometry
    local v=active.vehicle
    local x,z=nil,nil
    if v then x,z=FMAUtil.position(v.object) end
    if not g or not g.front or not g.dx or not g.dz or not g.length or not g.width
        or not x or not z then return false,nil,false end
    local along=(x-g.front.x)*g.dx+(z-g.front.z)*g.dz
    local lateral=math.abs(-(x-g.front.x)*g.dz+(z-g.front.z)*g.dx)
    local inside=along>=-2 and along<=g.length+2 and lateral<=g.width*0.5+1.5
    if not inside then return false,nil,false end
    local fromFront=along<g.length*0.5
    local gate=fromFront and g.frontOutside or g.backOutside
    if not gate then return false,'Chybí výjezdový bod jámy',true end
    local task={id='bunkerExit:'..tostring(t.bunkerIndex)..':'..tostring(v.key),
        kind='bunkerExit',operation='compact',bunkerIndex=t.bunkerIndex,
        originalWork=t,parentTask=t.parentTask,exitPoint=gate,
        label='Fyzický výjezd z jámy '..tostring(t.bunkerIndex),
        priority=100,state='running',exitAttempt=1}
    local outwardX,outwardZ=fromFront and -g.dx or g.dx,fromFront and -g.dz or g.dz
    local job,why=startGoto(controller,v,task,gate,outwardX,outwardZ)
    if job then
        if t.parentTask then t.parentTask.state='returning';t.parentTask.phase='VYJÍŽDÍ Z JÁMY' end
        controller:notify(v.name..' dohutnil · vyjíždí fyzicky z jámy '..tostring(t.bunkerIndex))
        if FMADiagnostics then FMADiagnostics.event(controller,'bunker.exitRequested',task.id,v.name) end
        return true,nil,true
    end
    return false,why or 'Výjezd z jámy nemá sjízdnou trasu',true
end

function FMABunkerCoordinator.onStopped(controller,active)
    local t=active.task
    if t.kind=='bunkerApproach' then
        if active.stopReason then
            recordWorkFailure(controller,t.bunkerIndex,active.stopReason,active.vehicle.key)
            if t.parentTask and t.parentTask.ownerStopRequested~=true then t.parentTask.state='pending';t.parentTask.reason=tostring(active.stopReason) end
            t.state='blocked'
            return true
        end
        local b=controller.bunkers and controller.bunkers[t.bunkerIndex]
        if not b or not b.x or not b.z then
            recordWorkFailure(controller,t.bunkerIndex,'Po příjezdu chybí geometrie cílové jámy',active.vehicle.key)
            return true
        end
        -- Never regard an unreachable/partial GoTo as a successful approach.
        -- The CP worker may only take the vehicle from the verified mouth.
        local fromFront=t.fromFront
        local arrived,arrivalWhy=FMABunkerCoordinator.safeWorkerStart(b,active.vehicle.object,fromFront~=false)
        -- A rear-mouth GoTo might finish successfully, but it must not feed CP
        -- until a directional start model has been verified for this map.
        if arrived and fromFront==false then
            arrived=false
            arrivalWhy='Zadní vjezd není pro Courseplay směrově ověřen; nepředávám řízení'
        end
        if not arrived then
            recordWorkFailure(controller,t.bunkerIndex,'PŘÍJEZD NEOVĚŘEN: '..tostring(arrivalWhy),active.vehicle.key)
            if t.parentTask and t.parentTask.ownerStopRequested~=true then
                t.parentTask.state='pending';t.parentTask.phase='JINÝ VJEZD / JINÝ TRAKTOR'
                t.parentTask.reason='FS25 oznámilo konec přejezdu, ale fyzická poloha a směr u vjezdu nesouhlasí: '..tostring(arrivalWhy)
                t.parentTask.retryAt=workState(controller,t.bunkerIndex).retryAt
            end
            t.state='blocked';t.reason=tostring(arrivalWhy)
            if FMADiagnostics then FMADiagnostics.event(controller,'bunker.ARRIVAL_REJECTED',
                active.vehicle.name or active.vehicle.key,tostring(arrivalWhy)) end
            return true
        end
        local job,why=startBunkerWorker(controller,b,t.bunkerIndex,active.vehicle,t.role,t.parentTask)
        if not job then
            recordWorkFailure(controller,t.bunkerIndex,why,active.vehicle.key)
            if t.parentTask and t.parentTask.ownerStopRequested~=true then t.parentTask.state='pending';t.parentTask.reason=tostring(why) end
            t.state='blocked'
            return true
        end
        controller:notify(active.vehicle.name..' dorazil k jámě; Courseplay dostal požadavek, převzetí ověří watchdog')
        return true
    elseif t.kind=='bunkerExit' then
        -- Report parking success ONLY when the physical return job verifies it.
        local target=t.exitPoint
        local px,pz=FMAUtil.position(active.vehicle.object)
        if active.stopReason or not px or not pz or not target
            or (px-target.x)^2+(pz-target.z)^2>12*12 then
            local why=active.stopReason or 'Traktor nepotvrdil výjezd na reálný bod za jámou'
            if t.parentTask then
                t.parentTask.returnFailed=true;t.parentTask.state='blocked'
                t.parentTask.phase='HUTNĚNÍ HOTOVO · NEÚSPĚŠNÝ VÝJEZD'
                t.parentTask.reason='Zhutnění hotovo; výjezd/parkování blokuje: '..tostring(why)
            end
            controller:issue('bunkerExit:'..tostring(t.bunkerIndex),'Traktor zůstal u jámy',tostring(why),98)
            return true
        end
        local original=t.originalWork or t
        local ok,why=nil,'Není dostupný systém návratu'
        if FMAReturnManager then ok,why=FMAReturnManager.begin(controller,{task=original,vehicle=active.vehicle}) end
        if not ok then
            if t.parentTask then
                t.parentTask.returnFailed=true;t.parentTask.reason='Z jámy vyjel, ale parkování čeká: '..tostring(why)
            end
            controller:issue('bunkerParking:'..tostring(t.bunkerIndex),'Traktor vyjel, čeká parkování',tostring(why),92)
        end
        return true
    elseif t.kind=='bunker' then
        local ws=workState(controller,t.bunkerIndex);ws.active=false
        local b=controller.bunkers and controller.bunkers[t.bunkerIndex]
        local duration=controller.now-(active.start or controller.now)
        local compactNow=b and (b.object and b.object.compactedPercent or b.compactedPercent) or 0
        if t.switchToCompaction then
            ws.failures=0;ws.retryAt=controller.now+(controller.settings.bunkerSettleSeconds or 8)*1000;ws.phase='COMPACT';releaseWorkZone(controller,t.bunkerIndex,active.vehicle.key)
            t.state='done';t.reason='Nahrnutí dokončeno · přechod na hutnění'
            if controller.settings.autoReturn and FMAReturnManager then local ok=FMAReturnManager.begin(controller,{task=t,vehicle=active.vehicle});if ok then return true end end
            return true
        end
        if t.completeForCover then
            ws.failures=0;ws.retryAt=0;ws.blocked=false;releaseWorkZone(controller,t.bunkerIndex,active.vehicle.key)
            t.state='done';t.reason='Jáma připravena k ručnímu zakrytí'
            if controller.settings.autoReturn then
                local departed,why,inside=departBunkerIfInside(controller,active)
                if departed then return true end
                if inside then
                    if t.parentTask then t.parentTask.returnFailed=true;t.parentTask.state='blocked';t.parentTask.reason='Hutnění dokončeno, ale výjezd selhal: '..tostring(why) end
                    controller:issue('bunkerExit:'..tostring(t.bunkerIndex),'Zhutněná jáma · zablokovaný výjezd',tostring(why),98)
                    return true
                end
                if FMAReturnManager then
                    local ok,why=FMAReturnManager.begin(controller,{task=t,vehicle=active.vehicle})
                    if ok then if t.parentTask then t.parentTask.state='returning';t.parentTask.phase='ODJEZD NA PARKOVÁNÍ' end;return true end
                    controller:issue('bunkerParking:'..tostring(t.bunkerIndex),'Zhutněná jáma · chybí parkování',tostring(why),90)
                end
            end
            return true
        end
        if t.yieldForDelivery and t.yieldPoint then
            releaseWorkZone(controller,t.bunkerIndex,active.vehicle.key)
            local wait={id='bunkerYield:'..t.bunkerIndex..':'..active.vehicle.key,kind='bunkerYield',operation='compact',label='Uvolnění silážní jámy',bunkerIndex=t.bunkerIndex,phase='yield',priority=99,state='running'}
            local bb=controller.bunkers[t.bunkerIndex];local dx,dz=bb and bb.geometry and bb.geometry.dx or 0,bb and bb.geometry and bb.geometry.dz or 1
            local job=startGoto(controller,active.vehicle,wait,t.yieldPoint,-dx,-dz)
            if job then controller:notify(active.vehicle.name..' uvolňuje vjezd odvozní soupravě');return true end
        end
        if active.stopReason or compactNow<100 then
            local detail=active.stopReason or ('Courseplay ukončil práci v jámě po '..string.format('%.1f',duration/1000)..' s bez stabilního průběhu')
            recordWorkFailure(controller,t.bunkerIndex,detail,active.vehicle.key)
            if t.parentTask and t.parentTask.ownerStopRequested~=true then t.parentTask.state='pending';t.parentTask.reason=detail end
            t.state='blocked';t.reason=detail;return true
        else
            ws.failures=0;ws.retryAt=controller.now+30000;ws.lastCompaction=compactNow
            releaseWorkZone(controller,t.bunkerIndex,active.vehicle.key)
        end
        t.state='done'
        if t.parentTask and t.parentTask.ownerStopRequested~=true then
            t.parentTask.state='done';t.parentTask.phase='HUTNĚNÍ DOKONČENO'
            t.parentTask.reason='Zhutnění bylo ověřeno ze stavu jámy'
        end
        if controller.settings.autoReturn then
            local departing,why,wasInside=departBunkerIfInside(controller,active)
            if departing then return true end
            if wasInside then
                if t.parentTask then
                    t.parentTask.returnFailed=true;t.parentTask.state='blocked'
                    t.parentTask.reason='Zhutnění hotovo; nelze fyzicky vyjet: '..tostring(why)
                end
                controller:issue('bunkerExit:'..tostring(t.bunkerIndex),
                    'Dokončeno zhutnění, ale nelze vyjet z jámy',tostring(why),99)
                return true
            end
        end
        if controller.settings.autoReturn and FMAReturnManager then
            local ok,why=FMAReturnManager.begin(controller,{task=t,vehicle=active.vehicle})
            if ok then
                if t.parentTask then
                    t.parentTask.state='returning';t.parentTask.phase='HUTNĚNÍ HOTOVO · NÁVRAT DO STÁNÍ'
                    t.parentTask.reason='Zhutnění ověřeno; parkování potvrdí až fyzický dojezd'
                end
                return true
            end
            if t.parentTask then
                t.parentTask.returnFailed=true
                t.parentTask.reason='Zhutnění ověřeno, ale nebylo možné zahájit parkování: '..tostring(why)
            end
            controller:issue('bunkerParking:'..tostring(t.bunkerIndex),
                'Po hutnění zbývá fyzické parkování',tostring(why or 'Neznámý odstavný bod'),92)
        end
        return true
    elseif t.kind=='bunkerYield' then
        if active.stopReason then recordWorkFailure(controller,t.bunkerIndex,active.stopReason,active.vehicle.key);return true end
        if controller.traffic then FMATraffic.release(controller.traffic,active.vehicle.key) end
        t.state='done';active.vehicle.busy=false;controller.reservations[active.vehicle.key]=nil;return true
    elseif t.kind~='bunkerDelivery' then return false end
    local plan=t.plan;local record=active.vehicle
    if active.stopReason then
        workState(controller,t.bunkerIndex).activeDeliveryKey=nil
        local parent=t.parentTask;if parent then parent.state='blocked';parent.reason=active.stopReason end
        if controller.traffic then FMATraffic.release(controller.traffic,record.key) end
        return true
    end
    if t.phase=='approach' then
        t.phase='position'
        local dirX,dirZ=plan.inwardX,plan.inwardZ
        if plan.mode=='reverse' then dirX,dirZ=-dirX,-dirZ end
        local job,why=startGoto(controller,record,t,plan.unload,dirX,dirZ)
        if not job then
            workState(controller,t.bunkerIndex).activeDeliveryKey=nil;FMATraffic.release(controller.traffic,record.key)
            FMAJobs.fail(controller,t.parentTask or t,record,why);return true end
        return true
    elseif t.phase=='position' then
        local tool,node=dischargeTool(record,t.fillType)
        local b=controller.bunkers[t.bunkerIndex]
        if not b or b.object~=t.bunkerObject or FMAUtil.owner(b.placeable)~=controller.farmId or not FMABunkerCoordinator.insideDischarge(b,tool,node) then
            workState(controller,t.bunkerIndex).activeDeliveryKey=nil
            FMAJobs.fail(controller,t,record,'Výstup nákladu není uvnitř ověřené vlastní jámy');if t.parentTask then t.parentTask.state='blocked';t.parentTask.reason=t.reason end
            if controller.traffic then FMATraffic.release(controller.traffic,record.key) end;return true
        end
        if not tool then local p=t.parentTask;if p then p.state='blocked';p.reason='Nenalezen výsyp vhodný pro vyklopení do jámy' end;return true end
        if node.index and FMAUtil.call(tool,'setCurrentDischargeNodeIndex',node.index)==false then end
        local ok=pcall(tool.setDischargeState,tool,Dischargeable and Dischargeable.DISCHARGE_STATE_GROUND or 2,true)
        if not ok then
            workState(controller,t.bunkerIndex).activeDeliveryKey=nil
            FMATraffic.release(controller.traffic,record.key)
            FMAJobs.fail(controller,t.parentTask or t,record,'FS25 odmítl vyklápění na zem v jámě')
            return true
        end
        controller.bunkerDeliverySessions=controller.bunkerDeliverySessions or {}
        controller.bunkerDeliverySessions[t.id]={task=t,vehicle=record,tool=tool,node=node,started=controller.now,lastProgress=controller.now,lastCargo=FMAUtil.call(tool,'getFillUnitFillLevel',node.fillUnitIndex) or 0}
        controller.reservations[record.key]=t.id;record.busy=true;t.phase='unloading'
        controller:notify(record.name..' vyklápí v silážní jámě '..t.bunkerIndex)
        return true
    elseif t.phase=='exit' then
        local ws=workState(controller,t.bunkerIndex);ws.activeDeliveryKey=nil;ws.lastDeliveryAt=controller.now;ws.phase='PUSH';ws.pushUntil=controller.now+(controller.settings.bunkerPushSeconds or 35)*1000
        local parent=t.parentTask
        if controller.traffic then FMATraffic.release(controller.traffic,record.key) end
        if t.returnToGroup then
            if parent then parent.state='done';parent.phase='NÁKLAD VYLOŽEN';parent.reason='Siláž vyložena · souprava je znovu volná pro řezačku' end
            controller.reservations[record.key]=nil;record.busy=false
            controller:notify(record.name..' vyložil siláž · vrací se do oběhu sklizňové skupiny')
            controller.elapsed=(controller.settings.scanSeconds or 12)*1000
            return true
        end
        if FMAForageCoordinator.resumeAfterDelivery(controller,parent,record) then return true end
        if parent and FMAForageCoordinator then controller.forageStages[tostring(parent.fieldId)]='collected';parent.state='done';parent.reason='Materiál vyložen do silážní jámy' end
        if controller.settings.autoReturn and FMAReturnManager then local ok=FMAReturnManager.begin(controller,{task=parent or t,vehicle=record});if ok then return true end end
        return true
    end
    return true
end

-- Predict departure BEFORE the wheel crosses the limit, rather than stopping
-- once the XERION has already driven into neighbouring buildings. This checks
-- any GIANTS/CP compaction job, independently of which UI page is visible.
function FMABunkerCoordinator.enforceSafety(controller)
    local now=controller.now or 0
    for job,a in pairs(controller.active or {}) do
        if a and a.task and a.task.kind=='bunker' and not a.task.safetyStopIssued then
            local b=controller.bunkers and controller.bunkers[a.task.bunkerIndex]
            local x,z=nil,nil
            if a.vehicle then x,z=FMAUtil.position(a.vehicle.object) end
            local inside,details=FMABunkerCoordinator.withinWorkEnvelope(b,x,z)
            local unsafe=not inside
            local explanation=unsafe and ('mimo obálku '..tostring(details)) or nil
            if inside then
                local last=a.bunkerSafetySample
                if last and now>last.time then
                    local dt=now-last.time
                    local moved=math.sqrt((x-last.x)^2+(z-last.z)^2)
                    if dt>=60 and dt<=3000 and moved>=.025 then
                        local distanceToProject=math.min(5,moved/dt*1600)
                        local length=moved
                        local px=x+(x-last.x)/length*distanceToProject
                        local pz=z+(z-last.z)/length*distanceToProject
                        local expected=FMABunkerCoordinator.withinWorkEnvelope(b,px,pz)
                        if not expected then
                            unsafe=true
                            explanation=string.format('předvídaný odjezd z koridoru: nyní %.1f,%.1f -> %.1f,%.1f',x,z,px,pz)
                        end
                    end
                end
                if not unsafe and (not last or now-last.time>=150) then
                    a.bunkerSafetySample={time=now,x=x,z=z}
                end
            end
            if unsafe then
                local msg='BEZPEČNOST: '..tostring(explanation)
                a.task.safetyStopIssued=true
                a.stopReason=msg
                if FMADiagnostics then
                    FMADiagnostics.event(controller,'bunker.GEOFENCE_STOP',a.vehicle and a.vehicle.name or '-',
                        'bunker='..tostring(a.task.bunkerIndex)..' x='..tostring(x)..' z='..tostring(z)..' '..msg)
                end
                FMAAI.stop(job)
            end
        end
    end
end

function FMABunkerCoordinator.update(controller)
    syncCampaign(controller)
    -- The safety watchdog also runs every FS25 frame from FMAController.update.
    -- Normal bunker orchestration stays at the slower one-second rate.
    FMABunkerCoordinator.enforceSafety(controller)
    for i,b in ipairs(controller.bunkers or {}) do
        local ws=workState(controller,i)
        if ws.phase=='PUSH' and (ws.pushUntil or 0)<=controller.now and not ws.activeDeliveryKey then
            local stoppedPusher=false
            for job,a in pairs(controller.active or {}) do
                if a.task and a.task.kind=='bunker' and a.task.bunkerIndex==i and a.task.role=='bunkerPusher' and not a.task.switchToCompaction then
                    a.task.switchToCompaction=true;FMAAI.stop(job);stoppedPusher=true;break
                end
            end
            if not stoppedPusher then ws.phase='COMPACT' end
        end
        if ws.intakeClosed then
            for job,a in pairs(controller.active or {}) do
                if a.task and a.task.kind=='bunker' and a.task.bunkerIndex==i and a.task.role=='bunkerPusher' and not a.task.switchToCompaction then
                    a.task.switchToCompaction=true;FMAAI.stop(job);break
                end
            end
        end
    end
    for id,s in pairs(controller.bunkerDeliverySessions or {}) do
        local cargo=FMAUtil.call(s.tool,'getFillUnitFillLevel',s.node.fillUnitIndex) or s.lastCargo
        if cargo<s.lastCargo-1 then s.lastProgress=controller.now end
        local empty=cargo<1;local timeout=(controller.now-s.lastProgress)>60000
        local cancelled=not controller.settings.enabled or (FMAGameNative and FMAGameNative.isManuallyControlled(s.vehicle.object))==true
        if cancelled then timeout=true end
        if empty or timeout then
            if s.tool and s.tool.setDischargeState then pcall(s.tool.setDischargeState,s.tool,Dischargeable and Dischargeable.DISCHARGE_STATE_OFF or 0,true) end
            controller.bunkerDeliverySessions[id]=nil;controller.reservations[s.vehicle.key]=nil;s.vehicle.busy=false
            local t=s.task
            if timeout then
                workState(controller,t.bunkerIndex).activeDeliveryKey=nil
                local reason=cancelled and 'Vykládku přerušil majitel' or 'Vykládka nepostupuje; náklad zůstal ve voze'
                FMAJobs.fail(controller,t,s.vehicle,reason)
                if t.parentTask then t.parentTask.state='blocked';t.parentTask.reason=reason end
                if controller.traffic then FMATraffic.release(controller.traffic,s.vehicle.key) end
            else
            t.phase='exit';local p=t.plan
            local dirX,dirZ=p.inwardX,p.inwardZ
            local point=p.exit
            if p.mode=='reverse' then dirX,dirZ=-dirX,-dirZ end
            local job,why=startGoto(controller,s.vehicle,t,point,dirX,dirZ)
            if not job then workState(controller,t.bunkerIndex).activeDeliveryKey=nil;FMATraffic.release(controller.traffic,s.vehicle.key);local parent=t.parentTask;if parent then parent.state='blocked';parent.reason=why end;controller:issue(t.id,t.label,why,98) end
            end
        else s.lastCargo=cargo end
    end
    -- Once FS25 says the silo can be covered and no feedstock is incoming, stop the bunker worker. Covering remains manual by design.
    for i,b in ipairs(controller.bunkers or {}) do
        if b.canClose and not hasIncoming(controller,i) then
            local ws=workState(controller,i);ws.armed=false
            for job,a in pairs(controller.active or {}) do
                if a.task and a.task.kind=='bunker' and a.task.bunkerIndex==i then a.task.completeForCover=true;FMAAI.stop(job) end
            end
        end
    end
end

function FMABunkerCoordinator.cancelAll(controller)
    for id,s in pairs(controller.bunkerDeliverySessions or {}) do
        if s.tool and s.tool.setDischargeState then pcall(s.tool.setDischargeState,s.tool,Dischargeable and Dischargeable.DISCHARGE_STATE_OFF or 0,true) end
        if s.vehicle then controller.reservations[s.vehicle.key]=nil;s.vehicle.busy=false;if controller.traffic then FMATraffic.release(controller.traffic,s.vehicle.key) end end
        if s.task and s.task.bunkerIndex then workState(controller,s.task.bunkerIndex).activeDeliveryKey=nil end
        if s.task and s.task.parentTask then s.task.parentTask.state='paused';s.task.parentTask.reason='Pozastaveno majitelem během vykládky do jámy' end
        controller.bunkerDeliverySessions[id]=nil
    end
end

function FMABunkerCoordinator.dispatch(controller)
    if not controller.settings.enabled or not controller.settings.bunkerAutomation then return false end
    if not FMACourseplay.available() and not (FMAOwnDriver and FMAOwnDriver.available) then return false end
    if FMAUtil.count(controller.reservations)>=controller.settings.maxWorkers then return false end
    for i,b in ipairs(controller.bunkers or {}) do
        local ws=workState(controller,i)
        local canFill=fillStateOk(b)
        local incoming=hasIncoming(controller,i)
        if incoming then ws.armed=true end
        local readyForManualCover=b.canClose and not incoming
        local activeCampaign=ws.armed==true or ws.intakeClosed==true or (b.fillLevel or 0)>100
        local deliveryZone=controller.traffic and controller.traffic.zones and controller.traffic.zones['bunker:'..i..':delivery']
        local compactTarget=100
        local root=controller.tasks and controller.tasks['bunkerOrder:'..b.key]
        local approved=controller.settings.selectedJobsOnly~=true or (root and root.ownerApproved==true and root.ownerStopRequested~=true)
        if FMAJobs.mayStart(controller,'bunker:work:'..b.key) and approved and not ws.blocked and activeCampaign and (ws.retryAt or 0)<=controller.now and not readyForManualCover and not ws.activeDeliveryKey and not deliveryZone and b.x and b.z and b.geometry and canFill and b.fillLevel>100 and (b.compactedPercent or 0)<compactTarget then
            local occupied=false
            for _,a in pairs(controller.active or {}) do
                if a.task and (a.task.kind=='bunker' or a.task.kind=='bunkerApproach' or a.task.kind=='bunkerDelivery') and a.task.bunkerIndex==i then occupied=true;break end
            end
            if not occupied then
                local chosen,role,bestScore=nil,nil,math.huge
                local wantPush=not ws.intakeClosed and ws.phase=='PUSH'
                for _,v in ipairs(controller.vehicles or {}) do
                    local cooling=ws.failedVehicleUntil and (ws.failedVehicleUntil[v.key] or 0)>controller.now
                    if not cooling and not v.busy and not controller.excluded[v.key]
                        and not controller.reservations[v.key] and not v.lowFuel
                        and FMAUtil.call(v.object,'getIsAIActive')~=true
                        and (not FMAControlAuthority or FMAControlAuthority.canStart(controller,v)==true)
                        and not (FMAGameNative and FMAGameNative.isManuallyControlled
                            and FMAGameNative.isManuallyControlled(v.object))
                        and (FMAUtil.call(v.object,'getCanStartCpBunkerSiloWorker')==true
                            or (FMAOwnDriver and FMAOwnDriver.available(v.object)==true
                                and (ws.failures or 0)>=1)
                            or (FMAOwnDriver and FMAOwnDriver.planInsideBunker
                                and FMAOwnDriver.available(v.object)==true
                                and FMAOwnDriver.planInsideBunker(controller,v,b)~=nil)) then
                        local candidateRole,penalty=nil,0
                        if wantPush and v.capabilities.pushSilo then candidateRole='bunkerPusher'
                        elseif not wantPush and (v.capabilities.compactSilo or v.capabilities.compact) then candidateRole='bunkerCompactor'
                        elseif v.capabilities.compactSilo then candidateRole='bunkerCompactor';penalty=50
                        elseif not wantPush and v.machineClass=='tractor' and ((v.mass or 0)>=5 or (v.mass or 0)==0) then
                            candidateRole='bunkerCompactor';penalty=75 end
                        if candidateRole and b.geometry then
                            local px,pz=FMAUtil.position(v.object)
                            if px and pz then
                                local g=b.geometry
                                local da=(px-g.frontOutside.x)^2+(pz-g.frontOutside.z)^2
                                local db=(px-g.backOutside.x)^2+(pz-g.backOutside.z)^2
                                local interior=FMAOwnDriver and FMAOwnDriver.planInsideBunker
                                    and FMAOwnDriver.planInsideBunker(controller,v,b)
                                -- A tractor already staged inside the correct bunker
                                -- outranks a tractor that still needs a road transfer.
                                local score=(interior and -1000 or math.sqrt(math.min(da,db)))+penalty
                                if score<bestScore then chosen,role,bestScore=v,candidateRole,score end
                            end
                        end
                    end
                end
                if chosen then
                    -- Courseplay bunker mode expects the vehicle near the silo. First drive to the
                    -- nearest mouth with the base AI, only then start the CP bunker worker.
                    local vx,vz=FMAUtil.position(chosen.object)
                    local g=b.geometry
                    local df=vx and ((vx-g.frontOutside.x)^2+(vz-g.frontOutside.z)^2) or 0
                    local db=vx and ((vx-g.backOutside.x)^2+(vz-g.backOutside.z)^2) or math.huge
                    -- CP start at the rear mouth sent the real XERION outward
                    -- in the supplied October trace. Until CP's rear-directed
                    -- strategy is proven, only stage it from the front mouth.
                    -- Already-inside machines are handled above by OwnDriver.
                    local fromFront=true
                    local point=fromFront and g.frontOutside or g.backOutside
                    local dx,dz=fromFront and g.dx or -g.dx,fromFront and g.dz or -g.dz
                    local task={id='bunker:approach:'..i,kind='bunkerApproach',operation='compact',bunkerIndex=i,label='Silážní jáma '..i..' · '..(role=='bunkerPusher' and 'nahrnování' or 'hutnění'),state='running',priority=86,attempts=1,role=role,x=b.x,z=b.z,parentTaskId=root and root.id,parentTask=root,fromFront=fromFront}
                    local zone='bunker:'..i..':work'
                    local granted=not controller.settings.trafficSafety or select(1,FMATraffic.reserve(controller.traffic,zone,chosen.key,role,controller.now,180000))
                    if granted then
                        -- 0.20.34 issued a CP request while the tractor was still
                        -- ~30 m from the bunker entrance; the motor/worker never
                        -- took over. Only machines at a REAL entry may start CP.
                        -- Everyone else must first finish a verified GIANTS/CP trip.
                        local nearEntry=vx and vz and ((vx-point.x)^2+(vz-point.z)^2)<=12*12
                        local workerReady,workerReason=FMABunkerCoordinator.safeWorkerStart(b,chosen.object,fromFront)
                        local job,why
                        local interior=FMAOwnDriver and FMAOwnDriver.planInsideBunker
                            and FMAOwnDriver.planInsideBunker(controller,chosen,b)
                        if interior then
                            -- A correctly staged tractor MUST be allowed to start
                            -- real work without another (often impossible) GoTo.
                            local started,ownWhy=FMAOwnDriver.beginBunker(controller,chosen,b,i,root,
                                function(c,session,success,detail)
                                    ws.active=false;ws.approaching=false;ws.vehicleKey=nil
                                    releaseWorkZone(c,i,chosen.key)
                                    if success and (b.object and b.object.compactedPercent or b.compactedPercent or 0)>=
                                        (c.settings.bunkerTargetCompaction or 0.98)*100 then
                                        ws.failures=0;ws.retryAt=c.now+30000
                                        if root then root.state='returning';root.phase='HUTNĚNÍ OVĚŘENO · NÁVRAT ČEKÁ';root.reason=tostring(detail) end
                                        local returned,returnReason=nil,'Není dostupný systém návratu'
                                        if FMAReturnManager then returned,returnReason=FMAReturnManager.begin(c,
                                            {task={kind='bunker',operation='compact',bunkerIndex=i,parentTask=root},vehicle=chosen}) end
                                        if not returned and root then root.state='blocked';root.phase='HUTNĚNÍ HOTOVO · PARKOVÁNÍ SELHALO';root.reason=tostring(returnReason) end
                                    elseif tostring(detail)=='Traktor převzal hráč' or not c.settings.enabled then
                                        ws.retryAt=c.now+10000
                                        if root then root.state='paused';root.phase='PŘEVZAL HRÁČ';root.reason=tostring(detail) end
                                    else
                                        recordWorkFailure(c,i,detail or 'Fyzické hutnění neověřeno',chosen.key)
                                        if root then root.state='blocked';root.reason='Vlastní řidič: '..tostring(detail) end
                                    end
                                end)
                            if started then
                                ws.active=true;ws.approaching=false;ws.vehicleKey=chosen.key
                                if root then root.state='running';root.phase='VLASTNÍ ŘIDIČ · UVNITŘ JÁMY';root.reason='Vynechán přejezd; fyzické průjezdy v potvrzeném koridoru' end
                                if FMADiagnostics then FMADiagnostics.event(controller,'bunker.INSIDE_START',chosen.name or chosen.key,tostring(i)) end
                                return true
                            end
                            why=ownWhy or 'Vlastní řidič odmítl ověřený průjezd'
                        elseif nearEntry and workerReady then
                            -- Third AI takes over only AFTER at least one real CP failure.
                            -- Use the verified front entrance and the original bunker
                            -- geometry. Own driver physically alternates forward/reverse.
                            local frontGap=vx and math.sqrt((vx-g.frontOutside.x)^2+(vz-g.frontOutside.z)^2) or math.huge
                            if (ws.failures or 0)>=1 and frontGap<=12 and not ws.ownFallbackDenied
                                and FMAOwnDriver and FMAOwnDriver.available(chosen.object)==true then
                                local started,ownWhy=FMAOwnDriver.beginBunker(controller,chosen,b,i,root,
                                    function(c,session,success,detail)
                                        ws.active=false;ws.approaching=false
                                        ws.vehicleKey=nil
                                        releaseWorkZone(c,i,chosen.key)
                                        local current=b.object and b.object.compactedPercent or b.compactedPercent or 0
                                        if success and current>=(c.settings.bunkerTargetCompaction or .98)*100 then
                                            ws.failures=0;ws.retryAt=c.now+30000
                                            -- Work can be physically complete while the crew is still
                                            -- parked in a silage bunker. This is NOT job completion.
                                            if root then
                                                root.state='returning';root.phase='HUTNĚNÍ OVĚŘENO · NÁVRAT ČEKÁ'
                                                root.reason=tostring(detail)
                                            end
                                            local returned,returnReason=nil,'Není dostupný systém návratu'
                                            if FMAReturnManager then returned,returnReason=FMAReturnManager.begin(c,
                                                {task={kind='bunker',operation='compact',bunkerIndex=i,parentTask=root},vehicle=chosen}) end
                                            if returned then
                                                if root then root.state='returning';root.phase='PARKOVÁNÍ PO HUTNĚNÍ' end
                                            else
                                                if root then
                                                    root.state='blocked';root.phase='HUTNĚNÍ HOTOVO · PARKOVÁNÍ SELHALO'
                                                    root.reason=tostring(returnReason or 'Nebylo možné zahájit návrat')
                                                end
                                                c:issue('ownBunkerParking:'..i,'Hutnění hotovo, parkování čeká',tostring(returnReason),90)
                                            end
                                        elseif tostring(detail)=='Traktor převzal hráč' or not c.settings.enabled then
                                            -- A human intervention is not a physical failure.
                                            -- Leave this work pending for the next explicit dispatch.
                                            ws.retryAt=c.now+10000
                                            if root then root.state='paused';root.phase='PŘEVZAL HRÁČ';root.reason=tostring(detail) end
                                        else
                                            recordWorkFailure(c,i,detail or 'Hutnění bez změny stavu',chosen.key)
                                            ws.ownFallbackDenied=true
                                            if root then root.state='blocked';root.reason='Vlastní řidič: '..tostring(detail) end
                                        end
                                    end)
                                if started then
                                    ws.active=true;ws.approaching=false;ws.vehicleKey=chosen.key
                                    if root then root.state='running';root.phase='VLASTNÍ ŘIDIČ · FYZICKÉ HUTNĚNÍ';root.reason='Kontroluje průjezdy a skutečné zhutnění' end
                                    controller:notify(chosen.name..' · FarmManagerAI převzal fyzické hutnění jámy '..i)
                                    return true
                                end
                                if FMADiagnostics then FMADiagnostics.event(controller,'bunker.ownRejected',tostring(i),tostring(ownWhy)) end
                            end
                            job,why=startBunkerWorker(controller,b,i,chosen,role,root)
                            if job then
                                controller:notify(chosen.name..' · Courseplay požádán o hutnění jámy '..i..' · čeká se na AI, motor a fyzický pohyb')
                                return true
                            end
                        else
                            -- Never start CP from an arbitrary nearby point. A
                            -- verified GoTo is required to position/turn first.
                            if FMADiagnostics and nearEntry and not workerReady then
                                FMADiagnostics.event(controller,'bunker.START_PREFLIGHT',chosen.name or chosen.key,tostring(workerReason))
                            end
                            job,why=startGoto(controller,chosen,task,point,dx,dz)
                        end
                        if interior and not job then
                            if controller.traffic then FMATraffic.release(controller.traffic,chosen.key) end
                            ws.retryAt=controller.now+30000
                            if root then root.state='blocked';root.phase='STROJ V JÁMĚ · ŘÍZENÍ ODMÍTNUTO';root.reason=tostring(why) end
                            if FMADiagnostics then FMADiagnostics.event(controller,'bunker.INSIDE_REJECTED',chosen.name or chosen.key,tostring(why)) end
                            return false
                        end
                        if job then
                            ws.vehicleKey=chosen.key;ws.approaching=true
                            if root then root.state='assembling';root.phase='PŘÍJEZD K JÁMĚ';root.reason=chosen.name..' jede k jámě' end
                            controller:notify(chosen.name..' jede k silážní jámě '..i..' pro '..(role=='bunkerPusher' and 'nahrnování' or 'hutnění'))
                            return true
                        else
                            ws.approaching=false
                            recordWorkFailure(controller,i,why,chosen.key)
                            if root then root.state='pending';root.phase='HLEDÁ JINÝ PŘÍJEZD';root.reason=tostring(why) end
                        end
                    end
                elseif root and approved and (root.state=='pending' or root.state=='blocked') then
                    root.state='pending';root.phase='HLEDÁ VOLNÝ / JINÝ HUTNICÍ STROJ'
                    root.reason='Nenalezen volný stroj s režimem Courseplay pro jámy a vhodným hutnicím nářadím; zkontroluj připojení válce/radlice'
                end
            end
        end
    end
    return false
end

function FMABunkerCoordinator.insideDischarge(b,tool,node)
    if not b or not tool or not node or not node.node or not getWorldTranslation then return false end
    local x,_,z=getWorldTranslation(node.node)
    local a=b.object.bunkerSiloArea;a=a and (a.inner or a)
    if not a then return false end
    local ux,uz=a.wx-a.sx,a.wz-a.sz;local vx,vz=a.hx-a.sx,a.hz-a.sz
    local det=ux*vz-uz*vx;if math.abs(det)<0.01 then return false end
    local dx,dz=x-a.sx,z-a.sz
    local u=(dx*vz-dz*vx)/det;local v=(ux*dz-uz*dx)/det
    return u>0.02 and u<0.98 and v>0.02 and v<0.98 and FMAUtil.call(tool,'getCanDischargeToGround',node)==true
end
