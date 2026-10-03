-- Optional teach mode. The owner can record trusted approach points and a sparse manual path.
-- Learned data are hints only: the manager still validates every AI leg before moving.
FMATeach={VERSION='0.20.13.0',roles={'DVŮR','POLE','JÁMA','SKLAD','NÁŘADÍ','SERVIS','PLNIČKA','ČEKÁNÍ','BRÁNA','OTOČKA'}}

local function currentVehicle(c)
    local player=FMAUtil.call(g_currentMission and g_currentMission.playerSystem,'getLocalPlayer') or g_localPlayer
    local v=FMAUtil.call(player,'getCurrentVehicle') or (g_currentMission and g_currentMission.controlledVehicle)
    v=v and (FMAUtil.call(v,'getRootVehicle') or v) or nil
    if v and FMAUtil.owner(v)==c.farmId then return v end
    return nil
end

function FMATeach.role(c)
    local i=math.floor(tonumber(c.settings.teachRole) or 1)
    i=math.max(1,math.min(#FMATeach.roles,i))
    return FMATeach.roles[i]
end

function FMATeach.cycleRole(c)
    local i=math.floor(tonumber(c.settings.teachRole) or 1)
    c.settings.teachRole=i%#FMATeach.roles+1
    c:notify('Učení · role '..FMATeach.role(c))
end

function FMATeach.learnPoint(c)
    local v=currentVehicle(c);if not v then return false,'Sedni do vlastního stroje v místě, které chceš naučit' end
    local x,z=FMAUtil.position(v);if not x then return false,'Nelze zjistit polohu stroje' end
    local dx,dz=0,1
    if localDirectionToWorld and v.rootNode then local ok,a,_,b=pcall(localDirectionToWorld,v.rootNode,0,0,1);if ok and a and b then dx,dz=a,b end end
    local angle=MathUtil and MathUtil.getYRotationFromDirection and MathUtil.getYRotationFromDirection(dx,dz) or 0
    c.learnedPoints=c.learnedPoints or {}
    local id='P'..tostring(c.nextLearnedPointId or (FMAUtil.count(c.learnedPoints)+1));c.nextLearnedPointId=(c.nextLearnedPointId or FMAUtil.count(c.learnedPoints)+1)+1
    c.learnedPoints[id]={id=id,role=FMATeach.role(c),label=FMATeach.role(c)..' · naučený příjezd',x=x,z=z,angle=angle,radius=c.settings.learnedApproachRadius or 35}
    c.diagnosticDirty=true;FMAState.save(c);c:notify('Uložen naučený bod '..id..' · '..FMATeach.role(c));return true
end

local function simplify(points)
    local out={};local last=nil
    for _,p in ipairs(points or {}) do
        if not last or (p.x-last.x)^2+(p.z-last.z)^2>=20*20 then out[#out+1]=p;last=p end
    end
    if #points>0 and (#out==0 or out[#out]~=points[#points]) then out[#out+1]=points[#points] end
    return out
end

function FMATeach.toggleRoute(c)
    if c.teachSession then
        local s=c.teachSession;c.teachSession=nil
        local points=simplify(s.points)
        if #points<2 then return false,'Učící jízda je příliš krátká' end
        c.learnedRoutes=c.learnedRoutes or {}
        local id='R'..tostring(c.nextLearnedRouteId or (FMAUtil.count(c.learnedRoutes)+1));c.nextLearnedRouteId=(c.nextLearnedRouteId or FMAUtil.count(c.learnedRoutes)+1)+1
        c.learnedRoutes[id]={id=id,role=s.role,label=s.role..' · ověřená trasa',points=points}
        FMAState.save(c);c.diagnosticDirty=true;c:notify('Uložena ověřená trasa '..id..' · '..#points..' bodů');return true
    end
    local v=currentVehicle(c);if not v then return false,'Sedni do vlastního stroje a projeď problematický příjezd' end
    local x,z=FMAUtil.position(v);if not x then return false,'Nelze zjistit polohu stroje' end
    c.teachSession={vehicle=v,role=FMATeach.role(c),points={{x=x,z=z,angle=0}},lastX=x,lastZ=z,start=c.now or 0}
    c:notify('UČÍCÍ JÍZDA ZAPNUTA · '..FMATeach.role(c)..' · projeď trasu a znovu Enter ji uloží');return true
end

function FMATeach.update(c)
    local s=c.teachSession;if not s then return end
    if not s.vehicle or FMAUtil.owner(s.vehicle)~=c.farmId then c.teachSession=nil;return end
    local x,z=FMAUtil.position(s.vehicle);if not x then return end
    if (x-s.lastX)^2+(z-s.lastZ)^2>=10*10 then
        s.points[#s.points+1]={x=x,z=z,angle=0};s.lastX=x;s.lastZ=z
        if #s.points>250 then table.remove(s.points,2) end
    end
end

local function distSq(a,b)
    if not a or not b or not a.x or not a.z or not b.x or not b.z then return math.huge end
    local dx=a.x-b.x;local dz=a.z-b.z;return dx*dx+dz*dz
end

function FMATeach.routeTo(c,from,target,role)
    if not target or not target.x or not target.z then return nil end
    local endpointRadius=math.max((c.settings.learnedApproachRadius or 35)*2,80)
    local startRadius=math.max(endpointRadius,140)
    local best,bestScore=nil,math.huge
    for id,r in pairs(c.learnedRoutes or {}) do
        local pts=r.points or {}
        if #pts>=2 and (not role or r.role==role) then
            local first,last=pts[1],pts[#pts]
            local dTargetFirst=distSq(target,first);local dTargetLast=distSq(target,last)
            local reversed=dTargetFirst<dTargetLast
            local endPoint=reversed and first or last
            local startPoint=reversed and last or first
            local dEnd=distSq(target,endPoint);local dStart=from and distSq(from,startPoint) or 0
            if dEnd<=endpointRadius*endpointRadius and (not from or dStart<=startRadius*startRadius) then
                local score=dEnd+dStart*0.25
                if score<bestScore then best,bestScore={id=id,route=r,reversed=reversed},score end
            end
        end
    end
    if not best then return nil end
    local out={};local pts=best.route.points
    if best.reversed then for i=#pts,1,-1 do out[#out+1]={x=pts[i].x,z=pts[i].z,angle=pts[i].angle or 0,learnedRouteId=best.id} end
    else for i=1,#pts do out[#out+1]={x=pts[i].x,z=pts[i].z,angle=pts[i].angle or 0,learnedRouteId=best.id} end end
    if from then while #out>0 and distSq(from,out[1])<8*8 do table.remove(out,1) end end
    return #out>0 and out or nil
end

function FMATeach.bestApproach(c,target,role)
    if not target or not target.x or not target.z then return nil end
    local maxDist=c.settings.learnedApproachRadius or 35
    local best,bestD=nil,maxDist*maxDist
    for _,p in pairs(c.learnedPoints or {}) do
        if not role or p.role==role then
            local d=(p.x-target.x)^2+(p.z-target.z)^2
            if d<=bestD then best,bestD=p,d end
        end
    end
    return best
end

function FMATeach.applyApproach(c,target,role)
    local p=FMATeach.bestApproach(c,target,role)
    if not p then return target,false end
    return {x=p.x,z=p.z,angle=p.angle or target.angle or 0,learned=true,label=p.label},true
end

function FMATeach.clearLast(c)
    local bestId=nil
    for id in pairs(c.learnedPoints or {}) do if not bestId or tostring(id)>tostring(bestId) then bestId=id end end
    if bestId then c.learnedPoints[bestId]=nil;FMAState.save(c);c:notify('Smazán naučený bod '..bestId);return true end
    local routeId=nil;for id in pairs(c.learnedRoutes or {}) do if not routeId or tostring(id)>tostring(routeId) then routeId=id end end
    if routeId then c.learnedRoutes[routeId]=nil;FMAState.save(c);c:notify('Smazána naučená trasa '..routeId);return true end
    return false
end

function FMATeach.writeDiagnostics(c,f)
    f:write('\nTEACH MODE\n')
    f:write('role=',FMATeach.role(c),' active=',tostring(c.teachSession~=nil),' points=',tostring(FMAUtil.count(c.learnedPoints or {})),' routes=',tostring(FMAUtil.count(c.learnedRoutes or {})),'\n')
    for id,p in pairs(c.learnedPoints or {}) do f:write('point ',id,' ',tostring(p.role),' x=',tostring(p.x),' z=',tostring(p.z),'\n') end
    for id,r in pairs(c.learnedRoutes or {}) do f:write('route ',id,' ',tostring(r.role),' waypoints=',tostring(#(r.points or {})),'\n') end
end
