return function(test,eq)
    local function fixture()
        local v={posX=91.4,posZ=-546.3,rootNode=4,getOwnerFarmId=function()return 1 end,
            getIsAIActive=function()return false end}
        local parent={id='field:6:fertilize',label='6 · Hnojení',state='pending',operation='fertilize'}
        local power={key='crystal',name='CRYSTAL HD 170',object=v}
        local tool={key='valmar',name='9620 Air Boom Applicator',object={posX=100,posZ=-550}}
        local plan={power=power,tool=tool}
        local c={now=20000,farmId=1,settings={enabled=true,attachRetryDelaySeconds=4,fieldStageAttempts=5},
            tasks={[parent.id]=parent},active={},reservations={},implementReservations={},
            assemblyLeases={},assemblyToolLeases={},issues={},issue=function(self,id,title,detail)self.issues[id]=detail end}
        local function active(index)
            return {assemblyPlan=plan,task={parentTaskId=parent.id,alignmentMode='staging',candidateIndex=index or 1},
                transferMethod='COURSEPLAY_ROUTE_ALTERNATIVE',trafficTarget={x=99.752,z=-549.244},
                startPosition={x=91.4,z=-546.3}}
        end
        return c,parent,plan,v,active
    end
    test('0.20.43: false CP success 8.8m away advances staging rather than repeating point one',function()
        local c,parent,plan,v,active=fixture()
        local oldStages=FMAAssembler.stagingCandidates
        local oldRescue=FMAAssembler.trySafeLocalRescue
        local oldFailover=FMAAssembler.tryAlternatePower
        FMAAssembler.stagingCandidates=function()return {{x=99,z=-549},{x=103,z=-555},{x=112,z=-560},{x=120,z=-566},{x=100,z=-530}}end
        FMAAssembler.trySafeLocalRescue=function()return false end
        FMAAssembler.tryAlternatePower=function()return false end
        FMAAssembler.onStopped(c,active(1),nil)
        eq(parent.stagingCandidateCursor,2)
        eq(c.assemblyCircuits[parent.id].failures,1)
        FMAAssembler.onStopped(c,active(2),nil)
        eq(parent.stagingCandidateCursor,3)
        for i=3,5 do FMAAssembler.onStopped(c,active(i),nil) end
        eq(parent.state,'blocked')
        eq(c.assemblyCircuits[parent.id].halted,true)
        eq(c.assemblyCircuits[parent.id].failures,5)
        assert(c.issues['assemblyLoop:'..parent.id])
        FMAAssembler.stagingCandidates=oldStages
        FMAAssembler.trySafeLocalRescue=oldRescue
        FMAAssembler.tryAlternatePower=oldFailover
    end)
    test('0.20.43: actual 3m relocation resets halted physical progress circuit',function()
        local c,parent,plan,v,active=fixture()
        c.assemblyCircuits={[parent.id]={signature='crystal/valmar',failures=5,startedX=91.4,startedZ=-546.3,halted=true}}
        v.posX=95.4
        local stopped=FMAAssembler.observeApproach(c,parent,plan,active(1),'arrived badly')
        eq(stopped,false)
        eq(c.assemblyCircuits[parent.id].failures,0)
        eq(c.assemblyCircuits[parent.id].halted,false)
    end)
    test('0.20.43: local physical recovery requires genuine short distance and safe heading',function()
        local c,parent,plan,v=fixture()
        c.assemblyCircuits={[parent.id]={signature='crystal/valmar',failures=2,startedX=v.posX,startedZ=v.posZ}}
        local oldA=FMAOwnDriver.available; local oldPose=FMAAssembler.approachPoint
        local oldL=localDirectionToWorld;local oldStart=FMAAssembler.startDrive
        FMAOwnDriver.available=function()return true end
        FMAAssembler.approachPoint=function()return {x=91.4,z=-552.3,reverse=true} end
        localDirectionToWorld=function() return 0,0,1 end
        local launches=0
        FMAAssembler.startDrive=function() launches=launches+1;return true end
        eq(FMAAssembler.trySafeLocalRescue(c,parent,plan),true)
        eq(launches,1)
        FMAAssembler.approachPoint=function()return {x=91.4,z=-570,reverse=true} end
        eq(FMAAssembler.trySafeLocalRescue(c,parent,plan),false)
        eq(launches,1)
        localDirectionToWorld=function()return 0,0,-1 end
        FMAAssembler.approachPoint=function()return {x=91.4,z=-552.3,reverse=true} end
        eq(FMAAssembler.trySafeLocalRescue(c,parent,plan),false)
        eq(launches,1)
        FMAOwnDriver.available=oldA;FMAAssembler.approachPoint=oldPose
        localDirectionToWorld=oldL;FMAAssembler.startDrive=oldStart
    end)
end
