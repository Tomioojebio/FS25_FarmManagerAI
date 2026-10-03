return function(test,eq)
    local function bunker()
        return {geometry={front={x=26,z=-535},dx=1,dz=0,length=44,width=12,
            frontOutside={x=12,z=-535},backOutside={x=84,z=-535}}}
    end
    test('45: CP starts only from accurately aligned real bunker mouth',function()
        local saved=localDirectionToWorld
        localDirectionToWorld=function()return 1,0,0 end
        local vehicle={rootNode=4,posX=14,posZ=-535}
        local ok,reason=FMABunkerCoordinator.safeWorkerStart(bunker(),vehicle,true)
        eq(ok,true)
        vehicle.posX=20
        ok,reason=FMABunkerCoordinator.safeWorkerStart(bunker(),vehicle,true)
        eq(ok,false)
        assert(reason:find('Neověřený příjezd'))
        vehicle.posX=14
        localDirectionToWorld=function()return -1,0,0 end
        ok,reason=FMABunkerCoordinator.safeWorkerStart(bunker(),vehicle,true)
        eq(ok,false)
        assert(reason:find('natočen'))
        localDirectionToWorld=saved
    end)
    test('45: Xerion stopped BEFORE predicted CP overshoot (20261003 trace)',function()
        local oldPosition=FMAUtil.position;local oldStop=FMAAI.stop;local oldEvent=FMADiagnostics.event
        local stopped=0
        local ok,err=pcall(function()
            FMAUtil.position=function(v) return v.posX,v.posZ end
            FMAAI.stop=function() stopped=stopped+1 end
            FMADiagnostics.event=function()end
            local vehicle={posX=83.4,posZ=-535}
            local task={kind='bunker',bunkerIndex=1}
            local active={vehicle={object=vehicle,name='XERION'},task=task,
                bunkerSafetySample={time=1000,x=82,z=-535}}
            local c={now=1200,active={[{}]=active},bunkers={bunker()}}
            local presentlySafe=FMABunkerCoordinator.withinWorkEnvelope(c.bunkers[1],83.4,-535)
            eq(presentlySafe,true)
            FMABunkerCoordinator.enforceSafety(c)
            eq(stopped,1)
            assert(task.safetyStopIssued and active.stopReason:find('předvídaný'))
        end)
        FMAUtil.position=oldPosition;FMAAI.stop=oldStop;FMADiagnostics.event=oldEvent
        assert(ok,err)
    end)
    test('45: collision probe blocks own driver before striking an unknown rigid body',function()
        local oldRay,oldWorld,oldDir,oldMission=raycastClosest,getWorldTranslation,localDirectionToWorld,g_currentMission
        local ok,err=pcall(function()
            getWorldTranslation=function()return 0,0,0 end
            localDirectionToWorld=function()return 0,0,1 end
            g_currentMission=nil
            local calls=0
            raycastClosest=function(x,y,z,dx,dy,dz,range,callback,target)
                calls=calls+1
                if calls==2 then target[callback](target,121212) end
                return 1
            end
            local clear,why=FMAOwnDriver.collisionCorridor({rootNode=1,size={width=3,length=5}}, {x=0,z=8})
            eq(clear,false)
            assert(calls==2 and why:find('překážku'))
        end)
        raycastClosest,getWorldTranslation,localDirectionToWorld,g_currentMission=oldRay,oldWorld,oldDir,oldMission
        assert(ok,err)
    end)
    test('45: farm survey recovers BOTH X and Z from Carpathian-owned buildings',function()
        local atlas={husbandries={{object={posX=81,posZ=-655}},
              {object={posX=12,posZ=-544}}},
              storages={{object={posX=108,posZ=-470}},{object={posX=106,posZ=-438}}}}
        local center=FMAFarmSurvey.findCenter({worldAtlas=atlas,vehicles={}})
        assert(center and type(center.x)=='number' and type(center.z)=='number')
        assert(center.z < -400 and center.z > -680)
    end)
    test('45: Courseplay preparation rejection retains actual failure reason',function()
        local oldPrepare=FMAFieldQuality.prepareCourseplayVehicle
        FMAFieldQuality.prepareCourseplayVehicle=function()return false,'TEST: příprava CP soupravy odmítnuta' end
        local vehicle={hasCpCourse=function()return true end}
        local job,why=FMACourseplay.startFieldwork({}, {object=vehicle}, {kind='field',operation='harvest'})
        FMAFieldQuality.prepareCourseplayVehicle=oldPrepare
        eq(job,nil)
        eq(why,'TEST: příprava CP soupravy odmítnuta')
    end)
    test('45: Lua multi-return diagnostics retain X/Z and failure reason',function()
        local function code(name)
            local file=assert(io.open('scripts/'..name..'.lua','r'))
            local content=file:read('*a');file:close()
            return content
        end
        assert(not code('FMABunkerCoordinator'):find('a.vehicle and FMAUtil.position',1,true))
        assert(not code('FMAFarmSurvey'):find('obj and FMAUtil.position',1,true))
        assert(not code('FMACourseplay'):find('local prepOk,prepWhy=FMAFieldQuality and',1,true))
        assert(not code('FMARecovery'):find('local started,why=FMANavigation and',1,true))
        assert(not code('FMAOwnDriver'):find('local inside,details=FMABunkerCoordinator and',1,true))
    end)
    test('45: missing physics query cannot become fictional safe clearance',function()
        local old=raycastClosest
        raycastClosest=nil
        local ok=FMAOwnDriver.collisionCorridor({rootNode=1},{x=0,z=4})
        raycastClosest=old
        eq(ok,false)
    end)
end
