return function(test,eq)
    test('23: excluded vehicle cannot masquerade as transient takeover',function()
        local old=g_currentMission
        local obj={isDeleted=false,getIsEntered=function() return false end}
        g_currentMission={player={currentVehicle=nil},controlledVehicle=nil}
        local c={settings={enabled=true},farmId=1,excluded={x=true}}
        local oldOwner=FMAUtil.owner;FMAUtil.owner=function() return 1 end
        local ok,why=FMALifecycle.allowed(c,{key='x',object=obj},false)
        eq(ok,false);eq(why,'Stroj vyřazen z automatizace majitelem')
        FMAUtil.owner=oldOwner;g_currentMission=old
    end)
    test('23: initial UI opens the simple job board',function()
        local c=FMAController.new()
        eq(c.page,9);eq(c.fmaTaskListMode,true)
    end)
    test('23: false cabin occupancy does not count as human takeover',function()
        local old=g_currentMission
        local helper={getIsEntered=function() return true end,getIsAIActive=function()return false end}
        g_currentMission={player={currentVehicle=nil},controlledVehicle={}}
        eq(FMAGameNative.operatorState(helper).manual,false)
        g_currentMission.controlledVehicle=helper
        eq(FMAGameNative.operatorState(helper).manual,true)
        helper.getIsAIActive=function()return true end
        eq(FMAGameNative.operatorState(helper).manual,false)
        g_currentMission=old
    end)
    test('23: approved owner intervention resumes only after real release',function()
        local task={id='lime',state='paused',ownerApproved=true,reason='Stroj převzal majitel',lastManualVehicleKey='v',lastManualCheckAt=1000}
        local v={getIsEntered=function()return true end,getIsAIActive=function()return false end}
        local r={key='v',object=v}
        local old=g_currentMission
        g_currentMission={player={currentVehicle=v},controlledVehicle=v}
        local c={settings={enabled=true},now=5200,tasks={lime=task},vehicleByKey={v=r},active={},playerTakeovers={}}
        eq(FMALifecycle.resumeReleasedOrders(c),0)
        eq(task.state,'paused')
        g_currentMission.controlledVehicle=nil;g_currentMission.player.currentVehicle=nil
        eq(FMALifecycle.resumeReleasedOrders(c),1)
        eq(task.state,'pending')
        eq(task.retryAt,6700)
        g_currentMission=old
    end)
    test('23: explicit STOP is never auto-resumed or dispatched',function()
        local task={id='lime',state='paused',ownerApproved=false,ownerStopRequested=true,reason='Stroj převzal majitel',lastManualCheckAt=1}
        local c={settings={enabled=true},now=8000,tasks={lime=task},active={}}
        eq(FMALifecycle.resumeReleasedOrders(c),0)
        eq(task.state,'paused')
    end)
    test('23: START STOP selected order never disables other live AI jobs',function()
        local old=FMAAI.stop
        local stopped={}
        FMAAI.stop=function(job)stopped[job]=true end
        local a={id='a',label='Sklizeň',state='running',ownerApproved=true}
        local b={id='b',label='Vápnění',state='running',ownerApproved=true}
        local r1={key='v1',name='Kombajn',busy=true};local r2={key='v2',name='Crystal',busy=true}
        local jobA,jobB={},{}
        local c={settings={enabled=true},active={[jobA]={task=a,vehicle=r1},[jobB]={task=b,vehicle=r2}},
            tasks={a=a,b=b},now=500,preparedSupport={},reservations={},notify=function()end}
        eq(FMAHud.stopTask(c,a),true)
        eq(stopped[jobA],true);eq(stopped[jobB],nil)
        eq(a.ownerApproved,false);eq(a.state,'paused')
        eq(b.ownerApproved,true);eq(b.state,'running');eq(c.settings.enabled,true)
        FMAAI.stop=old
    end)
    test('23: minimal menu exposes START STOP reason without implicit toggles',function()
        local t={id='field:32:harvest',label='32 · Sklizeň',state='blocked',priority=90,reason='Adaptér nebyl připojen'}
        local c={page=9,fmaTaskListMode=true,tasks={[t.id]=t},settings={enabled=true}}
        local rows=FMAHud.rows(c)
        eq(rows[1].object.slot,'simpleOpen')
        eq(t.ownerMarked,nil)
        c.focusTaskId=t.id;c.fmaTaskListMode=false
        rows=FMAHud.rows(c)
        eq(rows[1].object.slot,'simpleStart')
        eq(rows[2].object.slot,'simpleStop')
        assert(rows[4].detail:find('Adaptér nebyl připojen',1,true))
    end)
end
