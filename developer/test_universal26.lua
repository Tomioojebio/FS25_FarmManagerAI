return function(test,eq)
local saved=FillType
FillType={LIME=17,FERTILIZER=18,LIQUIDFERTILIZER=19,SLURRY=20,LIQUIDMANURE=21,
         MANURE=22,DIGESTATE=23,SEEDS=24,HERBICIDE=25,DIESEL=9}
local function makeMachine(typeId,spec)
    local level={value=1000}
    local tool={spec_fillUnit={fillUnits={{capacity=1200,supportedFillTypes={[typeId]=true}}}}}
    if spec then tool[spec]=true end
    tool.getFillUnits=function(self) return self.spec_fillUnit.fillUnits end
    tool.getFillUnitFillType=function()return typeId end
    tool.getFillUnitFillLevel=function()return level.value end
    tool.getFillUnitCapacity=function()return 1200 end
    local tractor={posX=0,posZ=0,ownerFarmId=1,getAttachedImplements=function()return {{object=tool}} end}
    return {key='generic',object=tractor},level,tool
end
for _,part in ipairs({
   {op='lime',type=17,spec='spec_sprayer'},
   {op='fertilize',type=18,spec='spec_sprayer'},
   {op='fertilize',type=19,spec='spec_sprayer'},
   {op='fertilize',type=20,spec='spec_sprayer'},
   {op='fertilize',type=22,spec='spec_sprayer'},
   {op='fertilize',type=23,spec='spec_sprayer'},
   {op='sow',type=24,spec='spec_sowingMachine'},
   {op='weed',type=25,spec='spec_sprayer'}
}) do
    test('26: all fill-driven categories verify real consumption '..part.op..':'..part.type,function()
        local record,level=makeMachine(part.type,part.spec)
        local task={kind='field',operation=part.op,fieldworkStartedAt=100}
        FMAWorkEvidence.begin({now=100},task,record)
        eq(FMAWorkEvidence.verify(task,record),false)
        record.object.posX=12;level.value=720
        FMAWorkEvidence.sample({now=250},task,record)
        eq(FMAWorkEvidence.verify(task,record),true)
    end)
end

test('26: generic plow cannot count unchanged physical position as work',function()
    local r=makeMachine(9)
    local t={kind='field',operation='plow',fieldworkStartedAt=100}
    FMAWorkEvidence.begin({now=100},t,r)
    eq(FMAWorkEvidence.verify(t,r),false)
    r.object.posZ=17;FMAWorkEvidence.sample({now=200},t,r)
    eq(FMAWorkEvidence.verify(t,r),true)
end)
test('26: mechanical weeders need movement but no fictional herbicide',function()
    local r=makeMachine(9)
    local t={kind='field',operation='weed',fieldworkStartedAt=100}
    FMAWorkEvidence.begin({now=100},t,r)
    eq(t.workEvidence.mode,'mechanical')
    r.object.posX=21;FMAWorkEvidence.sample({now=200},t,r)
    eq(FMAWorkEvidence.verify(t,r),true)
end)
test('26: herbicide sprayer with full tank is not a completed weed treatment',function()
    local r=makeMachine(25,'spec_sprayer')
    local t={kind='field',operation='weed',fieldworkStartedAt=100}
    FMAWorkEvidence.begin({now=100},t,r)
    r.object.posZ=20;FMAWorkEvidence.sample({now=200},t,r)
    eq(t.workEvidence.mode,'consumable');eq(FMAWorkEvidence.verify(t,r),false)
end)
test('26: wrong fluid/fuel is never proof of applying seed',function()
    local r=makeMachine(9)
    local t={kind='field',operation='sow',fieldworkStartedAt=100}
    FMAWorkEvidence.begin({now=100},t,r)
    r.object.posZ=12;FMAWorkEvidence.sample({now=200},t,r)
    eq(FMAWorkEvidence.verify(t,r),false)
end)
test('26: topping up during fieldwork then actually applying material is tracked',function()
    local r,level=makeMachine(17,'spec_sprayer')
    local t={kind='field',operation='lime',fieldworkStartedAt=100}
    FMAWorkEvidence.begin({now=100},t,r)
    level.value=600;r.object.posZ=12;FMAWorkEvidence.sample({now=200},t,r)
    level.value=1150;FMAWorkEvidence.sample({now=300},t,r)
    level.value=900;r.object.posZ=24;FMAWorkEvidence.sample({now=400},t,r)
    eq(FMAWorkEvidence.verify(t,r),true)
    assert(t.workEvidence.consumed>=650)
end)
test('26: disappearing tool must not be interpreted as material consumption',function()
    local r,level=makeMachine(17,'spec_sprayer')
    local t={kind='field',operation='lime',fieldworkStartedAt=100}
    FMAWorkEvidence.begin({now=100},t,r)
    r.object.getAttachedImplements=function()return {} end
    r.object.posZ=20;FMAWorkEvidence.sample({now=200},t,r)
    eq(t.workEvidence.consumed,0)
    eq(FMAWorkEvidence.verify(t,r),false)
end)
test('26: replacing an attached full implement with an empty one is not application',function()
    local r,level=makeMachine(17,'spec_sprayer')
    local t={kind='field',operation='lime',fieldworkStartedAt=100}
    FMAWorkEvidence.begin({now=100},t,r)
    local other,otherLevel,otherTool=makeMachine(17,'spec_sprayer')
    otherLevel.value=0
    r.object.getAttachedImplements=function()return {{object=otherTool}} end
    r.object.posZ=20;FMAWorkEvidence.sample({now=200},t,r)
    eq(t.workEvidence.consumed,0)
    eq(FMAWorkEvidence.verify(t,r),false)
end)
test('26: general fieldwork does not pass completion with only changed field metadata',function()
    local c=FMAController.new()
    local task={kind='field',operation='sow',fieldId='6',fieldworkStartedAt=100}
    c.fieldsById={['6']={valid=true,mixed=false,alive=true,fingerprint='after'}}
    eq(c:verifyFieldOrderComplete(task),false)
end)
test('26: wide sowers and mowers get turning-room headlands too',function()
    local orig=AIUtil;AIUtil=nil
    local function cell(v)
        return {getValue=function()return v end,setValue=function(self,x)self.value=x end,setFloatValue=function(self,x)self.value=x end}
    end
    for _,operation in ipairs({'sow','mow','plow','fertilize','roll','cultivate','weed'}) do
        local head=cell(1)
        local spec={workWidth=cell(8),turningRadius=cell(11),numberOfHeadlands=head}
        local vehicle={getCourseGeneratorSettings=function()return spec end}
        local ok,_,info=FMAFieldQuality.configure(vehicle,{operation=operation},{settings={minHeadlands=2,maxHeadlands=6}})
        assert(ok and head.value>=3,operation)
        assert(info.headlandFirst==true)
    end
    AIUtil=orig
end)
test('26: refill requirements include compatible herbicide for spray weeding',function()
    local ft=FMARefillManager.desiredFillTypes({operation='weed'})
    eq(ft[1],25)
end)
test('26: STOP targets nested dispatch/haulage/delivery/return but never other teams',function()
    local root={id='field:12:harvest',label='Sklizeň 12',crewId='harvest:12:combine',state='running'}
    local support={id='support:12',kind='support',parentTaskId=root.id}
    local deliver={id='deliver:12',kind='supportDelivery',parentTaskId=support.id}
    local home={id='return:12',kind='return',parentTask=deliver}
    local other={id='field:14:harvest',kind='field',state='running'}
    local c={tasks={[root.id]=root,[support.id]=support,[deliver.id]=deliver},active={},
        externalFieldwork={},settings={selectedJobsOnly=true},preparedSupport={},reservations={},
        notify=function()end}
    local stopped={};local original=FMAAI.stop
    FMAAI.stop=function(job)stopped[job]=true end
    local j1,j2,j3,j4={},{},{},{}
    c.active[j1]={task=root};c.active[j2]={task=deliver};c.active[j3]={task=home};c.active[j4]={task=other}
    FMAHud.stopTask(c,root)
    FMAAI.stop=original
    assert(stopped[j1] and stopped[j2] and stopped[j3] and not stopped[j4])
    eq(other.state,'running');eq(root.state,'paused')
end)
test('26: physical work policy requires movement for all listed categories',function()
    for _,operation in ipairs({'harvest','mow','roll','stone','sow','plow','cultivate',
         'fertilize','lime','weed','ted','windrow','bale','foragePickup'}) do
        local record=makeMachine(9)
        local task={kind='field',operation=operation,fieldworkStartedAt=1}
        FMAWorkEvidence.begin({now=1},task,record)
        eq(FMAWorkEvidence.verify(task,record),false)
    end
end)
FillType=saved
end
