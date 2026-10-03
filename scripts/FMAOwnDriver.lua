-- FARM MANAGER AI: third autonomous driver.  The base AI and Courseplay own normal
-- jobs. This driver owns ONLY bounded physical manoeuvres after those jobs have
-- released the vehicle; never fake job completion or teleport a vehicle.
FMAOwnDriver = {}

local function position(v)
    if FMAUtil and FMAUtil.position then return FMAUtil.position(v) end
    return nil,nil
end
local function distance(x,z,tx,tz)
    if not x or not z or not tx or not tz then return math.huge end
    return math.sqrt((tx-x)^2+(tz-z)^2)
end
local function diagnostic(c,kind,s,reason)
    if FMADiagnostics and FMADiagnostics.event then
        FMADiagnostics.event(c,'ownDriver.'..kind,s and s.id or '-',tostring(reason or ''))
    end
end
local function manual(v)
    return FMAGameNative and FMAGameNative.isManuallyControlled and FMAGameNative.isManuallyControlled(v)==true
end
local function aiActive(v)
    return FMAUtil and FMAUtil.call and FMAUtil.call(v,'getIsAIActive')==true
end
local function capable(v)
    if not v or not v.rootNode or not v.spec_motorized or not v.spec_drivable then return false,'Chybí řiditelná kola/motor' end
    if not (AIVehicleUtil and type(AIVehicleUtil.driveInDirection)=='function') then return false,'GIANTS AIVehicleUtil.driveInDirection není dostupný' end
    if type(worldDirectionToLocal)~='function' or type(localDirectionToWorld)~='function' then return false,'Chybí převod souřadnic GIANTS' end
    if type(v.startMotor)~='function' or type(v.getIsMotorStarted)~='function' then return false,'Chybí ovládání motoru' end
    -- Real FS25 crash: AIVehicleUtil.driveInDirection invokes vehicle:getMotor():setSpeedLimit().
    -- Merely having spec_motorized says nothing about a live motor instance.
    local motor=type(v.getMotor)=='function' and FMAUtil.call(v,'getMotor') or (v.spec_motorized and v.spec_motorized.motor)
    if not motor or type(motor.setSpeedLimit)~='function' then
        return false,'GIANTS: chybí inicializovaný motor (getMotor/setSpeedLimit); fyzické řízení se nespustí'
    end
    if g_server==nil or v.isServer==false then return false,'Vlastní fyzický řidič pouze na serveru' end
    return true
end
local function facing(v,dx,dz,reverse)
    local ok,fx,_,fz=pcall(localDirectionToWorld,v.rootNode,0,0,1)
    if not ok or not fx then return false,0 end
    local length=math.sqrt(dx*dx+dz*dz)
    if length<0.001 then return true,1 end
    local dot=(fx*dx+fz*dz)/length
    if reverse then dot=-dot end
    return dot>0.70,dot
end
-- GIANTS collision rays, not a guessed map square. Each direct hitch
-- manoeuvre verifies the real physics scene before starting and at runtime.
-- The ray callback deliberately stops on unknown shapes (fail closed).
function FMAOwnDriver:collisionRay(nodeId)
    local mission=g_currentMission
    local object=mission and mission.getNodeObject and mission:getNodeObject(nodeId)
    local root=object and FMAUtil.call(object,'getRootVehicle') or object
    if object and (object==self.guardVehicle or root==self.guardVehicle) then return false end
    if object and self.guardTool and (object==self.guardTool or root==self.guardTool) then
        -- The implement is a physical obstacle too: never steer through it.
        -- The attach engine itself must handle the last in-range centimetres.
    end
    self.guardBlocked=true
    self.guardNode=tostring(nodeId)
    return true
end

function FMAOwnDriver.collisionCorridor(v,goal,maxLookahead)
    if type(raycastClosest)~='function' or type(getWorldTranslation)~='function'
        or type(localDirectionToWorld)~='function' then
        return false,'FS25 neposkytlo kolizní sondu pro vlastní fyzický nájezd'
    end
    if not v or not v.rootNode or not goal then return false,'Chybí fyzické vozidlo nebo cíl' end
    local locationOk,x,y,z=pcall(getWorldTranslation,v.rootNode)
    if not locationOk or not x or not y or not z then return false,'Není možné určit fyzickou polohu/výšku stroje' end
    local dx,dz=goal.x-x,goal.z-z
    local length=math.sqrt(dx*dx+dz*dz)
    if length<.35 then return true,'V dosahu závěsu' end
    local nx,nz=dx/length,dz/length
    local rightX,rightZ=nz,-nx
    -- Read the real vehicle width/length when available. Checking only from
    -- rootNode would leave its bumper unguarded. Do not invent a map obstacle.
    local size=v.size or {}
    local halfWidth=math.max(0.8,math.min(2.2,(tonumber(size.width) or 2.6)*0.40))
    local frontReach=math.max(1.1,math.min(3.7,(tonumber(size.length) or 5.0)*0.38))
    local startX,startZ=x+nx*frontReach,z+nz*frontReach
    local lookahead=math.min(maxLookahead or 2.0,math.max(0.5,length-frontReach))
    local probes={-halfWidth,0,halfWidth}
    for _,offset in ipairs(probes) do
        for _,height in ipairs({0.75,1.45}) do
            FMAOwnDriver.guardVehicle=v
            FMAOwnDriver.guardBlocked=false
            FMAOwnDriver.guardNode=nil
            local sx,sz=startX+rightX*offset,startZ+rightZ*offset
            local ok,err=pcall(raycastClosest,sx,y+height,sz,nx,0,nz,lookahead,'collisionRay',FMAOwnDriver)
            if not ok then FMAOwnDriver.guardVehicle=nil;return false,'Kolizní dotaz GIANTS selhal: '..tostring(err) end
            if FMAOwnDriver.guardBlocked then
                FMAOwnDriver.guardVehicle=nil
                return false,'Kolizní sonda hlásí překážku ('..tostring(FMAOwnDriver.guardNode)..')'
            end
        end
    end
    FMAOwnDriver.guardVehicle=nil
    return true,'Tři fyzické kolizní sondy bez zjištěné překážky'
end

local function brake(s,dt)
    if not s or not s.record or not s.record.object then return end
    local v=s.vehicleObject
    if s.record.object~=v or manual(v) or aiActive(v) or v.isDeleted then return end
    -- No engine instance means GIANTS braking API would crash at setSpeedLimit, too.
    local motor=v and type(v.getMotor)=='function' and FMAUtil.call(v,'getMotor')
    if motor and type(motor.setSpeedLimit)=='function' and AIVehicleUtil and AIVehicleUtil.driveInDirection then
        pcall(AIVehicleUtil.driveInDirection,v,dt or 16,40,0,0,35,false,true,0,1,0,0.4)
    end
end
local function clear(c,s,ok,reason,dt)
    local sessions=c.ownDriveSessions or {}
    if sessions[s.record.key]~=s then return end
    sessions[s.record.key]=nil
    if c.reservations and c.reservations[s.record.key]==s.id then c.reservations[s.record.key]=nil end
    if c.implementReservations and s.toolKey and c.implementReservations[s.toolKey]==s.id then c.implementReservations[s.toolKey]=nil end
    -- Completion callback may race with a subsequent dispatch; do not clear a
    -- different worker's reservation or brake another owner of the wheels.
    local occupied=(c.reservations and c.reservations[s.record.key]~=nil)
    for _,a in pairs(c.active or {}) do
        if a.vehicle and a.vehicle.key==s.record.key then occupied=true;break end
    end
    if not occupied then s.record.busy=false end
    if not occupied and (ok or not manual(s.record.object)) then brake(s,dt) end
    diagnostic(c,ok and 'finished' or 'stopped',s,reason)
    if s.onDone then
        local called,err=pcall(s.onDone,c,s,ok,reason)
        if not called then
            diagnostic(c,'callbackError',s,err)
            c.settings.enabled=false
            c.runtimePaused=true
        end
    end
end

function FMAOwnDriver.available(v)
    return capable(v)
end
function FMAOwnDriver.isBusy(c,key)
    return c and c.ownDriveSessions and c.ownDriveSessions[key]~=nil
end
function FMAOwnDriver.hasBunker(c,index)
    for _,s in pairs(c and c.ownDriveSessions or {}) do
        if s.kind=='bunker' and s.bunkerIndex==index then return true end
    end
    return false
end

function FMAOwnDriver.begin(c,record,opts)
    opts=opts or {}
    local v=record and record.object
    if not c or not c.settings or c.settings.enabled~=true or not record or not v then return false,'AUTO není zapnuto' end
    local ready,why=capable(v);if not ready then return false,why end
    if manual(v) or aiActive(v) then return false,'Stroj řídí hráč nebo jiná AI' end
    if FMAControlAuthority then
        local allowed,reason=FMAControlAuthority.canStart(c,record,opts.expectedReservation)
        if not allowed then return false,reason end
    end
    if FMAUtil.owner(v)~=c.farmId then return false,'Cizí stroj' end
    if FMAOwnDriver.isBusy(c,record.key) then return false,'Vlastní řidič už vozidlo řídí' end
    if c.reservations[record.key] and c.reservations[record.key]~=opts.expectedReservation then return false,'Stroj už má rezervaci' end
    if not opts.id or not opts.goal or not opts.goal.x or not opts.goal.z then return false,'Chybí bezpečně ověřený cíl' end
    if opts.kind=='hitch' then
        local clear,clearance=FMAOwnDriver.collisionCorridor(v,opts.goal)
        if not clear then return false,clearance end
        opts.collisionCorridorVerified=true
    end
    local x,z=position(v)
    if distance(x,z,opts.goal.x,opts.goal.z)>(opts.maxDistance or 15) then return false,'Místní manévr je příliš daleko; použij běžnou AI' end
    local aligned,dot=facing(v,opts.goal.x-x,opts.goal.z-z,opts.goal.reverse)
    if not aligned and distance(x,z,opts.goal.x,opts.goal.z)>(opts.tolerance or 1.2) then
        return false,string.format('Traktor není natočen pro bezpečný %s nájezd (směr %.2f)',opts.goal.reverse and 'zpětný' or 'přední',dot)
    end
    if v.getCanMotorRun and FMAUtil.call(v,'getCanMotorRun')==false then return false,'Motor nemůže běžet' end
    local s={id=opts.id,kind=opts.kind or 'manoeuvre',record=record,vehicleObject=v,toolKey=opts.toolKey,
        goal=opts.goal,reverse=opts.goal.reverse==true,bunker=opts.bunker,bunkerIndex=opts.bunkerIndex,
        bunkerStart=opts.bunkerStart,waypoints=opts.waypoints,segment=1,passes=0,
        targetCompaction=opts.targetCompaction or 99.9,
        tolerance=opts.tolerance or 1.2,speed=math.min(opts.speed or 2.4,opts.maxSpeed or 6),
        started=c.now or 0,waypointStart=c.now or 0,lastMotion=c.now or 0,
        lastX=x,lastZ=z,originX=x,originZ=z,travelled=0,
        maxDuration=opts.maxDuration or 65000,maxDistance=opts.maxDistance or 15,
        onDone=opts.onDone,moveObserved=false,collisionCorridorVerified=opts.collisionCorridorVerified==true}
    c.ownDriveSessions=c.ownDriveSessions or {}
    c.ownDriveSessions[record.key]=s
    c.reservations[record.key]=s.id
    if s.toolKey then c.implementReservations[s.toolKey]=s.id end
    record.busy=true
    if not v:getIsMotorStarted() then
        local ok,err=pcall(v.startMotor,v,true)
        s.motorStartRequested=c.now or 0
        s.motorStartAttempts=1
        if not ok then
            -- Failed initialisation must not call the work-completion callback;
            -- the caller may still try a different engine for this same task.
            c.ownDriveSessions[record.key]=nil
            if c.reservations[record.key]==s.id then c.reservations[record.key]=nil end
            if s.toolKey and c.implementReservations[s.toolKey]==s.id then c.implementReservations[s.toolKey]=nil end
            record.busy=false
            diagnostic(c,'startFailed',s,err)
            return false,tostring(err)
        end
    end
    diagnostic(c,'started',s,tostring(s.kind)..' '..tostring(s.goal.x)..','..tostring(s.goal.z)..' reverse='..tostring(s.reverse))
    return true,s
end

local function bunkerCompaction(s)
    local b=s.bunker
    if not b then return nil end
    local raw=b.object and b.object.compactedPercent
    if type(raw)~='number' then raw=b.compactedPercent end
    return tonumber(raw)
end

-- A machine physically left inside a bunker must not be sent back through the
-- yard to a guessed gate. This is a strict *inner* rectangle, not the broad CP
-- entrance envelope. The driver only starts on a clear, aligned central lane.
function FMAOwnDriver.planInsideBunker(c,record,b)
    local g=b and b.geometry
    local v=record and record.object
    if not g or not g.front or not g.back or not g.dx or not g.dz or not g.length or not g.width
        or g.length<14 or g.width<4 or not v then return nil,'Neúplná geometrie jámy' end
    local x,z=position(v)
    if not x or not z then return nil,'Neznámá poloha traktoru' end
    local ox,oz=x-g.front.x,z-g.front.z
    local along=ox*g.dx+oz*g.dz
    local signedSide=-ox*g.dz+oz*g.dx
    local side=math.abs(signedSide)
    local halfVehicle=((v.size and tonumber(v.size.width)) or 3.0)*0.5
    local sideLimit=g.width*0.5-halfVehicle-0.65
    if sideLimit<=0.3 then return nil,'Pracovní koridor je pro šířku stroje příliš úzký' end
    local halfLength=((v.size and tonumber(v.size.length)) or 6.5)*0.5
    local margin=math.max(3.0,halfLength+0.85)
    if g.length<margin*2+7 then return nil,'Pracovní koridor je pro délku stroje příliš krátký' end
    if along<margin or along>g.length-margin or side>sideLimit then
        return nil,string.format('Stroj není bezpečně uvnitř volné osy: podélně %.1f, stranou %.1f/%.1f',along,side,sideLimit)
    end
    local ok,fx,_,fz=pcall(localDirectionToWorld,v.rootNode,0,0,1)
    if not ok or not fx or not fz then return nil,'Nelze ověřit směr stroje' end
    local dot=fx*g.dx+fz*g.dz
    if math.abs(dot)<0.90 then return nil,string.format('Stroj je natočen mimo osu jámy (%.2f)',dot) end
    -- Treat the machine's CURRENT longitudinal lane as the only candidate.
    -- Do not steer both machines toward the same centre line. Two tractors
    -- may operate only if their real lateral envelopes never overlap. If they
    -- are one behind the other in the same lane, remain stopped; they cannot
    -- magically pass in a concrete bunker.
    local objects={}
    for _,other in ipairs(c and c.vehicles or {}) do objects[#objects+1]=other end
    for _,tool in ipairs(c and c.loose or {}) do objects[#objects+1]=tool end
    for _,other in ipairs(objects) do
        if other~=record and other.object and other.object~=v and not other.object.isDeleted then
            local tx,tz=position(other.object)
            if tx and tz then
                local ax,az=tx-g.front.x,tz-g.front.z
                local p=ax*g.dx+az*g.dz
                local otherSide=-ax*g.dz+az*g.dx
                local otherHalfWidth=math.max(1.5,((other.object.size and tonumber(other.object.size.width)) or 3.5)*0.5)
                if p>=-4 and p<=g.length+4 and math.abs(otherSide)<=g.width*.5+otherHalfWidth then
                    if math.abs(otherSide-signedSide)<halfVehicle+otherHalfWidth+1.75 then
                        return nil,'V téže jízdní stopě stojí další stroj: '..tostring(other.name or other.key)
                    end
                end
            end
        end
    end
    -- Preserve the verified lateral lane instead of pulling toward the centre
    -- across a second tractor. The endpoints remain inside physical margins.
    local lateralX,lateralZ=-g.dz*signedSide,g.dx*signedSide
    local front={x=g.front.x+g.dx*margin+lateralX,z=g.front.z+g.dz*margin+lateralZ,reverse=false}
    local back={x=g.back.x-g.dx*margin+lateralX,z=g.back.z-g.dz*margin+lateralZ,reverse=false}
    -- First leg is forward along the vehicle nose; second is reverse along
    -- precisely the same aisle. No rotation in place near concrete walls.
    local forward=dot>0 and back or front
    local backward=dot>0 and front or back
    return {first={x=forward.x,z=forward.z,reverse=false},
        second={x=backward.x,z=backward.z,reverse=true},
        along=along,side=side,laneOffset=signedSide,dot=dot},nil
end

-- Begin a physically driven bunker sweep from an already verified FRONT entry.
-- CP remains preferred; this only runs if CP failed and the tractor faces in.
function FMAOwnDriver.beginBunker(c,record,b,index,parent,onDone)
    local g=b and b.geometry
    if not g or not g.frontOutside or not g.front or not g.dx or not g.dz or not g.length or not g.width
        or g.length<12 or g.width<4 then return false,'Geometrie silážní jámy není potvrzená' end
    local v=record.object
    local x,z=position(v)
    local interior,interiorWhy=FMAOwnDriver.planInsideBunker(c,record,b)
    if not interior and distance(x,z,g.frontOutside.x,g.frontOutside.z)>4.5 then
        return false,'Není v bezpečném průjezdu ani u vjezdu: '..tostring(interiorWhy)
    end
    local inside,details=false,'Geometrie jámy není dostupná'
    if FMABunkerCoordinator then inside,details=FMABunkerCoordinator.withinWorkEnvelope(b,x,z) end
    if inside~=true then return false,'Stroj mimo potvrzený vjezd: '..tostring(details) end
    local insideGoal,outsideGoal
    if interior then
        insideGoal,outsideGoal=interior.first,interior.second
    else
        local sideways=math.abs(-(x-g.front.x)*g.dz+(z-g.front.z)*g.dx)
        if sideways>g.width*.5+1 then return false,'Vlastní řidič není v průjezdném koridoru jámy' end
        local inX,inZ=g.front.x+g.dx*math.min(g.length-5,math.max(6,g.length*.7)),
            g.front.z+g.dz*math.min(g.length-5,math.max(6,g.length*.7))
        insideGoal={x=inX,z=inZ,reverse=false}
        outsideGoal={x=g.frontOutside.x,z=g.frontOutside.z,reverse=true}
        local ready,dot=facing(v,g.dx,g.dz,false)
        if not ready then return false,string.format('Traktor musí být natočen dovnitř jámy (%.2f)',dot) end
    end
    local id='ownBunker:'..tostring(index)..':'..record.key
    local ok,s=FMAOwnDriver.begin(c,record,{id=id,kind='bunker',bunker=b,bunkerIndex=index,
        bunkerStart=bunkerCompaction({bunker=b}) or 0,goal=insideGoal,
        waypoints={insideGoal,outsideGoal},maxDistance=math.max(75,g.length+15),
        maxDuration=420000,tolerance=3,speed=4.0,maxSpeed=4.0,
        onDone=onDone})
    if ok then s.parentTask=parent;s.bunkerInteriorStart=interior~=nil end
    return ok,s
end

function FMAOwnDriver.update(c,dt)
    local sessions=c and c.ownDriveSessions
    if not sessions then return end
    dt=math.max(1,math.min(tonumber(dt) or 16,120))
    -- Defer callbacks until after iterating: they may start other work immediately.
    local completed={}
    for _,s in pairs(sessions) do
        local v=s.record.object
        local now=c.now or 0
        local reason,finished
        if not c.settings.enabled then reason='AUTO vypnuto'
        elseif s.vehicleObject~=v or v.isDeleted or not v.rootNode then reason='FS25 změnilo nebo odstranilo objekt traktoru'
        elseif manual(v) then reason='Traktor převzal hráč'
        elseif aiActive(v) then reason='Traktor převzala jiná AI; vlastní řidič okamžitě končí'
        elseif FMAControlAuthority and FMAControlAuthority.snapshot(c,s.record).jobCount>0 then
            reason='Bezpečnostní blokace: souběžná pracovní úloha chce řídit stejný traktor' 
        elseif FMAUtil.owner(v)~=c.farmId then reason='Změnil se vlastník stroje'
        elseif now-s.started>s.maxDuration then reason='Časový limit fyzické jízdy'
        else
            local x,z=position(v)
            if not x then reason='Ztracena fyzická poloha traktoru'
            else
                -- The fallback driver gets the SAME physical containment as CP.
                -- Do not steer another frame after its tractor leaves a bunker.
                if s.kind=='bunker' and FMABunkerCoordinator and FMABunkerCoordinator.withinWorkEnvelope then
                    local enclosed,details=FMABunkerCoordinator.withinWorkEnvelope(s.bunker,x,z)
                    if not enclosed then reason='BEZPEČNOST: vlastní řidič mimo silážní jámu ('..tostring(details)..')' end
                end
                if s.kind=='bunker' and s.bunkerInteriorStart and not reason then
                    local planned,why=FMAOwnDriver.planInsideBunker(c,s.record,s.bunker)
                    -- Unlike the wide staging envelope, the strict corridor
                    -- prevents the physical driver entering walls or driving
                    -- through another machine during a live sweep.
                    if not planned then reason='BEZPEČNOST: vlastní hutnění přerušeno: '..tostring(why) end
                end
                if s.kind=='hitch' and not reason and (now-(s.lastCorridorScan or -1000))>=200 then
                    local clear,why=FMAOwnDriver.collisionCorridor(v,s.goal,2)
                    s.lastCorridorScan=now
                    if not clear then reason='BEZPEČNOST: vlastní řidič zastavil před překážkou: '..tostring(why) end
                end
                local moved=distance(x,z,s.lastX,s.lastZ)
                if moved>0.12 then
                    s.travelled=s.travelled+moved
                    s.moveObserved=true;s.lastMotion=now;s.lastX=x;s.lastZ=z
                end
                if s.travelled>(s.kind=='bunker' and 700 or s.maxDistance*3) then reason='Překročen limit fyzické jízdy' end
                local gap=distance(x,z,s.goal.x,s.goal.z)
                if not reason and gap<=s.tolerance then
                    if s.recoveryOriginal then
                        local saved=s.recoveryOriginal
                        s.recoveryOriginal=nil
                        s.goal=saved
                        s.reverse=s.goal.reverse==true
                        s.lastMotion=now
                        s.waypointStart=now
                        gap=distance(x,z,s.goal.x,s.goal.z)
                        diagnostic(c,'repositioned',s,'Fyzický úhybný manévr dokončen, navazuji původní směr')
                    elseif s.recoveryHitch then
                        reason='Traktor se fyzicky uvolnil popojetím; nyní zkusit druhý nájezd'
                    elseif s.kind~='bunker' then
                        finished=true
                        reason=s.moveObserved and 'Skutečný dojezd potvrzen' or 'Poloha cíle dosažena bez fyzické jízdy; závěs musí potvrdit FS25'
                    else
                        s.passes=s.passes+1
                        local p=bunkerCompaction(s)
                        local atExit=s.segment==2
                        if atExit and p and p>=s.targetCompaction then
                            finished=true;reason='Zhutnění fyzicky potvrzeno '..tostring(p)..' % po návratu v koridoru jámy'
                        elseif atExit and s.passes>=6 then
                            reason='Jáma stále není zhutněná po třech fyzických průjezdech ('..tostring(p or '?')..' %)'
                        elseif not atExit and s.passes>=4 and p and p<=(s.bunkerStart or 0)+0.05 then
                            reason='Traktor projíždí, ale FS25 nehlásí růst zhutnění'
                        else
                            s.segment=atExit and 1 or 2
                            s.goal=s.waypoints[s.segment]
                            s.reverse=s.goal.reverse
                            s.lastMotion=now;s.waypointStart=now
                            diagnostic(c,'bunkerPass',s,'průjezd '..s.passes..' zhutnění='..tostring(p))
                        end
                    end
                end
                if not reason and not finished then
                    if v:getIsMotorStarted() and now-s.lastMotion>10500 and now-s.started>5500 then
                        -- ONE bounded local escape. Reversing into a hitch can
                        -- wedge the tractor against a collision shape; physically
                        -- drive forward by 2.5 m before selecting another pose.
                        -- Inside a bunker, stay within the confirmed central aisle.
                        local recover=false
                        if not s.recoveryUsed and s.kind=='hitch' and s.reverse and s.collisionCorridorVerified==true then
                            local ok,fx,_,fz=pcall(localDirectionToWorld,v.rootNode,0,0,1)
                            if ok and fx then
                                s.recoveryUsed=true;s.recoveryHitch=true
                                s.goal={x=x+fx*2.5,z=z+fz*2.5,reverse=false}
                                s.reverse=false;s.lastMotion=now;recover=true
                            end
                        elseif not s.recoveryUsed and s.kind=='bunker' and s.bunker and s.bunker.geometry then
                            local g=s.bunker.geometry
                            local along=(x-g.front.x)*g.dx+(z-g.front.z)*g.dz
                            local side=math.abs(-(x-g.front.x)*g.dz+(z-g.front.z)*g.dx)
                            if along>=4 and along<=g.length-4 and side<g.width*.35 then
                                s.recoveryUsed=true
                                s.recoveryOriginal=s.goal
                                local sign=s.reverse and 1 or -1
                                s.goal={x=x+g.dx*sign*2.5,z=z+g.dz*sign*2.5,reverse=not s.reverse}
                                s.reverse=s.goal.reverse;s.lastMotion=now;recover=true
                            end
                        end
                        if recover then
                            gap=distance(x,z,s.goal.x,s.goal.z)
                            -- Reversing and then moving forward are different
                            -- collision corridors. The old reverse scan cannot
                            -- authorize the new forward escape lane.
                            if s.kind=='hitch' then
                                local free,why=FMAOwnDriver.collisionCorridor(v,s.goal)
                                if not free then reason='BEZPEČNOST: úhybný manévr není volný: '..tostring(why) end
                            end
                            s.lastCorridorScan=-1000
                            if not reason then diagnostic(c,'recoveryAttempt',s,'Fyzický úhybný manévr 2.5 m') end
                        else
                            reason='Traktor nedokázal fyzicky popojet ani bezpečně zvolit úhybný manévr'
                        end
                    end
                    if s.kind=='bunker' and now-s.waypointStart>95000 then reason='Traktor nedojel na konec silážní jámy' end
                end
                if not reason and not finished then
                    local canMove,dot=facing(v,s.goal.x-x,s.goal.z-z,s.reverse)
                    if not canMove then reason=string.format('Směr manévru není bezpečný (%.2f)',dot) end
                end
                if not reason and not finished then
                    if not v:getIsMotorStarted() then
                        -- The engine can be STARTING during asynchronous ignition. One bounded
                        -- re-request is allowed; never issue startMotor on every frame.
                        if now-(s.motorStartRequested or s.started)>5000 and (s.motorStartAttempts or 1)<2 then
                            local canRun=not v.getCanMotorRun or FMAUtil.call(v,'getCanMotorRun')~=false
                            if canRun then
                                local motorOk,motorErr=pcall(v.startMotor,v,true)
                                s.motorStartAttempts=(s.motorStartAttempts or 1)+1
                                s.motorStartRequested=now
                                diagnostic(c,'motorRetry',s,motorOk and 'Druhý pokus o zapálení motoru' or motorErr)
                            end
                        end
                        if now-s.started>17000 then
                            reason='FS25 nepotvrdil běžící motor; stav='..tostring(FMAUtil.call(v,'getMotorState'))..
                                ' spustitelny='..tostring(FMAUtil.call(v,'getCanMotorRun'))..
                                ' pokusy='..tostring(s.motorStartAttempts or 1)
                        end
                    else
                        local engineMotor=FMAUtil.call(v,'getMotor')
                        if not engineMotor or type(engineMotor.setSpeedLimit)~='function' then
                            reason='GIANTS: objekt motoru během práce zmizel (getMotor=nil); nesmím poslat driveInDirection'
                        end
                        local dx,dz=s.goal.x-x,s.goal.z-z
                        local ok,lx,_,lz=pcall(worldDirectionToLocal,v.rootNode,dx,0,dz)
                        if not ok or not lx then reason=reason or 'Nelze vypočítat reálný směr jízdy'
                        elseif not reason then
                            local length=math.sqrt(lx*lx+lz*lz)
                            if length>0.01 then
                                lx,lz=lx/length,lz/length
                                if s.reverse then lx,lz=-lx,-lz end
                                local speed=math.min(s.speed,gap<2 and 1.3 or s.speed)
                                -- API physically commands steering, motor and wheels on the server;
                                -- it is not a fake transform translation or a replacement AI job.
                                local driven,err=pcall(AIVehicleUtil.driveInDirection,v,dt,40,0.38,0.2,30,true,
                                    not s.reverse,lx,lz,speed,0.35)
                                if not driven then reason='GIANTS odmítl fyzické řízení: '..tostring(err) end
                            end
                        end
                    end
                end
            end
        end
        if reason then completed[#completed+1]={s=s,ok=finished==true,reason=reason} end
    end
    for _,entry in ipairs(completed) do clear(c,entry.s,entry.ok,entry.reason,dt) end
end

function FMAOwnDriver.stopAll(c,reason)
    local pending={}
    for _,s in pairs(c.ownDriveSessions or {}) do pending[#pending+1]=s end
    for _,s in ipairs(pending) do clear(c,s,false,reason or 'Vypnuto',16) end
end
