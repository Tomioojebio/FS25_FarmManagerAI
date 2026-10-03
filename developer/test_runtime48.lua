return function(test,eq)
    test('48: actual GIANTS motor missing rejects own driving BEFORE sending physics API',function()
        local priorServer,priorDriver,priorLocal,priorWorld=g_server,AIVehicleUtil,localDirectionToWorld,worldDirectionToLocal
        g_server={};AIVehicleUtil={driveInDirection=function() error('must never call motorless physics') end}
        localDirectionToWorld=function() return 0,0,1 end
        worldDirectionToLocal=function() return 0,0,1 end
        local v={rootNode=1,spec_motorized={},spec_drivable={},isServer=true,
            getMotor=function()return nil end,startMotor=function()end,getIsMotorStarted=function()return false end}
        local ok,why=FMAOwnDriver.available(v)
        eq(ok,false)
        assert(tostring(why):find('getMotor/setSpeedLimit',1,true))
        g_server,AIVehicleUtil,localDirectionToWorld,worldDirectionToLocal=priorServer,priorDriver,priorLocal,priorWorld
    end)
    test('48: actual engine absent after initialisation fails closed rather than throwing setSpeedLimit',function()
        local prior={server=g_server,drive=AIVehicleUtil,localDir=localDirectionToWorld,worldDir=worldDirectionToLocal}
        g_server={}
        local driveCalls=0
        AIVehicleUtil={driveInDirection=function() driveCalls=driveCalls+1 end}
        localDirectionToWorld=function(node,x,y,z)return x,y,z end
        worldDirectionToLocal=function(node,x,y,z)return x,y,z end
        local motor={setSpeedLimit=function()end}
        local v={rootNode=1,spec_motorized={motor=motor},spec_drivable={},isServer=true,ownerFarmId=1,posX=0,posZ=0,
            getMotor=function(self)return self.spec_motorized.motor end,
            getIsAIActive=function()return false end,
            getIsMotorStarted=function()return true end,
            startMotor=function()end}
        local rec={key='motor48',object=v,name='Test machine'}
        local c={now=0,farmId=1,settings={enabled=true},reservations={},implementReservations={}}
        local reason
        local ok=FMAOwnDriver.begin(c,rec,{id='motor48task',goal={x=0,z=8},onDone=function(_,_,good,why)
            eq(good,false);reason=why end})
        eq(ok,true)
        v.spec_motorized.motor=nil
        c.now=200
        FMAOwnDriver.update(c,16)
        assert(tostring(reason):find('getMotor=nil',1,true))
        eq(driveCalls,0)
        eq(c.ownDriveSessions.motor48,nil)
        g_server,AIVehicleUtil,localDirectionToWorld,worldDirectionToLocal=prior.server,prior.drive,prior.localDir,prior.worldDir
    end)
    test('48: requested Courseplay-only transfer NEVER silently retries GIANTS_GOTO',function()
        local oldCp=FMACourseplay
        FMACourseplay={available=function()return false end}
        local c={now=100,settings={navigationLearning=false}}
        local r={object={},name='LEXION 6900',key='test-lexion'}
        local result,why=FMAAI.createTransferJob(c,r,{x=654,z=373,requireCourseplay=true})
        eq(result,nil)
        assert(tostring(why):find('Courseplay opravdu neprevzal',1,true))
        FMACourseplay=oldCp
    end)
    test('48: stopped harvest requires explicit actual Courseplay selection',function()
        local f=assert(io.open('scripts/FMAHeaderTransport.lua','r'))
        local src=f:read('*a');f:close()
        assert(src:find('requireCourseplay=forceCp==true',1,true))
        assert(src:find('header.STATIONARY_CP_REFUSED',1,true))
        assert(src:find('maxAttempts=(plan.outboundTries or 0)+1',1,true))
    end)
end
