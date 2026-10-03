FMAWorld = {}

function FMAWorld.farmId()
    local player = FMAUtil.call(g_currentMission.playerSystem,"getLocalPlayer") or g_localPlayer or g_currentMission.player
    return player and player.farmId or nil
end

function FMAWorld.money(farmId)
    local farm = FMAUtil.call(g_farmManager,"getFarmById",farmId)
    return farm and (FMAUtil.call(farm,"getMoney") or farm.money) or nil
end

-- Return the physical child objects that currently belong to a vehicle tree.  FS25
-- uses two different mechanisms here: ordinary AttacherJoints and DynamicMountAttacher
-- (header on a cutter trailer, tension-belt style carriers, etc.).  Treating only
-- getAttachedImplements() as the tree made a parked combine + header trailer look like
-- a bare combine even though Courseplay could see the cutter on the trailer.
function FMAWorld.directChildren(object)
    local out,seen={},{}
    local function looksLikeVehicle(candidate)
        if type(candidate)~="table" then return false end
        if candidate.rootNode or candidate.uniqueId or candidate.configFileName or candidate.ownerFarmId~=nil or candidate.farmId~=nil or type(candidate.getOwnerFarmId)=="function" or candidate.spec_attachable or candidate.spec_cutter or candidate.spec_trailer or candidate.spec_motorized then return true end
        for key,value in pairs(candidate) do if type(key)=="string" and key:sub(1,5)=="spec_" and type(value)=="table" then return true end end
        return type(candidate.getRootVehicle)=="function" or type(candidate.getAttachedImplements)=="function"
    end
    local function add(candidate)
        if type(candidate)~="table" or candidate==object or seen[candidate] then return end
        -- A dynamicMountedObjects table is commonly keyed by the mounted vehicle itself,
        -- while some mods expose records containing object/vehicle. Accept both forms.
        candidate=candidate.object or candidate.vehicle or candidate
        if not looksLikeVehicle(candidate) or candidate==object or seen[candidate] then return end
        seen[candidate]=true;out[#out+1]=candidate
    end
    for _,entry in pairs(FMAUtil.call(object,"getAttachedImplements") or {}) do add(entry) end
    local spec=object and object.spec_dynamicMountAttacher
    for key,value in pairs(spec and spec.dynamicMountedObjects or {}) do
        add(key);add(value)
    end
    -- A few carrier mods keep mounted objects in alternative collections. They are
    -- optional; only accept actual vehicle-like tables and deduplicate above.
    for _,value in pairs(object and object.dynamicMountedObjects or {}) do add(value) end
    return out
end

function FMAWorld.children(root)
    local out,seen={},{}
    local function walk(v)
        if not v or seen[v] then return end
        seen[v]=true;out[#out+1]=v
        for _,child in ipairs(FMAWorld.directChildren(v)) do walk(child) end
    end
    walk(root)
    return out
end

-- The physical inventory also contains dynamic cargo (for example a cutter placed
-- on a header trailer). Cargo is NOT an operational implement merely because it is
-- riding on a machine. Only GIANTS' actual mechanical attachment tree contributes
-- work capabilities to a running vehicle.
function FMAWorld.operationalChildren(root)
    local out,seen={},{}
    local function visit(object)
        if not object or seen[object] then return end
        seen[object]=true;out[#out+1]=object
        for _,link in pairs(FMAUtil.call(object,'getAttachedImplements') or {}) do
            local child=link and (link.object or link.vehicle or link)
            if child and child~=object then visit(child) end
        end
    end
    visit(root)
    return out
end

function FMAWorld.containsObject(root,target)
    if not root or not target then return false end
    for _,object in ipairs(FMAWorld.children(root)) do if object==target then return true end end
    return false
end

function FMAWorld.courseplayHeaderTransportState(root)
    if not root or not AIUtil then return false end
    local onCarrier=false
    if type(AIUtil.hasCutterOnTrailerAttached)=="function" then
        local ok,value=pcall(AIUtil.hasCutterOnTrailerAttached,root);onCarrier=ok and value==true or false
    end
    if not onCarrier and type(AIUtil.hasCutterAsTrailerAttached)=="function" then
        local ok,value=pcall(AIUtil.hasCutterAsTrailerAttached,root);onCarrier=ok and value==true or false
    end
    return onCarrier
end

function FMAWorld.vehicleKey(v)
    return tostring(FMAUtil.call(v,"getUniqueId") or v.uniqueId or ((v.configFileName or "vehicle")..":"..tostring(v.savegameId or v.rootNode)))
end

-- Resolve the CURRENT runtime object for a saved/stable vehicle key. FS25 vehicle
-- reset/reload can delete the old Lua object and create a new one while preserving
-- getUniqueId(). Any long-lived Manager session must therefore rebind through the
-- VehicleSystem mapping instead of trusting a stale object reference.
function FMAWorld.resolveVehicle(key)
    if key==nil then return nil end
    local system=g_currentMission and g_currentMission.vehicleSystem
    local map=system and system.vehicleByUniqueId
    local object=map and map[tostring(key)] or nil
    if object and not object.isDeleted then return object end
    local vehicles=FMAUtil.call(system,"getVehicles") or (system and system.vehicles) or (g_currentMission and g_currentMission.vehicles) or {}
    for _,candidate in pairs(vehicles or {}) do
        if candidate and not candidate.isDeleted and FMAWorld.vehicleKey(candidate)==tostring(key) then return candidate end
    end
    return nil
end

function FMAWorld.refreshRecordObject(record)
    if not record or not record.key then return false,false end
    local live=FMAWorld.resolveVehicle(record.key)
    if not live then return false,false end
    local changed=record.object~=live
    record.object=live
    record.name=FMAUtil.name(live) or record.name
    local x,z=FMAUtil.position(live);record.x=x or record.x;record.z=z or record.z
    return true,changed
end

function FMAWorld.fillName(index)
    local ft=FMAUtil.call(g_fillTypeManager,"getFillTypeByIndex",index)
    return ft and (ft.title or ft.name) or tostring(index)
end

-- Classify self-propelled machines by the game's own store categories first.
-- This is deliberately separate from capability scanning: a telehandler may have
-- enough power and a compatible hitch, but it is not a normal field tractor and
-- must not be auto-selected for lime/fertilizer/tillage just because it can attach.
function FMAWorld.machineClass(root)
    if FMAGameNative and FMAGameNative.machineClass then
        local cls=FMAGameNative.machineClass(root)
        return cls or "unknown"
    end
    return "unknown"
end

FMAWorld.TRACTOR_FIELD_OPERATIONS={sow=true,fertilize=true,lime=true,weed=true,roll=true,plow=true,cultivate=true,stone=true,mow=true,ted=true,windrow=true,bale=true}
function FMAWorld.requiresFieldTractor(operation)
    return FMAWorld.TRACTOR_FIELD_OPERATIONS[tostring(operation or "")]==true
end
function FMAWorld.isAutoFieldPowerAllowed(record,operation)
    if not FMAWorld.requiresFieldTractor(operation) then return true end
    if FMAGameNative and FMAGameNative.fieldPowerAllowed then
        return FMAGameNative.fieldPowerAllowed(record,operation)==true
    end
    return record and record.machineClass=="tractor"
end

-- Capability profile of a detached implement or an attached child.  This is deliberately
-- based on specializations/fill types instead of store names, so ModHub machinery can be
-- discovered without a hand-maintained model list.
function FMAWorld.toolProfile(root)
    local native=FMAGameNative and FMAGameNative.storeIdentity and FMAGameNative.storeIdentity(root) or {categories={}}
    local p={object=root,key=FMAWorld.vehicleKey(root),name=(native.name~="" and native.name or FMAUtil.name(root)),storeCategory=native.primaryCategory,storeCategories=native.categories,storeSource=native.source,capabilities={},harvestFruits={},transportFillTypes={},children=FMAWorld.children(root),workWidth=0,
        isCarrier=root.spec_dynamicMountAttacher~=nil or root.spec_tensionBelts~=nil,
        damage=FMAUtil.call(root,"getDamageAmount") or 0,wear=FMAUtil.call(root,"getWearTotalAmount") or 0,
        mass=FMAUtil.call(root,"getTotalMass") or 0,requiredPowerKW=0}
    if FMAModHubAdapter then FMAModHubAdapter.decorateProfile(p,root) end
    local x,z=FMAUtil.position(root);p.x=x;p.z=z
    -- A detached implement's operation is defined by its OWN specializations.
    -- Its dynamically mounted cargo/child devices are physical inventory, not
    -- capabilities of the carrier.  The previous recursive scan made an N60-35
    -- cutter trailer claim HARVEST and an AW 22.17 transport chassis FERTILIZE.
    -- A complete tractor/harvester combination is aggregated separately in vehicles().
    for _,tool in ipairs({root}) do
        local c=p.capabilities
        local ww=FMAUtil.call(tool,"getAIWorkAreaWidth") or 0
        p.workWidth=math.max(p.workWidth or 0,ww or 0)
        local powerConsumer=tool.spec_powerConsumer
        local needed=powerConsumer and (powerConsumer.neededMinPtoPower or powerConsumer.neededMaxPtoPower) or 0
        if type(needed)=="number" and needed>0 then p.requiredPowerKW=(p.requiredPowerKW or 0)+needed end
        if tool.spec_plow then c.plow=true end
        if tool.spec_cultivator then c.cultivate=true end
        if tool.spec_mower then c.mow=true end
        if tool.spec_weeder then c.weed=true end
        if tool.spec_roller then c.roll=true end
        if tool.spec_stonePicker then c.stone=true end
        if tool.spec_sowingMachine then c.sow=true;p.seeder=tool end
        if tool.spec_tedder then c.ted=true end
        if tool.spec_windrower then c.windrow=true end
        if tool.spec_baler then c.bale=true end
        if tool.spec_baleWrapper then c.baleWrap=true end
        if tool.spec_baleLoader then c.baleCollect=true end
        if tool.spec_mixerWagon then c.mixFeed=true end
        if tool.spec_strawBlower then c.strawBed=true;c.transport=true end
        if tool.spec_shovel then c.loadBulk=true end
        if tool.spec_leveler then c.compact=true;c.pushSilo=true end
        if tool.spec_bunkerSiloCompacter then c.compact=true;c.compactSilo=true end
        if tool.spec_forageWagon then c.forageTransport=true;c.foragePickup=true;c.transport=true end
        if tool.spec_pickup and not tool.spec_baler and not tool.spec_baleLoader then c.foragePickup=true;p.isPickupHeader=tool.spec_cutter~=nil or p.hasCutter==true end
        if tool.spec_cutter then
            c.harvest=true;p.hasCutter=true
            for _,i in pairs(tool.spec_cutter.fruitTypeIndices or {}) do p.harvestFruits[i]=true end
            for i,yes in pairs(tool.spec_cutter.fruitTypes or {}) do if yes then p.harvestFruits[i]=true end end
        end
        if tool.spec_combine then p.hasCombine=true end
        local units=FMAUtil.call(tool,"getFillUnits") or (tool.spec_fillUnit and tool.spec_fillUnit.fillUnits) or {}
        for i,unit in pairs(units) do
            local ft=FMAUtil.call(tool,"getFillUnitFillType",i)
            local level=FMAUtil.call(tool,"getFillUnitFillLevel",i) or 0
            local capacity=FMAUtil.call(tool,"getFillUnitCapacity",i) or 0
            if ((tool.spec_trailer and tool.spec_dischargeable) or (FMAModHubAdapter and FMAModHubAdapter.isAttachableTransport(tool))) and FMAModHubAdapter.cargoUnit(tool,i) then
                c.transport=true;p.capacity=(p.capacity or 0)+capacity
                for fill,yes in pairs(unit.supportedFillTypes or {}) do if yes and (level<0.1 or fill==ft) then p.transportFillTypes[fill]=true end end
            end
            if tool.spec_sprayer and unit.supportedFillTypes then
                for fill,yes in pairs(unit.supportedFillTypes) do
                    if yes and FMAUtil.isFertilizerFillType(fill) then c.fertilize=true end
                    if yes and FMAUtil.isLimeFillType(fill) then c.lime=true end
                end
            end
        end
    end
    return p
end

function FMAWorld.vehicles(farmId)
    local roots,out,loose={}, {}, {}
    local system=g_currentMission.vehicleSystem
    local vehicles=FMAUtil.call(system,"getVehicles") or (system and system.vehicles) or g_currentMission.vehicles or {}
    -- Build a live parent map before classifying loose implements. A cutter dynamically
    -- mounted on a header trailer is still part of the combine's physical tree and must
    -- not simultaneously appear as a loose implement.
    local physicalChild={}
    for _,carrier in pairs(vehicles) do
        if FMAUtil.owner(carrier)==farmId then
            for _,child in ipairs(FMAWorld.directChildren(carrier)) do physicalChild[child]=carrier end
        end
    end
    for _,obj in pairs(vehicles) do
        if FMAUtil.owner(obj)==farmId then
            local root=FMAUtil.call(obj,"getRootVehicle") or obj
            if not roots[root] and FMAUtil.owner(root)==farmId then
                roots[root]=true
                if root.spec_motorized ~= nil and root.spec_enterable ~= nil then
                    local x,z=FMAUtil.position(root)
                    local native=FMAGameNative and FMAGameNative.storeIdentity and FMAGameNative.storeIdentity(root) or {categories={}}
                    local class,classSource=FMAWorld.machineClass(root),nil
                    if FMAGameNative and FMAGameNative.machineClass then class,classSource=FMAGameNative.machineClass(root) end
                    local v={object=root,key=FMAWorld.vehicleKey(root),name=(native.name~="" and native.name or FMAUtil.name(root)),x=x,z=z,
                        busy=FMAUtil.call(root,"getIsAIActive")==true or (FMAGameNative and FMAGameNative.isManuallyControlled(root))==true,
                        capabilities={},harvestFruits={},transportFillTypes={},children=FMAWorld.children(root),workChildren=FMAWorld.operationalChildren(root),
                        lowFuel=false,readyOperations={},fillTotal=0,capacity=0,harvesterCapacity=0,roles={},
                        damage=FMAUtil.call(root,"getDamageAmount") or 0,wear=FMAUtil.call(root,"getWearTotalAmount") or 0,
                        repairPrice=FMAUtil.call(root,"getRepairPrice") or 0,hasAttacherJoints=root.spec_attacherJoints~=nil,workWidth=0,
                        fuelLevel=0,fuelCapacity=0,fuelRatio=nil,isGrainCombine=false,isForageHarvester=false,isPowerUnit=false,
                        mass=FMAUtil.call(root,"getTotalMass") or 0,powerKW=0,powerHP=0,requiredPowerKW=0,
                        vehicleTypeName=root.typeName or root.vehicleType or root.typeDesc or '',machineClass=class or 'unknown',machineClassSource=classSource or 'fallback',storeCategory=native.primaryCategory,storeCategories=native.categories,storeSource=native.source}
                    if FMAModHubAdapter then FMAModHubAdapter.decorateProfile(v,root) end
                    local motor=FMAUtil.call(root,"getMotor") or (root.spec_motorized and root.spec_motorized.motor)
                    local power=motor and (motor.peakMotorPower or motor.maxMotorPower) or 0
                    if type(power)=="number" then v.powerKW=power;v.powerHP=power*1.359621617 end
                    local c=v.capabilities
                    for _,tool in ipairs(v.workChildren) do
                        local ww=FMAUtil.call(tool,"getAIWorkAreaWidth") or 0
                        v.workWidth=math.max(v.workWidth or 0,ww or 0)
                        local powerConsumer=tool.spec_powerConsumer
                        local needed=powerConsumer and (powerConsumer.neededMinPtoPower or powerConsumer.neededMaxPtoPower) or 0
                        if type(needed)=="number" and needed>0 then v.requiredPowerKW=(v.requiredPowerKW or 0)+needed end
                        if tool.spec_weight then v.hasBallast=true;v.roles.ballast=true end
                        if tool.spec_leveler then v.hasFrontBlade=true end
                        if tool.spec_plow then c.plow=true end
                        if tool.spec_cultivator then c.cultivate=true end
                        if tool.spec_mower then c.mow=true end
                        if tool.spec_weeder then c.weed=true end
                        if tool.spec_roller then c.roll=true end
                        if tool.spec_stonePicker then c.stone=true end
                        if tool.spec_sowingMachine then
                            c.sow=true
                            local spec=tool.spec_sowingMachine
                            local idx=FMAUtil.call(tool,"getSowingMachineSeedFruitType") or (spec.seeds and spec.seeds[spec.currentSeed])
                            local fruit=FMAUtil.call(g_fruitTypeManager,"getFruitTypeByIndex",idx)
                            v.sowingFruit=fruit and fruit.name
                            v.seeder=tool
                            v.directPlanting=spec.useDirectPlanting==true
                        end
                        if tool.spec_cutter then
                            for _,i in pairs(tool.spec_cutter.fruitTypeIndices or {}) do v.harvestFruits[i]=true end
                            for i,yes in pairs(tool.spec_cutter.fruitTypes or {}) do if yes then v.harvestFruits[i]=true end end
                            v.hasCutter=true
                        end
                        if tool.spec_combine then
                            v.hasCombine=true;v.roles.harvester=true
                            local combineFillIndex=tool.spec_combine.fillUnitIndex
                            local combineCapacity=combineFillIndex and FMAUtil.call(tool,"getFillUnitCapacity",combineFillIndex) or nil
                            if combineCapacity==math.huge then v.isForageHarvester=true;v.roles.forageHarvester=true
                            else v.isGrainCombine=true;v.roles.combine=true end
                        end
                        if tool.spec_tedder then c.ted=true;v.roles.tedder=true end
                        if tool.spec_windrower then c.windrow=true;v.roles.windrower=true end
                        if tool.spec_baler then c.bale=true;v.roles.baler=true end
                        if tool.spec_baleWrapper then c.baleWrap=true;v.roles.baleWrapper=true end
                        if tool.spec_baleLoader then c.baleCollect=true;v.roles.baleCollector=true end
                        if tool.spec_mixerWagon then c.mixFeed=true;v.roles.feedMixer=true end
                        if tool.spec_strawBlower then c.strawBed=true;c.transport=true;v.roles.strawBedding=true end
                        if tool.spec_shovel then c.loadBulk=true;v.roles.loader=true end
                        if tool.spec_leveler then c.compact=true;c.pushSilo=true;v.roles.pusher=true end
                        if tool.spec_bunkerSiloCompacter then c.compact=true;c.compactSilo=true;v.roles.compactor=true end
                        if tool.spec_forageWagon then c.forageTransport=true;c.foragePickup=true;v.roles.foragePickup=true end
                        if tool.spec_pickup and not tool.spec_baler and not tool.spec_baleLoader then c.foragePickup=true;v.roles.foragePickup=true end
                        local units=FMAUtil.call(tool,"getFillUnits") or (tool.spec_fillUnit and tool.spec_fillUnit.fillUnits) or {}
                        for i,unit in pairs(units) do
                            local level=FMAUtil.call(tool,"getFillUnitFillLevel",i) or 0
                            local capacity=FMAUtil.call(tool,"getFillUnitCapacity",i) or 0
                            local ft=FMAUtil.call(tool,"getFillUnitFillType",i)
                            v.fillTotal=v.fillTotal+level
                            if ((tool.spec_trailer and tool.spec_dischargeable) or (FMAModHubAdapter and FMAModHubAdapter.isAttachableTransport(tool))) and FMAModHubAdapter.cargoUnit(tool,i) then
                                c.transport=true;v.roles.transporter=true; v.capacity=v.capacity+capacity
                                for fill,yes in pairs(unit.supportedFillTypes or {}) do
                                    if yes and (level<0.1 or fill==ft) then v.transportFillTypes[fill]=true end
                                end
                            end
                            if tool.spec_combine and capacity>0 then v.harvesterCapacity=v.harvesterCapacity+capacity end
                            if FillType and unit.supportedFillTypes and unit.supportedFillTypes[FillType.DIESEL] and capacity>0 then
                                v.fuelLevel=v.fuelLevel+level;v.fuelCapacity=v.fuelCapacity+capacity
                                if level/capacity<0.12 then v.lowFuel=true end
                            end
                            if tool.spec_sprayer and unit.supportedFillTypes then
                                for fill,yes in pairs(unit.supportedFillTypes) do
                                    if yes and FMAUtil.isFertilizerFillType(fill) then c.fertilize=true end
                                    if yes and FMAUtil.isLimeFillType(fill) then c.lime=true end
                                end
                                if FMAUtil.isFertilizerFillType(ft) then v.readyOperations.fertilize=level>0 end
                                if FMAUtil.isLimeFillType(ft) then v.readyOperations.lime=level>0 end
                            end
                        end
                    end
                    -- Courseplay explicitly supports a cutter riding on an attached header
                    -- trailer. Because dynamic-mounted objects are now included in children(),
                    -- this complete parked chain is a serviceable harvest machine rather than
                    -- a bare combine that gets rejected by the planner.
                    v.headerOnCarrier=FMAWorld.courseplayHeaderTransportState(root)
                    if v.headerOnCarrier and not v.hasCutter then
                        -- Courseplay explicitly reports that the combine is towing a
                        -- header-carrier arrangement. The cutter can be retrieved by
                        -- CP's attach-header workflow; this is NOT inherited by other
                        -- dynamic cargo or ordinary transport vehicles.
                        for _,cargo in ipairs(v.children) do
                            if cargo.spec_cutter then
                                v.hasCutter=true
                                v.headerTransportPending=true
                                for _,i in pairs(cargo.spec_cutter.fruitTypeIndices or {}) do v.harvestFruits[i]=true end
                                for i,yes in pairs(cargo.spec_cutter.fruitTypes or {}) do if yes then v.harvestFruits[i]=true end end
                            end
                        end
                    end
                    c.harvest=v.hasCombine and v.hasCutter or false
                    v.isPowerUnit=v.hasAttacherJoints and not v.hasCombine
                    if v.fuelCapacity>0 then v.fuelRatio=v.fuelLevel/v.fuelCapacity end
                    if c.sow then c.cultivate=nil;c.fertilize=nil;c.lime=nil;c.roll=nil end
                    if c.harvest or c.mow then c.cultivate=nil;c.plow=nil end
                    if c.fertilize and v.readyOperations.fertilize==nil then v.readyOperations.fertilize=false end
                    if c.lime and v.readyOperations.lime==nil then v.readyOperations.lime=false end
                    out[#out+1]=v
                elseif root.spec_attachable ~= nil then
                    -- A physically attached or dynamically mounted object belongs to another
                    -- root tree. Do not offer it simultaneously as loose yard equipment.
                    local mounted=physicalChild[root] or FMAUtil.call(root,"getDynamicMountObject") or root.tensionMountObject or FMAUtil.call(root,"getAttacherVehicle")
                    if mounted==nil then
                        local record=FMAWorld.toolProfile(root)
                        record.ownerFarmId=farmId
                        loose[#loose+1]=record
                    end
                end
            end
        end
    end
    -- A wide cutter can be physically sitting on a header carrier.  It is still
    -- owned working equipment and must not disappear from inventory just because
    -- dynamic-mount/tension-belt transport is active.
    local looseKeys={}
    for _,tool in ipairs(loose) do looseKeys[tool.key]=true end
    for _,obj in pairs(vehicles) do
        if FMAUtil.owner(obj)==farmId and obj.spec_attachable~=nil and obj.spec_cutter~=nil then
            local key=FMAWorld.vehicleKey(obj)
            local attacher=FMAUtil.call(obj,"getAttacherVehicle")
            local mounted=FMAUtil.call(obj,"getDynamicMountObject") or obj.tensionMountObject
            local attachedToHarvester=attacher and attacher.spec_combine~=nil
            -- A cutter riding on an UNATTACHED carrier is available for retrieval,
            -- but must carry its real mounted location and carrier identity.
            -- A cutter on a carrier attached to an operating machine belongs to
            -- that machine and must not be double-booked as yard inventory.
            local ancestor=physicalChild[obj]
            local inMachine=false
            local visited={}
            while ancestor and not visited[ancestor] do
                visited[ancestor]=true
                if ancestor.spec_motorized or ancestor.spec_combine then inMachine=true;break end
                local attachedParent=FMAUtil.call(ancestor,'getAttacherVehicle')
                if attachedParent and (attachedParent.spec_motorized or attachedParent.spec_combine) then inMachine=true;break end
                ancestor=physicalChild[ancestor] or attachedParent
            end
            if not inMachine and not attachedToHarvester and not looseKeys[key] then
                local record=FMAWorld.toolProfile(obj)
                record.ownerFarmId=farmId
                record.transported=mounted~=nil or (physicalChild[obj]~=nil)
                record.mountedCarrier=mounted or physicalChild[obj]
                loose[#loose+1]=record;looseKeys[key]=true
            end
        end
    end
    table.sort(out,function(a,b) return a.key<b.key end)
    table.sort(loose,function(a,b) return a.key<b.key end)
    return out,loose
end

function FMAWorld.normalizeField(field,liveState)
    local state=liveState or (FMAGameNative and FMAGameNative.fieldState and FMAGameNative.fieldState(field)) or FMAUtil.call(field,"getFieldState") or field.fieldState
    local id=FMAUtil.call(field,"getId") or field.fieldId or field.id
    local x,z=field.posX,field.posZ
    local f={object=field,id=tostring(id or "?"),name="Pole "..tostring(id or "?"),x=x,z=z,valid=false}
    if not state or state.isValid~=true or x==nil or z==nil then return f end
    f.name=FMAUtil.call(field,"getName") or f.name
    f.valid=true
    local fruit=FMAUtil.call(g_fruitTypeManager,"getFruitTypeByIndex",state.fruitTypeIndex)
    local growth=state.growthState or 0
    local gt=state.groundType
    local function ground(name) return FieldGroundType and FieldGroundType[name]~=nil and gt==FieldGroundType[name] end
    local cleared=ground("CULTIVATED") or ground("PLOWED") or ground("SEEDBED")
    local sown=ground("SOWN") or ground("SOWN2") or ground("PLANTED")
    -- A cached fruit layer may outlive cultivation/plowing. Ground data proves
    -- the previous crop was removed; never harvest that cached fruit again.
    if cleared then fruit=nil end
    local unknownFruit=FruitType and FruitType.UNKNOWN or 0
    if not cleared and not fruit and state.fruitTypeIndex~=nil and state.fruitTypeIndex~=unknownFruit and state.fruitTypeIndex~=0 then
        f.valid=false;return f
    end
    f.fruitIndex=state.fruitTypeIndex
    f.fruit=fruit and fruit.name
    f.grass=f.fruit=="GRASS" or (FMACarpathianProfile and FMACarpathianProfile.isForageCrop and FMACarpathianProfile.isForageCrop(f.fruit)) or field.grassMissionOnly==true
    local cut=fruit and (FMAUtil.call(fruit,"getIsCut",growth)==true or (fruit.cutState~=nil and growth==fruit.cutState))
    local withered=fruit and (FMAUtil.call(fruit,"getIsWithered",growth)==true or (fruit.witheredState~=nil and growth==fruit.witheredState))
    f.ready=fruit and FMAUtil.call(fruit,"getIsHarvestable",growth)==true or false
    if fruit and fruit.minHarvestingGrowthState and fruit.minHarvestingGrowthState>0 and fruit.maxHarvestingGrowthState then
        f.ready=growth>=fruit.minHarvestingGrowthState and growth<=fruit.maxHarvestingGrowthState
    end
    f.ready=f.ready and not cut and not withered and not cleared
    f.bare=cleared or (not sown and (fruit==nil or cut or withered or growth==0))
    f.alive=sown or (not f.bare and not f.ready)
    if sown then f.ready=false end
    f.prepared=ground("CULTIVATED") or ground("PLOWED") or ground("SEEDBED")
    -- Never infer 'bare' for a living plant from ground type alone.
    local groundSystem=g_currentMission.fieldGroundSystem
    local maxPlow=FieldDensityMap and FMAUtil.call(groundSystem,"getMaxValue",FieldDensityMap.PLOW_LEVEL)
    local maxLime=FieldDensityMap and FieldDensityMap.LIME_LEVEL and FMAUtil.call(groundSystem,"getMaxValue",FieldDensityMap.LIME_LEVEL)
    local maxSpray=FieldDensityMap and FieldDensityMap.SPRAY_LEVEL and FMAUtil.call(groundSystem,"getMaxValue",FieldDensityMap.SPRAY_LEVEL)
    f.needsPlow=g_currentMission.missionInfo.plowingRequiredEnabled~=false and maxPlow~=nil and state.plowLevel~=nil and state.plowLevel<maxPlow
    f.needsLime=g_currentMission.missionInfo.limeRequired~=false and maxLime~=nil and state.limeLevel~=nil and state.limeLevel==0
    f.needsFertilize=f.alive and maxSpray~=nil and state.sprayLevel~=nil and state.sprayLevel==0
    f.needsWeed=g_currentMission.missionInfo.weedsEnabled~=false and (state.weedState or 0)>0 and (state.weedState or 0)<=2
    f.needsRoll=state.rollerLevel==0 and (ground("SOWN") or ground("SOWN2"))
    f.needsStone=g_currentMission.missionInfo.stonesEnabled~=false and (state.stoneLevel or 0)>0
    if FMACarpathianProfile then FMACarpathianProfile.applyFieldRules(f) end
    f.growthState=growth;f.groundType=gt
    f.groundTypeName=tostring(gt)
    if FieldGroundType then
        for name,value in pairs(FieldGroundType) do if type(value)~="function" and ground(name) then f.groundTypeName=name;break end end
    end
    f.stateLabel=f.ready and ((f.fruit or "Plodina").." · zralé") or f.alive and ((f.fruit or "Porost").." · roste") or f.prepared and "Zoraná / připravená půda" or "Sklizeno / holá půda"
    f.minSpray=state.sprayLevel;f.minLime=state.limeLevel;f.minPlow=state.plowLevel;f.minRoll=state.rollerLevel
    f.fingerprint=table.concat({tostring(f.fruitIndex),growth,tostring(gt),tostring(state.plowLevel),tostring(state.limeLevel),tostring(state.sprayLevel),tostring(state.weedState),tostring(state.stoneLevel),tostring(state.rollerLevel)},"/")
    return f
end

function FMAWorld.fields(farmId)
    local out={}
    for _,field in pairs(FMAUtil.call(g_fieldManager,"getFields") or (g_fieldManager and g_fieldManager.fields) or {}) do
        local farmland=field.farmland or FMAUtil.call(field,"getFarmland")
        if not farmland and field.posX and field.posZ then farmland=FMAUtil.call(g_farmlandManager,"getFarmlandAtWorldPosition",field.posX,field.posZ) end
        local owner=farmland and FMAUtil.owner(farmland)
        if owner==nil and farmland then owner=FMAUtil.call(g_farmlandManager,"getFarmlandOwner",farmland.id) end
        if owner==farmId then out[#out+1]=FMAWorld.sampleField(field) end
    end
    table.sort(out,function(a,b) return (tonumber(a.id) or math.huge)<(tonumber(b.id) or math.huge) end)
    return out
end

function FMAWorld.raining()
    if FMAGameNative and FMAGameNative.weather then return FMAGameNative.weather().raining==true end
    return false
end

function FMAWorld.conditionRows(farmId)
    local rows={}
    local system=g_currentMission.placeableSystem
    for _,p in pairs((FMAGameNative and FMAGameNative.placeables and FMAGameNative.placeables()) or (system and system.placeables) or {}) do
        if FMAUtil.owner(p)==farmId and p.spec_husbandry then
            local name=FMAUtil.name(p)
            local total=FMAUtil.call(p,"getTotalFood")
            local cap=FMAUtil.call(p,"getFoodCapacity")
            if total and cap and cap>0 then
                rows[#rows+1]={id="food:"..tostring(p),name=name.." · krmivo",value=total,capacity=cap,ratio=total/cap,
                    message="Doplnit krmivo; míchání a nakládání vyžaduje obsluhu",priority=100}
            end
            for i,info in ipairs(FMAUtil.call(p,"getConditionInfos") or {}) do
                if info.ratio~=nil and not info.disabled then
                    rows[#rows+1]={id="animal:"..tostring(p)..":"..i,name=name.." · "..tostring(info.title),
                        value=info.value or 0,ratio=info.invertedBar and 1-info.ratio or info.ratio,
                        message=info.invertedBar and "Odvézt výstup / uvolnit kapacitu" or "Doplnit zásobu",priority=100}
                end
            end
        end
    end
    local manager=g_currentMission.productionChainManager
    for _,point in pairs((FMAGameNative and FMAGameNative.productionPoints and FMAGameNative.productionPoints(farmId)) or FMAUtil.call(manager,"getProductionPointsForFarmId",farmId) or {}) do
        local storage=point.storage
        local name=FMAUtil.call(point,"getName") or (point.owningPlaceable and FMAUtil.name(point.owningPlaceable)) or "Výroba"
        if storage then
            for ft,level in pairs(FMAUtil.call(storage,"getFillLevels") or {}) do
                local capacity=FMAUtil.call(storage,"getCapacity",ft)
                if capacity and capacity>0 then
                    local input=point.inputFillTypeIds and point.inputFillTypeIds[ft]
                    local output=point.outputFillTypeIds and point.outputFillTypeIds[ft]
                    rows[#rows+1]={id="production:"..tostring(point)..":"..ft,name=name.." · "..FMAWorld.fillName(ft),
                        value=level,capacity=capacity,ratio=output and 1-level/capacity or level/capacity,
                        neutral=not input and not output,message=output and "Uvolnit sklad / odvézt výrobky" or "Doplnit vstup výroby",priority=85}
                end
            end
        end
    end
    return rows
end

function FMAWorld.supplyTasks(farmId, threshold)
    local result={}
    local storageSystem=g_currentMission.storageSystem
    local loads=(FMAGameNative and FMAGameNative.loadingStations and FMAGameNative.loadingStations()) or FMAUtil.call(storageSystem,"getLoadingStations") or {}
    local unloads=(FMAGameNative and FMAGameNative.unloadingStations and FMAGameNative.unloadingStations()) or FMAUtil.call(storageSystem,"getUnloadingStations") or {}
    for _,dest in pairs(unloads) do
        local place=dest.owningPlaceable
        -- Only feed owned husbandries or owned production inputs, never a public sell point or another silo.
        if place and FMAUtil.owner(place)==farmId and (place.spec_husbandry or place.spec_productionPoint) then
            for ft in pairs(FMAUtil.call(dest,"getAISupportedFillTypes") or {}) do
                local free=FMAUtil.call(dest,"getFreeCapacity",ft,farmId)
                local capacity=FMAUtil.call(dest,"getCapacity",ft,farmId)
                local level=FMAUtil.call(dest,"getFillLevel",ft,farmId)
                if not capacity and free and level then capacity=free+level end
                local fillDesc=FMAUtil.call(g_fillTypeManager,"getFillTypeByIndex",ft)
                if free and capacity and capacity>0 and free/capacity>=(1-threshold) and fillDesc and fillDesc.isBulkType then
                    local chosen,bestLevel=nil,0
                    for _,src in pairs(loads) do
                        local sourcePlace=src.owningPlaceable
                        -- Own storage only: no automatic purchases from refill triggers.
                        if sourcePlace and sourcePlace~=place and FMAUtil.owner(sourcePlace)==farmId then
                            local supported=FMAUtil.call(src,"getAISupportedFillTypes") or {}
                            local available=FMAUtil.call(src,"getFillLevel",ft,farmId) or 0
                            if supported[ft] and available>bestLevel then chosen,bestLevel=src,available end
                        end
                    end
                    if chosen and bestLevel>100 then
                        local x,z=FMAUtil.position(place)
                        result[#result+1]={id="supply:"..tostring(dest)..":"..ft,kind="supply",operation="supply",priority=place.spec_husbandry and 100 or 85,
                            label=FMAUtil.name(place).." · "..FMAWorld.fillName(ft),state="pending",attempts=0,
                            source=chosen,destination=dest,fillType=ft,free=free,available=bestLevel,x=x,z=z}
                    end
                end
            end
        end
    end
    return result
end

-- Query live density at several interior points. This is a conservative sample,
-- not a promise that every square metre is finished.
function FMAWorld.sampleField(field)
    local fallback=FMAWorld.normalizeField(field)
    if not FieldState or not FieldState.new then return fallback end
    local samples={};local positions={{x=field.posX,z=field.posZ}}
    local polygon={}
    for _,node in ipairs(field.polygonPoints or {}) do
        if getWorldTranslation then local x,_,z=getWorldTranslation(node);polygon[#polygon+1]={x=x,z=z} end
    end
    local function inside(x,z)
        if #polygon<3 then return false end
        local hit=false;local j=#polygon
        for i=1,#polygon do
            local a,b=polygon[i],polygon[j]
            if (a.z>z)~=(b.z>z) and x<(b.x-a.x)*(z-a.z)/(b.z-a.z)+a.x then hit=not hit end
            j=i
        end
        return hit
    end
    if field.posX and field.posZ and #polygon>0 then
        local stride=math.max(1,math.floor(#polygon/16))
        for i=1,#polygon,stride do
            local x=(polygon[i].x+field.posX)*0.5;local z=(polygon[i].z+field.posZ)*0.5
            if inside(x,z) then positions[#positions+1]={x=x,z=z} end
            if #positions>=17 then break end
        end
    end
    for _,pos in ipairs(positions) do
        local state=FieldState.new()
        if not state or type(state.update)~="function" then return fallback end
        local ok=pos.x and pos.z and pcall(state.update,state,pos.x,pos.z)
        if ok and state.isValid then samples[#samples+1]=FMAWorld.normalizeField(field,state) end
    end
    if #samples==0 then fallback.valid=false;fallback.reason="Živý vzorek pole nebyl dostupný";return fallback end

    local counts={ready=0,growing=0,bare=0,unknown=0,prepared=0};local fruitCounts={}
    local byClass={ready={},growing={},bare={},unknown={}}
    local function class(smp)
        if smp.ready then return "ready" elseif smp.alive then return "growing" elseif smp.bare then return "bare" end
        return "unknown"
    end
    for _,smp in ipairs(samples) do
        local k=class(smp);counts[k]=counts[k]+1;byClass[k][#byClass[k]+1]=smp
        if smp.prepared then counts.prepared=counts.prepared+1 end
        if smp.fruit and k~="bare" then fruitCounts[smp.fruit]=(fruitCounts[smp.fruit] or 0)+1 end
    end
    local dominant="unknown";for _,k in ipairs({"ready","growing","bare"}) do if counts[k]>counts[dominant] then dominant=k end end
    local threshold=math.max(2,math.ceil(#samples*0.60))
    local center=samples[1]
    -- The field centre is the same live density source the base field state is built
    -- from.  Never let harvest-looking edge samples override an authoritative
    -- growing or prepared centre (the exact false-harvest regression from field 6).
    if dominant=="ready" and center and (center.alive or center.prepared or center.bare) and not center.ready then
        local f=center;f.sampleCount=#samples;f.sampleSource="liveDensity";f.mixed=true
        f.ready=false;f.valid=false;f.readyCoverage=counts.ready/#samples;f.aliveCoverage=counts.growing/#samples;f.bareCoverage=counts.bare/#samples;f.preparedCoverage=counts.prepared/#samples
        f.reason="Střed pole není připraven ke sklizni; okrajové vzorky byly odmítnuty"
        f.stateLabel=center.alive and ((center.fruit or "Porost").." · roste") or "Půda / nedokončený stav · bez sklizně"
        return f
    end
    local representative=byClass[dominant][1] or samples[1]
    local f=representative
    f.sampleCount=#samples;f.sampleSource="liveDensity"
    f.readyCoverage=counts.ready/#samples;f.aliveCoverage=counts.growing/#samples;f.bareCoverage=counts.bare/#samples;f.preparedCoverage=counts.prepared/#samples
    f.mixed=(counts[dominant]<#samples)
    f.primaryGrowthState=representative.growthState;f.primaryPrepared=representative.prepared
    if counts[dominant]<threshold then
        f.valid=false;f.ready=false;f.alive=false;f.bare=false
        f.reason="Nejistý stav pole · vzorky se neshodují (sklizeň "..counts.ready.." / roste "..counts.growing.." / půda "..counts.bare..")"
        f.stateLabel="NEJISTÝ STAV · bez automatického zásahu"
        return f
    end
    if dominant=="bare" and (counts.ready>0 or counts.growing>0) then
        f.valid=false;f.ready=false;f.alive=false;f.bare=false
        f.reason="Pole není dokončeno · část porostu ještě zůstává"
        f.stateLabel="SMÍŠENÝ STAV · bez automatického zásahu"
        return f
    end
    -- Harvest is deliberately fail-closed: meaningful bare/prepared coverage means
    -- the field is partly worked/harvested and must be checked instead of sending a combine blindly.
    if dominant=="ready" and (f.bareCoverage>=0.25 or f.preparedCoverage>=0.25) then
        f.valid=false;f.ready=false;f.reason="Pole je jen částečně ke sklizni / část už je zpracovaná"
        f.stateLabel="SMÍŠENÝ STAV · sklizeň pozastavena"
        return f
    end
    f.ready=dominant=="ready";f.alive=dominant=="growing";f.bare=dominant=="bare"
    if f.ready then f.stateLabel=(f.fruit or "Plodina").." · připraveno ke sklizni"
    elseif f.alive then f.stateLabel=(f.fruit or "Porost").." · roste"
    elseif f.prepared then f.stateLabel="Zoraná / připravená půda" else f.stateLabel="Sklizeno / holá půda" end
    return f
end

