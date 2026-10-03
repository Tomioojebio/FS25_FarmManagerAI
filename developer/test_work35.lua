return function(test,eq)
    test('35: management UI splits field work, harvest, livestock and bunker orders',function()
        eq(FMAHud.matchesSection(12,{kind='field',operation='lime'}),true)
        eq(FMAHud.matchesSection(12,{kind='field',operation='harvest'}),false)
        eq(FMAHud.matchesSection(13,{kind='field',operation='harvest'}),true)
        eq(FMAHud.matchesSection(14,{kind='livestockNeed',operation='supply'}),true)
        eq(FMAHud.matchesSection(15,{kind='bunkerWorkOrder',operation='compact'}),true)
        eq(FMAHud.matchesSection(9,{kind='anything'}),true)
        eq(FMAHud.orderIcon({kind='livestockNeed'}),'cow')
        eq(FMAHud.orderIcon({kind='bunkerWorkOrder'}),'silo')
    end)
    test('35: GIANTS motor is really requested before CP public bunker start',function()
        local oldBunker=g_bunkerSiloManager
        local job={cpJobParameters={siloPosition={setPosition=function()end},
            startPosition={setPosition=function()end},stopWithCompactedSilo={setValue=function()end}}}
        local calls={}
        local v={posX=20,posZ=30,started=false,
            getCanStartCpBunkerSiloWorker=function()return true end,
            getIsAIActive=function()return false end,
            getCanMotorRun=function()return true end,
            getIsMotorStarted=function(self)return self.started end,
            startMotor=function(self)table.insert(calls,'motor');self.started=true end,
            startCpAtFirstWp=function()table.insert(calls,'CP');return true end,
            getCpBunkerSiloWorkerJob=function()return job end}
        g_bunkerSiloManager={getBunkerSiloAtPosition=function()return true,{} end}
        local c={bunkers={{geometry={center={x=22,z=31}}}}}
        local started=FMACourseplay.startBunker(c,{object=v,name='T'},22,31,{bunkerIndex=1})
        eq(started,job);eq(calls[1],'motor');eq(calls[2],'CP')
        g_bunkerSiloManager=oldBunker
    end)
    test('35: bunker request without real AI acceptance stops after timeout',function()
        local v={posX=2,posZ=3, getIsAIActive=function()return false end,
            getIsMotorStarted=function()return false end,getIsCpActive=function()return false end,
            getJob=function()return nil end}
        local job={isRunning=false}
        local a={job=job,task={id='bunker:work:1',kind='bunker',operation='compact',bunkerIndex=1},
            vehicle={object=v,name='Mock'},start=0,startCompaction=12}
        local stopped=false
        local c={now=11001,active={[job]=a},
            onJobStopped=function(self,j,reason)stopped=(j==job) end}
        FMAJobs.verifyAuxiliaryStarts(c)
        eq(a.dispatchRejected,true);eq(stopped,true)
        assert(a.stopReason:find('Courseplay pouze odeslal',1,true))
    end)
    test('35: even accepted AI without tractor motion does not fake compacting',function()
        local job={isRunning=true}
        local v={posX=2,posZ=3, getIsAIActive=function()return true end,
            getJob=function()return job end,getIsMotorStarted=function()return true end}
        local a={job=job,task={id='bunker:work:1',kind='bunker',operation='compact',bunkerIndex=1},
            vehicle={object=v,name='Mock'},start=1000,startCompaction=14}
        local oldStop=FMAAI.stop;local stopped=false
        FMAAI.stop=function()stopped=true end
        local c={now=4000,active={[job]=a},bunkers={{object={compactedPercent=14}}}}
        FMAJobs.verifyAuxiliaryStarts(c)
        eq(a.dispatchVerified,true);eq(a.physicalMotionVerified,nil)
        c.now=40000;FMAJobs.verifyAuxiliaryStarts(c)
        eq(stopped,true);assert(a.stopReason:find('fyzicky nepopojel',1,true))
        FMAAI.stop=oldStop
    end)
    test('35: actual GIANTS tractor translation counts as bunker motion',function()
        local job={isRunning=true}
        local v={posX=1,posZ=2,getIsAIActive=function()return true end,getJob=function()return job end}
        local a={job=job,task={id='bunker:work:9',kind='bunker',operation='compact',bunkerIndex=1},
            vehicle={object=v,name='Real mover'},start=1000,startCompaction=20,startX=1,startZ=2}
        local c={now=3000,active={[job]=a},bunkers={{object={compactedPercent=20}}}}
        FMAJobs.verifyAuxiliaryStarts(c);eq(a.dispatchVerified,true)
        v.posX=4;c.now=4000;FMAJobs.verifyAuxiliaryStarts(c)
        eq(a.physicalMotionVerified,true);eq(a.stopReason,nil)
    end)
    test('35: completed bunker first exits concrete silo and only then starts parking',function()
        local oldCreate,oldStart,oldReturn=FMAAI.createTransferJob,FMAJobs.start,FMAReturnManager.begin
        local transferCount,parkingCount=0,0
        FMAAI.createTransferJob=function()transferCount=transferCount+1;return {},nil,'GIANTS_GOTO' end
        FMAJobs.start=function()return true end
        FMAReturnManager.begin=function()parkingCount=parkingCount+1;return true end
        local parent={id='bunkerOrder:A',state='running'}
        local work={id='bunker:work:1',kind='bunker',operation='compact',bunkerIndex=1,parentTask=parent}
        local b={key='A',object={compactedPercent=100},compactedPercent=100,
            geometry={front={x=0,z=0},back={x=60,z=0},dx=1,dz=0,length=60,width=12,
                frontOutside={x=-14,z=0},backOutside={x=74,z=0}}}
        local v={posX=15,posZ=0};local record={object=v,key='V',name='V'}
        local c={now=10000,bunkers={b},vehicles={record},loose={},tasks={[parent.id]=parent},
            settings={autoReturn=true,trafficSafety=false},reservations={},active={},
            notify=function()end,issue=function()end}
        eq(FMABunkerCoordinator.onStopped(c,{task=work,start=8000,vehicle=record}),true)
        eq(transferCount,1);eq(parkingCount,0);eq(parent.state,'returning')
        v.posX=-14
        local exitActive=nil
        for _,entry in pairs(c.active) do if entry.task.kind=='bunkerExit' then exitActive=entry end end
        assert(exitActive and exitActive.task.exitPoint.x==-14)
        eq(FMABunkerCoordinator.onStopped(c,exitActive),true)
        eq(parkingCount,1)
        FMAAI.createTransferJob,FMAJobs.start,FMAReturnManager.begin=oldCreate,oldStart,oldReturn
    end)
    test('35: remote tractor must stage at real bunker entrance instead of CP request',function()
        local oldBunker,oldAvailable,oldCP,oldCreate,oldStart=BunkerSilo,FMACourseplay.available,FMACourseplay.startBunker,FMAAI.createTransferJob,FMAJobs.start
        BunkerSilo={STATE_FILL=1};FMACourseplay.available=function()return true end
        local cpCalled,transferCalled=false,false
        FMACourseplay.startBunker=function()cpCalled=true;return {} end
        FMAAI.createTransferJob=function(self,record,point)transferCalled=true;return {},nil,'NATIVE' end
        FMAJobs.start=function()return true end
        local b={key='storedSilo',object={fillLevel=20000,compactedPercent=40,state=1},
            x=55,z=0,fillLevel=20000,compactedPercent=40,state=1,
            geometry={frontOutside={x=30,z=0},backOutside={x=80,z=0},center={x=55,z=0},dx=1,dz=0}}
        local v={key='A',name='A',object={posX=60,posZ=-20,
            getCanStartCpBunkerSiloWorker=function()return true end,
            getIsAIActive=function()return false end},capabilities={compactSilo=true},machineClass='tractor',mass=11}
        local c={settings={enabled=true,bunkerAutomation=true,selectedJobsOnly=false,maxWorkers=2,trafficSafety=false},now=5000,
            active={},reservations={},bunkers={b},vehicles={v},excluded={},tasks={},notify=function()end,issue=function()end}
        eq(FMABunkerCoordinator.dispatch(c),true)
        eq(transferCalled,true);eq(cpCalled,false)
        FMACourseplay.available,FMACourseplay.startBunker,BunkerSilo,FMAAI.createTransferJob,FMAJobs.start=oldAvailable,oldCP,oldBunker,oldCreate,oldStart
    end)
end
