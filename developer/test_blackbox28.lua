return function(test,eq)
    test('28: recorder diagnoses invalid route goal and explains correction',function()
        local kind,fix=FMABlackBox.cause('Pathfinder goalNodeInvalid=true')
        eq(kind,'NAV_GOAL');assert(fix:find('AI bodu',1,true))
    end)
    test('28: recorder identifies missing Courseplay unloader',function()
        eq(FMABlackBox.cause('findUnloader: no idle unloader found'),'CREW_UNLOADER')
    end)
    test('28: recorder distinguishes attachment, material, return and absent cause',function()
        eq(FMABlackBox.cause('FS25 chyba zapřažení nářadí'),'ASSEMBLY')
        eq(FMABlackBox.cause('Není žádný materiál'),'REFILL')
        eq(FMABlackBox.cause('Návrat na farmu selhal'),'RETURN')
        eq(FMABlackBox.cause(''),nil)
    end)
    test('28: recorder detects task transitions and approval',function()
        local c={now=1000,settings={enabled=false},tasks={test={id='test',operation='harvest',state='pending',phase='PLAN',ownerApproved=false}},vehicles={}}
        FMABlackBox.sample(c)
        local n=#c.blackBox.rows
        c.now=3000;c.tasks.test.ownerApproved=true;c.tasks.test.state='running';c.tasks.test.phase='WORK'
        FMABlackBox.sample(c)
        assert(#c.blackBox.rows>n, 'old='..n..' now='..#c.blackBox.rows)
        local text=table.concat(c.blackBox.rows,'\n')
        assert(text:find('approved=true',1,true) and text:find('ORDER',1,true),'rows='..text)
    end)
    test('28: recorder detects stationary accepted AI and traces route',function()
        local obj={posX=30,posZ=40,getIsAIActive=function()return true end}
        local c={now=2000,settings={},vehicles={{key='tractor',name='Test tractor',object=obj}}}
        FMABlackBox.sample(c)
        c.now=40000;FMABlackBox.sample(c)
        assert(table.concat(c.blackBox.rows,'\n'):find('AI_ACTIVE_BUT_STATIONARY',1,true))
        obj.posX=130;c.now=42000;FMABlackBox.sample(c)
        assert(c.blackBox.vehicles.tractor.x==130,"x="..tostring(c.blackBox.vehicles.tractor.x))
    end)
    test('28: recorder distinguishes real Courseplay status without claiming automatic movement',function()
        local c={now=5000,settings={enabled=true},vehicles={{key='one',name='One',object={posX=20,posZ=60,
            getIsAIActive=function()return false end,getIsCpFieldWorkActive=function()return true end}}}}
        FMABlackBox.sample(c)
        assert(table.concat(c.blackBox.rows,'\n'):find('cp=true',1,true))
    end)
    test('28: recorder captures reservation and crew stages only when changed',function()
        local c={now=1000,settings={},vehicles={},tasks={},
            preparedSupport={harvest={[1]={state='STAGING',phase='FIELD_APPROACH',record={key='hauler1',name='Hauler 1'}}}}}
        FMABlackBox.sample(c)
        local n=#c.blackBox.rows
        c.now=2000;FMABlackBox.sample(c);eq(#c.blackBox.rows,n)
        c.preparedSupport.harvest[1].state='UNLOADING';c.now=3000;FMABlackBox.sample(c)
        assert(#c.blackBox.rows>n)
    end)
    test('28: recorder has no file IO before explicit flush and uses bounded rewrite',function()
        local old=FMAOpsLog.writePortable
        local files={};FMAOpsLog.writePortable=function(name,data) files[#files+1]={name=name,data=data};return '/desktop/'..name,true end
        local c={now=15000,settings={},tasks={},vehicles={}}
        FMABlackBox.sample(c)
        assert(#files==1 and files[1].name=='FS25_FarmManagerAI_TRACE_01.txt')
        assert(files[1].data:find('FLIGHT RECORDER',1,true))
        c.now=16000;FMABlackBox.sample(c);eq(#files,1)
        FMAOpsLog.writePortable=old
    end)
    test('28: recorder rotation wraps and never expands number of files',function()
        local old=FMAOpsLog.writePortable
        local files={};FMAOpsLog.writePortable=function(name,data) files[name]=data;return name,true end
        local c={now=15000,settings={},vehicles={}}
        for i=1,FMABlackBox.SLOTS+2 do
            local r=FMABlackBox.attach(c);r.rows={}
            for j=1,FMABlackBox.MAX_ROWS do r.rows[#r.rows+1]='test | '..j end
            r.dirty=true;c.now=c.now+16000;FMABlackBox.flush(c,true)
        end
        local n=0;for name in pairs(files) do
            n=n+1;assert(name:match('^FS25_FarmManagerAI_TRACE_%d%d%.txt$'))
        end
        eq(n,FMABlackBox.SLOTS)
        FMAOpsLog.writePortable=old
    end)
    test('28: recorder failed disk write remains safe and diagnostic',function()
        local old=FMAOpsLog.writePortable
        FMAOpsLog.writePortable=function()return nil,false end
        local c={now=30000,settings={},vehicles={}}
        FMABlackBox.event(c,'ai','test','failed')
        assert(FMABlackBox.flush(c,true)==false)
        assert(c.blackBox.lastWriteError and c.blackBox.dirty)
        FMAOpsLog.writePortable=old
    end)
    test('28: recorder never mistakes a missing field position for successful navigation',function()
        local c={now=3000,settings={},vehicles={{key='test',name='No location',object={}}}}
        FMABlackBox.sample(c)
        c.now=45000;FMABlackBox.sample(c)
        local r=c.blackBox
        assert(r.vehicles.test.x==nil and r.vehicles.test.z==nil)
    end)
    test('28: existing diagnostics journal connects to flight recorder',function()
        local c={now=5000}
        FMADiagnostics.event(c,'cp.start','tractor','accepted but not moving')
        assert(table.concat(c.blackBox.rows,'\n'):find('cp.start',1,true))
    end)
end
