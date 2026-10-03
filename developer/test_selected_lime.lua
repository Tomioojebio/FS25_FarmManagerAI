return function(test,eq)
    test('manual lime supply follows the current attached fill unit after a tank switch',function()
        local lime=5555
        local original={fill=0,capacity=1000,ownerFarmId=1,
            getFillUnits=function() return {{supportedFillTypes={[lime]=true}}} end,
            getFillUnitFillLevel=function(self)return self.fill end,
            getFillUnitFillType=function()return lime end,
            getFillUnitCapacity=function(self)return self.capacity end}
        local switched={fill=0,capacity=500,ownerFarmId=1,
            getFillUnits=function()return {{supportedFillTypes={[lime]=true}}}end,
            getFillUnitFillType=function()return lime end,
            getFillUnitFillLevel=function(self)return self.fill end,
            getFillUnitCapacity=function(self)return self.capacity end}
        local root={getAttachedImplements=function()return {{object=original},{object=switched}}end}
        local record={key='crystal',name='CRYSTAL',object=root,busy=true}
        local req={object=original,fillUnitIndex=1,level=0,capacity=1000,fillType=lime}
        local ctrl={settings={enabled=true,refillBeforeWork=0.25,scanSeconds=12},refillSessions={},
            tasks={},reservations={crystal='manualRefill:t'},issues={['manualRefill:t']={}},now=2500,
            notify=function()end,vehicleByKey={crystal=record},diagnosticDirty=false}
        local task={id='t',kind='field',state='waiting',label='5 · Vápnění',manualRefillVehicleKey='crystal',manualRefillRequirement=req}
        ctrl.tasks.t=task
        ctrl.refillSessions.t={manual=true,requirement=req,vehicle=record,parent=task,started=0}
        switched.fill=320
        FMARefillManager.update(ctrl)
        eq(task.state,'pending');eq(ctrl.refillSessions.t,nil);eq(ctrl.reservations.crystal,nil)
        eq(task.manualRefillVehicleKey,nil);eq(task.failures,0)
    end)
    test('manual lime never accepts seed or fertilizer instead of LIME',function()
        local lime=5555;local other=222
        local unit={level=800,ownerFarmId=1,
            getFillUnits=function()return {{supportedFillTypes={[lime]=true,[other]=true}}}end,
            getFillUnitFillType=function()return other end,
            getFillUnitFillLevel=function(self)return self.level end,
            getFillUnitCapacity=function()return 1000 end}
        local record={object={getAttachedImplements=function()return {{object=unit}}end}}
        local req={object=unit,fillUnitIndex=1,level=0,capacity=1000,fillType=lime}
        local ok=FMARefillManager.manualMaterialReady({settings={refillBeforeWork=0.25}},record,req)
        eq(ok,false)
    end)
    test('manual loading while driving cancels only that refill job before field starts',function()
        local lime=5555
        local object={level=350,getFillUnitFillLevel=function(self)return self.level end,
            getFillUnitCapacity=function()return 1000 end}
        local r={name='CRYSTAL',key='v',object={},busy=true}
        local req={object=object,fillUnitIndex=1,fillType=lime,level=0,capacity=1000}
        local parent={id='field:5:lime',label='Pole 5 · Vápnění',state='assembling',manualRefillVehicleKey='v',manualRefillRequirement=req}
        local job={isRunning=true}
        local active={task={kind='refill',parentTaskId=parent.id},vehicle=r}
        local c={settings={enabled=true,refillBeforeWork=.25,scanSeconds=12},tasks={[parent.id]=parent},
            vehicleByKey={v=r},active={[job]=active},refillSessions={},reservations={v='refill'},issues={},now=1000,
            notify=function()end}
        local stopOld=FMAAI.stop;local stopped=0
        FMAAI.stop=function()stopped=stopped+1 end
        FMARefillManager.update(c)
        FMAAI.stop=stopOld
        eq(stopped,1);eq(active.stopReason,'MANUAL_MATERIAL_READY');eq(parent.state,'assembling')
        FMARefillManager.onStopped(c, {task={parentTaskId=parent.id,requirement=req,station={manual=true}},vehicle=r,stopReason='MANUAL_MATERIAL_READY'},nil)
        eq(parent.state,'pending');eq(parent.manualRefillRequirement,req)
        eq(parent.manualRefillVehicleKey,nil)
    end)
    test('selected-only dispatcher does not attempt unrelated pending orders',function()
        local c=FMAController.new()
        c.settings.enabled=true;c.settings.selectedJobsOnly=true;c.settings.reserve=0
        c.inventorySafe=true;c.now=1000;c.tasks={a={id='a',state='pending',priority=20},b={id='b',state='pending',priority=10}}
        c.reservations={};c.vehicles={};c.active={}
        local oldCan=FMAPlanner.canDispatch;local oldMay=FMAJobs.mayStart
        FMAPlanner.canDispatch=function()return true end
        local checked={};FMAJobs.mayStart=function(_,id)checked[#checked+1]=id;return false end
        FMAController.dispatch(c)
        eq(#checked,0)
        c.tasks.a.ownerApproved=true
        FMAController.dispatch(c)
        eq(#checked,1);eq(checked[1],'a')
        FMAPlanner.canDispatch=oldCan;FMAJobs.mayStart=oldMay
    end)
    test('job list marking is not an immediate global AUTO start',function()
        local t1={id='one',label='Orba',state='pending',priority=50}
        local t2={id='two',label='Sklizeň',state='pending',priority=40}
        local c={page=9,fmaTaskListMode=true,selection=1,tasks={one=t1,two=t2},supported=true,
            settings={enabled=false,selectedJobsOnly=true},notify=function()end}
        FMAHud.select(c) -- open order, without starting or toggling it
        eq(c.fmaTaskListMode,false)
        eq(t1.ownerMarked,nil)
        c.selection=3;FMAHud.select(c) -- add to batch
        eq(t1.ownerMarked,true);eq(t1.ownerApproved,nil);eq(t2.ownerMarked,nil)
        c.fmaTaskListMode=true
        eq(c.settings.enabled,false)
        c.enableAutomation=function(self)self.settings.enabled=true;return true end
        c.scan=function()end;c.dispatch=function(self)self.started=true end
        c.selection=1;FMAHud.cycleJobSlot(c,{object={slot='launchMarked'}})
        eq(t1.ownerApproved,true);eq(t2.ownerApproved,nil);eq(c.started,true)
    end)
end
