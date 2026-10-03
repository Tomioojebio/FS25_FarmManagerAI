-- Farm Manager AI: read-only rotating flight recorder. Never controls a vehicle,
-- never opens/copies the savegame and never uses append (FS25 sandbox restriction).
FMABlackBox={VERSION='0.20.48.0',SLOTS=12,MAX_ROWS=400,FLUSH_MS=15000,SAMPLE_MS=1000,
    HEARTBEAT_MS=60000,MOTION_MS=25000,SEGMENT_PREFIX='FS25_FarmManagerAI_TRACE_'}
local B=FMABlackBox
local function safe(value)
    local s=tostring(value==nil and '-' or value)
    return s:gsub('[\r\n\t|]',' '):sub(1,250)
end
local function pos(record)
    if not record then return nil,nil end
    local obj=record.object
    local x,z=nil,nil
    if obj then x,z=FMAUtil.position(obj) end
    return tonumber(x or record.x),tonumber(z or record.z)
end
local function dist(x,z,a,b)
    if x==nil or z==nil or a==nil or b==nil then return nil end
    local dx,dz=x-a,z-b
    return math.sqrt(dx*dx+dz*dz)
end
function B.new()
    return {slot=1,serial=1,rows={},savedSegments={},lastFlush=-1000000,lastSample=0,lastHeartbeat=0,
        tasks={},vehicles={},crews={},active={},fields={},diagnoses={},categories={},written=0,
        lastWriteError=nil,dirty=true,lastAuto=nil,lastMap=nil}
end
function B.attach(c)
    if not c then return nil end
    if not c.blackBox then c.blackBox=B.new() end
    return c.blackBox
end
local function queue(c,category,key,parts)
    local r=B.attach(c)
    if not r then return false end
    local now=math.floor((c.now or 0)/1000)
    local details={}
    local count=0
    for k in pairs(parts or {}) do if type(k)=="number" and k>count then count=k end end
    for i=1,count do details[#details+1]=safe(parts[i]) end
    r.rows[#r.rows+1]=tostring(now)..' | '..safe(category)..' | '..safe(key)..' | '..table.concat(details,' | ')
    r.categories[category]=(r.categories[category] or 0)+1
    r.dirty=true
    return true
end
function B.event(c,kind,id,detail)
    return queue(c,'EVENT',kind,{id,detail})
end
function B.cause(text)
    local low=tostring(text or ''):lower()
    if low=='' or low=='-' then return nil end
    if low:find('goalnodeinvalid',1,true) or low:find('cíl není dosažiteln',1,true) or low:find('nelze najít trasu',1,true)
        or low:find('neprůjezd',1,true) then
        return 'NAV_GOAL','Zkontrolovat platnost AI bodu, rozměry soupravy a výjezd; použít existující ověřený nájezd'
    end
    if low:find('no idle unloader',1,true) or low:find('odvozce',1,true) and low:find('chyb',1,true) then
        return 'CREW_UNLOADER','Ověřit registraci Courseplay unloader strategie, rezervaci traktoru a skutečný přívěs'
    end
    if low:find('courseplay',1,true) and (low:find('start',1,true) or low:find('odmít',1,true)) then
        return 'CP_START','Zkontrolovat AI obsazení, typ úlohy, výběr kurzu a odpověď veřejného CP API'
    end
    if low:find('zapřaž',1,true) or low:find('nářad',1,true) and low:find('příjez',1,true) then
        return 'ASSEMBLY','Zkontrolovat skutečné spojení, orientaci závěsu a vhodný příjezdový bod'
    end
    if low:find('napln',1,true) or low:find('materiál',1,true) then
        return 'REFILL','Přečíst live fillType, fillUnit index a množství v připojeném nářadí'
    end
    if low:find('vrac',1,true) or low:find('návrat',1,true) then
        return 'RETURN','Prověřit parkovací bod, ověřenou výjezdovou trasu a směrovost silnice'
    end
    return nil
end
function B.diagnose(c,key,description)
    local r=B.attach(c)
    if not r then return nil end
    local kind,remedy=B.cause(description)
    if not kind then return nil end
    local causeKey=safe(key)..':'..kind
    if r.diagnoses[causeKey]~=description then
        r.diagnoses[causeKey]=description
        queue(c,'DIAG',causeKey,{description,remedy,'AUTO_REPAIR=only existing verified recovery'})
    end
    return kind
end
local function walkTasks(c,r)
    local present={}
    for id,task in pairs(c.tasks or {}) do
        local key=tostring(id)
        present[key]=true
        local state=table.concat({safe(task.state),safe(task.phase),safe(task.reason),
            'approved='..tostring(task.ownerApproved==true),'attempts='..safe(task.attempts)},'~')
        if r.tasks[key]~=state then
            queue(c,'ORDER',key,{task.operation,task.state,task.phase,task.reason,
                'approved='..tostring(task.ownerApproved==true),'attempts='..safe(task.attempts)})
            if task.reason then B.diagnose(c,key,task.reason) end
            r.tasks[key]=state
        end
        if task.workEvidence then
            local e=task.workEvidence
            local evidence=math.floor(tonumber(e.consumed) or 0)..':'..math.floor(tonumber(e.observedMove) or 0)
            if evidence~=(r.evidence and r.evidence[key]) then
                r.evidence=r.evidence or {}
                r.evidence[key]=evidence
                if (e.consumed or 0)>0 or (e.observedMove or 0)>0 then
                    queue(c,'WORK_PROOF',key,{'litres='..safe(e.consumed),'metres='..safe(e.observedMove),'mode='..safe(e.mode)})
                end
            end
        end
    end
    for key in pairs(r.tasks) do if not present[key] then r.tasks[key]=nil;queue(c,'ORDER_GONE',key,{}) end end
end
local function walkActive(c,r)
    local present={}
    for job,active in pairs(c.active or {}) do
        local id=safe(active.task and active.task.id)
        local vehicle=safe(active.vehicle and active.vehicle.key)
        local key=id..'@'..vehicle
        present[key]=true
        local phase=safe(active.task and active.task.phase)..'/'..safe(active.transferMethod)..'/'..tostring(job and job.isRunning)
        if r.active[key]~=phase then
            queue(c,'AI_JOB',key,{phase,'confirmed='..safe(active.dispatchVerified),'motion='..safe(active.physicalMotionVerified),
                'target='..safe(active.trafficTarget and active.trafficTarget.x)..','..safe(active.trafficTarget and active.trafficTarget.z)})
            r.active[key]=phase
        end
    end
    for key in pairs(r.active) do if not present[key] then r.active[key]=nil;queue(c,'AI_JOB_END',key,{}) end end
end
local function walkCrew(c,r)
    local present={}
    for id,roles in pairs(c.preparedSupport or {}) do
        for slot,s in pairs(roles or {}) do
            local key=safe(id)..':'..safe(slot)
            present[key]=true
            local stage=table.concat({safe(s.state),safe(s.phase),safe(s.record and s.record.key),safe(s.reason)},'~')
            if r.crews[key]~=stage then
                r.crews[key]=stage
                queue(c,'CREW',key,{s.state,s.phase,s.record and s.record.name,s.reason})
                if s.reason then B.diagnose(c,key,s.reason) end
            end
        end
    end
    for key in pairs(r.crews) do if not present[key] then r.crews[key]=nil;queue(c,'CREW_GONE',key,{}) end end
end
local function walkFarm(c,r)
    -- One-time/diff-only census: not a 1 Hz dump of the whole map.
    local registry=c.worldRegistry or {}
    local atlas=c.worldAtlas or {}
    local census=table.concat({safe(#(c.fields or {})),safe(#(c.vehicles or {})),
        safe(#(c.loose or {})),safe(registry.revision or 0),safe(atlas.identity),
        safe(atlas.totalMapFields),safe(atlas.placeables),safe(atlas.ownedPlaceables),
        safe(#(atlas.husbandries or {})),safe(#(atlas.storages or {})),
        safe(#(atlas.productions or {})),safe(#(atlas.bunkers or {})),
        safe(#(atlas.loadingStations or {})),safe(#(atlas.unloadingStations or {}))},'~')
    if r.census~=census then
        r.census=census
        queue(c,'WORLD_SCAN','inventory',{'ownedFields='..safe(#(c.fields or {})),
            'poweredVehicles='..safe(#(c.vehicles or {})),'looseTools='..safe(#(c.loose or {})),
            'registryRevision='..safe(registry.revision or 0),'map='..safe(atlas.identity),
            'mapFields='..safe(atlas.totalMapFields),'placeables='..safe(atlas.placeables),
            'ownedBuildings='..safe(atlas.ownedPlaceables),'husbandries='..safe(#(atlas.husbandries or {})),
            'silos='..safe(#(atlas.storages or {})),'productions='..safe(#(atlas.productions or {})),
            'bunkers='..safe(#(atlas.bunkers or {})),
            'loading='..safe(#(atlas.loadingStations or {})),'unloading='..safe(#(atlas.unloadingStations or {}))})
    end
    local present={}
    for _,f in ipairs(c.fields or {}) do
        if f.id then
            local id=safe(f.id);present[id]=true
            local snapshot=table.concat({safe(f.valid),safe(f.ready),safe(f.alive),safe(f.bare),
                safe(f.needsLime),safe(f.needsPlow),safe(f.needsFertilize),safe(f.needsWeed),safe(f.fingerprint)},'~')
            if r.fields[id]~=snapshot then
                queue(c,'FIELD_SCAN',id,{'valid='..safe(f.valid),'ready='..safe(f.ready),
                    'alive='..safe(f.alive),'bare='..safe(f.bare),'lime='..safe(f.needsLime),
                    'plow='..safe(f.needsPlow),'fertilize='..safe(f.needsFertilize),
                    'weed='..safe(f.needsWeed),'fingerprint='..safe(f.fingerprint)})
                r.fields[id]=snapshot
            end
        end
    end
    for key in pairs(r.fields) do if not present[key] then r.fields[key]=nil;queue(c,'FIELD_GONE',key,{}) end end
    local transfer=FMATransfer and FMATransfer.runtimeStatus and FMATransfer.runtimeStatus() or {}
    local cp=safe(transfer.registered)..':'..safe(transfer.environment)..':'..safe(transfer.error)
    if cp~=r.lastCp then
        r.lastCp=cp
        queue(c,'COURSEPLAY','interface',{'registered='..safe(transfer.registered),
            'environment='..safe(transfer.environment),'error='..safe(transfer.error)})
    end
end
local function walkVehicles(c,r,now)
    local present={}
    for _,v in ipairs(c.vehicles or {}) do
        if v.key then
            local key=safe(v.key);present[key]=true
            local x,z=pos(v)
            local obj=v.object
            local job=FMAUtil.call(obj,'getIsAIActive')==true
            local cp=FMAUtil.call(obj,'getIsCpFieldWorkActive')==true
            local owner=safe(c.reservations and c.reservations[v.key])
            local state='ai='..tostring(job)..' cp='..tostring(cp)..' lock='..owner
            local previous=r.vehicles[key]
            if not previous then
                queue(c,'VEHICLE_NEW',key,{v.name,'x='..safe(x),'z='..safe(z),state})
                r.vehicles[key]={x=x,z=z,changedAt=now,lastAt=now,lastTraceAt=now,state=state}
            else
                local moved=dist(x,z,previous.x,previous.z)
                if moved and moved>=1.5 then
                    previous.x=x;previous.z=z;previous.lastAt=now
                end
                if previous.state~=state then
                    queue(c,'VEHICLE_AI',key,{v.name,state,'x='..safe(x),'z='..safe(z)})
                    previous.state=state;previous.changedAt=now
                end
                if (job or cp or owner~='-') and now-(previous.lastTraceAt or 0)>=B.MOTION_MS then
                    previous.lastTraceAt=now
                    queue(c,'VEHICLE_POS',key,{v.name,'x='..safe(x),'z='..safe(z),state})
                end
                if (job or cp) and now-(previous.lastAt or now)>=35000 and now-(previous.lastStallAt or 0)>=35000 then
                    previous.lastStallAt=now
                    queue(c,'DIAG',key,{'AI_ACTIVE_BUT_STATIONARY','x='..safe(x),'z='..safe(z),
                        'Zkontrolovat cestu, fyzickou překážku, otáčení a CP job; není důkaz o pohybu'})
                end
            end
        end
    end
    for key in pairs(r.vehicles) do if not present[key] then r.vehicles[key]=nil;queue(c,'VEHICLE_GONE',key,{}) end end
end
function B.sample(c)
    if not c then return end
    local r=B.attach(c)
    local now=c.now or 0
    if now-(r.lastSample or 0)<B.SAMPLE_MS then return end
    r.lastSample=now
    local auto=tostring(c.settings and c.settings.enabled==true)..' paused='..tostring(c.runtimePaused==true)
    if auto~=r.lastAuto then r.lastAuto=auto;queue(c,'AUTO','state',{auto}) end
    local atlas=c.worldAtlas and c.worldAtlas.identity or c.mapProfile and c.mapProfile.mapId
    if atlas and atlas~=r.lastMap then r.lastMap=atlas;queue(c,'MAP','loaded',{atlas,'fields='..tostring(#(c.fields or {})),
        'vehicles='..tostring(#(c.vehicles or {}))}) end
    walkFarm(c,r)
    walkTasks(c,r)
    walkActive(c,r)
    walkCrew(c,r)
    walkVehicles(c,r,now)
    if now-(r.lastHeartbeat or 0)>=B.HEARTBEAT_MS then
        r.lastHeartbeat=now
        queue(c,'HEARTBEAT','farm',{auto,'vehicles='..tostring(#(c.vehicles or {})),
            'tasks='..tostring(FMAUtil.count(c.tasks or {})),
            'active='..tostring(FMAUtil.count(c.active or {})),
            'reserved='..tostring(FMAUtil.count(c.reservations or {})),
            'faults='..tostring(FMAUtil.count(c.subsystemFaults or {}))})
    end
    B.flush(c,false)
end
function B.flush(c,force)
    local r=B.attach(c)
    if not r or not FMAOpsLog or not FMAOpsLog.writePortable then return false end
    local now=c.now or 0
    if not force and (not r.dirty or now-(r.lastFlush or 0)<B.FLUSH_MS) then return false end
    if #r.rows==0 then return false end
    local name=B.SEGMENT_PREFIX..string.format('%02d',r.slot)..'.txt'
    local heading='FMA FLIGHT RECORDER '..B.VERSION..' | SESSION '..safe(c.flightSessionId or 'game')..' | SLOT '..r.slot..'/'..B.SLOTS..'\n'
        ..'READ ONLY. Times in seconds from game session start. New segments rotate after '..B.MAX_ROWS..' events.\n'
    local _,ok=FMAOpsLog.writePortable(name,heading..table.concat(r.rows,'\n')..'\n')
    r.lastFlush=now
    if not ok then r.lastWriteError='trace writer denied: '..name;return false end
    r.lastWriteError=nil;r.written=r.written+1;r.dirty=false
    -- Preserve the bounded, last-12-segment history in RAM for one-file export.
    -- The GIANTS sandbox does not allow reopening earlier TRACE files for reading.
    r.savedSegments=r.savedSegments or {}
    r.savedSegments[r.slot]={serial=r.serial or 1,slot=r.slot,content=heading..table.concat(r.rows,'\n')..'\n'}
    if #r.rows>=B.MAX_ROWS then
        r.serial=(r.serial or 1)+1
        r.slot=r.slot%B.SLOTS+1
        r.rows={};r.dirty=false
    end
    return true
end
function B.summary(c)
    local r=c and c.blackBox
    if not r then return 'Recorder not initialized' end
    return 'recorder version='..B.VERSION..' slot='..r.slot..' rows='..#r.rows..' writes='..r.written
        ..' lastError='..safe(r.lastWriteError)..' files='..B.SEGMENT_PREFIX..'01..12.txt'
end

-- Text captured from this session only.  A saved segment for the current slot
-- is replaced by the latest in-memory rows so no event is lost between flushes.
function B.exportHistory(c)
    local r=c and c.blackBox
    if not r then return {},'Flight recorder not initialized in this session' end
    local segments={}
    for slot,snapshot in pairs(r.savedSegments or {}) do
        if slot~=r.slot or #(r.rows or {})==0 then
            segments[#segments+1]={serial=snapshot.serial or 0,slot=slot,content=snapshot.content}
        end
    end
    if #(r.rows or {})>0 then
        local header='FMA FLIGHT RECORDER '..B.VERSION..' | SESSION '..safe(c.flightSessionId or 'game')
            ..' | SLOT '..r.slot..'/'..B.SLOTS..' | IN MEMORY\n'
        segments[#segments+1]={serial=r.serial or 1,slot=r.slot,
            content=header..table.concat(r.rows,'\n')..'\n'}
    end
    table.sort(segments,function(a,b) return a.serial<b.serial end)
    return segments,nil
end
