-- Observed navigation truth. A driven track is not a global navmesh; only
-- successful engine-confirmed arrivals become reusable route evidence.
-- No physics teleports, forced velocity changes, blind obstacle bypass or
-- ownership violations. Optional 3-lane reverse probe fails CLOSED.
FMANavigation={VERSION='0.20.16.0',CELL=16,MAX_ROUTES=32,MAX_HAZARDS=90}

local function sq(a,b) local x,z=(a.x-b.x),(a.z-b.z);return x*x+z*z end
local function point(o) local x,z=FMAUtil.position(o);if x and z then return {x=x,z=z} end end
local function cell(p) return math.floor(p.x/FMANavigation.CELL)..':'..math.floor(p.z/FMANavigation.CELL) end
local function length(points)
    local d=0
    for i=2,#points do d=d+math.sqrt(sq(points[i],points[i-1])) end
    return d
end
local function validPoint(p)
    return p and type(p.x)=='number' and type(p.z)=='number'
        and p.x==p.x and p.z==p.z and math.abs(p.x)<100000 and math.abs(p.z)<100000
end
local function nav(c)
    c.navigationMap=c.navigationMap or {routes={},hazards={},learned=0,failures=0,escapes=0,lastEvent=''}
    local n=c.navigationMap
    n.routes=n.routes or {};n.hazards=n.hazards or {}
    return n
end
function FMANavigation.summary(c)
    local n=nav(c);local safe=0;local danger=0
    for _ in pairs(n.routes) do safe=safe+1 end
    for _ in pairs(n.hazards) do danger=danger+1 end
    return {routes=safe,hazards=danger,learned=n.learned or 0,failures=n.failures or 0,escapes=n.escapes or 0,last=n.lastEvent or ''}
end
function FMANavigation.sample(c,a)
    if not c or not a or not a.vehicle or not a.vehicle.object or not a.trafficTarget or not c.settings or (c.settings.navigationLearning==false and c.settings.surveyEnabled==false) then return end
    if not a.job or a.job.isRunning~=true then return end
    local now=c.now or 0
    if now-(a.navLastSample or -100000)>=1000 then
        a.navLastSample=now
        local p=point(a.vehicle.object)
        if not validPoint(p) then return end
        local samples=a.navSamples or {};a.navSamples=samples
        if #samples==0 or sq(samples[#samples],p)>=6*6 then
            if #samples<100 then samples[#samples+1]=p
            else table.remove(samples,2);samples[#samples+1]=p end
        end
    end
end
function FMANavigation.hazard(c,a,reason)
    if not a or not a.vehicle or not a.vehicle.object then return end
    local p=point(a.vehicle.object)
    if not validPoint(p) then return end
    local n=nav(c);local k=cell(p)
    local row=n.hazards[k] or {x=p.x,z=p.z,failures=0}
    row.x=p.x;row.z=p.z;row.failures=math.min(20,row.failures+1)
    row.reason=tostring(reason or 'NO_MOTION'):sub(1,95)
    row.age=c.now or 0;n.hazards[k]=row
    n.failures=(n.failures or 0)+1;n.lastEvent='NEPRŮJEZDNÉ '..k..' · '..row.reason
    local count=0;for _ in pairs(n.hazards) do count=count+1 end
    if count>FMANavigation.MAX_HAZARDS then
        local oldest,t=nil,math.huge
        for key,h in pairs(n.hazards) do if (h.age or 0)<t then oldest,t=key,h.age or 0 end end
        if oldest then n.hazards[oldest]=nil end
    end
    c.diagnosticDirty=true
    if FMAFarmSurvey and FMAFarmSurvey.markHazard then FMAFarmSurvey.markHazard(c,p) end
    if FMADiagnostics then FMADiagnostics.event(c,'navigation.hazard',a.vehicle.name or '?',k..' '..row.reason) end
end
function FMANavigation.finish(c,a,outcome)
    if not a or not a.trafficTarget or not a.vehicle or not a.vehicle.object then return false end
    local p=point(a.vehicle.object);local dest=a.trafficTarget
    if not validPoint(p) or not validPoint(dest) then return false end
    local tol=math.max(4,math.min(17,tonumber(dest.tolerance or (a.task and a.task.tolerance)) or 9))
    local reached=sq(p,dest)<=tol*tol
    if outcome~='success' or not reached or a.stopReason or a.playerTakeover then
        if not reached and outcome~='success' and not a.playerTakeover then
            if FMAJobs and FMAJobs.isNavigationEvidence(a,a.stopReason) then
                FMANavigation.hazard(c,a,a.stopReason or 'AI_ROUTE_FAIL')
            else
                local n=nav(c);n.dispatchFailures=(n.dispatchFailures or 0)+1
                if FMADiagnostics then FMADiagnostics.event(c,'navigation.startNotRouteEvidence',a.vehicle.name or '?',tostring(a.stopReason or outcome)) end
            end
        end
        return false
    end
    if not c.settings or c.settings.navigationLearning==false then
        if FMAFarmSurvey and FMAFarmSurvey.confirmTransfer then FMAFarmSurvey.confirmTransfer(c,a) end
        return true
    end
    local n=nav(c);local pts=a.navSamples or {}
    if #pts==0 then return true end
    if sq(pts[#pts],p)>1 then pts[#pts+1]=p end
    if #pts<2 or length(pts)<12 then
        if FMAFarmSurvey and FMAFarmSurvey.confirmTransfer then FMAFarmSurvey.confirmTransfer(c,a) end
        return true
    end
    -- Keyed by start/end cells so a near duplicate is replaced, not multiplied.
    local k=cell(pts[1])..'>'..cell(dest)
    local old=n.routes[k]
    local new={key=k,from=pts[1],target={x=dest.x,z=dest.z},finish={x=p.x,z=p.z},points={},metres=length(pts),uses=(old and old.uses or 0)+1,vehicle=a.vehicle.key,footprint=(FMAFarmSurvey and FMAFarmSurvey.classify(a.vehicle.object) or 'UNKNOWN'),method=a.transferMethod or 'AI',age=c.now or 0}
    for i=1,#pts,math.max(1,math.ceil(#pts/96)) do new.points[#new.points+1]=pts[i] end
    if #new.points==0 or sq(new.points[#new.points],p)>1 then new.points[#new.points+1]=p end
    n.routes[k]=new;n.learned=(n.learned or 0)+1
    local h=n.hazards[cell(p)];if h then h.failures=math.max(0,(h.failures or 1)-1);if h.failures==0 then n.hazards[cell(p)]=nil end end
    local count=0;for _ in pairs(n.routes) do count=count+1 end
    if count>FMANavigation.MAX_ROUTES then
        local oldest,t=nil,math.huge
        for key,r in pairs(n.routes) do if (r.age or 0)<t then oldest,t=key,r.age or 0 end end
        if oldest then n.routes[oldest]=nil end
    end
    n.lastEvent='OVĚŘENÁ TRASA '..k..' · '..math.floor(new.metres)..'m';c.diagnosticDirty=true
    if FMAFarmSurvey and FMAFarmSurvey.confirmTransfer then FMAFarmSurvey.confirmTransfer(c,a) end
    if FMADiagnostics then FMADiagnostics.event(c,'navigation.routeVerified',a.vehicle.name or '?',n.lastEvent) end
    return true
end
function FMANavigation.preferAlternative(c,record,target)
    if not c or not record or not validPoint(target) then return false end
    local p=point(record.object)
    if not p then return false end
    local n=nav(c)
    local start=n.hazards[cell(p)]
    local finish=n.hazards[cell(target)]
    return (start and (start.failures or 0)>0) or (finish and (finish.failures or 0)>0) or false
end
-- Known successful finish points within original target tolerance can help CP
-- avoid parking a wheel exactly on a bad trigger; no untested waypoint is used.
function FMANavigation.verifiedDestination(c,record,target)
    if not c or not validPoint(target) then return nil end
    local n=nav(c);local from=point(record.object)
    if not from then return nil end
    local radius=math.min(math.max(tonumber(target.tolerance) or 6,4)*0.65,8)
    local best,score=nil,math.huge
    for _,r in pairs(n.routes) do
        if validPoint(r.finish) and validPoint(r.target) and sq(r.target,target)<20*20 and sq(r.finish,target)<=radius*radius
            and validPoint(r.from) and sq(r.from,from)<=70*70 and not n.hazards[cell(r.finish)] then
            local cost=sq(r.from,from)+sq(r.finish,target)
            if cost<score then best,score=r.finish,cost end
        end
    end
    return best and {x=best.x,z=best.z,angle=target.angle,tolerance=target.tolerance,preferCourseplay=true,probeRadius=target.probeRadius} or nil
end

local function ownActor(v,actor)
    for _,obj in ipairs(FMAWorld.children(v)) do
        for _,component in ipairs(obj.components or {}) do if component.node==actor then return true end end
        if obj.rootNode==actor then return true end
    end
    return false
end
function FMANavigation:raycastHit(actor,x,y,z,distance,nx,ny,nz,subShape,shape,isLast)
    if actor and actor~=0 and not ownActor(self._probeVehicle,actor) then self._probeBlocked=true end
    -- GDN FS25: returning true stops further collision callbacks. Keep inspecting
    -- other bodies, including a wall hidden behind our own collision shape.
    return false
end
-- Three height-separated strips. If physics query fails, lack of confirmation
-- is NOT clearance. No reversing with any attached implement or trailer.
function FMANavigation.reverseClear(c,record,metres)
    local self=FMANavigation
    local v=record and record.object
    if not v or not v.rootNode or not raycastAll or not localDirectionToWorld or not getWorldTranslation or not getTerrainHeightAtWorldPos then return false,'Chybí fyzikální měření prostoru' end
    if FMAUtil.owner(v)~=c.farmId or (FMAGameNative and FMAGameNative.isManuallyControlled(v)) then return false,'Stroj není pod řízením managera' end
    if #FMAWorld.operationalChildren(v)>1 then return false,'S připojeným nářadím se automaticky naslepo necouvá' end
    local ok,dx,_,dz=pcall(localDirectionToWorld,v.rootNode,0,0,-1)
    local pos=point(v);if not ok or not pos or not dx or not dz then return false,'Neznámý směr jízdy' end
    local m=math.sqrt(dx*dx+dz*dz);if m<0.5 then return false,'Neplatná orientace' end
    dx,dz=dx/m,dz/m
    local distance=math.max(2,math.min(4,metres or 3))
    local terrain=g_terrainNode or (g_currentMission and g_currentMission.terrainRootNode)
    if not terrain then return false,'Není načten terén' end
    local okY,y=pcall(getTerrainHeightAtWorldPos,terrain,pos.x,0,pos.z)
    local okE,y2=pcall(getTerrainHeightAtWorldPos,terrain,pos.x+dx*distance,0,pos.z+dz*distance)
    if not okY or not okE or not y or not y2 or math.abs(y2-y)>0.6 then return false,'Terén za strojem není ověřený / je příliš svažitý' end
    for _,other in ipairs(c.vehicles or {}) do
        if other.object~=v then
            local p=point(other.object)
            if p then
                local along=(p.x-pos.x)*dx+(p.z-pos.z)*dz
                local lateral=math.abs((p.x-pos.x)*dz-(p.z-pos.z)*dx)
                if along>-3 and along<distance+5 and lateral<5 then return false,'Za strojem stojí další vozidlo' end
            end
        end
    end
    self._probeVehicle=v;self._probeBlocked=false
    local safe=true
    -- Includes scene static objects such as sheds, poles and walls.
    for _,side in ipairs({-1.3,0,1.3}) do
        for _,height in ipairs({0.8,1.8}) do
            local px=pos.x+(-dz)*side;local pz=pos.z+dx*side
            local valid=pcall(raycastAll,px,y+height,pz,dx,0,dz,distance+1.5,'raycastHit',self)
            if not valid or self._probeBlocked then safe=false;break end
        end
        if not safe then break end
    end
    self._probeVehicle=nil;self._probeBlocked=nil
    return safe,safe and 'PROBE_CLEAR' or 'Fyzika zjistila překážku za strojem'
end
function FMANavigation.beginEscape(c,a)
    if not a or not a.vehicle or not a.vehicle.object or not a.task or not a.trafficTarget then return false,'Není to měřený přejezd' end
    if not c.settings or c.settings.reverseRecovery==false then return false,'Bezpečné couvání je vypnuté' end
    if (a.task.navReverseAttempts or 0)>=1 then return false,'Couvání už bylo zkoušeno' end
    local ok,reason=FMANavigation.reverseClear(c,a.vehicle,3.2)
    if not ok then return false,reason end
    local v=a.vehicle.object;local x,z=FMAUtil.position(v)
    local dx,_,dz=localDirectionToWorld(v.rootNode,0,0,-1)
    local tgt={x=x+dx*3.2,z=z+dz*3.2,tolerance=0.85,directApproach=true,recoveryReverse=true}
    local job,why,method=FMAAI.createTransferJob(c,a.vehicle,tgt)
    if not job then return false,why end
    a.task.navReverseAttempts=(a.task.navReverseAttempts or 0)+1
    local escape={id='navigationEscape:'..tostring(a.task.id),kind='navigationEscape',label='Bezpečné vyproštění',phase='COUVÁNÍ 3 M',state='running',originalTask=a.task,originalActive=a}
    c.active[job]={job=job,task=escape,vehicle=a.vehicle,start=c.now,lastProgress=c.now,x=x,z=z,fill=a.vehicle.fillTotal,trafficTarget=tgt,transferMethod=method,escapeOrigin={x=x,z=z}}
    c.reservations[a.vehicle.key]=escape.id;a.vehicle.busy=true
    local started,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,c.farmId)
    if not started then
        c.active[job]=nil;c.reservations[a.vehicle.key]=nil;a.vehicle.busy=false
        return false,err
    end
    a.task.phase='VYPROŠTĚNÍ · OVĚŘENÉ COUVÁNÍ';a.task.reason='Úzký prostor, ověřuji krátké couvnutí a novou trasu'
    if FMADiagnostics then FMADiagnostics.event(c,'navigation.reverseStart',a.task.id,a.vehicle.key) end
    return true
end
function FMANavigation.escapeStopped(c,a)
    local original=a.task and a.task.originalActive
    if not original then return true end
    local p=point(a.vehicle.object);local moved=p and a.escapeOrigin and math.sqrt(sq(p,a.escapeOrigin)) or 0
    if a.outcome=='success' and moved>=1.8 and not a.stopReason then
        local n=nav(c);n.escapes=(n.escapes or 0)+1
        n.lastEvent='VYPROŠTĚNÍ '..tostring(a.vehicle.name)..' · '..string.format('%.1f',moved)..'m'
        if FMADiagnostics then FMADiagnostics.event(c,'navigation.reverseConfirmed',original.task.id,n.lastEvent) end
    else
        if FMADiagnostics then FMADiagnostics.event(c,'navigation.reverseFailed',original.task.id,'moved='..tostring(moved)) end
    end
    original.stopReason='RECOVERY_REROUTE'
    if FMARecovery and FMARecovery.onStopped then FMARecovery.onStopped(c,original) end
    return true
end
function FMANavigation.writeDiagnostics(c,f)
    local n=nav(c);local s=FMANavigation.summary(c)
    f:write('\nOBSERVED NAVIGATION MAP routes=',s.routes,' hazards=',s.hazards,' successfulLegs=',s.learned,' failures=',s.failures,' reverses=',s.escapes,'\n')
    for k,h in pairs(n.hazards) do f:write('navHazard ',k,' count=',tostring(h.failures),' at=',tostring(h.x),',',tostring(h.z),' ',tostring(h.reason),'\n') end
    for k,r in pairs(n.routes) do f:write('navRoute ',k,' metres=',tostring(r.metres),' samples=',tostring(#(r.points or {})),' uses=',tostring(r.uses),'\n') end
end
