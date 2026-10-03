-- Bale-chain coordinator. Courseplay handles field driving/pickup; Farm Manager
-- decides when to collect, remembers actual bale fill types and sends the loaded
-- collector to a compatible owned ObjectStorage afterwards.
FMABaleCoordinator = {}

local function ownedFieldAt(controller,x,z)
    if x==nil or z==nil then return nil end
    local CpFieldUtil=FS25_Courseplay and FS25_Courseplay.CpFieldUtil
    if CpFieldUtil and type(CpFieldUtil.getFieldIdAtWorldPosition)=='function' then
        local ok,id=pcall(CpFieldUtil.getFieldIdAtWorldPosition,x,z)
        if ok and id~=nil then
            local key=tostring(id)
            if controller.fieldsById and controller.fieldsById[key] then return controller.fieldsById[key] end
        end
    end
    if g_fieldManager and type(g_fieldManager.getFieldIdAtWorldPosition)=='function' then
        local ok,id=pcall(g_fieldManager.getFieldIdAtWorldPosition,g_fieldManager,x,z)
        if ok and id~=nil then
            local key=tostring(id)
            if controller.fieldsById and controller.fieldsById[key] then return controller.fieldsById[key] end
        end
    end
    return nil
end

local function baleFillType(bale)
    if not bale then return nil end
    return FMAUtil.call(bale,'getFillType') or bale.fillType or (bale.spec_bale and bale.spec_bale.fillType)
end

local function typeSummary(fillTypes)
    local rows={}
    for ft,count in pairs(fillTypes or {}) do rows[#rows+1]={ft=ft,count=count,name=FMAWorld.fillName(ft)} end
    table.sort(rows,function(a,b)return tostring(a.name)<tostring(b.name) end)
    local parts={};for _,row in ipairs(rows) do parts[#parts+1]=row.name..' '..row.count..'×' end
    return #parts>0 and table.concat(parts,' · ') or 'typ nezjištěn'
end

function FMABaleCoordinator.scan(controller)
    controller.baleFields={}
    if not controller.settings.baleAutomation or not FMACourseplay.available() then return end
    local g_baleToCollectManager=FS25_Courseplay and FS25_Courseplay.g_baleToCollectManager
    if not g_baleToCollectManager or type(g_baleToCollectManager.getBales)~='function' then return end
    local ok,bales=pcall(g_baleToCollectManager.getBales,g_baleToCollectManager)
    if not ok or type(bales)~='table' then return end
    for _,bale in pairs(bales) do
        local node=bale and bale.nodeId
        if node and node~=0 and type(getWorldTranslation)=='function' then
            local okPos,x,_,z=pcall(getWorldTranslation,node)
            if okPos then
                local field=ownedFieldAt(controller,x,z)
                if field then
                    local row=controller.baleFields[field.id]
                    if not row then row={fieldId=field.id,x=field.x,z=field.z,count=0,fillTypes={},bales={}};controller.baleFields[field.id]=row end
                    row.count=row.count+1;row.bales[#row.bales+1]=bale
                    local ft=baleFillType(bale);if ft then row.fillTypes[ft]=(row.fillTypes[ft] or 0)+1 end
                end
            end
        end
    end
    for fieldId,stage in pairs(controller.forageStages or {}) do
        if stage=='baled' and controller.baleFields[fieldId]==nil then
            -- Absence in CP's pickup registry is not proof that every bale was stored.
            controller:issue('bales:check:'..fieldId,'Pole '..fieldId..' · kontrola balíků','Registr nehlásí další balíky; ověř uložení nebo dokončené balení.',50)
        end
    end
    for fieldId,row in pairs(controller.baleFields) do
        row.typeSummary=typeSummary(row.fillTypes)
        if row.count>0 then
            local can=false
            for _,v in ipairs(controller.vehicles or {}) do
                if not controller.excluded[v.key] and type(v.object.getCanStartCpBaleFinder)=='function' then
                    local okCan,value=pcall(v.object.getCanStartCpBaleFinder,v.object)
                    if okCan and value then can=true break end
                end
            end
            if not can then
                controller:issue('bales:equipment:'..fieldId,'Pole '..fieldId..' · '..row.count..' balíků čeká',
                    row.typeSummary..' · chybí připravený Courseplay-kompatibilní sběrač/ovíječka. Manager nebude balíky ignorovat ani náhodně přesouvat.',78)
                controller:equipmentIssue('baleCollect','Balíky na poli '..fieldId)
            end
        end
    end
end

function FMABaleCoordinator.dispatch(controller)
    if not controller.settings.enabled or not controller.settings.baleAutomation or not FMACourseplay.available() then return false end
    if FMAUtil.count(controller.reservations)>=controller.settings.maxWorkers then return false end
    for fieldId,row in pairs(controller.baleFields or {}) do
        if row.count>0 and FMAJobs.mayStart(controller,"bales:"..fieldId) then
            local occupied=false
            for _,a in pairs(controller.active or {}) do if a.task and a.task.fieldId==fieldId then occupied=true break end end
            if not occupied then
                for _,v in ipairs(controller.vehicles or {}) do
                    if not v.busy and not controller.excluded[v.key] and not controller.reservations[v.key] and not v.lowFuel and type(v.object.getCanStartCpBaleFinder)=='function' then
                        local okCan,can=pcall(v.object.getCanStartCpBaleFinder,v.object)
                        if okCan and can then
                            local task={id='bales:'..fieldId,kind='bales',operation='baleCollect',fieldId=fieldId,
                                label='Balíky · pole '..fieldId,state='running',priority=76,attempts=1,x=row.x,z=row.z,baleFillTypes=row.fillTypes,baleTypeSummary=row.typeSummary}
                            local job,why,waiting=FMACourseplay.startBales(controller,v,row.x,row.z)
                            if job then
                                controller.reservations[v.key]=task.id;v.busy=true
                                controller.active[job]={job=job,task=task,vehicle=v,start=controller.now,lastProgress=controller.now,x=v.x,z=v.z,fill=v.fillTotal}
                                controller:notify(v.name..' zahájil sběr '..row.count..' balíků na poli '..fieldId..' · '..row.typeSummary)
                                return true
                            else
                                if not waiting then FMAJobs.fail(controller,task,v,why) end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end
