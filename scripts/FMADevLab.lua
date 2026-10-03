-- TEMPORARY DEVELOPMENT INSTRUMENTATION. REMOVE BEFORE STABLE RELEASE.
-- Passive audit runs automatically while the game is loaded, including with AUTO off.
-- A bounded physical smoke test requires a deliberate click on a COPY of the save.
FMADevLab = {VERSION='0.20.48.0-dev',SAMPLE_MS=1600,REPORT_MS=90000,MAX_EVENTS=210}
local D=FMADevLab
local function say(v)
    if v==nil then return '-' end
    return tostring(v):gsub('[\r\n|]',' '):sub(1,250)
end
local function sensor(v,method)
    if not v or type(v[method])~='function' then return nil end
    local ok,result=pcall(v[method],v)
    if ok then return result end
    return nil
end
local function pos(v)
    if not v or not FMAUtil or not FMAUtil.position then return nil,nil end
    local ok,x,z=pcall(FMAUtil.position,v)
    if ok then return x,z end
    return nil,nil
end
local function range(ax,az,bx,bz)
    if not ax or not az or not bx or not bz then return math.huge end
    return math.sqrt((ax-bx)^2+(az-bz)^2)
end
local function entries(t)
    local n=0;for _ in pairs(t or {}) do n=n+1 end;return n
end
local function lab(c)
    if not c.devLab then
        c.devLab={clock=0,nextSample=0,nextReport=24000,vehicles={},events={},anomalies={},
            count={},reports=0,frame=0,steps={},physical=nil,complete=nil,
            signatures={},errors=0}
    end
    return c.devLab
end
local function event(c,code,detail,key,repeatable)
    local l=lab(c)
    local sig=tostring(code)..':'..tostring(key or '')
    if not repeatable and l.signatures[sig] then return end
    l.signatures[sig]=true
    l.count[code]=(l.count[code] or 0)+1
    local row={time=math.floor(l.clock/1000),code=code,detail=say(detail),key=key or '-'}
    l.events[#l.events+1]=row
    while #l.events>D.MAX_EVENTS do table.remove(l.events,1) end
    if FMABlackBox and FMABlackBox.event then pcall(FMABlackBox.event,c,'devLab.'..code,row.key,row.detail) end
end
local function gameOwner(c,v)
    if not v or not FMAUtil or not FMAUtil.owner then return false end
    local ok,value=pcall(FMAUtil.owner,v)
    return ok and value==c.farmId
end
local function controlled(c,r)
    if FMAControlAuthority and FMAControlAuthority.snapshot then
        local ok,result=pcall(FMAControlAuthority.snapshot,c,r)
        if ok and result then return result end
    end
    return {mode='UNKNOWN',ai=sensor(r.object,'getIsAIActive')==true,
        reservedBy=c.reservations and c.reservations[r.key]}
end
local function nearestTool(c,v)
    local x,z=pos(v)
    local best=math.huge;local label='-';local toolObj=nil
    for _,item in pairs(c.loose or {}) do
        local object=item.object
        local tx,tz=pos(object)
        local d=range(x,z,tx,tz)
        if d<best then best=d;label=item.name or item.key;toolObj=object end
    end
    return best,label,toolObj
end
function D.sample(c)
    local l=lab(c);l.frame=l.frame+1
    local inventory={};local aiCount=0;local players=0
    for _,r in ipairs(c.vehicles or {}) do
        if r and r.key and r.object and not r.object.isDeleted then
            local v=r.object;local x,z=pos(v)
            local authority=controlled(c,r)
            local engine=sensor(v,'getIsMotorStarted')
            local s={time=l.clock,x=x,z=z,mode=authority.mode or 'UNKNOWN',
                engine=engine,ai=authority.ai==true,cp=authority.courseplay==true,
                reserved=authority.reservedBy,work=authority.jobId,
                attachments=entries(sensor(v,'getAttachedImplements') or {})}
            inventory[#inventory+1]={name=r.name or r.key, key=r.key, s=s}
            if s.ai then aiCount=aiCount+1 end
            if authority.player then players=players+1 end
            local prev=l.vehicles[r.key]
            if prev and x and z and prev.x and prev.z then
                local travel=range(x,z,prev.x,prev.z)
                local dt=(l.clock-prev.time)/1000
                if (s.ai or s.mode=='FMA_OWN' or s.mode=='AI_PENDING') and not authority.player then
                    if travel<0.18 then s.stillSince=prev.stillSince or l.clock
                    else s.stillSince=l.clock end
                    local idle=(l.clock-s.stillSince)/1000
                    if idle>=15 and (not prev.lastStallAt or (l.clock-prev.lastStallAt)>60000) then
                        event(c,'STALLED','AI='..say(s.ai)..' cp='..say(s.cp)..' motor='..say(engine)
                            ..' owner='..say(s.mode)..' pausedFor='..math.floor(idle)..'s x='..say(x)..' z='..say(z)
                            ..' job='..say(s.work),r.key,true)
                        s.lastStallAt=l.clock
                    else s.lastStallAt=prev.lastStallAt end
                end
                if s.ai and engine==false and dt>=1 then
                    s.engineOffSince=(prev.engineOffSince or l.clock)
                    if l.clock-s.engineOffSince>7000 then
                        event(c,'AI_ENGINE_OFF','AI engaged but engine remains OFF x='..say(x)..' z='..say(z),r.key)
                    end
                end
            end
            if s.mode=='PLAYER' and (s.ai or s.reserved~=nil and s.reserved~='__FMA_DEVLAB__') then
                event(c,'PLAYER_CONFLICT','Player owns wheels but AI/reservation persists: '..say(s.reserved),r.key)
            end
            if s.mode=='FMA_OWN' and authority.jobCount and authority.jobCount>0 then
                event(c,'DOUBLE_CONTROL','Direct driver and native AI job overlap: '..say(s.work),r.key)
            end
            l.vehicles[r.key]=s
        end
    end
    if entries(c.parkingBays)==0 then event(c,'NO_PARKING_BAYS','No verified parking bays; return-to-home cannot be accepted as a completed parking manoeuvre','farm') end
    for id,task in pairs(c.tasks or {}) do
        if task and task.state=='blocked' and not l.signatures['BLOCKED_TASK:'..tostring(id)] then
            event(c,'BLOCKED_TASK',say(task.label)..' reason='..say(task.reason)..' operation='..say(task.operation),id)
        end
    end
    if l.frame%5==0 then
        event(c,'HEARTBEAT','vehicles='..#inventory..' ai='..aiCount..' player='..players
            ..' active='..entries(c.active)..' reserved='..entries(c.reservations)
            ..' tools='..entries(c.loose)..' auto='..say(c.settings and c.settings.enabled), 'heartbeat:'..math.floor(l.clock/10000),true)
    end
end
local function physicalEnd(c,passed,reason)
    local l=lab(c);local t=l.physical
    if not t then return end
    local v=t.vehicle
    l.physical=nil
    if c.reservations and c.reservations[t.key]=='__FMA_DEVLAB__' then c.reservations[t.key]=nil end
    if t.record then t.record.busy=t.priorBusy end
    local player=(FMAGameNative and FMAGameNative.isManuallyControlled
        and v and not v.isDeleted and FMAGameNative.isManuallyControlled(v)) or false
    if not player and v and not v.isDeleted and not sensor(v,'getIsAIActive') then
        if AIVehicleUtil and AIVehicleUtil.driveInDirection then
            pcall(AIVehicleUtil.driveInDirection,v,16,30,0,0,20,false,true,0,1,0,0.45)
        end
        if t.startedMotor and type(v.stopMotor)=='function' then pcall(v.stopMotor,v) end
    end
    local result=(passed and 'PASS' or 'FAIL')..' | '..say(reason)
    l.complete=result
    event(c,passed and 'DRIVE_PASS' or 'DRIVE_FAIL',result,t.key,true)
    if c.notify then pcall(c.notify,c,'DEV TEST '..result) end
end
function D.stop(c)
    local l=lab(c)
    if l.physical then physicalEnd(c,false,'Zastaveno majitelem') end
end
function D.beginPhysical(c)
    local l=lab(c)
    if l.physical then return false,'Zkouška již běží' end
    if not c.initialized or c.runtimePaused then return false,'Manager se ještě inicializuje nebo je pozastaven' end
    if c.settings and c.settings.enabled then return false,'Nejprve vypnout AUTO (Alt+H)' end
    if entries(c.active)>0 or entries(c.ownDriveSessions)>0 then return false,'Nejdříve nechat jiné pracovníky zastavit' end
    if not AIVehicleUtil or type(AIVehicleUtil.driveInDirection)~='function' or g_server==nil then
        return false,'GIANTS physical AI drive API nedostupné' end
    if entries(c.parkingFacilities)==0 then
        return false,'Chybí geometrie budov pro bezpečnostní kontrolu okolí'
    end
    local candidates={}
    for _,r in ipairs(c.vehicles or {}) do
        local v=r.object
        if v and not v.isDeleted and v.rootNode and v.isServer~=false
            and v.spec_motorized and v.spec_drivable
            and not r.busy and not (c.excluded and c.excluded[r.key])
            and gameOwner(c,v) and not sensor(v,'getIsAIActive')
            and not (c.reservations and c.reservations[r.key])
            and not (FMAGameNative and FMAGameNative.isManuallyControlled
                and FMAGameNative.isManuallyControlled(v))
            and type(v.startMotor)=='function' and type(v.getIsMotorStarted)=='function' then
            local x,z=pos(v)
            if x and z and entries(sensor(v,'getAttachedImplements') or {})==0 then
                local safe=true;local clearance=math.huge
                for _,other in ipairs(c.vehicles or {}) do
                    if other.object and other.object~=v then
                        local tx,tz=pos(other.object);clearance=math.min(clearance,range(x,z,tx,tz))
                    end
                end
                -- Facility centres are NOT validated entrance or manoeuvring points.
                -- Prevent motion near any known structure instead of trusting a root node.
                for _,site in pairs(c.parkingFacilities or {}) do
                    if type(site)=='table' then
                        local sx=site.x or site.posX;local sz=site.z or site.posZ
                        clearance=math.min(clearance,range(x,z,sx,sz))
                    end
                end
                if clearance>=25 then candidates[#candidates+1]={record=r,vehicle=v,x=x,z=z,clearance=clearance} end
            end
        end
    end
    table.sort(candidates,function(a,b) return a.clearance>b.clearance end)
    local chosen=candidates[1]
    if not chosen then
        event(c,'DRIVE_SKIP','No idle owned tractor in a sufficiently clear area (>=25m from known structures/vehicles). Test does NOT move machines.','farm',true)
        return false,'Nenalezen bezpečný volný traktor mimo dvůr – fyzický test přeskočen, pasivní testy běží'
    end
    local v=chosen.vehicle
    local t={key=chosen.record.key,record=chosen.record,vehicle=v,originX=chosen.x,originZ=chosen.z,
        started=l.clock,stage='engine',stageAt=l.clock,priorBusy=chosen.record.busy,
        startedMotor=sensor(v,'getIsMotorStarted')~=true,initialClearance=chosen.clearance}
    l.physical=t
    c.reservations=c.reservations or {};c.reservations[t.key]='__FMA_DEVLAB__'
    chosen.record.busy=true
    event(c,'DRIVE_BEGIN','TEST COPY ONLY: '..say(chosen.record.name)..' clearance='..math.floor(chosen.clearance)
        ..'m; staged motor -> 1.4m forward -> reverse -> stop',t.key,true)
    if t.startedMotor then
        local ok,err=pcall(v.startMotor,v,true)
        if not ok then physicalEnd(c,false,'startMotor exception: '..say(err));return false,say(err) end
    end
    return true,'Zkouším motor, jízdu a couvání na '..say(chosen.record.name)
end
function D.physicalUpdate(c,dt)
    local l=lab(c);local t=l.physical
    if not t then return end
    local v=t.vehicle
    if not v or v.isDeleted or t.record.object~=v or c.settings.enabled or c.shuttingDown then
        physicalEnd(c,false,'Objekt změněn nebo byla zapnuta automatika');return
    end
    if FMAGameNative and FMAGameNative.isManuallyControlled and FMAGameNative.isManuallyControlled(v) then
        physicalEnd(c,false,'Hráč převzal řízení – test přerušen');return
    end
    if sensor(v,'getIsAIActive') or c.reservations[t.key]~='__FMA_DEVLAB__' then
        physicalEnd(c,false,'Kolize řízení s další AI');return
    end
    local x,z=pos(v)
    if not x or range(x,z,t.originX,t.originZ)>4.5 or l.clock-t.started>45000 then
        physicalEnd(c,false,'Neplatná poloha / překročen prostor či čas testu');return
    end
    if t.stage=='engine' then
        if sensor(v,'getIsMotorStarted')==true then
            t.stage='forward';t.stageAt=l.clock
            event(c,'ENGINE_PASS','Motor physically reports running',t.key,true)
        elseif l.clock-t.stageAt>9000 then physicalEnd(c,false,'Motor did not report running within 9 s') end
    elseif t.stage=='forward' or t.stage=='reverse' then
        local dist=range(x,z,t.originX,t.originZ)
        if t.stage=='forward' and dist>=1.35 then
            event(c,'FORWARD_PASS','Displacement='..string.format('%.2f',dist)..' m',t.key,true)
            t.stage='reverse';t.stageAt=l.clock
        elseif t.stage=='reverse' and dist<=0.55 then
            physicalEnd(c,true,'Motor + actual forward displacement + reverse return confirmed')
            return
        elseif l.clock-t.stageAt>13000 then
            physicalEnd(c,false,t.stage..' stalled; displacement='..string.format('%.2f',dist)..' m')
            return
        end
        if l.physical then
            local forward=t.stage=='forward'
            -- Request ONLY straight low-speed physically simulated motion.
            local ok,err=pcall(AIVehicleUtil.driveInDirection,v,math.max(1,math.min(dt or 16,120)),
                30,0.25,0.14,20,true,forward,0,forward and 1 or -1,1.5,0.5)
            if not ok then physicalEnd(c,false,'GIANTS driveInDirection failed: '..say(err)) end
        end
    end
end
function D.update(c,dt)
    local l=lab(c)
    l.clock=l.clock+math.max(0,math.min(tonumber(dt) or 0,1000))
    if not c.initialized or not g_currentMission or not g_currentMission.isRunning then return end
    D.physicalUpdate(c,dt)
    if l.clock>=l.nextSample then
        l.nextSample=l.clock+D.SAMPLE_MS
        D.sample(c)
    end
    if l.clock>=l.nextReport and not c.shuttingDown then
        l.nextReport=l.clock+D.REPORT_MS
        -- Only one automatically updated report. No need for player to press Alt+D.
        if FMASupportReport and FMASupportReport.export then
            -- Refresh a CURRENT snapshot even while normal AUTO is disabled.
            if c.diagnostics then pcall(c.diagnostics,c,true) end
            local diagnostic=c.lastDiagnosticText
            local ok,report=pcall(FMASupportReport.export,c,diagnostic or '[not generated yet]')
            if ok and report and report.ok then l.reports=l.reports+1
            else l.errors=l.errors+1 end
        end
    end
end
function D.report(c)
    local l=lab(c)
    local lines={'FMA DEVELOPMENT LAB '..D.VERSION,
        'TEMPORARY. PASSIVE sampling auto-starts. PHYSICAL test requires explicit selection on a DUPLICATE save.',
        'Physical test is NOT an automatic proof of hitching, bunker work, fieldwork, or safe obstacle avoidance.',
        'Does NOT load engine log (FS25 Lua sandbox limitation). Separate log.txt may still be needed.',
        'uptimeSeconds='..math.floor(l.clock/1000)..' samples='..l.frame..' autoExports='..l.reports..
            ' exportErrors='..l.errors..' activePhysical='..tostring(l.physical and l.physical.stage or false),
        'lastPhysical='..say(l.complete), 'observerError='..say(c.devLabError), '--- aggregate events ---'}
    local keys={};for k in pairs(l.count) do keys[#keys+1]=k end;table.sort(keys)
    for _,k in ipairs(keys) do lines[#lines+1]=k..'='..l.count[k] end
    lines[#lines+1]='--- assembly physical progress and bounded retry circuit ---'
    for taskId,gate in pairs(c.assemblyCircuits or {}) do
        lines[#lines+1]=table.concat({say(taskId),'rig='..say(gate.signature),
            'failedApproaches='..say(gate.failures),'halted='..say(gate.halted),
            'initialXY='..say(gate.startedX)..','..say(gate.startedZ)},' | ')
    end
    lines[#lines+1]='--- current vehicle snapshot (real sensor observations) ---'
    for _,r in ipairs(c.vehicles or {}) do
        local s=l.vehicles[r.key]
        if s then
            lines[#lines+1]=table.concat({say(r.key),say(r.name),
                'xy='..say(s.x)..','..say(s.z),'mode='..say(s.mode),
                'ai='..say(s.ai),'cp='..say(s.cp),'engine='..say(s.engine),
                'reservation='..say(s.reserved),'job='..say(s.work),
                'implements='..say(s.attachments)},' | ')
        end
    end
    lines[#lines+1]='--- event timeline (seconds from load) ---'
    for _,row in ipairs(l.events) do
        lines[#lines+1]=row.time..' | '..row.code..' | '..say(row.key)..' | '..say(row.detail)
    end
    return table.concat(lines,'\n')..'\n'
end
