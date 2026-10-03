return function(test,eq)
    test('37: Enter motor binding remains native, no Alt+P binding',function()
        local source=assert(io.open('scripts/main.lua','r')):read('*a')
        assert(not source:find('controller.visible and alt and Input.KEY_p',1,true))
        assert(not source:find('sym==Input.KEY_return',1,true))
        assert(not source:find('sym==Input.KEY_enter',1,true))
    end)
    test('45: verified aligned bunker entrance starts CP without impossible GoTo',function()
        local oldBunker,oldAvailable,oldStart,oldTransfer,oldDirection=BunkerSilo,FMACourseplay.available,FMACourseplay.startBunker,FMAAI.createTransferJob,localDirectionToWorld
        local count,transferCount=0,0
        BunkerSilo={STATE_FILL=1}
        localDirectionToWorld=function() return 1,0,0 end
        FMACourseplay.available=function() return true end
        FMACourseplay.startBunker=function() count=count+1;return {mockWorker=true} end
        FMAAI.createTransferJob=function() transferCount=transferCount+1;return nil,'test: should not be requested' end
        local silo={fillLevel=30000,compactedPercent=18,state=1,getCanCloseSilo=function()return false end}
        local b={key='mySilo',object=silo,x=30,z=0,fillLevel=30000,compactedPercent=18,state=1,
            geometry={front={x=14,z=0},width=12,length=32,dx=1,dz=0,frontOutside={x=0,z=0},backOutside={x=60,z=0}}}
        local vehicle={key='tractor',name='Test Tractor',x=2,z=0,busy=false,object={posX=2,posZ=0,rootNode=7,
            getCanStartCpBunkerSiloWorker=function()return true end},capabilities={compactSilo=true},machineClass='tractor',mass=10}
        local root={id='bunkerOrder:mySilo',ownerApproved=true,state='pending'}
        local c={settings={enabled=true,bunkerAutomation=true,selectedJobsOnly=true,maxWorkers=2,
                bunkerFillTarget=0.90,bunkerNominalHeight=4,trafficSafety=false},now=120000,active={},
                bunkers={b},vehicles={vehicle},excluded={},reservations={},jobFailures={},
                tasks={[root.id]=root},notify=function()end,issue=function()end}
        local ok=FMABunkerCoordinator.dispatch(c)
        eq(ok,true);eq(count,1);eq(transferCount,0);eq(root.state,'starting')
        assert(c.reservations.tractor and c.active)
        FMACourseplay.available,FMACourseplay.startBunker,FMAAI.createTransferJob,BunkerSilo,localDirectionToWorld=oldAvailable,oldStart,oldTransfer,oldBunker,oldDirection
    end)
end
