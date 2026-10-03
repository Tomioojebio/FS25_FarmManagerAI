return function(test,eq)
    test('31: an unreachable native assembly staging retries same pose through CP once',function()
        local original=FMAAssembler.stagingCandidates
        FMAAssembler.stagingCandidates=function() return {{x=10,z=5},{x=20,z=5}} end
        local parent={id='f:6',operation='fertilize',state='assembling',stagingCandidateCursor=1}
        local plan={power={key='jd',name='JD'},tool={key='sprayer',name='Sprayer'}}
        local c={tasks={['f:6']=parent},implementReservations={},now=10000,settings={attachRetryDelaySeconds=4}}
        local active={task={parentTaskId='f:6',kind='assemble',alignmentMode='staging',candidateIndex=1},
            assemblyPlan=plan,stopReason='Pracovník přestal: cíl není dosažitelný',transferMethod='GIANTS_GOTO'}
        FMAAssembler.onStopped(c,active,nil)
        eq(parent.stagingCandidateCursor,1)
        eq(parent.assemblyTryCourseplay,true)
        eq(parent.phase,'NÁHRADNÍ NÁJEZD · COURSEPLAY')
        -- The independent CP attempt may also fail: only then try a different safe point.
        active.task.stagingCpAttempt=true
        active.transferMethod='COURSEPLAY_ROUTE_ALTERNATIVE'
        parent.assemblyTryCourseplay=nil
        FMAAssembler.onStopped(c,active,nil)
        eq(parent.stagingCandidateCursor,2)
        eq(parent.assemblyTryCourseplay,nil)
        eq(parent.state,'pending')
        FMAAssembler.stagingCandidates=original
    end)
    test('31: an AI start rejection is NOT misdiagnosed as an impassable road',function()
        local original=FMAAssembler.stagingCandidates
        FMAAssembler.stagingCandidates=function()return {{x=10,z=5},{x=20,z=5}}end
        local parent={id='f:6',operation='fertilize',stagingCandidateCursor=1}
        local plan={power={key='jd',name='JD'},tool={key='sprayer',name='Sprayer'}}
        local c={tasks={['f:6']=parent},implementReservations={},now=10000,settings={attachRetryDelaySeconds=4}}
        local active={task={parentTaskId='f:6',kind='assemble',alignmentMode='staging',candidateIndex=1},assemblyPlan=plan,
            stopReason='FS25 nepotvrdilo převzetí pomocného přejezdu do 12 s',transferMethod='GIANTS_GOTO',dispatchRejected=true}
        FMAAssembler.onStopped(c,active,nil)
        eq(parent.assemblyTryCourseplay,nil)
        eq(parent.stagingCandidateCursor,2)
        FMAAssembler.stagingCandidates=original
    end)
    test('31: exhausted assembler changes to another compatible tractor only when AUTO',function()
        local oldFind=FMAAssembler.findPlan
        local tried=false
        FMAAssembler.findPlan=function(_,parent)
            tried=true
            eq(parent.preferredVehicleKey,nil)
            eq(parent.preferredImplementKey,'spreader')
            eq(parent.failedVehicleKeys.old,true)
            return {power={key='new',name='New Tractor'},tool={key='spreader',name='Spreader'}}
        end
        local parent={id='f:5',operation='lime',preferredVehicleKey='old',preferredVehicleName='Old Tractor',ownerPinnedVehicle=false,
            preferredImplementKey='spreader',preferredImplementName='Spreader'}
        local plan={power={key='old',name='Old Tractor'},tool={key='spreader',name='Spreader'}}
        local c={now=30000,settings={attachRetryDelaySeconds=4}}
        eq(FMAAssembler.tryAlternatePower(c,parent,plan),true)
        eq(tried,true);eq(parent.preferredVehicleKey,'new');eq(parent.assemblyPowerFailovers,1)
        eq(parent.state,'pending');eq(parent.stagingCandidateCursor,1)
        FMAAssembler.findPlan=oldFind
    end)
    test('31: explicit owner tractor selection forbids automatic tractor swap',function()
        local parent={id='f:5',operation='lime',preferredVehicleKey='old',ownerPinnedVehicle=true}
        local plan={power={key='old',name='Old Tractor'},tool={key='spreader',name='Spreader'}}
        local c={now=30000,settings={}}
        eq(FMAAssembler.tryAlternatePower(c,parent,plan),false)
        eq(parent.preferredVehicleKey,'old')
    end)
    test('31: when no verified replacement exists, original tractor choice is retained and blocked',function()
        local oldFind=FMAAssembler.findPlan
        FMAAssembler.findPlan=function() return nil,'Žádný volný traktor' end
        local parent={id='f:5',operation='lime',preferredVehicleKey='old',preferredVehicleName='Old Tractor'}
        local plan={power={key='old',name='Old Tractor'},tool={key='spreader',name='Spreader'}}
        local c={now=30000,settings={}}
        eq(FMAAssembler.tryAlternatePower(c,parent,plan),false)
        eq(parent.preferredVehicleKey,'old');eq(parent.assemblyPowerFailovers,nil)
        eq(parent.failedVehicleKeys.old,nil)
        FMAAssembler.findPlan=oldFind
    end)
end
