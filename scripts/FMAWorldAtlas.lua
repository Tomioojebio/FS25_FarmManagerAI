-- Runtime map atlas for EVERY FS25 map (Carpathian Countryside included).
-- This is a read-only inventory of real engine objects and their capabilities,
-- NOT a fabricated road network. A trigger/root position is never proof that
-- a particular tractor+implement can physically drive to it.
FMAWorldAtlas={VERSION='0.20.18.0',MAX_PLACEABLES=3000,MAX_STATIONS=1000}
local Atlas=FMAWorldAtlas

local function identityValue(value)
    value=tostring(value or '')
    return value~='' and value or nil
end
function Atlas.identity(mission)
    mission=mission or g_currentMission
    local info=mission and mission.missionInfo or {}
    local id=identityValue(info.mapId) or identityValue(info.mapXMLFilename) or identityValue(info.mapTitle)
    return id or 'MAP_UNIDENTIFIED'
end
local function position(object)
    if not object then return nil,nil end
    local x,z=FMAUtil.position(object)
    if x~=nil and z~=nil and x==x and z==z and math.abs(x)<100000 and math.abs(z)<100000 then return x,z end
    return nil,nil
end
local function getStations(storage,name)
    local rows=FMAUtil.call(storage,name)
    return type(rows)=='table' and rows or {}
end
local function eachStation(stations,callback)
    local count=0
    for key,value in pairs(stations) do
        if count>=Atlas.MAX_STATIONS then break end
        local station=(type(value)=='table' or type(value)=='userdata') and value or
            ((type(key)=='table' or type(key)=='userdata') and key or nil)
        if station then count=count+1;callback(station) end
    end
    return count
end
-- The actual AI load/unload goal is NOT the root node of the placeable:
-- GIANTS AIJobLoadAndDeliver requests getAITargetPositionAndDirection(ft)
-- and uses the position only when that call returns a non-nil trigger.
-- Root fallback is displayed for diagnostics ONLY, never declared an AI goal.
function Atlas.stationTarget(station,fillType)
    if station==nil or fillType==nil or type(station.getAITargetPositionAndDirection)~='function' then return nil end
    local ok,x,z,dx,dz,trigger=pcall(station.getAITargetPositionAndDirection,station,fillType)
    if not ok or trigger==nil or type(x)~='number' or type(z)~='number' then return nil end
    if x~=x or z~=z or math.abs(x)>=100000 or math.abs(z)>=100000 then return nil end
    if type(dx)~='number' or type(dz)~='number' or dx~=dx or dz~=dz then return nil end
    return {x=x,z=z,dirX=dx,dirZ=dz,fillType=fillType,hasTrigger=true,
        physicallyVerified=false,pointSource='AI_TARGET'}
end
local function stationInfo(station,farmId,kind,access)
    local ownerObject=station.owningPlaceable
    local x,z=position(station)
    local location='STATION'
    if x==nil then x,z=position(ownerObject);location='PLACEABLE_ROOT' end
    local supported=FMAUtil.call(station,'getAISupportedFillTypes')
    local types={};local n=0
    local targets={};local preferred=nil
    if type(supported)=='table' then
        for ft,allowed in pairs(supported) do
            local number=tonumber(ft)
            if number and allowed then
                n=n+1;types[number]=true
                if #targets<64 then
                    local target=Atlas.stationTarget(station,number)
                    if target then targets[#targets+1]=target;preferred=preferred or target end
                end
            end
        end
    end
    if preferred then x,z=preferred.x,preferred.z;location='AI_TARGET' end
    if x==nil then return nil end
    local allowed=nil
    if access and type(access.canFarmAccess)=='function' then
        local ok,val=pcall(access.canFarmAccess,access,farmId,station)
        if ok then allowed=val==true end
    end
    local owner=ownerObject and FMAUtil.owner(ownerObject) or nil
    return {object=station,owner=owner,x=x,z=z,kind=kind,
        id=tostring(kind)..':'..tostring(station),name=FMAUtil.call(station,'getName') or FMAUtil.name(ownerObject or station),
        pointSource=location,routeVerified=false,access=allowed,types=types,fillTypeCount=n,
        aiTargets=targets,aiTargetCount=#targets,aiTargetVerified=false,
        owned=owner==farmId,public=owner==nil or owner==0}
end
local function placeableKind(p)
    if p.spec_husbandry then return 'husbandry' end
    if p.spec_bunkerSilo then return 'bunker' end
    if p.spec_productionPoint then return 'production' end
    if p.spec_workshop or p.spec_vehicleWorkshop then return 'workshop' end
    if p.spec_silo or p.spec_objectStorage then return 'storage' end
    return 'other'
end
function Atlas.scan(c)
    local m=g_currentMission
    if not m then return nil,'MISSION_NOT_READY' end
    local farmId=c and c.farmId
    if farmId==nil then return nil,'FARM_NOT_READY' end
    local storage=m.storageSystem
    local access=m.accessHandler
    local atlas={identity=Atlas.identity(m),title=(m.missionInfo and m.missionInfo.mapTitle) or 'Neznámá mapa',
        scannedAt=c.now or 0,fields={},allFields={},totalMapFields=0,farmlands={owned=0,total=0},vehicles=0,
        ownedPlaceables=0,placeables=0,kinds={},husbandries={},bunkers={},storages={},productions={},workshops={},
        loadingStations={},unloadingStations={},allLoading={},allUnloading={},
        fieldCount=0,fieldOwnershipKnown=false,stationCount=0,validAccessPoints=0,
        roadSystem={mapAvailable=false,source='GIANTS_AI_COSTMAP',splinesKnown=false},
        bounded=false}
    for _,field in ipairs(c.fields or {}) do
        if field.id then
            atlas.fields[#atlas.fields+1]={id=field.id,name=field.name,x=field.x,z=field.z,valid=field.valid~=false}
        end
    end
    atlas.fieldCount=#atlas.fields
    -- Scan the WHOLE map's field registry (including fields not yet owned).
    -- Only c.fields represent the owned, live state sampled for scheduling.
    local engineFields=FMAUtil.call(g_fieldManager,'getFields') or (g_fieldManager and g_fieldManager.fields) or {}
    for _,f in pairs(engineFields) do
        if atlas.totalMapFields>=2000 then atlas.bounded=true;break end
        if f then
            atlas.totalMapFields=atlas.totalMapFields+1
            local farmland=f.farmland or FMAUtil.call(f,'getFarmland')
            if farmland==nil and f.posX and f.posZ then
                farmland=FMAUtil.call(g_farmlandManager,'getFarmlandAtWorldPosition',f.posX,f.posZ)
            end
            -- Some map integrations expose the farmland id directly, others
            -- provide the object. Neither form should crash the map scanner.
            local landId=(type(farmland)=='table' and farmland.id) or (type(farmland)=='number' and farmland) or nil
            local owner=landId and FMAUtil.call(g_farmlandManager,'getFarmlandOwner',landId) or nil
            atlas.allFields[#atlas.allFields+1]={id=f.fieldId or f.id or atlas.totalMapFields,
                x=f.posX,z=f.posZ,owner=owner,farmlandId=landId}
        end
    end
    local farmlands=FMAUtil.call(g_farmlandManager,'getFarmlands') or (g_farmlandManager and g_farmlandManager.farmlands) or {}
    for id,_ in pairs(farmlands) do
        atlas.farmlands.total=atlas.farmlands.total+1
        local owner=FMAUtil.call(g_farmlandManager,'getFarmlandOwner',id)
        if owner==farmId then atlas.farmlands.owned=atlas.farmlands.owned+1 end
    end
    atlas.fieldOwnershipKnown=(g_farmlandManager~=nil and atlas.farmlands.total>0)
    for _ in pairs(c.vehicles or {}) do atlas.vehicles=atlas.vehicles+1 end
    local ps=m.placeableSystem
    for _,p in pairs(ps and ps.placeables or {}) do
        if atlas.placeables>=Atlas.MAX_PLACEABLES then atlas.bounded=true;break end
        if p and not p.isDeleted then
            atlas.placeables=atlas.placeables+1
            if FMAUtil.owner(p)==farmId then
                atlas.ownedPlaceables=atlas.ownedPlaceables+1
                local row={object=p,name=FMAUtil.name(p),key=FMAGameNative and FMAGameNative.placeableKey and FMAGameNative.placeableKey(p)}
                local kind=placeableKind(p)
                atlas.kinds[kind]=(atlas.kinds[kind] or 0)+1
                if p.spec_husbandry then atlas.husbandries[#atlas.husbandries+1]=row end
                if p.spec_bunkerSilo then atlas.bunkers[#atlas.bunkers+1]=row end
                if p.spec_silo or p.spec_objectStorage then atlas.storages[#atlas.storages+1]=row end
                if p.spec_productionPoint then atlas.productions[#atlas.productions+1]=row end
                if p.spec_workshop or p.spec_vehicleWorkshop then atlas.workshops[#atlas.workshops+1]=row end
            end
        end
    end
    local function collect(name,kind,all,owned)
        local count=eachStation(getStations(storage,name),function(station)
            local row=stationInfo(station,farmId,kind,access)
            if row then
                all[#all+1]=row;atlas.stationCount=atlas.stationCount+1
                if row.owned and row.fillTypeCount>0 and row.access~=false then owned[#owned+1]=row end
                if row.access~=false and row.pointSource=='AI_TARGET' and row.fillTypeCount>0 then
                    atlas.validAccessPoints=atlas.validAccessPoints+1
                end
            end
        end)
        if count==Atlas.MAX_STATIONS then atlas.bounded=true end
    end
    collect('getLoadingStations','LOAD',atlas.allLoading,atlas.loadingStations)
    collect('getUnloadingStations','UNLOAD',atlas.allUnloading,atlas.unloadingStations)
    local ai=m.aiSystem
    local nav=FMAUtil.call(ai,'getNavigationMap') or (ai and ai.navigationMap)
    atlas.roadSystem.mapAvailable=nav~=nil
    atlas.roadSystem.costmapFilename=FMAUtil.call(ai,'getNavigationMapFilename') or (ai and ai.filename)
    atlas.roadSystem.splinesKnown=ai and (ai.roadSplines~=nil or ai.delayedRoadSplines~=nil) or false
    -- Navigation map presence is NOT an assertion that any specific route is driveable.
    return atlas
end
function Atlas.writeDiagnostics(c,file)
    local a=c and c.worldAtlas or nil
    if not a or not file then return end
    file:write('\nLIVE WORLD ATLAS\nmap=',tostring(a.identity),' title=',tostring(a.title),
        ' ownFields=',tostring(a.fieldCount),' allFields=',tostring(a.totalMapFields),' farmlands=',tostring(a.farmlands.owned),'/',tostring(a.farmlands.total),
        ' vehicles=',tostring(a.vehicles),' placeables=',tostring(a.placeables),' own=',tostring(a.ownedPlaceables),
        ' stations=',tostring(a.stationCount),' accessibleTriggers=',tostring(a.validAccessPoints),
        ' navCostmap=',tostring(a.roadSystem.mapAvailable),' boundsReached=',tostring(a.bounded),'\n')
    for _,field in ipairs(a.allFields or {}) do
        file:write('MAP_FIELD ',tostring(field.id),' farmland=',tostring(field.farmlandId),
            ' owner=',tostring(field.owner),' x=',tostring(field.x),' z=',tostring(field.z),'\n')
    end
    for _,row in ipairs(a.allLoading or {}) do
        file:write('LOAD ',tostring(row.name),' x=',tostring(row.x),' z=',tostring(row.z),' source=',tostring(row.pointSource),
            ' types=',tostring(row.fillTypeCount),' actualAiTargets=',tostring(row.aiTargetCount),' access=',tostring(row.access),' owned=',tostring(row.owned),'\n')
    end
    for _,row in ipairs(a.allUnloading or {}) do
        file:write('UNLOAD ',tostring(row.name),' x=',tostring(row.x),' z=',tostring(row.z),' source=',tostring(row.pointSource),
            ' types=',tostring(row.fillTypeCount),' actualAiTargets=',tostring(row.aiTargetCount),' access=',tostring(row.access),' owned=',tostring(row.owned),'\n')
    end
end
