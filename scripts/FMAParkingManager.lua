-- Smart farm parking. IMPORTANT: map placeable root positions are diagnostics,
-- never driveable garage entrances. Only explicitly taught, physically visited
-- bay positions may trigger automated parking. All motion is GIANTS/CP AI,
-- verified by FMAReturnManager. No teleport, no guessed reversing in sheds.
FMAParkingManager={VERSION='0.20.33.0',MAX_BAYS=96}
local P=FMAParkingManager

local function dist2(a,b)
    if not a or not b or not a.x or not a.z or not b.x or not b.z then return math.huge end
    return (a.x-b.x)^2+(a.z-b.z)^2
end
local function valid(p)
    return p and type(p.x)=='number' and type(p.z)=='number' and p.x==p.x and p.z==p.z and math.abs(p.x)<100000 and math.abs(p.z)<100000
end
local function contains(str,needle) return tostring(str or ''):lower():find(needle,1,true)~=nil end

function P.siteType(p)
    if not p then return 'other' end
    local n=FMAUtil.name(p):lower()
    if p.spec_bunkerSilo or contains(n,'siláž') or contains(n,'silaz') or contains(n,'bunker') or contains(n,'jáma') then return 'silage' end
    if contains(n,'hnojiv') or contains(n,'herbic') or contains(n,'chemik') or contains(n,'fertiliz') or contains(n,'postřik') or contains(n,'postrik') then return 'supplies' end
    if contains(n,'hnůj') or contains(n,'hnoj') or contains(n,'mrv') or contains(n,'kejda') or contains(n,'manure') or contains(n,'slurry') then return 'manure' end
    if p.spec_husbandry then return 'livestock' end
    if contains(n,'garáž') or contains(n,'garaz') or contains(n,'garage') or contains(n,'vehicle hall') then return 'garage' end
    if contains(n,'přístřeš') or contains(n,'pristres') or contains(n,'kůlna') or contains(n,'kolna') or contains(n,'shed') or contains(n,'stodola') or contains(n,'hala') then return 'shelter' end
    if contains(n,'seník') or contains(n,'seno') or contains(n,'hay') or contains(n,'sláma') then return 'hay' end
    if p.spec_silo or contains(n,'obil') or contains(n,'grain') or contains(n,'silo') or contains(n,'šrot') then return 'grain' end
    if p.spec_workshop or contains(n,'dílna') or contains(n,'servis') or contains(n,'workshop') then return 'service' end
    return 'other'
end

function P.role(object,record,kind)
    if kind=='vehicle' then
        if (object and object.spec_combine) or (record and record.isGrainCombine) then return 'harvester' end
        local cls=record and record.machineClass or (FMAWorld and FMAWorld.machineClass and FMAWorld.machineClass(object))
        if cls=='tractor' or (object and object.spec_attacherJoints and object.spec_motorized) then return 'tractor' end
        if object and (object.spec_wheelLoader or object.spec_frontloader or object.spec_telehandler) then return 'loader' end
        return 'motorized'
    end
    if not object then return 'tool' end
    if object.spec_manureSpreader or object.spec_slurryTank then return 'manure' end
    if object.spec_leveler or object.spec_bunkerSiloCompacter then return 'silage' end
    if object.spec_sowingMachine or object.spec_planter then return 'seeder' end
    if object.spec_forageWagon then return 'silage' end
    if object.spec_mixerWagon or object.spec_strawBlower then return 'livestock' end
    if object.spec_baler or object.spec_tedder or object.spec_windrower or object.spec_mower then return 'hay' end
    if object.spec_sprayer then return 'sprayer' end
    if object.spec_trailer or object.spec_dischargeable or object.spec_baleLoader then return 'trailer' end
    if object.spec_cutter then return 'header' end
    if object.spec_plow or object.spec_cultivator or object.spec_roller then return 'tillage' end
    return 'tool'
end

function P.suggestSite(role)
    if role=='tractor' or role=='loader' then return 'garage' end
    if role=='harvester' or role=='motorized' then return 'shelter' end
    if role=='manure' then return 'manure' end
    if role=='silage' then return 'silage' end
    if role=='hay' then return 'hay' end
    if role=='livestock' then return 'livestock' end
    if role=='sprayer' or role=='seeder' then return 'supplies' end
    if role=='trailer' then return 'yard' end
    if role=='tillage' or role=='header' or role=='tool' then return 'shelter' end
    return 'yard'
end

function P.sitePreferences(role)
    local roles={
        tractor={'garage','shelter','yard'},loader={'garage','shelter','silage','yard'},
        harvester={'shelter','garage','yard'},motorized={'shelter','garage','yard'},
        manure={'manure','shelter','yard'},silage={'silage','shelter','yard'},
        hay={'hay','shelter','silage','yard'},livestock={'livestock','shelter','yard'},
        sprayer={'supplies','shelter','yard'},seeder={'supplies','shelter','yard'},
        trailer={'yard','shelter','grain'},header={'shelter','yard'},
        tillage={'shelter','yard'},tool={'shelter','yard'},
    }
    return roles[role] or {'yard','shelter'}
end
function P.scan(c)
    local out={}
    local ps=g_currentMission and g_currentMission.placeableSystem
    for _,placeable in pairs(ps and ps.placeables or {}) do
        if #out>=3000 then break end
        if placeable and not placeable.isDeleted and FMAUtil.owner(placeable)==c.farmId then
            local kind=P.siteType(placeable)
            if kind~='other' then
                local x,z=FMAUtil.position(placeable)
                if valid({x=x,z=z}) then out[#out+1]={object=placeable,name=FMAUtil.name(placeable),type=kind,x=x,z=z} end
            end
        end
    end
    c.parkingFacilities=out
    local advice={}
    for _,group in ipairs({{list=c.vehicles,kind='vehicle'},{list=c.loose,kind='tool'}}) do
        for _,record in ipairs(group.list or {}) do
            if #advice>=160 then break end
            local role=P.role(record.object,record,group.kind)
            local wanted=P.suggestSite(role)
            local x,z=FMAUtil.position(record.object)
            local near=x and P.nearbyFacility and P.nearbyFacility(c,{x=x,z=z},wanted) or nil
            advice[#advice+1]={key=record.key,name=record.name,kind=group.kind,role=role,
                wanted=wanted,near=near and near.name or nil}
        end
    end
    c.parkingAdvice=advice
    return out
end

function P.nearbyFacility(c,p,kind)
    local best=nil;local distance=65*65
    for _,row in ipairs(c.parkingFacilities or {}) do
        if not kind or row.type==kind then
            local d=dist2(p,row)
            if d<distance then best=row;distance=d end
        end
    end
    return best,distance
end

function P.bestFacilityForRole(c,p,role)
    local best,bestScore=nil,math.huge
    for order,kind in ipairs(P.sitePreferences(role)) do
        local facility,d=P.nearbyFacility(c,p,kind)
        if facility then
            local metric=math.sqrt(d)+order*11
            if metric<bestScore then best,bestScore=facility,metric end
        end
    end
    return best
end

function P.footprint(object,kind)
    local w,l=0,0
    if not object then return 5,10 end
    local objs={object}
    if kind=='vehicle' and FMAWorld and FMAWorld.operationalChildren then objs=FMAWorld.operationalChildren(object) end
    for _,v in ipairs(objs) do
        local size=v and v.size
        local a=size and (size.width or size.x) or FMAUtil.call(v,'getWidth')
        local b=size and (size.length or size.z) or FMAUtil.call(v,'getLength')
        if type(a)=='number' and a>0 and a<100 then w=math.max(w,a) end
        if type(b)=='number' and b>0 and b<100 then l=l+b end
    end
    -- Unknown ModHub dimensions are NOT a 2-metre-wide tractor by default.
    -- Keep conservative fallbacks; a trusted bay must still fit the complete rig.
    if w<=0 or l<=0 then
        local role=P.role(object,nil,kind)
        local fallbacks={tractor={3.5,8},harvester={9,17},loader={4,11},motorized={6,13},
            trailer={4.5,18},header={13,6},manure={4.5,14},silage={5,12},
            hay={5,14},livestock={4.5,12},seeder={6,12},sprayer={6,13},tillage={6,12},tool={5,12}}
        local dims=fallbacks[role] or {6,14}
        if w<=0 then w=dims[1] end
        if l<=0 then l=dims[2] end
    end
    return w,l
end

function P.pose(object)
    local x,z=FMAUtil.position(object)
    if not valid({x=x,z=z}) then return nil end
    local angle=0
    if localDirectionToWorld and object.rootNode and MathUtil and MathUtil.getYRotationFromDirection then
        local ok,dx,_,dz=pcall(localDirectionToWorld,object.rootNode,0,0,1)
        if ok and dx and dz then angle=MathUtil.getYRotationFromDirection(dx,dz) or 0 end
    end
    return {x=x,z=z,angle=angle}
end

-- Position alone is not an aligned parking result. Use real vehicle root
-- orientation when GIANTS exposes it; unknown orientation is never invented.
function P.isAligned(object,target,maxRadians)
    if not object or not target or type(target.angle)~='number' then return nil end
    if not localDirectionToWorld or not MathUtil or not MathUtil.getYRotationFromDirection or not object.rootNode then return nil end
    local ok,dx,_,dz=pcall(localDirectionToWorld,object.rootNode,0,0,1)
    if not ok or type(dx)~='number' or type(dz)~='number' then return nil end
    local angle=MathUtil.getYRotationFromDirection(dx,dz)
    if type(angle)~='number' then return nil end
    local d=((angle-target.angle+math.pi)%(2*math.pi))-math.pi
    return math.abs(d)<=(maxRadians or 0.45)
end

function P.teach(c,kind)
    if not c or not c.supported then return false,'Parkování lze učit jen v singleplayeru' end
    local driver=FMAFarmSurvey and FMAFarmSurvey.playerVehicle and FMAFarmSurvey.playerVehicle(c)
    if not driver or FMAUtil.owner(driver)~=c.farmId then return false,'Sedni do svého stroje a zastav v přesné parkovací poloze' end
    if FMAUtil.call(driver,'getIsAIActive')==true then return false,'Nejdřív vypni AI a bezpečně zastav' end
    local speed=FMAUtil.call(driver,'getLastSpeed')
    if type(speed)=='number' and speed>1 then return false,'Parkovací bod ukládej jen se stojícím strojem' end
    local obj=driver
    if kind=='tool' then
        obj=nil
        for _,linked in ipairs(FMAWorld and FMAWorld.operationalChildren and FMAWorld.operationalChildren(driver) or {}) do
            if linked~=driver and linked.spec_attachable and not (FMAAssembler and FMAAssembler.isPassiveAttachment and FMAAssembler.isPassiveAttachment(linked)) then
                obj=linked;break
            end
        end
        if not obj then return false,'Pro stání nářadí musí být nářadí fyzicky zapřažené' end
    end
    local p=P.pose(obj);local drive=P.pose(driver)
    if not p or not drive then return false,'FS25 neposkytuje ověřené souřadnice soupravy' end
    c.parkingBays=c.parkingBays or {}
    if FMAUtil.count(c.parkingBays)>=P.MAX_BAYS then return false,'Paměť parkovacích stání je plná' end
    for _,other in pairs(c.parkingBays) do
        if other.kind==kind and dist2(other,p)<5*5 then
            return false,'Tady už je naučené stání '..tostring(other.id)..' · další stání musí být oddělené'
        end
    end
    local profile=c.vehicleByKey and c.vehicleByKey[FMAWorld.vehicleKey(obj)] or nil
    local role=P.role(obj,profile,kind)
    local preferred=P.suggestSite(role)
    local facility=P.bestFacilityForRole(c,p,role)
    local facilityType=facility and facility.type or 'yard'
    local w,l=P.footprint(obj,kind)
    local id='B'..tostring((c.parkingBaySequence or 0)+1)
    while c.parkingBays[id] do c.parkingBaySequence=(c.parkingBaySequence or 0)+1;id='B'..tostring(c.parkingBaySequence+1) end
    c.parkingBaySequence=(c.parkingBaySequence or 0)+1
    c.parkingBays[id]={id=id,kind=kind,role=role,site=facilityType,x=p.x,z=p.z,angle=p.angle,
        width=w+2,length=l+3,driverKey=kind=='tool' and FMAWorld.vehicleKey(driver) or nil,
        driveX=drive.x,driveZ=drive.z,driveAngle=drive.angle,
        taughtFor=FMAWorld.vehicleKey(obj),source='OWNER_TAUGHT',label=facility and facility.name or 'Volné stání'}
    c.diagnosticDirty=true
    if FMAState then FMAState.save(c) end
    if FMADiagnostics then FMADiagnostics.event(c,'parking.bayTaught',id,kind..'/'..role..' '..tostring(p.x)..','..tostring(p.z)) end
    c:notify('Naučeno stání '..id..' · '..role..' · '..(facility and facility.name or 'dvůr'))
    return true,id
end

function P.removeLast(c)
    local maxId=nil;local index=-1
    for id in pairs(c.parkingBays or {}) do
        local n=tonumber(tostring(id):match('^B(%d+)$')) or 0
        if n>index and not (c.parkingLeases and c.parkingLeases[id]) then maxId=id;index=n end
    end
    if not maxId then return false,'Žádné volné stání nelze smazat' end
    c.parkingBays[maxId]=nil
    if FMAState then FMAState.save(c) end
    c:notify('Smazáno naučené parkovací stání '..maxId)
    return true
end

local function occupies(c,record,bay)
    local clearance=math.max(5,(bay.width or 4)/2+2)
    for _,v in ipairs(c.vehicles or {}) do
        if v.key~=record.key then
            local x,z=FMAUtil.position(v.object)
            if valid({x=x,z=z}) and dist2({x=x,z=z},bay)<clearance*clearance then return true,'parkovací místo obsadil '..tostring(v.name) end
        end
    end
    for _,tool in ipairs(c.loose or {}) do
        if tool.key~=record.key then
            local x,z=FMAUtil.position(tool.object)
            if valid({x=x,z=z}) and dist2({x=x,z=z},bay)<clearance*clearance then return true,'místo obsadilo nářadí '..tostring(tool.name) end
        end
    end
    return false
end

-- A recommendation never creates a fictional point in a building. Every
-- returned target must be an explicit physical pose visited by the owner.
function P.select(c,record,kind,driverKey,excludeId)
    if not c or c.settings and c.settings.smartParking==false or not record then return nil,'Chytré parkování je vypnuté' end
    local role=P.role(record.object,record,kind)
    local preferred=P.suggestSite(role)
    local width,length=P.footprint(record.object,kind)
    local best,score=nil,-math.huge
    for _,bay in pairs(c.parkingBays or {}) do
        local neighboringLease=false
        for id,owner in pairs(c.parkingLeases or {}) do
            local neighbor=c.parkingBays and c.parkingBays[id]
            if owner and neighbor and id~=bay.id then
                local radius=((bay.width or 6)+(neighbor.width or 6))*0.5+3
                if dist2(bay,neighbor)<radius*radius then neighboringLease=true;break end
            end
        end
        if not neighboringLease and bay.id~=excludeId and bay.source=='OWNER_TAUGHT' and bay.kind==kind and valid(bay)
            and (bay.role==role or (role=='trailer' and bay.role=='tool') or (role=='motorized' and (bay.role=='tractor' or bay.role=='harvester')))
            and (bay.width or 0)>=width+0.4 and (bay.length or 0)>=length+0.5
            and (kind~='tool' or not bay.driverKey or bay.driverKey==driverKey)
            and (not c.parkingLeases or not c.parkingLeases[bay.id]) then
            local occupied=occupies(c,record,bay)
            if not occupied then
                local facility=P.bestFacilityForRole(c,bay,role)
                local placeScore=facility and 30 or 0
                for order,site in ipairs(P.sitePreferences(role)) do
                    if bay.site==site then placeScore=placeScore+math.max(0,40-13*(order-1));break end
                end
                if bay.taughtFor==record.key then placeScore=placeScore+35 end
                local d=dist2(record,bay)
                local s=100+placeScore-math.sqrt(d)*0.04
                if s>score then best,score=bay,s end
            end
        end
    end
    return best,best and nil or ('Není volné naučené stání pro '..role..' · doporučeno '..preferred)
end

function P.reserve(c,bay,task)
    if not c or not bay or not task or not task.id then return false end
    c.parkingLeases=c.parkingLeases or {}
    if c.parkingLeases[bay.id] and c.parkingLeases[bay.id]~=task.id then return false end
    for id,owner in pairs(c.parkingLeases) do
        if owner~=task.id and id~=bay.id and c.parkingBays and c.parkingBays[id] then
            local other=c.parkingBays[id]
            local radius=((bay.width or 6)+(other.width or 6))*0.5+3
            if dist2(bay,other)<radius*radius then return false end
        end
    end
    c.parkingLeases[bay.id]=task.id;task.parkingBayId=bay.id
    return true
end
function P.release(c,task)
    if not c or not task then return end
    local id=task.parkingBayId
    if id and c.parkingLeases and c.parkingLeases[id]==task.id then c.parkingLeases[id]=nil end
    task.parkingBayId=nil
end

function P.organize(c)
    if not c or not c.supported then return false,'Přesuny jsou dostupné pouze v singleplayeru' end
    if FMAUtil.count(c.parkingBays or {})==0 then return false,'Nejdřív nauč aspoň jedno skutečné parkovací stání v kartě MAPA' end
    c.parkingOrganize=true;c.parkingOrganizeTried={};c.parkingOrganizeNext=0
    c:notify('Uspořádání techniky připraveno · jen volné stroje a naučená místa')
    return true
end

function P.update(c)
    if not c.parkingOrganize then return end
    if not c.settings or not c.settings.enabled or not c.inventorySafe or c.runtimePaused then return end
    if (c.now or 0)<(c.parkingOrganizeNext or 0) then return end
    c.parkingOrganizeNext=(c.now or 0)+7000
    for _,active in pairs(c.active or {}) do
        if active.task and active.task.kind=='return' and active.task.purpose=='parking' then return end
    end
    local considered=0;local candidates=0
    for _,r in ipairs(c.vehicles or {}) do
        if not (c.parkingOrganizeTried and c.parkingOrganizeTried[r.key]) then
            considered=considered+1
            if not r.busy and not (c.reservations and c.reservations[r.key]) and not FMAUtil.call(r.object,'getIsAIActive')
                and not (FMAGameNative and FMAGameNative.isManuallyControlled and FMAGameNative.isManuallyControlled(r.object)) then
                local bay=P.select(c,r,'vehicle')
                if bay then
                    candidates=candidates+1
                    local x,z=FMAUtil.position(r.object)
                    if not x or dist2({x=x,z=z},bay)>4*4 then
                        local task={id='parking:'..tostring(r.key)..':'..tostring(math.floor(c.now or 0)),kind='return',purpose='parking',
                            operation='park',label='Uspořádat · '..tostring(r.name),state='pending',home=bay}
                        if P.reserve(c,bay,task) then
                            local ok,why=FMAReturnManager.startDrive(c,r,bay,task,'vehicleHome')
                            if ok then
                                c.parkingOrganizeTried[r.key]=true
                                if FMADiagnostics then FMADiagnostics.event(c,'parking.organizeSent',r.key,bay.id) end
                                return
                            end
                            P.release(c,task)
                            if FMADiagnostics then FMADiagnostics.event(c,'parking.organizeFailed',r.key,tostring(why)) end
                        end
                    end
                end
            end
            c.parkingOrganizeTried[r.key]=true
        end
    end
    if considered==0 or candidates==0 then
        c.parkingOrganize=false
        c:notify('Uspořádání hotovo nebo čeká na další naučená stání; neznámé cesty se nezkoušejí naslepo')
    end
end

function P.writeDiagnostics(c,f)
    f:write('\nPARKING bays=',tostring(FMAUtil.count(c.parkingBays or {})),' facilities=',tostring(#(c.parkingFacilities or {})),
        ' organizing=',tostring(c.parkingOrganize==true),' leases=',tostring(FMAUtil.count(c.parkingLeases or {})),'\n')
    for _,row in ipairs(c.parkingAdvice or {}) do
        f:write('ADVICE ',tostring(row.name),' role=',row.role,' preferred=',row.wanted,' near=',tostring(row.near or 'unknown'),'\n')
    end
    for _,row in ipairs(c.parkingFacilities or {}) do f:write('FACILITY ',tostring(row.type),' ',tostring(row.name),' x=',tostring(row.x),' z=',tostring(row.z),' [ROOT ONLY / NOT A PARKING GOAL]\n') end
    for id,bay in pairs(c.parkingBays or {}) do
        f:write('BAY ',id,' kind=',bay.kind,' role=',bay.role,' site=',bay.site,' x=',bay.x,' z=',bay.z,
            ' width=',bay.width,' length=',bay.length,' taughtFor=',tostring(bay.taughtFor),
            ' reserved=',tostring(c.parkingLeases and c.parkingLeases[id] or '-'),'\n')
    end
end
