FMAState = {}
FMAState.defaults={enabled=false,selectedJobsOnly=false,autonomyDefaultApplied=false,maxWorkers=8,reserve=5000,scanSeconds=12,stallSeconds=300,
    maxAttempts=3,cropCare=true,preferCourseplay=true,supply=true,threshold=0.25,daylightOnly=false,
    livestock=true,productions=true,harvestTeams=true,bunkerAutomation=true,baleAutomation=true,trafficSafety=true,
    playerPriority=true,autoSellOutputs=false,foodTarget=0.70,foodEmergency=0.15,productionInputEmergency=0.10,
    feedForecastHours=18,beddingForecastHours=18,strawTarget=0.65,strawEmergency=0.15,waterTarget=0.60,feedLoadTimeoutSeconds=180,
    outputMoveAt=0.75,outputForecastHours=12,retainOrganicFertilizer=true,organicReserveTarget=0.35,
    sellWhenStoreAbove=0.90,priceSellThreshold=0.95,storageReservePercent=0.15,
    bunkerDeliveryAutomation=true,bunkerWaitDistance=12,bunkerFillTarget=0.90,bunkerNominalHeight=4.0,bunkerPrimaryIndex=0,bunkerNextIndex=0,bunkerPushSeconds=35,bunkerSettleSeconds=8,
    unloaderCall=0.80,maxUnloaders=3,unloaderLeadSeconds=30,unloaderApproachSpeed=7.5,
    defaultHaulCycleSeconds=360,harvestFieldWaitDistance=12,fieldStageRadius=180,fieldStageAttempts=5,bunkerTargetCompaction=0.98,autoAssemble=true,assemblyStagingDistance=10.0,autoAttachMaxDistance=6.0,
    attachAlignmentOffset=2.7,attachRetryDelaySeconds=4,trafficCellSize=18,trafficStartSeparation=14,trafficEmergencyDistance=8,trafficRetrySeconds=6,trafficMaxTransit=10,trafficLaunchIntervalSeconds=2.5,
    autoReturn=true,restoreImplements=true,parkTolerance=8,smartParking=true,
    refillBeforeWork=0.25,refillTarget=0.85,fuelBeforeWork=0.25,fuelTarget=0.90,refillArrivalTolerance=10,refillTimeoutSeconds=180,
    autoBuyConsumables=false,headerTransport=true,headerTransportMinWidth=6.0,headerFieldStagingDistance=22,headerMountWaitSeconds=8,
    precisionFieldwork=true,reliabilityFallback=true,coverageOverlapPercent=8,headlandSafetyFactor=1.35,minHeadlands=2,maxHeadlands=6,qualityAudit=true,
    windrowCourseReuse=true,autoForageChain=true,strawRecovery=true,forageMode=0,baleStorageAutomation=true,baleStorageTolerance=12,baleSortByFillType=true,baleStorageReserve=5,
    proactivePlanning=true,strategyMode=0,brainSeconds=5,roadSpeedEstimateMps=7.0,recoveryEnabled=true,recoveryProbeSeconds=20,recoveryRerouteSeconds=43,recoveryFailoverSeconds=85,navigationTimeoutSeconds=75,navigationLearning=true,reverseRecovery=true,surveyEnabled=true,surveyRadius=230,surveyViewRadius=180,hudPosition=0,maxRecoveryCycles=3,
    preventiveServiceDamage=0.60,criticalServiceDamage=0.85,autoService=true,serviceAtPreventiveIdle=true,serviceArrivalTolerance=12,learnedApproachRadius=35,teachRole=1,weatherPriority=true,ownerApprovalPurchases=true,performanceBudget=true}

function FMAState.getSchema()
    if FMAState.schema then return FMAState.schema end
    if XMLSchema==nil then return nil end
    local schema=XMLSchema.new("FarmManagerAI")
    schema:register(XMLValueType.INT,"farmManager#version","Format version",1)
    schema:register(XMLValueType.STRING,"farmManager#mapIdentity","Map identity of learned geometry")
    for key,value in pairs(FMAState.defaults) do
        local valueType=type(value)=="boolean" and XMLValueType.BOOL or XMLValueType.FLOAT
        schema:register(valueType,"farmManager.settings#"..key,key,value)
    end
    schema:register(XMLValueType.STRING,"farmManager.fields.field(?)#id","Field ID")
    schema:register(XMLValueType.BOOL,"farmManager.fields.field(?)#enabled","Managed field",true)
    schema:register(XMLValueType.STRING,"farmManager.fields.field(?)#crop","Next crop","")
    schema:register(XMLValueType.STRING,"farmManager.excluded.vehicle(?)#id","Manual vehicle ID")
    schema:register(XMLValueType.STRING,"farmManager.forage.field(?)#id","Forage field ID")
    schema:register(XMLValueType.STRING,"farmManager.forage.field(?)#stage","Forage workflow stage")
    schema:register(XMLValueType.STRING,"farmManager.routes.route(?)#vehicle","Route vehicle ID")
    for _,group in ipairs({"homes.vehicle","homes.tool"}) do
        schema:register(XMLValueType.STRING,"farmManager."..group.."(?)#id","Learned parking object ID")
        schema:register(XMLValueType.FLOAT,"farmManager."..group.."(?)#x","Parking X")
        schema:register(XMLValueType.FLOAT,"farmManager."..group.."(?)#z","Parking Z")
        schema:register(XMLValueType.FLOAT,"farmManager."..group.."(?)#angle","Parking angle")
    end
    for _,key in ipairs({'id','kind','role','site','driverKey','taughtFor','source','label'}) do
        schema:register(XMLValueType.STRING,'farmManager.parking.bay(?)#'..key,'Learned bay '..key)
    end
    for _,key in ipairs({'x','z','angle','width','length','driveX','driveZ','driveAngle'}) do
        schema:register(XMLValueType.FLOAT,'farmManager.parking.bay(?)#'..key,'Learned bay '..key)
    end
    for _,side in ipairs({"load","unload"}) do
        for _,axis in ipairs({"x","z","angle"}) do
            schema:register(XMLValueType.FLOAT,"farmManager.routes.route(?)."..side.."#"..axis,"Route point "..axis)
        end
    end
    schema:register(XMLValueType.STRING,"farmManager.learned.point(?)#id","Learned point ID")
    schema:register(XMLValueType.STRING,"farmManager.learned.point(?)#role","Learned point role")
    schema:register(XMLValueType.STRING,"farmManager.learned.point(?)#label","Learned point label")
    schema:register(XMLValueType.FLOAT,"farmManager.learned.point(?)#x","Learned point X")
    schema:register(XMLValueType.FLOAT,"farmManager.learned.point(?)#z","Learned point Z")
    schema:register(XMLValueType.FLOAT,"farmManager.learned.point(?)#angle","Learned point angle")
    schema:register(XMLValueType.FLOAT,"farmManager.learned.point(?)#radius","Learned point radius")
    schema:register(XMLValueType.STRING,"farmManager.learned.route(?)#id","Learned route ID")
    schema:register(XMLValueType.STRING,"farmManager.learned.route(?)#role","Learned route role")
    schema:register(XMLValueType.STRING,"farmManager.learned.route(?)#label","Learned route label")
    schema:register(XMLValueType.FLOAT,"farmManager.learned.route(?).waypoint(?)#x","Learned route X")
    schema:register(XMLValueType.FLOAT,"farmManager.learned.route(?).waypoint(?)#z","Learned route Z")
    schema:register(XMLValueType.FLOAT,"farmManager.learned.route(?).waypoint(?)#angle","Learned route angle")
    -- Price observations are historical measurements, not guaranteed forecasts.
    schema:register(XMLValueType.INT,'farmManager.market.price(?)#fillType','Stored fill type')
    schema:register(XMLValueType.FLOAT,'farmManager.market.price(?)#low','Observed minimum price/litre')
    schema:register(XMLValueType.FLOAT,'farmManager.market.price(?)#high','Observed maximum price/litre')
    schema:register(XMLValueType.INT,'farmManager.market.price(?)#samples','Observed price samples')
    -- Bounded cross-session machine/operation experience (not active tasks/locks).
    schema:register(XMLValueType.STRING,"farmManager.experience.entry(?)#operation","Operation")
    schema:register(XMLValueType.STRING,"farmManager.experience.entry(?)#vehicle","Stable vehicle key")
    schema:register(XMLValueType.INT,"farmManager.experience.entry(?)#successes","Verified successes")
    schema:register(XMLValueType.INT,"farmManager.experience.entry(?)#failures","Observed failures")
    schema:register(XMLValueType.INT,"farmManager.experience.entry(?)#debt","Physical vehicle failure debt")
    schema:register(XMLValueType.INT,"farmManager.experience.entry(?)#handovers","Verified implement handovers")
    schema:register(XMLValueType.INT,"farmManager.experience.entry(?)#handoverFailures","Aborted handovers")
    schema:register(XMLValueType.STRING,"farmManager.experience.entry(?)#category","Last failure class")
    -- In-flight handovers persist only stable identities/checkpoints. No Lua
    -- object pointers, AI jobs or runtime reservations are serialized.
    for _,field in ipairs({'taskId','vehicle','tool','operation','stage','reason'}) do
        schema:register(XMLValueType.STRING,'farmManager.handover.entry(?)#'..field,'Physical handover checkpoint '..field)
    end
    schema:register(XMLValueType.STRING,'farmManager.navigation.route(?)#key','Observed verified route key')
    for _,key in ipairs({'x','z'}) do
        schema:register(XMLValueType.FLOAT,'farmManager.navigation.route(?)#'..key,'Arrival coordinate')
        schema:register(XMLValueType.FLOAT,'farmManager.navigation.route(?)#from'..key,'Start coordinate')
        schema:register(XMLValueType.FLOAT,'farmManager.navigation.route(?)#target'..key,'Target coordinate')
        schema:register(XMLValueType.FLOAT,'farmManager.navigation.route(?).p(?)#'..key,'Observed trace point')
    end
    schema:register(XMLValueType.STRING,'farmManager.navigation.route(?)#vehicle','Confirmed vehicle for witnessed trace')
    schema:register(XMLValueType.STRING,'farmManager.navigation.route(?)#footprint','SOLO or TOWED vehicle during route')
    schema:register(XMLValueType.INT,'farmManager.navigation.route(?)#uses','Observed repeated successful arrivals')
    schema:register(XMLValueType.STRING,'farmManager.navigation.hazard(?)#key','Observed bad cell')
    schema:register(XMLValueType.FLOAT,'farmManager.navigation.hazard(?)#x','Bad location x')
    schema:register(XMLValueType.FLOAT,'farmManager.navigation.hazard(?)#z','Bad location z')
    schema:register(XMLValueType.INT,'farmManager.navigation.hazard(?)#failures','Repeated route failures')
    schema:register(XMLValueType.STRING,'farmManager.navigation.hazard(?)#reason','Failure context')
    for _,countName in ipairs({'learned','failures','escapes'}) do
        schema:register(XMLValueType.INT,'farmManager.navigation#'..countName,'Navigation experience '..countName)
    end
    schema:register(XMLValueType.STRING,'farmManager.navigation#lastEvent','Last navigation result')
    schema:register(XMLValueType.FLOAT,'farmManager.farmSurvey#x','Farmyard center x')
    schema:register(XMLValueType.FLOAT,'farmManager.farmSurvey#z','Farmyard center z')
    schema:register(XMLValueType.BOOL,'farmManager.farmSurvey#manual','Manual yard centre')
    schema:register(XMLValueType.INT,'farmManager.farmSurvey#observed','Observed physical edges')
    schema:register(XMLValueType.INT,'farmManager.farmSurvey#confirmed','AI verified physical edges')
    for _,axis in ipairs({'ax','az','bx','bz'}) do
        schema:register(XMLValueType.FLOAT,'farmManager.farmSurvey.edge(?)#'..axis,'Actual driven edge '..axis)
    end
    for _,kind in ipairs({'solo','towed','manual','ai'}) do
        schema:register(XMLValueType.INT,'farmManager.farmSurvey.edge(?)#'..kind,'Recorded traversals')
    end
    FMAState.schema=schema
    return schema
end

function FMAState.new()
    local state={settings={},fields={},excluded={},routes={},forageStages={},homePositions={},toolHomes={},learnedPoints={},learnedRoutes={},navigationMap={routes={},hazards={}},farmSurvey={edges={},manual=false},experience={},handoverJournal={},marketHistory={},parkingBays={}}
    for k,v in pairs(FMAState.defaults) do state.settings[k]=v end
    state.settings.autonomyDefaultApplied=true
    return state
end

function FMAState.path()
    local info=g_currentMission and g_currentMission.missionInfo
    if info and info.savegameDirectory then return info.savegameDirectory.."/farmManagerAI.xml" end
    return nil
end

function FMAState.load()
    local state=FMAState.new()
    local path=FMAState.path()
    if not path or not fileExists(path) then return state end
    local xml=XMLFile.load("farmManagerAI",path,FMAState.getSchema())
    if not xml then return state end
    local ok,err=pcall(function()
        state.mapIdentity=xml:getValue('farmManager#mapIdentity')
        for k,v in pairs(FMAState.defaults) do state.settings[k]=xml:getValue("farmManager.settings#"..k,v) end
        -- 0.20.34: Existing saves inherited the old manual-only default (true).
        -- Adopt the owner's requested fully autonomous default ONCE. The marker
        -- is saved; any later change to manual-selection mode remains respected.
        if state.settings.autonomyDefaultApplied~=true then
            state.settings.selectedJobsOnly=false
            state.settings.autonomyDefaultApplied=true
        end
        for idx=0,159 do
            local key='farmManager.market.price('..idx..')'
            if not xml:hasProperty(key) then break end
            local ft=xml:getValue(key..'#fillType')
            local low,high=xml:getValue(key..'#low'),xml:getValue(key..'#high')
            if ft and ft>0 and low and high and low>=0 and high>=low then
                state.marketHistory[ft]={low=low,high=high,samples=xml:getValue(key..'#samples',0),last=high}
            end
        end
        local yard=state.farmSurvey
        local yardX=xml:getValue('farmManager.farmSurvey#x')
        local yardZ=xml:getValue('farmManager.farmSurvey#z')
        if yardX and yardZ and math.abs(yardX)<100000 and math.abs(yardZ)<100000 then yard.center={x=yardX,z=yardZ} end
        yard.manual=xml:getValue('farmManager.farmSurvey#manual',false)==true
        yard.observed=xml:getValue('farmManager.farmSurvey#observed',0)
        yard.confirmed=xml:getValue('farmManager.farmSurvey#confirmed',0)
        for idx=0,699 do
            local k='farmManager.farmSurvey.edge('..idx..')'
            if not xml:hasProperty(k) then break end
            local ax,az,bx,bz=xml:getValue(k..'#ax'),xml:getValue(k..'#az'),xml:getValue(k..'#bx'),xml:getValue(k..'#bz')
            if ax and az and bx and bz and math.abs(ax)<100000 and math.abs(az)<100000 and math.abs(bx)<100000 and math.abs(bz)<100000 then
                local id=math.floor(ax/3+0.5)..':'..math.floor(az/3+0.5)..'>'..math.floor(bx/3+0.5)..':'..math.floor(bz/3+0.5)
                yard.edges[id]={id=id,ax=ax,az=az,bx=bx,bz=bz,solo=xml:getValue(k..'#solo',0),towed=xml:getValue(k..'#towed',0),manual=xml:getValue(k..'#manual',0),ai=xml:getValue(k..'#ai',0),age=idx}
            end
        end
        local n=state.navigationMap
        n.learned=math.max(0,math.min(1000000,xml:getValue('farmManager.navigation#learned',0) or 0))
        n.failures=math.max(0,math.min(1000000,xml:getValue('farmManager.navigation#failures',0) or 0))
        n.escapes=math.max(0,math.min(1000000,xml:getValue('farmManager.navigation#escapes',0) or 0))
        n.lastEvent=tostring(xml:getValue('farmManager.navigation#lastEvent','') or ''):sub(1,140)
        local navIdx=0
        while xml:hasProperty('farmManager.navigation.route('..navIdx..')') and navIdx<32 do
            local key='farmManager.navigation.route('..navIdx..')';local id=xml:getValue(key..'#key')
            local x,z=xml:getValue(key..'#x'),xml:getValue(key..'#z')
            local fx,fz=xml:getValue(key..'#fromx'),xml:getValue(key..'#fromz')
            local tx,tz=xml:getValue(key..'#targetx'),xml:getValue(key..'#targetz')
            if id and #id<128 and x and z and fx and fz and tx and tz then
                local r={key=id,from={x=fx,z=fz},target={x=tx,z=tz},finish={x=x,z=z},vehicle=xml:getValue(key..'#vehicle'),footprint=xml:getValue(key..'#footprint'),uses=xml:getValue(key..'#uses',1),points={}}
                for j=0,95 do
                    local wk=key..'.p('..j..')'
                    if not xml:hasProperty(wk) then break end
                    local px,pz=xml:getValue(wk..'#x'),xml:getValue(wk..'#z')
                    if px and pz then r.points[#r.points+1]={x=px,z=pz} end
                end
                n.routes[id]=r
            end
            navIdx=navIdx+1
        end
        navIdx=0
        while xml:hasProperty('farmManager.navigation.hazard('..navIdx..')') and navIdx<90 do
            local k='farmManager.navigation.hazard('..navIdx..')';local id=xml:getValue(k..'#key')
            local x,z=xml:getValue(k..'#x'),xml:getValue(k..'#z')
            if id and #id<128 and x and z then n.hazards[id]={x=x,z=z,failures=xml:getValue(k..'#failures',1),reason=xml:getValue(k..'#reason','OBSERVED')} end
            navIdx=navIdx+1
        end
        local journalIndex=0
        while xml:hasProperty('farmManager.handover.entry('..journalIndex..')') and journalIndex<32 do
            local k='farmManager.handover.entry('..journalIndex..')'
            local taskId=xml:getValue(k..'#taskId');local vehicle=xml:getValue(k..'#vehicle')
            local tool=xml:getValue(k..'#tool')
            if taskId and vehicle and tool and #taskId<256 and #vehicle<256 and #tool<256 then
                state.handoverJournal[taskId]={taskId=taskId,vehicle=vehicle,tool=tool,
                    operation=xml:getValue(k..'#operation','?'),stage=xml:getValue(k..'#stage','attached'),
                    reason=xml:getValue(k..'#reason','')}
            end
            journalIndex=journalIndex+1
        end
        local e=0
        while xml:hasProperty("farmManager.experience.entry("..e..")") and e<120 do
            local prefix="farmManager.experience.entry("..e..")"
            local op=xml:getValue(prefix.."#operation")
            local vehicle=xml:getValue(prefix.."#vehicle")
            if op and vehicle and #op<128 and #vehicle<256 then
                local row={operation=op,vehicleKey=vehicle,
                    successes=FMAUtil.clamp(tonumber(xml:getValue(prefix.."#successes",0)) or 0,0,1000),
                    failures=FMAUtil.clamp(tonumber(xml:getValue(prefix.."#failures",0)) or 0,0,1000),
                    reliabilityDebt=FMAUtil.clamp(tonumber(xml:getValue(prefix.."#debt",0)) or 0,0,20),
                    handovers=FMAUtil.clamp(tonumber(xml:getValue(prefix.."#handovers",0)) or 0,0,1000),
                    handoverFailures=FMAUtil.clamp(tonumber(xml:getValue(prefix.."#handoverFailures",0)) or 0,0,1000),
                    lastCategory=xml:getValue(prefix.."#category","NONE")}
                state.experience[FMAExperience.key(op,vehicle)]=row
            end
            e=e+1
        end
        local i=0
        while xml:hasProperty("farmManager.fields.field("..i..")") and i<10000 do
            local key="farmManager.fields.field("..i..")"
            local id=xml:getValue(key.."#id")
            if id then state.fields[tostring(id)]={enabled=xml:getValue(key.."#enabled",true),crop=xml:getValue(key.."#crop","")} end
            i=i+1
        end
        i=0
        while xml:hasProperty("farmManager.excluded.vehicle("..i..")") and i<10000 do
            local id=xml:getValue("farmManager.excluded.vehicle("..i..")#id")
            if id then state.excluded[id]=true end
            i=i+1
        end
        i=0
        while xml:hasProperty("farmManager.forage.field("..i..")") and i<10000 do
            local key="farmManager.forage.field("..i..")"
            local id=xml:getValue(key.."#id");local stage=xml:getValue(key.."#stage")
            if id and stage then state.forageStages[tostring(id)]=stage end
            i=i+1
        end
        i=0
        while xml:hasProperty("farmManager.routes.route("..i..")") and i<10000 do
            local key="farmManager.routes.route("..i..")"
            local id=xml:getValue(key.."#vehicle")
            if id then
                local route={key=id,enabled=false}
                for _,side in ipairs({"load","unload"}) do
                    if xml:hasProperty(key.."."..side) then
                        route[side]={x=xml:getValue(key.."."..side.."#x"),z=xml:getValue(key.."."..side.."#z"),angle=xml:getValue(key.."."..side.."#angle",0)}
                    end
                end
                state.routes[id]=route
            end
            i=i+1
        end
        local function loadHomes(group,target)
            local j=0
            while xml:hasProperty("farmManager.homes."..group.."("..j..")") and j<10000 do
                local key="farmManager.homes."..group.."("..j..")"
                local id=xml:getValue(key.."#id")
                local x=xml:getValue(key.."#x");local z=xml:getValue(key.."#z")
                if id and x and z then target[id]={x=x,z=z,angle=xml:getValue(key.."#angle",0)} end
                j=j+1
            end
        end
        loadHomes("vehicle",state.homePositions)
        loadHomes("tool",state.toolHomes)
        for index=0,95 do
            local key='farmManager.parking.bay('..index..')'
            if not xml:hasProperty(key) then break end
            local bay={}
            for _,field in ipairs({'id','kind','role','site','driverKey','taughtFor','source','label','x','z','angle','width','length','driveX','driveZ','driveAngle'}) do
                bay[field]=xml:getValue(key..'#'..field)
            end
            if bay.id and bay.x and bay.z and bay.source=='OWNER_TAUGHT' and math.abs(bay.x)<100000 and math.abs(bay.z)<100000 then
                state.parkingBays[bay.id]=bay
            end
        end
        i=0
        while xml:hasProperty("farmManager.learned.point("..i..")") and i<1000 do
            local key="farmManager.learned.point("..i..")"
            local id=xml:getValue(key.."#id")
            local x=xml:getValue(key.."#x");local z=xml:getValue(key.."#z")
            if id and x and z then state.learnedPoints[id]={id=id,role=xml:getValue(key.."#role","DVŮR"),label=xml:getValue(key.."#label",id),x=x,z=z,angle=xml:getValue(key.."#angle",0),radius=xml:getValue(key.."#radius",35)} end
            i=i+1
        end
        i=0
        while xml:hasProperty("farmManager.learned.route("..i..")") and i<200 do
            local key="farmManager.learned.route("..i..")"
            local id=xml:getValue(key.."#id")
            if id then
                local route={id=id,role=xml:getValue(key.."#role","DVŮR"),label=xml:getValue(key.."#label",id),points={}}
                local j=0
                while xml:hasProperty(key..".waypoint("..j..")") and j<500 do
                    local wk=key..".waypoint("..j..")";local x=xml:getValue(wk.."#x");local z=xml:getValue(wk.."#z")
                    if x and z then route.points[#route.points+1]={x=x,z=z,angle=xml:getValue(wk.."#angle",0)} end
                    j=j+1
                end
                state.learnedRoutes[id]=route
            end
            i=i+1
        end
    end)
    xml:delete()
    if not ok then FMAUtil.log("Nastavení nelze načíst: "..tostring(err));return FMAState.new() end
    state.settings.sellWhenStoreAbove=FMAUtil.clamp(state.settings.sellWhenStoreAbove or 0.90,0.5,0.99)
    state.settings.priceSellThreshold=FMAUtil.clamp(state.settings.priceSellThreshold or 0.95,0.7,1.0)
    state.settings.storageReservePercent=FMAUtil.clamp(state.settings.storageReservePercent or 0.15,0,0.6)
    state.settings.maxWorkers=FMAUtil.clamp(state.settings.maxWorkers,1,20)
    state.settings.reserve=FMAUtil.clamp(state.settings.reserve,0,100000000)
    state.settings.scanSeconds=FMAUtil.clamp(state.settings.scanSeconds,5,120)
    state.settings.stallSeconds=FMAUtil.clamp(state.settings.stallSeconds,60,1800)
    state.settings.maxAttempts=FMAUtil.clamp(state.settings.maxAttempts,1,3)
    state.settings.threshold=FMAUtil.clamp(state.settings.threshold,0.1,0.9)
    state.settings.foodTarget=FMAUtil.clamp(state.settings.foodTarget,0.2,0.95)
    state.settings.foodEmergency=FMAUtil.clamp(state.settings.foodEmergency,0.05,0.5)
    state.settings.outputMoveAt=FMAUtil.clamp(state.settings.outputMoveAt,0.4,0.98)
    state.settings.unloaderCall=FMAUtil.clamp(state.settings.unloaderCall,0.5,0.95)
    state.settings.maxUnloaders=FMAUtil.clamp(state.settings.maxUnloaders,1,4)
    state.settings.bunkerTargetCompaction=FMAUtil.clamp(state.settings.bunkerTargetCompaction,0.8,1.0)
    state.settings.feedForecastHours=FMAUtil.clamp(state.settings.feedForecastHours,2,72)
    state.settings.beddingForecastHours=FMAUtil.clamp(state.settings.beddingForecastHours,2,72)
    state.settings.strawTarget=FMAUtil.clamp(state.settings.strawTarget,0.2,0.95)
    state.settings.strawEmergency=FMAUtil.clamp(state.settings.strawEmergency,0.05,0.5)
    state.settings.waterTarget=FMAUtil.clamp(state.settings.waterTarget,0.2,0.95)
    state.settings.feedLoadTimeoutSeconds=FMAUtil.clamp(state.settings.feedLoadTimeoutSeconds,30,600)
    state.settings.outputForecastHours=FMAUtil.clamp(state.settings.outputForecastHours,2,72)
    state.settings.organicReserveTarget=FMAUtil.clamp(state.settings.organicReserveTarget,0,0.95)
    state.settings.bunkerWaitDistance=FMAUtil.clamp(state.settings.bunkerWaitDistance,6,30)
    state.settings.bunkerFillTarget=FMAUtil.clamp(state.settings.bunkerFillTarget,0.70,0.98)
    state.settings.bunkerNominalHeight=FMAUtil.clamp(state.settings.bunkerNominalHeight,2.5,6.0)
    state.settings.bunkerPrimaryIndex=FMAUtil.clamp(state.settings.bunkerPrimaryIndex,0,32)
    state.settings.bunkerNextIndex=FMAUtil.clamp(state.settings.bunkerNextIndex,0,32)
    state.settings.bunkerPushSeconds=FMAUtil.clamp(state.settings.bunkerPushSeconds,10,120)
    state.settings.bunkerSettleSeconds=FMAUtil.clamp(state.settings.bunkerSettleSeconds,2,30)
    state.settings.harvestFieldWaitDistance=FMAUtil.clamp(state.settings.harvestFieldWaitDistance or 12,8,25)
    state.settings.fieldStageRadius=FMAUtil.clamp(state.settings.fieldStageRadius or 180,60,400)
    state.settings.fieldStageAttempts=FMAUtil.clamp(state.settings.fieldStageAttempts or 5,2,12)
    state.settings.assemblyStagingDistance=FMAUtil.clamp(math.max(state.settings.assemblyStagingDistance or 10.0,8.0),8.0,15.0)
    state.settings.autoAttachMaxDistance=FMAUtil.clamp(state.settings.autoAttachMaxDistance,2.0,10.0)
    state.settings.attachAlignmentOffset=FMAUtil.clamp(state.settings.attachAlignmentOffset or 2.7,2.5,2.9)
    state.settings.attachRetryDelaySeconds=FMAUtil.clamp(state.settings.attachRetryDelaySeconds,2,15)
    state.settings.trafficCellSize=FMAUtil.clamp(state.settings.trafficCellSize,10,40)
    state.settings.trafficStartSeparation=FMAUtil.clamp(state.settings.trafficStartSeparation,6,30)
    state.settings.trafficEmergencyDistance=FMAUtil.clamp(state.settings.trafficEmergencyDistance,4,20)
    state.settings.trafficRetrySeconds=FMAUtil.clamp(state.settings.trafficRetrySeconds,2,30)
    state.settings.trafficMaxTransit=FMAUtil.clamp(state.settings.trafficMaxTransit,2,20)
    state.settings.trafficLaunchIntervalSeconds=FMAUtil.clamp(state.settings.trafficLaunchIntervalSeconds,0.5,10)
    state.settings.parkTolerance=FMAUtil.clamp(state.settings.parkTolerance,3.0,20.0)
    state.settings.refillBeforeWork=FMAUtil.clamp(state.settings.refillBeforeWork,0.05,0.8)
    state.settings.refillTarget=FMAUtil.clamp(state.settings.refillTarget,0.3,1.0)
    state.settings.fuelBeforeWork=FMAUtil.clamp(state.settings.fuelBeforeWork,0.05,0.5)
    state.settings.fuelTarget=FMAUtil.clamp(state.settings.fuelTarget,0.3,1.0)
    state.settings.refillArrivalTolerance=FMAUtil.clamp(state.settings.refillArrivalTolerance,3,20)
    state.settings.refillTimeoutSeconds=FMAUtil.clamp(state.settings.refillTimeoutSeconds,30,600)
    state.settings.headerTransportMinWidth=FMAUtil.clamp(state.settings.headerTransportMinWidth,3.0,15.0)
    state.settings.headerFieldStagingDistance=FMAUtil.clamp(state.settings.headerFieldStagingDistance,10,60)
    state.settings.headerMountWaitSeconds=FMAUtil.clamp(state.settings.headerMountWaitSeconds,3,30)
    state.settings.coverageOverlapPercent=FMAUtil.clamp(state.settings.coverageOverlapPercent,0,20)
    state.settings.headlandSafetyFactor=FMAUtil.clamp(state.settings.headlandSafetyFactor,1.0,2.0)
    state.settings.minHeadlands=FMAUtil.clamp(state.settings.minHeadlands,1,6)
    state.settings.maxHeadlands=FMAUtil.clamp(state.settings.maxHeadlands,state.settings.minHeadlands,10)
    state.settings.forageMode=FMAUtil.clamp(state.settings.forageMode,0,3)
    state.settings.baleStorageTolerance=FMAUtil.clamp(state.settings.baleStorageTolerance,5,25)
    state.settings.baleStorageReserve=FMAUtil.clamp(state.settings.baleStorageReserve,0,50)
    state.settings.strategyMode=FMAUtil.clamp(state.settings.strategyMode or 0,0,3)
    state.settings.brainSeconds=FMAUtil.clamp(state.settings.brainSeconds or 5,2,20)
    state.settings.roadSpeedEstimateMps=FMAUtil.clamp(state.settings.roadSpeedEstimateMps or 7,3,15)
    state.settings.recoveryProbeSeconds=FMAUtil.clamp(state.settings.recoveryProbeSeconds or 20,10,120)
    state.settings.recoveryRerouteSeconds=FMAUtil.clamp(state.settings.recoveryRerouteSeconds or 43,state.settings.recoveryProbeSeconds+5,240)
    state.settings.recoveryFailoverSeconds=FMAUtil.clamp(state.settings.recoveryFailoverSeconds or 85,state.settings.recoveryRerouteSeconds+5,600)
    state.settings.navigationTimeoutSeconds=FMAUtil.clamp(state.settings.navigationTimeoutSeconds or 75,40,240)
    state.settings.hudPosition=FMAUtil.clamp(state.settings.hudPosition or 0,0,2)
    state.settings.maxRecoveryCycles=FMAUtil.clamp(state.settings.maxRecoveryCycles or 3,1,5)
    state.settings.preventiveServiceDamage=FMAUtil.clamp(state.settings.preventiveServiceDamage or 0.60,0.30,0.90)
    state.settings.criticalServiceDamage=FMAUtil.clamp(state.settings.criticalServiceDamage or 0.85,state.settings.preventiveServiceDamage+0.05,0.99)
    state.settings.serviceArrivalTolerance=FMAUtil.clamp(state.settings.serviceArrivalTolerance or 12,5,30)
    state.settings.learnedApproachRadius=FMAUtil.clamp(state.settings.learnedApproachRadius or 35,10,80)
    state.settings.teachRole=FMAUtil.clamp(state.settings.teachRole or 1,1,10)
    -- Starts are always explicit after loading. A stale save cannot resume a vehicle behind the player's back.
    state.settings.enabled=false
    return state
end

function FMAState.save(controller)
    if not controller.initialized or not controller.supported then return end
    local path=FMAState.path()
    if not path then return end
    local xml=XMLFile.create("farmManagerAI",path,"farmManager",FMAState.getSchema())
    if not xml then FMAUtil.log("Nelze uložit nastavení");return end
    local ok,err=pcall(function()
        xml:setValue("farmManager#version",1)
        if FMAWorldAtlas and FMAWorldAtlas.identity then
            xml:setValue('farmManager#mapIdentity',FMAWorldAtlas.identity())
        end
        for k,v in pairs(controller.settings) do xml:setValue("farmManager.settings#"..k,v) end
        local marketKeys={}
        for ft,h in pairs(controller.marketHistory or {}) do
            if type(ft)=='number' and h and type(h.low)=='number' and type(h.high)=='number' then marketKeys[#marketKeys+1]=ft end
        end
        table.sort(marketKeys)
        for i=1,math.min(#marketKeys,160) do
            local ft=marketKeys[i];local h=controller.marketHistory[ft];local key='farmManager.market.price('..(i-1)..')'
            xml:setValue(key..'#fillType',ft)
            xml:setValue(key..'#low',math.max(0,h.low))
            xml:setValue(key..'#high',math.max(0,h.high))
            xml:setValue(key..'#samples',math.max(0,math.min(100000,h.samples or 0)))
        end
        local ids={}
        for id in pairs(controller.policies) do ids[#ids+1]=id end
        table.sort(ids)
        for i,id in ipairs(ids) do
            local key="farmManager.fields.field("..(i-1)..")"
            local p=controller.policies[id]
            xml:setValue(key.."#id",id);xml:setValue(key.."#enabled",p.enabled);xml:setValue(key.."#crop",p.crop or "")
        end
        local i=0
        for id,excluded in pairs(controller.excluded) do
            if excluded then xml:setValue("farmManager.excluded.vehicle("..i..")#id",id);i=i+1 end
        end
        i=0
        for id,stage in pairs(controller.forageStages or {}) do
            local key="farmManager.forage.field("..i..")";i=i+1
            xml:setValue(key.."#id",id);xml:setValue(key.."#stage",stage)
        end
        i=0
        for id,route in pairs(controller.routes or {}) do
            local key="farmManager.routes.route("..i..")";i=i+1
            xml:setValue(key.."#vehicle",id)
            for _,side in ipairs({"load","unload"}) do
                local point=route[side]
                if point and point.x and point.z then
                    xml:setValue(key.."."..side.."#x",point.x);xml:setValue(key.."."..side.."#z",point.z)
                    xml:setValue(key.."."..side.."#angle",point.angle or 0)
                end
            end
        end
        local function saveHomes(group,source)
            local keys={};for id,pos in pairs(source or {}) do if pos and pos.x and pos.z then keys[#keys+1]=id end end;table.sort(keys)
            for j,id in ipairs(keys) do
                local pos=source[id];local key="farmManager.homes."..group.."("..(j-1)..")"
                xml:setValue(key.."#id",id);xml:setValue(key.."#x",pos.x);xml:setValue(key.."#z",pos.z);xml:setValue(key.."#angle",pos.angle or 0)
            end
        end
        saveHomes("vehicle",controller.homePositions)
        saveHomes("tool",controller.toolHomes)
        local keys={}
        for id,bay in pairs(controller.parkingBays or {}) do
            if bay and bay.x and bay.z and bay.source=='OWNER_TAUGHT' then keys[#keys+1]=id end
        end
        table.sort(keys)
        for i=1,math.min(#keys,96) do
            local bay=controller.parkingBays[keys[i]]
            local key='farmManager.parking.bay('..(i-1)..')'
            for _,field in ipairs({'id','kind','role','site','driverKey','taughtFor','source','label','x','z','angle','width','length','driveX','driveZ','driveAngle'}) do
                if bay[field]~=nil then xml:setValue(key..'#'..field,bay[field]) end
            end
        end
        local checkpoints={}
        for id,entry in pairs(controller.handoverJournal or {}) do
            if type(entry)=='table' and entry.vehicle and entry.tool and #tostring(id)<256 then
                checkpoints[#checkpoints+1]={id=id,entry=entry}
            end
        end
        table.sort(checkpoints,function(a,b) return tostring(a.id)<tostring(b.id) end)
        for i=1,math.min(#checkpoints,32) do
            local row=checkpoints[i];local entry=row.entry;local k='farmManager.handover.entry('..(i-1)..')'
            xml:setValue(k..'#taskId',tostring(row.id));xml:setValue(k..'#vehicle',tostring(entry.vehicle))
            xml:setValue(k..'#tool',tostring(entry.tool));xml:setValue(k..'#operation',tostring(entry.operation or '?'))
            xml:setValue(k..'#stage',tostring(entry.stage or 'attached'))
            xml:setValue(k..'#reason',tostring(entry.reason or ''):sub(1,240))
        end
        local pointIds={};for id,p in pairs(controller.learnedPoints or {}) do if p and p.x and p.z then pointIds[#pointIds+1]=id end end;table.sort(pointIds)
        for j,id in ipairs(pointIds) do
            local p=controller.learnedPoints[id];local key="farmManager.learned.point("..(j-1)..")"
            xml:setValue(key.."#id",id);xml:setValue(key.."#role",p.role or "DVŮR");xml:setValue(key.."#label",p.label or id);xml:setValue(key.."#x",p.x);xml:setValue(key.."#z",p.z);xml:setValue(key.."#angle",p.angle or 0);xml:setValue(key.."#radius",p.radius or 35)
        end
        local routeIds={};for id,r in pairs(controller.learnedRoutes or {}) do if r and #(r.points or {})>1 then routeIds[#routeIds+1]=id end end;table.sort(routeIds)
        for j,id in ipairs(routeIds) do
            local r=controller.learnedRoutes[id];local key="farmManager.learned.route("..(j-1)..")"
            xml:setValue(key.."#id",id);xml:setValue(key.."#role",r.role or "DVŮR");xml:setValue(key.."#label",r.label or id)
            for k,p in ipairs(r.points or {}) do local wk=key..".waypoint("..(k-1)..")";xml:setValue(wk.."#x",p.x);xml:setValue(wk.."#z",p.z);xml:setValue(wk.."#angle",p.angle or 0) end
        end
        -- Save only bounded, stable statistics. Never persist live job reservations.
        local memories={}
        for _,r in pairs(controller.experience or {}) do
            if r.operation and r.vehicleKey and (#tostring(r.operation)<128) and (#tostring(r.vehicleKey)<256) then
                memories[#memories+1]=r
            end
        end
        table.sort(memories,function(a,b)
            local as=(a.failures or 0)+(a.successes or 0)
            local bs=(b.failures or 0)+(b.successes or 0)
            if as~=bs then return as>bs end
            return tostring(a.operation)..tostring(a.vehicleKey)<tostring(b.operation)..tostring(b.vehicleKey)
        end)
        for j=1,math.min(#memories,120) do
            local r=memories[j];local key="farmManager.experience.entry("..(j-1)..")"
            xml:setValue(key.."#operation",r.operation)
            xml:setValue(key.."#vehicle",r.vehicleKey)
            xml:setValue(key.."#successes",math.min(1000,math.max(0,r.successes or 0)))
            xml:setValue(key.."#failures",math.min(1000,math.max(0,r.failures or 0)))
            xml:setValue(key.."#debt",math.min(20,math.max(0,r.reliabilityDebt or 0)))
            xml:setValue(key.."#handovers",math.min(1000,math.max(0,r.handovers or 0)))
            xml:setValue(key.."#handoverFailures",math.min(1000,math.max(0,r.handoverFailures or 0)))
            xml:setValue(key.."#category",r.lastCategory or "NONE")
        end
        local yard=controller.farmSurvey or {}
        if yard.center and yard.center.x and yard.center.z then
            xml:setValue('farmManager.farmSurvey#x',yard.center.x)
            xml:setValue('farmManager.farmSurvey#z',yard.center.z)
            xml:setValue('farmManager.farmSurvey#manual',yard.manual==true)
        end
        xml:setValue('farmManager.farmSurvey#observed',math.min(1000000,yard.observed or 0))
        xml:setValue('farmManager.farmSurvey#confirmed',math.min(1000000,yard.confirmed or 0))
        local safeEdges={};for _,row in pairs(yard.edges or {}) do
            if row.ax and row.az and row.bx and row.bz then safeEdges[#safeEdges+1]=row end
        end
        table.sort(safeEdges,function(a,b)return (a.age or 0)>(b.age or 0) end)
        for i=1,math.min(700,#safeEdges) do
            local e=safeEdges[i];local k='farmManager.farmSurvey.edge('..(i-1)..')'
            for _,axis in ipairs({'ax','az','bx','bz'}) do xml:setValue(k..'#'..axis,e[axis]) end
            for _,kind in ipairs({'solo','towed','manual','ai'}) do xml:setValue(k..'#'..kind,math.min(999,e[kind] or 0)) end
        end
        local n=controller.navigationMap or {};local nRoutes={}
        for _,countName in ipairs({'learned','failures','escapes'}) do
            xml:setValue('farmManager.navigation#'..countName,math.max(0,math.min(1000000,n[countName] or 0)))
        end
        xml:setValue('farmManager.navigation#lastEvent',tostring(n.lastEvent or ''):sub(1,140))
        for key,r in pairs(n.routes or {}) do if r.from and r.target and r.finish then nRoutes[#nRoutes+1]={key=key,row=r} end end
        table.sort(nRoutes,function(a,b)return tostring(a.key)<tostring(b.key) end)
        for i=1,math.min(32,#nRoutes) do
            local entry=nRoutes[i];local r=entry.row;local k='farmManager.navigation.route('..(i-1)..')'
            xml:setValue(k..'#key',entry.key)
            xml:setValue(k..'#x',r.finish.x);xml:setValue(k..'#z',r.finish.z)
            xml:setValue(k..'#fromx',r.from.x);xml:setValue(k..'#fromz',r.from.z)
            xml:setValue(k..'#targetx',r.target.x);xml:setValue(k..'#targetz',r.target.z)
            xml:setValue(k..'#uses',math.min(1000,r.uses or 1))
            xml:setValue(k..'#vehicle',r.vehicle)
            xml:setValue(k..'#footprint',r.footprint)
            for j,p in ipairs(r.points or {}) do if j>96 then break end
                local wk=k..'.p('..(j-1)..')';xml:setValue(wk..'#x',p.x);xml:setValue(wk..'#z',p.z)
            end
        end
        local hKeys={};for k,h in pairs(n.hazards or {}) do if h.x and h.z then hKeys[#hKeys+1]=k end end
        table.sort(hKeys)
        for i=1,math.min(90,#hKeys) do
            local h=n.hazards[hKeys[i]];local k='farmManager.navigation.hazard('..(i-1)..')'
            xml:setValue(k..'#key',hKeys[i]);xml:setValue(k..'#x',h.x);xml:setValue(k..'#z',h.z)
            xml:setValue(k..'#failures',math.min(20,h.failures or 1));xml:setValue(k..'#reason',h.reason or '')
        end
        xml:save()
    end)
    xml:delete()
    if not ok then FMAUtil.log("Chyba uložení: "..tostring(err)) end
end
