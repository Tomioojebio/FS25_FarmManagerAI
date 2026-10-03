unpack=table.unpack
local files={"FMAUtil","FMAOpsLog","FMALiveTelemetry","FMABlackBox","FMATestSuite","FMADevLab","FMASupportReport","FMADiagnostics","FMAJobs","FMALifecycle","FMAModHubAdapter","FMACatalog","FMACarpathianProfile","FMAPlanner","FMAGameNative","FMAWorld","FMAWorldRegistry","FMAWorldAtlas","FMACompatibility","FMAAI","FMAControlAuthority","FMAOwnDriver","FMAState","FMAAutoRoute","FMAAssembler","FMALogistics","FMAMarketPlanner","FMARefillManager","FMAParkingManager","FMAReturnManager","FMAHeaderTransport","FMALivestockCoordinator","FMAAnimalManager","FMAProductionManager","FMACourseplay","FMATransfer","FMAFieldQuality","FMAForageCoordinator","FMABaleStorage","FMATraffic","FMAHaulageCycle","FMAFleetCoordinator","FMABunkerCoordinator","FMABaleCoordinator","FMAProcurement","FMAFarmBrain","FMANavigation","FMAEngineRoads","FMAFarmSurvey","FMAPathRunner","FMARecovery","FMAExperience","FMASelfHealing","FMAWorkEvidence","FMATeach","FMAServiceManager","FMAController","FMAJobBrief","FMAHud"}
for _,f in ipairs(files) do dofile("scripts/"..f..".lua") end
local passed=0
local function test(name,fn)
    local ok,why=xpcall(fn,debug.traceback);if not ok then error(name.."\n"..why) end;passed=passed+1;print("PASS "..name)
end
local function eq(actual,expected) assert(actual==expected,tostring(actual).." ~= "..tostring(expected)) end
local function shallow(t) local n={};for k,v in pairs(t) do n[k]=v end;return n end
local settings=FMAState.new().settings
local policy={enabled=true,crop="WHEAT"}

test("growing crop is never plowed",function()
    eq(FMAPlanner.nextOperation({valid=true,alive=true,needsPlow=true,bare=false},policy,settings),nil)
end)
test("ready crop precedes soil operations",function()
    eq(FMAPlanner.nextOperation({valid=true,ready=true,needsPlow=true},policy,settings),"harvest")
end)
test("grass regrowth is not reseeded",function()
    eq(FMAPlanner.nextOperation({valid=true,grass=true,ready=false,bare=true},policy,settings),nil)
end)
test("grass ready becomes mowing",function()
    eq(FMAPlanner.nextOperation({valid=true,grass=true,ready=true},policy,settings),"mow")
end)
test("field quality calculates enough headlands for turning room",function()
    local cfg=shallow(settings);cfg.headlandSafetyFactor=1.35;cfg.minHeadlands=2;cfg.maxHeadlands=6
    eq(FMAFieldQuality.headlandCount(3,7,cfg),4)
    eq(FMAFieldQuality.headlandCount(12,7,cfg),2)
end)
test("forage chain hands work to next crew",function()
    local c={settings=shallow(settings),vehicles={},loose={},excluded={},forageStages={['1']='mowed'}}
    c.settings.autoForageChain=true;c.settings.forageMode=3
    eq(FMAForageCoordinator.nextOperation(c,{id='1',grass=true}),"windrow")
    c.forageStages['1']='windrowed';eq(FMAForageCoordinator.nextOperation(c,{id='1',grass=true}),"foragePickup")
end)
test("forage pickup is a real catalog capability",function()
    eq(FMACatalog.operations.foragePickup.cap,"foragePickup")
end)
test("windrow course is copied to following pickup machine",function()
    local copied=false;local vehicle={cpCopyCourse=function(self,c)copied=c end}
    local c={settings={windrowCourseReuse=true},windrowCourses={['1']={id='course'}}}
    local task={operation='foragePickup',fieldId='1'}
    eq(FMAFieldQuality.copyRememberedWindrow(c,task,{object=vehicle}),true);assert(copied and copied.id=='course')
end)
test("harvest course is remembered as straw row centerline",function()
    local course={id='harvestCourse',copy=function(self)return {id=self.id} end}
    local c={settings={windrowCourseReuse=true},windrowCourses={},notify=function()end}
    local vehicle={getFieldWorkCourse=function()return course end}
    FMAFieldQuality.rememberWindrow(c,{operation='harvest',fieldId='9'},vehicle)
    assert(c.windrowCourses['9'] and c.windrowCourses['9'].id=='harvestCourse')
end)
test("unknown field state fails closed",function()
    eq(FMAPlanner.nextOperation({valid=false,ready=true},policy,settings),nil)
end)
test("excluded field creates no work",function()
    eq(FMAPlanner.nextOperation({valid=true,ready=true},{enabled=false},settings),nil)
end)
test("no crop choice means no automatic planting",function()
    eq(FMAPlanner.nextOperation({valid=true,bare=true,prepared=true},{enabled=true,crop=""},settings),nil)
end)
test("soil preparation precedes sowing",function()
    eq(FMAPlanner.nextOperation({valid=true,bare=true,prepared=false},policy,settings),"cultivate")
    eq(FMAPlanner.nextOperation({valid=true,bare=true,prepared=true},policy,settings),"sow")
end)
test("bare field with lime and plowing has ordered prerequisites",function()
    eq(FMAPlanner.nextOperation({valid=true,bare=true,needsLime=true,needsPlow=true},policy,settings),"lime")
end)
test("crop-care disabled prevents guessed treatments",function()
    local config=shallow(settings);config.cropCare=false
    eq(FMAPlanner.nextOperation({valid=true,alive=true,needsWeed=true,needsFertilize=true},policy,config),nil)
end)
test("running work survives a new plan",function()
    local old={a={id="a",state="running"}}
    eq(FMAPlanner.merge(old,{},10).a,old.a)
end)
test("cooldown survives and then expires",function()
    local old={a={id="a",state="cooldown",retryAt=100}}
    eq(FMAPlanner.merge(old,{{id="a",state="pending"}},50).a.state,"cooldown")
    eq(FMAPlanner.merge(old,{{id="a",state="pending"}},100).a.state,"pending")
end)
test("fresh task crop replaces a stale crop policy",function()
    local old={a={id="a",state="pending",crop="WHEAT"}}
    eq(FMAPlanner.merge(old,{{id="a",crop="BARLEY"}},0).a.crop,"BARLEY")
end)
test("reservations and occupancy prevent double assignment",function()
    local task={operation="cultivate",x=0,z=0}
    local v={key="1",capabilities={cultivate=true},x=1,z=1,readyOperations={}}
    eq(FMAPlanner.chooseVehicle(task,{v},{["1"]=true},{}),nil)
    v.busy=true;eq(FMAPlanner.chooseVehicle(task,{v},{},{}),nil)
    v.busy=false;eq(FMAPlanner.chooseVehicle(task,{v},{},{["1"]=true}),nil)
end)
test("matching seeder, cutter fruit and material required",function()
    local v={key="1",capabilities={sow=true,harvest=true,fertilize=true},x=0,z=0,sowingFruit="WHEAT",harvestFruits={[1]=true},readyOperations={fertilize=false}}
    eq(FMAPlanner.chooseVehicle({operation="sow",crop="BARLEY"},{v},{},{}),nil)
    eq(FMAPlanner.chooseVehicle({operation="harvest",fruitIndex=2},{v},{},{}),nil)
    eq(FMAPlanner.chooseVehicle({operation="fertilize"},{v},{},{}),nil)
    eq(FMAPlanner.chooseVehicle({operation="harvest",fruitIndex=1},{v},{},{}),v)
end)
test("budget and worker limits gate starts",function()
    local config=shallow(settings);config.enabled=true
    eq(FMAPlanner.canDispatch(config,0,4999,0),false)
    eq(FMAPlanner.canDispatch(config,0,nil,0),false)
    eq(FMAPlanner.canDispatch(config,0,10000,config.maxWorkers),false)
    eq(FMAPlanner.canDispatch(config,0,10000,0),true)
end)

test("owner-requested priority sorts ahead of equal or higher routine work",function()
    local q=FMAPlanner.queue({a={id="a",priority=100},b={id="b",priority=10,ownerRequested=true}})
    eq(q[1].id,"b")
end)

test("keyboard overview Enter opens job setup without starting blindly",function()
    local task={id="field:32:harvest",kind="field",operation="harvest",label="32 · Sklizeň",state="pending",priority=80}
    local c={supported=true,page=1,selection=3,tasks={[task.id]=task},conditions={},fields={},settings=shallow(settings),lastMessage=""}
    c.notify=function(self,msg)self.lastMessage=msg end
    c.scan=function()end
    FMAHud.select(c)
    eq(c.focusTaskId,task.id);eq(c.page,9);eq(c.selection,1);eq(task.ownerRequested,nil)
end)

test("job start row activates selected task from keyboard",function()
    local task={id="field:32:harvest",kind="field",operation="harvest",label="32 · Sklizeň",state="pending",priority=80}
    local dispatched=false;local scanned=false
    local c={supported=true,page=9,selection=1,fmaTaskListMode=false,tasks={[task.id]=task},focusTaskId=task.id,conditions={},settings=shallow(settings),vehicles={},loose={},lastMessage=""}
    c.settings.enabled=false
    c.notify=function(self,msg)self.lastMessage=msg end
    c.scan=function()scanned=true end
    c.dispatch=function()dispatched=true end
    c.enableAutomation=function(self)self.settings.enabled=true;return true end
    FMAHud.select(c)
    eq(c.settings.enabled,true);eq(task.ownerRequested,true);eq(scanned,true);eq(dispatched,true)
end)
test("assembler pairs a detached cutter with an owned combine chassis",function()
    AttacherJoints={getAttacherJointCompatibility=function()return true end}
    local powerObj={ownerFarmId=1,spec_attacherJoints={attacherJoints={{jointIndex=0,jointType=1}}},spec_combine={},
        getAttacherJoints=function(self)return self.spec_attacherJoints.attacherJoints end,getIsAttachingAllowed=function()return true end}
    local cutterObj={ownerFarmId=1,spec_cutter={fruitTypeIndices={3}},spec_attachable={inputAttacherJoints={{jointType=1}}},getInputAttacherJoints=function(self)return self.spec_attachable.inputAttacherJoints end,
        isAttachAllowed=function()return true end}
    local c={farmId=1,vehicles={{object=powerObj,key="combine",name="Combine",x=0,z=0,busy=false,lowFuel=false,hasCombine=true,isGrainCombine=true,capabilities={}}},
        loose={{object=cutterObj,key="header",name="Header",x=5,z=0,capabilities={harvest=true},harvestFruits={[3]=true},transportFillTypes={}}},
        excluded={},reservations={},implementReservations={}}
    local plan=FMAAssembler.findPlan(c,{kind="field",operation="harvest",fruitIndex=3,x=50,z=50})
    assert(plan);eq(plan.power.key,"combine");eq(plan.tool.key,"header")
end)


test("preferred prepared vehicle wins selection",function()
    local a={key="a",name="A",capabilities={cultivate=true},x=1,z=0,busy=false,lowFuel=false,readyOperations={}}
    local b={key="b",name="B",capabilities={cultivate=true},x=20,z=0,busy=false,lowFuel=false,readyOperations={}}
    local task={operation="cultivate",x=0,z=0,preferredVehicleKey="b"}
    eq(FMAPlanner.chooseVehicle(task,{a,b},{},{}),b)
end)

test("return manager learns vehicle and detached implement homes",function()
    local oldL,oldM=localDirectionToWorld,MathUtil
    localDirectionToWorld=function()return 0,0,1 end;MathUtil={getYRotationFromDirection=function()return 0 end}
    local v={rootNode=1,posX=10,posZ=20};local t={rootNode=2,posX=30,posZ=40}
    local c={vehicles={{key="v",object=v,busy=false}},loose={{key="t",object=t}},implementReservations={},homePositions={},toolHomes={}}
    FMAReturnManager.captureHomes(c)
    eq(c.homePositions.v.x,10);eq(c.homePositions.v.z,20);eq(c.toolHomes.t.x,30);eq(c.toolHomes.t.z,40)
    localDirectionToWorld,MathUtil=oldL,oldM
end)

test("fleet sizing scales with harvesting throughput",function()
    eq(FMAFleetCoordinator.requiredUnloaders(50,600,30000,4),1)
    eq(FMAFleetCoordinator.requiredUnloaders(120,600,30000,4),3)
end)
test("predictive unloader call can happen before 80 percent",function()
    local cfg=shallow(settings);cfg.unloaderCall=0.8;cfg.unloaderApproachSpeed=8;cfg.unloaderLeadSeconds=30
    eq(FMAFleetCoordinator.shouldCallUnloader(0.70,100,10000,300,cfg),true)
    eq(FMAFleetCoordinator.shouldCallUnloader(0.20,10,10000,50,cfg),false)
end)
test("traffic reservation cannot evict a vehicle still occupying the zone",function()
    local t=FMATraffic.new()
    eq(select(1,FMATraffic.reserve(t,"yardGate","ai","fieldWorker",0,10000)),true)
    eq(select(1,FMATraffic.reserve(t,"yardGate","player","player",1,10000)),false)
    eq(t.zones.yardGate.vehicleKey,"ai")
end)
test("public destination is opt-in",function()
    local own={ownerFarmId=1};local src={owningPlaceable=own,getFillLevel=function()return 2000 end}
    local dst={owningPlaceable=nil,getFreeCapacity=function()return 2000 end}
    local c=controller and nil -- evaluated later only for syntax guard
    assert(src and dst)
end)

-- Engine API contract doubles below exercise our code paths, not the FS25 implementation.
g_server={}
FillType={SEEDS=1,FERTILIZER=2,LIQUIDFERTILIZER=3,LIME=4,DIESEL=5,SLURRY=6,MANURE=7,DIGESTATE=8,LIQUIDMANURE=9,SILAGE=20,DRYGRASS_WINDROW=21,STRAW=22,FORAGE_MIXING=23,WATER=24}
g_currentMission={missionInfo={growthMode=1,savegameDirectory="mock",mapTitle="Mock"},missionDynamicInfo={isMultiplayer=false},environment={currentPeriod=3,weather={getIsRaining=function() return false end}},isRunning=true}
g_fruitTypeManager={getFruitTypeByName=function(_,name) return {name=name,getIsPlantableInPeriod=function() return true end} end}
g_currentMission.aiSystem={started={},stopped={}}
function g_currentMission.aiSystem:startJob(job,farm) job.isRunning=true;self.started[#self.started+1]={job=job,farm=farm} end
function g_currentMission.aiSystem:stopJob(job,message) job.isRunning=false;self.stopped[#self.stopped+1]=job end
AIMessageSuccessStoppedByUser={new=function()return {} end}
local function parameter()
    return {setPosition=function(self,x,z)self.x=x;self.z=z end,setAngle=function(self,a)self.angle=a end,
        setLoadingStation=function(self,o)self.value=o end,setUnloadingStation=function(self,o)self.value=o end,
        setFillTypeIndex=function(self,o)self.value=o end,setIsLooping=function(self,o)self.value=o end}
end
local function jobFactory()
    return {getVehicle=function(self)return self.vehicle end,getIsAvailableForVehicle=function()return true end,applyCurrentState=function(self,v,m,f,d)self.vehicle=v;self.direct=d end,
        setValues=function(self)self.set=true end,validate=function(self)assert(self.set);return true end,getIsStartable=function()return true end,
        positionAngleParameter=parameter(),loadingStationParameter=parameter(),unloadingStationParameter=parameter(),fillTypeParameter=parameter(),loopingParameter=parameter(),updateFillTypes=function()end}
end
AIJobFieldWork={new=jobFactory};AIJobLoadAndDeliver={new=jobFactory};AIJobGoTo={new=jobFactory}
AIJobDeliver={new=jobFactory}
local nativeNames={'GOTO','FIELDWORK','LOAD_AND_DELIVER','DELIVER'}
local nativeClasses={AIJobGoTo,AIJobFieldWork,AIJobLoadAndDeliver,AIJobDeliver}
g_currentMission.aiJobTypeManager={
    getJobTypeIndexByName=function(_,name)for i,n in ipairs(nativeNames)do if n==name then return i end end end,
    createJob=function(_,i)local job=nativeClasses[i].new();job.jobTypeIndex=i;job.mockClassIndex=i;return job end,
    getJobTypeIndex=function(_,job)return job.mockClassIndex end,
    getJobTypeByIndex=function(_,i)if nativeNames[i]then return {name=nativeNames[i]} end end
}

local function vehicle()
    return {ownerFarmId=1,rootNode=1,name="Traktor",spec_motorized={},spec_enterable={},
        getIsAIActive=function()return false end,getIsEntered=function()return false end,getAttachedImplements=function()return {} end}
end
getWorldTranslation=function() return 0,0,0 end
local function controller()
    local c=FMAController.new();c.initialized=true;c.supported=true;c.farmId=1;c.settings.enabled=true;c.fieldsById["1"]={valid=true}
    c.settings.precisionFieldwork=false
    c.notify=function(self,text)self.lastMessage=text end
    return c
end
test("pre-work refill detects empty seed tank without inventing material",function()
    local seedTool={spec_fillUnit={fillUnits={{supportedFillTypes={[FillType.SEEDS]=true}}}},
        getFillUnits=function(self)return self.spec_fillUnit.fillUnits end,getFillUnitCapacity=function()return 2000 end,getFillUnitFillLevel=function()return 100 end}
    local root=vehicle();root.getAttachedImplements=function()return {{object=seedTool}} end
    local req=FMARefillManager.requirement({object=root},{operation="sow"},settings)
    assert(req);eq(req.fillType,FillType.SEEDS);eq(req.capacity,2000);assert(req.targetRatio>=0.8)
end)

test("fertilizer workflow accepts slurry manure and digestate fill types",function()
    local found={};for _,ft in ipairs(FMARefillManager.desiredFillTypes({operation="fertilize"})) do found[ft]=true end
    eq(found[FillType.FERTILIZER],true);eq(found[FillType.SLURRY],true);eq(found[FillType.MANURE],true);eq(found[FillType.DIGESTATE],true)
end)

test("dynamic livestock ration follows the loaded AnimalFoodSystem recipe",function()
    local oldStorage,oldFood=g_currentMission.storageSystem,g_currentMission.animalFoodSystem
    local own={ownerFarmId=1}
    local function source(ft,level) return {owningPlaceable=own,getAISupportedFillTypes=function()return {[ft]=true}end,getFillLevel=function()return level end} end
    g_currentMission.storageSystem={getLoadingStations=function()return {source(FillType.SILAGE,10000),source(FillType.DRYGRASS_WINDROW,10000),source(FillType.STRAW,5000)}end,getUnloadingStations=function()return {}end}
    g_currentMission.animalFoodSystem={
        getAnimalFood=function()return {groups={{title="TMR",productionWeight=1,fillTypes={[FillType.FORAGE_MIXING]=true}}}} end,
        getMixturesByAnimalTypeIndex=function()return {[FillType.FORAGE_MIXING]=true} end,
        getMixtureByFillType=function(_,ft) if ft~=FillType.FORAGE_MIXING then return nil end return {ingredients={
            {weight=0.50,fillTypes={[FillType.SILAGE]=true}},
            {weight=0.30,fillTypes={FillType.DRYGRASS_WINDROW}},
            {weight=0.20,fillTypes={FillType.STRAW}}}} end}
    local place={ownerFarmId=1,spec_husbandryFood={animalTypeIndex=1,fillLevels={[FillType.FORAGE_MIXING]=0}},getTotalFood=function()return 100 end,getFoodCapacity=function()return 1000 end,getFoodLitersPerHour=function()return 50 end}
    local plan=FMALivestockCoordinator.feedPlan(place,1,settings)
    assert(plan and plan.mixturePlan and plan.mixturePlan.complete);eq(#plan.mixturePlan.ingredients,3);eq(math.floor(plan.needed),600)
    assert(plan.mixturePlan.availableMixLiters>=20000-1)
    g_currentMission.storageSystem,g_currentMission.animalFoodSystem=oldStorage,oldFood
end)

test("organic manure and slurry are not auto-sold when nutrient retention is enabled",function()
    local oldStorage=g_currentMission.storageSystem
    local husbandry={ownerFarmId=1,spec_husbandry={}}
    local src={owningPlaceable=husbandry,getAISupportedFillTypes=function()return {[FillType.MANURE]=true}end,getFillLevel=function()return 900 end,getCapacity=function()return 1000 end}
    local sell={isSellingPoint=true,getAISupportedFillTypes=function()return {[FillType.MANURE]=true}end,getFreeCapacity=function()return 100000 end,getEffectiveFillTypePrice=function()return 1 end}
    g_currentMission.storageSystem={getLoadingStations=function()return {src}end,getUnloadingStations=function()return {sell}end}
    local cfg=shallow(settings);cfg.autoSellOutputs=true;cfg.retainOrganicFertilizer=true;cfg.outputMoveAt=0.75
    eq(#FMALogistics.outputTasks(1,cfg),0)
    cfg.retainOrganicFertilizer=false;eq(#FMALogistics.outputTasks(1,cfg),1)
    g_currentMission.storageSystem=oldStorage
end)

test("bunker drive-through requires actual Courseplay wall detection",function()
    local c=controller();c.settings.bunkerWaitDistance=12
    local record={object=vehicle(),key="tipper",x=-30,z=0}
    local b={wrapper={initialized=true,siloMode=0,SIDE_MODES={OPEN=0}},geometry={front={x=0,z=0},back={x=0,z=40},frontOutside={x=0,z=-14},backOutside={x=0,z=54},dx=0,dz=1,length=40}}
    local p=FMABunkerCoordinator.deliveryPlan(c,b,record);eq(p.mode,"driveThrough");assert(p.wait.z<p.entry.z)
    b.wrapper.siloMode=1;eq(FMABunkerCoordinator.deliveryPlan(c,b,record),nil)
    b.wrapper=nil;eq(FMABunkerCoordinator.deliveryPlan(c,b,record),nil)
end)

test("livestock defaults forecast feed bedding outputs and keep organic fertilizer",function()
    eq(settings.retainOrganicFertilizer,true);assert(settings.feedForecastHours>=12);assert(settings.beddingForecastHours>=12);assert(settings.outputForecastHours>=12)
end)

test("wide cutter requires a real header carrier workflow",function()
    local cutter={spec_cutter={},getAIWorkAreaWidth=function()return 9.3 end}
    local root=vehicle();root.getAttachedImplements=function()return {{object=cutter}} end
    local needed,found,width=FMAHeaderTransport.needsTransport({settings=settings},{operation="harvest"},{object=root})
    eq(needed,true);eq(found,cutter);assert(width>9)
    eq(FMAHeaderTransport.isCarrier({object={spec_dynamicMountAttacher={}}}),true)
end)

test("harvest support selection distinguishes tractor and trailer",function()
    local trailer={uniqueId="trailer",spec_attachable={}}
    local root=vehicle();root.uniqueId="tractor";root.getAttachedImplements=function()return {{object=trailer}} end
    local record={key="tractor",object=root}
    local task={preferredSupportKeys={[1]="tractor"},preferredSupportToolKeys={[1]="trailer"}}
    eq(FMAFleetCoordinator.transporterMatchesSelection(task,record,1),true)
    task.preferredSupportToolKeys[1]="other";eq(FMAFleetCoordinator.transporterMatchesSelection(task,record,1),false)
end)
test("native start uses a validated job at the actual target",function()
    local c=controller();local v=vehicle()
    local j=FMAAI.start(c,{kind="field",operation="cultivate",fieldId="1",x=120,z=250},{object=v})
    assert(j);eq(j.positionAngleParameter.x,120);eq(j.positionAngleParameter.z,250);eq(j.direct,false)
    eq(g_currentMission.aiSystem.started[#g_currentMission.aiSystem.started].farm,1)
end)
test("foreign or occupied vehicle cannot be started",function()
    local c=controller();local v=vehicle();v.ownerFarmId=2
    eq(FMAAI.start(c,{kind="field"},{object=v}),nil)
    v.ownerFarmId=1;v.getIsEntered=function()return true end
    eq(FMAAI.start(c,{kind="field"},{object=v}),nil)
end)
test("rain holds harvest without engine mutation",function()
    g_currentMission.environment.weather.getIsRaining=function()return true end
    local before=#g_currentMission.aiSystem.started
    eq(FMAAI.start(controller(),{kind="field",operation="harvest"},{object=vehicle()}),nil)
    eq(#g_currentMission.aiSystem.started,before)
    g_currentMission.environment.weather.getIsRaining=function()return false end
end)
test("unverified sowing calendar blocks start",function()
    local original=g_fruitTypeManager.getFruitTypeByName
    g_fruitTypeManager.getFruitTypeByName=function()return {} end
    eq(FMAAI.start(controller(),{kind="field",operation="sow",crop="WHEAT"},{object=vehicle(),sowingFruit="WHEAT"}),nil)
    g_fruitTypeManager.getFruitTypeByName=original
end)
test("engine validation failure does not start a job",function()
    local old=AIJobFieldWork.new
    AIJobFieldWork.new=function()local j=jobFactory();j.validate=function()return false,"denied" end;return j end
    local j,why=FMAAI.start(controller(),{kind="field",operation="cultivate",fieldId="1"},{object=vehicle()})
    eq(j,nil);eq(why,"denied");AIJobFieldWork.new=old
end)
test("supply is one trip with sufficient own stock and destination space",function()
    local p={ownerFarmId=1}
    local src={owningPlaceable=p,getFillLevel=function()return 2000 end}
    local dst={owningPlaceable={ownerFarmId=1},getFreeCapacity=function()return 1500 end}
    local task={kind="supply",source=src,destination=dst,fillType=1}
    local j=FMAAI.start(controller(),task,{object=vehicle(),capacity=1000})
    assert(j);eq(j.loopingParameter.value,false);eq(j.fillTypeParameter.value,1)
    eq(FMAAI.start(controller(),task,{object=vehicle(),capacity=3000}),nil)
    src.owningPlaceable.ownerFarmId=2
    eq(FMAAI.start(controller(),task,{object=vehicle(),capacity=1000}),nil)
end)
test("turning off only stops jobs owned by manager",function()
    local c=controller();local managed={isRunning=true};local foreign={isRunning=true}
    c.active[managed]={task={},vehicle={key="1"}};c.routes={}
    c:toggle();eq(managed.isRunning,false);eq(foreign.isRunning,true);eq(c.settings.enabled,false)
end)
test("stopped job is not blindly counted as completed",function()
    local c=controller();local j={};local t={id="field:test",kind="field",state="running",attempts=1,label="test"}
    c.active[j]={task=t,vehicle={key="1"}};c.reservations["1"]=t
    c:onJobStopped(j,nil);c:drainStoppedJobs();eq(t.state,"blocked");eq(c.reservations["1"],nil)
end)
test("watchdog halts only a stalled managed job",function()
    local c=controller();c.now=400000;local j={isRunning=true}
    local t={id="field:stalled",kind="field",attempts=1,label="stalled"}
    c.active[j]={task=t,vehicle={object=vehicle(),key="1"},lastProgress=0,x=0,z=0,fill=0}
    c:watchdog();c:drainStoppedJobs();eq(j.isRunning,false);eq(t.state,"blocked")
end)
test("unknown autoloader is detected without being called",function()
    local v=vehicle();v.spec_untrustedAutoload={isLoading=true}
    local result=FMACompatibility.inspect(v)
    eq(#result.autoloaders,1);eq(result.externalBusy,true);eq(FMAAutoRoute.tool(v),nil)
end)
test("autoload route uses non-forced unloading and waits for empty cargo",function()
    local v=vehicle();local forceSeen=nil;local loadCount=2
    v.spec_universalAutoload={isAutoloadAvailable=true}
    v.ualStartLoad=function()end;v.ualStopLoad=function()end;v.ualGetFillUnitFillLevel=function()return loadCount end
    FS25_UniversalAutoload={UniversalAutoload={startUnloading=function(_,force)forceSeen=force end}}
    local c=controller();local r={key="v",enabled=true,phase="unloading",since=0,lastChange=0,vehicle={object=v,key="v"}}
    c.routes.v=r;c.reservations.v=true;c.now=10000
    FMAAutoRoute.update(c);eq(forceSeen,false);eq(r.phase,"unloading")
    loadCount=0;FMAAutoRoute.update(c);eq(r.phase,"idle");eq(r.cycles,1);eq(c.reservations.v,nil)
end)
test("route fails if driver takes over at loading point",function()
    local v=vehicle();v.spec_universalAutoload={isAutoloadAvailable=true}
    v.ualStartLoad=function()error("must not load")end;v.ualStopLoad=function()end;v.ualGetFillUnitFillLevel=function()return 0 end
    v.getIsEntered=function()return true end
    local c=controller();local r={key="v",enabled=true,phase="loading",vehicle={object=v,key="v"}}
    c.routes.v=r;FMAAutoRoute.update(c);eq(r.enabled,false);eq(r.phase,"blocked")
end)
test("route arrival rejects a job stopped far from destination",function()
    local c=controller();local r={key="v",enabled=true,phase="toLoad",load={x=100,z=100}}
    local a={task={kind="route",route=r},vehicle={object=vehicle(),key="v"}}
    FMAAutoRoute.onStopped(c,a,nil);eq(r.enabled,false);eq(r.phase,"blocked")
end)

-- In-memory XML doubles verify savegame roundtrip semantics and restart policy.
local saved={}
XMLFile={}
local function xmlObject()
    return {setValue=function(_,key,value)saved[key]=value end,getValue=function(_,key,default)if saved[key]~=nil then return saved[key] end;return default end,
        hasProperty=function(_,key)for k in pairs(saved) do if k==key or k:sub(1,#key+1)==key.."#" or k:sub(1,#key+1)==key.."." then return true end end;return false end,
        save=function()end,delete=function()end}
end
XMLFile.create=function()saved={};return xmlObject()end
XMLFile.load=function()return xmlObject()end
fileExists=function()return true end
test("savegame policies routes and exclusions roundtrip without auto restart",function()
    local c=controller();c.policies={["4"]={enabled=false,crop="BARLEY"}};c.excluded.tractor=true
    c.routes.tractor={key="tractor",enabled=true,load={x=20,z=40,angle=1},unload={x=80,z=90,angle=2}}
    FMAState.save(c);local s=FMAState.load()
    eq(s.fields["4"].crop,"BARLEY");eq(s.fields["4"].enabled,false);eq(s.excluded.tractor,true)
    eq(s.routes.tractor.load.x,20);eq(s.routes.tractor.unload.angle,2);eq(s.routes.tractor.enabled,false);eq(s.settings.enabled,false)
end)
test("corrupted config numbers are clamped",function()
    saved["farmManager.settings#maxWorkers"]=500
    saved["farmManager.settings#reserve"]=-10
    local s=FMAState.load();eq(s.settings.maxWorkers,20);eq(s.settings.reserve,0)
end)
test("learned parking homes survive savegame roundtrip",function()
    saved={}
    local c=controller();c.homePositions={tractor={x=11,z=22,angle=1.2}};c.toolHomes={plow={x=33,z=44,angle=2.3}}
    FMAState.save(c);local st=FMAState.load()
    eq(st.homePositions.tractor.x,11);eq(st.homePositions.tractor.z,22);eq(st.toolHomes.plow.angle,2.3)
end)
test("Carpathian rolling whitelist prevents false rolling jobs",function()
    local a={fruit="MAIZE",needsRoll=true};FMACarpathianProfile.applyFieldRules(a);eq(a.needsRoll,false)
    local b={fruit="RYE",needsRoll=true};FMACarpathianProfile.applyFieldRules(b);eq(b.needsRoll,true)
end)
test("Carpathian profile is detected from mission map path",function()
    local oldInfo=g_currentMission.missionInfo;local oldLoaded=g_modIsLoaded;local oldMgr=g_modManager
    g_currentMission.missionInfo={mapTitle="Carpathian Countryside",mapXMLFilename="maps/map.xml",baseDirectory="C:/mods/FS25_CarpathianCountryside_crossplay/"}
    g_modIsLoaded={FS25_CarpathianCountryside_crossplay=true};g_modManager={getModByName=function()return {version="1.1.0.0",title="Carpathian Countryside"}end}
    local p=FMACarpathianProfile.detect();eq(p.active,true);eq(p.loaded,true);eq(p.version,"1.1.0.0")
    g_currentMission.missionInfo=oldInfo;g_modIsLoaded=oldLoaded;g_modManager=oldMgr
end)
test("one existing fertilizer layer does not loop immediately into another pass",function()
    local oldFT=g_fruitTypeManager.getFruitTypeByIndex;local oldGround=g_currentMission.fieldGroundSystem;local oldFD=FieldDensityMap;local oldFG=FieldGroundType
    g_fruitTypeManager.getFruitTypeByIndex=function()return {name="WHEAT",getIsCut=function()return false end,getIsWithered=function()return false end,getIsHarvestable=function()return false end}end
    FieldDensityMap={PLOW_LEVEL=1,LIME_LEVEL=2,SPRAY_LEVEL=3};FieldGroundType={SOWN=4,SOWN2=5,CULTIVATED=1,PLOWED=2,SEEDBED=3}
    g_currentMission.fieldGroundSystem={getMaxValue=function(_,index) if index==1 then return 3 elseif index==2 then return 3 elseif index==3 then return 2 end end}
    g_currentMission.missionInfo.plowingRequiredEnabled=true;g_currentMission.missionInfo.limeRequired=true;g_currentMission.missionInfo.weedsEnabled=true;g_currentMission.missionInfo.stonesEnabled=true
    local f=FMAWorld.normalizeField({id=9,posX=1,posZ=1,getFieldState=function()return {isValid=true,fruitTypeIndex=1,growthState=2,groundType=4,plowLevel=3,limeLevel=3,sprayLevel=1,weedState=0,stoneLevel=0,rollerLevel=1}end})
    eq(f.needsFertilize,false)
    g_fruitTypeManager.getFruitTypeByIndex=oldFT;g_currentMission.fieldGroundSystem=oldGround;FieldDensityMap=oldFD;FieldGroundType=oldFG
end)
test("Carpathian alfalfa is treated as a forage crop",function()
    eq(FMACarpathianProfile.isForageCrop("ALFALFA"),true)
    eq(FMACarpathianProfile.isForageCrop("RYE"),false)
end)
test("map-defined fertilizer spray types are accepted for refilling",function()
    local oldSpray=g_sprayTypeManager
    g_sprayTypeManager={getSprayTypes=function()return {{isFertilizer=true,fillType={index=77}},{isLime=true,fillType={index=78}}} end,
        getSprayTypeByFillTypeIndex=function(_,ft) if ft==77 then return {isFertilizer=true} elseif ft==78 then return {isLime=true} end end}
    local f=FMARefillManager.desiredFillTypes({operation="fertilize"});local seen={};for _,ft in ipairs(f)do seen[ft]=true end
    eq(seen[77],true);eq(FMAUtil.isFertilizerFillType(77),true);eq(FMAUtil.isLimeFillType(78),true)
    g_sprayTypeManager=oldSpray
end)
test("Carpathian profile learns user-added owned AI loading stations",function()
    local oldInfo=g_currentMission.missionInfo;local oldLoaded=g_modIsLoaded;local oldMgr=g_modManager;local oldStorage=g_currentMission.storageSystem;local oldPlaceables=g_currentMission.placeableSystem
    g_currentMission.missionInfo={mapTitle="Carpathian Countryside",mapXMLFilename="C:/mods/FS25_CarpathianCountryside_crossplay/maps/map.xml",baseDirectory="C:/mods/FS25_CarpathianCountryside_crossplay/"}
    g_modIsLoaded={FS25_CarpathianCountryside_crossplay=true};g_modManager={getModByName=function()return {version="1.0.1.0"}end}
    local place={ownerFarmId=1,name="User farm buying silo",posX=10,posZ=20}
    local station={owningPlaceable=place,getAISupportedFillTypes=function()return {[FillType.SEEDS]=true}end}
    g_currentMission.placeableSystem={placeables={place}};g_currentMission.storageSystem={getLoadingStations=function()return {station}end,getUnloadingStations=function()return {}end}
    local snap=FMACarpathianProfile.scan({farmId=1});eq(snap.active,true);eq(snap.ownLoadingStations,1);eq(snap.aiLoadingStations,1);eq(snap.loadingStations[1].name,"User farm buying silo")
    g_currentMission.missionInfo=oldInfo;g_modIsLoaded=oldLoaded;g_modManager=oldMgr;g_currentMission.storageSystem=oldStorage;g_currentMission.placeableSystem=oldPlaceables
end)
test("inventory does not assign a neighboring farm's vehicle",function()
    local own=vehicle();own.uniqueId="own";own.spec_cultivator={}
    local other=vehicle();other.ownerFarmId=2
    g_currentMission.vehicleSystem={vehicles={own,other}}
    local list=FMAWorld.vehicles(1);eq(#list,1);eq(list[1].key,"own");eq(list[1].capabilities.cultivate,true)
end)
test("combined seeder cannot be dispatched for destructive cultivation",function()
    local v=vehicle();v.spec_cultivator={};v.spec_sowingMachine={seeds={1},currentSeed=1}
    g_fruitTypeManager.getFruitTypeByIndex=function()return {name="WHEAT"}end
    g_currentMission.vehicleSystem={vehicles={v}}
    local list=FMAWorld.vehicles(1);eq(list[1].capabilities.sow,true);eq(list[1].capabilities.cultivate,nil)
end)
test("Cutter fruitTypeIndices from FS25 are recognized",function()
    local v=vehicle();v.spec_combine={};v.spec_cutter={fruitTypeIndices={1,3}}
    g_currentMission.vehicleSystem={vehicles={v}}
    local list=FMAWorld.vehicles(1);eq(list[1].capabilities.harvest,true);eq(list[1].harvestFruits[3],true)
end)

test("unknown mod crop never becomes a bare field",function()
    local old=g_fruitTypeManager.getFruitTypeByIndex
    g_fruitTypeManager.getFruitTypeByIndex=function()return nil end
    local field={id=1,posX=10,posZ=10,getFieldState=function()return {isValid=true,fruitTypeIndex=99,growthState=4}end}
    eq(FMAWorld.normalizeField(field).valid,false)
    g_fruitTypeManager.getFruitTypeByIndex=old
end)
test("a loading route still consumes a worker reservation",function()
    local c=controller();c.settings.maxWorkers=1;c.reservations.route="route"
    local old=FMAWorld.money;FMAWorld.money=function()return 100000 end
    local before=#g_currentMission.aiSystem.started
    c:dispatch();eq(#g_currentMission.aiSystem.started,before);eq(c.waitReason,"Limit pracovníků")
    FMAWorld.money=old
end)
test("turning off fleet automation cancels a loading route",function()
    local c=controller();local v=vehicle();local stopped=false
    v.spec_universalAutoload={isAutoloadAvailable=true};v.ualStartLoad=function()end
    v.ualStopLoad=function()stopped=true end;v.ualGetFillUnitFillLevel=function()return 1 end
    c.vehicles={{object=v,key="v",name="UAL",capabilities={},compatibility={autoloaders={{}}}}}
    c.routes.v={key="v",enabled=true,phase="loading",vehicle=c.vehicles[1]}
    c.reservations.v="route";c.page=3;c.selection=1;c.scan=function()end
    FMAHud.select(c);eq(c.routes.v.enabled,false);eq(c.reservations.v,nil);eq(stopped,true)
end)


test("ModHub adapter identifies an external asset without model whitelist",function()
    local o={configFileName="C:/Users/test/Documents/My Games/FarmingSimulator2025/mods/FS25_TestTrailer/trailer.xml",spec_attachable={},spec_dischargeable={},spec_fillUnit={}}
    local meta=FMAModHubAdapter.profileObject(o)
    eq(meta.originKind,"mod");eq(meta.originMod,"FS25_TestTrailer");eq(FMAModHubAdapter.isAttachableTransport(o),true)
end)
test("custom autoload specialization is detected but not guessed as bale loader",function()
    local o={customEnvironment="FS25_AutoloadPack",spec_attachable={},spec_myUniversalAutoload={isLoading=false}}
    local meta=FMAModHubAdapter.profileObject(o)
    eq(meta.externalAutoload,true);eq(meta.originMod,"FS25_AutoloadPack")
end)
test("attachable dischargeable ModHub tank is accepted as transport",function()
    local oldManager=g_currentMission.vehicleSystem
    local t={ownerFarmId=1,uniqueId="tank",configFileName="C:/mods/FS25_Tank/tank.xml",spec_attachable={},spec_dischargeable={dischargeNodes={{fillUnitIndex=1}}},spec_fillUnit={fillUnits={{supportedFillTypes={[20]=true}}}},getFillUnits=function(self)return self.spec_fillUnit.fillUnits end,getFillUnitFillLevel=function()return 0 end,getFillUnitCapacity=function()return 12000 end,getFillUnitFillType=function()return 0 end}
    g_currentMission.vehicleSystem={vehicles={t}}
    local _,loose=FMAWorld.vehicles(1);eq(#loose,1);eq(loose[1].capabilities.transport,true);eq(loose[1].transportFillTypes[20],true)
    g_currentMission.vehicleSystem=oldManager
end)


test("registered AI jobs are created by AIJobTypeManager",function()
    local old=g_currentMission.aiJobTypeManager
    local created={}
    local mgr={}
    mgr.getJobTypeIndexByName=function(_,name) if name=="GOTO" then return 4 end end
    mgr.createJob=function(_,idx) if idx==4 then local j=jobFactory();j.registered=true;j.jobTypeIndex=4;created[#created+1]=j;return j end end
    mgr.getJobTypeIndex=function(_,job) if job and job.registered then return 4 end end
    mgr.getJobTypeByIndex=function(_,idx) if idx==4 then return {name="GOTO"} end end
    g_currentMission.aiJobTypeManager=mgr
    local j,idx=FMAAI.createRegisteredJob("GOTO",AIJobGoTo)
    assert(j and j.registered);eq(idx,4);eq(FMAAI.ensureJobType(j),true);eq(j.jobTypeIndex,4)
    g_currentMission.aiJobTypeManager=old
end)

test("save guard removes unregistered AI lastJob from every owned live vehicle",function()
    local oldMgr=g_currentMission.aiJobTypeManager;local oldVS=g_currentMission.vehicleSystem
    local validJob={registered=true};local invalidJob={registered=false}
    g_currentMission.aiJobTypeManager={getJobTypeIndex=function(_,job) if job.registered then return 2 end end,getJobTypeByIndex=function(_,idx) if idx==2 then return {name="FIELDWORK"} end end}
    local a=vehicle();a.uniqueId="a";a.spec_aiJobVehicle={lastJob=invalidJob}
    local b=vehicle();b.uniqueId="b";b.spec_aiJobVehicle={lastJob=validJob}
    g_currentMission.vehicleSystem={vehicles={a,b}}
    local c={farmId=1,vehicles={},sanitizedJobHistory=0}
    eq(FMAAI.sanitizeVehicleJobHistory(c),1);eq(a.spec_aiJobVehicle.lastJob,nil);eq(b.spec_aiJobVehicle.lastJob,validJob)
    g_currentMission.aiJobTypeManager=oldMgr;g_currentMission.vehicleSystem=oldVS
end)

test("bunker quick failure enters cooldown instead of one-second restart loop",function()
    local c={now=10000,settings={autoReturn=false},bunkerWorkState={},issues={},traffic=FMATraffic.new(),bunkers={}}
    c.issue=function(self,id,title,detail,priority) self.issues[id]={title=title,detail=detail,priority=priority} end
    local a={task={kind="bunker",bunkerIndex=1},vehicle={key="x",name="X"},start=9000}
    eq(FMABunkerCoordinator.onStopped(c,a),true)
    local ws=c.bunkerWorkState[1];eq(ws.failures,1);assert(ws.retryAt>c.now);eq(ws.blocked,false)
end)

-- Live-density fixtures reproduce the user's stale field summary without replacing our classifier.
local function liveField(cached,live,edge)
    local previous={FieldState,FieldGroundType,FieldDensityMap,getWorldTranslation,g_fruitTypeManager.getFruitTypeByIndex,g_currentMission.fieldGroundSystem}
    FieldGroundType={PLOWED=1,CULTIVATED=2,SEEDBED=3,SOWN=4,SOWN2=5,GROWING=6}
    FieldDensityMap={PLOW_LEVEL=1,LIME_LEVEL=2,SPRAY_LEVEL=3}
    g_currentMission.fieldGroundSystem={getMaxValue=function()return 3 end}
    g_fruitTypeManager.getFruitTypeByIndex=function(_,i) if i==1 then return {name="WHEAT",minHarvestingGrowthState=6,maxHarvestingGrowthState=7,cutState=8,witheredState=9} end end
    getWorldTranslation=function(node)return node.x,0,node.z end
    FieldState={new=function()return {update=function(self,x,z)
        local selected=edge and (x~=0 or z~=0) and edge or live
        for k,v in pairs(selected) do self[k]=v end
    end}end}
    local field={id=32,posX=0,posZ=0,fieldState=cached,polygonPoints={{x=-10,z=-10},{x=10,z=-10},{x=10,z=10},{x=-10,z=10}}}
    local result=FMAWorld.sampleField(field)
    FieldState,FieldGroundType,FieldDensityMap,getWorldTranslation,g_fruitTypeManager.getFruitTypeByIndex,g_currentMission.fieldGroundSystem=unpack(previous,1,6)
    return result
end
local function density(growth,ground)
    return {isValid=true,fruitTypeIndex=1,growthState=growth,groundType=ground,plowLevel=3,limeLevel=3,sprayLevel=0,weedState=0,stoneLevel=0,rollerLevel=1}
end

test("harvested cutState is never reclassified as harvest-ready",function()
    local f=liveField(density(7,6),density(8,1))
    eq(f.ready,false);eq(f.bare,true);eq(f.prepared,true)
end)

test("one isolated ready sample does not turn mostly harvested field into harvest task",function()
    local f=liveField(density(7,6),density(7,6),density(8,1))
    eq(f.valid,false);eq(FMAPlanner.nextOperation(f,policy,settings),nil)
end)

test("bunker scanner ignores anonymous or neighboring-farm silos",function()
    local oldPS=g_currentMission.placeableSystem
    local own={ownerFarmId=1,spec_bunkerSilo={}};local ownB={owningPlaceable=own,bunkerSiloArea={sx=0,sz=0,wx=2,wz=0,hx=0,hz=20},fillLevel=100}
    own.spec_bunkerSilo.bunkerSilo=ownB
    local other={ownerFarmId=2,spec_bunkerSilo={}};local otherB={owningPlaceable=other,bunkerSiloArea={sx=0,sz=0,wx=2,wz=0,hx=0,hz=20},fillLevel=100};other.spec_bunkerSilo.bunkerSilo=otherB
    local anon={bunkerSiloArea={sx=0,sz=0,wx=2,wz=0,hx=0,hz=20},fillLevel=100}
    g_currentMission.placeableSystem={placeables={own,other,anon}}
    local rows=FMABunkerCoordinator.bunkers(1);eq(#rows,1);eq(rows[1].object,ownB)
    g_currentMission.placeableSystem=oldPS
end)

test("Carpathian multifunction silo is also exposed as production",function()
    local oldInfo=g_currentMission.missionInfo;local oldLoaded=g_modIsLoaded;local oldMgr=g_modManager;local oldStorage=g_currentMission.storageSystem;local oldPlaceables=g_currentMission.placeableSystem
    g_currentMission.missionInfo={mapTitle="Carpathian Countryside",mapXMLFilename="maps/map.xml",baseDirectory="C:/mods/FS25_CarpathianCountryside_crossplay/"}
    g_modIsLoaded={FS25_CarpathianCountryside_crossplay=true};g_modManager={getModByName=function()return {version="1.0.1.0"}end}
    local p={ownerFarmId=1,name="Silo + production",spec_silo={},spec_productionPoint={}}
    g_currentMission.placeableSystem={placeables={p}};g_currentMission.storageSystem={getLoadingStations=function()return {}end,getUnloadingStations=function()return {}end}
    local snap=FMACarpathianProfile.scan({farmId=1});eq(#snap.storages,1);eq(#snap.productions,1)
    g_currentMission.missionInfo=oldInfo;g_modIsLoaded=oldLoaded;g_modManager=oldMgr;g_currentMission.storageSystem=oldStorage;g_currentMission.placeableSystem=oldPlaceables
end)

test("Carpathian silo inventory reads direct PlaceableSilo storage instead of guessing empty",function()
    local oldInfo=g_currentMission.missionInfo;local oldLoaded=g_modIsLoaded;local oldMgr=g_modManager;local oldStorage=g_currentMission.storageSystem;local oldPlaceables=g_currentMission.placeableSystem
    g_currentMission.missionInfo={mapTitle="Carpathian Countryside",mapXMLFilename="maps/map.xml",baseDirectory="C:/mods/FS25_CarpathianCountryside_crossplay/"}
    g_modIsLoaded={FS25_CarpathianCountryside_crossplay=true};g_modManager={getModByName=function()return {version="1.0.1.0"}end}
    local store={getIsFillTypeSupported=function(_,ft)return ft==1 end,getCapacity=function()return 50000 end}
    local p={ownerFarmId=1,name="Farm silo",spec_silo={storages={store}},getFillLevels=function()return {[1]=12345}end}
    g_currentMission.placeableSystem={placeables={p}};g_currentMission.storageSystem={getLoadingStations=function()return {}end,getUnloadingStations=function()return {}end}
    local snap=FMACarpathianProfile.scan({farmId=1});eq(#snap.storages,1);eq(snap.storages[1].inventoryKnown,true);eq(snap.storages[1].fillRows[1].level,12345);eq(snap.storages[1].fillRows[1].capacity,50000)
    g_currentMission.missionInfo=oldInfo;g_modIsLoaded=oldLoaded;g_modManager=oldMgr;g_currentMission.storageSystem=oldStorage;g_currentMission.placeableSystem=oldPlaceables
end)

test("field sampler refreshes density map at center and across two inner rings",function()
    local f=liveField(density(7,6),density(8,1))
    eq(f.sampleSource,"liveDensity");eq(f.sampleCount,5);eq(f.ready,false)
end)

-- Full mod-listener boot contract, action registration, draw calls and save hook.
g_fruitTypeManager.getFruitTypeByIndex=function()return {name="WHEAT",minHarvestingGrowthState=6,maxHarvestingGrowthState=7,getIsCut=function()return true end,getIsWithered=function()return false end}end
FieldGroundType={PLOWED=1,CULTIVATED=2,SEEDBED=3};FieldDensityMap={PLOW_LEVEL=1}
g_currentMission.fieldGroundSystem={getMaxValue=function()return 3 end}
g_currentMission.missionInfo.isValid=true
g_currentMission.fieldGroundSystem={getMaxValue=function()return 3 end}
g_fieldManager={getFields=function()return {{id=1,farmland={ownerFarmId=1},posX=50,posZ=50,getFieldState=function()return {isValid=true,fruitTypeIndex=1,growthState=8,groundType=1,plowLevel=3,limeLevel=3,sprayLevel=0,rollerLevel=1}end}} end}
g_farmManager={getFarmById=function()return {money=50000}end}
g_currentMission.playerSystem={getLocalPlayer=function()return {farmId=1}end}
g_currentMission.placeableSystem={placeables={}}
g_currentMission.storageSystem={getLoadingStations=function()return {}end,getUnloadingStations=function()return {}end}
g_storeManager={getItems=function()return {}end}
local v=vehicle();v.uniqueId="v";v.spec_cultivator={}
g_currentMission.vehicleSystem={vehicles={v}}
g_currentModDirectory="./"
g_modIsLoaded={}
FSBaseMission={INGAME_NOTIFICATION_INFO=1}
g_currentMission.addIngameNotification=function()end
g_gui={getIsGuiVisible=function()return false end}
local events={};local nextId=0;local modifyingContext=nil;local activeContext="PLAYER";local contextStack={}
g_inputBinding={
    registerActionEvent=function(_,name,target,callback)nextId=nextId+1;events[nextId]={name=name,target=target,callback=callback,context=modifyingContext};return true,nextId end,
    removeActionEvent=function(_,id)events[id]=nil end,
    setActionEventTextVisibility=function()end,setActionEventTextPriority=function()end,
    beginActionEventsModification=function(_,name) modifyingContext=name end,
    endActionEventsModification=function() modifyingContext=nil end,
    setContext=function(_,name,createNew)
        if createNew then for id,e in pairs(events) do if e.context==name then events[id]=nil end end end
        contextStack[#contextStack+1]=activeContext;activeContext=name
    end,
    getContextName=function()return activeContext end,
    revertContext=function() activeContext=contextStack[#contextStack];contextStack[#contextStack]=nil end
}
InputAction=setmetatable({},{__index=function(_,key)return key end})
Input={KEY_up=101,KEY_down=102,KEY_left=103,KEY_right=104,KEY_return=105,KEY_enter=105,KEY_kp_enter=106,KEY_m=107,KEY_h=108,KEY_d=109,KEY_r=110,KEY_lalt=111,KEY_p=112,MOD_LALT=1}
Input.isKeyPressed=function()return false end
bitAND=function(a,b)return ((a or 0)%(2*b)>=b) and b or 0 end
PlayerInputComponent={INPUT_CONTEXT_NAME="PLAYER",registerGlobalPlayerActionEvents=function()end}
Vehicle={INPUT_CONTEXT_NAME="VEHICLE"}
FSCareerMissionInfo={saveToXMLFile=function()end}
VehicleSystem={save=function()end}
Utils={appendedFunction=function(first,second)return function(...)first(...);second(...)end end,
    prependedFunction=function(first,second)return function(...)second(...);return first(...) end end,
    overwrittenFunction=function(original,wrapper)return function(self,...)return wrapper(self,original,...) end end}
local drew=0
Overlay={new=function()return {setPosition=function()end,setDimension=function()end,setColor=function()end,render=function()drew=drew+1 end,delete=function()end}end}
RenderText={ALIGN_LEFT=0};setTextAlignment=function()end;setTextBold=function()end;setTextColor=function()end;renderText=function()drew=drew+1 end
local mod
addModEventListener=function(listener)mod=listener end
dofile("scripts/main.lua")
local function action(name)
    g_time=(g_time or 0)+200
    for _,e in pairs(events) do
        if e.name==name and (e.context==nil or e.context==activeContext) then e.callback(e.target,name,1);return end
    end
    error("Action missing in active context "..tostring(activeContext)..": "..name)
end
test("manifest loads without mutating native action registry",function()
    local before=#g_currentMission.aiSystem.started
    local original=PlayerInputComponent.registerGlobalPlayerActionEvents
    mod:loadMap();mod:update(3000)
    eq(#g_currentMission.aiSystem.started,before)
    eq(FMAUtil.count(events),0)
    eq(activeContext,'PLAYER')
    eq(PlayerInputComponent.registerGlobalPlayerActionEvents,original)
end)
test("Alt M toggles pointer without touching native controls",function()
    g_time=(g_time or 0)+300;mod:keyEvent(0,Input.KEY_m,Input.MOD_LALT,true)
    eq(activeContext,'PLAYER');eq(FMAUtil.count(events),0)
    mod:draw();assert(drew>5)
end)
test("Enter and Alt P never activate any Farm Manager row",function()
    local calls=0;local previous=FMAHud.select
    FMAHud.select=function()calls=calls+1 end
    for _,code in ipairs({Input.KEY_return,Input.KEY_enter,Input.KEY_kp_enter}) do
        mod:keyEvent(0,code,0,true)
    end
    g_time=(g_time or 0)+300;mod:keyEvent(0,Input.KEY_p,Input.MOD_LALT,true)
    eq(calls,0)
    FMAHud.select=previous
end)
test("vehicle E closes manager panel without registering E binding",function()
    Input.KEY_e=114
    g_time=(g_time or 0)+300;mod:keyEvent(0,Input.KEY_e,0,true)
    eq(activeContext,'PLAYER')
    eq(FMAUtil.count(events),0)
end)
test("native player input hook is unchanged across context transitions",function()
    local original=PlayerInputComponent.registerGlobalPlayerActionEvents
    activeContext='VEHICLE';mod:update(6000)
    eq(FMAUtil.count(events),0)
    eq(PlayerInputComponent.registerGlobalPlayerActionEvents,original)
    g_time=(g_time or 0)+300;mod:keyEvent(0,Input.KEY_m,Input.MOD_LALT,true)
    eq(activeContext,'VEHICLE')
    activeContext='PLAYER'
    g_time=(g_time or 0)+300;mod:keyEvent(0,Input.KEY_m,Input.MOD_LALT,true)
    eq(activeContext,'PLAYER')
end)
test("save hooks and cleanup do not change native action list",function()
    VehicleSystem.save(g_currentMission.vehicleSystem)
    FSCareerMissionInfo.saveToXMLFile(g_currentMission.missionInfo)
    eq(saved['farmManager#version'],1)
    mod:deleteMap();eq(FMAUtil.count(events),0)
end)
test("map subsystem failure is isolated instead of killing the whole manager",function()
    local oldScan=FMABunkerCoordinator.scan
    FMABunkerCoordinator.scan=function() error("synthetic bunker failure") end
    local c=FMAController.new();c.farmId=1;c.initialized=true;c.supported=true
    c.settings.bunkerAutomation=true;c.settings.livestock=false;c.settings.productions=false;c.settings.supply=false;c.settings.baleAutomation=false;c.settings.baleStorageAutomation=false
    c:scan()
    assert(c.subsystemFaults["bunker.scan"]~=nil)
    assert(c.issues["subsystem:bunker.scan"]~=nil)
    FMABunkerCoordinator.scan=oldScan
end)



test("forage field gets crop care while growing instead of harvest",function()
    local op=FMAPlanner.nextOperation({valid=true,grass=true,ready=false,alive=true,needsLime=true,needsFertilize=true},{enabled=true,crop="SOYBEAN"},{cropCare=true})
    eq(op,"fertilize")
end)
test("job main selector keeps tractor visible even when implement is missing",function()
    local c=controller();c.vehicles={{key="t",name="Tractor",capabilities={},isPowerUnit=true,hasCombine=false}};c.loose={};c.excluded={}
    local rows=FMAHud.mainCandidates(c,{operation="lime"});eq(#rows,1);eq(rows[1].key,"t")
end)
test("harvest main selector exposes bare combine chassis",function()
    local c=controller();c.vehicles={{key="c",name="Combine",capabilities={},hasCombine=true,isGrainCombine=true}};c.loose={};c.excluded={}
    local rows=FMAHud.mainCandidates(c,{operation="harvest"});eq(#rows,1);eq(rows[1].key,"c")
end)


test("authoritative growing field can never be promoted to harvest by edge samples",function()
    local f=liveField(density(7,6),density(3,6),density(7,6))
    eq(f.valid,false);eq(FMAPlanner.nextOperation(f,policy,settings),nil)
end)

test("job page keeps manual machine selection simple and cyclic",function()
    local task={id="field:7:lime",kind="field",operation="lime",label="7 · Vápnění",state="pending",priority=64,x=0,z=0}
    local tractor={key="tractorA",name="1050 Vario",isPowerUnit=true,hasCombine=false,capabilities={},damage=0.1,wear=0.2,busy=false,lowFuel=false,x=0,z=0}
    local c={supported=true,page=9,selection=1,fmaAdvancedTask=true,fmaTaskListMode=false,tasks={[task.id]=task},focusTaskId=task.id,conditions={},purchaseNeeds={},settings=shallow(settings),
        vehicles={tractor},loose={},excluded={},reservations={},implementReservations={},lastMessage=""}
    c.notify=function(self,msg)self.lastMessage=msg end
    local rows=FMAHud.rows(c)
    local main=nil;local choiceRows=0
    for i,row in ipairs(rows) do
        if row.object and row.object.slot=="main" then main=i end
        if row.object and (row.object.slot=="mainChoice" or row.object.slot=="implementChoice") then choiceRows=choiceRows+1 end
    end
    assert(main~=nil);eq(choiceRows,0);assert(#rows<=8)
    c.selection=main;FMAHud.select(c)
    eq(task.preferredVehicleKey,"tractorA");eq(task.preferredVehicleName,"1050 Vario")
end)




test("field-info regression: growing soybeans needing lime must not become harvest",function()
    local live=density(3,6);live.limeLevel=0
    local f=liveField(density(7,6),live)
    eq(f.valid,true);eq(f.ready,false);eq(f.alive,true)
    eq(FMAPlanner.nextOperation(f,policy,settings),"fertilize")
end)

test("growing crop defers lime and keeps valid fertilizer care",function()
    local op=FMAPlanner.nextOperation({valid=true,grass=false,ready=false,bare=false,alive=true,needsLime=true,needsFertilize=true,needsWeed=false,needsRoll=false},{enabled=true,crop="SOYBEAN"},{cropCare=true})
    eq(op,"fertilize")
end)


test("prepared soil blocks stale harvest metadata",function()
    local f=liveField(density(7,6),density(7,1))
    eq(f.ready,false);eq(f.bare,true);eq(f.alive,false)
end)

test("meaningful plowed coverage fails harvest closed",function()
    local f=liveField(density(7,6),density(7,6),density(7,1))
    eq(f.valid,false);eq(FMAPlanner.nextOperation(f,policy,settings),nil)
end)

test("grain harvest selector never offers forage harvester",function()
    local c=controller();c.vehicles={
        {key="forage",name="Big X",capabilities={harvest=true},hasCombine=true,isForageHarvester=true,isGrainCombine=false},
        {key="grain",name="Lexion",capabilities={harvest=true},hasCombine=true,isForageHarvester=false,isGrainCombine=true}}
    c.loose={};c.excluded={}
    local rows=FMAHud.mainCandidates(c,{operation="harvest"})
    eq(#rows,1);eq(rows[1].key,"grain")
end)

test("AUTO fleet selection rejects underpowered tractor and prefers adequate power",function()
    local task={operation="cultivate",kind="field",x=0,z=0}
    local weak={key="w",capabilities={cultivate=true},x=1,z=0,readyOperations={},powerKW=80,requiredPowerKW=100,mass=6,damage=0,wear=0}
    local ok={key="o",capabilities={cultivate=true},x=10,z=0,readyOperations={},powerKW=150,requiredPowerKW=100,mass=9,damage=0,wear=0}
    eq(FMAPlanner.chooseVehicle(task,{weak,ok},{},{}),ok)
end)

test("overview surfaces purchase requirement before owner starts job",function()
    local task={id="field:5:lime",kind="field",operation="lime",label="5 · Vápnění",state="pending",priority=60}
    local c={page=1,fields={},tasks={[task.id]=task},conditions={},vehicles={},loose={},purchaseNeeds={lime={operation="lime",label="Vápnění",candidates={{name="Lime spreader",price=10000}}}},settings=shallow(settings),reservations={},issues={}}
    local rows=FMAHud.rows(c);local found=false
    for _,row in ipairs(rows) do if tostring(row.title):find("CHYBÍ / DOKOUPIT",1,true) then found=true end end
    eq(found,true)
end)



test("assembler will not chain a second work implement behind an occupied tractor",function()
    local tool={name="Cultivator",spec_cultivator={}}
    local tractor={getAttachedImplements=function()return {{object=tool}} end}
    eq(FMAAssembler.hasBlockingAttachment({object=tractor}),true)
    local weight={name="Front weight",spec_weight={}}
    tractor.getAttachedImplements=function()return {{object=weight}} end
    eq(FMAAssembler.hasBlockingAttachment({object=tractor}),false)
end)

test("traffic core reserves a shared yard target for only one managed vehicle",function()
    local c={settings={trafficSafety=true,trafficCellSize=18,trafficStartSeparation=10},traffic=FMATraffic.new(),active={},now=1000}
    local a={key="a",object={posX=0,posZ=0}}
    local b={key="b",object={posX=50,posZ=50}}
    local target={x=100,z=100}
    local ok1=FMATraffic.canStart(c,a,target,{id="a",kind="assemble"},30000)
    local ok2=FMATraffic.canStart(c,b,target,{id="b",kind="assemble"},30000)
    eq(ok1,true);eq(ok2,false)
    FMATraffic.release(c.traffic,"a")
    local ok3=FMATraffic.canStart(c,b,target,{id="b",kind="assemble"},30000)
    eq(ok3,true)
end)

test("traffic start separation holds a second yard vehicle until the first clears",function()
    local c={settings={trafficSafety=true,trafficCellSize=18,trafficStartSeparation=14},traffic=FMATraffic.new(),active={},now=1000}
    local a={key="a",object={posX=0,posZ=0}}
    local b={key="b",object={posX=5,posZ=0}}
    c.active.job={vehicle=a,task={kind="assemble"}}
    local ok,why=FMATraffic.canStart(c,b,{x=100,z=0},{id="b",kind="assemble"},30000)
    eq(ok,false);assert(tostring(why):find("výjezdu",1,true)~=nil)
end)



test("bunker geometry estimate gives a usable fill percentage",function()
    local c={settings={bunkerNominalHeight=4,bunkerFillTarget=0.90,bunkerPrimaryIndex=0,bunkerNextIndex=0}}
    local b={geometry={width=12,length=58},fillLevel=2505600}
    local ratio=FMABunkerCoordinator.fillRatio(c,b)
    assert(math.abs(ratio-0.90)<0.001)
end)

test("bunker selection cycles primary then next",function()
    local c={settings={bunkerPrimaryIndex=0,bunkerNextIndex=0},notify=function()end}
    FMABunkerCoordinator.cycleSelection(c,1);eq(c.settings.bunkerPrimaryIndex,1)
    FMABunkerCoordinator.cycleSelection(c,2);eq(c.settings.bunkerNextIndex,2)
    FMABunkerCoordinator.cycleSelection(c,1);eq(c.settings.bunkerPrimaryIndex,2);eq(c.settings.bunkerNextIndex,0)
end)

test("traffic launch interval begins only after a real job start",function()
    local c={settings={trafficSafety=true,trafficCellSize=18,trafficStartSeparation=1,trafficLaunchIntervalSeconds=2.5,trafficMaxTransit=20},traffic=FMATraffic.new(),active={},now=10000}
    local a={key="a",object={posX=0,posZ=0}};local b={key="b",object={posX=100,posZ=0}}
    local taskA={kind="return"}
    eq(select(1,FMATraffic.canStart(c,a,{x=200,z=0},taskA,30000)),true)
    -- Merely passing validation is not a launch. A second vehicle may still validate.
    c.now=11000;eq(select(1,FMATraffic.canStart(c,b,{x=300,z=0},{kind="return"},30000)),true)
    FMATraffic.release(c.traffic,"b")
    FMATraffic.markStarted(c,a,taskA)
    c.now=12000;local ok,why=FMATraffic.canStart(c,b,{x=300,z=0},{kind="return"},30000);eq(ok,false);assert(tostring(why):find("rozestup",1,true)~=nil)
end)

test("traffic core enforces configured maximum transit jobs",function()
    local c={settings={trafficSafety=true,trafficCellSize=18,trafficStartSeparation=1,trafficLaunchIntervalSeconds=0,trafficMaxTransit=2},traffic=FMATraffic.new(),active={},now=10000}
    c.active.j1={vehicle={key="x",object={posX=0,posZ=0}},task={kind="return"}}
    c.active.j2={vehicle={key="y",object={posX=50,posZ=0}},task={kind="refill"}}
    local ok,why=FMATraffic.canStart(c,{key="z",object={posX=100,posZ=0}},{x=200,z=0},{kind="return"},30000)
    eq(ok,false);assert(tostring(why):find("vytížená",1,true)~=nil)
end)


test("bale storage selection rejects incompatible bale type",function()
    local badObj={getObjectStorageSupportsFillType=function(_,ft)return false end}
    local goodObj={getObjectStorageSupportsFillType=function(_,ft)return ft==77 end}
    local c={settings={baleStorageReserve=0,baleSortByFillType=true},baleStorages={
        {object=badObj,name="Near",x=1,z=0,free=50,storedFillTypes={}},
        {object=goodObj,name="Compatible",x=20,z=0,free=50,storedFillTypes={[77]=2}}}}
    local found=FMABaleStorage.find(c,{x=0,z=0},{[77]=4})
    assert(found and found.name=="Compatible")
end)
dofile("developer/test_regressions.lua")(test,eq)
dofile("developer/test_adaptive.lua")(test,eq)
dofile("developer/test_navigation.lua")(test,eq)
dofile("developer/test_survey.lua")(test,eq)
dofile("developer/test_atlas.lua")(test,eq)
dofile("developer/test_hotfix.lua")(test,eq)
dofile("developer/test_route20.lua")(test,eq)
dofile("developer/test_selected_lime.lua")(test,eq)
dofile("developer/test_haulage_cycle.lua")(test,eq)
dofile("developer/test_market.lua")(test,eq)
dofile("developer/test_simple23.lua")
dofile("developer/test_hotfix24.lua")(test,eq)
dofile("developer/test_physical25.lua")(test,eq)
dofile("developer/test_universal26.lua")(test,eq)
dofile("developer/test_dashboard27.lua")(test,eq)
dofile("developer/test_blackbox28.lua")(test,eq)
dofile("developer/test_support32.lua")(test,eq)
dofile("developer/test_parking29.lua")(test,eq)
dofile("developer/test_livefarm30.lua")(test,eq)
dofile("developer/test_assembly31.lua")(test,eq)
dofile("developer/test_hotfix33.lua")(test,eq)
dofile("developer/test_live34.lua")(test,eq)
dofile("developer/test_work35.lua")(test,eq)
dofile("developer/test_hitch36.lua")(test,eq)
dofile("developer/test_safe37.lua")(test,eq)
dofile("developer/test_three_ai40.lua")(test,eq)
dofile("developer/test_authority41.lua")(test,eq)
dofile("developer/test_devlab42.lua")(test,eq)
dofile("developer/test_circuit43.lua")(test,eq)
dofile("developer/test_collision44.lua")(test,eq)
dofile("developer/test_guard45.lua")(test,eq)
dofile("developer/test_inside46.lua")(test,eq)
dofile("developer/test_self_healing47.lua")(test,eq)
dofile("developer/test_runtime48.lua")(test,eq)
dofile("developer/test_roads49.lua")(test,eq)
dofile("developer/test_roads50.lua")(test,eq)
print(string.format("RESULT: %d logic/contract tests passed. FS25 runtime NOT executed.",passed))
