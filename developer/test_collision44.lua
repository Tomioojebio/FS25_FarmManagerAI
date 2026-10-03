return function(test,eq)
    local function bunker()
        -- Synthetic rectangular lane; the regression trace shows a Xerion
        -- leaving the silo area towards farm buildings while its CP job ran.
        return {key='test-silo',object={fillLevel=200,compactedPercent=20,state=0},
            geometry={front={x=26,z=-535},dx=1,dz=0,length=44,width=12,
                frontOutside={x=12,z=-535},backOutside={x=84,z=-535}}}
    end
    test('44: bunker containment permits real entrance and aisle, rejects wrong direction',function()
        local b=bunker()
        eq(FMABunkerCoordinator.withinWorkEnvelope(b,79,-532),true)
        eq(FMABunkerCoordinator.withinWorkEnvelope(b,50,-535),true)
        eq(FMABunkerCoordinator.withinWorkEnvelope(b,116,-532),false)
        eq(FMABunkerCoordinator.withinWorkEnvelope(b,50,-515),false)
        eq(FMABunkerCoordinator.withinWorkEnvelope({},50,-535),false)
    end)
    test('45: CP worker outside bunker is stopped immediately instead of grace period',function()
        local job={}
        local stopCount=0
        local oldStop=FMAAI.stop
        local oldPosition=FMAUtil.position
        local oldEvent=FMADiagnostics.event
        local ok,err=pcall(function()
            FMAAI.stop=function(j) eq(j,job);stopCount=stopCount+1 end
            FMAUtil.position=function(v) return v.x,v.z end
            FMADiagnostics.event=function() end
            local v={x=116,z=-532}
            local task={kind='bunker',bunkerIndex=1}
            local a={task=task,vehicle={key='xerion',name='XERION',object=v}}
            local c={bunkers={bunker()},active={[job]=a},now=1000,
                settings={enabled=true,bunkerAutomation=true,bunkerTargetCompaction=.98},
                tasks={},issue=function()end}
            FMABunkerCoordinator.enforceSafety(c)
            eq(stopCount,1)
            c.now=1600
            FMABunkerCoordinator.enforceSafety(c)
            eq(stopCount,1)
            assert(task.safetyStopIssued and a.stopReason:find('BEZPEČNOST',1,true))
            c.now=2200
            FMABunkerCoordinator.enforceSafety(c)
            eq(stopCount,1)
        end)
        FMAAI.stop=oldStop;FMAUtil.position=oldPosition;FMADiagnostics.event=oldEvent
        if not ok then error(err) end
    end)
    test('44: a bunker geofence fault locks the whole silo against automatic retry',function()
        local b=bunker()
        local c={bunkers={b},bunkerWorkState={},now=1500,
            settings={bunkerTargetCompaction=.98},issue=function()end}
        local root={state='running'}
        local a={task={kind='bunker',bunkerIndex=1,parentTask=root},
            vehicle={key='xerion',name='XERION'},start=800,
            stopReason='BEZPEČNOST: stroj opustil ověřenou oblast silážní jámy'}
        eq(FMABunkerCoordinator.onStopped(c,a),true)
        local ws=c.bunkerWorkState[1]
        assert(ws.blocked==true and ws.ownFallbackDenied==true)
        eq(root.state,'pending')
        assert(ws.lastError:find('BEZPEČNOST:',1,true))
    end)
    test('44: stationary harvest combine does not silently reroute to 52 destinations',function()
        local oldEvent=FMADiagnostics.event
        FMADiagnostics.event=function()end
        local parent={id='field:64:harvest',label='64 harvest',state='running'}
        local c={tasks={[parent.id]=parent},issue=function()end}
        local a={task={parentTaskId=parent.id,phase='toFieldWithCarrier'},
            headerPlan={outboundTries=1,carrier={key='trailer'}},
            stopReason='AI převzala stroj, ale ten se do 23 s nerozjel',
            vehicle={key='lexion',name='LEXION 6900'},physicalMotionVerified=false}
        local ok,err=pcall(FMAHeaderTransport.onStopped,c,a,'')
        FMADiagnostics.event=oldEvent
        assert(ok,err)
        eq(parent.state,'blocked')
        eq(parent.phase,'KOMBAJN SE FYZICKY NEROZJEL')
        eq(a.headerPlan.outboundTries,1)
    end)
end
