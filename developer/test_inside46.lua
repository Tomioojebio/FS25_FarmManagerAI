return function(test,eq)
    test('46: machine already in measured bunker gets a real bidirectional sweep without GoTo',function()
        local oldDir,oldBegin=localDirectionToWorld,FMAOwnDriver.begin
        local ok,err=pcall(function()
            localDirectionToWorld=function()return 1,0,0 end
            local b={geometry={front={x=26,z=-535},back={x=70,z=-535},dx=1,dz=0,length=44,width=12,
                frontOutside={x=12,z=-535},backOutside={x=84,z=-535}}}
            local v={rootNode=1,size={width=3},posX=43,posZ=-535}
            local r={key='JD6',name='JD 6',object=v}
            local c={vehicles={r}}
            local plan,why=FMAOwnDriver.planInsideBunker(c,r,b)
            assert(plan,why)
            eq(plan.first.reverse,false);eq(plan.second.reverse,true)
            assert(plan.first.x>v.posX and plan.second.x<v.posX)
            local submitted
            FMAOwnDriver.begin=function(_,_,opts) submitted=opts;return true,{} end
            local started=FMAOwnDriver.beginBunker(c,r,b,1,{},function()end)
            eq(started,true)
            eq(submitted.kind,'bunker')
            eq(submitted.goal.x,plan.first.x)
            eq(submitted.waypoints[2].reverse,true)
            -- Tractor reversed in same aisle: physical forward leg changes side.
            localDirectionToWorld=function()return -1,0,0 end
            plan,why=FMAOwnDriver.planInsideBunker(c,r,b)
            assert(plan,why)
            assert(plan.first.x<v.posX and plan.second.x>v.posX)
        end)
        localDirectionToWorld,FMAOwnDriver.begin=oldDir,oldBegin
        assert(ok,err)
    end)
    test('46: bunker inside sweep rejects side wall, wrong angle or other parked tractor',function()
        local oldDir=localDirectionToWorld
        local ok,err=pcall(function()
            localDirectionToWorld=function()return 1,0,0 end
            local b={geometry={front={x=26,z=-535},back={x=70,z=-535},dx=1,dz=0,length=44,width=12}}
            local v={rootNode=1,size={width=3},posX=43,posZ=-535}
            local r={key='A',object=v,name='A'}
            local c={vehicles={r}}
            local plan=FMAOwnDriver.planInsideBunker(c,r,b)
            assert(plan)
            v.posZ=-540
            eq(FMAOwnDriver.planInsideBunker(c,r,b),nil)
            v.posZ=-535
            localDirectionToWorld=function()return 0,0,1 end
            eq(FMAOwnDriver.planInsideBunker(c,r,b),nil)
            localDirectionToWorld=function()return 1,0,0 end
            c.vehicles[2]={key='B',name='B',object={posX=60,posZ=-535}}
            local result,why=FMAOwnDriver.planInsideBunker(c,r,b)
            eq(result,nil);assert(why:find('další stroj'))
            c.vehicles[2].object.posZ=-560
            assert(FMAOwnDriver.planInsideBunker(c,r,b))
        end)
        localDirectionToWorld=oldDir
        assert(ok,err)
    end)
    test('46: stalled harvest attempts only one alternate Courseplay engine',function()
        local oldRetry,oldAvailable,oldCan,oldEvent=FMAHeaderTransport.retryFieldOutbound,FMACourseplay.available,FMAControlAuthority.canStart,FMADiagnostics.event
        local ok,err=pcall(function()
            local calls=0
            FMAHeaderTransport.retryFieldOutbound=function(c,parent,record,plan,why,forceCp)
                calls=calls+1;eq(forceCp,true);return true,nil
            end
            FMACourseplay.available=function()return true end
            FMAControlAuthority.canStart=function()return true end
            FMADiagnostics.event=function()end
            local parent={id='field:64:harvest',state='assembling',label='Harvest'}
            local plan={outboundTries=1}
            local rec={name='LEXION 6900'}
            local active={task={parentTaskId=parent.id,phase='toFieldWithCarrier'},headerPlan=plan,vehicle=rec,
                stopReason='AI převzala stroj, ale ten se do 23 s nerozjel'}
            local controller={tasks={[parent.id]=parent},issue=function()end}
            FMAHeaderTransport.onStopped(controller,active,'')
            eq(calls,1);eq(plan.stationaryCpTried,true)
            FMAHeaderTransport.onStopped(controller,active,'')
            eq(calls,1);eq(parent.state,'blocked')
        end)
        FMAHeaderTransport.retryFieldOutbound,FMACourseplay.available,FMAControlAuthority.canStart,FMADiagnostics.event=oldRetry,oldAvailable,oldCan,oldEvent
        assert(ok,err)
    end)
end
