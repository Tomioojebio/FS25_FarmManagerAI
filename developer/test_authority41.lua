return function(test,eq)
 local function v(key)
   local object={ownerFarmId=1,spec_motorized={},spec_drivable={},rootNode=1,isServer=true,
     getIsAIActive=function(self) return self.ai==true end,
     getIsEntered=function()return false end}
   return {key=key or 'tractor1',name='Tractor',object=object,busy=false}
 end
 local function farm()
   return {farmId=1,settings={enabled=true},excluded={},active={},reservations={},
     implementReservations={},ownDriveSessions={},vehicles={},tasks={},now=10000}
 end
 test('41: own-driver remains leased after lifecycle reconciliation',function()
   local c=farm();local r=v();c.vehicles={r};c.ownDriveSessions[r.key]={id='fma:1',record=r,toolKey='drill'}
   c.reservations[r.key]='fma:1';c.implementReservations.drill='fma:1'
   local vv,tt=FMALifecycle.liveReservations(c);eq(vv[r.key],true);eq(tt.drill,true)
 end)
 test('41: authority refuses native AI, CP, player and pending active job',function()
   local c=farm();local r=v();c.vehicles={r}
   eq(FMAControlAuthority.canStart(c,r,'new'),true)
   r.object.ai=true;eq(FMAControlAuthority.canStart(c,r,'new'),false)
   r.object.ai=false;c.active.x={vehicle=r,task={id='old'}};eq(FMAControlAuthority.canStart(c,r,'new'),false)
   c.active={};c.ownDriveSessions[r.key]={id='own',record=r};eq(FMAControlAuthority.canStart(c,r,'new'),false)
   c.ownDriveSessions={};c.reservations[r.key]='other';eq(FMAControlAuthority.canStart(c,r,'new'),false)
   c.reservations={};c.settings.enabled=false;eq(FMAControlAuthority.canStart(c,r,'new'),false)
 end)
 test('41: authority audit finds overlapping physical control',function()
   local c=farm();local r=v();c.vehicles={r};c.ownDriveSessions[r.key]={id='own',record=r}
   c.active.job={vehicle=r,task={id='other'}}
   eq(FMAControlAuthority.audit(c),1);eq(c.controlAuthorityConflicts,1)
 end)
 test('41: finished job must not clear newer worker reservation',function()
   local c=FMAController.new();c.farmId=1;c.settings.enabled=false
   local r=v();local task={id='oldTask',kind='assemble',state='running',label='work'}
   local j={};c.active[j]={task=task,vehicle=r};c.reservations[r.key]='newTask'
   r.busy=true;c:handleJobStopped(j,nil);eq(c.reservations[r.key],'newTask');eq(r.busy,true)
 end)
 test('41: own-driver guard sees another managed AI as conflicting',function()
   local c=farm();local r=v();c.active.job={vehicle=r,task={id='one'}}
   c.ownDriveSessions[r.key]={id='two',record=r}
   local state=FMAControlAuthority.snapshot(c,r)
   eq(state.jobCount,1);eq(state.mode,'FMA_OWN');eq(FMAControlAuthority.canStart(c,r,'three'),false)
 end)
 test('41: native job launcher rejects simultaneous own-driver control',function()
   local c=farm();local r=v();r.key=FMAWorld.vehicleKey(r.object);c.vehicles={r}
   c.ownDriveSessions[r.key]={id='myDriver',record=r}
   eq(FMAControlAuthority.canLaunch(c,r.object,{}),false)
 end)
 test('41: native job launcher rejects two workers on a tractor',function()
   local c=farm();local r=v();r.key=FMAWorld.vehicleKey(r.object);c.vehicles={r}
   c.active.existing={vehicle=r,task={id='previous'}}
   eq(FMAControlAuthority.canLaunch(c,r.object,{}),false)
 end)
end
