return function(test,eq)
    local function rig()
        local WHEAT=1111
        local trailer={spec_trailer={},spec_dischargeable={dischargeNodes={{fillUnitIndex=1}}},capacity=12000,level=8000,
            getFillUnits=function()return {{capacity=12000}}end,
            getFillUnitFillType=function()return WHEAT end,
            getFillUnitFillLevel=function(self)return self.level end,
            getFillUnitCapacity=function(self)return self.capacity end}
        local root={ownerFarmId=1,posX=10,posZ=10,
            getIsAIActive=function()return false end,
            getAttachedImplements=function()return {{object=trailer}} end}
        local record={key='t1',name='6R 250',object=root,x=10,z=10,capabilities={transport=true}}
        local parent={id='field:32:harvest',kind='field',operation='harvest',fieldId=32,state='running',ownerApproved=true,fieldworkStartedAt=50}
        local c={now=1000,farmId=1,settings={enabled=true,selectedJobsOnly=true,autoSellOutputs=false},
            tasks={[parent.id]=parent},reservations={},active={},haulageCycles={},excluded={},fieldsById={},
            issues={},diagnosticDirty=false,notify=function()end,issue=function()end,vehicleByKey={t1=record}}
        local active={task={kind='support',parentGroup='harvest:32:combine',parentTaskId=parent.id,fieldId=32,fillType=WHEAT},vehicle=record}
        return c,parent,record,trailer,active
    end
    test('haulage reads only physical trailer grain, not tractor fuel',function()
        local c,parent,record,trailer=rig()
        record.object.getFillUnits=function()return {{capacity=100,level=50}} end
        record.object.getFillUnitFillType=function()return FillType and FillType.DIESEL or 1 end
        record.object.getFillUnitFillLevel=function()return 50 end
        local level,capacity,ft=FMAHaulageCycle.cargo(record,1111)
        eq(level,8000);eq(capacity,12000);eq(ft,1111)
    end)
    test('stopped CP unloader with cargo reserves cycle and is not marked done',function()
        local c,parent,record,trailer,a=rig()
        eq(FMAFleetCoordinator.onSupportStopped(c,a),true)
        eq(c.haulageCycles.t1.state,'NEED_DELIVERY')
        eq(record.busy,true)
        eq(c.reservations.t1,'haulageCycle:t1')
        eq(parent.state,'running')
    end)
    test('successful AI callback without cargo drop is not an unload success',function()
        local c,parent,record,trailer,a=rig()
        FMAHaulageCycle.queue(c,a)
        local session=c.haulageCycles.t1;session.state='DELIVERING'
        eq(FMAHaulageCycle.onDeliveryStopped(c,{vehicle=record,haulageSession=session,outcome='success'}),true)
        eq(session.state,'NEED_DELIVERY');eq(session.attempts,1)
        eq(c.reservations.t1,'haulageCycle:t1')
    end)
    test('observed drop below five percent allows return but not false harvest completion',function()
        local c,parent,record,trailer,a=rig()
        FMAHaulageCycle.queue(c,a)
        local session=c.haulageCycles.t1
        trailer.level=100
        FMAHaulageCycle.onDeliveryStopped(c,{vehicle=record,haulageSession=session,outcome='success'})
        eq(session.state,'RETURN_FIELD');eq(parent.state,'running')
    end)
    test('no sale station cannot launch unverified delivery',function()
        local c,parent,record,trailer,a=rig()
        FMAHaulageCycle.queue(c,a);c.now=10000
        local old=FMALogistics.destinationOptions
        FMALogistics.destinationOptions=function()return {} end
        FMAHaulageCycle.update(c)
        local s=c.haulageCycles.t1
        assert(s and s.state~='DELIVERING')
        eq(c.reservations.t1,'haulageCycle:t1')
        FMALogistics.destinationOptions=old
    end)
    test('CP unloader cannot start before confirmed combine work',function()
        local c,parent,record,trailer,a=rig()
        local combine={object={getIsCpFieldWorkActive=function()return false end,getIsAIActive=function()return false end}}
        eq(FMAHaulageCycle.harvesterWorking({harvester=combine,parentTask=parent}),false)
        combine.object.getIsCpFieldWorkActive=function()return true end
        eq(FMAHaulageCycle.harvesterWorking({harvester=combine,parentTask=parent}),true)
        parent.ownerApproved=false
        eq(FMAHaulageCycle.harvesterWorking({harvester=combine,parentTask=parent}),true)
    end)
    test('CP near-field check uses polygon edge, not middle of field',function()
        local c,parent,record,trailer,a=rig()
        local poly={ {x=0,z=0},{x=100,z=0},{x=100,z=100},{x=0,z=100} }
        c.fieldsById[32]={object={polygonPoints={1,2,3,4}}}
        local old=getWorldTranslation
        getWorldTranslation=function(node) return poly[node].x,0,poly[node].z end
        local group={fieldId=32,harvester={object={posX=50,posZ=50}}}
        record.object.posX=110;record.object.posZ=40
        eq(FMAHaulageCycle.nearField(c,group,record),true)
        record.object.posX=50;record.object.posZ=50
        eq(FMAHaulageCycle.nearField(c,group,record),false)
        getWorldTranslation=old
    end)
end
