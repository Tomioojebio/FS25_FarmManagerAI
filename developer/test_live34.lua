return function(test,eq)
    test('34: new profiles default to autonomous dispatch without starting AI before Alt+H',function()
        local st=FMAState.new()
        eq(st.settings.selectedJobsOnly,false)
        eq(st.settings.enabled,false)
        eq(st.settings.autonomyDefaultApplied,true)
    end)

    test('34: bunker CP uses vehicle registered job and true tractor start pose',function()
        local oldManager=g_bunkerSiloManager
        local p={}
        local function positionParameter(label)
            local obj={}
            obj.setPosition=function(self,x,z) p[label]={x=x,z=z} end
            return obj
        end
        local job={cpJobParameters={siloPosition=positionParameter('silo'),
            startPosition=positionParameter('start'),stopWithCompactedSilo={setValue=function(self,b)p.stop=b end}}}
        local starts=0
        local v={posX=13.4,posZ=-583,
            getCanStartCpBunkerSiloWorker=function()return true end,
            getIsAIActive=function()return false end,
            getCpBunkerSiloWorkerJob=function()return job end,
            startCpAtFirstWp=function(self) starts=starts+1;return true end}
        g_bunkerSiloManager={getBunkerSiloAtPosition=function(self,x,z)
            eq(x,20);eq(z,-530);return true,{isSilo=true}
        end}
        local b={geometry={center={x=20,z=-530}}}
        local c={farmId=1,bunkers={b}}
        local result,why=FMACourseplay.startBunker(c,{object=v,key='x',name='XERION'},20,-530,{bunkerIndex=1})
        eq(result,job);eq(why,nil);eq(starts,1)
        eq(p.silo.x,20);eq(p.silo.z,-530)
        eq(p.start.x,13.4);eq(p.start.z,-583)
        eq(p.stop,true);eq(job.fmaCourseplayPublicStart,true)
        g_bunkerSiloManager=oldManager
    end)

    test('34: bunker CP fails closed with missing vehicle-bound job',function()
        local starts=0
        local v={posX=0,posZ=0,getCanStartCpBunkerSiloWorker=function()return true end,
            startCpAtFirstWp=function()starts=starts+1;return true end}
        local c={bunkers={{geometry={center={x=5,z=5}}}}}
        local job,why=FMACourseplay.startBunker(c,{object=v,key='x'},5,5,{bunkerIndex=1})
        eq(job,nil);assert(why:find('úlohu',1,true));eq(starts,0)
    end)

    test('34: fleet will not steal separately operating GIANTS or CP tractor',function()
        local oldBunker,oldAvailable,oldStart,oldDirection=BunkerSilo,FMACourseplay.available,FMACourseplay.startBunker,localDirectionToWorld
        BunkerSilo={STATE_FILL=1};FMACourseplay.available=function()return true end
        localDirectionToWorld=function()return 1,0,0 end
        local started={}
        FMACourseplay.startBunker=function(c,v)started[#started+1]=v.key;return {mock=true} end
        local b={key='ownedSilo',object={fillLevel=20000,compactedPercent=30,state=1},
            x=40,z=0,fillLevel=20000,compactedPercent=30,state=1,
            geometry={front={x=44,z=0},frontOutside={x=30,z=0},backOutside={x=80,z=0},center={x=55,z=0},length=22,width=12,dx=1,dz=0}}
        local function vehicle(key,x,active)
            return {key=key,name=key,object={posX=x,posZ=0,rootNode=7,getCanStartCpBunkerSiloWorker=function()return true end,
                getIsAIActive=function()return active end},capabilities={compactSilo=true},machineClass='tractor',mass=11}
        end
        local list={vehicle('occupied',28,true),vehicle('distant',500,false),vehicle('near',32,false)}
        local root={id='bunkerOrder:ownedSilo',ownerApproved=true}
        local c={settings={enabled=true,bunkerAutomation=true,selectedJobsOnly=true,maxWorkers=2,
                bunkerNominalHeight=4,trafficSafety=false},now=10000,active={},reservations={},
                bunkers={b},vehicles=list,excluded={},tasks={[root.id]=root},notify=function()end,issue=function()end}
        eq(FMABunkerCoordinator.dispatch(c),true)
        eq(started[1],'near')
        FMACourseplay.available,FMACourseplay.startBunker,BunkerSilo,localDirectionToWorld=oldAvailable,oldStart,oldBunker,oldDirection
    end)
end
