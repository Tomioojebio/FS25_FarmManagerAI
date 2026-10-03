return function(test,eq)
    local function environment()
        local old={server=g_server,drive=AIVehicleUtil,localDir=localDirectionToWorld,worldDir=worldDirectionToLocal,raycast=raycastClosest,translation=getWorldTranslation}
        g_server={}
        local log={}
        AIVehicleUtil={driveInDirection=function(v,dt,steer,acc,slow,limit,allowed,forwards,lx,lz,maxspeed)
            log[#log+1]={vehicle=v,forwards=forwards,allowed=allowed,speed=maxspeed,lz=lz}
        end}
        localDirectionToWorld=function(node,x,y,z)return x,y,z end
        worldDirectionToLocal=function(node,x,y,z)return x,y,z end
        getWorldTranslation=function(node)return 0,0,0 end
        raycastClosest=function()return 0 end
        local motor={setSpeedLimit=function()end}
        local v={rootNode=1,spec_motorized={motor=motor},spec_drivable={},posX=0,posZ=0,isServer=true,ownerFarmId=1,
            getMotor=function(self)return self.spec_motorized.motor end,
            engine=false,ai=false,startedRequests=0,
            getIsAIActive=function(self)return self.ai end,
            getIsMotorStarted=function(self)return self.engine end,
            startMotor=function(self,on) self.startedRequests=self.startedRequests+1;self.engine=true end}
        local r={object=v,key='tractor',name='Tractor'}
        local c={now=0,farmId=1,settings={enabled=true},reservations={},implementReservations={}}
        return c,v,r,log,function()g_server,AIVehicleUtil,localDirectionToWorld,worldDirectionToLocal,raycastClosest,getWorldTranslation=old.server,old.drive,old.localDir,old.worldDir,old.raycast,old.translation end
    end
    test('40: GIANTS / CP / OWN: own driver drives real physical wheel API, starts motor, holds reservation',function()
        local c,v,r,log,restore=environment()
        local ok=FMAOwnDriver.begin(c,r,{id='third1',kind='hitch',goal={x=0,z=6,reverse=false}})
        eq(ok,true);eq(v.startedRequests,1);eq(c.reservations.tractor,'third1')
        c.now=1000;FMAOwnDriver.update(c,16)
        eq(#log,1);eq(log[1].forwards,true);eq(log[1].allowed,true);assert(log[1].speed<=3)
        v.posZ=3;c.now=2500;FMAOwnDriver.update(c,16)
        assert(c.ownDriveSessions.tractor.moveObserved)
        v.posZ=6;c.now=4200;FMAOwnDriver.update(c,16)
        eq(c.ownDriveSessions.tractor,nil);eq(c.reservations.tractor,nil)
        restore()
    end)
    test('40: physical reversing uses reverse flag, never teleports or modifies transforms',function()
        local c,v,r,log,restore=environment()
        local ok=FMAOwnDriver.begin(c,r,{id='third2',kind='hitch',goal={x=0,z=-5,reverse=true}})
        eq(ok,true);c.now=500;FMAOwnDriver.update(c,16)
        eq(log[1].forwards,false);eq(log[1].lz,1)
        eq(v.posZ,0)
        restore()
    end)
    test('48: ignition stays pending and is retried once instead of triggering no-motion failure',function()
        local c,v,r,log,restore=environment()
        v.engine=false
        v.startedRequests=0
        v.startMotor=function(self)
            self.startedRequests=self.startedRequests+1
            if self.startedRequests==2 then self.engine=true end
        end
        local ok=FMAOwnDriver.begin(c,r,{id='ignition48',goal={x=0,z=5}})
        eq(ok,true);eq(v.startedRequests,1)
        c.now=6000;FMAOwnDriver.update(c,16)
        eq(v.startedRequests,2)
        assert(c.ownDriveSessions.tractor~=nil)
        c.now=6200;FMAOwnDriver.update(c,16)
        assert(#log>0)
        restore()
    end)
    test('40: player takeover releases driving and does NOT brake player controls',function()
        local c,v,r,log,restore=environment()
        local oldManual=FMAGameNative.isManuallyControlled
        local player=false
        FMAGameNative.isManuallyControlled=function()return player end
        local last
        assert(FMAOwnDriver.begin(c,r,{id='takeover',goal={x=0,z=5},onDone=function(_,s,ok,why) last=why end}))
        c.now=100;FMAOwnDriver.update(c,16);local previous=#log
        player=true;c.now=120;FMAOwnDriver.update(c,16)
        eq(c.ownDriveSessions.tractor,nil);eq(c.reservations.tractor,nil);eq(#log,previous)
        assert(last:find('hráč'))
        FMAGameNative.isManuallyControlled=oldManual;restore()
    end)
    test('40: no physical motion fails after guard rather than claiming arrival',function()
        local c,v,r,log,restore=environment()
        local outcome
        assert(FMAOwnDriver.begin(c,r,{id='stuck',goal={x=0,z=5},onDone=function(_,s,ok,why)outcome={ok,why}end}))
        for ms=1000,12000,1000 do c.now=ms;FMAOwnDriver.update(c,16) end
        eq(c.ownDriveSessions.tractor,nil);eq(outcome[1],false);assert(outcome[2]:find('nedokázal fyzicky'))
        restore()
    end)
    test('40: concurrent base AI prevents own wheel writes, releases lease',function()
        local c,v,r,log,restore=environment()
        assert(FMAOwnDriver.begin(c,r,{id='cp-takes-over',goal={x=0,z=5}}))
        v.ai=true;c.now=100;FMAOwnDriver.update(c,16)
        eq(c.ownDriveSessions.tractor,nil);eq(#log,0)
        restore()
    end)
    test('40: bunker own driver never claims compaction without actual percent change',function()
        local c,v,r,log,restore=environment()
        local b={compactedPercent=0,object={compactedPercent=0},geometry={width=12,length=32,
            frontOutside={x=0,z=0},front={x=0,z=2},dx=0,dz=1}}
        local outcome
        local ok=FMAOwnDriver.beginBunker(c,r,b,1,nil,function(_,s,yes,why)outcome={yes,why}end)
        eq(ok,true)
        local goals={24.4,0,24.4,0,24.4}
        for i,z in ipairs(goals) do
            v.posZ=z;c.now=i*1000;FMAOwnDriver.update(c,16)
            -- Snapshot the target end from a real physical position each leg.
        end
        eq(c.ownDriveSessions.tractor,nil);eq(outcome[1],false)
        assert(outcome[2]:find('nehlásí růst'))
        restore()
    end)
    test('40: bunker own driver closes only after confirmed full compaction AND physical exit',function()
        local c,v,r,log,restore=environment()
        local b={compactedPercent=0,object={compactedPercent=0},geometry={width=12,length=32,
            frontOutside={x=0,z=0},front={x=0,z=2},dx=0,dz=1}}
        local outcome
        assert(FMAOwnDriver.beginBunker(c,r,b,1,nil,function(_,s,yes,why)outcome={yes,why}end))
        v.posZ=24.4;c.now=1000;FMAOwnDriver.update(c,16)
        b.object.compactedPercent=100
        assert(c.ownDriveSessions.tractor)
        v.posZ=0;c.now=2000;FMAOwnDriver.update(c,16)
        eq(c.ownDriveSessions.tractor,nil);eq(outcome[1],true)
        restore()
    end)
    test('40: runtime object reload never steers a replacement vehicle',function()
        local c,v,r,log,restore=environment()
        assert(FMAOwnDriver.begin(c,r,{id='reload',goal={x=0,z=6}}))
        local fresh={rootNode=2,spec_motorized={},spec_drivable={},posX=1,posZ=1,isServer=true,ownerFarmId=1}
        r.object=fresh;c.now=100;FMAOwnDriver.update(c,16)
        eq(c.ownDriveSessions.tractor,nil);eq(#log,0);eq(c.reservations.tractor,nil)
        restore()
    end)
    test('40: stalled reversing hitch physically moves forward before retry',function()
        local c,v,r,log,restore=environment()
        local final
        assert(FMAOwnDriver.begin(c,r,{id='unstick',kind='hitch',goal={x=0,z=-5,reverse=true},
            onDone=function(_,s,ok,why)final={ok,why}end}))
        for ms=1000,12000,1000 do c.now=ms;FMAOwnDriver.update(c,16) end
        local session=c.ownDriveSessions.tractor
        assert(session and session.recoveryHitch and session.goal.z>0)
        -- GIANTS wheel physics would move here; mock the observed motion only.
        v.posZ=2.5;c.now=13200;FMAOwnDriver.update(c,16)
        eq(c.ownDriveSessions.tractor,nil);eq(final[1],false)
        assert(final[2]:find('uvolnil popojetím'))
        restore()
    end)
    test('40: source integration uses third physical driver for hitch and silo, never Alt+P',function()
        local function src(name)local f=assert(io.open('scripts/'..name..'.lua'));local t=f:read('*a');f:close();return t end
        assert(src('FMAAssembler'):find('FMAOwnDriver.begin(',1,true))
        assert(src('FMABunkerCoordinator'):find('FMAOwnDriver.beginBunker(',1,true))
        assert(src('FMAController'):find('FMAOwnDriver.stopAll(',1,true))
        assert(src('FMAController'):find('pcall(FMAOwnDriver.update',1,true))
    end)
end
