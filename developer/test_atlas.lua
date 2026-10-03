return function(test,eq)
local function withWorld(fn)
    local oldMission,oldFarmland,oldField=g_currentMission,g_farmlandManager,g_fieldManager
    local ok,err=pcall(fn)
    g_currentMission,g_farmlandManager,g_fieldManager=oldMission,oldFarmland,oldField
    if not ok then error(err) end
end
local function station(name,x,owner,fill,capacity)
    local obj={posX=x,posZ=0,owningPlaceable={ownerFarmId=owner,posX=x,posZ=0}}
    function obj:getName()return name end
    function obj:getAISupportedFillTypes()return fill or {[101]=true} end
    function obj:getFreeCapacity(_,_) return capacity end
    return obj
end
test('universal map registry scans other maps, not just Karpatsky venkov',function()
    withWorld(function()
        local silo={ownerFarmId=1,posX=42,posZ=17,spec_silo={}}
        local livestock={ownerFarmId=1,posX=50,posZ=25,spec_husbandry={}}
        local ourLoad=station('Owned filling',42,1,{[101]=true},800)
        local publicUnload=station('Public station',150,0,{[101]=true},1000)
        g_currentMission={missionInfo={mapId='FS25_AnotherMap.Map',mapTitle='Jiná mapa'},
            placeableSystem={placeables={silo,livestock}},aiSystem={getNavigationMap=function()return {} end},
            storageSystem={getLoadingStations=function()return {[ourLoad]=ourLoad} end,
                           getUnloadingStations=function()return {[publicUnload]=publicUnload} end},
            accessHandler={canFarmAccess=function(_,farm,s)return farm==1 end}}
        g_farmlandManager={getFarmlands=function()return {[3]={id=3},[4]={id=4}} end,
            getFarmlandOwner=function(_,id)return id==3 and 1 or 0 end}
        g_fieldManager={getFields=function()return {{fieldId=7,posX=10,posZ=11,farmland={id=3}},{fieldId=8,posX=40,posZ=50,farmland={id=4}}} end}
        local c={farmId=1,fields={{id=7,x=10,z=11,name='Pole 7'}},vehicles={{}},now=123}
        local a=FMAWorldAtlas.scan(c)
        eq(a.identity,'FS25_AnotherMap.Map');eq(a.ownedPlaceables,2)
        eq(#a.husbandries,1);eq(#a.storages,1);eq(a.fieldCount,1);eq(a.totalMapFields,2)
        eq(a.farmlands.owned,1);eq(a.farmlands.total,2)
        eq(a.allFields[2].owner,0);eq(a.roadSystem.mapAvailable,true)
        eq(#a.loadingStations,1);eq(#a.unloadingStations,0)
        assert(a.allUnloading[1].access==true and a.allUnloading[1].owned==false)
        eq(a.allLoading[1].routeVerified,false)
    end)
end)
test('other map can have no AI navigation costmap; atlas never fakes one',function()
    withWorld(function()
        g_currentMission={missionInfo={mapId='Mod.OtherMap'},aiSystem={},placeableSystem={placeables={}}}
        g_farmlandManager={};g_fieldManager={}
        local a=FMAWorldAtlas.scan({farmId=1,fields={},vehicles={}})
        eq(a.roadSystem.mapAvailable,false);eq(a.totalMapFields,0)
    end)
end)
test('missing mission or farm does not invent a populated map',function()
    withWorld(function()
        g_currentMission=nil
        local a,why=FMAWorldAtlas.scan({farmId=1})
        eq(a,nil);eq(why,'MISSION_NOT_READY')
        g_currentMission={}
        eq(select(2,FMAWorldAtlas.scan({})), 'FARM_NOT_READY')
    end)
end)
test('owned unloading destination takes priority over public sale and must support fillType',function()
    withWorld(function()
        local origin=station('source',0,1,nil,1000)
        local sale=station('sale',4,0,nil,1000);sale.isSellingPoint=true
        local incompatible=station('wrong',8,1,{[202]=true},20000)
        local own=station('own',25,1,nil,1000)
        g_currentMission={storageSystem={getUnloadingStations=function()return {incompatible,sale,own} end}}
        local chosen,isSale=FMALogistics.bestDestination(1,origin,101,true)
        eq(chosen,own);eq(isSale,false)
    end)
end)
test('nearest owned compatible station with measured free capacity wins',function()
    withWorld(function()
        local origin=station('source',0,1,nil,1000)
        local far=station('far',100,1,nil,700)
        local near=station('near',15,1,nil,700)
        local noSpace=station('full',3,1,nil,50)
        g_currentMission={storageSystem={getUnloadingStations=function()return {far,near,noSpace} end}}
        eq(FMALogistics.bestDestination(1,origin,101,false),near)
    end)
end)
test('owned station inaccessible to this farm cannot be assigned',function()
    withWorld(function()
        local origin=station('source',0,1,nil,1000)
        local forbidden=station('inaccessible',5,1,nil,1000)
        g_currentMission={storageSystem={getUnloadingStations=function()return {forbidden} end},
            accessHandler={canFarmAccess=function(_,farm,s)return s~=forbidden end}}
        eq(FMALogistics.bestDestination(1,origin,101,false),nil)
    end)
end)
test('unapproved automatic selling never silently overrides no storage',function()
    withWorld(function()
        local origin=station('source',0,1,nil,1000)
        local sale=station('sale',5,0,nil,1000);sale.isSellingPoint=true
        g_currentMission={storageSystem={getUnloadingStations=function()return {sale} end}}
        eq(FMALogistics.bestDestination(1,origin,101,false),nil)
        local result,isSale=FMALogistics.bestDestination(1,origin,101,true)
        eq(result,sale);eq(isSale,true)
    end)
end)
test('Map geometry carries version-independent stable identity into savegame schema',function()
    local s=io.open('scripts/FMAState.lua','r'):read('*a')
    local c=io.open('scripts/FMAController.lua','r'):read('*a')
    assert(s:find('farmManager#mapIdentity',1,true))
    assert(c:find("state.mapIdentity~=mapId",1,true))
    assert(c:find('self.experience=differentMap and {}',1,true))
    assert(c:find('self.inventorySafe=(okFields and okVehicles)==true',1,true))
    assert(c:find('self.inventorySafe==false',1,true))
end)

test('FS25 actual unload trigger beats building center; never claim route verified',function()
    withWorld(function()
        local p=station('Inside barn', 10,1,{[101]=true},1500)
        function p:getAITargetPositionAndDirection(ft)
            if ft==101 then return 76,89,0,1,{} end
        end
        g_currentMission={missionInfo={mapId='MapA'},storageSystem={getUnloadingStations=function()return {p} end}}
        g_farmlandManager={};g_fieldManager={}
        local atlas=FMAWorldAtlas.scan({farmId=1,fields={},vehicles={},now=0})
        local row=atlas.allUnloading[1]
        eq(row.x,76);eq(row.z,89);eq(row.pointSource,'AI_TARGET')
        eq(row.aiTargetCount,1);eq(row.routeVerified,false);eq(row.aiTargetVerified,false)
        eq(atlas.validAccessPoints,1)
        local goal=FMAWorldAtlas.stationTarget(p,101)
        eq(goal.physicallyVerified,false);eq(goal.x,76)
    end)
end)
test('station returning no real trigger is NOT a valid AI entry even if position exists',function()
    withWorld(function()
        local p=station('Bad trigger',30,1,{[101]=true},1500)
        function p:getAITargetPositionAndDirection()return 500,500,0,1,nil end
        g_currentMission={missionInfo={mapId='MapB'},storageSystem={getLoadingStations=function()return {p} end}}
        g_farmlandManager={};g_fieldManager={}
        local atlas=FMAWorldAtlas.scan({farmId=1,fields={},vehicles={},now=0})
        eq(atlas.validAccessPoints,0)
        local row=atlas.allLoading[1]
        eq(row.pointSource,'STATION');eq(row.x,30);eq(row.routeVerified,false)
        eq(FMAWorldAtlas.stationTarget(p,101),nil)
    end)
end)
test('missing target method and invalid coordinates do not fabricate AI position',function()
    local p=station('Legacy',6,1,{[101]=true},400)
    eq(FMAWorldAtlas.stationTarget(p,101),nil)
    function p:getAITargetPositionAndDirection()return 0/0,12,1,0,{} end
    eq(FMAWorldAtlas.stationTarget(p,101),nil)
    function p:getAITargetPositionAndDirection()error('not ready') end
    eq(FMAWorldAtlas.stationTarget(p,101),nil)
end)


test('real AI destination is preferred over nearer wall/root and no fake sale',function()
    withWorld(function()
        local source=station('source',0,1,{[101]=true},1200)
        local wrong=station('wall silo',5,1,{[101]=true},1500)
        local road=station('road silo',90,1,{[101]=true},1500)
        function road:getAITargetPositionAndDirection(ft)
            if ft==101 then return 91,2,0,1,{} end
        end
        g_currentMission={storageSystem={getUnloadingStations=function()return {wrong,road} end}}
        eq(FMALogistics.bestDestination(1,source,101,false),road)
        local goal=FMAWorldAtlas.stationTarget(road,101)
        eq(goal.x,91);eq(goal.z,2)
    end)
end)
test('digital map uses observed station AI target instead of duplicate roof position',function()
    withWorld(function()
        local stationObject=station('farm load',5,1,{[101]=true},2000)
        function stationObject:getAITargetPositionAndDirection()return 88,100,0,1,{} end
        g_currentMission={missionInfo={mapId='MapX'},storageSystem={getLoadingStations=function()return {stationObject} end}}
        g_farmlandManager={};g_fieldManager={}
        local c={farmId=1,fields={},vehicles={},now=0,settings={},homePositions={},toolHomes={},learnedPoints={},learnedRoutes={}}
        c.worldAtlas=FMAWorldAtlas.scan(c)
        FMAFarmBrain.buildDigitalMap(c)
        local found=FMAFarmBrain.findZone(c,'PLNIČKA')
        assert(found~=nil);eq(found.x,88);eq(found.z,100)
        eq(found.source,'runtime:AI_TARGET')
    end)
end)

test('farmland reference may be a numeric id on custom maps',function()
    withWorld(function()
        g_currentMission={missionInfo={mapId='Custom.Map'},placeableSystem={placeables={}}}
        g_fieldManager={getFields=function()return {{fieldId=11,posX=2,posZ=3,farmland=99}} end}
        g_farmlandManager={getFarmlandOwner=function(_,id)return id==99 and 7 or 0 end}
        local a=FMAWorldAtlas.scan({farmId=7,fields={},vehicles={}})
        eq(a.allFields[1].farmlandId,99);eq(a.allFields[1].owner,7)
    end)
end)
end
