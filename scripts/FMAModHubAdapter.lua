-- Dynamic compatibility layer for user-owned ModHub equipment/placeables.
-- The manager never whitelists brands/models.  It classifies what is actually
-- loaded in the savegame from standard FS25 specializations, fill types and
-- attach points.  Custom script specializations are recorded for diagnostics
-- and are treated conservatively instead of being guessed.
FMAModHubAdapter = {}

local function normalizePath(value)
    return string.gsub(tostring(value or ""), "\\", "/")
end

function FMAModHubAdapter.modNameFromPath(value)
    local path=normalizePath(value)
    return string.match(path,"/mods/([^/]+)/") or string.match(path,"^mods/([^/]+)/")
end

function FMAModHubAdapter.origin(object)
    if object==nil then return {kind="unknown",name="unknown"} end
    local store=object.storeItem or object.storeData
    local env=object.customEnvironment or (store and store.customEnvironment)
    if env~=nil and tostring(env)~="" then return {kind="mod",name=tostring(env)} end
    local file=object.configFileName or object.xmlFilename or (store and store.xmlFilename)
    local name=FMAModHubAdapter.modNameFromPath(file)
    if name then return {kind="mod",name=name} end
    return {kind="base",name="baseGame"}
end

function FMAModHubAdapter.specializations(object)
    local rows={}
    for key,spec in pairs(object or {}) do
        if type(key)=="string" and string.sub(key,1,5)=="spec_" and type(spec)=="table" then
            rows[#rows+1]=string.sub(key,6)
        end
    end
    table.sort(rows)
    return rows
end

local standardSpecs={
    attachable=true,attacherJoints=true,baleLoader=true,baleWrapper=true,baler=true,bunkerSiloCompacter=true,
    combine=true,cultivator=true,cutter=true,dischargeable=true,dynamicMountAttacher=true,enterable=true,
    fillUnit=true,forageWagon=true,leveler=true,mixerWagon=true,motorized=true,mower=true,pickup=true,
    plow=true,roller=true,shovel=true,sowingMachine=true,sprayer=true,stonePicker=true,strawBlower=true,
    tedder=true,tensionBelts=true,trailer=true,weeder=true,windrower=true,workArea=true,powerConsumer=true
}

function FMAModHubAdapter.customSpecializations(object)
    local rows={}
    for _,name in ipairs(FMAModHubAdapter.specializations(object)) do
        if not standardSpecs[name] then rows[#rows+1]=name end
    end
    return rows
end

function FMAModHubAdapter.hasAutoloadSpecialization(object)
    for _,name in ipairs(FMAModHubAdapter.specializations(object)) do
        if string.find(string.lower(name),"autoload",1,true) then return true,name end
    end
    return false,nil
end

function FMAModHubAdapter.profileObject(object)
    local origin=FMAModHubAdapter.origin(object)
    local autoload,autoloadSpec=FMAModHubAdapter.hasAutoloadSpecialization(object)
    return {
        originKind=origin.kind,originMod=origin.name,
        customSpecializations=FMAModHubAdapter.customSpecializations(object),
        externalAutoload=autoload,autoloadSpecialization=autoloadSpec
    }
end

function FMAModHubAdapter.decorateProfile(profile,object)
    if profile==nil or object==nil then return profile end
    local meta=FMAModHubAdapter.profileObject(object)
    profile.originKind=meta.originKind
    profile.originMod=meta.originMod
    profile.customSpecializations=meta.customSpecializations
    profile.externalAutoload=meta.externalAutoload
    profile.autoloadSpecialization=meta.autoloadSpecialization
    return profile
end

-- Broad but safe transport test for attachable ModHub tanks/trailers.  Some mods
-- omit the Trailer specialization while still exposing a normal FillUnit +
-- Dischargeable pair.  We accept those only when the object is attachable, so a
-- self-propelled combine/sprayer is not accidentally treated as a haul vehicle.
function FMAModHubAdapter.isAttachableTransport(object)
    return object~=nil and object.spec_attachable~=nil and object.spec_dischargeable~=nil and object.spec_fillUnit~=nil
        and not object.spec_sowingMachine and not object.spec_sprayer and not object.spec_baler and not object.spec_stonePicker
end

function FMAModHubAdapter.scanOwned(controller)
    local snapshot={modObjects=0,baseObjects=0,mods={},customSpecializations={},autoloaders=0}
    local function add(object)
        if object==nil then return end
        local meta=FMAModHubAdapter.profileObject(object)
        if meta.originKind=="mod" then
            snapshot.modObjects=snapshot.modObjects+1
            snapshot.mods[meta.originMod]=(snapshot.mods[meta.originMod] or 0)+1
        else snapshot.baseObjects=snapshot.baseObjects+1 end
        if meta.externalAutoload then snapshot.autoloaders=snapshot.autoloaders+1 end
        for _,name in ipairs(meta.customSpecializations or {}) do
            snapshot.customSpecializations[name]=(snapshot.customSpecializations[name] or 0)+1
        end
    end
    local seen={}
    for _,v in ipairs(controller.vehicles or {}) do
        for _,object in ipairs(v.children or {}) do if not seen[object] then seen[object]=true;add(object) end end
    end
    for _,tool in ipairs(controller.loose or {}) do if tool.object and not seen[tool.object] then seen[tool.object]=true;add(tool.object) end end
    return snapshot
end

function FMAModHubAdapter.describe(snapshot)
    snapshot=snapshot or {}
    local n=0;for _ in pairs(snapshot.mods or {}) do n=n+1 end
    return string.format("modované objekty %d · zdrojové mody %d · autoloadery %d",snapshot.modObjects or 0,n,snapshot.autoloaders or 0)
end

function FMAModHubAdapter.cargoUnit(object,index)
    local spec=object and object.spec_dischargeable
    for _,node in ipairs(spec and spec.dischargeNodes or {}) do
        if node.fillUnitIndex==index then return true end
    end
    return false
end
