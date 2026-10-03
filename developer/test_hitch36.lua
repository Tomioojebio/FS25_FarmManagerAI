-- New native-world mock checks for physical hitch gating. Not an FS25 runtime test.
return function(test,eq)
    test('36: real tractor hitch and implement input nodes produce multiple close approach poses',function()
        local oldG,oldD,oldW,oldL,oldM=getWorldTranslation,localDirectionToWorld,worldToLocal,MathUtil
        local nodes={[111]={10,0,10},[222]={0,0,-1.5}}
        getWorldTranslation=function(n)local v=nodes[n];return v[1],v[2],v[3] end
        localDirectionToWorld=function()return 0,0,1 end
        worldToLocal=function(_,x,y,z)return x,y,z end
        MathUtil={getYRotationFromDirection=function()return 0 end}
        local plan={power={object={rootNode=1,posX=0,posZ=0}},tool={object={posX=10,posZ=10}},
            joint={node=222},input={node=111},inputIndex=1}
        local poses=FMAAssembler.alignmentCandidates(plan,{attachAlignmentOffset=2.7})
        eq(#poses,5);eq(poses[1].mode,'staging');eq(poses[2].mode,'jointA')
        eq(poses[3].mode,'jointB');eq(poses[4].mode,'jointA');eq(poses[5].mode,'jointB')
        assert(poses[2].hitchGap<=2.0 and poses[4].hitchGap<=poses[2].hitchGap)
        getWorldTranslation,localDirectionToWorld,worldToLocal,MathUtil=oldG,oldD,oldW,oldL,oldM
    end)
    test('36: do not steal neighboring implement when GIANTS detects the wrong tool',function()
        local oldAttach=AttacherJoints
        local foreign={spec_attachable={},name='wrong'}
        local target={spec_attachable={},ownerFarmId=1,name='chosen',getActiveInputAttacherJointDescIndex=function()return nil end,
            isAttachAllowed=function()return true end}
        local tractor={ownerFarmId=1,spec_attacherJoints={},getIsAIActive=function()return false end}
        local called=false
        tractor.attachImplementFromInfo=function()called=true;return true end
        AttacherJoints={MAX_ATTACH_DISTANCE_SQ=9,MAX_ATTACH_ANGLE=.5,
            updateVehiclesInAttachRange=function()return tractor,1,foreign,1 end}
        local c={farmId=1};local plan={power={object=tractor,name='T'},tool={object=target,name='chosen'}}
        local result=FMAAssembler.attach(c,plan)
        eq(result,false);eq(called,false)
        AttacherJoints=oldAttach
    end)
    test('36: request to GIANTS is not marked physically complete before root reparenting',function()
        local oldAttach=AttacherJoints
        local tractor={ownerFarmId=1,spec_attacherJoints={},getIsAIActive=function()return false end}
        local target={spec_attachable={},ownerFarmId=1,getActiveInputAttacherJointDescIndex=function()return nil end,
            isAttachAllowed=function()return true end,getRootVehicle=function(self)return self.currentRoot or self end}
        tractor.attachImplementFromInfo=function()return true end
        AttacherJoints={MAX_ATTACH_DISTANCE_SQ=9,MAX_ATTACH_ANGLE=.5,
            updateVehiclesInAttachRange=function()return tractor,1,target,1 end}
        local c={farmId=1,now=100,settings={enabled=true,scanSeconds=12},
            reservations={},implementReservations={},tasks={},attachSessions={}}
        local parent={id='work36',state='pending'};c.tasks[parent.id]=parent
        local plan={power={object=tractor,name='T',key='t'},tool={object=target,name='Sprayer',key='sp'}}
        eq(FMAAssembler.attach(c,plan),true)
        FMAAssembler.confirm(c,parent,plan)
        FMAAssembler.update(c)
        eq(parent.state,'assembling');assert(c.attachSessions.work36)
        target.currentRoot=tractor;c.now=1100
        c.notify=function()end
        FMAAssembler.update(c)
        eq(parent.state,'pending');eq(c.attachSessions.work36,nil)
        AttacherJoints=oldAttach
    end)
    test('36: false arrival never advances staging to a remote hitch position',function()
        local parent={id='field:6:fertilize',operation='fertilize',state='assembling'}
        local power={key='t',name='T',object={posX=0,posZ=0}}
        local plan={power=power,tool={key='sp',name='Sprayer'}}
        local c={now=20000,settings={attachRetryDelaySeconds=4},tasks={[parent.id]=parent},implementReservations={}}
        local active={task={kind='assemble',parentTaskId=parent.id,alignmentMode='staging'},
            assemblyPlan=plan,trafficTarget={x=100,z=100}}
        FMAAssembler.onStopped(c,active,nil)
        eq(parent.phase,'PŘEJEZD K NÁŘADÍ NEBYL DOKONČEN')
        eq(parent.state,'pending');assert(parent.reason:find('FS25 ukončilo přejezd',1,true))
    end)
    test('36: precise hitch method attempts vehicle motor start before GIANTS travel',function()
        local source=assert(io.open('scripts/FMAAssembler.lua','r')):read('*a')
        assert(source:find("pcall(vehicle.startMotor,vehicle,true)",1,true))
        assert(source:find("FMAAssembler.hitchEvent(controller,'driveRequested'",1,true))
    end)
end
