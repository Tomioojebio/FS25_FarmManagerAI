return function(test,eq)
    test('runtime: failed CP transfer enters a cooldown instead of repeating endlessly',function()
        local oldAvailable=FMACourseplay.available
        local oldCreate=FMATransfer.createJob
        local oldAI=AIJobGoTo
        local tries=0
        FMACourseplay.available=function() return true end
        FMATransfer.createJob=function()tries=tries+1;return nil,'stav 4' end
        AIJobGoTo=nil
        local v={startCpWithStrategy=function()end,getCpSettings=function()return {} end}
        local c={now=1000,settings={navigationLearning=false}}
        local r={object=v,name='Trial tractor',key='trial'}
        FMAAI.createTransferJob(c,r,{x=60,z=72,preferCourseplay=true})
        eq(tries,1)
        c.now=1200
        FMAAI.createTransferJob(c,r,{x=61,z=70,preferCourseplay=true})
        eq(tries,1)
        c.now=122000
        FMAAI.createTransferJob(c,r,{x=60,z=72,preferCourseplay=true})
        eq(tries,2)
        FMACourseplay.available=oldAvailable
        FMATransfer.createJob=oldCreate
        AIJobGoTo=oldAI
    end)
    test('runtime: a seated AI worker without displacement is detected and stopped',function()
        local oldStop=FMAAI.stop
        local calls=0
        FMAAI.stop=function()calls=calls+1 end
        local vehicle={posX=0,posZ=0,getIsAIActive=function()return true end}
        local job={isRunning=true}
        vehicle.getJob=function()return job end
        local a={job=job,vehicle={object=vehicle,key='v',name='Stalled tractor'},
            task={id='refill:field:5:lime',kind='refill'},trafficTarget={x=75,z=40},start=1000}
        local c={active={[job]=a},now=1500}
        FMAJobs.verifyAuxiliaryStarts(c)
        eq(a.dispatchVerified,true)
        eq(a.physicalMotionVerified,nil)
        c.now=26000
        FMAJobs.verifyAuxiliaryStarts(c)
        eq(calls,1)
        assert(a.stopReason and a.stopReason:find('nerozjel',1,true))
        FMAAI.stop=oldStop
    end)
    test('runtime: actual displacement confirms a moving assistant',function()
        local job={isRunning=true}
        local v={posX=10,posZ=15,getIsAIActive=function()return true end,getJob=function()return job end}
        local a={job=job,vehicle={object=v,key='v',name='Moving tractor'},
            task={kind='refill',id='f'},trafficTarget={x=90,z=120},start=1000}
        local c={now=2000,active={[job]=a}}
        FMAJobs.verifyAuxiliaryStarts(c)
        eq(a.dispatchVerified,true)
        v.posX=16;v.posZ=17;c.now=27000
        FMAJobs.verifyAuxiliaryStarts(c)
        eq(a.physicalMotionVerified,true)
        eq(a.stopReason,nil)
    end)
    test('runtime: already at destination does not trigger a phantom stalled launch',function()
        local job={isRunning=true}
        local v={posX=30,posZ=30,getIsAIActive=function()return true end,getJob=function()return job end}
        local a={job=job,vehicle={object=v,key='v',name='Nearby'},task={kind='return',id='r'},trafficTarget={x=31,z=31},start=1000}
        local c={now=2000,active={[job]=a}}
        FMAJobs.verifyAuxiliaryStarts(c)
        c.now=28000;FMAJobs.verifyAuxiliaryStarts(c)
        eq(a.stopReason,nil)
    end)
    test('runtime: shortened panel avoids top notifications and bottom-right gauges',function()
        local c={settings={hudPosition=0}}
        FMAHud._controller=c
        local x,y,w,h=FMAHud.layout(false)
        assert(x+w<0.96 and y>0.24 and y+h<0.80)
        local d=FMAHud.panelGeometry(false)
        assert(d.navTop-5*d.navStep>d.y+0.12)
        assert(d.listTop-3*d.listStep-0.022>d.y+0.138)
        FMAHud._controller=nil
    end)
    test('runtime: mouse cursor is restored without closing Alt+M',function()
        local prevInput,prevGui=g_inputBinding,g_gui
        local visible=false;local restores=0
        g_inputBinding={getShowMouseCursor=function()return visible end,
            setShowMouseCursor=function(_,v)visible=v;restores=restores+1 end}
        g_gui={getIsGuiVisible=function()return false end,getIsDialogVisible=function()return false end}
        local c={visible=true,fmaMouseMode=true,now=2000}
        eq(FMAHud.maintainMouse(c),true)
        eq(visible,true);eq(restores,1)
        visible=false;c.now=2500;eq(FMAHud.maintainMouse(c),false)
        eq(restores,1)
        c.now=3100;eq(FMAHud.maintainMouse(c),true)
        eq(restores,2)
        c.visible=false;c.now=4500;eq(FMAHud.maintainMouse(c),false)
        g_inputBinding,g_gui=prevInput,prevGui
    end)

end
