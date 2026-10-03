-- Single physical control authority per tractor. Never compete with the player,
-- GIANTS AI, Courseplay or FarmManager's own direct wheel driver.
FMAControlAuthority = {}

local function actualAI(v)
    return FMAUtil and FMAUtil.call and FMAUtil.call(v,'getIsAIActive')==true
end
local function player(v)
    return FMAGameNative and FMAGameNative.isManuallyControlled and FMAGameNative.isManuallyControlled(v)==true
end

function FMAControlAuthority.snapshot(c,record)
    local key=record and record.key
    local v=record and record.object
    local state={key=key,vehicle=v,mode='IDLE',jobCount=0,jobId=nil,
        reservedBy=key and c and c.reservations and c.reservations[key] or nil}
    if not v or v.isDeleted then state.mode='MISSING';return state end
    local own=key and c and c.ownDriveSessions and c.ownDriveSessions[key]
    state.ownSession=own
    for _,active in pairs(c and c.active or {}) do
        if active.vehicle and active.vehicle.key==key then
            state.jobCount=state.jobCount+1
            state.jobId=active.task and active.task.id or '?'
        end
    end
    state.player=player(v)
    state.ai=actualAI(v)
    state.courseplay=state.ai and ((FMAUtil.call(v,'getIsCpActive')==true)
        or (FMAUtil.call(v,'getCpDriveStrategy')~=nil))
    if state.player then state.mode='PLAYER'
    elseif own then state.mode='FMA_OWN'
    elseif state.ai and state.courseplay then state.mode='COURSEPLAY'
    elseif state.ai then state.mode='GIANTS_AI'
    elseif state.jobCount>0 then state.mode='AI_PENDING'
    elseif state.reservedBy then state.mode='FMA_RESERVED' end
    return state
end

-- Every new worker must pass through this interlock. A reservation is NOT
-- sufficient evidence that the old engine released the wheels.
function FMAControlAuthority.canStart(c,record,taskId,allowReserved)
    if not c or not c.settings or c.settings.enabled~=true or c.shuttingDown then
        return false,'Družstvo není spuštěné'
    end
    local state=FMAControlAuthority.snapshot(c,record)
    if state.mode=='MISSING' then return false,'Vozidlo už není načteno' end
    if FMAUtil.owner(state.vehicle)~=c.farmId then return false,'Cizí stroj' end
    if c.excluded and c.excluded[state.key] then return false,'Stroj vyřazen majitelem' end
    if state.player then return false,'Vozidlo převzal hráč' end
    if state.ownSession then return false,'Vozidlo řídí vlastní FMA řidič' end
    if state.ai then return false,'FS25 / Courseplay ještě neuvolnil fyzické řízení' end
    if state.jobCount>0 then return false,'Předchozí AI úloha ještě není uzavřena' end
    if state.reservedBy and state.reservedBy~=taskId and not allowReserved then
        return false,'Vozidlo je rezervované: '..tostring(state.reservedBy)
    end
    return true,state
end

-- Final launch interlock shared by ALL GIANTS AI jobs (including CP jobs that
-- use the native AI job factory). The just-created entry may already be in
-- c.active; only OTHER jobs sharing the same tractor are a conflict.
function FMAControlAuthority.canLaunch(c,vehicle,job)
    if not c or not vehicle then return true end
    local key=FMAWorld and FMAWorld.vehicleKey and FMAWorld.vehicleKey(vehicle)
    if not key then return false,'Stroj nemá stabilní identitu' end
    if c.ownDriveSessions and c.ownDriveSessions[key] then
        return false,'Vlastní FMA řidič dosud fyzicky řídí vozidlo'
    end
    for existing,active in pairs(c.active or {}) do
        if existing~=job and active and active.vehicle and
            (active.vehicle.key==key or active.vehicle.object==vehicle) then
            return false,'Souběžná pracovní úloha na stejném traktoru'
        end
    end
    return true
end

-- Own-driving is also an active reservation: otherwise the generic cleanup
-- silently drops its lease at the next reconciliation and dispatches another job.
function FMAControlAuthority.liveReservations(c,vehicles,tools)
    for key,session in pairs(c.ownDriveSessions or {}) do
        vehicles[key]=true
        if session.toolKey then tools[session.toolKey]=true end
    end
end

-- Read-only arbiter diagnostics. Never silently stop a player's controls.
function FMAControlAuthority.audit(c)
    local conflicts=0
    for _,record in ipairs(c.vehicles or {}) do
        local state=FMAControlAuthority.snapshot(c,record)
        if (state.ownSession and (state.jobCount>0 or state.ai or state.player))
            or state.jobCount>1 then
            conflicts=conflicts+1
            if (not c.controlConflictLogged or c.controlConflictLogged[record.key]~=(state.jobCount..':'..state.mode))
                and FMADiagnostics and FMADiagnostics.event then
                c.controlConflictLogged=c.controlConflictLogged or {}
                c.controlConflictLogged[record.key]=state.jobCount..':'..state.mode
                FMADiagnostics.event(c,'control.conflict',record.name or record.key,
                    'mode='..state.mode..' jobs='..state.jobCount..' reservation='..tostring(state.reservedBy))
            end
        elseif c.controlConflictLogged then
            c.controlConflictLogged[record.key]=nil
        end
    end
    c.controlAuthorityConflicts=conflicts
    return conflicts
end
