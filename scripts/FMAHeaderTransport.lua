-- Header/cutter transport workflow for wide harvesting equipment.
-- The goal is a real sequence: cutter -> carrier -> field -> cutter -> work ->
-- carrier -> home. It uses physical AI driving, normal attach/detach and the
-- game's dynamic-mount/tension-belt systems; if a carrier cannot actually secure
-- the cutter, the workflow stops instead of teleporting it.
FMAHeaderTransport = {}

function FMAHeaderTransport.attachedCutter(vehicle)
    -- A cutter on a dynamically mounted trailer is NOT attached to the combine.
    -- Only GIANTS' mechanical attachment chain can power real harvesting.
    for _,tool in ipairs(FMAWorld.operationalChildren(vehicle)) do
        if tool~=vehicle and tool.spec_cutter then return tool end
    end
    return nil
end

function FMAHeaderTransport.workWidth(cutter)
    if not cutter then return 0 end
    local w=FMAUtil.call(cutter,"getAIWorkAreaWidth")
    if w and w>0 then return w end
    local spec=cutter.spec_workArea
    if spec then
        local best=0
        for _,a in pairs(spec.workAreas or {}) do best=math.max(best,a.workWidth or 0) end
        return best
    end
    return 0
end

function FMAHeaderTransport.hasBuiltInTransport(cutter)
    if not cutter then return false end
    if cutter.spec_builtInCutterTrailer~=nil then return true end
    -- Some ModHub cutters expose a second towing input joint instead of a separate carrier.
    local inputs=FMAUtil.call(cutter,"getInputAttacherJoints") or (cutter.spec_attachable and cutter.spec_attachable.inputAttacherJoints) or {}
    return #inputs>1 and cutter.spec_foldable~=nil
end

function FMAHeaderTransport.isCarrier(tool)
    local o=tool and tool.object
    if not o then return false end
    if o.spec_cutter or o.spec_baler or o.spec_sowingMachine or o.spec_sprayer then return false end
    return o.spec_dynamicMountAttacher~=nil or o.spec_tensionBelts~=nil
end

function FMAHeaderTransport.isSecured(cutter,carrier)
    if not cutter or not carrier then return false end
    if FMAUtil.call(cutter,"getDynamicMountObject")==carrier then return true end
    if cutter.tensionMountObject==carrier then return true end
    local dm=carrier.spec_dynamicMountAttacher
    if dm and dm.dynamicMountedObjects and dm.dynamicMountedObjects[cutter] then return true end
    return false
end

-- Detect a real-world "combine + header trailer + cutter already loaded" chain.
-- In the supplied savegame this is exactly how the LEXION is parked: the carrier
-- is attached to the combine while the cutter is dynamically mounted on the carrier.
-- Treating the carrier as a blocking foreign implement made the combine look unusable.
function FMAHeaderTransport.attachedCarrier(record)
    if not record or not record.object then return nil end
    for _,entry in pairs(FMAUtil.call(record.object,"getAttachedImplements") or {}) do
        local object=entry.object
        if object then
            local profile={object=object,key=FMAWorld.vehicleKey(object),name=FMAUtil.name(object)}
            if FMAHeaderTransport.isCarrier(profile) then return profile end
        end
    end
    return nil
end

function FMAHeaderTransport.cutterOnCarrier(controller,carrier)
    if not controller or not carrier or not carrier.object then return nil end
    -- A dynamically mounted cutter is intentionally excluded from controller.loose,
    -- because physically it belongs to the carrier tree. Inspect that real tree first.
    for _,object in ipairs(FMAWorld.children(carrier.object) or {}) do
        if object~=carrier.object and object.spec_cutter and FMAHeaderTransport.isSecured(object,carrier.object) then
            local profile=FMAWorld.toolProfile(object)
            profile.mountedCarrier=carrier.object;profile.transported=true
            return profile
        end
    end
    -- Compatibility fallback for unusual mods that expose the mounted cutter in loose.
    for _,tool in ipairs(controller.loose or {}) do
        if tool.object and tool.object.spec_cutter and (tool.mountedCarrier==carrier.object or FMAHeaderTransport.isSecured(tool.object,carrier.object)) then return tool end
    end
    return nil
end

function FMAHeaderTransport.preloadedChain(controller,task)
    if not controller or not task or task.operation~="harvest" or task.headerTransportReady then return nil end
    for _,record in ipairs(controller.vehicles or {}) do
        if record.isGrainCombine==true and not record.busy and not controller.reservations[record.key]
            and (task.preferredVehicleKey==nil or task.preferredVehicleKey==record.key) then
            local carrier=FMAHeaderTransport.attachedCarrier(record)
            local cutter=carrier and FMAHeaderTransport.cutterOnCarrier(controller,carrier) or nil
            local carrierReservation=carrier and controller.implementReservations and controller.implementReservations[carrier.key] or nil
            local cutterReservation=cutter and controller.implementReservations and controller.implementReservations[cutter.key] or nil
            local reservationOk=(carrierReservation==nil or carrierReservation==task.id) and (cutterReservation==nil or cutterReservation==task.id)
            local selectedToolOk=cutter and (task.preferredImplementKey==nil or task.preferredImplementKey==cutter.key)
            if carrier and cutter and reservationOk and selectedToolOk then
                if task.fruitIndex==nil or not cutter.harvestFruits or next(cutter.harvestFruits)==nil or cutter.harvestFruits[task.fruitIndex]==true then
                    return {record=record,carrier=carrier,cutter=cutter,width=FMAHeaderTransport.workWidth(cutter.object),preloaded=true}
                end
            end
        end
    end
    return nil
end

function FMAHeaderTransport.releaseCarrierLoad(cutter,carrier)
    if carrier and carrier.setAllTensionBeltsActive then pcall(carrier.setAllTensionBeltsActive,carrier,false) end
    if cutter and FMAUtil.call(cutter,"getDynamicMountObject")==carrier and cutter.unmountDynamic then pcall(cutter.unmountDynamic,cutter,false) end
    return true
end

function FMAHeaderTransport.findCarrier(controller,task,harvester,cutter)
    local best,bestScore
    for _,tool in ipairs(controller.loose or {}) do
        if FMAHeaderTransport.isCarrier(tool) and not controller.implementReservations[tool.key] and (task.preferredCarrierKey==nil or task.preferredCarrierKey==tool.key) then
            local joint=FMAAssembler.findJointPair(harvester.object,tool.object,controller.farmId)
            if joint then
                local score=FMAUtil.distance(harvester,tool)
                if not best or score<bestScore then best,bestScore=tool,score end
            end
        end
    end
    return best
end

local function pose(object)
    local x,z=FMAUtil.position(object);return x and {x=x,z=z,angle=0} or nil
end

function FMAHeaderTransport.fieldStage(parent,carrierHome,settings)
    local fx,fz=parent.x,parent.z
    if not fx then return nil end
    local hx,hz=carrierHome and carrierHome.x,carrierHome and carrierHome.z
    local dx,dz=(hx or fx+1)-fx,(hz or fz)-fz
    local len=math.sqrt(dx*dx+dz*dz);if len<0.1 then dx,dz,len=1,0,1 end
    dx,dz=dx/len,dz/len
    local dist=settings.headerFieldStagingDistance or 22
    return {x=fx+dx*dist,z=fz+dz*dist,angle=MathUtil and MathUtil.getYRotationFromDirection and MathUtil.getYRotationFromDirection(-dx,-dz) or 0}
end

function FMAHeaderTransport.carrierLoadTarget(record,cutter,carrier,settings)
    local object=carrier and carrier.object
    if not record or not record.object or not cutter or not object then return nil end
    local mountNode=nil
    local dm=object.spec_dynamicMountAttacher
    if dm then
        local trigger=dm.dynamicMountAttacherTrigger
        mountNode=(trigger and (trigger.jointNode or trigger.rootNode or trigger.triggerNode)) or dm.dynamicMountAttacherNode
    end
    if not mountNode and object.spec_tensionBelts then mountNode=object.spec_tensionBelts.jointNode or object.spec_tensionBelts.linkNode end
    local mx,mz
    if mountNode and getWorldTranslation then local ok,x,_,z=pcall(getWorldTranslation,mountNode);if ok then mx,mz=x,z end end
    if not mx then mx,mz=FMAUtil.position(object) end
    if not mx then return nil end
    local angle=0;local rx,rz,fx,fz=1,0,0,1
    if mountNode and localDirectionToWorld then
        local ok1,x1,_,z1=pcall(localDirectionToWorld,mountNode,1,0,0);if ok1 then rx,rz=x1,z1 end
        local ok2,x2,_,z2=pcall(localDirectionToWorld,mountNode,0,0,1);if ok2 then fx,fz=x2,z2;if MathUtil and MathUtil.getYRotationFromDirection then angle=MathUtil.getYRotationFromDirection(fx,fz) end end
    end
    local lx,lz=0,0
    if record.object.rootNode and cutter.rootNode and localToLocal then
        local ok,x,_,z=pcall(localToLocal,cutter.rootNode,record.object.rootNode,0,0,0);if ok then lx,lz=x,z end
    end
    local extra=settings.headerCarrierLongitudinalOffset or 0
    return {x=mx-rx*lx-fx*(lz+extra),z=mz-rz*lx-fz*(lz+extra),angle=angle,toolX=mx,toolZ=mz}
end

function FMAHeaderTransport.needsTransport(controller,task,record)
    if not task or task.operation~="harvest" or task.headerTransportReady then return false end
    local cutter=FMAHeaderTransport.attachedCutter(record.object)
    if not cutter or FMAHeaderTransport.hasBuiltInTransport(cutter) then return false end
    local width=FMAHeaderTransport.workWidth(cutter)
    if width<(controller.settings.headerTransportMinWidth or 6.0) then return false end
    return true,cutter,width
end

function FMAHeaderTransport.describe(controller,task)
    if not task or task.operation~="harvest" then return {} end
    local lines={}
    local record=nil
    if task.preferredVehicleKey then for _,v in ipairs(controller.vehicles or {}) do if v.key==task.preferredVehicleKey then record=v end end end
    local cutter=record and FMAHeaderTransport.attachedCutter(record.object) or nil
    local width=cutter and FMAHeaderTransport.workWidth(cutter) or nil
    if width and width>0 then lines[#lines+1]="Adaptér: "..FMAUtil.name(cutter).." · "..string.format("%.1f m",width) end
    if width and width>=(controller.settings.headerTransportMinWidth or 6) and not FMAHeaderTransport.hasBuiltInTransport(cutter) then
        lines[#lines+1]="Přeprava adaptéru: podvozek + bezpečné přepřažení u pole"
    else
        lines[#lines+1]="Přeprava adaptéru: podle konstrukce / přímý výjezd"
    end
    lines[#lines+1]="Odvoz: automaticky 1–"..tostring(controller.settings.maxUnloaders or 3).." soupravy podle výkonu a obratu"
    lines[#lines+1]="Po práci: adaptér na podvozek, návrat, odstavení a parkování"
    return lines
end

function FMAHeaderTransport.startGoTo(controller,parent,record,plan,target,phase,label)
    if not target or not target.x then return false,"Chybí cílová poloha technologického kroku" end
    local trafficTask={id="header:"..parent.id..":"..phase,kind="headerTransport",operation="harvest",parentTaskId=parent.id}
    if FMATraffic and FMATraffic.canStart then
        local free,wait=FMATraffic.canStart(controller,record,target,trafficTask,45000)
        if not free then return FMALifecycle.defer(controller,trafficTask.id,record,parent,function() return FMAHeaderTransport.startGoTo(controller,parent,record,plan,target,phase,label) end,wait) end
    end
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=target.x,z=target.z,angle=target.angle or 0,tolerance=4,preferCourseplay=target.preferCourseplay})
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,moveWhy or "Stroj neumí autonomní přesun" end
    local task={id="header:"..parent.id..":"..phase,kind="headerTransport",operation="harvest",label=label or "Přeprava adaptéru",parentTaskId=parent.id,
        phase=phase,priority=(parent.priority or 90)+12,state="running",target=target}
    parent.state=phase:find("return") and "returning" or "assembling";parent.reason=task.label
    controller.reservations[record.key]=task.id;record.busy=true
    controller.implementReservations[plan.carrier.key]=parent.id
    controller.active[job]={job=job,task=task,vehicle=record,headerPlan=plan,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,transferMethod=moveMethod,trafficTarget=target}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(err) end
    controller:notify(task.label.." · "..record.name)
    return true
end

local function detachObject(attacher,object)
    if not attacher or not object or type(attacher.detachImplementByObject)~="function" then return false,"Chybí bezpečné odpojení" end
    -- FS25 Attachables expose isDetachAllowed (legacy mods sometimes expose
    -- getIsDetachAllowed). The old code queried only the legacy spelling and
    -- prevented ALL otherwise valid header-trailer detach operations.
    local method=type(object.isDetachAllowed)=='function' and 'isDetachAllowed' or 'getIsDetachAllowed'
    local allowed,warning=FMAUtil.call(object,method)
    if allowed~=true then return false,tostring(warning or "Odpojení není povoleno") end
    local ok,result=pcall(attacher.detachImplementByObject,attacher,object,false)
    if not ok or result==false then return false,"FS25 odmítl odpojení" end
    if FMAUtil.call(object,"getAttacherVehicle")~=nil then return false,"Odpojení ještě není dokončeno" end
    return true
end

local function carrierApproach(record,carrier,settings)
    return FMAAssembler.approachPoint(record,carrier,settings) or pose(carrier.object)
end

function FMAHeaderTransport.attachCarrier(controller,record,plan)
    local jointIndex,inputIndex=FMAAssembler.findJointPair(record.object,plan.carrier.object,controller.farmId)
    if not jointIndex then return false,"Kombajn/řezačka nemá kompatibilní závěs pro podvozek" end
    return FMAAssembler.attach(controller,{power=record,tool=plan.carrier,jointIndex=jointIndex,inputIndex=inputIndex})
end

function FMAHeaderTransport.attachCutter(controller,record,plan)
    FMAHeaderTransport.releaseCarrierLoad(plan.cutter,plan.carrier.object)
    local cutterRecord={object=plan.cutter,key=FMAWorld.vehicleKey(plan.cutter),name=FMAUtil.name(plan.cutter),capabilities={harvest=true},harvestFruits={}}
    local jointIndex,inputIndex=FMAAssembler.findJointPair(record.object,plan.cutter,controller.farmId)
    if not jointIndex then return false,"Po odstavení podvozku nelze znovu spojit adaptér s kombajnem" end
    return FMAAssembler.attach(controller,{power=record,tool=cutterRecord,jointIndex=jointIndex,inputIndex=inputIndex})
end

function FMAHeaderTransport.fieldOutboundCandidates(controller,parent,record,plan)
    local points,seen={},{}
    local function add(p)
        if not p or not p.x or not p.z then return end
        local id=string.format('%.0f:%.0f',p.x,p.z)
        if not seen[id] then seen[id]=true;points[#points+1]={x=p.x,z=p.z,angle=p.angle or 0} end
    end
    -- Prefer real boundary vertices instead of a single center-offset goal that
    -- may be inside buildings, fences or standing crop.
    if FMAFleetCoordinator and FMAFleetCoordinator.fieldWaitingCandidates then
        for _,p in ipairs(FMAFleetCoordinator.fieldWaitingCandidates(controller,parent,record)) do add(p) end
    end
    add(plan and plan.fieldStage)
    return points
end

function FMAHeaderTransport.retryFieldOutbound(controller,parent,record,plan,reason,forceCp)
    plan.outboundCandidates=plan.outboundCandidates or FMAHeaderTransport.fieldOutboundCandidates(controller,parent,record,plan)
    local options=plan.outboundCandidates
    if #options==0 then return false,'Nebylo nalezeno žádné bezpečné místo k převozu lišty' end
    local lastReason=reason
    -- A stationary combine MUST NOT be sent to fifty more destinations.
    -- A single alternate target plus one alternate routing engine is enough
    -- before surfacing the actual blocked starting position to the owner.
    local maxAttempts=math.min(4,#options*2)
    if forceCp==true then maxAttempts=(plan.outboundTries or 0)+1 end
    while (plan.outboundTries or 0)<maxAttempts do
        plan.outboundTries=(plan.outboundTries or 0)+1
        local index=((plan.outboundTries-1)%#options)+1
        local candidate=options[index]
        local point={x=candidate.x,z=candidate.z,angle=candidate.angle,
            preferCourseplay=forceCp==true or plan.outboundTries>#options,
            requireCourseplay=forceCp==true}
        plan.fieldStage=point
        FMADiagnostics.event(controller,'header.reroute',parent.id,'attempt='..tostring(plan.outboundTries)..'/'..tostring(maxAttempts)..' x='..tostring(point.x)..' z='..tostring(point.z))
        local started,why=FMAHeaderTransport.startGoTo(controller,parent,record,plan,point,'toFieldWithCarrier','Adaptér · alternativní přejezd k poli')
        if started then return true,nil end
        lastReason=why or lastReason
    end
    return false,'GIANTS i Courseplay odmítly alternativní cíle u pole; poslední důvod: '..tostring(lastReason)
end

function FMAHeaderTransport.startPreloadedOutbound(controller,parent,chain)
    if not chain or not chain.record or not chain.carrier or not chain.cutter then return false,"Chybí předpřipravený přepravní řetězec adaptéru" end
    local record,carrier,cutter=chain.record,chain.carrier,chain.cutter
    FMAReturnManager.captureHomes(controller)
    local plan={harvesterKey=record.key,cutter=cutter.object,cutterKey=cutter.key,cutterName=cutter.name,carrier=carrier,width=chain.width or FMAHeaderTransport.workWidth(cutter.object),
        carrierHome=controller.toolHomes[carrier.key] or pose(carrier.object),harvesterHome=controller.homePositions[record.key] or pose(record.object),preloaded=true}
    plan.fieldStage=FMAHeaderTransport.fieldStage(parent,plan.carrierHome,controller.settings)
    if not plan.fieldStage then return false,"Nelze určit bezpečný bod pro podvozek adaptéru u pole" end
    parent.headerTransportPlan=plan
    parent.vehicleKey=record.key -- live relocation can reopen this exact blocked route
    controller.implementReservations[carrier.key]=parent.id
    controller.implementReservations[cutter.key]=parent.id
    return FMAHeaderTransport.retryFieldOutbound(controller,parent,record,plan,'první přejezd')
end

function FMAHeaderTransport.startOutbound(controller,parent,record,cutter,width)
    local carrier=FMAHeaderTransport.findCarrier(controller,parent,record,cutter)
    if not carrier then
        local why="Adaptér "..FMAUtil.name(cutter).." má přibližně "..string.format("%.1f m",width)..". Pro realistický bezpečný výjezd chybí kompatibilní podvozek na lištu."
        controller:issue("headerCarrier:"..parent.id,parent.label.." · podvozek adaptéru",why,97)
        parent.reason=why
        return false,why
    end
    FMAReturnManager.captureHomes(controller)
    local plan={harvesterKey=record.key,cutter=cutter,cutterName=FMAUtil.name(cutter),carrier=carrier,width=width,
        carrierHome=controller.toolHomes[carrier.key] or pose(carrier.object),harvesterHome=controller.homePositions[record.key] or pose(record.object)}
    plan.fieldStage=FMAHeaderTransport.fieldStage(parent,plan.carrierHome,controller.settings)
    parent.headerTransportPlan=plan
    local target=FMAHeaderTransport.carrierLoadTarget(record,cutter,carrier,controller.settings) or carrierApproach(record,carrier,controller.settings)
    return FMAHeaderTransport.startGoTo(controller,parent,record,plan,target,"toCarrierWithCutter","Adaptér na podvozek · přesné přistavení")
end

function FMAHeaderTransport.waitForSecure(controller,parent,record,plan,returning)
    controller.headerWaits=controller.headerWaits or {}
    controller.headerWaits[parent.id]={parent=parent,vehicle=record,plan=plan,returning=returning,started=controller.now,deadline=controller.now+(controller.settings.headerMountWaitSeconds or 8)*1000}
    controller.reservations[record.key]="headerWait:"..parent.id;record.busy=true
    parent.state=returning and "returning" or "assembling";parent.reason="Čeká na bezpečné usazení adaptéru na podvozek"
end

function FMAHeaderTransport.secureCarrier(plan)
    local carrier=plan.carrier.object
    if carrier and carrier.setAllTensionBeltsActive then pcall(carrier.setAllTensionBeltsActive,carrier,true) end
end

function FMAHeaderTransport.update(controller)
    for id,w in pairs(controller.headerWaits or {}) do
        FMAHeaderTransport.secureCarrier(w.plan)
        if FMAHeaderTransport.isSecured(w.plan.cutter,w.plan.carrier.object) then
            controller.headerWaits[id]=nil;controller.reservations[w.vehicle.key]=nil;w.vehicle.busy=false
            local target=carrierApproach(w.vehicle,w.plan.carrier,controller.settings)
            local phase=w.returning and "toCarrierHitchReturn" or "toCarrierHitchOutbound"
            local label=w.returning and "Přistavení k podvozku pro návrat" or "Přistavení k naloženému podvozku"
            local started,err=FMAHeaderTransport.startGoTo(controller,w.parent,w.vehicle,w.plan,target,phase,label)
            if not started then w.parent.state="blocked";w.parent.reason=tostring(err);controller:issue(w.parent.id,w.parent.label,w.parent.reason,96) end
        elseif controller.now>=w.deadline then
            controller.headerWaits[id]=nil;controller.reservations[w.vehicle.key]=nil;w.vehicle.busy=false
            w.parent.state="blocked";w.parent.reason="Adaptér se fyzicky neusadil / nezajistil na podvozku. Uprav stání podvozku nebo použij kompatibilní podvozek."
            controller:issue(w.parent.id,w.parent.label,w.parent.reason,98)
        end
    end
end

function FMAHeaderTransport.onStopped(controller,active,message)
    local parent=controller.tasks[active.task.parentTaskId];local plan=active.headerPlan;local record=active.vehicle
    if not parent or not plan then return end
    if active.stopReason then
        if active.task.phase=='toFieldWithCarrier' then
            -- A real 0.20.43 trace showed GIANTS accepting the LEXION 6900
            -- but not moving even 1 metre in 23 seconds. Changing a distant
            -- destination does not repair a stationary combine in the yard.
            -- Do not retry this physical fault in a tight dispatch loop.
            local stationary=tostring(active.stopReason):find('do 23 s nerozjel',1,true)
                or tostring(active.stopReason):find('bez pohybu',1,true)
            if stationary and active.physicalMotionVerified~=true then
                local cpAvailable=FMACourseplay and FMACourseplay.available and FMACourseplay.available()
                local canChange,authorityWhy=FMAControlAuthority and FMAControlAuthority.canStart(controller,record,parent.id)
                if not plan.stationaryCpTried and cpAvailable and canChange then
                    plan.stationaryCpTried=true
                    local ok,why=FMAHeaderTransport.retryFieldOutbound(controller,parent,record,plan,
                        'GIANTS převzala stroj, ale nerozjela ho; přebírá Courseplay',true)
                    if ok then
                        if FMADiagnostics then FMADiagnostics.event(controller,'header.STATIONARY_CP_HANDOFF',record.name or record.key,'CP start actually requested') end
                        return
                    end
                    plan.stationaryCpReason=why
                else
                    plan.stationaryCpReason=(not cpAvailable and 'Courseplay není načtený')
                        or (not canChange and tostring(authorityWhy)) or 'Courseplay již byl vyzkoušen'
                end
                if FMADiagnostics then FMADiagnostics.event(controller,'header.STATIONARY_CP_REFUSED',record.name or record.key,tostring(plan.stationaryCpReason)) end
                parent.state='blocked';parent.phase='KOMBAJN SE FYZICKY NEROZJEL'
                parent.selfHealingCause='stationaryStart'
                parent.selfHealingVehicleKey=record.key
                parent.reason='LEXION/hlavní stroj: AI převzala řízení, ale stroj se nepohnul. Další dlouhý přejezd pozastaven. CP alternativa: '..tostring(plan.stationaryCpReason or 'nepotvrzena')..'. '..tostring(active.stopReason)
                controller:issue('headerStationary:'..parent.id,parent.label,parent.reason,99)
                if FMADiagnostics then FMADiagnostics.event(controller,'header.STATIONARY_BLOCK',record.name or record.key,parent.reason) end
                return
            end
            -- A failed point-to-point AI route is not permission to detach the cutter,
            -- finish the harvest, or abandon the job. Rotate to a different field entry.
            local ok,why=FMAHeaderTransport.retryFieldOutbound(controller,parent,record,plan,active.stopReason)
            if ok then return end
            parent.state='blocked';parent.phase='BLOKACE · VYČERPANÉ PŘÍJEZDY';parent.reason=why
            controller:issue('headerRoute:'..parent.id,parent.label,parent.reason,95)
            return
        end
        parent.state="blocked";parent.reason=active.stopReason;return
    end
    local phase=active.task.phase
    if phase=="toCarrierWithCutter" or phase=="returnToCarrierWithCutter" then
        local ok,why=detachObject(record.object,plan.cutter)
        if not ok then parent.state="blocked";parent.reason="Nelze položit adaptér na podvozek: "..tostring(why);controller:issue(parent.id,parent.label,parent.reason,98);return end
        FMAHeaderTransport.waitForSecure(controller,parent,record,plan,phase=="returnToCarrierWithCutter")
        return
    end
    if phase=="toCarrierHitchOutbound" or phase=="toCarrierHitchReturn" then
        local ok,why=FMAHeaderTransport.attachCarrier(controller,record,plan)
        if not ok then parent.state="blocked";parent.reason="Naložený podvozek nelze zapřáhnout: "..tostring(why);controller:issue(parent.id,parent.label,parent.reason,98);return end
        FMAAssembler.confirm(controller,parent,{power=record,tool=plan.carrier},function()
        local target=phase=="toCarrierHitchReturn" and plan.carrierHome or plan.fieldStage
        local nextPhase=phase=="toCarrierHitchReturn" and "returnCarrierHome" or "toFieldWithCarrier"
        local label=phase=="toCarrierHitchReturn" and "Návrat podvozku s adaptérem" or "Převoz adaptéru k poli"
        local started,err=FMAHeaderTransport.startGoTo(controller,parent,record,plan,target,nextPhase,label)
        if not started then parent.state="blocked";parent.reason=tostring(err) end
        end)
        return
    end
    if phase=="toFieldWithCarrier" then
        local ok,why=detachObject(record.object,plan.carrier.object)
        if not ok then parent.state="blocked";parent.reason="U pole nelze odpojit podvozek: "..tostring(why);return end
        FMAHeaderTransport.releaseCarrierLoad(plan.cutter,plan.carrier.object)
        plan.fieldCarrierPark=pose(plan.carrier.object)
        local cutterRecord={object=plan.cutter,key=FMAWorld.vehicleKey(plan.cutter),name=FMAUtil.name(plan.cutter)}
        local target=FMAAssembler.approachPoint(record,cutterRecord,controller.settings) or pose(plan.cutter)
        local started,err=FMAHeaderTransport.startGoTo(controller,parent,record,plan,target,"toCutterAtField","Přepřažení adaptéru u pole")
        if not started then parent.state="blocked";parent.reason=tostring(err) end
        return
    end
    if phase=="toCutterAtField" then
        local ok,why=FMAHeaderTransport.attachCutter(controller,record,plan)
        if ok then
            local cutterRecord={object=plan.cutter,key=FMAWorld.vehicleKey(plan.cutter),name=plan.cutterName}
            FMAAssembler.confirm(controller,parent,{power=record,tool=cutterRecord},function()
            parent.headerTransportReady=true;parent.state="pending";parent.reason=nil;parent.retryAt=0
            if plan.cutterKey then controller.implementReservations[plan.cutterKey]=nil end
            controller.implementReservations[plan.carrier.key]=parent.id
            controller:notify(plan.cutterName.." připraven · "..record.name.." může zahájit sklizeň")
            controller.elapsed=controller.settings.scanSeconds*1000
            end)
        else parent.state="blocked";parent.reason="Přepřažení adaptéru u pole selhalo: "..tostring(why);controller:issue(parent.id,parent.label,parent.reason,98) end
        return
    end
    if phase=="returnCarrierHome" then
        local ok,why=detachObject(record.object,plan.carrier.object)
        if not ok then parent.state="blocked";parent.reason="Doma nelze odstavit podvozek: "..tostring(why);return end
        local started,err=FMAHeaderTransport.startGoTo(controller,parent,record,plan,plan.harvesterHome,"returnHarvesterHome","Parkování sklizňového stroje")
        if not started then parent.state="blocked";parent.reason=tostring(err) end
        return
    end
    if phase=="returnHarvesterHome" then
        controller.implementReservations[plan.carrier.key]=nil
        if plan.cutterKey then controller.implementReservations[plan.cutterKey]=nil end
        local verified,verifyWhy=true,nil
        if controller.verifyFieldOrderComplete then verified,verifyWhy=controller:verifyFieldOrderComplete(parent) end
        if parent.kind=="field" and not verified then
            parent.state="pending";parent.phase="DOKONČENÍ NEPOTVRZENO";parent.reason=verifyWhy;parent.retryAt=controller.now+1500
        else
            parent.state="done";parent.phase="HOTOVO · OVĚŘENO FS25";parent.reason="Hotovo · skutečný stav ověřen, adaptér na podvozku, technika doma";parent.retryAt=controller.now+60000;parent.ownerRequested=nil
            if verified and controller.verifyFieldOrderComplete and FMAForageCoordinator and parent.operation=='harvest' then FMAForageCoordinator.afterOperation(controller,parent) end
            if FMAExperience and FMAExperience.verified then FMAExperience.verified(controller,parent,record,verified and controller.verifyFieldOrderComplete~=nil) end
        end
        parent.headerTransportReady=nil;parent.awaitingWorldVerification=nil
        FMAJobs.stopMotor(record)
        controller:notify(record.name.." zaparkoval · adaptér je na podvozku a sestava je připravena")
        controller.elapsed=controller.settings.scanSeconds*1000
    end
end

function FMAHeaderTransport.stopSupport(controller,harvesterKey)
    local jobs={}
    for job,a in pairs(controller.active or {}) do if a.task and a.task.kind=="support" and a.task.harvesterKey==harvesterKey then jobs[#jobs+1]=job end end
    for _,job in ipairs(jobs) do FMAAI.stop(job) end
end

function FMAHeaderTransport.beginReturn(controller,active)
    local parent=active.task;local plan=parent.headerTransportPlan;local record=active.vehicle
    if not plan or not parent.headerTransportReady then return false,"Chybí přepravní plán adaptéru" end
    local cutter=FMAHeaderTransport.attachedCutter(record.object)
    if not cutter then return false,"Po sklizni není adaptér připojen ke stroji" end
    plan.cutter=cutter
    FMAHeaderTransport.stopSupport(controller,record.key)
    local carrier=controller.looseByKey and controller.looseByKey[plan.carrier.key] or plan.carrier
    if carrier then plan.carrier=carrier end
    local target=FMAHeaderTransport.carrierLoadTarget(record,cutter,plan.carrier,controller.settings) or plan.fieldCarrierPark or pose(plan.carrier.object)
    parent.state="returning";parent.reason="Vrácení adaptéru na podvozek"
    return FMAHeaderTransport.startGoTo(controller,parent,record,plan,target,"returnToCarrierWithCutter","Po práci · adaptér na podvozek")
end

function FMAHeaderTransport.cancelAll(controller)
    for id,w in pairs(controller.headerWaits or {}) do
        controller.reservations[w.vehicle.key]=nil;w.vehicle.busy=false
        if w.parent then w.parent.state="paused";w.parent.reason="Pozastaveno majitelem během manipulace s adaptérem" end
        controller.headerWaits[id]=nil
    end
end
