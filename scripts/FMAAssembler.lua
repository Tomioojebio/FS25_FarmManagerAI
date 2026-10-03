-- Automatic fleet assembly: choose a power unit + detached implement, drive close to it,
-- attach it through the game's own AttacherJoints API and return the parent job to the queue.
-- It intentionally fails closed when geometry/compatibility cannot be proven.
FMAAssembler = {}

-- 0.20.43 DEV: engine-independent circuit breaker across task rescans.
-- A "success" callback from a GoTo job is NOT a physical arrival, so record
-- repeated attempts at the same parked tractor and move to another strategy.
-- An owner can recover by moving the vehicle several metres or changing the rig.
local function assemblyCircuit(c,parent,plan)
    c.assemblyCircuits=c.assemblyCircuits or {}
    local key=tostring(parent.id)
    local signature=tostring(plan.power.key)..'/'..tostring(plan.tool.key)
    local entry=c.assemblyCircuits[key]
    local x,z=FMAUtil.position(plan.power.object)
    if not entry or entry.signature~=signature then
        entry={signature=signature,failures=0,startedX=x,startedZ=z,created=c.now or 0}
        c.assemblyCircuits[key]=entry
    end
    -- A genuine change in the world is reason to retry, a timer alone is not.
    if x and z and entry.startedX and entry.startedZ then
        local moved=math.sqrt((x-entry.startedX)^2+(z-entry.startedZ)^2)
        if moved>=3.0 then
            entry.failures=0;entry.startedX=x;entry.startedZ=z;entry.halted=false
            if FMADiagnostics then FMADiagnostics.event(c,'assembly.circuitReset',key,'Traktor se opravdu posunul '..string.format('%.1f',moved)..' m') end
        end
    end
    return entry
end

function FMAAssembler.observeApproach(c,parent,plan,active,why)
    local entry=assemblyCircuit(c,parent,plan)
    local x,z=FMAUtil.position(plan.power.object)
    local origin=active and active.startPosition
    local moved=origin and x and math.sqrt((x-origin.x)^2+(z-origin.z)^2) or 0
    if moved>=2.0 then
        entry.failures=0;entry.startedX=x;entry.startedZ=z
        return false
    end
    entry.failures=(entry.failures or 0)+1
    if FMADiagnostics then
        FMADiagnostics.event(c,'assembly.noProgress',parent.id,
            'fail='..entry.failures..'/5 vehicle='..tostring(plan.power.name)..
            ' tool='..tostring(plan.tool.name)..' moved='..string.format('%.2f',moved)..
            'm method='..tostring(active and active.transferMethod)..' reason='..tostring(why))
    end
    if entry.failures<5 then return false end
    entry.halted=true
    FMAAssembler.releaseLease(c,parent,plan)
    -- Try a DIFFERENT tractor for the same actual implement at most twice.
    -- A new power/tool pair gets a fresh budget; the original cannot repeat.
    if FMAAssembler.tryAlternatePower and FMAAssembler.tryAlternatePower(c,parent,plan) then
        if FMADiagnostics then FMADiagnostics.event(c,'assembly.circuitFailover',parent.id,'Jiný traktor místo opakování stejného nájezdu') end
        return true
    end
    parent.state='blocked';parent.phase='STROJ STOJÍ · ZASTAVENO OPAKOVÁNÍ'
    parent.reason='Pět nájezdů bez fyzického posunu ('..tostring(plan.power.name)..
        '): ukončuji opakování téhož cíle. Stroj nebo nářadí musí změnit polohu, případně vybrat jinou soupravu.'
    parent.retryAt=(c.now or 0)+3600000
    parent.assemblyTryCourseplay=nil
    c:issue('assemblyLoop:'..parent.id,parent.label,parent.reason,97,'error')
    return true
end

function FMAAssembler.clearCircuit(c,parentId)
    if c and c.assemblyCircuits then c.assemblyCircuits[parentId]=nil end
end

local function tableHasAny(t)
    for _ in pairs(t or {}) do return true end
    return false
end

function FMAAssembler.toolSupports(task, tool)
    if not task or not tool or not tool.capabilities then return false end
    local op=task.operation
    local def=FMACatalog and FMACatalog.operations and FMACatalog.operations[op]
    local cap=def and def.cap or op
    if not tool.capabilities[cap] then return false end
    -- Capability from the transport payload does not make the carrier a work tool.
    -- Inspect the selected physical object's own FS25 specializations, not names.
    local object=tool.object
    if op=='harvest' and (not object or not object.spec_cutter) then return false end
    if (op=='fertilize' or op=='lime') and (not object or not (object.spec_sprayer or (op=='fertilize' and (object.spec_manureSpreader or object.spec_slurryTank)))) then return false end
    if op=='weed' and (not object or not (object.spec_weeder or object.spec_sprayer)) then return false end
    if op=='sow' and (not object or not object.spec_sowingMachine) then return false end
    if op=="harvest" and task.fruitIndex~=nil and tableHasAny(tool.harvestFruits) and tool.harvestFruits[task.fruitIndex]~=true then return false end
    if task.kind=="supply" and task.fillType~=nil then
        if FMAFleetCoordinator and FMAFleetCoordinator.supportsTransportFillType then
            if not FMAFleetCoordinator.supportsTransportFillType(tool,task.fillType) then return false end
        elseif tableHasAny(tool.transportFillTypes) and tool.transportFillTypes[task.fillType]~=true then return false end
    end
    return true
end

function FMAAssembler.findJointPair(attacher, attachable, farmId)
    if not attacher or not attachable or attacher.spec_attacherJoints==nil or attachable.spec_attachable==nil then return nil end
    local joints=FMAUtil.call(attacher,"getAttacherJoints") or (attacher.spec_attacherJoints and attacher.spec_attacherJoints.attacherJoints) or {}
    local inputs=FMAUtil.call(attachable,"getInputAttacherJoints") or (attachable.spec_attachable and attachable.spec_attachable.inputAttacherJoints) or {}
    for jointIndex,joint in ipairs(joints) do
        local attachingAllowed=FMAUtil.call(attacher,"getIsAttachingAllowed",joint)
        if attachingAllowed~=false and (joint.jointIndex==nil or joint.jointIndex==0) and not joint.isBlocked then
            for inputIndex,input in ipairs(inputs) do
                local compatible=joint.jointType~=nil and input.jointType~=nil and joint.jointType==input.jointType
                -- ModHub implements are not required to implement every optional compatibility
                -- callback exactly like base-game equipment.  Treat only an explicit FALSE as
                -- incompatible; nil/error falls back to the authoritative jointType match.
                if compatible and AttacherJoints and type(AttacherJoints.getAttacherJointCompatibility)=="function" then
                    local ok,result=pcall(AttacherJoints.getAttacherJointCompatibility,attacher,joint,attachable,input)
                    if ok and result==false then compatible=false end
                end
                if compatible then
                    local allowed=FMAUtil.call(attachable,"isAttachAllowed",farmId,attacher)
                    -- A header on an owned carrier may reject attach UNTIL it is
                    -- unmounted. For planning only, accept proven joint compatibility;
                    -- physical attach still goes through GIANTS' in-range detector.
                    local carrier=FMAUtil.call(attachable,'getDynamicMountObject') or attachable.tensionMountObject
                    if allowed~=false or (carrier and FMAUtil.owner(carrier)==farmId and attachable.spec_cutter) then
                        return jointIndex,inputIndex,joint,input
                    end
                end
            end
        end
    end
    return nil
end



function FMAAssembler.isPassiveAttachment(object)
    if not object then return true end
    if object.spec_weight~=nil then return true end
    local name=string.lower(FMAUtil.name(object) or "")
    if name:find("weight",1,true) or name:find("závaží",1,true) or name:find("ballast",1,true) then return true end
    return false
end

function FMAAssembler.hasBlockingAttachment(record,tool,task)
    if not record or not record.object then return true end
    -- A tractor can legitimately carry a front weight/blade while attaching a rear tool.
    -- If the target implement has a currently free compatible joint, another attachment
    -- on the opposite end is not a blocker. This is the important distinction between
    -- "tractor has something attached" and "the joint required by this tool is occupied".
    if tool and tool.object and FMAAssembler.findJointPair(record.object,tool.object,FMAUtil.owner(record.object)) then return false end
    for _,entry in pairs(FMAUtil.call(record.object,"getAttachedImplements") or {}) do
        local object=entry.object
        if object and not FMAAssembler.isPassiveAttachment(object) then
            if task and FMACatalog and FMACatalog.operations and FMACatalog.operations[task.operation] then
                local profile=FMAWorld.toolProfile(object)
                local cap=FMACatalog.operations[task.operation].cap
                if profile.capabilities and profile.capabilities[cap] then
                    -- This attachment is the work tool for the requested operation, not clutter.
                else return true end
            else return true end
        end
    end
    return false
end

local function jointNode(desc)
    if not desc then return nil end
    return desc.node or desc.jointTransform or desc.rootNode
end

local function nodeDirection(node)
    if not node or node==0 or not localDirectionToWorld then return nil,nil end
    local ok,dx,_,dz=pcall(localDirectionToWorld,node,0,0,1)
    if not ok or not dx or not dz then return nil,nil end
    local len=math.sqrt(dx*dx+dz*dz)
    if len<0.0001 then return nil,nil end
    return dx/len,dz/len
end

-- Couple to the real GIANTS hitch nodes, not vehicle/implement origins.
-- Probe both possible approach headings and two actual coupling distances.
-- A 2.7m clearance was too far for some joints even when GoTo reported success.
function FMAAssembler.alignmentCandidates(plan,settings)
    local result={}
    if not plan or not plan.power or not plan.tool then return result end
    local vehicle=plan.power.object
    local joint,input=plan.joint,plan.input
    if (not joint or not input) and vehicle and plan.tool.object then
        local _,_,j,i=FMAAssembler.findJointPair(vehicle,plan.tool.object,FMAUtil.owner(vehicle))
        joint=joint or j;input=input or i
    end
    local inNode=jointNode(input)
    local outNode=jointNode(joint)
    if vehicle and vehicle.rootNode and inNode and outNode and getWorldTranslation and worldToLocal and MathUtil and MathUtil.getYRotationFromDirection then
        local ok1,tx,_,tz=pcall(getWorldTranslation,inNode)
        local ok2,jx,jy,jz=pcall(getWorldTranslation,outNode)
        local dx,dz=nodeDirection(inNode)
        if ok1 and ok2 and tx and jx and dx then
            local ok3,lx,_,lz=pcall(worldToLocal,vehicle.rootNode,jx,jy,jz)
            if ok3 and lx and lz then
                -- The position is the tractor ROOT position needed to put its joint
                -- on the implement joint at the selected heading and stand-off.
                local preferredGap=math.min(2.0,math.max(1.2,(settings and settings.attachAlignmentOffset) or 1.8))
                local poses={}
                for _,sign in ipairs({1,-1}) do
                    local fx,fz=dx*sign,dz*sign
                    local rx0=tx-(fz*lx+fx*lz)
                    local rz0=tz-(-fx*lx+fz*lz)
                    -- This is a tractor-root pose with its REAL joint near the input joint.
                    -- Local negative-Z means a rear hitch: the last few metres MUST be driven
                    -- backwards. Previous versions always drove forwards and stopped 5-7 m away.
                    local reverse=lz < -0.25
                    local awayX,awayZ=reverse and fx or -fx,reverse and fz or -fz
                    for _,gap in ipairs({math.min(preferredGap,1.2),0.35}) do
                        poses[#poses+1]={x=rx0+awayX*gap,z=rz0+awayZ*gap,
                            angle=MathUtil.getYRotationFromDirection(fx,fz),toolX=tx,toolZ=tz,
                            mode=sign==1 and 'jointA' or 'jointB',hitchGap=gap,
                            reverse=reverse, localHitchZ=lz}
                    end
                end
                -- Retry the opposite approach before tightening the gap.
                for _,index in ipairs({1,3,2,4}) do
                    if poses[index] then result[#result+1]=poses[index] end
                end
            end
        end
    end
    local tx,tz=FMAAssembler.toolPoint(plan.tool,plan.inputIndex)
    local px,pz=FMAUtil.position(plan.power.object)
    if tx and px then
        local dx,dz=px-tx,pz-tz;local len=math.sqrt(dx*dx+dz*dz)
        if len<0.1 then dx,dz,len=0,1,1 end
        dx,dz=dx/len,dz/len
        local staging=math.max((settings and settings.assemblyStagingDistance) or 10.0,8.0)
        local x,z=tx+dx*staging,tz+dz*staging
        local angle=0
        if MathUtil and MathUtil.getYRotationFromDirection then angle=MathUtil.getYRotationFromDirection(tx-x,tz-z) end
        table.insert(result,1,{x=x,z=z,angle=angle,toolX=tx,toolZ=tz,mode='staging'})
    end
    return result
end

function FMAAssembler.powerFitsTool(power,tool)
    local required=tool and (tool.requiredPowerKW or 0) or 0
    local available=power and (power.powerKW or 0) or 0
    if required>0 and available>0 and available<required*1.05 then return false end
    return true
end

function FMAAssembler.pairScore(task,power,tool)
    local score=FMAUtil.distance(power,tool)+0.35*FMAUtil.distance(tool,task)
    score=score+(power.damage or 0)*80+(power.wear or 0)*25+(tool.damage or 0)*45+(tool.wear or 0)*15
    local required=tool.requiredPowerKW or 0
    local available=power.powerKW or 0
    if required>0 and available>0 then
        local reserve=(available-required)/math.max(required,1)
        score=score+math.abs(reserve-0.35)*20
    end
    local mass=power.mass or 0
    if task.operation=="plow" or task.operation=="cultivate" or task.operation=="stone" then score=score-math.min(mass,30)*0.7 end
    if (tool.workWidth or 0)>0 then score=score-math.min(tool.workWidth,18)*1.5 end
    return score
end
-- The same tractor must never be assigned to two unfinished assembly workflows.
-- Transient GIANTS GoTo jobs free their runtime reservation after each waypoint;
-- assembly ownership must outlive those individual AI jobs.
function FMAAssembler.leaseOwner(c,key)
    return c and c.assemblyLeases and c.assemblyLeases[key] or nil
end
function FMAAssembler.acquireLease(c,parent,plan)
    if not c or not parent or not plan or not plan.power or not plan.tool then return false end
    c.assemblyLeases=c.assemblyLeases or {}
    c.assemblyToolLeases=c.assemblyToolLeases or {}
    local owner=c.assemblyLeases[plan.power.key]
    local toolOwner=c.assemblyToolLeases[plan.tool.key]
    if (owner and owner~=parent.id) or (toolOwner and toolOwner~=parent.id) then return false end
    c.assemblyLeases[plan.power.key]=parent.id
    c.assemblyToolLeases[plan.tool.key]=parent.id
    return true
end
function FMAAssembler.releaseLease(c,parent,plan)
    if not c or not parent then return end
    local vehicleKey=plan and plan.power and plan.power.key or parent.preferredVehicleKey
    local toolKey=plan and plan.tool and plan.tool.key or parent.preferredImplementKey
    if c.assemblyLeases and vehicleKey and c.assemblyLeases[vehicleKey]==parent.id then c.assemblyLeases[vehicleKey]=nil end
    if c.assemblyToolLeases and toolKey and c.assemblyToolLeases[toolKey]==parent.id then c.assemblyToolLeases[toolKey]=nil end
end

function FMAAssembler.isPowerCandidate(controller, task, record, tool)
    if not record or not record.object or record.busy or record.lowFuel then return false end
    if FMAControlAuthority and controller.settings and controller.settings.enabled then
        local allowed=FMAControlAuthority.canStart(controller,record,task and task.id)
        if not allowed then return false end
    end
    if task and task.failedVehicleKeys and task.failedVehicleKeys[record.key] and task.ownerPinnedVehicle~=true then return false end
    if controller.excluded[record.key] or controller.reservations[record.key] then return false end
    if FMAAssembler.leaseOwner(controller,record.key) and FMAAssembler.leaseOwner(controller,record.key)~=task.id then return false end
    if tool and controller.assemblyToolLeases and controller.assemblyToolLeases[tool.key] and controller.assemblyToolLeases[tool.key]~=task.id then return false end
    if record.object.spec_attacherJoints==nil then return false end
    if task and task.ownerPinnedVehicle~=true and FMAWorld and FMAWorld.isAutoFieldPowerAllowed and not FMAWorld.isAutoFieldPowerAllowed(record,task.operation) then return false end
    if not FMAAssembler.powerFitsTool(record,tool) then return false end
    if task.operation=="harvest" then
        if record.isGrainCombine~=true then return false end
        return not FMAAssembler.hasBlockingAttachment(record,tool,task)
    end
    if task.operation=="foragePickup" and tool and tool.isPickupHeader then
        if record.hasCombine~=true then return false end
        return not FMAAssembler.hasBlockingAttachment(record,tool,task)
    end
    -- A tractor with another work implement already attached is not treated as a free
    -- power unit. Managed jobs return and detach their implement before re-use.
    if record.hasCombine then return false end
    if FMAAssembler.hasBlockingAttachment(record,tool,task) then return false end
    return true
end

function FMAAssembler.findPlan(controller, task)
    local best,bestScore
    for _,tool in ipairs(controller.loose or {}) do
        if not controller.implementReservations[tool.key] and FMAAssembler.toolSupports(task,tool) and (task.preferredImplementKey==nil or task.preferredImplementKey==tool.key) then
            for _,power in ipairs(controller.vehicles or {}) do
                if (task.preferredVehicleKey==nil or task.preferredVehicleKey==power.key) and FMAAssembler.isPowerCandidate(controller,task,power,tool) then
                    local jointIndex,inputIndex,joint,input=FMAAssembler.findJointPair(power.object,tool.object,controller.farmId)
                    if jointIndex then
                        local score=FMAAssembler.pairScore(task,power,tool)
                        if not best or score<bestScore then
                            best={power=power,tool=tool,jointIndex=jointIndex,inputIndex=inputIndex,joint=joint,input=input};bestScore=score
                        end
                    end
                end
            end
        end
    end
    if best then return best end
    if task.preferredVehicleKey or task.preferredImplementKey then return nil,"Vybraná kombinace stroje a nářadí není aktuálně kompatibilní / dostupná" end
    return nil,"Nenalezena kompatibilní volná kombinace tahače a odpojeného nářadí"
end

function FMAAssembler.hasPotentialForTask(controller, task)
    if not controller or not task or not task.operation then return false end
    local def=FMACatalog and FMACatalog.operations and FMACatalog.operations[task.operation]
    if not def then return false end
    -- A currently-ready complete machine counts even if it is busy; procurement must
    -- distinguish WAITING from BUYING.  Fruit/type checks are still enforced.
    for _,v in ipairs(controller.vehicles or {}) do
        if v.capabilities and v.capabilities[def.cap] then
            if task.operation~="harvest" or (v.isGrainCombine==true and (task.fruitIndex==nil or v.harvestFruits[task.fruitIndex]==true)) then return true end
        end
    end
    for _,tool in ipairs(controller.loose or {}) do
        if FMAAssembler.toolSupports(task,tool) then
            for _,v in ipairs(controller.vehicles or {}) do
                local typeOk=true
                if task.operation=="harvest" then typeOk=v.isGrainCombine==true
                elseif task.operation=="foragePickup" and tool.isPickupHeader then typeOk=v.hasCombine==true
                else typeOk=not v.hasCombine end
                if typeOk and v.object and v.object.spec_attacherJoints and FMAAssembler.powerFitsTool(v,tool)
                    and FMAAssembler.findJointPair(v.object,tool.object,controller.farmId) then return true end
            end
        end
    end
    return false
end

function FMAAssembler.hasPotential(controller, operation)
    return FMAAssembler.hasPotentialForTask(controller,{operation=operation,kind=operation=="supply" and "supply" or "field"})
end

function FMAAssembler.toolPoint(tool,inputIndex)
    local inputs=FMAUtil.call(tool.object,"getInputAttacherJoints") or (tool.object.spec_attachable and tool.object.spec_attachable.inputAttacherJoints) or {}
    local input=inputs[inputIndex or 1] or inputs[1]
    local node=jointNode(input)
    if node and node~=0 and getWorldTranslation then
        local ok,x,_,z=pcall(getWorldTranslation,node)
        if ok then return x,z end
    end
    return FMAUtil.position(tool.object)
end

function FMAAssembler.approachPoint(power,tool,settings,plan,attempt)
    local p=plan or {power=power,tool=tool}
    local candidates=FMAAssembler.alignmentCandidates(p,settings)
    if #candidates==0 then return nil end
    local index=math.max(1,math.min(#candidates,attempt or 1))
    local point=candidates[index]
    point.candidateIndex=index;point.candidateCount=#candidates
    return point
end

-- Coarse yard staging is deliberately broader than the final hitch alignment.
-- One side of an implement can be against a wall, shed or another machine; the
-- base-game helper should get several legal approach choices before the task is
-- declared blocked. Precise coupling still happens only through joint geometry.
function FMAAssembler.stagingCandidates(plan,settings)
    local result,seen={},{}
    if not plan or not plan.tool then return result end
    local tx,tz
    if plan.tool.object then tx,tz=FMAAssembler.toolPoint(plan.tool,plan.inputIndex) else tx,tz=plan.tool.x,plan.tool.z end
    if not tx then return result end
    local staging=math.max((settings and settings.assemblyStagingDistance) or 10.0,9.0)
    local function add(x,z,label)
        local key=string.format('%.1f:%.1f',x,z)
        if seen[key] then return end
        seen[key]=true
        local angle=0
        if MathUtil and MathUtil.getYRotationFromDirection then angle=MathUtil.getYRotationFromDirection(tx-x,tz-z) end
        result[#result+1]={x=x,z=z,angle=angle,toolX=tx,toolZ=tz,mode='staging',label=label}
    end
    -- Aim the staging tractor along the same COUPLING axis as the precision pass.
    -- The old staging angle always pointed *towards* the tool, even when a rear
    -- drawbar needs the tractor to face away and reverse. Do not set such a pose.
    local aligned=(plan.tool.object and plan.power and plan.power.object) and FMAAssembler.alignmentCandidates(plan,settings) or {}
    for _,pose in ipairs(aligned) do
        if pose.mode~='staging' and pose.localHitchZ~=nil then
            local fx,fz=MathUtil.getDirectionFromYRotation(pose.angle)
            local reverse=pose.reverse==true
            local side=reverse and 1 or -1
            local x,z=pose.x+fx*side*staging,pose.z+fz*side*staging
            local key=string.format('%.1f:%.1f',x,z)
            if not seen[key] then
                seen[key]=true
                result[#result+1]={x=x,z=z,angle=pose.angle,toolX=tx,toolZ=tz,
                    mode='staging',label=reverse and 'rearJoint' or 'frontJoint',reverse=reverse}
            end
        end
    end
    -- Fallback for aftermarket models where no valid joint-transform is available.
    local input=plan.input
    local inNode=jointNode(input)
    local fx,fz=nodeDirection(inNode)
    if fx and fz then
        local px,pz
        if plan.power and plan.power.object then px,pz=FMAUtil.position(plan.power.object) end
        local side=1
        if px then
            local dot=(px-tx)*fx+(pz-tz)*fz
            if dot<0 then side=-1 end
        end
        for _,sign in ipairs({side,-side}) do
            add(tx+fx*sign*staging,tz+fz*sign*staging,'hitchAxis')
            add(tx+fx*sign*(staging+8),tz+fz*sign*(staging+8),'hitchAxisFar')
        end
    end
    -- Only after joint-aligned goals probe alternative sectors of the yard.
    local px,pz
    if plan.power then
        if plan.power.object then px,pz=FMAUtil.position(plan.power.object) else px,pz=plan.power.x,plan.power.z end
    end
    if px then
        local dx,dz=px-tx,pz-tz;local len=math.sqrt(dx*dx+dz*dz)
        if len<0.1 then dx,dz,len=0,1,1 end
        add(tx+dx/len*staging,tz+dz/len*staging,'currentSide')
    end
    for i=0,7 do
        local a=i*math.pi/4
        add(tx+math.sin(a)*staging,tz+math.cos(a)*staging,'ring'..tostring(i+1))
    end
    return result
end

-- Written to Alt+D TRACE: exact coupling distances and which real object
-- GIANTS considers in reach. No remote attachment or fake success.
function FMAAssembler.jointDistance(plan)
    if not plan then return nil end
    local a=jointNode(plan.joint);local b=jointNode(plan.input)
    if not a or not b or not getWorldTranslation then return nil end
    local oka,x,y,z=pcall(getWorldTranslation,a)
    local okb,tx,ty,tz=pcall(getWorldTranslation,b)
    if not oka or not okb or not x or not tx then return nil end
    return math.sqrt((x-tx)^2+(y-ty)^2+(z-tz)^2)
end

function FMAAssembler.hitchEvent(c,name,plan,detail)
    if not c or not plan then return end
    local d=FMAAssembler.jointDistance(plan)
    local message=tostring(detail or '-')..' | jointDistance='..(d and string.format('%.2fm',d) or 'unknown')
    if FMADiagnostics then FMADiagnostics.event(c,'hitch.'..name,plan.power and plan.power.name or '?',message) end
    if FMAUtil and FMAUtil.log and (name=='failed' or name=='confirmed') then
        FMAUtil.log('HITCH '..name..' '..tostring(plan.tool and plan.tool.name)..' · '..message)
    end
end

function FMAAssembler.attach(controller,plan)
    local vehicle=plan.power.object
    local target=plan.tool.object
    if not vehicle or not target or FMAUtil.owner(vehicle)~=controller.farmId or FMAUtil.owner(target)~=controller.farmId then return false,"Změnilo se vlastnictví soupravy" end
    if (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle))==true or FMAUtil.call(vehicle,"getIsAIActive")==true then return false,"Tahač právě někdo ovládá" end
    if FMAUtil.call(target,"getActiveInputAttacherJointDescIndex")~=nil then return false,"Nářadí už bylo připojeno jinam" end
    local mounted=FMAUtil.call(target,"getDynamicMountObject") or target.tensionMountObject
    if mounted then
        if FMAUtil.owner(mounted)~=controller.farmId then return false,"Nářadí je zajištěné na cizím podvozku" end
        -- Do not drop/unmount a header from an arbitrary location in the yard.
        -- The normal FS joint nodes must be physically near each other FIRST.
        local _,_,joint,input=FMAAssembler.findJointPair(vehicle,target,controller.farmId)
        local aNode=joint and (joint.node or joint.jointTransform or joint.rootNode)
        local iNode=input and (input.node or input.jointTransform or input.rootNode)
        if not aNode or not iNode or not getWorldTranslation then
            return false,"Nelze ověřit polohu závěsů před uvolněním adaptéru z podvozku"
        end
        local oka,ax,ay,az=pcall(getWorldTranslation,aNode)
        local oki,ix,iy,iz=pcall(getWorldTranslation,iNode)
        if not oka or not oki or not ax or not ix then
            return false,"Poloha závěsu adaptéru není dostupná"
        end
        local distanceSq=(ax-ix)^2+(ay-iy)^2+(az-iz)^2
        if distanceSq>3.0*3.0 then
            return false,"Adaptér je na podvozku; nejdřív je nutné skutečně přistavit kombajn k závěsu"
        end
        if not FMAHeaderTransport or not FMAHeaderTransport.releaseCarrierLoad then
            return false,"Chybí bezpečné uvolnění adaptéru z podvozku"
        end
        FMAHeaderTransport.releaseCarrierLoad(target,mounted)
        if FMAUtil.call(target,'getDynamicMountObject')==mounted or target.tensionMountObject==mounted then
            return false,"FS25 zatím nepotvrdilo uvolnění adaptéru z podvozku"
        end
    end

    -- Prefer the same in-range detector and attach path the base game uses for the ATTACH action.
    if AttacherJoints and type(AttacherJoints.updateVehiclesInAttachRange)=="function" and vehicle.spec_attacherJoints then
        local maxDist=(AttacherJoints.MAX_ATTACH_DISTANCE_SQ or 9)
        local maxAngle=(AttacherJoints.MAX_ATTACH_ANGLE or 0.5)
        local ok,a,j,tool,input=pcall(AttacherJoints.updateVehiclesInAttachRange,vehicle,maxDist,maxAngle,true)
        if not ok then
            FMAAssembler.hitchEvent(controller,'detectorError',plan,tostring(a))
        elseif a and tool and tool~=target then
            FMAAssembler.hitchEvent(controller,'wrongTarget',plan,'GIANTS detects '..FMAUtil.name(tool)..' instead of selected '..FMAUtil.name(target))
        elseif a and tool==target then
            -- The returned attacher may be a child of the chosen tractor (e.g.
            -- frontend adapter). That is valid only if physically in its tree.
            if a~=vehicle and not FMAWorld.containsObject(vehicle,a) then
                return false,'GIANTS vybralo závěs jiného vozidla'
            end
            local info={attacherVehicle=a,attacherVehicleJointDescIndex=j,attachable=tool,attachableJointDescIndex=input}
            local allowed,reason=FMAUtil.call(tool,'isAttachAllowed',controller.farmId,a)
            if allowed==false then
                FMAAssembler.hitchEvent(controller,'notAllowed',plan,tostring(reason))
            else
                local attached=FMAUtil.call(a,'attachImplementFromInfo',info)
                if attached==true then
                    plan.attachRequested=true
                    FMAAssembler.hitchEvent(controller,'requested',plan,'GIANTS attachImplementFromInfo accepted; awaiting physical confirmation')
                    return true
                end
                FMAAssembler.hitchEvent(controller,'rejected',plan,'FS25 attachImplementFromInfo returned '..tostring(attached))
            end
        end
    end

    -- Never force a remote or misaligned attachment: use the game's actual
    -- angle/distance/compatibility detector, not tractor-centre distance.
    FMAAssembler.hitchEvent(controller,'failed',plan,'FS25 did not detect selected tool inside safe attach angle/distance')
    local distance=FMAAssembler.jointDistance(plan)
    return false,'FS25 nenašlo zvolené nářadí v bezpečném dosahu závěsu'..(distance and string.format(' (závěsy %.2f m)',distance) or ' (pozice závěsů není dostupná)')

end

function FMAAssembler.startDrive(controller,parent,plan,attempt)
    if FMAReturnManager then FMAReturnManager.rememberAssembly(controller,parent,plan) end
    attempt=attempt or 1
    local circuit=assemblyCircuit(controller,parent,plan)
    if circuit.halted then return false,'Nájezd pozastaven po opakovaném skutečném zastavení vozidla' end
    local point
    if attempt==1 then
        local staging=FMAAssembler.stagingCandidates(plan,controller.settings)
        local cursor=math.max(1,math.min(parent.stagingCandidateCursor or 1,#staging))
        point=staging[cursor]
        if point then point.candidateIndex=cursor;point.candidateCount=#staging end
    else
        point=FMAAssembler.approachPoint(plan.power,plan.tool,controller.settings,plan,attempt)
    end
    if not point then return false,"Nelze určit místo odpojeného nářadí" end
    local trafficTask={id="assemble:"..parent.id,kind="assemble",operation=parent.operation,parentTaskId=parent.id}
    if FMATraffic and FMATraffic.canStart then
        local free,wait=FMATraffic.canStart(controller,plan.power,point,trafficTask,30000)
        if not free then
            parent.state="pending";parent.phase="ČEKÁ NA PROVOZ";parent.reason=wait;parent.retryAt=controller.now+((controller.settings.trafficRetrySeconds or 6)*1000)
            return true,wait
        end
    end
    local vehicle=plan.power.object
    -- Do not even start a motor when the player or another worker owns the cab.
    -- This gate is intentionally BEFORE the proactive motor request below.
    if (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle))==true or
            FMAUtil.call(vehicle,'getIsAIActive')==true then
        if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end
        return false,'Tahač právě řídí majitel nebo jiný pracovník'
    end
    local precise=point.mode~="staging"
    if precise and point.reverse==nil then
        return false,'Chybí ověřená geometrie závěsu · přesný nájezd bez směru jízdy je nebezpečný'
    end
    -- A GIANTS GoTo rejection in the yard is not proof that all roads to the
    -- implement are blocked. Retry that SAME safe staging candidate only once
    -- with Courseplay's independent transfer planner before testing other poses.
    -- This never changes hitch geometry, teleports equipment or bypasses CP checks.
    if FMAControlAuthority then
        local allowed,reason=FMAControlAuthority.canStart(controller,plan.power,
            'assemble:'..tostring(parent.id))
        if not allowed then return false,reason end
    end
    local cpStagingRetry=not precise and parent.assemblyTryCourseplay==true
    parent.assemblyTryCourseplay=nil
    local transferTarget={x=point.x,z=point.z,angle=point.angle or 0,
        tolerance=precise and 1.35 or 5.0,
        probeRadius=precise and nil or math.max(14,(controller.settings.assemblyStagingDistance or 10)+6),
        directApproach=precise,preferCourseplay=cpStagingRetry,
        recoveryReverse=precise and point.reverse==true,
        couplingToolKey=precise and plan.tool.key or nil}
    -- Request the engine BEFORE validating a transfer job. Some CP/GIANTS
    -- configurations reject the job's startable state when the motor is off.
    -- Never assume that calling startMotor means it has actually started.
    if type(vehicle.startMotor)=='function' and FMAUtil.call(vehicle,'getIsMotorStarted')~=true then
        if FMAUtil.call(vehicle,'getCanMotorRun')==false then
            if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end
            FMAAssembler.hitchEvent(controller,'failed',plan,'Motor traktoru nelze nastartovat')
            return false,'Motor vybraného traktoru nelze nastartovat; zkontroluj palivo a stav stroje'
        end
        local motorOk,motorReason=pcall(vehicle.startMotor,vehicle,true)
        if FMADiagnostics then FMADiagnostics.event(controller,'hitch.motorRequest',plan.power.name,tostring(motorOk)..' '..tostring(motorReason)) end
        if not motorOk then
            if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end
            return false,'FS25 odmítlo nastartovat traktor: '..tostring(motorReason)
        end
    end
    -- Third driver: GIANTS and Courseplay retain global navigation. If the tractor
    -- is already near the exact hitch pose and their previous approach failed,
    -- FarmManagerAI physically drives the LAST metres itself via wheel physics.
    -- It never takes control of an AI job, a player vehicle or a distant tractor.
    if precise and attempt>=2 and FMAOwnDriver and FMAOwnDriver.available(vehicle) then
        local vx,vz=FMAUtil.position(vehicle)
        local near=vx and math.sqrt((vx-point.x)^2+(vz-point.z)^2)<=14
        if near then
            if not FMAAssembler.acquireLease(controller,parent,plan) then
                if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end
                return false,'Soupravu právě připravuje jiná zakázka'
            end
            local task={id='assemble:'..parent.id,kind='assemble',operation=parent.operation,
                parentTaskId=parent.id,alignmentMode=point.mode,
                assemblyAttempt=attempt,toolKey=plan.tool.key}
            local active={task=task,vehicle=plan.power,assemblyPlan=plan,
                trafficTarget=point,transferMethod='FMA_PHYSICAL_DRIVER',start=controller.now}
            local id='ownHitch:'..parent.id
            local ok,sessionOrWhy=FMAOwnDriver.begin(controller,plan.power,{
                id=id,kind='hitch',toolKey=plan.tool.key,
                goal={x=point.x,z=point.z,reverse=point.reverse==true},
                tolerance=1.2,maxDistance=15,speed=2.2,maxDuration=48000,
                onDone=function(c,session,arrived,reason)
                    if FMATraffic then FMATraffic.release(c.traffic,plan.power.key) end
                    if not c.settings.enabled or (FMAGameNative and FMAGameNative.isManuallyControlled(vehicle)) then
                        FMAAssembler.releaseLease(c,parent,plan)
                        parent.state='pending';parent.phase='POZASTAVENO HRÁČEM'
                        parent.reason=tostring(reason)
                        return
                    end
                    active.stopReason=arrived and nil or 'ASSEMBLY_RETRY'
                    FMAAssembler.hitchEvent(c,arrived and 'ownArrival' or 'ownFailed',plan,reason)
                    FMAAssembler.onStopped(c,active,nil)
                end})
            if ok then
                parent.state='assembling';parent.phase='VLASTNÍ ŘIDIČ · FYZICKÉ ZAPŘAHÁNÍ'
                parent.reason=plan.power.name..' fyzicky '..(point.reverse and 'couvá' or 'najíždí')..' k '..plan.tool.name
                FMAAssembler.hitchEvent(controller,'ownDriver',plan,'přesný manévr '..tostring(attempt))
                return true
            end
            FMAAssembler.releaseLease(controller,parent,plan)
            if FMADiagnostics then FMADiagnostics.event(controller,'hitch.ownRejected',parent.id,tostring(sessionOrWhy)) end
            -- When the local physics manoeuvre cannot safely start, let the
            -- established GIANTS/CP engine try this goal; never force the tractor.
        end
    end
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,plan.power,transferTarget)
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end;return false,moveWhy or "Tahač nemůže dojet k nářadí" end
    if not FMAAssembler.acquireLease(controller,parent,plan) then
        if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end
        return false,'Vybraný stroj nebo nářadí už dokončuje jinou zakázku'
    end

    local task={id="assemble:"..parent.id,kind="assemble",operation=parent.operation,label="Příprava soupravy · "..parent.label,
        state="running",parentTaskId=parent.id,toolKey=plan.tool.key,toolName=plan.tool.name,jointIndex=plan.jointIndex,inputIndex=plan.inputIndex,
        x=point.x,z=point.z,priority=(parent.priority or 50)+10,assemblyAttempt=attempt,
        alignmentMode=point.mode,stagingCpAttempt=cpStagingRetry,candidateIndex=point.candidateIndex}
    parent.preferredVehicleKey=parent.preferredVehicleKey or plan.power.key
    parent.preferredVehicleName=parent.preferredVehicleName or plan.power.name
    parent.preferredImplementKey=parent.preferredImplementKey or plan.tool.key
    parent.preferredImplementName=parent.preferredImplementName or plan.tool.name
    parent.state="assembling";parent.phase="PŘÍPRAVA SOUPRAVY · ZAPŘAŽENÍ";parent.reason="Tahač "..plan.power.name.." jede pro nářadí "..plan.tool.name.." · nájezd "..attempt.."/"..point.candidateCount
    controller.reservations[plan.power.key]=task.id
    controller.implementReservations[plan.tool.key]=task.id
    plan.power.busy=true
    local sx,sz=FMAUtil.position(plan.power.object)
    controller.active[job]={job=job,task=task,vehicle=plan.power,assemblyPlan=plan,start=controller.now,lastProgress=controller.now,x=plan.power.x,z=plan.power.z,fill=plan.power.fillTotal,trafficTarget=point,transferMethod=moveMethod,dispatchVerified=false,
        startPosition=(sx and sz) and {x=sx,z=sz} or nil}
    FMAAssembler.hitchEvent(controller,'driveRequested',plan,'mode='..tostring(point.mode)..' reverse='..tostring(point.reverse==true)..' gap='..tostring(point.hitchGap)..' attempt='..tostring(attempt)..' method='..tostring(moveMethod))
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not ok then
        controller.active[job]=nil;controller.reservations[plan.power.key]=nil;controller.implementReservations[plan.tool.key]=nil;plan.power.busy=false
        if FMATraffic then FMATraffic.release(controller.traffic,plan.power.key) end
        FMAAssembler.releaseLease(controller,parent,plan)
        parent.state="pending";parent.reason=tostring(err);parent.retryAt=controller.now+15000
        return false,tostring(err)
    end
    controller:notify(plan.power.name.." · odeslán přejezd pro "..plan.tool.name.." · čeká na potvrzení FS25")
    return true
end

function FMAAssembler.dispatch(controller,parent)
    if not controller.settings.autoAssemble then return false,"Automatické zapřahání je vypnuté" end
    -- Capture the detached tool's REAL home before any hitch action moves it.
    if FMAReturnManager then FMAReturnManager.captureHomes(controller) end
    if not FMAJobs.mayStart(controller,"assemble:"..parent.id) then return false,"Zapřažení čeká po chybě; Alt+R obnoví pokus" end
    local plan,why=FMAAssembler.findPlan(controller,parent)
    if not plan then return false,why end
    local circuit=assemblyCircuit(controller,parent,plan)
    if circuit.halted then
        parent.state='blocked';parent.phase='STROJ STOJÍ · ČEKÁ NA ZMĚNU POLOHY'
        parent.reason='Předchozí bezvýsledné nájezdy stejné soupravy. Další příkaz až po skutečné změně pozice.'
        return false,parent.reason
    end
    local distance=FMAUtil.distance(plan.power,plan.tool)
    if distance<=(controller.settings.autoAttachMaxDistance or 6.0) then
        local ok,reason=FMAAssembler.attach(controller,plan)
        if ok then
            if not FMAAssembler.acquireLease(controller,parent,plan) then return false,'Soupravu právě připravuje jiná zakázka' end
            if FMAReturnManager then FMAReturnManager.rememberAssembly(controller,parent,plan) end
            FMAAssembler.confirm(controller,parent,plan)
            return true
        end
        -- Do not give up on a nearby but misaligned tool: let GoTo reposition once.
        FMAUtil.log("Přímé zapřažení zatím nevyšlo: "..tostring(reason))
    end
    return FMAAssembler.startDrive(controller,parent,plan,parent.assemblyAttempt)
end

-- Switch only after the outgoing tractor has been stopped and its real
-- lease released. Keep the SAME loose implement; never steal a reserved tool.
-- The player's explicitly selected tractor is never replaced automatically.
function FMAAssembler.tryAlternatePower(controller,parent,plan)
    if not controller or not parent or not plan or not plan.power or not plan.tool
        or parent.ownerPinnedVehicle==true or parent.futurePrep==true then return false end
    if (parent.assemblyPowerFailovers or 0)>=2 then return false end
    local oldKey,oldName=parent.preferredVehicleKey,parent.preferredVehicleName
    local oldToolKey,oldToolName=parent.preferredImplementKey,parent.preferredImplementName
    local rejected=parent.failedVehicleKeys or {}
    local previousFlag=rejected[plan.power.key]
    parent.failedVehicleKeys=rejected
    rejected[plan.power.key]=true
    parent.preferredVehicleKey=nil;parent.preferredVehicleName=nil
    parent.preferredImplementKey=plan.tool.key;parent.preferredImplementName=plan.tool.name
    local alternative=FMAAssembler.findPlan(controller,parent)
    if alternative and alternative.power and alternative.power.key~=plan.power.key then
        parent.assemblyPowerFailovers=(parent.assemblyPowerFailovers or 0)+1
        parent.assemblyAttempt=1;parent.stagingCandidateCursor=1
        parent.assemblyTryCourseplay=nil
        parent.preferredVehicleKey=alternative.power.key
        parent.preferredVehicleName=alternative.power.name
        parent.state='pending';parent.phase='NÁHRADNÍ TRAKTOR K NÁŘADÍ'
        parent.reason='Nájezdy stroje '..tostring(plan.power.name)..' selhaly; prověřuji jiný kompatibilní volný traktor '..tostring(alternative.power.name)
        parent.retryAt=(controller.now or 0)+math.max(4000,(controller.settings.attachRetryDelaySeconds or 4)*1000)
        if FMADiagnostics then FMADiagnostics.event(controller,'assembly.powerFailover',parent.id,
            tostring(plan.power.name)..' -> '..tostring(alternative.power.name)) end
        return true
    end
    -- No verified alternative: leave the existing operator choice intact and
    -- report a genuine blockage instead of entering a re-selection loop.
    parent.preferredVehicleKey=oldKey;parent.preferredVehicleName=oldName
    parent.preferredImplementKey=oldToolKey;parent.preferredImplementName=oldToolName
    rejected[plan.power.key]=previousFlag
    return false
end

-- Give the physically controlled third driver a chance only when a native / CP
-- staging attempt has conclusively failed and the tractor really faces a nearby
-- joint-aligned pose. Far-off targets and badly oriented tractors stay with pathfinders.
function FMAAssembler.trySafeLocalRescue(c,parent,plan)
    if not FMAOwnDriver or not FMAOwnDriver.available or FMAOwnDriver.available(plan.power.object)~=true then return false end
    local circuit=assemblyCircuit(c,parent,plan)
    if circuit.halted or (circuit.failures or 0)<2 then return false end
    local point=FMAAssembler.approachPoint(plan.power,plan.tool,c.settings,plan,2)
    if not point or point.reverse==nil then return false end
    local v=plan.power.object
    local x,z=FMAUtil.position(v)
    if not x or math.sqrt((point.x-x)^2+(point.z-z)^2)>11 then return false end
    if FMAUtil.call(v,'getIsAIActive')==true or (FMAGameNative and FMAGameNative.isManuallyControlled(v))==true then return false end
    if type(localDirectionToWorld)~='function' then return false end
    local ok,fx,_,fz=pcall(localDirectionToWorld,v.rootNode,0,0,1)
    if not ok or not fx then return false end
    local dx,dz=point.x-x,point.z-z
    local length=math.sqrt(dx*dx+dz*dz)
    if length<=0.05 then return false end
    local dot=(fx*dx+fz*dz)/length
    if point.reverse then dot=-dot end
    if dot<0.75 then
        if FMADiagnostics then FMADiagnostics.event(c,'assembly.ownNotAligned',parent.id,'směr '..string.format('%.2f',dot)..' · fyzický manévr nepovolen') end
        return false
    end
    if FMADiagnostics then FMADiagnostics.event(c,'assembly.tryOwnRescue',parent.id,'bezpečný místní cíl '..string.format('%.1fm',length)) end
    local started=FMAAssembler.startDrive(c,parent,plan,2)
    return started==true
end

function FMAAssembler.onStopped(controller,active,message)
    local plan=active.assemblyPlan
    local parent=controller.tasks[active.task.parentTaskId] or (controller.futureTasks and controller.futureTasks[active.task.parentTaskId])
    if not plan or not parent then
        if plan and plan.tool then controller.implementReservations[plan.tool.key]=nil end
        return
    end
    if active.stopReason then
        if FMAAssembler.observeApproach(controller,parent,plan,active,active.stopReason) then return end
        -- Current AI has stopped, it is safe to try the OWN driver when close.
        if active.task.alignmentMode=='staging' and FMAAssembler.trySafeLocalRescue(controller,parent,plan) then return end
        controller.implementReservations[plan.tool.key]=nil
        parent.preferredVehicleKey=plan.power.key;parent.preferredVehicleName=plan.power.name
        parent.preferredImplementKey=plan.tool.key;parent.preferredImplementName=plan.tool.name

        -- Failure of a coarse FS25 GoTo staging point says nothing about the tractor
        -- or implement. Rotate around the same implement before attempting precision.
        if active.task.alignmentMode=='staging' then
            -- Only a confirmed navigation failure qualifies for an alternate
            -- path engine. A busy/permission/start rejection must not be
            -- mistaken for a tree or blocked road.
            local method=tostring(active.transferMethod or '')
            local native=method:find('GIANTS',1,true)~=nil
            local navFault=FMAJobs and FMAJobs.isNavigationEvidence
                and FMAJobs.isNavigationEvidence(active,active.stopReason)==true
            if native and navFault and active.task.stagingCpAttempt~=true then
                parent.assemblyTryCourseplay=true
                parent.state=parent.futurePrep and 'future' or 'pending'
                parent.phase='NÁHRADNÍ NÁJEZD · COURSEPLAY'
                parent.reason='GIANTS označil nájezd za nedosažitelný · zkouším stejné bezpečné místo přes Courseplay'
                parent.retryAt=(controller.now or 0)+math.max(4000,(controller.settings.attachRetryDelaySeconds or 4)*1000)
                if FMADiagnostics then FMADiagnostics.event(controller,'assembly.cpFallback',parent.id,method) end
                return
            end
            parent.assemblyTryCourseplay=nil
            local staging=FMAAssembler.stagingCandidates(plan,controller.settings)
            local nextCursor=(active.task.candidateIndex or parent.stagingCandidateCursor or 1)+1
            parent.stagingCandidateCursor=nextCursor
            if nextCursor<=math.min(#staging,controller.settings.fieldStageAttempts or 5) then
                parent.assemblyAttempt=1
                parent.state=parent.futurePrep and 'future' or 'pending'
                parent.phase='HLEDÁ SJÍZDNOU STRANU NÁŘADÍ'
                parent.reason='Tento nástupní bod není dosažitelný · zkouší se jiná strana stejného nářadí'
                parent.retryAt=controller.now+(controller.settings.attachRetryDelaySeconds or 4)*1000
            else
                FMAAssembler.releaseLease(controller,parent,plan)
                if FMAAssembler.tryAlternatePower(controller,parent,plan) then return end
                parent.state='blocked';parent.phase='BLOKACE PŘÍJEZDU K NÁŘADÍ' 
                parent.reason='FS25 nenašlo sjízdný bezpečný nástup k nářadí z více stran; souprava zůstává beze změny'
                controller:issue(parent.id,parent.label,parent.reason,parent.priority)
            end
            return
        end

        -- Precision approach can likewise try the alternate joint pose, but never a
        -- different tractor merely because the yard geometry is difficult.
        if active.stopReason=='ASSEMBLY_RETRY' or active.stopReason=='RECOVERY_REROUTE' then
            local nextAttempt=(active.task.assemblyAttempt or 1)+1
            local maxAttempts=math.min(#FMAAssembler.alignmentCandidates(plan,controller.settings),math.max(2,math.min(3,controller.settings.attachPrecisionAttempts or 3)))
            parent.assemblyAttempt=nextAttempt
            if nextAttempt<=maxAttempts then
                parent.state=parent.futurePrep and 'future' or 'pending'
                parent.phase='OPRAVNÝ NÁJEZD · STEJNÁ SOUPRAVA'
                parent.reason='Přejezd nedojel na závěs · další pozice stejného nářadí (max. 3 pokusy)'
                parent.retryAt=controller.now+(controller.settings.attachRetryDelaySeconds or 4)*1000
            else
                FMAAssembler.releaseLease(controller,parent,plan)
                if FMAAssembler.tryAlternatePower(controller,parent,plan) then return end
                parent.state='blocked';parent.phase='BLOKACE ZAPŘAŽENÍ' 
                parent.reason='Stejná souprava vyčerpala bezpečné přesné nájezdy; vyžaduje ruční srovnání nebo jiné stání nářadí'
                controller:issue(parent.id,parent.label,parent.reason,parent.priority)
            end
            return
        end
        FMAAssembler.releaseLease(controller,parent,plan)
        parent.state="blocked";parent.phase="BLOKACE";parent.reason=active.stopReason
        controller:issue(parent.id,parent.label,parent.reason,parent.priority)
        return
    end
    -- GIANTS stopping a transfer job is not proof of physical arrival. A false
    -- "success" would otherwise trigger the next phase or attempt an attach remotely.
    local px,pz=FMAUtil.position(plan.power.object)
    if px and pz and active.trafficTarget and active.trafficTarget.x then
        local target=active.trafficTarget
        local delta=math.sqrt((px-target.x)^2+(pz-target.z)^2)
        local maxGap=(active.task.alignmentMode=='staging') and 8.0 or 3.0
        if delta>maxGap then
            if FMAAssembler.observeApproach(controller,parent,plan,active,'FALEŠNÉ DOKONČENÍ PŘEJEZDU '..string.format('%.1fm',delta)) then return end
            if active.task.alignmentMode=='staging' and FMAAssembler.trySafeLocalRescue(controller,parent,plan) then return end
            controller.implementReservations[plan.tool.key]=nil
            if active.task.alignmentMode=='staging' then
                local count=#FMAAssembler.stagingCandidates(plan,controller.settings)
                parent.stagingCandidateCursor=math.min(count,(active.task.candidateIndex or parent.stagingCandidateCursor or 1)+1)
                parent.assemblyTryCourseplay=nil
            else
                parent.assemblyAttempt=(active.task.assemblyAttempt or 1)+1
            end
            parent.state='pending';parent.phase='PŘEJEZD K NÁŘADÍ NEBYL DOKONČEN'
            parent.reason=string.format('FS25 ukončilo přejezd %.1f m od cíle; zapřažení se neprovádí',delta)
            parent.retryAt=controller.now+(controller.settings.attachRetryDelaySeconds or 4)*1000
            FMAAssembler.hitchEvent(controller,'arrivalUnverified',plan,parent.reason)
            return
        end
    end
    -- Reaching the coarse staging point is not an attachment failure. Continue with
    -- a precision hitch pose, so recovery does not rotate through random tractors.
    if active.task.alignmentMode=="staging" then
        parent.stagingCandidateCursor=1
        parent.assemblyTryCourseplay=nil
        parent.assemblyAttempt=2
        local started,stageWhy=FMAAssembler.startDrive(controller,parent,plan,2)
        if started then return end
        controller.implementReservations[plan.tool.key]=nil
        parent.state="pending";parent.phase="PŘESNÝ NÁJEZD";parent.reason=stageWhy or "Nelze zahájit přesný nájezd k nářadí"
        parent.retryAt=controller.now+(controller.settings.attachRetryDelaySeconds or 4)*1000
        return
    end
    local ok,why=FMAAssembler.attach(controller,plan)
    if ok then
        if parent.futurePrep and FMAFarmBrain and FMAFarmBrain.onFutureAssemblyConfirmed then
            FMAAssembler.confirm(controller,parent,plan,function()FMAFarmBrain.onFutureAssemblyConfirmed(controller,parent,plan) end,true,'futureAttach:'..parent.id,function(reason)FMAFarmBrain.onFutureAssemblyFailed(controller,parent,plan,reason) end)
        else FMAAssembler.confirm(controller,parent,plan) end
        return
    end
    controller.implementReservations[plan.tool.key]=nil
    local nextAttempt=(active.task.assemblyAttempt or 1)+1
    parent.assemblyAttempt=nextAttempt
    parent.preferredVehicleKey=plan.power.key;parent.preferredImplementKey=plan.tool.key
    if nextAttempt<=math.min(#FMAAssembler.alignmentCandidates(plan,controller.settings),math.max(2,math.min(3,controller.settings.attachPrecisionAttempts or 3))) then
        parent.state=parent.futurePrep and "future" or "pending";parent.phase="OPRAVNÝ NÁJEZD";parent.reason=why
        parent.retryAt=controller.now+(controller.settings.attachRetryDelaySeconds or 4)*1000
    else
        if parent.futurePrep and FMAFarmBrain and FMAFarmBrain.onFutureAssemblyFailed then
            FMAFarmBrain.onFutureAssemblyFailed(controller,parent,plan,"Zapřažení se nepotvrdilo: "..tostring(why))
        else
            FMAJobs.fail(controller,active.task,active.vehicle,"Zapřažení: "..tostring(why))
            FMAAssembler.releaseLease(controller,parent,plan)
            parent.state="blocked";parent.reason="Zapřažení se nepotvrdilo: "..tostring(why)
            controller:issue(parent.id,parent.label,parent.reason,parent.priority)
        end
    end
end

function FMAAssembler.confirm(c,parent,plan,onConfirmed,preserveParentState,sessionId,onFailed)
    c.attachSessions=c.attachSessions or {}
    c.attachSessions[sessionId or parent.id]={parent=parent,plan=plan,start=c.now,onConfirmed=onConfirmed,onFailed=onFailed,preserveParentState=preserveParentState==true}
    if not preserveParentState then parent.state='assembling';parent.reason='Kontrola dokončení zapřažení' end
    c.reservations[plan.power.key]=parent.id;c.implementReservations[plan.tool.key]=parent.id
    plan.power.busy=true
end

function FMAAssembler.update(c)
    for vehicleKey,taskId in pairs(c.assemblyLeases or {}) do
        local task=(c.tasks and c.tasks[taskId]) or (c.futureTasks and c.futureTasks[taskId])
        if not task or task.state=='done' or task.state=='blocked' or task.state=='cancelled'
            or (task.preferredVehicleKey and task.preferredVehicleKey~=vehicleKey) then
            c.assemblyLeases[vehicleKey]=nil
            for toolKey,owner in pairs(c.assemblyToolLeases or {}) do
                if owner==taskId then c.assemblyToolLeases[toolKey]=nil end
            end
        end
    end
    for id,s in pairs(c.attachSessions or {}) do
        local target=s.plan.tool.object;local root=FMAUtil.call(target,'getRootVehicle')
        local attached=root==s.plan.power.object
        local cancelled=not c.settings.enabled or (FMAGameNative and FMAGameNative.isManuallyControlled(s.plan.power.object))==true
        if attached or cancelled or c.now-s.start>15000 then
            c.attachSessions[id]=nil;c.reservations[s.plan.power.key]=nil;c.implementReservations[s.plan.tool.key]=nil;s.plan.power.busy=false
            FMAAssembler.releaseLease(c,s.parent,s.plan)
            if attached and not cancelled then
                if s.parent.forceHandoverImplement and s.plan.tool.key==s.parent.preferredImplementKey then
                    s.parent.forceHandoverImplement=nil;s.parent.blockedByHandover=nil
                    s.parent.managedAttachment=nil
                    if FMAReturnManager then FMAReturnManager.rememberAssembly(c,s.parent,s.plan) end
                    if FMADiagnostics then FMADiagnostics.event(c,'handover.reattached',s.parent.id,s.plan.power.key) end
                end
                if not s.preserveParentState then s.parent.state='pending';s.parent.reason=nil;s.parent.retryAt=0;s.parent.failures=0 end
                if s.onConfirmed then s.onConfirmed()
                elseif not s.preserveParentState then s.parent.preferredVehicleKey=s.plan.power.key;s.parent.preferredVehicleName=s.plan.power.name;s.parent.qualityCourseReady=nil end
                FMAAssembler.clearCircuit(c,s.parent.id)
                FMAAssembler.hitchEvent(c,'confirmed',s.plan,'FS25 getRootVehicle confirmed')
                c:notify(s.plan.power.name..' · připojení '..s.plan.tool.name..' potvrzeno')
            else
                local reason=cancelled and 'Příprava přerušena majitelem' or 'Hra nepotvrdila připojení nářadí'
                FMAAssembler.hitchEvent(c,'failed',s.plan,reason)
                if s.preserveParentState then if s.onFailed then s.onFailed(reason) end
                else s.parent.state='blocked';s.parent.reason=reason end
            end
            c.elapsed=c.settings.scanSeconds*1000
        end
    end
end
