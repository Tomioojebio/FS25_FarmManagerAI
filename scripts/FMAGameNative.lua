-- Central authority bridge: always prefer data already exposed by FS25/GIANTS.
-- FarmManagerAI may coordinate and add policy, but it must not invent a second game state.
FMAGameNative = {}

local function upper(v) return string.upper(tostring(v or '')) end
local function appendUnique(out,seen,value)
    if value==nil then return end
    local text=tostring(value)
    if text=='' or seen[text] then return end
    seen[text]=true;out[#out+1]=text
end

function FMAGameNative.storeItem(object)
    if not object or not g_storeManager then return nil end
    local xml=object.configFileName or object.xmlFilename
    if not xml then return nil end
    local fn=g_storeManager.getItemByXMLFilename
    if type(fn)~='function' then return nil end
    local ok,item=pcall(fn,g_storeManager,xml)
    return ok and item or nil
end

function FMAGameNative.storeIdentity(object)
    local item=FMAGameNative.storeItem(object)
    local categories,seen={},{}
    if item then
        appendUnique(categories,seen,item.categoryName)
        for _,name in ipairs(item.categoryNames or {}) do appendUnique(categories,seen,name) end
    end
    local name=nil
    if item then
        name=item.name
        if type(name)=='table' then name=name.cz or name.en or next(name) end
    end
    return {
        item=item,
        name=tostring(name or (object and (FMAUtil.call(object,'getName') or object.name)) or ''),
        xml=object and (object.configFileName or object.xmlFilename) or nil,
        categories=categories,
        primaryCategory=categories[1],
        brand=item and (item.brandName or item.brand) or nil,
        source=item and 'FS25_STORE' or 'RUNTIME_FALLBACK'
    }
end

local function categoryContains(identity,needle)
    needle=upper(needle)
    for _,cat in ipairs(identity and identity.categories or {}) do
        local token=upper(cat):gsub('[^A-Z0-9]','')
        if token:find(needle,1,true) then return true end
    end
    return false
end

function FMAGameNative.machineClass(object)
    if not object then return 'unknown','none' end
    local id=FMAGameNative.storeIdentity(object)
    -- Store category is the primary authority. Specs below are only fallback for
    -- mods/items that fail to expose a store entry at runtime.
    if #id.categories>0 then
        if categoryContains(id,'TELEHAND') or categoryContains(id,'TELELOADER') then return 'telehandler','store' end
        if categoryContains(id,'WHEELLOADER') or categoryContains(id,'SKIDSTEER') or categoryContains(id,'FRONTLOADER') then return 'loader','store' end
        if categoryContains(id,'FORAGEHARVEST') then return 'forageHarvester','store' end
        if categoryContains(id,'HARVESTER') or categoryContains(id,'COMBINE') then return 'harvester','store' end
        if categoryContains(id,'SPRAYER') and object.spec_motorized then return 'selfPropelledField','store' end
        if categoryContains(id,'MOWER') and object.spec_motorized then return 'selfPropelledField','store' end
        if categoryContains(id,'TRACTOR') then return 'tractor','store' end
        if categoryContains(id,'TRUCK') then return 'truck','store' end
        if categoryContains(id,'CAR') or categoryContains(id,'PICKUP') or categoryContains(id,'UTV') then return 'roadVehicle','store' end
    end
    if object.spec_combine~=nil then
        local idx=object.spec_combine.fillUnitIndex
        local cap=idx and FMAUtil.call(object,'getFillUnitCapacity',idx)
        if cap==math.huge then return 'forageHarvester','specialization' end
        return 'harvester','specialization'
    end
    if object.spec_motorized and object.spec_enterable and object.spec_sprayer then return 'selfPropelledField','specialization' end
    return 'unknown','runtime'
end

function FMAGameNative.fieldPowerAllowed(record,operation)
    if not record then return false,'missing' end
    if record.capabilities and record.capabilities[operation]==true then
        -- A complete self-propelled working machine is authoritative as assembled.
        return true,'assembledCapability'
    end
    local cls=record.machineClass or 'unknown'
    if cls=='tractor' then return true,'storeCategory' end
    return false,'storeCategory:'..tostring(cls)
end

function FMAGameNative.resolveVehicle(uniqueId)
    if not uniqueId or not g_currentMission or not g_currentMission.vehicleSystem then return nil end
    local system=g_currentMission.vehicleSystem
    if system.vehicleByUniqueId and system.vehicleByUniqueId[uniqueId] then return system.vehicleByUniqueId[uniqueId] end
    for _,v in pairs(FMAUtil.call(system,'getVehicles') or system.vehicles or {}) do
        local id=FMAUtil.call(v,'getUniqueId') or v.uniqueId
        if tostring(id)==tostring(uniqueId) then return v end
    end
    return nil
end

function FMAGameNative.fieldState(field)
    return FMAUtil.call(field,'getFieldState') or field and field.fieldState or nil
end

function FMAGameNative.weather()
    local env=g_currentMission and g_currentMission.environment
    local weather=env and env.weather
    local raining=FMAUtil.call(weather,'getIsRaining')
    if raining==nil then local scale=FMAUtil.call(weather,'getRainFallScale');raining=scale~=nil and scale>0 end
    return {object=weather,raining=raining==true,currentPeriod=env and env.currentPeriod,source='FS25_ENVIRONMENT'}
end

function FMAGameNative.placeableCapabilities(placeable)
    local roles={}
    if not placeable then return roles end
    if placeable.spec_husbandry then roles.husbandry=true end
    if placeable.spec_productionPoint then roles.production=true end
    if placeable.spec_workshop or placeable.spec_vehicleSellingPoint or placeable.spec_vehicleWorkshop then roles.workshop=true end
    if placeable.spec_silo or placeable.spec_siloExtension then roles.storage=true end
    if placeable.spec_bunkerSilo then roles.bunker=true end
    if placeable.spec_objectStorage then roles.objectStorage=true end
    return roles
end

function FMAGameNative.loadingStations()
    local s=g_currentMission and g_currentMission.storageSystem
    return FMAUtil.call(s,'getLoadingStations') or {}
end
function FMAGameNative.unloadingStations()
    local s=g_currentMission and g_currentMission.storageSystem
    return FMAUtil.call(s,'getUnloadingStations') or {}
end
function FMAGameNative.productionPoints(farmId)
    local m=g_currentMission and g_currentMission.productionChainManager
    return FMAUtil.call(m,'getProductionPointsForFarmId',farmId) or {}
end
function FMAGameNative.placeables()
    local p=g_currentMission and g_currentMission.placeableSystem
    return p and p.placeables or {}
end

-- Unified control-state bridge. Being seated in a vehicle is not the same as driving it:
-- FS25 allows the player to remain in the cab while a native or Courseplay worker is active.
-- Every FarmManager subsystem must use this state instead of treating getIsEntered() alone
-- as a manual takeover.
function FMAGameNative.operatorState(object)
    if not object then return {mode='MISSING',entered=false,aiActive=false,cpActive=false,manual=false} end
    local entered=FMAUtil.call(object,'getIsEntered')==true
    local aiActive=FMAUtil.call(object,'getIsAIActive')==true
    local cpActive=false
    if aiActive then
        cpActive=FMAUtil.call(object,'getIsCpActive')==true
            or FMAUtil.call(object,'getIsCpCombineUnloaderActive')==true
            or FMAUtil.call(object,'getIsCpFieldWorkActive')==true
            or FMAUtil.call(object,'getIsCpBunkerSiloActive')==true
            or FMAUtil.call(object,'getIsCpSiloLoaderActive')==true
        if not cpActive and type(object.getCpDriveStrategy)=='function' then
            local ok,strategy=pcall(object.getCpDriveStrategy,object)
            cpActive=ok and strategy~=nil
        end
    end
    -- Detect the actual player's vehicle *independently* of AI state. Some
    -- FS25 helpers continue reporting aiActive during a player handover;
    -- ignoring that fact can steal controls and turn E into a dead key.
    local manual=entered and not aiActive
    local mission=g_currentMission
    if mission and mission.player then
        local controlled=mission.controlledVehicle or mission.currentVehicle
            or mission.player.currentVehicle or mission.player.vehicle
        if type(mission.getControlledVehicle)=='function' then
            local ok,current=pcall(mission.getControlledVehicle,mission)
            if ok and current then controlled=current end
        end
        manual=controlled==object and controlled~=nil
    end
    local mode='IDLE'
    if manual then mode='PLAYER'
    elseif aiActive and cpActive then mode='COURSEPLAY'
    elseif aiActive then mode='FS_AI' end
    return {mode=mode,entered=entered,aiActive=aiActive,cpActive=cpActive,manual=manual,job=FMAUtil.call(object,'getJob')}
end

function FMAGameNative.isManuallyControlled(object)
    return FMAGameNative.operatorState(object).manual==true
end

function FMAGameNative.isAIControlled(object)
    return FMAGameNative.operatorState(object).aiActive==true
end

function FMAGameNative.placeableKey(placeable)
    if not placeable then return nil end
    local id=FMAUtil.call(placeable,'getUniqueId') or placeable.uniqueId or placeable.savegameId or placeable.id
    if id~=nil then return 'placeable:'..tostring(id) end
    local root=placeable.rootNode or placeable.nodeId
    if root~=nil then return 'placeableNode:'..tostring(root) end
    local x,z=FMAUtil.position(placeable)
    local xml=placeable.configFileName or placeable.xmlFilename or 'placeable'
    return tostring(xml)..':'..tostring(math.floor((x or 0)*10))..':'..tostring(math.floor((z or 0)*10))
end

function FMAGameNative.placeableIdentity(placeable)
    local store=FMAGameNative.storeIdentity(placeable)
    local roles=FMAGameNative.placeableCapabilities(placeable)
    local kind='OBJECT'
    if roles.husbandry then kind='HUSBANDRY'
    elseif roles.production then kind='PRODUCTION'
    elseif roles.workshop then kind='WORKSHOP'
    elseif roles.bunker then kind='BUNKER'
    elseif roles.storage then kind='STORAGE'
    elseif roles.objectStorage then kind='OBJECT_STORAGE'
    else
        for _,cat in ipairs(store.categories or {}) do
            local token=upper(cat):gsub('[^A-Z0-9]','')
            if token:find('WEIGH',1,true) or token:find('SCALE',1,true) then kind='WEIGH_STATION';break end
            if token:find('WASH',1,true) then kind='WASH_STATION';break end
        end
    end
    return {kind=kind,roles=roles,storeCategory=store.primaryCategory,storeCategories=store.categories,storeSource=store.source,name=store.name,xml=store.xml}
end
