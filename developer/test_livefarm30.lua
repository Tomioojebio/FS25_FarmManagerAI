return function(test,eq)
    test('30: Alt+M releases the mouse cursor even when CpHud.isHudActive is a function',function()
        local savedGui,savedInput,savedMission,savedCp=g_gui,g_inputBinding,g_currentMission,CpHud
        local calls={};local shown=false
        g_gui={getIsGuiVisible=function()return false end,getIsDialogVisible=function()return false end}
        g_inputBinding={getShowMouseCursor=function()return shown end,
            setShowMouseCursor=function(_,v) shown=v;calls[#calls+1]=v end}
        local first={isRotatable=true};local second={isRotatable=false};local third={}
        g_currentMission={controlledVehicle={spec_enterable={cameras={first,second,third}}}}
        CpHud={isHudActive=function()return false end}
        local c={visible=false,now=0}
        FMAHud.setVisible(c,true)
        eq(shown,true);eq(first.isRotatable,true);eq(second.isRotatable,false);eq(third.isRotatable,nil)
        FMAHud.setVisible(c,false)
        eq(shown,false);eq(first.isRotatable,true);eq(second.isRotatable,false);eq(third.isRotatable,nil)
        eq(#calls,2)
        g_gui,g_inputBinding,g_currentMission,CpHud=savedGui,savedInput,savedMission,savedCp
    end)
    test('30: preexisting external cursor is never stolen from Courseplay',function()
        local savedGui,savedInput,savedMission=g_gui,g_inputBinding,g_currentMission
        local calls=0
        g_gui={getIsGuiVisible=function()return false end}
        g_inputBinding={getShowMouseCursor=function()return true end,
            setShowMouseCursor=function()calls=calls+1 end}
        local cam={isRotatable=true};g_currentMission={controlledVehicle={spec_enterable={cameras={cam}}}}
        local c={visible=false}
        FMAHud.setVisible(c,true);FMAHud.setVisible(c,false)
        eq(cam.isRotatable,true);eq(calls,0)
        g_gui,g_inputBinding,g_currentMission=savedGui,savedInput,savedMission
    end)
    test('30: full but under-compacted silage bunkers become visible jobs without deliveries',function()
        local s=FMAState.new().settings;s.bunkerAutomation=true
        local c={settings=s,bunkers={{key='farm:one',x=5,z=5,fillLevel=2300000,compactedPercent=18,canClose=false},
            {key='farm:two',x=10,z=10,fillLevel=2300000,compactedPercent=65,canClose=false},
            {key='farm:three',x=12,z=12,fillLevel=2300000,compactedPercent=100,canClose=false}},bunkerWorkState={}}
        local result=FMABunkerCoordinator.proposals(c)
        eq(#result,2)
        eq(result[1].kind,'bunkerWorkOrder');eq(result[1].id,'bunkerOrder:farm:one')
        assert(result[1].label:find('18',1,true));eq(result[2].compactedPercent,nil)
    end)
    test('30: inactive bunker mode is transparently blocked, not silently marked complete',function()
        local saved=BunkerSilo;BunkerSilo={STATE_FILL=3}
        local c={settings={bunkerAutomation=true,bunkerTargetCompaction=0.98},bunkers={{key='b1',fillLevel=1100,compactedPercent=0,state=5}},bunkerWorkState={}}
        local tasks=FMABunkerCoordinator.proposals(c);eq(tasks[1].state,'blocked')
        assert(tasks[1].reason:find('příjmu',1,true))
        BunkerSilo=saved
    end)
    test('30: approved bunker order retains identity through task replan',function()
        local c={settings={bunkerAutomation=true,bunkerTargetCompaction=0.98},bunkers={{key='b1',fillLevel=1600,compactedPercent=35}},bunkerWorkState={}}
        local old=FMABunkerCoordinator.proposals(c)[1];old.ownerApproved=true
        c.bunkers[1].compactedPercent=55
        local tasks=FMAPlanner.merge({[old.id]=old},FMABunkerCoordinator.proposals(c),100)
        eq(tasks[old.id].ownerApproved,true)
    end)
    test('30: livestock straw deficit creates explicit blocked job when there is no AI access',function()
        local oldMission=g_currentMission
        local h={ownerFarmId=1,customName='Test Barn',posX=10,posZ=25,spec_husbandry={},spec_husbandryStraw={inputFillType=17},
            getHusbandryFillLevel=function()return 0 end,getHusbandryCapacity=function()return 10000 end}
        g_currentMission={placeableSystem={placeables={h}},storageSystem={getLoadingStations=function()return {} end,getUnloadingStations=function()return {} end}}
        local c={settings={livestock=true,strawTarget=0.65},farmId=1,livestockPlans={}}
        local tasks=FMALivestockCoordinator.careProposals(c)
        eq(#tasks,1);eq(tasks[1].kind,'livestockNeed');eq(tasks[1].state,'blocked');eq(tasks[1].needed,6500)
        assert(tasks[1].reason:find('sklad',1,true))
        g_currentMission=oldMission
    end)
    test('30: owned AI source and husbandry AI tip trigger activate real physical supply order',function()
        local oldMission=g_currentMission
        local h={ownerFarmId=1,posX=10,posZ=25,spec_husbandry={},spec_husbandryStraw={inputFillType=17},
            getHusbandryFillLevel=function()return 100 end,getHusbandryCapacity=function()return 10000 end}
        local storagePlace={ownerFarmId=1}
        local src={owningPlaceable=storagePlace,getAISupportedFillTypes=function()return {[17]=true} end,getFillLevel=function()return 12000 end}
        local dst={owningPlaceable=h,getAISupportedFillTypes=function()return {[17]=true} end}
        g_currentMission={placeableSystem={placeables={h}},storageSystem={getLoadingStations=function()return {src} end,getUnloadingStations=function()return {dst} end}}
        local c={settings={livestock=true,strawTarget=0.65},farmId=1,livestockPlans={}}
        local tasks=FMALivestockCoordinator.careProposals(c)
        eq(#tasks,1);eq(tasks[1].kind,'supply');eq(tasks[1].state,'pending');eq(tasks[1].destination,dst);eq(tasks[1].source,src)
        g_currentMission=oldMission
    end)
    test('30: water in automatic-water barns does not become fake supply job',function()
        local oldMission=g_currentMission
        local h={ownerFarmId=1,spec_husbandry={},spec_husbandryWater={automaticWaterSupply=true,fillType=9},
            getHusbandryFillLevel=function()return 0 end,getHusbandryCapacity=function()return 10000 end}
        g_currentMission={placeableSystem={placeables={h}},storageSystem={getLoadingStations=function()return {} end}}
        local c={settings={livestock=true,waterTarget=0.6},farmId=1,livestockPlans={}}
        eq(#FMALivestockCoordinator.careProposals(c),0)
        g_currentMission=oldMission
    end)
    test('30: new AI unloading trigger re-opens previously blocked livestock order',function()
        local old={id='livestock:care:p:17',kind='livestockNeed',operation='supply',state='blocked',
                   blockedByIntegration=true,ownerApproved=true,reason='no trigger'}
        local cand={id=old.id,kind='supply',operation='supply',state='pending',source={},destination={},fillType=17,phase='READY'}
        local fresh=FMAPlanner.merge({[old.id]=old},{cand},999)[old.id]
        eq(fresh.state,'pending');eq(fresh.kind,'supply');eq(fresh.ownerApproved,true)
    end)
    test('30: explicitly stopped livestock care order is never silently reactivated',function()
        local old={id='livestock:care:p:17',kind='livestockNeed',operation='supply',state='paused',
                   blockedByIntegration=true,ownerStopRequested=true,ownerApproved=false}
        local cand={id=old.id,kind='supply',operation='supply',state='pending',source={},destination={},fillType=17,phase='READY'}
        local fresh=FMAPlanner.merge({[old.id]=old},{cand},999)[old.id]
        eq(fresh.state,'paused');eq(fresh.ownerApproved,false)
    end)
    test('30: source disappearing after owner approval blocks supply before starting an AI job',function()
        local id='livestock:care:p:17'
        local old={id=id,kind='supply',operation='supply',state='pending',ownerApproved=true,
            source={getFillLevel=function()return 1000 end},destination={},fillType=17}
        local candidate={id=id,kind='livestockNeed',operation='supply',state='blocked',
            blockedByIntegration=true,reason='Chybí vlastní sklad',label='Kravský chlév · sláma',
            phase='POTŘEBA CHOVU',fillType=17}
        local now=FMAPlanner.merge({[id]=old},{candidate},200)[id]
        eq(now.state,'blocked');eq(now.kind,'livestockNeed');eq(now.ownerApproved,true)
        eq(now.source,nil);eq(now.destination,nil)
        eq(now.reason,'Chybí vlastní sklad')
    end)
    test('30: bunker compaction and display percentage stay synchronized across scans',function()
        local id='bunkerOrder:stable'
        local old={id=id,kind='bunkerWorkOrder',operation='compact',state='pending',ownerApproved=true,
            label='Silážní jáma 1 · hutnění 18 %',bunkerIndex=1,compactBefore=18,priority=90}
        local candidate={id=id,kind='bunkerWorkOrder',operation='compact',state='pending',
            label='Silážní jáma 1 · hutnění 65 %',bunkerIndex=2,compactBefore=65,priority=88}
        local now=FMAPlanner.merge({[id]=old},{candidate},200)[id]
        eq(now.ownerApproved,true);eq(now.label,'Silážní jáma 1 · hutnění 65 %')
        eq(now.bunkerIndex,2);eq(now.compactBefore,65);eq(now.priority,88)
    end)
    test('30: stopped livestock order stays paused when loading path disappears',function()
        local id='livestock:care:p:17'
        local old={id=id,kind='supply',operation='supply',state='paused',ownerApproved=false,ownerStopRequested=true}
        local candidate={id=id,kind='livestockNeed',operation='supply',state='blocked',blockedByIntegration=true,reason='no trigger'}
        local now=FMAPlanner.merge({[id]=old},{candidate},200)[id]
        eq(now.state,'paused');eq(now.ownerStopRequested,true);eq(now.kind,'livestockNeed')
    end)
    test('30: blocked husbandry deficit cannot be misrepresented as STARTed work',function()
        local c={supported=true,settings={enabled=true},notify=function(self,s)self.message=s end}
        local t={kind='livestockNeed',state='blocked',reason='no AI station'}
        FMAHud.activateTask(c,t)
        eq(t.state,'blocked');assert(c.message:find('no AI station',1,true))
    end)
end
