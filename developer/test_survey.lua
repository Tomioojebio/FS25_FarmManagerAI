return function(test,eq)
local function fixture()
    return {farmId=1,now=0,initialized=true,supported=true,settings={surveyEnabled=true,surveyRadius=230,surveyViewRadius=180},farmSurvey={center={x=0,z=0},manual=true,edges={}},navigationMap={routes={},hazards={}},active={},homePositions={},toolHomes={},learnedPoints={},digitalMap={zones={}}}
end
local function tractor(x,z)
    return {ownerFarmId=1,posX=x or 0,posZ=z or 0,rootNode=11}
end
local oldManual=FMAGameNative.isManuallyControlled
test('live yard mapper rejects stationary tractor and wheel-only turning',function()
    local c=fixture();local v=tractor(0,0)
    FMAGameNative.isManuallyControlled=function() return true end
    for t=1,10 do c.now=t*1000;FMAFarmSurvey.observeManual(c,v) end
    eq(FMAFarmSurvey.summary(c).mapped,0)
    FMAGameNative.isManuallyControlled=oldManual
end)
test('live yard mapper paints actual manual motion without teleport gaps',function()
    local c=fixture();local v=tractor(0,0)
    FMAGameNative.isManuallyControlled=function()return true end
    c.now=1000;FMAFarmSurvey.observeManual(c,v)
    v.posX=7;c.now=2000;FMAFarmSurvey.observeManual(c,v)
    eq(FMAFarmSurvey.summary(c).mapped,1)
    v.posX=90;c.now=3000;FMAFarmSurvey.observeManual(c,v)
    eq(FMAFarmSurvey.summary(c).mapped,1)
    FMAGameNative.isManuallyControlled=oldManual
end)
test('yard mapper does not assume remote fields belong to the yard',function()
    local c=fixture();local v=tractor(800,800)
    FMAGameNative.isManuallyControlled=function()return true end
    c.now=1000;FMAFarmSurvey.observeManual(c,v)
    v.posX=807;c.now=2000;FMAFarmSurvey.observeManual(c,v)
    eq(FMAFarmSurvey.summary(c).mapped,0)
    FMAGameNative.isManuallyControlled=oldManual
end)
test('farm centre is chosen near known parking rather than distant field',function()
    local c=fixture();c.farmSurvey.center=nil;c.farmSurvey.manual=false
    c.homePositions={a={x=21,z=31},b={x=25,z=30},c={x=22,z=32}}
    c.learnedPoints={far={x=960,z=900,role='POLE'}}
    eq(FMAFarmSurvey.initialize(c),true)
    assert(c.farmSurvey.center and c.farmSurvey.center.x<100)
end)
test('unverified AI travel never writes safe farm edges',function()
    local c=fixture();local v=tractor(15,0)
    eq(FMAFarmSurvey.summary(c).mapped,0)
    local active={vehicle={key='a',object=v},navSamples={{x=0,z=0},{x=7,z=0},{x=15,z=0}}}
    -- Samples are transient until original navigation.finish approves arrival.
    eq(FMAFarmSurvey.summary(c).mapped,0)
    eq(FMAFarmSurvey.confirmTransfer(c,active),2)
    eq(FMAFarmSurvey.summary(c).confirmed,2)
end)
test('connected observed edges plan same-direction advisory path',function()
    local c=fixture()
    local active={vehicle={key='a',object=tractor(20,0)},navSamples={{x=0,z=0},{x=5,z=0},{x=10,z=0},{x=15,z=0},{x=20,z=0}}}
    FMAFarmSurvey.confirmTransfer(c,active)
    local path=FMAFarmSurvey.plan(c,{x=0,z=0},{x=20,z=0},'SOLO')
    assert(path and #path>=3)
    local reverse=FMAFarmSurvey.plan(c,{x=20,z=0},{x=0,z=0},'SOLO')
    eq(reverse,nil)
end)
test('towed rigs cannot inherit untested solo clearance',function()
    local c=fixture()
    FMAFarmSurvey.confirmTransfer(c,{vehicle={key='a',object=tractor(20,0)},navSamples={{x=0,z=0},{x=7,z=0},{x=14,z=0},{x=20,z=0}}})
    eq(FMAFarmSurvey.plan(c,{x=0,z=0},{x=20,z=0},'TOWED'),nil)
end)
test('yard manual centre overrides only own position and preserves old map edges',function()
    local c=fixture();c.farmSurvey.edges.old={ax=2,az=2,bx=3,bz=3}
    local ok=FMAFarmSurvey.anchor(c,{x=12,z=18})
    eq(ok,true);eq(c.farmSurvey.center.z,18)
    eq(FMAFarmSurvey.summary(c).mapped,1)
end)
test('map draws live path and facilities without steering the vehicle',function()
    local c=fixture();c.digitalMap={zones={{kind='SKLAD',x=10,z=0}}}
    FMAFarmSurvey.confirmTransfer(c,{vehicle={key='a',object=tractor(12,0)},navSamples={{x=0,z=0},{x=6,z=0},{x=12,z=0}}})
    local drawn=0;local turns=0
    local overlay={setPosition=function()end,setDimension=function()end,setColor=function()end,render=function() drawn=drawn+1 end,setRotation=function() turns=turns+1 end}
    local rect=function() drawn=drawn+1 end
    FMAFarmSurvey.draw(c,overlay,{x=.1,y=.1,w=.3,h=.28},rect,function()end)
    assert(drawn>2 and turns>=2)
end)
test('yard painter is disabled by the owner without losing previous observations',function()
    local c=fixture();local v=tractor(0,0)
    c.settings.surveyEnabled=false
    FMAGameNative.isManuallyControlled=function()return true end
    local previousMission=g_currentMission
    g_currentMission={controlledVehicle=v}
    c.now=1000;FMAFarmSurvey.update(c)
    v.posX=6;c.now=2000;FMAFarmSurvey.update(c)
    eq(FMAFarmSurvey.summary(c).mapped,0)
    g_currentMission=previousMission
    FMAGameNative.isManuallyControlled=oldManual
end)
test('survey observations persist in owned savegame XML and never auto start work',function()
    local c=fixture()
    c.policies={};c.excluded={};c.routes={};c.forageStages={};c.homePositions={};c.toolHomes={};c.learnedPoints={};c.learnedRoutes={};c.experience={};c.handoverJournal={}
    FMAFarmSurvey.confirmTransfer(c,{vehicle={key='a',object=tractor(14,0)},navSamples={{x=0,z=0},{x=7,z=0},{x=14,z=0}}})
    FMAState.save(c)
    local saved=FMAState.load()
    assert(saved.farmSurvey.center and saved.farmSurvey.center.x==0)
    eq(saved.farmSurvey.manual,true)
    assert(FMAUtil.count(saved.farmSurvey.edges)>=1)
    eq(saved.settings.enabled,false)
end)
test('repeated obstacle excludes previously traversed segment from advisory planning',function()
    local c=fixture()
    FMAFarmSurvey.confirmTransfer(c,{vehicle={key='a',object=tractor(21,0)},navSamples={{x=0,z=0},{x=7,z=0},{x=14,z=0},{x=21,z=0}}})
    assert(FMAFarmSurvey.plan(c,{x=0,z=0},{x=21,z=0},'SOLO')~=nil)
    c.navigationMap.hazards.obstacle={x=14,z=0,failures=3}
    eq(FMAFarmSurvey.plan(c,{x=0,z=0},{x=21,z=0},'SOLO'),nil)
end)
test('advisory preview cycles real known facilities without starting a vehicle',function()
    local c=fixture()
    local v=tractor(0,0)
    c.digitalMap={zones={{kind='SKLAD',x=21,z=0,label='A skladní hala'},{kind='BRÁNA',x=18,z=180,label='Z druhá brána'}}}
    local priorMission=g_currentMission
    g_currentMission={controlledVehicle=v}
    FMAFarmSurvey.confirmTransfer(c,{vehicle={key='tractorA',object=v},navSamples={{x=0,z=0},{x=7,z=0},{x=14,z=0},{x=21,z=0}}})
    local ok,message=FMAFarmSurvey.previewNext(c)
    eq(ok,true)
    assert(message:find('bodů',1,true))
    assert(c.farmSurveyPreview.path and #c.farmSurveyPreview.path>=3)
    eq(c.active and next(c.active),nil)
    eq(v.posX,0)
    -- The next facility cannot inherit the successful first path.
    local ok2,why=FMAFarmSurvey.previewNext(c)
    eq(ok2,false)
    assert(why:find('naučit',1,true))
    g_currentMission=priorMission
end)
test('unknown farm zone never creates a fake route preview',function()
    local c=fixture();local previousMission=g_currentMission
    g_currentMission={controlledVehicle=tractor(0,0)}
    local ok,reason=FMAFarmSurvey.previewNext(c)
    eq(ok,false);assert(reason:find('načtené cíle',1,true))
    eq(c.farmSurveyPreview,nil)
    g_currentMission=previousMission
end)
test('re-anchoring more than the farm radius starts a distinct map',function()
    local c=fixture()
    FMAFarmSurvey.confirmTransfer(c,{vehicle={key='a',object=tractor(15,0)},navSamples={{x=0,z=0},{x=7,z=0},{x=15,z=0}}})
    assert(FMAFarmSurvey.summary(c).mapped>0)
    FMAFarmSurvey.anchor(c,{x=600,z=600})
    eq(FMAFarmSurvey.summary(c).mapped,0)
end)
end
