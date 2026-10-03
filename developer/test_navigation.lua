return function(test,eq)
local function makeRecord(x,z)
    local v={ownerFarmId=1,posX=x or 0,posZ=z or 0,rootNode=11}
    local r={key='tractorNav1',name='Zetor NAV',object=v}
    return r,v
end
local function make()
    return {farmId=1,now=0,settings={navigationLearning=true,reverseRecovery=true,maxRecoveryCycles=3},vehicles={},active={},reservations={},tasks={},navigationMap={routes={},hazards={}}}
end
local function leg(c,r)
    return {vehicle=r,job={isRunning=true},task={id='route:test',kind='route'},trafficTarget={x=28,z=0,tolerance=8},navSamples={}}
end
local function sample(c,a,x,z,now)
    c.now=now;a.vehicle.object.posX=x;a.vehicle.object.posZ=z
    FMANavigation.sample(c,a)
end

test('navigation watches real displacement, not steering animation or spinning wheels',function()
    local c=make();local r=makeRecord(0,0);local a=leg(c,r)
    for i=1,15 do sample(c,a,0,0,i*2000) end
    eq(#a.navSamples,1)
    eq(FMANavigation.finish(c,a,'success'),false)
    eq(FMANavigation.summary(c).routes,0)
end)

test('navigation records physically traversed samples but only upon confirmed arrival',function()
    local c=make();local r=makeRecord(0,0);local a=leg(c,r)
    for i=0,4 do sample(c,a,i*7,0,2000+i*2200) end
    eq(#a.navSamples,5)
    eq(FMANavigation.finish(c,a,'success'),true)
    local s=FMANavigation.summary(c)
    eq(s.routes,1);eq(s.learned,1)
    local row=next(c.navigationMap.routes)
    assert(row~=nil)
    for _,route in pairs(c.navigationMap.routes) do
        assert(route.metres>=25)
        eq(route.finish.x,28)
    end
end)

test('navigation never learns failed AI job even if vehicle happens to be at destination',function()
    local c=make();local r=makeRecord(0,0);local a=leg(c,r)
    for i=0,4 do sample(c,a,i*7,0,2000+i*2200) end
    eq(FMANavigation.finish(c,a,'error'),false)
    eq(FMANavigation.summary(c).routes,0)
end)

test('navigation never learns successful AI stop distant from desired target',function()
    local c=make();local r=makeRecord(0,0);local a=leg(c,r)
    for i=0,4 do sample(c,a,i*7,0,2000+i*2200) end
    a.trafficTarget={x=100,z=0,tolerance=8}
    eq(FMANavigation.finish(c,a,'success'),false)
    eq(FMANavigation.summary(c).routes,0)
end)

test('navigation does not reward manually overridden or stopped jobs',function()
    local c=make();local r=makeRecord(0,0);local a=leg(c,r)
    for i=0,4 do sample(c,a,i*7,0,2000+i*2200) end
    a.stopReason='PLAYER_TAKEOVER';a.playerTakeover=true
    eq(FMANavigation.finish(c,a,'success'),false)
    eq(FMANavigation.summary(c).learned,0)
end)

test('navigation keeps only bounded repeated confirmed route entry',function()
    local c=make();local r=makeRecord(0,0)
    for trip=1,3 do
        local a=leg(c,r)
        for i=0,4 do sample(c,a,i*7,0,2000+i*2200+trip*20000) end
        eq(FMANavigation.finish(c,a,'success'),true)
    end
    eq(FMANavigation.summary(c).routes,1)
    for _,r0 in pairs(c.navigationMap.routes) do eq(r0.uses,3) end
end)

test('navigation hazard makes independent routing preferable',function()
    local c=make();local r=makeRecord(32,30);local a=leg(c,r)
    FMANavigation.hazard(c,a,'OBSTACLE')
    eq(FMANavigation.summary(c).hazards,1)
    eq(FMANavigation.preferAlternative(c,r,{x=85,z=85}),true)
end)

test('navigation declines unverified shortcut beyond actual job arrival tolerance',function()
    local c=make();local r=makeRecord(0,0);local a=leg(c,r)
    for i=0,4 do sample(c,a,i*7,0,2000+i*2200) end
    FMANavigation.finish(c,a,'success')
    local alt=FMANavigation.verifiedDestination(c,r,{x=28,z=0,tolerance=8})
    assert(alt~=nil and math.abs(alt.x-28)<0.1)
    eq(FMANavigation.verifiedDestination(c,r,{x=140,z=90,tolerance=8}),nil)
end)

test('reverse clearance fails closed when FS25 collision physics is unavailable',function()
    local c=make();local r=makeRecord(2,3);c.vehicles={r}
    local old=raycastAll;raycastAll=nil
    local ok=FMANavigation.reverseClear(c,r,3)
    eq(ok,false);raycastAll=old
end)

test('reverse clearance refuses any mechanically attached tool',function()
    local c=make();local r,v=makeRecord(2,3);c.vehicles={r}
    v.getAttachedImplements=function()return {{object={}}} end
    local old={ray=raycastAll,world=localDirectionToWorld,pos=getWorldTranslation,terrain=getTerrainHeightAtWorldPos,mission=g_currentMission}
    raycastAll=function()end;localDirectionToWorld=function(_,x,y,z)return x,y,z end
    getWorldTranslation=function()return 2,0,3 end
    getTerrainHeightAtWorldPos=function()return 0 end
    g_currentMission={terrainRootNode=1}
    local ok,why=FMANavigation.reverseClear(c,r,3)
    eq(ok,false);assert(why:find('nářadím',1,true))
    raycastAll=old.ray;localDirectionToWorld=old.world;getWorldTranslation=old.pos;getTerrainHeightAtWorldPos=old.terrain;g_currentMission=old.mission
end)

test('reverse clearance rejects raycast obstacle behind vehicle',function()
    local c=make();local r,v=makeRecord(2,3);c.vehicles={r}
    local old={ray=raycastAll,world=localDirectionToWorld,terrain=getTerrainHeightAtWorldPos,mission=g_currentMission}
    localDirectionToWorld=function(_,x,y,z)return x,y,z end
    getTerrainHeightAtWorldPos=function()return 0 end
    g_currentMission={terrainRootNode=1}
    raycastAll=function(x,y,z,dx,dy,dz,d,method,obj)
        obj[method](obj,99,x+dx,y+dy,z+dz,2,dx,dy,dz)
    end
    local ok=FMANavigation.reverseClear(c,r,3)
    eq(ok,false)
    raycastAll=old.ray;localDirectionToWorld=old.world;getTerrainHeightAtWorldPos=old.terrain;g_currentMission=old.mission
end)

test('reverse clearance rejects live player tractor standing behind',function()
    local c=make();local r,v=makeRecord(2,3);local r2=makeRecord(2,0);c.vehicles={r,r2}
    local old={ray=raycastAll,world=localDirectionToWorld,terrain=getTerrainHeightAtWorldPos,mission=g_currentMission}
    localDirectionToWorld=function(_,x,y,z)return x,y,z end
    getTerrainHeightAtWorldPos=function()return 0 end
    g_currentMission={terrainRootNode=1}
    raycastAll=function()end
    local ok,why=FMANavigation.reverseClear(c,r,3)
    eq(ok,false);assert(why:find('vozidlo',1,true))
    raycastAll=old.ray;localDirectionToWorld=old.world;getTerrainHeightAtWorldPos=old.terrain;g_currentMission=old.mission
end)

test('reverse clearance probes all six lanes when unoccupied and known flat',function()
    local c=make();local r=makeRecord(2,3);c.vehicles={r}
    local old={ray=raycastAll,world=localDirectionToWorld,terrain=getTerrainHeightAtWorldPos,mission=g_currentMission}
    localDirectionToWorld=function(_,x,y,z)return x,y,z end
    getTerrainHeightAtWorldPos=function()return 0 end
    g_currentMission={terrainRootNode=1}
    local calls=0;raycastAll=function()calls=calls+1 end
    local ok=FMANavigation.reverseClear(c,r,3)
    eq(ok,true);eq(calls,6)
    raycastAll=old.ray;localDirectionToWorld=old.world;getTerrainHeightAtWorldPos=old.terrain;g_currentMission=old.mission
end)

test('escape job uses physics-checked reverse and maintains exclusive tractor reservation',function()
    local c=make();local r=makeRecord(0,0);c.vehicles={r};c.now=10000
    local task={kind='route',id='abc',state='running'}
    local a={task=task,vehicle=r,trafficTarget={x=100,z=0}}
    local old={clear=FMANavigation.reverseClear,ai=FMAAI.createTransferJob,start=FMAJobs.start,world=localDirectionToWorld,mission=g_currentMission}
    FMANavigation.reverseClear=function()return true,'PROBE_CLEAR' end
    localDirectionToWorld=function(_,x,y,z)return x,y,z end
    local job={isRunning=true};FMAAI.createTransferJob=function(_,_,target)assert(target.recoveryReverse);return job,nil,'CP_SAFE_REVERSE' end
    FMAJobs.start=function()return nil end
    g_currentMission={aiSystem={}}
    local ok=FMANavigation.beginEscape(c,a)
    eq(ok,true);eq(c.reservations[r.key],'navigationEscape:abc');eq(c.active[job].task.kind,'navigationEscape')
    eq(task.navReverseAttempts,1)
    local again=FMANavigation.beginEscape(c,a);eq(again,false)
    FMANavigation.reverseClear=old.clear;FMAAI.createTransferJob=old.ai;FMAJobs.start=old.start;localDirectionToWorld=old.world;g_currentMission=old.mission
end)

test('navigation classifies Czech engine obstacle message as recoverable route problem',function()
    local category,temporary=FMAExperience.classify('V cestě brání objekt')
    eq(category,'ROUTE');eq(temporary,true)
    eq(select(1,FMAExperience.classify('Zablokované · kola se točí ale stojím')),'ROUTE')
end)

test('navigation raycast callback never stops before second hidden obstacle',function()
    local r=makeRecord(0,0)
    FMANavigation._probeVehicle=r.object
    FMANavigation._probeBlocked=false
    local keep=FMANavigation:raycastHit(0,0,0,0)
    eq(keep,false)
    local keep2=FMANavigation:raycastHit(9021,0,0,0)
    eq(keep2,false);eq(FMANavigation._probeBlocked,true)
    FMANavigation._probeVehicle=nil;FMANavigation._probeBlocked=nil
end)

test('navigation recovery requires confirmed success for physically driven escape',function()
    local c=make();local r=makeRecord(4,0)
    local task={id='base',kind='route'};c.tasks[task.id]=task
    local original={vehicle=r,task=task,stopReason='NAV_REVERSE'}
    local escaping={vehicle=r,task={kind='navigationEscape',originalActive=original},escapeOrigin={x=0,z=0},outcome='unknown'}
    local old=FMARecovery.onStopped;local observed
    FMARecovery.onStopped=function(_,a)observed=a.stopReason end
    FMANavigation.escapeStopped(c,escaping)
    eq(FMANavigation.summary(c).escapes,0)
    eq(observed,'RECOVERY_REROUTE')
    FMARecovery.onStopped=old
end)

test('navigation summary and traced path persist across native-style XML reload',function()
    local before={mission=g_currentMission,xml=XMLFile,schema=XMLSchema,types=XMLValueType,exists=fileExists,cached=FMAState.schema}
    local written={}
    g_currentMission={missionInfo={savegameDirectory='/example/savegame'},isRunning=true}
    XMLValueType={STRING=1,BOOL=2,FLOAT=3,INT=4}
    XMLSchema={new=function()return {register=function()end}end}
    FMAState.schema=nil;fileExists=function()return true end
    local function handle()
        return {setValue=function(_,k,v)written[k]=v end,
            getValue=function(_,k,default)if written[k]==nil then return default end return written[k] end,
            hasProperty=function(_,k)for key in pairs(written) do if string.sub(key,1,#k)==k then return true end end return false end,
            save=function()end,delete=function()end}
    end
    XMLFile={create=handle,load=handle}
    local c=make();c.initialized=true;c.supported=true
    c.policies={};c.excluded={};c.routes={};c.forageStages={};c.learnedPoints={};c.learnedRoutes={}
    local r=makeRecord(0,0);local a=leg(c,r)
    for i=0,4 do sample(c,a,i*7,0,2000+i*2200) end
    FMANavigation.finish(c,a,'success')
    c.now=10000;FMANavigation.hazard(c,a,'WALL')
    c.navigationMap.escapes=2
    FMAState.save(c)
    local restored=FMAState.load()
    eq(restored.navigationMap.learned,1)
    eq(restored.navigationMap.escapes,2)
    eq(restored.navigationMap.failures,1)
    eq(FMANavigation.summary(restored).routes,1)
    eq(FMANavigation.summary(restored).hazards,1)
    for _,route in pairs(restored.navigationMap.routes) do
        assert(#route.points>=2)
        eq(route.finish.x,28)
        eq(route.target.x,28)
    end
    g_currentMission=before.mission;XMLFile=before.xml;XMLSchema=before.schema;XMLValueType=before.types;fileExists=before.exists;FMAState.schema=before.cached
end)

test('navigation console keeps consistent layout even without global controller',function()
    local c=make();c.settings.hudPosition=1
    FMAHud._controller=c
    local x=FMAHud.layout(false)
    eq(x,0.225)
    c.settings.hudPosition=2;eq(FMAHud.layout(false),0.026)
    c.settings.hudPosition=0;eq(FMAHud.layout(false),0.414)
    FMAHud._controller=nil
end)

end
