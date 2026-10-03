-- Real, engine-confirmed cargo destinations for an autonomous cooperative.
-- An arbitrary nearby silo is not a valid unloading point: the fill type,
-- access rights, known free capacity and physical job completion are separate.
FMALogistics = {}

function FMALogistics.stationOwner(station)
    return station and station.owningPlaceable and FMAUtil.owner(station.owningPlaceable) or nil
end

function FMALogistics.isOrganicFertilizer(fillType)
    if fillType==nil then return false end
    if FillType and (fillType==FillType.MANURE or (FillType.LIQUIDMANURE and fillType==FillType.LIQUIDMANURE) or (FillType.SLURRY and fillType==FillType.SLURRY) or fillType==FillType.DIGESTATE) then return true end
    local desc=FMAUtil.call(g_fillTypeManager,'getFillTypeByIndex',fillType)
    return desc~=nil and string.upper(tostring(desc.name or ''))=='COMPOST'
end

function FMALogistics.supports(station,fillType)
    local types=FMAUtil.call(station,'getAISupportedFillTypes')
    return type(types)=='table' and types[fillType]~=nil and types[fillType]~=false
end

local function accessible(station,farmId)
    local handler=g_currentMission and g_currentMission.accessHandler
    if handler and type(handler.canFarmAccess)=='function' then
        local ok,result=pcall(handler.canFarmAccess,handler,farmId,station)
        if ok and result==false then return false end
    end
    return true -- inaccessible is a definite block; unknown is NOT proof of access.
end
local function stationXY(station,fillType)
    if not station then return nil,nil end
    local goal=FMAWorldAtlas and FMAWorldAtlas.stationTarget and FMAWorldAtlas.stationTarget(station,fillType)
    if goal then return goal.x,goal.z end
    local x,z=FMAUtil.position(station)
    if x==nil then x,z=FMAUtil.position(station.owningPlaceable) end
    return x,z
end
local function distance(a,b,fillType)
    local ax,az=stationXY(a,fillType);local bx,bz=stationXY(b,fillType)
    if ax==nil or bx==nil then return math.huge end
    return math.sqrt((ax-bx)^2+(az-bz)^2)
end
-- Prefer the owner's compatible destination; within that category prefer a
-- station with confirmed space and a shorter physical journey. Selling stations
-- are a separate explicitly-authorized fallback, not a silent default.
function FMALogistics.bestDestination(farmId,source,fillType,allowSale)
    local storage=g_currentMission and g_currentMission.storageSystem
    if not storage then return nil,false end
    local own,public={},{}
    for key,value in pairs(FMAUtil.call(storage,'getUnloadingStations') or {}) do
        local dst=type(value)=='table' and value or (type(key)=='table' and key or nil)
        if dst and dst~=source and FMALogistics.supports(dst,fillType) and accessible(dst,farmId) then
            local owner=FMALogistics.stationOwner(dst)
            local free=FMAUtil.call(dst,'getFreeCapacity',fillType,farmId)
            if free==nil or free>100 then
                local aiTarget=FMAWorldAtlas and FMAWorldAtlas.stationTarget and FMAWorldAtlas.stationTarget(dst,fillType)
                local row={object=dst,dist=distance(source,dst,fillType),aiTarget=aiTarget~=nil,knownSpace=type(free)=='number',free=free or 0}
                if owner==farmId then own[#own+1]=row
                elseif allowSale and dst.isSellingPoint==true then
                    row.price=FMAUtil.call(dst,'getEffectiveFillTypePrice',fillType) or 0
                    public[#public+1]=row
                end
            end
        end
    end
    table.sort(own,function(a,b)
        -- Actual AI trigger first. This is not proof of route clearance;
        -- the AI job still has to physically arrive and unload.
        if a.aiTarget~=b.aiTarget then return a.aiTarget end
        if a.knownSpace~=b.knownSpace then return a.knownSpace end
        if a.dist~=b.dist then return a.dist<b.dist end
        return tostring(a.object)<tostring(b.object)
    end)
    if #own>0 then return own[1].object,false end
    table.sort(public,function(a,b)
        if a.aiTarget~=b.aiTarget then return a.aiTarget end
        if a.price~=b.price then return a.price>b.price end
        if a.dist~=b.dist then return a.dist<b.dist end
        return tostring(a.object)<tostring(b.object)
    end)
    if #public>0 then return public[1].object,true end
    return nil,false
end

-- Ordered FALLBACKS for grain haulage. Reject stations without a real GIANTS
-- unloading target and never silently select a selling point without approval.
-- Returning several options lets a stopped helper try another silo after a
-- concrete failed AI delivery instead of repeating one broken entrance.
function FMALogistics.destinationOptions(farmId,source,fillType,allowSale)
    local storage=g_currentMission and g_currentMission.storageSystem
    if not storage or fillType==nil then return {} end
    local own,public={},{}
    for key,value in pairs(FMAUtil.call(storage,'getUnloadingStations') or {}) do
        local station=type(value)=='table' and value or (type(key)=='table' and key or nil)
        if station and station~=source and FMALogistics.supports(station,fillType) and accessible(station,farmId) then
            local target=FMAWorldAtlas and FMAWorldAtlas.stationTarget and FMAWorldAtlas.stationTarget(station,fillType)
            local free=FMAUtil.call(station,'getFreeCapacity',fillType,farmId)
            if target and target.x and target.z and (free==nil or free>100) then
                local row={object=station,dist=distance(source,station,fillType),knownSpace=type(free)=='number',free=free or 0}
                local owner=FMALogistics.stationOwner(station)
                if owner==farmId then own[#own+1]=row
                elseif allowSale and station.isSellingPoint==true then
                    row.price=FMAUtil.call(station,'getEffectiveFillTypePrice',fillType) or 0
                    public[#public+1]=row
                end
            end
        end
    end
    table.sort(own,function(a,b)
        if a.knownSpace~=b.knownSpace then return a.knownSpace end
        if a.dist~=b.dist then return a.dist<b.dist end
        return tostring(a.object)<tostring(b.object)
    end)
    table.sort(public,function(a,b)
        if a.price~=b.price then return a.price>b.price end
        if a.dist~=b.dist then return a.dist<b.dist end
        return tostring(a.object)<tostring(b.object)
    end)
    local out={}
    for _,row in ipairs(own) do out[#out+1]=row.object end
    for _,row in ipairs(public) do out[#out+1]=row.object end
    return out
end

function FMALogistics.outputTasks(farmId,settings)
    local result={}
    local storage=g_currentMission and g_currentMission.storageSystem
    if not storage then return result end
    for key,value in pairs(FMAUtil.call(storage,'getLoadingStations') or {}) do
        local src=type(value)=='table' and value or (type(key)=='table' and key or nil)
        local place=src and src.owningPlaceable
        if place and FMAUtil.owner(place)==farmId and (place.spec_husbandry or place.spec_productionPoint) then
            for ft in pairs(FMAUtil.call(src,'getAISupportedFillTypes') or {}) do
                local level=FMAUtil.call(src,'getFillLevel',ft,farmId) or 0
                local cap=FMAUtil.call(src,'getCapacity',ft,farmId)
                if cap and cap>0 and level/cap>=(settings.outputMoveAt or 0.75) then
                    local allowSale=settings.autoSellOutputs==true and not (settings.retainOrganicFertilizer and FMALogistics.isOrganicFertilizer(ft))
                    local dst,isSale=FMALogistics.bestDestination(farmId,src,ft,allowSale)
                    if dst then
                        local x,z=FMAUtil.position(place)
                        result[#result+1]={id='output:'..tostring(src)..':'..ft,kind='supply',operation='supply',priority=place.spec_husbandry and 94 or 82,
                            label=FMAUtil.name(place)..' · odvoz '..FMAWorld.fillName(ft),state='pending',attempts=0,source=src,destination=dst,
                            fillType=ft,available=level,x=x,z=z,allowPublicDestination=isSale,isSale=isSale}
                    end
                end
            end
        end
    end
    return result
end
