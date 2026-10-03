-- Universal, read-only fieldwork proof. The tractor's name/store category does
-- not determine success: the LIVE attached implement, its real fill units,
-- physical travel and the live field map do. No fictional application/teleport.
FMAWorkEvidence={}
local E=FMAWorkEvidence
local applicable={harvest=true,mow=true,lime=true,fertilize=true,weed=true,sow=true,
    plow=true,cultivate=true,stone=true,roll=true,ted=true,windrow=true,
    bale=true,foragePickup=true}
local supplied={lime=true,fertilize=true,sow=true,weed=true}

local function addType(result,name)
    local index=FillType and FillType[name]
    if index==nil and g_fillTypeManager and type(g_fillTypeManager.getFillTypeIndexByName)=='function' then
        index=FMAUtil.call(g_fillTypeManager,'getFillTypeIndexByName',name)
    end
    if index~=nil then result[index]=true end
end

function E.materialTypes(operation)
    local types={}
    if operation=='lime' then addType(types,'LIME')
    elseif operation=='sow' then addType(types,'SEEDS')
    elseif operation=='fertilize' then
        for _,name in ipairs({'FERTILIZER','LIQUIDFERTILIZER','SLURRY','LIQUIDMANURE','MANURE','DIGESTATE'}) do
            addType(types,name)
        end
    elseif operation=='weed' then addType(types,'HERBICIDE') end
    if operation=='lime' or operation=='fertilize' then
        for _,spray in pairs(FMAUtil.call(g_sprayTypeManager,'getSprayTypes') or {}) do
            local matching=(operation=='lime' and spray.isLime==true)
                or (operation=='fertilize' and spray.isFertilizer==true)
            if matching and spray.fillType then
                local id=type(spray.fillType)=='table' and spray.fillType.index or spray.fillType
                if id~=nil then types[id]=true end
            end
        end
    end
    return types
end

local function operationalParts(record)
    if not record or not record.object then return {} end
    -- Transported implements (a header strapped to a carrier) are NOT working.
    if FMAWorld and FMAWorld.operationalChildren then
        return FMAWorld.operationalChildren(record.object)
    end
    return FMAWorld and FMAWorld.children and FMAWorld.children(record.object) or {record.object}
end

-- Detect herbicide sprayer versus mechanical weeder without a model-name list.
function E.mode(record,operation)
    if not applicable[operation] then return 'none' end
    if operation~='weed' then return supplied[operation] and 'consumable' or 'mechanical' end
    for _,obj in ipairs(operationalParts(record)) do
        if obj.spec_sprayer then return 'consumable' end
        local units=FMAUtil.call(obj,'getFillUnits') or (obj.spec_fillUnit and obj.spec_fillUnit.fillUnits) or {}
        local herbicide=FillType and FillType.HERBICIDE
        if herbicide~=nil then
            for i,unit in pairs(units) do
                local index=tonumber(i)
                if index and ((unit and unit.supportedFillTypes and unit.supportedFillTypes[herbicide])
                    or FMAUtil.call(obj,'getFillUnitFillType',index)==herbicide
                    or FMAUtil.call(obj,'getFillUnitSupportsFillType',index,herbicide)==true) then
                    return 'consumable'
                end
            end
        end
    end
    return 'mechanical'
end

-- A snapshot identifies individual physical tanks. An implement replacement or
-- detachment must not masquerade as consumption of a different tank.
function E.measure(record,operation)
    if not supplied[operation] then return nil end
    local wanted=E.materialTypes(operation)
    if next(wanted)==nil then return nil end
    local level,capacity,seen,readings=0,0,false,{}
    for _,obj in ipairs(operationalParts(record)) do
        local units=FMAUtil.call(obj,'getFillUnits') or (obj.spec_fillUnit and obj.spec_fillUnit.fillUnits) or {}
        for i,unit in pairs(units) do
            local index=tonumber(i)
            if index then
                local ft=FMAUtil.call(obj,'getFillUnitFillType',index)
                local amount=tonumber(FMAUtil.call(obj,'getFillUnitFillLevel',index))
                local cap=tonumber(FMAUtil.call(obj,'getFillUnitCapacity',index)) or tonumber(unit and unit.capacity) or 0
                local compatible=wanted[ft]==true
                if not compatible then
                    for fillType in pairs(wanted) do
                        if (unit and unit.supportedFillTypes and unit.supportedFillTypes[fillType]==true)
                            or FMAUtil.call(obj,'getFillUnitSupportsFillType',index,fillType)==true then
                            compatible=true;break
                        end
                    end
                end
                -- A nonempty unit of some OTHER material is not our consumable.
                if compatible and amount and cap>0 and (wanted[ft]==true or amount<=0) then
                    local key=tostring(obj)..':'..tostring(index)
                    readings[key]=math.max(0,amount)
                    level=level+math.max(0,amount);capacity=capacity+cap;seen=true
                end
            end
        end
    end
    if not seen then return nil end
    return {level=level,capacity=capacity,units=readings}
end

function E.begin(c,task,record)
    if not task or not applicable[task.operation] or not record then return end
    if task.workEvidence and task.workEvidence.vehicleKey==record.key
        and task.workEvidence.fieldworkToken==task.fieldworkStartedAt then return end
    local mode=E.mode(record,task.operation)
    local row=mode=='consumable' and E.measure(record,task.operation) or nil
    local x,z=FMAUtil.position(record.object)
    task.workEvidence={vehicleKey=record.key,fieldworkToken=task.fieldworkStartedAt,
        mode=mode,first=row and row.level or nil,minimum=row and row.level or nil,
        capacity=row and row.capacity or nil,unitReadings=row and row.units or nil,
        consumed=0,observed=0,startedAt=c and c.now or 0,observedMove=0,
        lastX=x,lastZ=z}
end

function E.sample(c,task,record)
    if not task or not applicable[task.operation] or not record then return end
    if not task.workEvidence then E.begin(c,task,record) end
    local e=task.workEvidence
    if not e or e.vehicleKey~=record.key then return end
    if e.mode=='consumable' then
        local row=E.measure(record,task.operation)
        if row then
            if e.first==nil then e.first=row.level end
            e.minimum=math.min(e.minimum or row.level,row.level)
            e.capacity=math.max(e.capacity or 0,row.capacity or 0)
            for key,amount in pairs(row.units or {}) do
                local before=e.unitReadings and e.unitReadings[key]
                if before~=nil and before>amount then
                    e.consumed=(e.consumed or 0)+(before-amount)
                end
            end
            e.unitReadings=row.units
            e.observed=(e.observed or 0)+1
        else
            -- Never credit disappearance of a disconnected/changed implement.
            e.unitReadings=nil
        end
    end
    local x,z=FMAUtil.position(record.object)
    if x and z and e.lastX and e.lastZ then
        local dx,dz=x-e.lastX,z-e.lastZ
        local metres=math.sqrt(dx*dx+dz*dz)
        -- Ignore resets/teleports: work requires real incremental movement.
        if metres>0.7 and metres<65 then e.observedMove=(e.observedMove or 0)+metres end
    end
    e.lastX=x or e.lastX;e.lastZ=z or e.lastZ
end

function E.verify(task,record)
    if not task or not applicable[task.operation] then return true,nil end
    local e=task.workEvidence
    if not e then return false,'Chybí průběžný fyzický záznam práce stroje' end
    if record and record.key==e.vehicleKey then E.sample(nil,task,record) end
    -- Support in-progress legacy work records restored in the same session.
    local mode=e.mode or (supplied[task.operation] and task.operation~='weed' and 'consumable' or 'mechanical')
    if mode=='consumable' then
        if e.first==nil then
            return false,'Nelze ověřit skutečnou nádrž s materiálem v připojeném nářadí'
        end
        local consumed=tonumber(e.consumed)
        if consumed==nil then consumed=math.max(0,(e.first or 0)-(e.minimum or e.first or 0)) end
        local minConsumption=math.max(3,math.min(30,(e.capacity or 0)*0.001))
        if consumed<minConsumption then
            local last=record and E.measure(record,task.operation)
            local pct=last and last.capacity>0 and math.floor(last.level/last.capacity*100+0.5)
            return false,'Nářadí neprokázalo spotřebu materiálu pro '..tostring(task.operation)
                ..' (minimální úbytek '..math.floor(minConsumption)..' l, naměřeno '..math.floor(consumed)
                ..' l'..(pct and ', nádrž '..pct..' %' or '')..'). Stav pole sám nestačí'
        end
    end
    if (e.observedMove or 0)<5 then
        return false,'Není potvrzen fyzický pohyb pracovního stroje (nejméně 5 m, bez teleportu)'
    end
    if mode=='consumable' then
        return true,'Fyzický úbytek materiálu a pohyb potvrzeny'
    end
    return true,'Fyzický pohyb stroje potvrzen; výsledný stav pole se ověřuje samostatně'
end
