return function(test,eq)
    test('27: list displays actual jobs first rather than controls',function()
        local tasks={}
        for i=1,6 do tasks[tostring(i)]={id=tostring(i),label='Pole '..i,priority=50-i,state='pending'} end
        local c={page=9,fmaTaskListMode=true,tasks=tasks,settings={}}
        local rows=FMAHud.rows(c)
        eq(#rows,6)
        eq(rows[1].object.slot,'simpleOpen')
        eq(rows[4].object.slot,'simpleOpen')
        eq(FMAJobBrief.summary(c).jobs,6)
    end)
    test('38: home ALL JOBS button lists tasks without starting machinery',function()
        local oldInput,oldGui=Input,g_gui
        Input={MOUSE_BUTTON_LEFT=1}
        g_gui={getIsGuiVisible=function()return false end,getIsDialogVisible=function()return false end}
        local t={id='task',kind='field',operation='plow',label='Orba',priority=60,state='pending'}
        local c={page=1,fmaCardHome=true,selection=1,visible=true,fmaMouseMode=true,
            supported=true,tasks={task=t},settings={enabled=false},notify=function()end}
        local d=FMAHud.cardGeometry()
        eq(FMAHud.mouseEvent(c,d.actionX+0.02,d.actionY+0.02,true,false,1),true)
        eq(c.page,9);eq(c.fmaCardHome,false);eq(c.fmaCardFilter,nil)
        eq(t.ownerApproved,nil);eq(c.settings.enabled,false)
        Input,g_gui=oldInput,oldGui
    end)
    test('38: card terminal is a centered grid and has no sidebar overlap',function()
        local d=FMAHud.cardGeometry()
        assert(d.w>0.65 and d.h>0.70 and d.x>0.10)
        assert(d.x+d.w<.96 and d.top<.92)
        for i=1,9 do
            local x,y,w,h=FMAHud.cardRect(d,i)
            assert(x>=d.x and x+w<=d.x+d.w)
            assert(y>d.y+.125 and y+h<d.top-.15)
        end
    end)
    test('27: description reports true physical evidence and no false success',function()
        local t={id='lime',kind='field',operation='lime',state='running',phase='PRÁCE',
            workEvidence={observedMove=222.8,consumed=0}}
        local c={vehicleByKey={}}
        local msg=FMAJobBrief.reason(c,t)
        assert(msg:find('222 m',1,true) and msg:find('0 l',1,true))
        t.state='done';t.resultVerified=nil
        assert(FMAJobBrief.reason(c,t):find('zkontroluj',1,true))
        t.ownerStopRequested=true
        assert(FMAJobBrief.reason(c,t):find('Zastaveno',1,true))
    end)
    test('27: blocked list uses audit reason before inventing equipment issue',function()
        local t={id='blocked',label='Pole 8',state='blocked'}
        local c={tasks={blocked=t},readinessAudit={blocked={state='BLOCKED',reason='Nedostupný přístup k nářadí'}}}
        local problems=FMAJobBrief.problems(c)
        eq(#problems,1);eq(problems[1].reason,'Nedostupný přístup k nářadí')
    end)
    test('27: stopped crew stays stopped even if last reason was navigation',function()
        local t={id='transport',state='paused',ownerApproved=false,ownerStopRequested=true,reason='Trasa nenalezena'}
        eq(FMAJobBrief.reason({},t),'Zastaveno majitelem · pro pokračování použij START')
    end)    test('27: map-defined sowable fruits appear without hard-coded names',function()
        local old=g_fruitTypeManager
        local source={
            WHEAT={name='WHEAT',allowsSeeding=true,title='Pšenice'},
            PEAS={name='PEAS',allowsSeeding=true,title='Hrách'},
            MODDED_CLOVER={name='MODDED_CLOVER',allowsSeeding=true,title='Jetel'},
            STATIC_ROCKS={name='STATIC_ROCKS',allowsSeeding=false,title='Kameny'},
        }
        g_fruitTypeManager={getFruitTypes=function()return source end,
            getFruitTypeByName=function(_,name)return source[name] end}
        local crops=FMACatalog.availableCrops()
        local present={}
        for _,n in ipairs(crops) do present[n]=true end
        eq(present.WHEAT,true);eq(present.PEAS,true)
        eq(present.MODDED_CLOVER,true);eq(present.STATIC_ROCKS,nil)
        eq(FMACatalog.cropLabels.MODDED_CLOVER,'Jetel')
        g_fruitTypeManager=old
    end)
    test('27: crop selector can choose a new map fruit',function()
        local old=g_fruitTypeManager
        local source={WHEAT={name='WHEAT',allowsSeeding=true},MODDED_CLOVER={name='MODDED_CLOVER',allowsSeeding=true}}
        g_fruitTypeManager={getFruitTypes=function()return source end,getFruitTypeByName=function(_,name)return source[name] end}
        local field={id=12,name='Pole 12',valid=true}
        local c={page=2,selection=1,policies={[12]={enabled=true,crop='WHEAT'}},fields={field},fieldsById={[12]=field},scan=function()end,settings={}}
        FMAHud.changeCrop(c)
        eq(c.policies[12].crop,'MODDED_CLOVER')
        g_fruitTypeManager=old
    end)
    test('27: mechanical job never invents material consumption',function()
        local t={id='plow',kind='field',operation='plow',state='running',phase='ORBA',workEvidence={observedMove=200,consumed=0}}
        local desc=FMAJobBrief.reason({},t)
        assert(desc:find('200 m',1,true) and not desc:find('spotřeba',1,true))
    end)

end
