return function(test,eq)
    local function vehicle(key,x,z,width,length)
        local o={uniqueId=key,posX=x,posZ=z,ownerFarmId=1,spec_motorized={},spec_attacherJoints={},size={width=width or 3.3,length=length or 7.0}}
        local r={key=key,name=key,machineClass='tractor',object=o,x=x,z=z,busy=false}
        return r,o
    end
    local function bay(id,x,z,role,kind)
        return {id=id,x=x,z=z,angle=0,kind=kind or 'vehicle',role=role or 'tractor',source='OWNER_TAUGHT',
            site='garage',width=6,length=12,driveX=x,driveZ=z,driveAngle=0}
    end
    test('29: taught bays persist through XML save and reload, without restoring active parking leases',function()
        local oldXml,oldExists,oldMission=XMLFile,fileExists,g_currentMission
        local db={}
        local function handle()
            return {setValue=function(_,key,value) db[key]=value end,
                getValue=function(_,key,default) if db[key]~=nil then return db[key] end return default end,
                hasProperty=function(_,key)
                    for saved in pairs(db) do if saved:sub(1,#key)==key then return true end end
                    return false
                end,save=function()end,delete=function()end}
        end
        XMLFile={create=function()return handle()end,load=function()return handle()end}
        fileExists=function()return true end
        g_currentMission={missionInfo={savegameDirectory='/tmp/test-save-parking'}}
        local c={initialized=true,supported=true,settings=FMAState.new().settings,policies={},excluded={},routes={},
            parkingBays={B9=bay('B9',45,61)},parkingLeases={B9='return:old'},
            homePositions={},toolHomes={},forageStages={},learnedPoints={},learnedRoutes={},
            navigationMap={routes={},hazards={}},farmSurvey={edges={}},experience={}}
        FMAState.save(c)
        local reloaded=FMAState.load()
        assert(reloaded.parkingBays.B9 and reloaded.parkingBays.B9.role=='tractor')
        eq(reloaded.parkingBays.B9.x,45)
        eq(reloaded.parkingBays.B9.z,61)
        eq(reloaded.parkingLeases,nil)
        XMLFile,fileExists,g_currentMission=oldXml,oldExists,oldMission
    end)
    test('29: bale wagon and seeder prefer relevant production zones',function()
        eq(FMAParkingManager.role({spec_forageWagon={}},nil,'tool'),'silage')
        eq(FMAParkingManager.suggestSite('silage'),'silage')
        eq(FMAParkingManager.role({spec_mixerWagon={}},nil,'tool'),'livestock')
        eq(FMAParkingManager.suggestSite('livestock'),'livestock')
        eq(FMAParkingManager.siteType({name='Nádrže na tekutá hnojiva'}),'supplies')
        eq(FMAParkingManager.suggestSite('sprayer'),'supplies')
    end)
    test('29: placeable center never masquerades as a parking target',function()
        local old=g_currentMission
        g_currentMission={placeableSystem={placeables={{name='Nová garáž',posX=100,posZ=100,ownerFarmId=1},
            {name='Silážní jáma',posX=200,posZ=200,ownerFarmId=1}}}}
        local c={farmId=1,parkingBays={}}
        local sites=FMAParkingManager.scan(c);eq(#sites,2)
        local record=vehicle('a',0,0)
        eq(select(1,FMAParkingManager.select(c,record,'vehicle')),nil)
        assert(sites[1].type=='garage' and sites[2].type=='silage')
        g_currentMission=old
    end)
    test('29: manure, silage and tractor classes are identified from real specs',function()
        eq(FMAParkingManager.role({spec_manureSpreader={}},nil,'tool'),'manure')
        eq(FMAParkingManager.role({spec_bunkerSiloCompacter={}},nil,'tool'),'silage')
        eq(FMAParkingManager.role({spec_sowingMachine={}},nil,'tool'),'seeder')
        eq(FMAParkingManager.role({spec_trailer={}},nil,'tool'),'trailer')
        local r=vehicle('t',0,0);eq(FMAParkingManager.role(r.object,r,'vehicle'),'tractor')
        eq(FMAParkingManager.suggestSite('tractor'),'garage')
        eq(FMAParkingManager.suggestSite('manure'),'manure')
        eq(FMAParkingManager.suggestSite('silage'),'silage')
    end)
    test('29: garage parking requires learned bay of sufficient dimensions',function()
        local r=vehicle('tractor',0,0)
        local small=bay('small',20,0);small.width=2
        local other=bay('other',10,0,'manure','tool')
        local good=bay('good',30,0)
        local c={parkingBays={small=small,other=other,good=good},vehicles={r},settings={smartParking=true}}
        eq(FMAParkingManager.select(c,r,'vehicle'),good)
        c.parkingLeases={good='busy'}
        eq(select(1,FMAParkingManager.select(c,r,'vehicle')),nil)
    end)
    test('29: two machines cannot receive the same occupied parking spot',function()
        local r=vehicle('own',0,0)
        local other=vehicle('other',50,0)
        local p=bay('P1',50,0)
        local c={parkingBays={P1=p},vehicles={r,other},parkingLeases={},settings={smartParking=true}}
        eq(select(1,FMAParkingManager.select(c,r,'vehicle')),nil)
        other.object.posX=80;other.object.posZ=0
        eq(FMAParkingManager.select(c,r,'vehicle'),p)
        local task={id='park:own'}
        eq(FMAParkingManager.reserve(c,p,task),true)
        eq(FMAParkingManager.reserve(c,p,{id='park:other'}),false)
        FMAParkingManager.release(c,task);eq(c.parkingLeases.P1,nil)
    end)
    test('29: taught trailer bay remembers tractor pose for precise unhook',function()
        local oldSurvey,oldSave,oldDiag=FMAFarmSurvey.playerVehicle,FMAState.save,FMADiagnostics.event
        local r,tractor=vehicle('driver',10,10)
        local trailer={posX=8,posZ=10,ownerFarmId=1,uniqueId='tool',spec_attachable={},spec_trailer={},size={width=3,length=8}}
        tractor.getAttachedImplements=function()return {{object=trailer}} end
        FMAFarmSurvey.playerVehicle=function() return tractor end
        FMAState.save=function()return true end
        FMADiagnostics.event=function()end
        local c={supported=true,farmId=1,parkingBays={},parkingFacilities={},vehicles={r},vehicleByKey={},
            notify=function()end}
        local ok,id=FMAParkingManager.teach(c,'tool')
        eq(ok,true);assert(id)
        local chosen=c.parkingBays[id]
        eq(chosen.kind,'tool');eq(chosen.role,'trailer');eq(chosen.driveX,10);eq(chosen.x,8)
        eq(chosen.driverKey,FMAWorld.vehicleKey(tractor))
        assert(chosen.width>3 and chosen.length>8)
        FMAFarmSurvey.playerVehicle,FMAState.save,FMADiagnostics.event=oldSurvey,oldSave,oldDiag
    end)
    test('29: return dispatcher selects taught garage rather than scattered initial home',function()
        local oldBegin=FMAReturnManager.startDrive
        local r=vehicle('t',1,1)
        local p=bay('GAR',60,80)
        local c={settings={autoReturn=true,smartParking=true},farmId=1,
            homePositions={[r.key]={x=1,z=1}},toolHomes={},vehicles={r},loose={},
            parkingBays={GAR=p},parkingLeases={},reservations={},tasks={},notify=function()end}
        local to
        FMAReturnManager.startDrive=function(_,record,target,task,phase)to={target=target,task=task,phase=phase};return true end
        local ok=FMAReturnManager.begin(c,{task={id='work',operation='plow',state='running'},vehicle=r})
        eq(ok,true);eq(to.target.x,60);eq(to.target.z,80);eq(to.phase,'vehicleHome')
        eq(c.parkingLeases.GAR,to.task.id)
        FMAReturnManager.startDrive=oldBegin
    end)
    test('29: completed organized vehicle parking verifies physical arrival and updates home',function()
        local oldStop=FMAJobs.stopMotor
        FMAJobs.stopMotor=function()end
        local r=vehicle('t',30,80)
        local task={id='parking:t',kind='return',purpose='parking',phase='vehicleHome',parkingBayId='B2',target={x=30,z=80}}
        local c={settings={parkTolerance=8},homePositions={},parkingLeases={B2='parking:t'},
            reservations={t='parking:t'},tasks={},notify=function()end}
        FMAReturnManager.finish(c,{task=task,vehicle=r})
        eq(c.homePositions.t.x,30);eq(c.parkingLeases.B2,nil);eq(c.reservations.t,nil)
        FMAJobs.stopMotor=oldStop
    end)
    test('29: batch organization dispatches only one idle compatible machine per scan',function()
        local oldStart,oldManual=FMAReturnManager.startDrive,FMAGameNative.isManuallyControlled
        local a=vehicle('a',0,0);local b=vehicle('b',50,0)
        local c={settings={smartParking=true,enabled=true},supported=true,inventorySafe=true,now=1000,
            parkingBays={A=bay('A',120,0),B=bay('B',180,0)},parkingLeases={},
            parkingOrganize=true,parkingOrganizeTried={},parkingOrganizeNext=0,
            vehicles={a,b},loose={},active={},reservations={},notify=function()end}
        local called=0
        FMAReturnManager.startDrive=function()called=called+1;return true end
        FMAGameNative.isManuallyControlled=function()return false end
        FMAParkingManager.update(c)
        eq(called,1);assert(FMAUtil.count(c.parkingLeases)==1)
        c.now=9000;FMAParkingManager.update(c);eq(called,2)
        FMAReturnManager.startDrive,FMAGameNative.isManuallyControlled=oldStart,oldManual
    end)
end
