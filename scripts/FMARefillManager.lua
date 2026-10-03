-- Physical pre-work filling/refuelling. The manager only uses real AI-capable
-- loading stations exposed by the map. It never creates fill level out of thin air.
FMARefillManager = {}

local function supports(unit, fillType)
    return unit and unit.supportedFillTypes and unit.supportedFillTypes[fillType]==true
end

function FMARefillManager.desiredFillTypes(task)
    local result,seen={},{}
    if not task then return result end
    local function add(ft)
        if ft~=nil and not seen[ft] then seen[ft]=true;result[#result+1]=ft end
    end
    if task.operation=="sow" and FillType then
        add(FillType.SEEDS)
        -- Combined seeders may also have a fertilizer tank. Map-defined fertilizer
        -- spray types are included below and unsupported fill units are ignored later.
        for _,spray in pairs(FMAUtil.call(g_sprayTypeManager,"getSprayTypes") or {}) do
            if spray.isFertilizer==true and spray.fillType then add(spray.fillType.index or spray.fillType) end
        end
    elseif task.operation=="fertilize" then
        for _,spray in pairs(FMAUtil.call(g_sprayTypeManager,"getSprayTypes") or {}) do
            if spray.isFertilizer==true and spray.fillType then add(spray.fillType.index or spray.fillType) end
        end
        -- Fallback for engine builds/mods that expose the common fill types but not spray metadata.
        if FillType then
            add(FillType.FERTILIZER);add(FillType.LIQUIDFERTILIZER);add(FillType.SLURRY)
            if FillType.LIQUIDMANURE~=FillType.SLURRY then add(FillType.LIQUIDMANURE) end
            add(FillType.MANURE);add(FillType.DIGESTATE)
        end
    elseif task.operation=="weed" then
        if FillType then add(FillType.HERBICIDE) end
    elseif task.operation=="lime" then
        for _,spray in pairs(FMAUtil.call(g_sprayTypeManager,"getSprayTypes") or {}) do
            if spray.isLime==true and spray.fillType then add(spray.fillType.index or spray.fillType) end
        end
        if FillType then add(FillType.LIME) end
    end
    return result
end

function FMARefillManager.requirement(record, task, settings)
    if not record or not record.object then return nil end
    local before=settings.refillBeforeWork or 0.25
    local target=settings.refillTarget or 0.85
    local wanted=FMARefillManager.desiredFillTypes(task)
    local wantedSet={};for _,ft in ipairs(wanted) do wantedSet[ft]=true end
    -- Fuel is a prerequisite for every autonomous assignment.
    if FillType and FillType.DIESEL then wantedSet[FillType.DIESEL]=true end
    local best=nil
    for _,tool in ipairs(FMAWorld.children(record.object)) do
        local units=FMAUtil.call(tool,"getFillUnits") or (tool.spec_fillUnit and tool.spec_fillUnit.fillUnits) or {}
        for i,unit in pairs(units) do
            local capacity=FMAUtil.call(tool,"getFillUnitCapacity",i) or 0
            if capacity>0 then
                local level=FMAUtil.call(tool,"getFillUnitFillLevel",i) or 0
                for fillType in pairs(wantedSet) do
                    if supports(unit,fillType) then
                        local ratio=level/capacity
                        local isFuel=FillType and fillType==FillType.DIESEL
                        local eta=math.max(0,tonumber(task.etaMinutes) or 0)
                        -- Long shifts are prepared before departure instead of waiting for an empty tank.
                        -- This is deliberately conservative: exact material consumption varies by ModHub implement.
                        local forecastFuel=math.min(0.55,0.12+(eta/180)*0.35)
                        local forecastMaterial=math.min(0.65,0.20+(eta/150)*0.35)
                        local threshold=isFuel and math.max(settings.fuelBeforeWork or 0.12,forecastFuel) or math.max(before,forecastMaterial)
                        local targetRatio=isFuel and math.max(settings.fuelTarget or 0.90,math.min(1,forecastFuel+0.25)) or math.max(target,math.min(1,forecastMaterial+0.25))
                        if ratio<threshold then
                            local req={object=tool,fillUnitIndex=i,fillType=fillType,level=level,capacity=capacity,ratio=ratio,targetRatio=targetRatio,isFuel=isFuel,forecastMinutes=eta}
                            if best==nil or req.ratio<best.ratio then best=req end
                        end
                    end
                end
            end
        end
    end
    return best
end

-- A manually filled implement may switch active fill units while parked or the
-- player's interaction may replace the original attachment record. Always read
-- ALL currently attached physical fill units from FS25, not only the saved index.
-- Never infer material from a vehicle total (diesel, seeds and lime are distinct).
function FMARefillManager.liveMaterial(record,req)
    if not req or not record or not record.object then return nil end
    local best=nil
    local objects=FMAWorld.children(record.object)
    -- Preserve the original object for diagnosis if the engine detached it.
    if req.object then
        local seen=false
        for _,obj in ipairs(objects) do if obj==req.object then seen=true;break end end
        if not seen and not req.object.isDeleted then objects[#objects+1]=req.object end
    end
    for _,obj in ipairs(objects) do
        if obj and not obj.isDeleted then
            local units=FMAUtil.call(obj,'getFillUnits') or (obj.spec_fillUnit and obj.spec_fillUnit.fillUnits) or {}
            for i,unit in pairs(units) do
                local index=tonumber(i)
                if index then
                    local actualType=FMAUtil.call(obj,'getFillUnitFillType',index)
                    local supported=(unit and unit.supportedFillTypes and unit.supportedFillTypes[req.fillType]==true)
                        or FMAUtil.call(obj,'getFillUnitSupportsFillType',index,req.fillType)==true
                        or FMAUtil.call(obj,'getFillUnitAllowsFillType',index,req.fillType)==true
                    -- The original unit is authoritative while empty, but a different
                    -- non-empty unit must report the real material before being accepted.
                    if supported or (obj==req.object and index==req.fillUnitIndex) or actualType==req.fillType then
                        local level=tonumber(FMAUtil.call(obj,'getFillUnitFillLevel',index))
                        local capacity=tonumber(FMAUtil.call(obj,'getFillUnitCapacity',index)) or 0
                        if level and capacity>0 and (actualType==req.fillType or (level<=0 and supported)) then
                            local candidate={object=obj,index=index,level=level,capacity=capacity,
                                ratio=level/capacity,fillType=req.fillType}
                            if not best or candidate.level>best.level then best=candidate end
                        end
                    end
                end
            end
        end
    end
    if not best and req.object and not req.object.isDeleted then
        -- Some ModHub implements expose their active tank through indexed getters
        -- while omitting getFillUnits(). The already-verified request index is
        -- still usable, provided the reported live type does not contradict it.
        local actualType=FMAUtil.call(req.object,'getFillUnitFillType',req.fillUnitIndex)
        if actualType==nil or actualType==req.fillType then
            local level=tonumber(FMAUtil.call(req.object,'getFillUnitFillLevel',req.fillUnitIndex))
            local capacity=tonumber(FMAUtil.call(req.object,'getFillUnitCapacity',req.fillUnitIndex))
                or tonumber(req.capacity) or 0
            if level and capacity>0 then
                best={object=req.object,index=req.fillUnitIndex,level=level,
                    capacity=capacity,ratio=level/capacity,fillType=req.fillType}
            end
        end
    end
    return best
end

function FMARefillManager.manualMaterialReady(controller,record,req)
    local status=FMARefillManager.liveMaterial(record,req)
    if not status then return false,nil end
    local threshold=math.min(0.20,tonumber(controller.settings.refillBeforeWork) or 0.25)
    -- A genuine change must be observed; a merely compatible EMPTY unit cannot
    -- release a work order. Allow limited manually bought material for small fields.
    local ready=status.ratio>=threshold and status.level>(tonumber(req.level) or 0)+1
    return ready,status
end

function FMARefillManager.finishManual(controller,parent,vehicle,status)
    if not parent then return end
    local session=controller.refillSessions and controller.refillSessions[parent.id]
    if session and session.trigger and session.trigger.isLoading and session.trigger.setIsLoading then
        pcall(session.trigger.setIsLoading,session.trigger,false,session.requirement.object,
            session.requirement.fillUnitIndex,session.requirement.fillType)
    end
    if vehicle and vehicle.key then
        controller.reservations[vehicle.key]=nil;vehicle.busy=false
        if controller.traffic and FMATraffic then FMATraffic.release(controller.traffic,vehicle.key) end
    end
    controller.refillSessions[parent.id]=nil
    parent.state='pending';parent.phase='VÁPNO / MATERIÁL DOPLNĚN';parent.reason=nil
    parent.retryAt=0;parent.failures=0;parent.manualSupplyCursor=nil
    parent.manualSupplySourceCursor=nil;parent.manualRefillVehicleKey=nil
    controller.issues['manualRefill:'..parent.id]=nil
    controller.elapsed=(controller.settings.scanSeconds or 12)*1000
    controller.diagnosticDirty=true
    if FMADiagnostics and FMADiagnostics.event then
        FMADiagnostics.event(controller,'refill.manualVerified',parent.id,
            tostring(status and status.level or '?')..'/'..tostring(status and status.capacity or '?')..' l')
    end
    controller:notify('Doplnění potvrzeno: '..tostring(status and math.floor(status.level) or 0)..
        ' l · '..tostring(parent.label or parent.id)..' pokračuje na pole')
end

-- Public/manual supply is a legitimate dependency. The map may advertise a public
-- lime shop but its loading station does NOT support AI automation. Park beside it
-- and wait for a real player fill instead of falsely declaring lime unavailable.
-- Public, owned, or multifruit loading stations can be manually supplied even if
-- their GIANTS AI contract advertises no fill types. Only an actual loading station
-- with verifiable material support (or the existing known lime-shop fallback) is a
-- candidate; the center of a placeable is NEVER treated as a fill trigger.
local function manualStationSupports(controller,row,req)
    for _,ft in ipairs(row.fillTypes or {}) do
        if ft==req.fillType then return true,'ai-list' end
    end
    local station=row.object
    if station and FMAUtil.call(station,'getIsFillTypeSupported',req.fillType)==true then
        return true,'station-contract'
    end
    -- A multifunction silo can expose valid fill types in silo storage metadata
    -- even when currently empty, and even when AI loading is unavailable.
    local place=station and station.owningPlaceable
    if place and place.spec_silo then
        for _,store in ipairs(place.spec_silo.storages or {}) do
            if FMAUtil.call(store,'getIsFillTypeSupported',req.fillType)==true then
                return true,'placeable-silo-type'
            end
        end
    end
    -- An owned multifunction silo can expose supported stock through the physical
    -- PlaceableSilo while the loading station declines to advertise AI capability.
    for _,inventory in ipairs(controller.mapProfile and controller.mapProfile.storages or {}) do
        if place and inventory.object==place and inventory.fillByType and inventory.fillByType[req.fillType] then
            return true,'placeable-inventory'
        end
    end
    local label=string.lower(tostring(row.name or ''))
    if FillType and req.fillType==FillType.LIME and label:find('váp',1,true) then
        return true,'named-lime-source'
    end
    return false,nil
end

function FMARefillManager.manualSupplySources(controller,req,record)
    local results,seen={},{}
    if not req then return results end
    local vx,vz=nil,nil
    if record and record.object then vx,vz=FMAUtil.position(record.object) end
    for _,row in ipairs(controller.mapProfile and controller.mapProfile.loadingStations or {}) do
        local supported,evidence=manualStationSupports(controller,row,req)
        if supported and row.x and row.z then
            local key=string.format('%.1f:%.1f',row.x,row.z)
            if not seen[key] then
                seen[key]=true
                local own=row.owner==controller.farmId
                local distance=vx and math.sqrt((vx-row.x)^2+(vz-row.z)^2) or 0
                -- Prefer an owned verified silo over an equally distant public store.
                -- A vague name match ranks behind directly verified capability.
                local evidencePenalty=evidence=='named-lime-source' and 600 or 0
                results[#results+1]={name=row.name,object=row.object,x=row.x,z=row.z,
                    owner=row.owner,evidence=evidence,score=distance+(own and 0 or 100)+evidencePenalty}
            end
        end
    end
    table.sort(results,function(a,b)
        if a.score~=b.score then return a.score<b.score end
        return tostring(a.name)<tostring(b.name)
    end)
    return results
end

function FMARefillManager.manualWaitingPoints(source,controller)
    local result={}
    if not source or not source.x or not source.z then return result end
    -- Driver-taught safe points have priority. They are saved as role PLNIČKA
    -- and still require a real FS/CP journey, not a position teleport.
    local learned={}
    for _,p in pairs(controller and controller.learnedPoints or {}) do
        if p.role=='PLNIČKA' and p.x and p.z then
            local d2=(p.x-source.x)^2+(p.z-source.z)^2
            if d2<=85*85 then learned[#learned+1]={p=p,d2=d2} end
        end
    end
    table.sort(learned,function(a,b)return a.d2<b.d2 end)
    for _,item in ipairs(learned) do
        local p=item.p
        result[#result+1]={x=p.x,z=p.z,angle=p.angle or 0,taught=true}
    end
    -- Unknown public buildings may be obstructed. Rotate through stand-off
    -- locations, never into the placeable's center or directly into its collision.
    local directions={{1,0},{0,1},{-1,0},{0,-1},{1,1},{-1,1},{-1,-1},{1,-1}}
    for _,distance in ipairs({20,35}) do
        for _,dir in ipairs(directions) do
            local norm=math.sqrt(dir[1]*dir[1]+dir[2]*dir[2])
            result[#result+1]={x=source.x+dir[1]*distance/norm,z=source.z+dir[2]*distance/norm,angle=0}
        end
    end
    return result
end

function FMARefillManager.findStation(controller, record, req, parent)
    if not req then return nil,'Chybí požadavek na materiál' end
    local storage=g_currentMission and g_currentMission.storageSystem
    local candidates={}
    for _,station in pairs(FMAUtil.call(storage,"getLoadingStations") or {}) do
        local supported=FMAUtil.call(station,"getAISupportedFillTypes") or {}
        if supported[req.fillType]==true then
            local owner=FMALogistics and FMALogistics.stationOwner(station) or nil
            local own=owner==controller.farmId
            local canBuy=controller.settings.autoBuyConsumables==true
            if own or canBuy then
                local ok,x,z,dx,dz,trigger=pcall(station.getAITargetPositionAndDirection,station,req.fillType)
                if ok and x and z and trigger and FMAUtil.call(trigger,"getSupportAILoading")==true then
                    local stock=FMAUtil.call(station,"getFillLevel",req.fillType,controller.farmId)
                    if stock==nil or stock>1 or not own then
                        -- Match the base game's loading offset: park the actual fill unit, not the tractor cab, under the trigger.
                        local offsetZ=0
                        local fillNode=FMAUtil.call(req.object,"getFillUnitRootNode",req.fillUnitIndex)
                        if fillNode and record.object.rootNode and localToLocal then
                            local okOffset,_,_,oz=pcall(localToLocal,fillNode,record.object.rootNode,0,0,0)
                            if okOffset and oz then offsetZ=oz end
                        end
                        local targetX=x+(dx or 0)*(-offsetZ);local targetZ=z+(dz or 0)*(-offsetZ)
                        local rx,rz=FMAUtil.position(record.object)
                        local d=rx and math.sqrt((rx-targetX)^2+(rz-targetZ)^2) or 0
                        candidates[#candidates+1]={station=station,trigger=trigger,x=targetX,z=targetZ,triggerX=x,triggerZ=z,dx=dx,dz=dz,own=own,offsetZ=offsetZ,score=d+(own and 0 or 100000)}
                    end
                end
            end
        end
    end
    table.sort(candidates,function(a,b)return a.score<b.score end)
    if #candidates>0 then return candidates[1] end
    local sources=FMARefillManager.manualSupplySources(controller,req,record)
    local sourceCursor=parent and (tonumber(parent.manualSupplySourceCursor) or 1) or 1
    local chosen=sources[sourceCursor]
    if chosen then
        local points=FMARefillManager.manualWaitingPoints(chosen,controller)
        local cursor=parent and (tonumber(parent.manualSupplyCursor) or 1) or 1
        if cursor<=#points then
            local point=points[cursor]
            return {manual=true,name=chosen.name,source=chosen,sources=sources,sourceIndex=sourceCursor,
                waitPoints=points,waitIndex=cursor,x=point.x,z=point.z,dx=0,dz=1,angle=point.angle or 0,
                preferCourseplay=cursor>math.floor(#points/2),taught=point.taught==true}
        end
        return nil,'Plnicí místo '..tostring(chosen.name)..' bylo nalezeno, ale všechny nájezdy AI odmítla. Nauč bezpečný bod PLNIČKA nebo přistav soupravu ručně.'
    end
    local material=FMAWorld.fillName(req.fillType)
    if controller.settings.autoBuyConsumables~=true then
        return nil,"Chybí vlastní AI plnicí místo pro "..material..". Doplň zásobu farmy nebo povol automatický nákup spotřebního materiálu."
    end
    return nil,"Nenalezena přístupná AI plnicí stanice pro "..material
end

local function angleFromDirection(dx,dz)
    if MathUtil and MathUtil.getYRotationFromDirection and dx and dz then return MathUtil.getYRotationFromDirection(dx,dz) end
    return 0
end

function FMARefillManager.startDrive(controller,parent,record,req,station)
    local trafficTask={id="refill:"..parent.id..":"..record.key,kind="refill",operation=parent.operation,parentTaskId=parent.id}
    if FMATraffic and FMATraffic.canStart then
        local free,wait=FMATraffic.canStart(controller,record,station,trafficTask,45000)
        if not free then
            parent.state="pending";parent.phase="ČEKÁ NA PROVOZ";parent.reason=wait;parent.retryAt=controller.now+((controller.settings.trafficRetrySeconds or 6)*1000)
            return true,wait
        end
    end
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=station.x,z=station.z,
        angle=station.manual and station.angle or angleFromDirection(station.dx,station.dz),tolerance=station.manual and 10 or 4,
        preferCourseplay=station.preferCourseplay})
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,moveWhy or "Souprava neumí autonomně dojet k plnicímu místu" end
    local task={id="refill:"..parent.id..":"..record.key,kind="refill",operation=parent.operation,label="Doplnění · "..record.name,
        parentTaskId=parent.id,priority=(parent.priority or 50)+15,state="running",requirement=req,station=station}
    if station.manual then
        parent.manualRefillVehicleKey=record.key
        parent.manualRefillRequirement=req
    end
    parent.state="assembling";parent.phase=station.manual and "CESTA K VEŘEJNÉMU ZDROJI" or "DOPLNĚNÍ MATERIÁLU"
    parent.reason=station.manual and ('Přejezd ke zdroji odeslán · '..tostring(station.name)..' · ruční naložení '..FMAWorld.fillName(req.fillType))
        or ('Doplnění '..FMAWorld.fillName(req.fillType)..' před prací')
    controller.reservations[record.key]=task.id;record.busy=true
    controller.active[job]={job=job,task=task,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,transferMethod=moveMethod,trafficTarget=station}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;parent.state="pending";if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(err) end
    controller:notify(station.manual and (record.name..' · požadavek na přejezd k '..tostring(station.name)..' · čeká na potvrzení pohybu')
        or (record.name.." · požadavek na doplnění "..FMAWorld.fillName(req.fillType)))
    return true
end

function FMARefillManager.dispatch(controller,parent,record)
    local req=FMARefillManager.requirement(record,parent,controller.settings)
    if not req then return false,nil end
    local station,why=FMARefillManager.findStation(controller,record,req,parent)
    if not station then
        controller:issue("material:"..parent.id,parent.label.." · chybí "..FMAWorld.fillName(req.fillType),why,96)
        parent.reason=why
        return false,why
    end
    return FMARefillManager.startDrive(controller,parent,record,req,station)
end

function FMARefillManager.findPreparableVehicle(controller,task)
    local def=FMACatalog.operations[task.operation];if not def then return nil end
    local best,bestD
    for _,v in ipairs(controller.vehicles or {}) do
        if v.capabilities and v.capabilities[def.cap] and not v.busy and not controller.excluded[v.key] and not controller.reservations[v.key] then
            if task.preferredVehicleKey==nil or task.preferredVehicleKey==v.key then
                local configOk=true
                if task.operation=="sow" and v.sowingFruit~=task.crop then configOk=false end
                if task.operation=="harvest" and v.harvestFruits[task.fruitIndex]~=true then configOk=false end
                if configOk then
                    local req=FMARefillManager.requirement(v,task,controller.settings)
                    if req then
                        local d=FMAUtil.distance(v,task)
                        if not best or d<bestD then best,bestD=v,d end
                    end
                end
            end
        end
    end
    return best
end

function FMARefillManager.canLoad(trigger,object,index,fillType,farmId)
    if not trigger or type(trigger.setIsLoading)~="function" then return false,"Plnicí bod nemá rozhraní nakládky" end
    if trigger.isLoading then return false,"Plnicí bod právě obsluhuje jinou nakládku" end
    if FMAUtil.call(trigger,"getSupportAILoading")~=true then return false,"Plnicí bod nepodporuje AI" end
    if FMAUtil.call(trigger,"getIsFillTypeSupported",fillType)~=true then return false,"Plnicí bod nepodporuje materiál" end
    local inRange=false
    for _,entry in pairs(trigger.fillableObjects or {}) do
        if entry.object==object and entry.fillUnitIndex==index then inRange=true;break end
    end
    if not inRange then return false,"Plnicí hrdlo není uvnitř skutečného nakládacího triggeru" end
    if FMAUtil.call(trigger,"getAllowsActivation",object)~=true then return false,"Plnicí bod odmítl aktivaci pro tuto soupravu" end
    if FMAUtil.call(trigger.source,"getIsFillAllowedToFarm",farmId)~=true then return false,"Zdroj nepovolil odběr této farmě" end
    if FMAUtil.call(object,"getFillUnitAllowsFillType",index,fillType)~=true then return false,"Nádrž nepřijímá zvolený materiál" end
    if not ToolType or FMAUtil.call(object,"getFillUnitSupportsToolType",index,ToolType.TRIGGER)~=true then return false,"Nádrž nepřijímá materiál z triggeru" end
    return true
end

function FMARefillManager.onStopped(controller,active,message)
    local parent=controller.tasks[active.task.parentTaskId]
    if not parent then return end
    local req=active.task.requirement;local station=active.task.station
    if station and station.manual then
        local ready,status=FMARefillManager.manualMaterialReady(controller,active.vehicle,req)
        if ready then
            FMARefillManager.finishManual(controller,parent,active.vehicle,status)
            return
        end
    end
    if active.stopReason then
        if station and station.manual then
            parent.manualSupplyCursor=active.stopReason=='PLAYER_TAKEOVER' and #(station.waitPoints or {})+1 or (station.waitIndex or 1)+1
            local remaining=#(station.waitPoints or {})-parent.manualSupplyCursor+1
            if remaining>0 then
                parent.state='pending';parent.phase='DOPLNĚNÍ · JINÝ PŘÍJEZD';parent.retryAt=controller.now+1500
                parent.reason='AI odmítla čekací místo u '..tostring(station.name)..'; zkouší další bod (zbývá '..tostring(remaining)..')'
                FMADiagnostics.event(controller,'refill.reroute',parent.id,'waitPoint='..tostring(parent.manualSupplyCursor))
                return
            end
        end
        if station and station.manual and station.sourceIndex and station.sources
                and station.sourceIndex < #station.sources then
            -- One silo's parking approaches have failed; do not repeat the same
            -- blocked path forever when a second valid filling source exists.
            parent.manualSupplySourceCursor=station.sourceIndex+1
            parent.manualSupplyCursor=1
            parent.state='pending';parent.phase='DOPLNĚNÍ · JINÝ ZDROJ'
            parent.reason='První plnicí místo je neprůjezdné. Zkouší '..tostring(station.sources[station.sourceIndex+1].name)
            parent.retryAt=controller.now+1500
            FMADiagnostics.event(controller,'refill.nextSource',parent.id,'index='..tostring(parent.manualSupplySourceCursor))
            return
        end
        if station and station.manual then
            -- After exhausting route entry points, keep the real equipment and
            -- material dependency open. Player may bring it to the public source.
            controller.refillSessions=controller.refillSessions or {}
            controller.refillSessions[parent.id]={manual=true,parent=parent,vehicle=active.vehicle,
                requirement=req,station=station,started=controller.now,lastLevel=req.level,needsDriver=true}
            controller.reservations[active.vehicle.key]='manualRefill:'..parent.id
            active.vehicle.busy=true
            parent.state='waiting';parent.phase='RUČNÍ PŘISTAVENÍ KE ZDROJI'
            parent.reason='Automatické objížďky k '..tostring(station.name)..' nevyšly. Přistav soupravu ručně a nalož '..FMAWorld.fillName(req.fillType)..'; doplnění se samo rozpozná.'
            controller:issue('manualRefill:'..parent.id,'Přistav k '..tostring(station.name),parent.reason,93)
            return
        end
        parent.state="blocked";parent.reason=active.stopReason;return
    end
    local x,z=FMAUtil.position(active.vehicle.object)
    if not x or ((x-station.x)^2+(z-station.z)^2)>(controller.settings.refillArrivalTolerance or 10)^2 then
        parent.state="blocked";parent.reason="Souprava nedojela k plnicímu místu";controller:issue(parent.id,parent.label,parent.reason,90);return
    end
    if station.manual then
        controller.refillSessions=controller.refillSessions or {}
        controller.refillSessions[parent.id]={manual=true,parent=parent,vehicle=active.vehicle,
            requirement=req,station=station,started=controller.now,lastLevel=req.level}
        controller.reservations[active.vehicle.key]='manualRefill:'..parent.id;active.vehicle.busy=true
        parent.state='waiting';parent.phase='ČEKÁ NA RUČNÍ NALOŽENÍ'
        parent.reason='Souprava čeká u '..tostring(station.name)..'. Nalož '..FMAWorld.fillName(req.fillType)..' ručně; potom AUTO samo naváže.'
        controller:issue('manualRefill:'..parent.id,'Nalož '..FMAWorld.fillName(req.fillType),parent.reason,92)
        controller:notify(active.vehicle.name..' čeká na ruční naložení '..FMAWorld.fillName(req.fillType))
        return
    end
    local trigger=station.trigger
    local allowed,why=FMARefillManager.canLoad(trigger,req.object,req.fillUnitIndex,req.fillType,controller.farmId)
    if not allowed then FMAJobs.fail(controller,parent,active.vehicle,why);return end
    local ok,err=pcall(trigger.setIsLoading,trigger,true,req.object,req.fillUnitIndex,req.fillType)
    if not ok then parent.state="blocked";parent.reason="Plnění nelze spustit: "..tostring(err);return end
    controller.refillSessions=controller.refillSessions or {}
    controller.refillSessions[parent.id]={parent=parent,vehicle=active.vehicle,trigger=trigger,requirement=req,started=controller.now,lastLevel=req.level}
    controller.reservations[active.vehicle.key]=active.task.id;active.vehicle.busy=true
    parent.state="assembling";parent.phase="DOPLNĚNÍ MATERIÁLU";parent.reason="Probíhá plnění "..FMAWorld.fillName(req.fillType)
    controller:notify(active.vehicle.name.." se plní: "..FMAWorld.fillName(req.fillType))
end

function FMARefillManager.update(controller)
    if not controller.settings.enabled then return end
    controller.refillSessions=controller.refillSessions or {}
    for id,s in pairs(controller.refillSessions) do
        local req=s.requirement
        if s.manual then
            local ready,status=FMARefillManager.manualMaterialReady(controller,s.vehicle,req)
            if ready then
                FMARefillManager.finishManual(controller,s.parent,s.vehicle,status)
            else
                -- A changing ratio is observed, not guessed from the arrival event.
                if status and s.parent then
                    s.parent.reason='Čeká na '..FMAWorld.fillName(req.fillType)..' · skutečně v nádrži '..
                        math.floor(status.level)..'/'..math.floor(status.capacity)..' l ('..
                        math.floor(status.ratio*100)..' %). Po doplnění naváže na práci.'
                end
            end
        else
            local level=FMAUtil.call(req.object,'getFillUnitFillLevel',req.fillUnitIndex) or 0
            local ratio=req.capacity>0 and level/req.capacity or 1
            local timedOut=(controller.now-s.started)>(controller.settings.refillTimeoutSeconds or 180)*1000
            local stopped=s.trigger.isLoading==false and level<=s.lastLevel+0.1
            if ratio>=req.targetRatio or timedOut or stopped then
                if s.trigger and s.trigger.isLoading and s.trigger.setIsLoading then
                    pcall(s.trigger.setIsLoading,s.trigger,false,req.object,req.fillUnitIndex,req.fillType)
                end
                controller.reservations[s.vehicle.key]=nil;s.vehicle.busy=false
                if controller.traffic then FMATraffic.release(controller.traffic,s.vehicle.key) end
                if ratio>=req.targetRatio then
                    s.parent.state='pending';s.parent.phase='SOUPRAVA PŘIPRAVENA'
                    s.parent.reason=nil;s.parent.retryAt=0;s.parent.failures=0
                    controller:notify(s.vehicle.name..' doplněn na '..math.floor(ratio*100)..' % · pokračuje v úkolu')
                    controller.elapsed=controller.settings.scanSeconds*1000
                else
                    s.parent.state='blocked';s.parent.phase='BLOKACE'
                    s.parent.reason=timedOut and 'Plnění překročilo časový limit' or 'Plnicí místo přestalo vydávat materiál'
                    controller:issue(s.parent.id,s.parent.label,s.parent.reason,95)
                end
                controller.refillSessions[id]=nil
            else s.lastLevel=level end
        end
    end
    -- A driver may manually fill while the AI arrival job is still active,
    -- or re-enter after the loading session was lost on a transient save reload.
    for _,parent in pairs(controller.tasks or {}) do
        local key=parent.manualRefillVehicleKey
        local req=parent.manualRefillRequirement
        if key and req and parent.state~='done' then
            local vehicle=controller.vehicleByKey and controller.vehicleByKey[key]
            if vehicle then
                local ready,status=FMARefillManager.manualMaterialReady(controller,vehicle,req)
                if ready then
                    local activeJob,activeRefill
                    for job,a in pairs(controller.active or {}) do
                        if a.task and a.task.kind=='refill' and a.task.parentTaskId==parent.id then
                            activeJob,activeRefill=job,a;break
                        end
                    end
                    if activeJob then
                        if activeRefill.stopReason~='MANUAL_MATERIAL_READY' then
                            activeRefill.stopReason='MANUAL_MATERIAL_READY'
                            if FMAAI and FMAAI.stop then pcall(FMAAI.stop,activeJob) end
                        end
                    else
                        FMARefillManager.finishManual(controller,parent,vehicle,status)
                    end
                end
            end
        end
    end
end

function FMARefillManager.cancelAll(controller)
    for id,s in pairs(controller.refillSessions or {}) do
        if s.trigger and s.trigger.isLoading and s.trigger.setIsLoading then pcall(s.trigger.setIsLoading,s.trigger,false,s.requirement.object,s.requirement.fillUnitIndex,s.requirement.fillType) end
        controller.reservations[s.vehicle.key]=nil;s.vehicle.busy=false
            if controller.traffic then FMATraffic.release(controller.traffic,s.vehicle.key) end
        if s.parent then s.parent.state="paused";s.parent.reason="Pozastaveno majitelem během plnění" end
        controller.refillSessions[id]=nil
    end
end
