-- Cooperative enterprise supervisor. FS25 and Courseplay remain the authoritative
-- execution engines; this layer only reconciles live world state, persistent crews,
-- work-order phases and human intervention into one dispatch view.
FMAEnterprise = { VERSION='0.20.27.0' }

local function phase(task)
    if not task then return 'IDLE' end
    local p=string.upper(tostring(task.phase or ''))
    if p:find('PLN',1,true) or p:find('DOPL',1,true) then return 'PLNĚNÍ' end
    if p:find('AGREG',1,true) or p:find('SOUPR',1,true) or p:find('ADAPT',1,true) then return 'AGREGACE' end
    if p:find('PŘEJEZD',1,true) or p:find('PRESUN',1,true) or p:find('TRASA',1,true) or p:find('ČEKÁ NA PROVOZ',1,true) then return 'PŘEJEZD' end
    if p:find('NÁVRAT',1,true) or p:find('ODSTAV',1,true) then return 'NÁVRAT' end
    if p:find('RUČN',1,true) or p:find('AI ŘÍZEN',1,true) then return 'PRÁCE' end
    local s=tostring(task.state or '')
    if s=='assembling' or s=='preparing' then return 'PŘÍPRAVA' end
    if s=='running' then return 'PRÁCE' end
    if s=='returning' then return 'NÁVRAT' end
    if s=='waiting' then return 'ČEKÁNÍ' end
    if s=='blocked' then return 'BLOKACE' end
    if s=='done' then
        if task.kind=='field' and (not task.fieldworkStartedAt or task.awaitingWorldVerification==true) then return 'OVĚŘENÍ' end
        return 'HOTOVO' end
    if s=='paused' then return 'POZASTAVENO' end
    return 'PLÁN'
end

function FMAEnterprise.operatorMode(record)
    if not record then return 'MISSING' end
    if FMAGameNative and FMAGameNative.operatorState then
        return FMAGameNative.operatorState(record.object).mode
    end
    return record.operatorMode or 'IDLE'
end

function FMAEnterprise.update(c)
    c.enterprise=c.enterprise or {revision=0,orders={},phaseCounts={},lastWorldRevision=-1}
    local e=c.enterprise
    local wr=c.worldRegistry and c.worldRegistry.revision or 0
    if wr~=e.lastWorldRevision then
        e.lastWorldRevision=wr;e.revision=(e.revision or 0)+1
        e.lastWorldChange=c.worldRegistry and c.worldRegistry.lastChangeText or nil
    end

    e.orders={};e.phaseCounts={}
    for id,task in pairs(c.tasks or {}) do
        local ph=phase(task)
        e.phaseCounts[ph]=(e.phaseCounts[ph] or 0)+1
        e.orders[id]={id=id,label=task.label,phase=ph,state=task.state,fieldId=task.fieldId,operation=task.operation,reason=task.reason}
        task.enterprisePhase=ph
    end

    -- Keep every live vehicle record synchronized with the actual control authority.
    -- This is deliberately independent of job ownership: PLAYER / FS_AI / COURSEPLAY
    -- are modes of the same crew member, not different crews.
    e.controlCounts={PLAYER=0,FS_AI=0,COURSEPLAY=0,IDLE=0,MISSING=0}
    for _,record in ipairs(c.vehicles or {}) do
        local mode=FMAEnterprise.operatorMode(record)
        record.operatorMode=mode
        e.controlCounts[mode]=(e.controlCounts[mode] or 0)+1
    end

    e.activeOrders=0;e.blockedOrders=0
    for _,row in pairs(e.orders) do
        if row.phase=='PRÁCE' or row.phase=='PŘÍPRAVA' or row.phase=='AGREGACE' or row.phase=='PLNĚNÍ' or row.phase=='PŘEJEZD' or row.phase=='NÁVRAT' or row.phase=='ČEKÁNÍ' then e.activeOrders=e.activeOrders+1 end
        if row.phase=='BLOKACE' then e.blockedOrders=e.blockedOrders+1 end
    end
end

function FMAEnterprise.summary(c)
    local e=c.enterprise or {}
    local cc=e.controlCounts or {}
    return 'Zakázky '..tostring(e.activeOrders or 0)..' · blokace '..tostring(e.blockedOrders or 0)
        ..' · hráč '..tostring(cc.PLAYER or 0)..' · FS AI '..tostring(cc.FS_AI or 0)..' · CP '..tostring(cc.COURSEPLAY or 0)
end

function FMAEnterprise.writeDiagnostics(c,f)
    local e=c.enterprise or {}
    f:write('\nENTERPRISE SUPERVISOR revision=',tostring(e.revision or 0),' worldRevision=',tostring(e.lastWorldRevision or 0),
        ' lastWorldChange=',tostring(e.lastWorldChange or 'none'),' active=',tostring(e.activeOrders or 0),' blocked=',tostring(e.blockedOrders or 0),'\n')
    local ids={};for id in pairs(e.orders or {}) do ids[#ids+1]=id end;table.sort(ids)
    for _,id in ipairs(ids) do local o=e.orders[id];f:write('ORDER ',tostring(id),' phase=',tostring(o.phase),' state=',tostring(o.state),' op=',tostring(o.operation),' field=',tostring(o.fieldId or '-'),' reason=',tostring(o.reason or '-'),'\n') end
end
