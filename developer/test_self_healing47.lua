return function(test,eq)
    local function bunker()
        return {x=49,z=-535,geometry={front={x=26,z=-535},back={x=70,z=-535},dx=1,dz=0,length=44,width=12,
            frontOutside={x=12,z=-535},backOutside={x=84,z=-535}}}
    end
    test('47: false GIANTS arrival cannot start CP outside real bunker mouth',function()
        local savedDir=localDirectionToWorld
        local savedStart=FMACourseplay.startBunker
        local calls=0
        local ok,err=pcall(function()
            localDirectionToWorld=function()return 1,0,0 end
            FMACourseplay.startBunker=function()calls=calls+1;return {isRunning=true} end
            local vehicle={rootNode=9,posX=87.77,posZ=-522.39}
            local record={key='xerion',name='XERION',object=vehicle}
            local parent={id='bunkerOrder:1',state='assembling'}
            local c={now=120000,vehicles={record},bunkers={bunker()},bunkerWorkState={},
                traffic=FMATraffic.new(),settings={enabled=true},tasks={[parent.id]=parent},
                reservations={},active={},issue=function()end,notify=function()end}
            local active={vehicle=record,task={kind='bunkerApproach',bunkerIndex=1,
                fromFront=true,role='bunkerCompactor',parentTask=parent}}
            eq(FMABunkerCoordinator.onStopped(c,active),true)
            eq(calls,0)
            assert(parent.reason:find('fyzická poloha',1,true))
            assert(c.bunkerWorkState[1].failures==1)
            assert(parent.state=='pending')
        end)
        localDirectionToWorld,FMACourseplay.startBunker=savedDir,savedStart
        assert(ok,err)
    end)
    test('47: CP must never start at rear mouth that sent real XERION out of bunker',function()
        local oldDir=localDirectionToWorld
        local oldStart=FMACourseplay.startBunker
        local calls=0
        local ok,err=pcall(function()
            -- Tractor is at the rear gate x=84, heading INTO the bunker
            -- (negative world X). This used to count as safe and then CP
            -- immediately drove OUT through the rear mouth in the live trace.
            localDirectionToWorld=function()return -1,0,0 end
            FMACourseplay.startBunker=function()calls=calls+1;return {isRunning=true} end
            local rec={key='xerion',name='XERION',object={rootNode=9,posX=84,posZ=-535}}
            local parent={id='bunkerOrder:1',state='assembling'}
            local c={now=125000,vehicles={rec},bunkers={bunker()},bunkerWorkState={},
                traffic=FMATraffic.new(),settings={enabled=true},tasks={[parent.id]=parent},
                reservations={},active={},issue=function()end,notify=function()end}
            local worker={vehicle=rec,task={kind='bunkerApproach',bunkerIndex=1,
                fromFront=false,role='bunkerCompactor',parentTask=parent}}
            eq(FMABunkerCoordinator.onStopped(c,worker),true)
            eq(calls,0)
            assert(tostring(parent.reason):find('Zadní vjezd',1,true),tostring(parent.reason))
        end)
        localDirectionToWorld,FMACourseplay.startBunker=oldDir,oldStart
        assert(ok,err)
    end)
    test('47: two machines in separated real lanes preserve each lane without crossing',function()
        local oldDir=localDirectionToWorld
        local ok,err=pcall(function()
            localDirectionToWorld=function()return 1,0,0 end
            local a={key='a',name='6R',object={rootNode=7,posX=42,posZ=-538,size={width=2.5,length=5}}}
            local b={key='b',name='JD',object={rootNode=8,posX=49,posZ=-532,size={width=2.5,length=5}}}
            local c={vehicles={a,b},loose={}}
            local plan,why=FMAOwnDriver.planInsideBunker(c,a,bunker())
            assert(plan,why)
            eq(plan.first.z,-538)
            eq(plan.second.z,-538)
            b.object.posZ=-535
            local notSafe,whyNot=FMAOwnDriver.planInsideBunker(c,a,bunker())
            eq(notSafe,nil)
            assert(whyNot:find('další stroj',1,true))
        end)
        localDirectionToWorld=oldDir
        assert(ok,err)
    end)
    test('47: stopped LEXION is not re-dispatched on timer but is reconsidered after real relocation',function()
        local task={id='field:64:harvest',kind='field',operation='harvest',state='blocked',
            phase='KOMBAJN SE FYZICKY NEROZJEL',selfHealingCause='stationaryStart',
            selfHealingVehicleKey='lexion'}
        local record={key='lexion',name='LEXION',busy=false,object={posX=192,posZ=-606}}
        local c={settings={enabled=true},now=60000,vehicles={record},tasks={[task.id]=task},
            jobFailures={['header:'..task.id..':toFieldWithCarrier']={blocked=true}},
            reservations={}}
        FMASelfHealing.scan(c)
        eq(task.state,'blocked')
        c.now=c.now+900000
        FMASelfHealing.scan(c)
        eq(task.state,'blocked')
        record.object.posX=203
        FMASelfHealing.scan(c)
        eq(task.state,'pending')
        eq(task.selfHealingCount,1)
        eq(c.jobFailures['header:'..task.id..':toFieldWithCarrier'],nil)
        assert(task.retryAt>c.now)
    end)
    test('47: assembler breaker resumes after physically observed relocation, not after mere scan',function()
        local task={id='field:6:fertilize',kind='field',operation='fertilize',state='blocked',
            preferredVehicleKey='crystal'}
        local r={key='crystal',busy=false,object={posX=91,posZ=-546}}
        local circuit={halted=true,failures=5,startedX=91,startedZ=-546}
        local c={settings={enabled=true},now=80000,vehicles={r},tasks={[task.id]=task},
            assemblyCircuits={[task.id]=circuit},reservations={},jobFailures={}}
        FMASelfHealing.scan(c)
        eq(task.state,'blocked')
        r.object.posX=97
        FMASelfHealing.scan(c)
        eq(task.state,'pending')
        eq(circuit.halted,false)
        eq(task.selfHealingAssemblyCount,1)
    end)
    test('47: safety geofence block cannot be silently forgiven after relocation',function()
        local r={key='xerion',busy=false,object={posX=40,posZ=-535}}
        local ws={blocked=true,failedVehicleKey='xerion',failedPose={x=0,z=-535},
            lastError='BEZPEČNOST: předvídaný odjezd z jámy'}
        local c={settings={enabled=true},now=90000,vehicles={r},tasks={},
            bunkerWorkState={[1]=ws},bunkers={[1]=bunker()},reservations={}}
        FMASelfHealing.scan(c)
        eq(ws.blocked,true)
    end)
    test('47: header detachable uses native FS25 isDetachAllowed instead of legacy-only callback',function()
        local old=FMAHeaderTransport.startGoTo
        local ok,err=pcall(function()
            FMAHeaderTransport.startGoTo=function()return true end
            local carrier={posX=300,posZ=400,isDetachAllowed=function()return true end,
                detachImplementByObject=function(self,object)self.attached=false;return true end,
                getAttacherVehicle=function(self)return self.attached and self or nil end}
            carrier.attached=true
            local cutter={posX=300,posZ=400}
            local record={key='lexion',name='LEXION',object=carrier}
            local parent={id='field:64:harvest',kind='field',state='assembling'}
            local active={task={kind='headerTransport',phase='toFieldWithCarrier',parentTaskId=parent.id},
                vehicle=record,headerPlan={carrier={object=carrier,key='carrier'},cutter=cutter}}
            FMAHeaderTransport.onStopped({tasks={[parent.id]=parent},settings={},implementReservations={}},active)
            eq(carrier.attached,false)
            assert(parent.state~='blocked',tostring(parent.reason))
        end)
        FMAHeaderTransport.startGoTo=old
        assert(ok,err)
    end)
end
