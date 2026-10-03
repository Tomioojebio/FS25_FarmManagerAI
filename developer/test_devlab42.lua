return function(test,eq)
  local function farm()
    local v={rootNode=5,posX=100,posZ=100,isServer=true,spec_motorized={},spec_drivable={},
      getOwnerFarmId=function() return 1 end,
      getIsAIActive=function()return false end,
      getIsMotorStarted=function(self)return self.running==true end,
      startMotor=function(self)self.running=true end,
      stopMotor=function(self)self.running=false end,
      getAttachedImplements=function()return {} end}
    local r={key='v1',name='Test tractor',object=v,busy=false}
    local c={farmId=1,initialized=true,settings={enabled=false},vehicles={r},
      tasks={},loose={},parkingFacilities={{x=0,z=0}},parkingBays={{id='safe'}},
      excluded={},reservations={},active={},ownDriveSessions={},notify=function()end}
    return c,v,r
  end
  test('DevLab passive monitor collects motor and authority evidence without driving',function()
    local c,v=farm()
    local old=FMAControlAuthority.snapshot
    FMAControlAuthority.snapshot=function()return {mode='GIANTS_AI',ai=true,jobId='field42'} end
    v.getIsAIActive=function()return true end
    c.devLab={clock=0,nextSample=0,nextReport=24000,vehicles={},events={},anomalies={},count={},reports=0,frame=0,steps={},signatures={},errors=0}
    for i=1,16 do c.devLab.clock=i*1600;FMADevLab.sample(c) end
    eq((c.devLab.count.STALLED or 0)>0,true)
    eq((c.devLab.count.AI_ENGINE_OFF or 0)>0,true)
    eq(v.running,nil)
    assert(FMADevLab.report(c):find('STALLED',1,true))
    FMAControlAuthority.snapshot=old
  end)
  test('DevLab physical probe rejects normal AUTO and does not touch engine',function()
    local c,v=farm();c.settings.enabled=true
    local ok=FMADevLab.beginPhysical(c)
    eq(ok,false);eq(v.running,nil)
  end)
  test('DevLab physical probe skips densely parked tractor without moving it',function()
    local c,v=farm();c.parkingFacilities={{x=105,z=100}}
    local ok=FMADevLab.beginPhysical(c)
    eq(ok,false);eq(v.running,nil)
  end)
  test('DevLab test starts motor only when explicitly requested',function()
    local c,v=farm();local old=FMAControlAuthority.snapshot
    FMAControlAuthority.snapshot=function()return {mode='IDLE',ai=false} end
    local oldDriver=AIVehicleUtil
    AIVehicleUtil={driveInDirection=function()end}
    local oldServer=g_server;g_server={}
    local ok,why=FMADevLab.beginPhysical(c)
    eq(ok,true);eq(v.running,true);eq(c.reservations.v1,'__FMA_DEVLAB__')
    FMADevLab.stop(c)
    eq(v.running,false);eq(c.reservations.v1,nil)
    FMAControlAuthority.snapshot=old;AIVehicleUtil=oldDriver;g_server=oldServer
  end)
  test('DevLab engine and forward reverse stages require measured real displacement',function()
    local c,v=farm();local old=FMAControlAuthority.snapshot
    FMAControlAuthority.snapshot=function()return {mode='IDLE',ai=false} end
    local oldDriver=AIVehicleUtil;local oldServer=g_server
    AIVehicleUtil={driveInDirection=function(self,dt,limit,accel,slow,angle,allowed,forward)
      if allowed then self.posZ=self.posZ+(forward and 0.34 or -0.34) end
    end};g_server={}
    local ok=FMADevLab.beginPhysical(c);eq(ok,true)
    local l=c.devLab
    for i=1,20 do if not l.physical then break end;l.clock=l.clock+300;FMADevLab.physicalUpdate(c,100) end
    eq(l.complete:find('PASS',1,true)~=nil,true)
    eq(c.reservations.v1,nil)
    eq(v.running,false)
    FMAControlAuthority.snapshot=old;AIVehicleUtil=oldDriver;g_server=oldServer
  end)
end
