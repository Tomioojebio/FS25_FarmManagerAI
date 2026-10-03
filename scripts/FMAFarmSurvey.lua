-- Live, bounded farm-yard survey. Observations are evidence, not a navmesh.
-- Only physical movement creates segments; unverified AI transfer samples are
-- staged, and committed after the existing FS25 arrival confirmation.
-- Never infer clear space between buildings from empty/unobserved grid cells.
FMAFarmSurvey = {VERSION='0.20.49.0',GRID=3,MAX_EDGES=700,MAX_LIVE=40}
local S=FMAFarmSurvey
local function good(p)
    return type(p)=='table' and type(p.x)=='number' and type(p.z)=='number' and
        p.x==p.x and p.z==p.z and math.abs(p.x)<100000 and math.abs(p.z)<100000
end
local function dist(a,b) local dx=a.x-b.x;local dz=a.z-b.z;return math.sqrt(dx*dx+dz*dz) end
local function clone(p) return {x=p.x,z=p.z} end
local function key(p) return math.floor(p.x/S.GRID+0.5)..':'..math.floor(p.z/S.GRID+0.5) end
local function edgeId(a,b) return key(a)..'>'..key(b) end
local function edgeCount(t) local n=0;for _ in pairs(t or {}) do n=n+1 end;return n end
local function bounds(c,p)
    local v=c.farmSurvey
    local limit=math.max(80,math.min(500,tonumber(c.settings and c.settings.surveyRadius) or 230))
    return v and good(v.center) and good(p) and dist(v.center,p)<=limit
end
function S.data(c)
    c.farmSurvey=c.farmSurvey or {edges={},center=nil,manual=false,observed=0,confirmed=0,blocked=0}
    local v=c.farmSurvey
    v.edges=v.edges or {};v.manual=v.manual==true
    return v
end
-- Prefer existing recorded parking/home coordinates. Do not take the position
-- of a tractor on a remote field as a new farm centre automatically.
function S.findCenter(c)
    local spots={}
    for _,rows in ipairs({c.homePositions or {},c.toolHomes or {}}) do
        for _,p in pairs(rows) do if good(p) then spots[#spots+1]=p end end
    end
    for _,p in pairs(c.learnedPoints or {}) do
        if good(p) and p.role~='POLE' then spots[#spots+1]=p end
    end
    -- Unconfigured map: find the dense CLUSTER of owned farm facilities instead
    -- of choosing an arbitrary tractor parked on a distant field.
    if #spots==0 then
        for _,row in ipairs((c.worldAtlas and c.worldAtlas.husbandries) or {}) do
            local obj=row.object
            local x,z=nil,nil
            if obj then x,z=FMAUtil.position(obj) end
            if x and z then spots[#spots+1]={x=x,z=z} end
        end
        for _,row in ipairs((c.worldAtlas and c.worldAtlas.storages) or {}) do
            local obj=row.object
            local x,z=nil,nil
            if obj then x,z=FMAUtil.position(obj) end
            if x and z then spots[#spots+1]={x=x,z=z} end
        end
        for _,z in ipairs((c.digitalMap and c.digitalMap.zones) or {}) do
            if good(z) and z.kind~='POLE' and z.kind~='TRASA' then spots[#spots+1]=z end
        end
        if #spots<3 then
            for _,v in ipairs(c.vehicles or {}) do
                local x,z=FMAUtil.position(v.object)
                if x and z then spots[#spots+1]={x=x,z=z} end
            end
        end
        if #spots<3 then return nil end
    end
    local best,score=nil,-1
    for _,p in ipairs(spots) do
        local near=0
        for _,q in ipairs(spots) do if dist(p,q)<110 then near=near+1 end end
        if near>score then best,score=p,near end
    end
    return best and clone(best) or nil
end
function S.initialize(c)
    local v=S.data(c)
    if not v.manual and not good(v.center) then v.center=S.findCenter(c) end
    return v.center~=nil
end
function S.anchor(c,p)
    if not good(p) then return false,'Střed dvora se nepodařilo zaměřit' end
    local v=S.data(c)
    local old=v.center
    if good(old) and dist(old,p)>math.max(80,tonumber(c.settings and c.settings.surveyRadius) or 230) then
        v.edges={};v.hazards={};v.observed=0;v.confirmed=0
    end
    v.center=clone(p);v.manual=true;v.liveManual=nil
    c.diagnosticDirty=true
    return true
end
function S.playerVehicle(c)
    local mission=g_currentMission
    local v=mission and mission.controlledVehicle
    local player=FMAUtil and (FMAUtil.call(mission and mission.playerSystem,'getLocalPlayer') or g_localPlayer)
    if not v and player then v=FMAUtil.call(player,'getCurrentVehicle') end
    if v and type(v.getRootVehicle)=='function' then v=FMAUtil.call(v,'getRootVehicle') or v end
    if v and FMAUtil.owner(v)==c.farmId then return v end
    return nil
end
function S.classify(vehicle)
    if not vehicle then return 'UNKNOWN' end
    local v=vehicle.object or vehicle
    if FMAWorld and type(FMAWorld.operationalChildren)=='function' then
        local ok,parts=pcall(FMAWorld.operationalChildren,v)
        if ok and type(parts)=='table' and #parts>1 then return 'TOWED' end
    end
    return 'SOLO'
end
local function merge(c,a,b,mode,vehicleKey)
    if not bounds(c,a) or not bounds(c,b) then return false end
    local len=dist(a,b)
    -- Never connect teleport/reset, a stationary sample or adjacent points
    -- separated by large unobserved distances.
    if len<1.5 or len>18 or key(a)==key(b) then return false end
    local v=S.data(c);local id=edgeId(a,b)
    local row=v.edges[id]
    if not row then
        row={id=id,ax=a.x,az=a.z,bx=b.x,bz=b.z,solo=0,towed=0,manual=0,ai=0,blocked=0}
        v.edges[id]=row
    end
    if mode=='TOWED' then row.towed=math.min(999,(row.towed or 0)+1)
    else row.solo=math.min(999,(row.solo or 0)+1) end
    row.manual=math.min(999,(row.manual or 0)+(vehicleKey=='MANUAL' and 1 or 0))
    row.ai=math.min(999,(row.ai or 0)+(vehicleKey=='AI' and 1 or 0))
    row.age=c.now or 0
    v.observed=(v.observed or 0)+1
    if vehicleKey=='AI' then v.confirmed=(v.confirmed or 0)+1 end
    local n=edgeCount(v.edges)
    if n>S.MAX_EDGES then
        local oldest,age=nil,math.huge
        for k,e in pairs(v.edges) do if (e.age or 0)<age then oldest,age=k,e.age or 0 end end
        if oldest then v.edges[oldest]=nil end
    end
    return true
end
-- Player drives the farm during teach or ordinary manual driving; each 1s
-- sample is physically checked against the last sample and teleport jumps drop.
function S.observeManual(c,vehicle)
    local v=S.data(c)
    if not c.settings or c.settings.surveyEnabled==false or not S.initialize(c) then return end
    if not vehicle or (FMAUtil and FMAUtil.owner(vehicle)~=c.farmId) then return end
    if FMAGameNative and FMAGameNative.isManuallyControlled and not FMAGameNative.isManuallyControlled(vehicle) then return end
    local x,z=FMAUtil.position(vehicle);local p={x=x,z=z}
    if not good(p) then return end
    local stamp=c.now or 0
    local trace=v.liveManual
    local token=tostring(vehicle)
    if not trace or trace.token~=token or stamp-(trace.time or 0)>3000 then
        v.liveManual={p=p,token=token,time=stamp};return
    end
    v.liveManual={p=p,token=token,time=stamp}
    local d=dist(trace.p,p)
    if d>=1.5 and d<=18 then merge(c,trace.p,p,S.classify(vehicle),'MANUAL') end
end
function S.update(c)
    if not c or not c.initialized or not c.supported or not c.settings or c.settings.surveyEnabled==false then return end
    -- Navigation costmap and road spline geometry are owned by the loaded map,
    -- not by the savegame's almost-empty navigationSystem.xml file.
    if FMAEngineRoads and not (c.engineRoads and c.engineRoads.finished) then
        FMAEngineRoads.scan(c)
    end
    if not S.initialize(c) then return end
    -- Feed the manual painter even when AUTO is off. Never seize controls.
    local obj=S.playerVehicle(c)
    if obj then S.observeManual(c,obj) end
end
-- AI only receives credit when the original transfer reports a real confirmed
-- arrival, including actual destination distance. The progress samples remain
-- transient during a failed attempt, and no fake edge survives that attempt.
function S.confirmTransfer(c,active)
    if not c or not active or not c.settings or c.settings.surveyEnabled==false then return 0 end
    if not S.initialize(c) then return 0 end
    local pts=active.navSamples or {}
    local kind=S.classify(active.vehicle)
    local added=0
    for i=2,#pts do if good(pts[i-1]) and good(pts[i]) and merge(c,pts[i-1],pts[i],kind,'AI') then added=added+1 end end
    if added>0 then c.diagnosticDirty=true end
    return added
end
function S.markHazard(c,p)
    if not c or not bounds(c,p) then return end
    local v=S.data(c)
    local cell=key(p)
    local hazards=v.hazards or {};v.hazards=hazards
    hazards[cell]=math.min(20,(hazards[cell] or 0)+1)
    v.blocked=(v.blocked or 0)+1
end
-- Graph planning combines observed directed edges with the real AI road splines.
-- Candidate edges become valid for this vehicle only after physically confirmed AI legs.
function S.plan(c,start,finish,mode)
    if not good(start) or not good(finish) then return nil,'NEZNÁMÁ POLOHA' end
    local v=S.data(c)
    -- First try the whole real FS25 road graph, including fields kilometres
    -- away. Its output is provisional; only physical AI arrival verifies it.
    if FMAEngineRoads and FMAEngineRoads.route then
        local roads,reason=FMAEngineRoads.route(c,start,finish,mode)
        if roads then return roads,nil end
        -- If a start/finish is outside the yard, a disconnected public road is
        -- not license to create a blind straight-line path through buildings.
        if not v.center or not bounds(c,start) or not bounds(c,finish) then
            return nil,reason or 'MIMO_SILNIČNÍ_SÍŤ'
        end
    elseif not v.center or not bounds(c,start) or not bounds(c,finish) then
        return nil,'MIMO DVŮR'
    end
    if not v.center or not bounds(c,start) or not bounds(c,finish) then return nil,'MIMO DVŮR' end
    local adj={};local positions={}
    local function danger(p)
        local total=0
        for _,h in pairs((c.navigationMap and c.navigationMap.hazards) or {}) do
            if good(h) and dist(p,h)<9 then total=math.max(total,h.failures or 0) end
        end
        total=math.max(total,(v.hazards and v.hazards[key(p)]) or 0)
        return total
    end
    -- GIANTS' real navigation splines form a *candidate* street network for
    -- solo vehicles; their presence is not proof a long trailer fits.
    -- The engine validates physical traversal of every chosen 27 m section.
    if mode~='TOWED' and FMAEngineRoads and c.engineRoads and c.engineRoads.hasCostmap then
        for _,e in ipairs(FMAEngineRoads.near(c,v.center,math.max(80,math.min(500,tonumber(c.settings and c.settings.surveyRadius) or 230)))) do
            local a={x=e.ax,z=e.az};local b={x=e.bx,z=e.bz}
            local ka,kb=key(a),key(b)
            if danger(a)<2 and danger(b)<2 and bounds(c,a) and bounds(c,b) then
                local len=dist(a,b)
                adj[ka]=adj[ka] or {};adj[ka][#adj[ka]+1]={to=kb,length=len*1.4,hazard=0,unverified=true}
                positions[ka]=positions[ka] or a;positions[kb]=positions[kb] or b
            end
        end
    end
    for _,e in pairs(v.edges) do
        if (mode=='TOWED' and (e.towed or 0)>0) or (mode~='TOWED' and ((e.solo or 0)>0 or (e.towed or 0)>0)) then
            local a={x=e.ax,z=e.az};local b={x=e.bx,z=e.bz}
            local ka,kb=key(a),key(b)
            local risk=math.max(danger(a),danger(b))
            -- Multiple confirmed blocked-route incidents: fail closed until a
            -- safe drive revalidates the location. No route through the wall.
            if risk<2 then
                adj[ka]=adj[ka] or {};adj[ka][#adj[ka]+1]={to=kb,length=dist(a,b),hazard=risk}
                positions[ka]=positions[ka] or a;positions[kb]=positions[kb] or b
            end
        end
    end
    local function nearest(p)
        local best,d=nil,math.huge
        for k,node in pairs(positions) do local t=dist(node,p);if t<d then best,d=k,t end end
        if d>11 then return nil end
        return best
    end
    local source,target=nearest(start),nearest(finish)
    if not source or not target then return nil,'NENAUČENÁ ČÁST DVORA' end
    local costs={[source]=0};local routes={};local open={[source]=true};local visited={}
    local count=0
    while next(open) and count<1500 do
        count=count+1
        local node,value=nil,math.huge
        for k in pairs(open) do local cost=costs[k]+dist(positions[k],positions[target]);if cost<value then node,value=k,cost end end
        open[node]=nil
        if node==target then
            local backwards={};local cursor=node
            while cursor do table.insert(backwards,1,clone(positions[cursor]));cursor=routes[cursor] end
            return backwards,nil
        end
        visited[node]=true
        for _,e in ipairs(adj[node] or {}) do
            local penalty=math.min(60,e.hazard*12)
            local cost=costs[node]+e.length+penalty
            if not visited[e.to] and (costs[e.to]==nil or cost<costs[e.to]) then costs[e.to]=cost;routes[e.to]=node;open[e.to]=true end
        end
    end
    return nil,'ŽÁDNÉ OVĚŘENÉ SPOJENÍ'
end
function S.summary(c)
    local v=S.data(c);return {mapped=edgeCount(v.edges),observed=v.observed or 0,confirmed=v.confirmed or 0,center=v.center,manual=v.manual,hazards=v.blocked or 0}
end
-- Choose only a real, currently loaded farm facility; never invent a road.
-- Preview is read-only; execution remains with FS25 / Courseplay.
function S.previewNext(c)
    local center=S.data(c).center
    if not good(center) then return false,'Nejdřív zaměř střed dvora' end
    local vehicle=S.playerVehicle(c)
    if not vehicle then return false,'Pro náhled trasy sedni do vlastního stroje' end
    local px,pz=FMAUtil.position(vehicle)
    if not px or not pz then return false,'Poloha traktoru není dostupná' end
    local destinations={}
    for _,z in ipairs((c.digitalMap and c.digitalMap.zones) or {}) do
        if good(z) and bounds(c,z) and z.kind~='POLE' and z.kind~='TRASA' then destinations[#destinations+1]=z end
    end
    table.sort(destinations,function(a,b)return tostring(a.label or a.id)<tostring(b.label or b.id) end)
    if #destinations==0 then return false,'Nejsou načtené cíle dvora' end
    local last=c.farmSurveyPreview and c.farmSurveyPreview.index or 0
    local at=last%#destinations+1
    local target=destinations[at]
    local path,why=S.plan(c,{x=px,z=pz},target,S.classify(vehicle))
    c.farmSurveyPreview={index=at,name=tostring(target.label or target.kind),target=clone(target),path=path,reason=why,vehicle=vehicle}
    return path~=nil,path and ('Naučená trasa k '..tostring(target.label or '?')..' · '..#path..' bodů') or
       (tostring(target.label or '?')..' · '..tostring(why)..' · nutno projet/naučit')
end
-- A truly live miniature map, drawn in the own independent menu. Overlay
-- rotation follows GIANTS Overlay:setRotation; never touch the base game map.
function S.draw(c,overlay,box,rect,txt)
    local s=S.data(c);local center=s.center
    local x,y,w,h=box.x,box.y,box.w,box.h
    rect(x,y,w,h,0.022,0.067,0.064,1)
    if not center then
        txt(x+0.012,y+h*0.57,0.012,'STŘED FARMY NENÍ ZAMĚŘEN',0.98,0.72,0.42,true)
        txt(x+0.012,y+h*0.40,0.010,'Ulož stání nebo vyber UKOTVIT DVŮR.',0.79,0.87,0.77)
        return
    end
    local radius=math.max(70,math.min(480,tonumber(c.settings and c.settings.surveyViewRadius) or 180))
    local function proj(p)
        local px=x+w*0.5+(p.x-center.x)/(radius*2)*w
        local py=y+h*0.5-(p.z-center.z)/(radius*2)*h
        if px<x+0.003 or px>x+w-0.003 or py<y+0.003 or py>y+h-0.003 then return nil end
        return px,py
    end
    local function line(a,b,rr,gg,bb,alpha)
        local ax,ay=proj(a);local bx,by=proj(b)
        if not ax or not bx then return end
        local dx,dy=bx-ax,by-ay
        local len=math.sqrt(dx*dx+dy*dy)
        if len<0.0005 then return end
        local thick=0.0024
        -- Pivot is relative to overlay position, not to the game window.
        if type(overlay.setRotation)=='function' then
            overlay:setPosition((ax+bx)*0.5-len*0.5,(ay+by)*0.5-thick*0.5)
            overlay:setDimension(len,thick)
            overlay:setRotation((math.atan2 and math.atan2(dy,dx) or math.atan(dy,dx)),len*0.5,thick*0.5)
            overlay:setColor(rr,gg,bb,alpha or 1);overlay:render()
            overlay:setRotation(0,0,0)
        else rect((ax+bx)*0.5,(ay+by)*0.5,0.003,0.003,rr,gg,bb,alpha) end
    end
    for i=1,4 do
        local gx=x+w*i/5;rect(gx,y+0.004,0.0007,h-0.008,0.16,0.25,0.21,0.42)
        local gy=y+h*i/5;rect(x+0.004,gy,w-0.008,0.0007,0.16,0.25,0.21,0.42)
    end
    -- Lightweight REAL map background: road splines from the loaded AISystem.
    -- Bound drawing work independently of the full road costmap size and never
    -- confuse these provisional roads with physically verified farm tracks.
    local roads=c.engineRoads
    if roads and roads.edges then
        local previewKey=tostring(roads)..':'..key(center)..':'..tostring(math.floor(radius))
        if s.roadPreviewKey~=previewKey then
            local candidates={}
            for _,e in ipairs(roads.edges) do
                local mx,mz=(e.ax+e.bx)*0.5,(e.az+e.bz)*0.5
                if math.abs(mx-center.x)<=radius and math.abs(mz-center.z)<=radius then
                    candidates[#candidates+1]=e
                end
            end
            s.roadPreview={}
            local stride=math.max(1,math.ceil(#candidates/100))
            for i=1,#candidates,stride do
                if #s.roadPreview>=100 then break end
                s.roadPreview[#s.roadPreview+1]=candidates[i]
            end
            s.roadPreviewKey=previewKey
        end
        for _,e in ipairs(s.roadPreview or {}) do
            line({x=e.ax,z=e.az},{x=e.bx,z=e.bz},0.34,0.43,0.51,0.49)
        end
    end
    local displayed=0
    for _,e in pairs(s.edges or {}) do
        if displayed>=260 then break end
        local cR,cG,cB=0.37,0.87,0.48
        if (e.ai or 0)==0 then cR,cG,cB=0.93,0.74,0.29 end
        if (e.towed or 0)>0 then cR,cG,cB=0.35,0.82,0.96 end
        line({x=e.ax,z=e.az},{x=e.bx,z=e.bz},cR,cG,cB,0.94);displayed=displayed+1
    end
    -- Real FS25 zone coordinates: facilities are point markers, NOT guessed
    -- footprints or walls. Keep markers sparse and avoid remote field centres.
    local facilities=0
    for _,z in ipairs((c.digitalMap and c.digitalMap.zones) or {}) do
        if facilities>=28 then break end
        if z.kind~='POLE' and z.kind~='TRASA' and good(z) then
            local px,py=proj(z)
            if px then
                local r,g,b=0.74,0.73,0.64
                if z.kind=='JÁMA' then r,g,b=0.91,0.62,0.31
                elseif z.kind=='PARKING' or z.kind=='NÁŘADÍ' then r,g,b=0.72,0.80,0.95
                elseif z.kind=='BRÁNA' then r,g,b=0.97,0.92,0.38 end
                rect(px-0.002,py-0.002,0.004,0.004,r,g,b,1)
                facilities=facilities+1
            end
        end
    end
    local preview=c.farmSurveyPreview
    if preview and preview.path then
        for i=2,#preview.path do line(preview.path[i-1],preview.path[i],0.95,0.36,0.91,0.98) end
    end
    local hazardCount=0
    for _,hazard in pairs((c.navigationMap and c.navigationMap.hazards) or {}) do
        if hazardCount>=40 then break end
        if good(hazard) then local px,py=proj(hazard);if px then rect(px-0.0027,py-0.0027,0.0054,0.0054,1,0.26,0.19,0.96);hazardCount=hazardCount+1 end end
    end
    for _,live in pairs(c.active or {}) do
        local v=live.vehicle and live.vehicle.object
        if v then local px,pz=FMAUtil.position(v);local p={x=px,z=pz};if good(p) then local mx,my=proj(p);if mx then rect(mx-0.003,my-0.003,0.006,0.006,0.99,0.97,0.88,1) end end end
    end
    local mp=S.playerVehicle(c)
    if mp then local mx,mz=FMAUtil.position(mp);local p={x=mx,z=mz};if good(p) then local px,py=proj(p);if px then rect(px-0.004,py-0.004,0.008,0.008,1,1,1,1) end end end
    local cx,cy=proj(center);if cx then rect(cx-0.003,cy-0.003,0.006,0.006,0.55,0.93,0.60,1) end
    txt(x+0.010,y+h-0.021,0.010,'DVŮR · živě · poloměr '..math.floor(radius)..' m',0.95,0.98,0.89,true)
    txt(x+0.009,y+0.009,0.009,'ŽLUTÁ ručně · ZELENÁ AI · MODRÁ souprava · ČERVENÁ problém · FIALOVÁ náhled',0.88,0.95,0.84)
end
function S.writeDiagnostics(c,f)
    local sum=S.summary(c)
    f:write('\nFARM SURVEY edges=',sum.mapped,' manual=',tostring(sum.manual),' center=',sum.center and (tostring(sum.center.x)..','..tostring(sum.center.z)) or 'UNKNOWN',' confirmed=',sum.confirmed,'\n')
end
