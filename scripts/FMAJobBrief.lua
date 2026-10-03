-- One truthful operator-facing status for EVERY job category. This module is
-- intentionally read-only: a bad rendering call must never start or stop AI.
-- A declared capability or a generated task is NOT proof of physical execution.
FMAJobBrief={}

function FMAJobBrief.reason(c,task)
    if not task then return 'Zakázka není dostupná' end
    if task.ownerStopRequested then return 'Zastaveno majitelem · pro pokračování použij START' end
    local state=tostring(task.state or 'pending')
    local reason=type(task.reason)=='string' and task.reason~='' and task.reason or nil
    if state=='done' then
        return task.resultVerified==true and 'Ověřený výsledek operace' or 'Dokončení evidováno · zkontroluj výsledek v FS25'
    end
    if state=='running' then
        local real=(c and c.vehicleByKey and task.vehicleKey and c.vehicleByKey[task.vehicleKey])
        local phase=tostring(task.phase or '')
        if task.kind=='field' and task.workEvidence then
            local e=task.workEvidence
            local dist=math.floor(tonumber(e.observedMove) or 0)
            local litres=math.floor(tonumber(e.consumed) or 0)
            local consumable={lime=true,fertilize=true,sow=true,weed=true}
            local consumption=consumable[task.operation] and (' · spotřeba '..litres..' l') or ''
            return 'AI etapa '..phase..' · fyzicky '..dist..' m'..consumption
        end
        if not real and task.kind=='field' then
            return 'Práce označena jako běžící · kontroluje se skutečný pracovní stroj'
        end
        return 'AI etapa probíhá · '..(reason or phase)
    end
    if state=='blocked' or state=='paused' or state=='cooldown' then
        if reason then return reason end
        local row=c and c.readinessAudit and c.readinessAudit[task.id]
        if row and row.reason then return tostring(row.reason) end
        return 'Je potřeba ověřit techniku, nájezd nebo dostupnost surovin'
    end
    if state=='assembling' or state=='preparing' or state=='waiting' or state=='starting' or state=='returning' then
        return tostring(task.phase or 'Příprava')..(reason and (' · '..reason) or '')
    end
    if task.isSale and task.ownerApproved~=true then
        return 'Prodej vyžaduje ruční START · vlastní sklady mají přednost'
    end
    if task.kind=='field' and c and c.fieldsById and task.fieldId then
        local field=c.fieldsById[task.fieldId] or c.fieldsById[tostring(task.fieldId)]
        if field and field.valid==false then return 'Stav pole není ověřený · práce nesmí začít naslepo' end
    end
    local audit=c and c.readinessAudit and c.readinessAudit[task.id]
    if audit then
        if audit.state=='BLOCKED' or audit.state=='STALE' then
            return tostring(audit.reason or 'Chybí připravená kompatibilní souprava')
        end
        if audit.state=='SERVICEABLE' then
            return 'Zakázku lze připravit · skutečný start potvrdí FS25 / Courseplay'
        end
    end
    return reason or tostring(task.phase or 'Čeká na tvůj START')
end

function FMAJobBrief.summary(c)
    local jobs,started,stopped,blockers=0,0,0,0
    for _,task in pairs(c and c.tasks or {}) do
        jobs=jobs+1
        if task.ownerApproved then started=started+1 end
        if task.ownerStopRequested then stopped=stopped+1 end
        if task.state=='blocked' then blockers=blockers+1 end
    end
    return {jobs=jobs,started=started,stopped=stopped,blockers=blockers}
end

-- An actionable, read-only view across the SAME real orders the dispatcher sees.
-- Do not create fictitious purchase orders or claim that an unresolved task works.
function FMAJobBrief.problems(c,limit)
    local result={}
    for _,task in pairs(c and c.tasks or {}) do
        local state=task.state or 'pending'
        if state=='blocked' or (state=='paused' and task.ownerApproved) then
            result[#result+1]={taskId=task.id,label=task.label or task.id,reason=FMAJobBrief.reason(c,task)}
        end
    end
    table.sort(result,function(a,b)return tostring(a.label)<tostring(b.label) end)
    while #result>(limit or 12) do table.remove(result) end
    return result
end
