-- Map-specific operating profile for Carpathian Countryside.
-- The user's target farm is intentionally optimized for this map instead of guessing
-- universal names/coordinates.  Fixed map facts are used only for policy; actual
-- positions, triggers, husbandries, silos and any later user-placed objects are always
-- discovered from the running savegame, so adding bunker silos or on-farm buying silos
-- does not invalidate the profile.
FMACarpathianProfile = {}

FMACarpathianProfile.MOD_NAME = "FS25_CarpathianCountryside_crossplay"
FMACarpathianProfile.CURRENT_MODHUB_VERSION = "1.1.0.0"
FMACarpathianProfile.ROLLING_REQUIRED = {
    WHEAT=true, BARLEY=true, CANOLA=true, OAT=true, SOYBEAN=true, RYE=true
}
FMACarpathianProfile.FORAGE_CROPS = {ALFALFA=true}
FMACarpathianProfile.EXTRA_CROPS = {
    {name="ALFALFA", label="Vojtěška"},
    {name="RYE", label="Žito"},
    {name="MUSTARD", label="Hořčice"}
}

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function hasCarpathianToken(value)
    local s=lower(value)
    return s:find("carpathiancountryside",1,true)~=nil or s:find("carpathian countryside",1,true)~=nil
end

function FMACarpathianProfile.detect()
    local info=g_currentMission and g_currentMission.missionInfo or nil
    local loaded=g_modIsLoaded and g_modIsLoaded[FMACarpathianProfile.MOD_NAME]==true or false
    local probes={
        info and info.mapId,
        info and info.mapTitle,
        info and info.mapXMLFilename,
        info and info.baseDirectory,
        g_currentMission and g_currentMission.customEnvironment
    }
    local active=false
    for _,value in ipairs(probes) do
        if value~=nil and (hasCarpathianToken(value) or lower(value):find(lower(FMACarpathianProfile.MOD_NAME),1,true)~=nil) then
            active=true
            break
        end
    end
    -- mapXMLFilename/baseDirectory are the authoritative probes.  The fallback below
    -- is only for engine builds where they are not exposed to scripts.
    if not active and loaded and info and hasCarpathianToken(info.mapTitle) then active=true end

    local modItem=nil
    if g_modManager and type(g_modManager.getModByName)=="function" then
        local ok,value=pcall(g_modManager.getModByName,g_modManager,FMACarpathianProfile.MOD_NAME)
        if ok then modItem=value end
    end
    return {
        active=active,
        loaded=loaded,
        mapId=info and info.mapId or nil,
        mapTitle=info and info.mapTitle or nil,
        mapXMLFilename=info and info.mapXMLFilename or nil,
        baseDirectory=info and info.baseDirectory or nil,
        version=modItem and (modItem.version or modItem.modVersion) or nil,
        title=modItem and modItem.title or nil
    }
end

local function appendCrop(name,label)
    if not FMACatalog or not FMAUtil.fruit(name) then return false end
    for _,existing in ipairs(FMACatalog.crops or {}) do if existing==name then return true end end
    FMACatalog.crops[#FMACatalog.crops+1]=name
    FMACatalog.cropLabels[name]=label
    return true
end

function FMACarpathianProfile.installCatalog()
    local installed={}
    for _,crop in ipairs(FMACarpathianProfile.EXTRA_CROPS) do
        if appendCrop(crop.name,crop.label) then installed[#installed+1]=crop.name end
    end
    return installed
end

function FMACarpathianProfile.isForageCrop(name)
    return FMACarpathianProfile.FORAGE_CROPS[string.upper(tostring(name or ""))]==true
end

function FMACarpathianProfile.runtimeFillTypes()
    local rows={}
    for _,spray in pairs(FMAUtil.call(g_sprayTypeManager,"getSprayTypes") or {}) do
        local ft=spray.fillType and (spray.fillType.index or spray.fillType) or nil
        if ft then rows[#rows+1]={fillType=ft,name=FMAWorld and FMAWorld.fillName(ft) or tostring(ft),fertilizer=spray.isFertilizer==true,lime=spray.isLime==true} end
    end
    return rows
end

function FMACarpathianProfile.applyFieldRules(field)
    if not field or not field.fruit then return field end
    -- Carpathian Countryside explicitly disables rolling requirement for all crops
    -- except this whitelist.  Trust the actual field state for whether a whitelisted
    -- crop still needs the pass, but never invent rolling for the other map crops.
    if FMACarpathianProfile.ROLLING_REQUIRED[field.fruit]~=true then field.needsRoll=false end
    return field
end

local function placeableKind(p)
    if p.spec_husbandry then return "husbandry" end
    if p.spec_bunkerSilo then return "bunker" end
    if p.spec_objectStorage then return "objectStorage" end
    if p.spec_silo then return "silo" end
    if p.spec_workshop then return "workshop" end
    if p.spec_productionPoint then return "production" end
    return "other"
end

local function stationHasAI(station)
    local supported=FMAUtil.call(station,"getAISupportedFillTypes") or {}
    for _ in pairs(supported) do return true end
    return false
end

function FMACarpathianProfile.scan(controller)
    local snapshot={active=false,ownedPlaceables=0,kinds={},husbandries={},bunkers={},storages={},productions={},
        ownLoadingStations=0,ownUnloadingStations=0,publicLoadingStations=0,publicUnloadingStations=0,
        aiLoadingStations=0,aiUnloadingStations=0,extraCrops={},loadingStations={},unloadingStations={},sprayFillTypes={},storageInventory={}}
    local detected=FMACarpathianProfile.detect()
    for k,v in pairs(detected) do snapshot[k]=v end
    if not snapshot.active then return snapshot end

    snapshot.extraCrops=FMACarpathianProfile.installCatalog()
    local placeables=g_currentMission and g_currentMission.placeableSystem and g_currentMission.placeableSystem.placeables or {}
    for _,p in pairs(placeables) do
        if FMAUtil.owner(p)==controller.farmId then
            snapshot.ownedPlaceables=snapshot.ownedPlaceables+1
            local kind=placeableKind(p)
            snapshot.kinds[kind]=(snapshot.kinds[kind] or 0)+1
            local row={object=p,name=FMAUtil.name(p)}
            -- A Carpathian placeable can be multifunctional (for example silo + production).
            -- Classify capabilities independently so the dashboard does not hide a production
            -- just because the same building also exposes a silo specialization.
            if p.spec_husbandry then snapshot.husbandries[#snapshot.husbandries+1]=row end
            if p.spec_bunkerSilo then snapshot.bunkers[#snapshot.bunkers+1]=row end
            if p.spec_silo or p.spec_objectStorage then snapshot.storages[#snapshot.storages+1]=row end
            if p.spec_productionPoint then snapshot.productions[#snapshot.productions+1]=row end
        end
    end

    local storageRowByPlace={}
    local function mergeStorageFill(row,fillType,level,capacity,source)
        if not row or fillType==nil or type(level)~="number" then return end
        row.inventoryKnown=true
        row.inventorySource=row.inventorySource or source
        row.fillByType=row.fillByType or {}
        local existing=row.fillByType[fillType]
        if existing then
            -- Direct PlaceableSilo storage is preferred over trigger-derived values.
            if existing.source~="PlaceableSilo" or source=="PlaceableSilo" then
                existing.level=level;existing.capacity=capacity or existing.capacity or 0;existing.source=source
            end
        else
            existing={fillType=fillType,level=level,capacity=capacity or 0,source=source}
            row.fillByType[fillType]=existing
            row.fillRows[#row.fillRows+1]=existing
        end
    end
    for _,row in ipairs(snapshot.storages) do
        storageRowByPlace[row.object]=row;row.fillRows={};row.fillByType={};row.inventoryKnown=false
        local place=row.object
        if place and place.spec_silo then
            local levels=FMAUtil.call(place,"getFillLevels")
            if type(levels)=="table" then
                row.inventoryKnown=true;row.inventorySource="PlaceableSilo"
                for ft,level in pairs(levels) do
                    if type(level)=="number" then
                        local capacity=0
                        for _,store in ipairs(place.spec_silo.storages or {}) do
                            local supported=FMAUtil.call(store,"getIsFillTypeSupported",ft)
                            if supported~=false then capacity=capacity+(FMAUtil.call(store,"getCapacity",ft) or 0) end
                        end
                        mergeStorageFill(row,ft,level,capacity,"PlaceableSilo")
                    end
                end
            end
        end
    end
    local productionSeen={}
    for _,row in ipairs(snapshot.productions) do productionSeen[row.object]=true end
    local productionManager=g_currentMission and g_currentMission.productionChainManager
    for _,point in pairs(FMAUtil.call(productionManager,'getProductionPointsForFarmId',controller.farmId) or {}) do
        local place=point.owningPlaceable
        if place and not productionSeen[place] then
            productionSeen[place]=true
            snapshot.productions[#snapshot.productions+1]={object=place,productionPoint=point,name=FMAUtil.call(point,'getName') or FMAUtil.name(place)}
        end
    end

    local storage=g_currentMission and g_currentMission.storageSystem
    local function stationRow(station,owner)
        local place=station and station.owningPlaceable or nil
        local x,z=FMAUtil.position(place or station)
        local fills={}
        for ft,yes in pairs(FMAUtil.call(station,"getAISupportedFillTypes") or {}) do if yes then fills[#fills+1]=ft end end
        table.sort(fills)
        return {object=station,name=FMAUtil.name(place or station),owner=owner,x=x,z=z,fillTypes=fills,ai=#fills>0}
    end
    for _,station in pairs(FMAUtil.call(storage,"getLoadingStations") or {}) do
        local owner=FMALogistics and FMALogistics.stationOwner(station) or nil
        if owner==controller.farmId then snapshot.ownLoadingStations=snapshot.ownLoadingStations+1
        else snapshot.publicLoadingStations=snapshot.publicLoadingStations+1 end
        local row=stationRow(station,owner);snapshot.loadingStations[#snapshot.loadingStations+1]=row
        if row.ai then snapshot.aiLoadingStations=snapshot.aiLoadingStations+1 end
        if owner==controller.farmId and station.owningPlaceable then
            local storageRow=storageRowByPlace[station.owningPlaceable]
            if storageRow then
                local seenFill={}
                for _,ft in ipairs(row.fillTypes or {}) do
                    if not seenFill[ft] then
                        seenFill[ft]=true
                        local level=FMAUtil.call(station,'getFillLevel',ft,controller.farmId)
                        local cap=FMAUtil.call(station,'getCapacity',ft,controller.farmId)
                        local free=FMAUtil.call(station,'getFreeCapacity',ft,controller.farmId)
                        if level~=nil then
                            if cap==nil and free~=nil then cap=level+free end
                            mergeStorageFill(storageRow,ft,level,cap or 0,"LoadingStation")
                        end
                    end
                end
            end
        end
    end
    for _,station in pairs(FMAUtil.call(storage,"getUnloadingStations") or {}) do
        local owner=FMALogistics and FMALogistics.stationOwner(station) or nil
        if owner==controller.farmId then snapshot.ownUnloadingStations=snapshot.ownUnloadingStations+1
        else snapshot.publicUnloadingStations=snapshot.publicUnloadingStations+1 end
        local row=stationRow(station,owner);snapshot.unloadingStations[#snapshot.unloadingStations+1]=row
        if row.ai then snapshot.aiUnloadingStations=snapshot.aiUnloadingStations+1 end
    end
    snapshot.sprayFillTypes=FMACarpathianProfile.runtimeFillTypes()
    return snapshot
end

function FMACarpathianProfile.requireCourseplay(controller)
    return controller and controller.mapProfile and controller.mapProfile.active==true and controller.settings and controller.settings.preferCourseplay==true
end

function FMACarpathianProfile.describe(snapshot)
    snapshot=snapshot or {}
    if not snapshot.active then return "jiná mapa / profil neaktivní" end
    return string.format("Karpatský venkov · chovy %d · jámy %d · sklady %d · vlastní AI nakládky %d",
        #(snapshot.husbandries or {}),#(snapshot.bunkers or {}),#(snapshot.storages or {}),snapshot.aiLoadingStations or 0)
end
