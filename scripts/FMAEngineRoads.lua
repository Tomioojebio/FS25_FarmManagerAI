-- Read-only bridge to the REAL GIANTS AISystem road splines and navigation map.
-- These edges are map infrastructure (POTENTIAL routes), not proof that a
-- particular tractor+implement cleared a gate.  Only physical driving produces
-- the 'verified' FarmSurvey records.  No changes are made to the game's map.
FMAEngineRoads={VERSION='0.20.50.0',SAMPLE_METRES=5,MAX_EDGES=15000,MAX_SPLINES=1600,MAX_SEARCH=30000}
local R=FMAEngineRoads
local function isFinite(v) return type(v)=='number' and v==v and math.abs(v)<100000 end
local function valid(x,z) return isFinite(x) and isFinite(z) end
local function position(spline,t)
    if type(getSplinePosition)~='function' then return nil end
    local ok,x,y,z=pcall(getSplinePosition,spline,t)
    if ok and valid(x,z) then return {x=x,z=z} end
end
function R.scan(c)
    local mission=g_currentMission
    local ai=mission and mission.aiSystem
    if not ai then return false,'AISYSTEM_NOT_LOADED' end
    local map=(FMAWorldAtlas and FMAWorldAtlas.identity and FMAWorldAtlas.identity(mission)) or (mission.missionInfo and mission.missionInfo.mapId) or 'unknown'
    if c.engineRoads and c.engineRoads.map==map and c.engineRoads.ai==ai and c.engineRoads.finished then return true,c.engineRoads end
    local mapHandle=FMAUtil and FMAUtil.call(ai,'getNavigationMap') or ai.navigationMap
    local result={map=map,ai=ai,hasCostmap=mapHandle~=nil and mapHandle~=0,
        hasTraffic=mission.trafficSystem~=nil,edges={},splineCount=0,source='GIANTS_AISYSTEM',finished=false}
    c.engineRoads=result
    local candidates,unique={},{}
    local function add(node)
        if type(node)=='number' and node>0 and not unique[node] then unique[node]=true;candidates[#candidates+1]=node end
    end
    for _,spline in pairs(ai.roadSplines or {}) do add(spline) end
    if type(ai.getRoadSplines)=='function' then
        local ok,splines=pcall(ai.getRoadSplines,ai)
        if ok and type(splines)=='table' then
            for a,b in pairs(splines) do
                if type(b)=='number' then add(b)
                elseif b==true then add(a) end
            end
        end
    end
    -- The traffic root can contain road splines not explicitly registered as
    -- individual AI splines, so only use its geometry when already registered
    -- by AISystem. Never fabricate a road from an ordinary scene object.
    local function visit(node)
        if result.splineCount>=R.MAX_SPLINES or #result.edges>=R.MAX_EDGES then return end
        local isSpline=false
        if I3DUtil and type(I3DUtil.getIsSpline)=='function' then
            local ok,value=pcall(I3DUtil.getIsSpline,node)
            isSpline=ok and value==true
        end
        if not isSpline then return end
        local ok,len=pcall(getSplineLength,node)
        if not ok or not isFinite(len) or len<1 then return end
        result.splineCount=result.splineCount+1
        local count=math.max(1,math.ceil(len/R.SAMPLE_METRES))
        local prev=position(node,0)
        for i=1,math.min(count,R.MAX_EDGES-#result.edges) do
            local nextPos=position(node,i/count)
            if prev and nextPos then
                local width=nil
                if type(getUserAttribute)=='function' then
                    local worked,value=pcall(getUserAttribute,node,'maxWidth')
                    if worked then width=tonumber(value) end
                end
                result.edges[#result.edges+1]={ax=prev.x,az=prev.z,bx=nextPos.x,bz=nextPos.z,
                    id='ai:'..tostring(node)..':'..i,maxWidth=width,source='AI_SPLINE'}
            end
            prev=nextPos
        end
    end
    for _,node in ipairs(candidates) do
        if result.splineCount>=R.MAX_SPLINES or #result.edges>=R.MAX_EDGES then break end
        if type(getSplineLength)=='function' then visit(node) end
        if I3DUtil and type(I3DUtil.iterateRecursively)=='function' then
            pcall(I3DUtil.iterateRecursively,node,function(child) if child~=node then visit(child) end end,true)
        end
    end
    result.finished=true
    if FMADiagnostics and FMADiagnostics.event then
        FMADiagnostics.event(c,'map.realNavigationLoaded',map,
            'costmap='..tostring(result.hasCostmap)..' splines='..result.splineCount..' edges='..#result.edges)
    end
    c.diagnosticDirty=true
    return true,result
end
function R.near(c,p,radius)
    local result=c and c.engineRoads
    if not result or not result.edges or not p or not p.x or not p.z then return {} end
    local out={};local rr=(radius or 230)^2
    for _,e in ipairs(result.edges) do
        local dx,dz=e.ax-p.x,e.az-p.z
        if dx*dx+dz*dz<=rr then out[#out+1]=e end
    end
    return out
end

-- The GIANTS AISystem network is a candidate graph, not a list of confirmed
-- passages. Each returned waypoint is executed by GIANTS/CP with real physics.
-- Neither a nearest-road hop nor a new spline connection is marked verified.
local function roadKey(x,z)
    return math.floor(x*10+0.5)..":"..math.floor(z*10+0.5)
end
local function dist2(a,b)
    local dx,dz=a.x-b.x,a.z-b.z
    return dx*dx+dz*dz
end
local function suitable(e,mode)
    if mode~='TOWED' then return true end
    -- A non-certified road cannot prove clearance for a towed implement.
    return tonumber(e.maxWidth)~=nil and tonumber(e.maxWidth)>=4.5
end
local function buildGraph(roads,mode)
    local graph={nodes={},adj={},keys={},edgeCount=0}
    local terminals={}
    local function node(x,z)
        local k=roadKey(x,z)
        local id=graph.keys[k]
        if not id then
            id=#graph.nodes+1
            graph.keys[k]=id
            graph.nodes[id]={x=x,z=z}
            graph.adj[id]={}
        end
        return id
    end
    for _,e in ipairs(roads.edges or {}) do
        if valid(e.ax,e.az) and valid(e.bx,e.bz) and suitable(e,mode) then
            local a=node(e.ax,e.az)
            local b=node(e.bx,e.bz)
            -- Spline ends may meet a junction with sub-metre positional error.
            -- Track only explicit ends (not arbitrary parallel road points).
            local spline,index=string.match(tostring(e.id or ''),'^(ai:%d+):(%d+)$')
            if spline then
                local t=terminals[spline] or {firstIndex=math.huge,lastIndex=-1}
                index=tonumber(index)
                if index<t.firstIndex then t.firstIndex=index;t.first=a end
                if index>t.lastIndex then t.lastIndex=index;t.last=b end
                terminals[spline]=t
            end
            if a~=b then
                local dx,dz=e.bx-e.ax,e.bz-e.az
                local metres=math.sqrt(dx*dx+dz*dz)
                -- Reject degenerate/map-corrupt samples instead of bridging a gap.
                if metres>0.15 and metres<=R.SAMPLE_METRES*2.5 then
                    graph.adj[a][#graph.adj[a]+1]={to=b,cost=metres}
                    graph.adj[b][#graph.adj[b]+1]={to=a,cost=metres}
                    graph.edgeCount=graph.edgeCount+1
                end
            end
        end
    end
    -- Join only authentic spline terminals whose geometry already meets.
    -- No long guessed links and no connections between arbitrary nearby roads.
    local ends={}
    for _,t in pairs(terminals) do
        if t.first then ends[#ends+1]=t.first end
        if t.last then ends[#ends+1]=t.last end
    end
    local buckets={}
    local function bucket(x,z) return math.floor(x/2)..':'..math.floor(z/2) end
    for _,id in ipairs(ends) do
        local p=graph.nodes[id]
        local ix,iz=math.floor(p.x/2),math.floor(p.z/2)
        for dx=-1,1 do for dz=-1,1 do
            for _,other in ipairs(buckets[(ix+dx)..':'..(iz+dz)] or {}) do
                if other~=id then
                    local gap=math.sqrt(dist2(p,graph.nodes[other]))
                    if gap<=0.75 then
                        graph.adj[id][#graph.adj[id]+1]={to=other,cost=gap}
                        graph.adj[other][#graph.adj[other]+1]={to=id,cost=gap}
                    end
                end
            end
        end end
        local k=bucket(p.x,p.z)
        buckets[k]=buckets[k] or {}
        buckets[k][#buckets[k]+1]=id
    end
    return graph
end
local function push(h,id,cost)
    local i=#h+1
    while i>1 do
        local p=math.floor(i/2)
        if h[p].cost<=cost then break end
        h[i]=h[p];i=p
    end
    h[i]={id=id,cost=cost}
end
local function pop(h)
    local first=h[1]
    if not first then return nil end
    local last=h[#h];h[#h]=nil
    if #h>0 then
        local i=1
        while i*2<=#h do
            local child=i*2
            if child<#h and h[child+1].cost<h[child].cost then child=child+1 end
            if h[child].cost>=last.cost then break end
            h[i]=h[child];i=child
        end
        h[i]=last
    end
    return first
end
-- Plan across the WHOLE actual FS25 spline network, not only the yard radius.
-- This does not move a vehicle. If no connected path exists, fail closed.
-- Optional last-mile access is used only by the segment runner. The route planner
-- still cannot assert any off-road passage is clear: GIANTS must drive each
-- bounded access leg, and the progress watchdog checks actual arrival.
function R.route(c,start,finish,mode,accessMetres)
    local roads=c and c.engineRoads
    if not roads or not roads.hasCostmap or type(roads.edges)~='table' then
        return nil,'GIANTS_SILNICE_NEJSOU_DOSTUPNÉ'
    end
    if not start or not finish or not valid(start.x,start.z) or not valid(finish.x,finish.z) then
        return nil,'NEPLATNÉ_SOUŘADNICE'
    end
    mode=mode=='TOWED' and 'TOWED' or 'SOLO'
    roads.routeGraphs=roads.routeGraphs or {}
    local graph=roads.routeGraphs[mode]
    if not graph then graph=buildGraph(roads,mode);roads.routeGraphs[mode]=graph end
    if graph.edgeCount==0 then return nil,'CHYBÍ_OVĚŘENÁ_ŠÍŘKA_PRO_SOUPRAVU' end
    local from,to=nil,nil
    local fromDist,toDist=math.huge,math.huge
    for id,p in ipairs(graph.nodes) do
        local ds=dist2(start,p)
        local de=dist2(finish,p)
        if ds<fromDist then from,fromDist=id,ds end
        if de<toDist then to,toDist=id,de end
    end
    -- Do not assume that a 30m shortcut through a building connects a yard
    -- parking slot with the public road. AI has to verify the entrance first.
    local access=11
    if type(accessMetres)=='number' and accessMetres==accessMetres then
        access=math.max(11,math.min(32,accessMetres))
    end
    if fromDist>access*access then return nil,'START_NENÍ_U_SILNICE' end
    if toDist>access*access then return nil,'CÍL_NENÍ_U_SILNICE' end
    local hazard=(c.navigationMap and c.navigationMap.hazards) or {}
    local function blocked(id)
        local p=graph.nodes[id]
        local key=math.floor(p.x/16)..':'..math.floor(p.z/16)
        local row=hazard[key]
        return row and (row.failures or 0)>=2
    end
    if blocked(from) or blocked(to) then return nil,'NEPRŮJEZDNÉ_NAPOJENÍ' end
    local goal=graph.nodes[to]
    local function heuristic(id) return math.sqrt(dist2(graph.nodes[id],goal)) end
    local scores={[from]=0};local parents={};local closed={};local heap={}
    push(heap,from,heuristic(from))
    local explored=0
    while #heap>0 and explored<R.MAX_SEARCH do
        local candidate=pop(heap)
        local id=candidate.id
        if not closed[id] then
            closed[id]=true;explored=explored+1
            if id==to then
                local out={};local cursor=id
                while cursor do
                    local p=graph.nodes[cursor]
                    table.insert(out,1,{x=p.x,z=p.z})
                    cursor=parents[cursor]
                end
                return out,nil
            end
            for _,edge in ipairs(graph.adj[id]) do
                local nextId=edge.to
                if not closed[nextId] and not blocked(nextId) then
                    local newCost=scores[id]+edge.cost
                    if scores[nextId]==nil or newCost<scores[nextId] then
                        scores[nextId]=newCost;parents[nextId]=id
                        push(heap,nextId,newCost+heuristic(nextId))
                    end
                end
            end
        end
    end
    return nil,'SILNIČNÍ_SÍŤ_NEMÁ_SPOJENÍ'
end
