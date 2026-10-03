return function(test,eq)
    test('32: one-file report contains diagnostic, live, operation log and recorder',function()
        local c={now=42000,settings={enabled=true},farmId=1,fields={},vehicles={},tasks={},history={}}
        FMABlackBox.event(c,'cp.start','TRACTOR','accepted')
        FMAOpsLog.lines={'Startup','Courseplay path rejected goalNodeInvalid=true'}
        local content,sections=FMASupportReport.compose(c,'diagnostic says BUNKER:65%')
        assert(content:find('diagnostic says BUNKER:65%%'))
        assert(content:find('FMA LIVE',1,true))
        assert(content:find('Courseplay path rejected',1,true))
        assert(content:find('cp.start',1,true))
        assert(content:find('GENUINE NEVER',1,true)==nil)
        eq(#sections,8)
        assert(content:find('01B_DEV_AUTOTEST.txt',1,true))
    end)
    test('32: rolling recorder preserves older segments in one current-session report',function()
        local c={now=1000,settings={},vehicles={},tasks={}}
        local original=FMAOpsLog.writePortable
        local writes={}
        FMAOpsLog.writePortable=function(name,data) writes[name]=data;return '/fake/'..name,true end
        local r=FMABlackBox.attach(c)
        for n=1,3 do
            r.rows={'time | TEST | generation '..n}
            for i=2,FMABlackBox.MAX_ROWS do r.rows[i]='sample '..i end
            r.dirty=true
            c.now=n*16000
            assert(FMABlackBox.flush(c,true)==true)
        end
        r.rows={'time | TEST | newest unflushed generation 4'}
        local segments=FMABlackBox.exportHistory(c)
        eq(#segments,4)
        for i=1,4 do assert(segments[i].content:find('generation '..i,1,true)) end
        local full=FMASupportReport.compose(c,'diagnostic')
        for i=1,4 do assert(full:find('generation '..i,1,true)) end
        FMAOpsLog.writePortable=original
    end)
    test('32: safe passive test flags blockage and leaves farm unaffected',function()
        local c={now=1234,settings={enabled=true},fields={{id=1}},vehicles={{name='JD'}},
            tasks={one={id='one',state='blocked',phase='ASSEMBLY',reason='Invalid goal',ownerApproved=true}},
            active={},bunkers={{}},subsystemFaults={}}
        local checked=FMATestSuite.run(c)
        assert((checked.BLOCK or 0)>=1)
        assert(c.settings.enabled==true and c.tasks.one.state=='blocked')
        local report=FMATestSuite.report(c)
        assert(report:find('Invalid goal',1,true))
    end)
    test('32: the issues page exposes single-report test without starting machines',function()
        local c={page=6,selection=1,supported=true,settings={enabled=false},tasks={},active={},
            fields={},vehicles={},issues={},purchaseNeeds={},now=100,diagnostics=function(self,quiet)
                self.diagnosticInvocations=(self.diagnosticInvocations or 0)+1
                assert(quiet==false)
            end}
        for i,row in ipairs(FMAHud.rows(c)) do if row.object and row.object.runPassiveTest then c.selection=i;break end end
        assert(FMAHud.rows(c)[c.selection].object.runPassiveTest)
        FMAHud.select(c)
        eq(c.diagnosticInvocations,1)
        eq(c.settings.enabled,false)
    end)
    test('32: keep flight recorder bounded at 12 slots after wraparound',function()
        local c={now=1000,settings={},vehicles={},tasks={}}
        local original=FMAOpsLog.writePortable
        FMAOpsLog.writePortable=function(name,data)return name,true end
        local r=FMABlackBox.attach(c)
        for n=1,FMABlackBox.SLOTS+4 do
            r.rows={'session event '..n}
            for i=2,FMABlackBox.MAX_ROWS do r.rows[i]='sample' end
            r.dirty=true;c.now=n*16000
            assert(FMABlackBox.flush(c,true)==true)
        end
        local items=FMABlackBox.exportHistory(c)
        eq(#items,FMABlackBox.SLOTS)
        assert(items[1].content:find('session event 5',1,true))
        assert(items[#items].content:find('session event 16',1,true))
        FMAOpsLog.writePortable=original
    end)
    test('32: export produces exactly one sendable report from in-memory information',function()
        local c={now=999,settings={enabled=false},vehicles={},tasks={}}
        local original=FMAOpsLog.writePortable
        local captured={}
        FMAOpsLog.writePortable=function(name,data) captured[#captured+1]={name=name,body=data};return '/Desktop/'..name,true end
        local result=FMASupportReport.export(c,'a diagnostic snapshot')
        assert(result.ok and result.path=='/Desktop/FS25_FarmManagerAI_REPORT.txt')
        eq(#captured,1)
        assert(captured[1].body:find('Flight recorder',1,true))
        FMAOpsLog.writePortable=original
    end)
    test('32: disk error fails safely and does not modify current game state',function()
        local c={now=1000,settings={enabled=true},vehicles={},tasks={}}
        local original=FMAOpsLog.writePortable
        FMAOpsLog.writePortable=function()return nil,false end
        local result=FMASupportReport.export(c,'test')
        eq(result.ok,false)
        eq(c.settings.enabled,true)
        FMAOpsLog.writePortable=original
    end)
    test('32: truncated diagnostic section has explicit marker without dropping newest events',function()
        local c={now=1000,settings={},vehicles={},tasks={}}
        local old=FMASupportReport.MAX_SECTION
        FMASupportReport.MAX_SECTION=120
        local output=FMASupportReport.compose(c,string.rep('OLD',100)..'LATEST_END')
        assert(output:find('LATEST_END',1,true))
        assert(output:find('older content truncated',1,true))
        FMASupportReport.MAX_SECTION=old
    end)
end
