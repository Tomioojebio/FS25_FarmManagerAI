FMAUtil = {}

function FMAUtil.call(object, name, ...)
    if object == nil or type(object[name]) ~= "function" then return nil end
    local result = {pcall(object[name], object, ...)}
    if not result[1] then
        if FMADiagnostics and FMAJobs and FMAJobs.controller then FMADiagnostics.error(FMAJobs.controller,"api:"..name,result[2]) end
        return nil
    end
    return unpack(result, 2)
end

function FMAUtil.clamp(value, lo, hi)
    return math.max(lo, math.min(hi, tonumber(value) or lo))
end

function FMAUtil.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function FMAUtil.sorted(t, key)
    local out = {}
    for _, v in pairs(t or {}) do out[#out + 1] = v end
    table.sort(out, function(a,b) return tostring(a[key]) < tostring(b[key]) end)
    return out
end

function FMAUtil.name(object)
    return tostring(FMAUtil.call(object, "getName") or object.name or object.configFileName or "Neznámý objekt")
end

function FMAUtil.position(object)
    if object == nil then return nil end
    if object.posX ~= nil and object.posZ ~= nil then return object.posX, object.posZ end
    if object.rootNode ~= nil and object.rootNode ~= 0 and getWorldTranslation ~= nil then
        local ok, x, _, z = pcall(getWorldTranslation, object.rootNode)
        if ok then return x,z end
    end
    return nil
end

function FMAUtil.owner(object)
    if object==nil then return nil end
    return FMAUtil.call(object, "getOwnerFarmId") or object.ownerFarmId or object.farmId
end

function FMAUtil.distance(a, b)
    if a.x == nil or b.x == nil then return math.huge end
    return math.sqrt((a.x-b.x)^2 + (a.z-b.z)^2)
end

function FMAUtil.fruit(name)
    return FMAUtil.call(g_fruitTypeManager, "getFruitTypeByName", name)
end


function FMAUtil.fillTypeIndex(name)
    local ft=FMAUtil.call(g_fillTypeManager, "getFillTypeByName", name)
    return ft and ft.index or nil
end

function FMAUtil.sprayType(fillType)
    if fillType==nil then return nil end
    return FMAUtil.call(g_sprayTypeManager, "getSprayTypeByFillTypeIndex", fillType)
end

function FMAUtil.isFertilizerFillType(fillType)
    local spray=FMAUtil.sprayType(fillType)
    return spray~=nil and spray.isFertilizer==true
end

function FMAUtil.isLimeFillType(fillType)
    local spray=FMAUtil.sprayType(fillType)
    return spray~=nil and spray.isLime==true
end

function FMAUtil.log(message)
    local line="[FarmManagerAI] " .. tostring(message)
    print(line)
    if FMAOpsLog and FMAOpsLog.appendManager then pcall(FMAOpsLog.appendManager,line) end
end

function FMAUtil.money(value)
    return tostring(math.floor(tonumber(value) or 0))
end

function FMAUtil.limit(s, n)
    s = tostring(s or "")
    -- Byte-safe enough for ASCII filenames; do not split a Czech UTF-8 glyph.
    if #s <= n then return s end
    local last = n
    while last > 0 and s:byte(last) >= 128 and s:byte(last) < 192 do last = last-1 end
    return s:sub(1,last-1) .. "…"
end
