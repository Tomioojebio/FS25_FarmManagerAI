-- Courseplay-backed point-to-point transfer job used for yard logistics.
-- This file deliberately resolves Courseplay classes from Courseplay's own mod
-- environment. FS25 isolates globals per mod, so direct references such as
-- CpAIJob/PathfinderContext are nil from another mod even when Courseplay is loaded.
FMATransfer = {}

local JOB_NAME = "FMA_TRANSFER_CP"
local cpApiCache=nil

local function currentAngle(vehicle)
    if vehicle and vehicle.rootNode and localDirectionToWorld and MathUtil and MathUtil.getYRotationFromDirection then
        local ok,dx,_,dz=pcall(localDirectionToWorld,vehicle.rootNode,0,0,1)
        if ok and dx and dz then return MathUtil.getYRotationFromDirection(dx,dz) end
    end
    return 0
end

local function globalEnvironment()
    if type(getfenv)=="function" then
        local ok,env=pcall(getfenv,0)
        if ok and type(env)=="table" then return env end
    end
    return _G
end

local function tableIndexEnvironment(env)
    if type(env)~="table" or type(getmetatable)~="function" then return nil end
    local ok,mt=pcall(getmetatable,env)
    if not ok or type(mt)~="table" then return nil end
    return type(mt.__index)=="table" and mt.__index or nil
end

local function courseplayEnvironment()
    local modName=(g_modManager and g_modManager.CP_MOD_NAME) or "FS25_Courseplay"
    local env=globalEnvironment()
    local shared=tableIndexEnvironment(env) or tableIndexEnvironment(_G)
    local candidates={env,_G,shared}
    for _,candidate in ipairs(candidates) do
        local cpEnv=type(candidate)=="table" and candidate[modName] or nil
        if type(cpEnv)=="table" then return cpEnv,nil end
    end
    -- Some GIANTS builds expose a loaded mod record with its custom Lua environment.
    -- Probe only table-valued fields and never depend on a private field being present.
    local mod=nil
    if g_modManager and type(g_modManager.getModByName)=="function" then
        local ok,value=pcall(g_modManager.getModByName,g_modManager,modName)
        if ok then mod=value end
    end
    if type(mod)=="table" then
        for _,key in ipairs({"env","environment","customEnvironment","modEnvironment","globals"}) do
            local cpEnv=mod[key]
            if type(cpEnv)=="table" then return cpEnv,nil end
        end
    end
    return nil,"Courseplay mod environment není dostupný ("..tostring(modName)..")"
end

local function resolveCpApi(force)
    if cpApiCache and not force then return cpApiCache,nil end
    local env,why=courseplayEnvironment();if not env then return nil,why end
    local names={
        "CpObject","CpAIJob","CpAITask","AIDriveStrategyCourse","PathfinderContext","PathfinderController",
        "State3D","CpMathUtil","MotorController","WearableController","FoldableController",
        "AIMessageCpErrorNoPathFound"
    }
    local api={env=env}
    local missing={}
    for _,name in ipairs(names) do
        api[name]=env[name]
        if api[name]==nil and name~="MotorController" and name~="WearableController" and name~="FoldableController" and name~="AIMessageCpErrorNoPathFound" then
            missing[#missing+1]=name
        end
    end
    if #missing>0 then return nil,"Courseplay API chybí: "..table.concat(missing,",") end
    cpApiCache=api
    return api,nil
end

local function cpRuntimeReady(vehicle)
    local api,why=resolveCpApi(false)
    if not api then return false,why end
    if not vehicle then return false,"Chybí vozidlo" end
    if type(vehicle.startCpWithStrategy)~="function" then return false,"Stroj nemá startCpWithStrategy" end
    if type(vehicle.getCpSettings)~="function" then return false,"Stroj nemá Courseplay nastavení" end
    if type(vehicle.getCourseGeneratorSettings)~="function" then return false,"Stroj nemá Courseplay generator nastavení" end
    return true,nil,api
end

local function makeCpError(api)
    local cls=api and api.AIMessageCpErrorNoPathFound
    if cls and type(cls.new)=="function" then
        local ok,msg=pcall(cls.new)
        if ok and msg then return msg end
    end
    return AIMessageErrorUnknown and AIMessageErrorUnknown.new and AIMessageErrorUnknown.new() or nil
end

local function ensureClasses()
    if FMAAIJobTransfer~=nil and FMAAITaskTransfer~=nil and FMAAIDriveStrategyTransfer~=nil then return true end
    local api,why=resolveCpApi(true);if not api then return false,why end
    local CpObject=api.CpObject
    local CpAIJob=api.CpAIJob
    local CpAITask=api.CpAITask
    local AIDriveStrategyCourse=api.AIDriveStrategyCourse
    local PathfinderContext=api.PathfinderContext
    local State3D=api.State3D
    local CpMathUtil=api.CpMathUtil
    local MotorController=api.MotorController
    local WearableController=api.WearableController
    local FoldableController=api.FoldableController

    FMAAIJobTransfer = CpObject(CpAIJob)
    FMAAIJobTransfer.name = JOB_NAME
    FMAAIJobTransfer.jobName = "FMA transfer"

    function FMAAIJobTransfer:init(isServer)
        CpAIJob.init(self,isServer)
        self.fmaTarget=nil
        self.fmaTolerance=4
        self.fmaProbeRadius=nil
        self.fmaDirectApproach=false
        self.fmaRecoveryReverse=false
        self.isDirectStart=true
    end

    function FMAAIJobTransfer:setupJobParameters()
        CpAIJob.setupJobParameters(self)
    end

    function FMAAIJobTransfer:setupTasks(isServer)
        -- Task 1 is the normal GIANTS drive-to placeholder expected by CpAIJob.
        -- Direct start skips it and starts our Courseplay transfer task at index 2.
        CpAIJob.setupTasks(self,isServer)
        self.transferTask=FMAAITaskTransfer(isServer,self)
        self:addTask(self.transferTask)
    end

    function FMAAIJobTransfer:applyCurrentState(vehicle,mission,farmId,isDirectStart)
        CpAIJob.applyCurrentState(self,vehicle,mission,farmId,true)
        self.isDirectStart=true
    end

    function FMAAIJobTransfer:setTarget(x,z,angle,tolerance,probeRadius,directApproach,recoveryReverse)
        self.fmaTarget={x=x,z=z,angle=angle}
        self.fmaTolerance=math.max(0.8,tonumber(tolerance) or 4)
        self.fmaProbeRadius=tonumber(probeRadius)
        self.fmaDirectApproach=directApproach==true
        self.fmaRecoveryReverse=recoveryReverse==true
    end

    local function jobVehicle(job)
        if not job then return nil end
        local v=nil
        if job.vehicleParameter and type(job.vehicleParameter.getVehicle)=="function" then
            local ok,value=pcall(job.vehicleParameter.getVehicle,job.vehicleParameter)
            if ok then v=value end
        end
        return v or job.vehicle
    end

    function FMAAIJobTransfer:setValues()
        self:resetTasks()
        local vehicle=jobVehicle(self)
        if self.transferTask and vehicle then self.transferTask:setVehicle(vehicle) end
    end

    -- Courseplay/GIANTS can reconstruct a registered job before the direct-start task
    -- actually begins. Re-bind the physical vehicle immediately before execution so
    -- FMAAITaskTransfer never indexes a stale/nil task vehicle.
    function FMAAIJobTransfer:onPreStart()
        local vehicle=jobVehicle(self)
        if self.transferTask and vehicle then self.transferTask:setVehicle(vehicle) end
    end

    function FMAAIJobTransfer:validate(farmId)
        local ok,msg=CpAIJob.validate(self,farmId)
        if not ok then return false,msg end
        if not self.fmaTarget or not self.fmaTarget.x or not self.fmaTarget.z then return false,"Chybí cíl přejezdu" end
        local vehicle=self.vehicleParameter:getVehicle()
        local ready,readyWhy=cpRuntimeReady(vehicle)
        if not ready then return false,readyWhy end
        return true,""
    end

    function FMAAIJobTransfer:getIsAvailableForVehicle(vehicle)
        return cpRuntimeReady(vehicle)==true
    end

    function FMAAIJobTransfer:getCanStartJob()
        return self:getIsAvailableForVehicle(self.vehicleParameter:getVehicle())
    end

    function FMAAIJobTransfer:getDescription()
        return "Farm Manager · přejezd"
    end

    FMAAITaskTransfer = CpObject(CpAITask)
    function FMAAITaskTransfer:init(isServer,job)
        CpAITask.init(self,isServer,job)
    end
    function FMAAITaskTransfer:start()
        if self.isServer then
            local vehicle=self.vehicle or jobVehicle(self.job)
            if vehicle and type(vehicle.startCpWithStrategy)=="function" then
                self.vehicle=vehicle
                local strategy=FMAAIDriveStrategyTransfer(self,self.job)
                strategy:setAIVehicle(vehicle)
                vehicle:startCpWithStrategy(strategy)
            else
                -- Do not throw from the GIANTS update loop. A missing vehicle is a
                -- controlled no-path failure and will be retried by the Manager.
                if vehicle and type(vehicle.stopCurrentAIJob)=="function" then vehicle:stopCurrentAIJob(makeCpError(api)) end
            end
        end
        CpAITask.start(self)
    end
    function FMAAITaskTransfer:stop(wasJobStopped)
        if self.isServer and self.vehicle and self.vehicle.stopCpDriver then self.vehicle:stopCpDriver(wasJobStopped) end
        CpAITask.stop(self,wasJobStopped)
    end

    FMAAIDriveStrategyTransfer = CpObject(AIDriveStrategyCourse)
    FMAAIDriveStrategyTransfer.myStates={PATHFINDING={},DRIVING={}}

    local function appendGoalCandidate(list,seen,x,z,angle)
        if not x or not z then return end
        local key=string.format("%.2f:%.2f",x,z)
        if seen[key] then return end
        seen[key]=true
        list[#list+1]={x=x,z=z,angle=angle}
    end

    local function transferGoalCandidates(target,tolerance,probeRadius)
        local list,seen={},{}
        local t=target or {}
        appendGoalCandidate(list,seen,t.x,t.z,t.angle)
        if not t.x or not t.z then return list end
        -- A map trigger/root point can lie inside a building or on a non-drivable
        -- nav cell. Probe nearby map cells and let Courseplay validate the actual
        -- collision costmap. Coarse staging may deliberately use a wider probe ring.
        local tol=math.max(2,tonumber(tolerance) or 4)
        local probe=math.max(tol,tonumber(probeRadius) or tol)
        local radii={math.min(tol*0.45,4),math.min(tol*0.82,9)}
        if probe>tol+0.5 then
            radii[#radii+1]=math.min(probe*0.60,12)
            radii[#radii+1]=math.min(probe,18)
        end
        for _,r in ipairs(radii) do
            if r>=1 then
                for i=0,7 do
                    local a=i*math.pi/4
                    appendGoalCandidate(list,seen,t.x+math.sin(a)*r,t.z+math.cos(a)*r,t.angle)
                end
            end
        end
        return list
    end

    function FMAAIDriveStrategyTransfer:init(task,job)
        AIDriveStrategyCourse.init(self,task,job)
        self:initStates(FMAAIDriveStrategyTransfer.myStates)
        self.state=self.states.PATHFINDING
        self.target=job.fmaTarget
        self.tolerance=job.fmaTolerance or 4
        self.probeRadius=job.fmaProbeRadius
        self.directApproach=job.fmaDirectApproach==true
        self.recoveryReverse=job.fmaRecoveryReverse==true
        self.goalCandidates=transferGoalCandidates(self.target,self.tolerance,self.probeRadius)
        self.goalCandidateIndex=1
        self.activeGoal=nil
    end

    function FMAAIDriveStrategyTransfer:isGeneratedCourseNeeded()
        return false
    end

    function FMAAIDriveStrategyTransfer:initializeImplementControllers(vehicle)
        -- Keep the powertrain/folding under CP control, but never activate field tools.
        if MotorController and Motorized then self:addImplementController(vehicle,MotorController,Motorized,{}) end
        if WearableController and Wearable then self:addImplementController(vehicle,WearableController,Wearable,{}) end
        if FoldableController and Foldable then self:addImplementController(vehicle,FoldableController,Foldable,{}) end
    end

    function FMAAIDriveStrategyTransfer:setAIVehicle(vehicle)
        AIDriveStrategyCourse.setAIVehicle(self,vehicle,{})
        if self.pathfinderController and self.pathfinderController.registerListeners then
            self.pathfinderController:registerListeners(self,self.onPathfindingFinished,self.onPathfindingFailed,self.onPathfindingObstacleAtStart)
        end
    end

    function FMAAIDriveStrategyTransfer:onPathfindingObstacleAtStart(controller,lastContext,maxDistance,trailerCollisionsOnly)
        if trailerCollisionsOnly and lastContext then
            lastContext:ignoreTrailerAtStartRange(1.5*(self.turningRadius or 8))
            controller:retry(lastContext)
            return
        end
        if self.vehicle and self.vehicle.stopCurrentAIJob then self.vehicle:stopCurrentAIJob(makeCpError(api)) end
    end

    function FMAAIDriveStrategyTransfer:startGoalCandidate()
        local t=self.goalCandidates and self.goalCandidates[self.goalCandidateIndex] or self.target or {}
        if not t.x or not t.z then
            if self.vehicle and self.vehicle.stopCurrentAIJob then self.vehicle:stopCurrentAIJob(makeCpError(api)) end
            return false
        end
        local angle=t.angle
        if angle==nil then
            local x,z=FMAUtil.position(self.vehicle)
            if x and MathUtil and MathUtil.getYRotationFromDirection then angle=MathUtil.getYRotationFromDirection(t.x-x,t.z-z) end
        end
        angle=angle or currentAngle(self.vehicle)
        local context=PathfinderContext(self.vehicle)
        context:allowReverse(self:getAllowReversePathfinding())
        self.state=self.states.PATHFINDING
        self.activeGoal=t
        local goal=State3D(t.x,-t.z,CpMathUtil.angleFromGame(angle))
        self.pathfinderController:findPathToGoal(context,goal,2)
        return true
    end

    function FMAAIDriveStrategyTransfer:nextGoalCandidate()
        self.goalCandidateIndex=(self.goalCandidateIndex or 1)+1
        if self.goalCandidates and self.goalCandidateIndex<=#self.goalCandidates then
            return self:startGoalCandidate()
        end
        if self.vehicle and self.vehicle.stopCurrentAIJob then self.vehicle:stopCurrentAIJob(makeCpError(api)) end
        return false
    end

    function FMAAIDriveStrategyTransfer:startWithoutCourse(jobParameters)
        self.goalCandidateIndex=math.max(1,self.goalCandidateIndex or 1)
        -- Final hitch alignment is a short, slow manoeuvre. Running a global
        -- pathfinder into the collision envelope of the implement often produces
        -- goalNodeInvalid/no-path even though the tractor is already correctly
        -- staged. For this last few metres we use the normal AI steering target
        -- directly and keep proximity sensing active.
        if self.directApproach then
            self.state=self.states.DRIVING
            self.activeGoal=self.target
            return
        end
        self:startGoalCandidate()
    end

    function FMAAIDriveStrategyTransfer:onPathfindingFailed(controller,lastContext,wasLastRetry,currentRetryAttempt)
        if wasLastRetry then
            self:nextGoalCandidate()
            return
        end
        if not lastContext then self:nextGoalCandidate();return end
        if currentRetryAttempt and currentRetryAttempt>=2 then lastContext:ignoreFruit(true):ignoreFruitHeaps() end
        if PathfinderContext.defaultOffFieldPenalty then lastContext:offFieldPenalty(PathfinderContext.defaultOffFieldPenalty/2) end
        controller:retry(lastContext)
    end

    function FMAAIDriveStrategyTransfer:onPathfindingFinished(controller,success,course,goalNodeInvalid)
        if goalNodeInvalid==true then
            self:nextGoalCandidate()
            return
        end
        if not success or not course then
            self:nextGoalCandidate()
            return
        end
        if course.adjustForTowedImplements then pcall(course.adjustForTowedImplements,course,2) end
        self:startCourse(course,1)
        self.state=self.states.DRIVING
    end

    local function reached(self)
        local t=self.target or {};if not t.x or not t.z then return false end
        local x,z=FMAUtil.position(self.vehicle);if not x then return false end
        local dx,dz=x-t.x,z-t.z
        return dx*dx+dz*dz <= (self.tolerance or 4)^2
    end

    function FMAAIDriveStrategyTransfer:update(dt)
        AIDriveStrategyCourse.update(self,dt)
        self:updateImplementControllers(dt)
        if self.state==self.states.DRIVING and reached(self) then self:setCurrentTaskFinished() end
    end

    function FMAAIDriveStrategyTransfer:getDriveData(dt,vX,vY,vZ)
        if self.directApproach and self.state==self.states.DRIVING then
            local t=self.target or {}
            local x,z=FMAUtil.position(self.vehicle)
            if not x or not t.x then return x or 0,z or 0,true,0,60 end
            local dx,dz=t.x-x,t.z-z
            local d=math.sqrt(dx*dx+dz*dz)
            if d<=(self.tolerance or 1.5) then return t.x,t.z,true,0,60 end
            -- Same Courseplay drive controller used by other AI jobs, but with the
            -- selected physical hitch end driving toward the implement.
            -- Keep proximity protection enabled in BOTH travel directions.
            local allowedSpeed=math.min(self.recoveryReverse and 2.2 or 2.8,
                (self.vehicle.getSpeedLimit and self.vehicle:getSpeedLimit(true)) or 2.8)
            self:setMaxSpeed(allowedSpeed)
            self:limitSpeed()
            self:checkProximitySensors(not self.recoveryReverse)
            return t.x,t.z,not self.recoveryReverse,self.maxSpeed,80
        end
        if self.state==self.states.PATHFINDING or not self.ppc or not self.ppc:getCourse() then
            local x,z=FMAUtil.position(self.vehicle);return x or 0,z or 0,true,0,100
        end
        self:updateLowFrequencyImplementControllers()
        self:updateLowFrequencyPathfinder()
        local moveForwards=not self.ppc:isReversing()
        local gx,gz,maxSpeed
        if moveForwards then gx,_,gz=self.ppc:getGoalPointPosition();maxSpeed=self.vehicle:getSpeedLimit(true)
        else gx,gz,maxSpeed=self:getReverseDriveData() end
        local road=(self.settings and self.settings.fieldSpeed and self.settings.fieldSpeed:getValue()) or 25
        self:setMaxSpeed(math.min(maxSpeed or road,road))
        self:limitSpeed();self:checkProximitySensors(moveForwards)
        return gx,gz,moveForwards,self.maxSpeed,100
    end

    function FMAAIDriveStrategyTransfer:onWaypointChange(ix,course)
        if course and course.isCloseToLastWaypoint and course:isCloseToLastWaypoint(math.max(3,self.tolerance or 4)) then self:setCurrentTaskFinished() end
    end

    return true
end

function FMATransfer.runtimeStatus(vehicle)
    local api,why=resolveCpApi(false)
    local status={cpLoaded=FMACourseplay and FMACourseplay.available and FMACourseplay.available() or false,
        environment=api~=nil,classes=api~=nil,vehicleReady=false,error=why,
        modName=(g_modManager and g_modManager.CP_MOD_NAME) or "FS25_Courseplay"}
    if vehicle then
        local ready,readyWhy=cpRuntimeReady(vehicle);status.vehicleReady=ready;status.error=status.error or readyWhy
    end
    return status
end

function FMATransfer.ensureRegistered(controller)
    if not (FMACourseplay and FMACourseplay.available and FMACourseplay.available()) then
        if controller then controller.lastTransferRegistrationError="Courseplay není aktivní" end
        return false,"Courseplay není aktivní"
    end
    local ok,why=ensureClasses();if not ok then if controller then controller.lastTransferRegistrationError=why end;return false,why end
    local manager=g_currentMission and g_currentMission.aiJobTypeManager
    if not manager or type(manager.getJobTypeIndexByName)~="function" or type(manager.registerJobType)~="function" then
        if controller then controller.lastTransferRegistrationError="AIJobTypeManager není připraven" end
        return false,"AIJobTypeManager není připraven"
    end
    local index=manager:getJobTypeIndexByName(JOB_NAME)
    if index==nil then
        local registered,err=pcall(manager.registerJobType,manager,JOB_NAME,"Farm Manager · přejezd",FMAAIJobTransfer)
        if not registered then if controller then controller.lastTransferRegistrationError=tostring(err) end;return false,tostring(err) end
        index=manager:getJobTypeIndexByName(JOB_NAME)
    end
    if index==nil then
        if controller then controller.lastTransferRegistrationError="Nepodařilo se zaregistrovat Courseplay transfer job" end
        return false,"Nepodařilo se zaregistrovat Courseplay transfer job"
    end
    if controller then controller.transferJobType=index;controller.lastTransferRegistrationError=nil end
    return true,index
end

function FMATransfer.createJob(controller,record,target)
    if not controller or not record or not record.object or not target or not target.x or not target.z then return nil,"Chybí stroj nebo cíl přejezdu" end
    local ready,readyWhy=cpRuntimeReady(record.object);if not ready then return nil,readyWhy end
    local ok,why=FMATransfer.ensureRegistered(controller);if not ok then return nil,why end
    local job,err=FMAAI.createRegisteredJob(JOB_NAME)
    if not job then return nil,err or "Nelze vytvořit Courseplay transfer job" end
    job:applyCurrentState(record.object,g_currentMission,controller.farmId,true)
    job:setTarget(target.x,target.z,target.angle or currentAngle(record.object),target.tolerance or 4,target.probeRadius,target.directApproach,target.recoveryReverse)
    job:setValues()
    local valid,reason=job:validate(controller.farmId);if valid~=true then return nil,tostring(reason or "Courseplay odmítl přejezd") end
    local startable,state=job:getIsStartable(nil)
    if startable~=true then
        local description=nil
        local method=job.getIsStartErrorText
        if type(method)=='function' then
            local ok,value=pcall(method,state)
            if ok and value and tostring(value)~='' then description=tostring(value) end
        end
        local category,details=FMAJobs.startRejection(record.object,'Courseplay',state)
        if controller and FMADiagnostics then FMADiagnostics.event(controller,'transfer.cpStartGate',record.name or record.key,category..' '..details) end
        return nil,category..': '..details..(description and ': '..description or '')
    end
    return job,nil
end
