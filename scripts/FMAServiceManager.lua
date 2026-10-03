-- Preventive service coordinator. Repairs are performed only after a real owned
-- vehicle reaches a verified/taught service point. No teleport, no field repair.
FMAServiceManager={VERSION='0.20.13.0'}

local function distanceSq(a,b)
    if not a or not b or not a.x or not a.z or not b.x or not b.z then return math.huge end
    local dx=a.x-b.x;local dz=a.z-b.z;return dx*dx+dz*dz
end

function FMAServiceManager.points(c)
    local out={}
    for _,z in ipairs(c.digitalMap and c.digitalMap.zones or {}) do
        if z.kind=='SERVIS' then out[#out+1]=z end
    end
    return out
end

function FMAServiceManager.findPoint(c,record)
    local best,bestD=nil,math.huge
    for _,p in ipairs(FMAServiceManager.points(c)) do
        local d=distanceSq(record,p)
        if d<bestD then best,bestD=p,d end
    end
    return best
end

function FMAServiceManager.price(record)
    if not record or not record.object then return nil end
    local p=FMAUtil.call(record.object,'getRepairPrice')
    if type(p)=='number' and p>=0 then return p end
    return nil
end

function FMAServiceManager.needs(c,record)
    if not record then return false end
    local damage=tonumber(record.damage) or tonumber(FMAUtil.call(record.object,'getDamageAmount')) or 0
    local preventive=FMAUtil.clamp(tonumber(c.settings.preventiveServiceDamage) or 0.60,0.30,0.90)
    local critical=FMAUtil.clamp(tonumber(c.settings.criticalServiceDamage) or 0.85,preventive+0.05,0.99)
    if damage>=critical then return true,'CRITICAL',damage end
    if damage>=preventive and (c.settings.strategyMode==3 or c.settings.serviceAtPreventiveIdle~=false) then return true,'PREVENTIVE',damage end
    return false,'OK',damage
end

local function hasUrgentWork(c)
    for _,t in pairs(c.tasks or {}) do
        local live=t.state=='pending' or t.state=='assembling' or t.state=='running' or t.state=='blocked'
        if live and (t.ownerRequested or (t.kind=='field' and (t.priority or 0)>=80)) then return true end
    end
    return false
end

function FMAServiceManager.start(c,record,point,state)
    if not record or not record.object or not point then return false,'Chybí stroj / servisní bod' end
    local price=FMAServiceManager.price(record)
    local money=FMAWorld.money(c.farmId)
    if price and money and money-price<(c.settings.reserve or 0) then return false,'Servis by porušil finanční rezervu farmy' end
    local task={id='service:'..record.key,kind='service',operation='service',label='Servis · '..record.name,state='running',priority=state=='CRITICAL' and 99 or 65,x=point.x,z=point.z,serviceState=state,servicePoint=point,price=price}
    local okTraffic,wait=true,nil
    if FMATraffic and FMATraffic.canStart then okTraffic,wait=FMATraffic.canStart(c,record,point,task,60000) end
    if not okTraffic then return false,wait end
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(c,record,{x=point.x,z=point.z,angle=point.angle or 0,tolerance=c.settings.serviceArrivalTolerance or 12})
    if not job then if FMATraffic then FMATraffic.release(c.traffic,record.key) end;return false,moveWhy or 'Stroj nepodporuje autonomní přejezd do servisu' end
    c.reservations[record.key]=task.id;record.busy=true
    c.active[job]={job=job,task=task,vehicle=record,start=c.now,lastProgress=c.now,x=record.x,z=record.z,fill=record.fillTotal,trafficTarget=point,transferMethod=moveMethod}
    local ok,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,c.farmId)
    if not ok then c.active[job]=nil;c.reservations[record.key]=nil;record.busy=false;if FMATraffic then FMATraffic.release(c.traffic,record.key) end;return false,tostring(err) end
    c:notify(record.name..' jede na '..(state=='CRITICAL' and 'nutný' or 'preventivní')..' servis')
    return true
end

function FMAServiceManager.dispatch(c)
    if not c.settings.enabled or c.settings.autoService==false then return false end
    for _,a in pairs(c.active or {}) do if a.task and a.task.kind=='service' then return false end end
    c.serviceRouteFailures=c.serviceRouteFailures or {}
    local candidates={}
    for _,v in ipairs(c.vehicles or {}) do
        local need,state,damage=FMAServiceManager.needs(c,v)
        local routeState=c.serviceRouteFailures[v.key]
        local routeReady=not routeState or (routeState.retryAt or 0)<=(c.now or 0)
        if need and routeReady and not v.busy and not c.reservations[v.key] and not c.excluded[v.key] and not (FMAGameNative and FMAGameNative.isManuallyControlled(v.object)) and type(v.object.repairVehicle)=='function' then
            -- Preventive service yields to urgent production/field work; critical service never does.
            if state=='CRITICAL' or not hasUrgentWork(c) then candidates[#candidates+1]={record=v,state=state,damage=damage} end
        end
    end
    table.sort(candidates,function(a,b)return a.damage>b.damage end)
    for _,row in ipairs(candidates) do
        local point=FMAServiceManager.findPoint(c,row.record)
        if point then
            local ok,why=FMAServiceManager.start(c,row.record,point,row.state)
            if ok then return true end
            c:issue('serviceRoute:'..row.record.key,row.record.name..' · servis',tostring(why),row.state=='CRITICAL' and 98 or 65)
        elseif row.state=='CRITICAL' then
            c:issue('servicePoint:'..row.record.key,row.record.name..' · chybí servisní bod','Manager stroj nepoužije. Nauč bod SERVIS na kartě Mapa nebo zajisti mapový workshop.',98)
        end
    end
    return false
end

function FMAServiceManager.onStopped(c,active)
    local r=active.vehicle;local task=active.task;local p=task.servicePoint
    c.serviceRouteFailures=c.serviceRouteFailures or {}
    if active.stopReason or active.outcome~='success' then
        local old=c.serviceRouteFailures[r.key] or {count=0}
        old.count=(old.count or 0)+1
        old.reason=active.stopReason or 'Přejezd do servisu nebyl dokončen'
        old.retryAt=(c.now or 0)+math.min(300000,15000*(2^(math.min(4,old.count-1))))
        c.serviceRouteFailures[r.key]=old
        c:issue(task.id,task.label,old.reason..' · další automatický pokus za '..tostring(math.floor((old.retryAt-(c.now or 0))/1000))..' s',95);return true
    end
    local x,z=FMAUtil.position(r.object)
    local tol=c.settings.serviceArrivalTolerance or 12
    if not x or not p or (x-p.x)^2+(z-p.z)^2>tol*tol then c:issue(task.id,task.label,'Stroj nedojel do servisní zóny',95);return true end
    local price=FMAServiceManager.price(r)
    local money=FMAWorld.money(c.farmId)
    if price and money and money-price<(c.settings.reserve or 0) then c:issue(task.id,task.label,'Servis zrušen: finanční rezerva farmy',95);return true end
    local ok,err=pcall(r.object.repairVehicle,r.object)
    if not ok then c:issue(task.id,task.label,'Opravu nelze provést: '..tostring(err),95);return true end
    r.damage=tonumber(FMAUtil.call(r.object,'getDamageAmount')) or 0;r.serviceState='OK';c.serviceRouteFailures[r.key]=nil
    FMADiagnostics.event(c,'service.repaired',r.key,'price='..tostring(price or '?'))
    c:notify(r.name..' · servis dokončen')
    c.elapsed=c.settings.scanSeconds*1000
    return true
end

function FMAServiceManager.writeDiagnostics(c,f)
    f:write('\nSERVICE PLANNER\n')
    f:write('auto=',tostring(c.settings.autoService~=false),' points=',tostring(#FMAServiceManager.points(c)),' queue=',tostring(#(c.serviceQueue or {})),'\n')
    for _,q in ipairs(c.serviceQueue or {}) do f:write(tostring(q.vehicle and q.vehicle.name),' state=',tostring(q.state),' damage=',tostring(q.vehicle and q.vehicle.damage),' price=',tostring(FMAServiceManager.price(q.vehicle) or '?'),'\n') end
end
