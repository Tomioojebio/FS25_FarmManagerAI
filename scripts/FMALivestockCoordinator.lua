-- Advanced livestock planning and physical feed-mixing workflow.
-- All rations are discovered from the currently loaded FS25 AnimalFoodSystem; no animal-specific recipe is hard coded.
FMALivestockCoordinator = {}

local function fillTypeList(values)
    local out={}
    if type(values)~='table' then return out end
    for k,v in pairs(values) do
        if type(v)=='number' then out[#out+1]=v
        elseif type(k)=='number' and v==true then out[#out+1]=k
        elseif type(v)=='table' then
            local ft=v.fillTypeIndex or v.fillType
            if type(ft)=='number' then out[#out+1]=ft end
        end
    end
    return out
end

local function safeLevel(place, fillType)
    return FMAUtil.call(place,'getHusbandryFillLevel',fillType,nil) or FMAUtil.call(place,'getHusbandryFillLevel',fillType) or 0
end

local function safeCapacity(place, fillType)
    return FMAUtil.call(place,'getHusbandryCapacity',fillType,nil) or FMAUtil.call(place,'getHusbandryCapacity',fillType) or 0
end

local function ownLoadingSources(farmId, fillType)
    local out={}
    local storage=g_currentMission and g_currentMission.storageSystem
    for _,station in pairs(FMAUtil.call(storage,'getLoadingStations') or {}) do
        local place=station.owningPlaceable
        local supported=FMAUtil.call(station,'getAISupportedFillTypes') or {}
        if place and FMAUtil.owner(place)==farmId and supported[fillType]==true then
            local level=FMAUtil.call(station,'getFillLevel',fillType,farmId) or 0
            if level>1 then out[#out+1]={station=station,level=level,place=place} end
        end
    end
    table.sort(out,function(a,b)return a.level>b.level end)
    return out
end

local function bestSource(farmId, choices)
    local best=nil
    for _,fillType in ipairs(fillTypeList(choices or {})) do
        local sources=ownLoadingSources(farmId,fillType)
        if #sources>0 and (best==nil or sources[1].level>best.level) then
            best={fillType=fillType,station=sources[1].station,level=sources[1].level}
        end
    end
    return best
end

local function husbandryDestination(place, farmId, fillType)
    local storage=g_currentMission and g_currentMission.storageSystem
    for _,station in pairs(FMAUtil.call(storage,'getUnloadingStations') or {}) do
        if station.owningPlaceable==place then
            local supported=FMAUtil.call(station,'getAISupportedFillTypes') or {}
            if supported[fillType]==true then return station end
        end
    end
    return nil
end

local function animalFoodData(place)
    local spec=place and place.spec_husbandryFood
    local sys=g_currentMission and g_currentMission.animalFoodSystem
    if not spec or not sys or spec.animalTypeIndex==nil then return nil,nil,{} end
    local food=FMAUtil.call(sys,'getAnimalFood',spec.animalTypeIndex)
    local mixtures=FMAUtil.call(sys,'getMixturesByAnimalTypeIndex',spec.animalTypeIndex) or {}
    return spec,food,mixtures
end

local function mixturePlan(farmId, mixtureFillType)
    local sys=g_currentMission and g_currentMission.animalFoodSystem
    local mix=sys and FMAUtil.call(sys,'getMixtureByFillType',mixtureFillType)
    if not mix or not mix.ingredients or #mix.ingredients==0 then return nil end
    local ingredients={};local complete=true;local availability=math.huge
    for _,ingredient in pairs(mix.ingredients) do
        local source=bestSource(farmId,ingredient.fillTypes or {})
        local weight=tonumber(ingredient.weight) or 0
        if weight<=0 then complete=false end
        if not source then
            complete=false
            ingredients[#ingredients+1]={weight=weight,choices=fillTypeList(ingredient.fillTypes or {}),missing=true}
        else
            availability=math.min(availability,source.level/math.max(weight,0.001))
            ingredients[#ingredients+1]={weight=weight,choices=fillTypeList(ingredient.fillTypes or {}),fillType=source.fillType,source=source.station,available=source.level}
        end
    end
    return {fillType=mixtureFillType,mixture=mix,ingredients=ingredients,complete=complete,availableMixLiters=availability==math.huge and 0 or availability}
end

function FMALivestockCoordinator.feedPlan(place,farmId,settings)
    local spec,food,mixtures=animalFoodData(place)
    if not spec then return nil end
    local total=FMAUtil.call(place,'getTotalFood') or 0
    local capacity=FMAUtil.call(place,'getFoodCapacity') or spec.capacity or 0
    local perHour=FMAUtil.call(place,'getFoodLitersPerHour') or spec.litersPerHour or 0
    local plan={place=place,name=FMAUtil.name(place),total=total,capacity=capacity,perHour=perHour,groups={},mixtures={},ratio=capacity>0 and total/capacity or 1}
    if food and food.groups then
        for _,group in pairs(food.groups) do
            local level=0
            local groupFillTypes=fillTypeList(group.fillTypes or {})
            for _,ft in ipairs(groupFillTypes) do level=level+(spec.fillLevels and spec.fillLevels[ft] or 0) end
            plan.groups[#plan.groups+1]={title=group.title or 'Krmivo',productionWeight=tonumber(group.productionWeight) or 0,fillTypes=groupFillTypes,level=level}
        end
        table.sort(plan.groups,function(a,b)return a.productionWeight>b.productionWeight end)
    end
    for _,entry in pairs(mixtures or {}) do
        local ft
        if type(entry)=='table' then ft=entry.fillTypeIndex or entry.fillType
        elseif type(entry)=='number' then ft=entry
        elseif type(entry)=='boolean' and entry==true and type(_)=='number' then ft=_ end
        local mp=type(ft)=='number' and mixturePlan(farmId,ft) or nil
        if mp then plan.mixtures[#plan.mixtures+1]=mp end
    end
    local needed=math.max(0,capacity*(settings.foodTarget or 0.70)-total)
    plan.needed=needed
    plan.hoursRemaining=perHour>0 and total/perHour or math.huge
    -- Prefer a fully sourceable game-defined mixture. Otherwise choose the best production group with own stock.
    local chosen=nil
    for _,mp in ipairs(plan.mixtures) do
        if mp.complete and mp.availableMixLiters>100 and (not chosen or mp.availableMixLiters>chosen.availableMixLiters) then chosen=mp end
    end
    plan.mixturePlan=chosen
    if not chosen then
        for _,group in ipairs(plan.groups) do
            local source=bestSource(farmId,group.fillTypes)
            if source then plan.directFillType=source.fillType;plan.directSource=source.station;plan.directAvailable=source.level;plan.selectedGroup=group;break end
        end
    end
    return plan
end

local function outputRow(rows,issues,place,name,fillType,perHour,settings,label,farmId)
    if not fillType then return end
    local level=safeLevel(place,fillType);local capacity=safeCapacity(place,fillType)
    if capacity<=0 then return end
    local ratio=level/capacity
    local free=math.max(0,capacity-level)
    local hours=perHour and perHour>0 and free/perHour or math.huge
    rows[#rows+1]={id='livestock:output:'..tostring(place)..':'..tostring(fillType),name=name..' · '..(label or FMAWorld.fillName(fillType)),ratio=1-ratio,value=level,capacity=capacity,message='Výstup chovu · volná kapacita '..math.floor((1-ratio)*100)..' %',priority=92,neutral=false,output=true,source='FS25_STORAGE'}
    if ratio>=(settings.outputMoveAt or 0.75) or hours<=(settings.outputForecastHours or 12) then
        local detail=FMAWorld.fillName(fillType)..' '..math.floor(level)..' / '..math.floor(capacity)..' l'
        if hours<math.huge then detail=detail..' · při současné produkci plné přibližně za '..string.format('%.1f',hours)..' h' end
        local destination=nil
        if FMALogistics then destination=FMALogistics.bestDestination(farmId,nil,fillType,false) end
        if destination then detail=detail..'. Nalezen vlastní cíl: '..FMAUtil.name(destination.owningPlaceable or destination)..'.'
        else detail=detail..'. Vlastní AI cíl nebyl nalezen; Manager upozorní dřív, než se výstup naplní.' end
        if FMALogistics and FMALogistics.isOrganicFertilizer(fillType) and settings.retainOrganicFertilizer then detail=detail..' Organické hnojivo je rezervované pro vlastní pole.' end
        issues[#issues+1]={id='animalOutput:'..tostring(place)..':'..tostring(fillType),title=name..' · odvoz '..FMAWorld.fillName(fillType),detail=detail,priority=ratio>0.92 and 99 or 86}
    end
end

function FMALivestockCoordinator.scan(farmId,settings)
    local rows,issues,plans={},{},{}
    local placeables=g_currentMission.placeableSystem and g_currentMission.placeableSystem.placeables or {}
    for _,p in pairs(placeables) do
        if FMAUtil.owner(p)==farmId and p.spec_husbandry then
            local name=FMAUtil.name(p)
            local gameInfos=FMAUtil.call(p,'getConditionInfos') or {}
            local hasGameConditions=false
            for i,info in ipairs(gameInfos) do
                if info.ratio~=nil and not info.disabled then
                    hasGameConditions=true
                    local ratio=info.invertedBar and (1-info.ratio) or info.ratio
                    rows[#rows+1]={id='livestock:game:'..tostring(p)..':'..tostring(i),name=name..' · '..tostring(info.title or 'stav'),ratio=ratio,value=info.value,capacity=info.capacity,message='Stav přímo z rozhraní chovu FS25',priority=100,gameCondition=true,source='FS25',neutral=info.neutral==true}
                end
            end
            if p.spec_husbandryFood then
                local plan=FMALivestockCoordinator.feedPlan(p,farmId,settings)
                if plan then
                    plans[p]=plan
                    local feedMessage='Krmná dávka · '..(plan.mixturePlan and ('směs '..FMAWorld.fillName(plan.mixturePlan.fillType)) or plan.directFillType and FMAWorld.fillName(plan.directFillType) or 'čeká na suroviny')
                    if plan.hoursRemaining<math.huge then feedMessage=feedMessage..' · zásoba asi na '..string.format('%.1f',plan.hoursRemaining)..' h' end
                    if not hasGameConditions then rows[#rows+1]={id='livestock:food:'..tostring(p),name=name..' · krmivo',ratio=plan.ratio,value=plan.total,capacity=plan.capacity,message=feedMessage,priority=100,source='FALLBACK'} end
                    if plan.ratio<(settings.foodEmergency or 0.15) then
                        issues[#issues+1]={id='animal:critical:'..tostring(p),title=name..' · KRITICKÉ KRMIVO',detail='Zásoba pod '..math.floor((settings.foodEmergency or 0.15)*100)..' %. Krmná četa má absolutní prioritu.',priority=100}
                    elseif plan.hoursRemaining<=(settings.feedForecastHours or 12) then
                        issues[#issues+1]={id='animal:forecast:'..tostring(p),title=name..' · připravit krmivo',detail='Při současné spotřebě zbývá přibližně '..string.format('%.1f',plan.hoursRemaining)..' h. Manager plánuje doplnění předem.',priority=91}
                    end
                    if plan.needed>100 and plan.mixturePlan then
                        local parts={}
                        for _,ing in ipairs(plan.mixturePlan.ingredients or {}) do parts[#parts+1]=string.format('%s %.0f%%',ing.fillType and FMAWorld.fillName(ing.fillType) or 'CHYBÍ', (ing.weight or 0)*100) end
                        plan.summary='Příští dávka '..math.floor(math.min(plan.needed,plan.mixturePlan.availableMixLiters or plan.needed))..' l · '..table.concat(parts,' + ')
                    end
                    if plan.needed>100 and not plan.mixturePlan and not plan.directSource then
                        local wanted={}
                        if #plan.mixtures>0 then
                            for _,ing in ipairs(plan.mixtures[1].ingredients or {}) do
                                if ing.missing then
                                    local names={};for _,ft in ipairs(ing.choices or {}) do names[#names+1]=FMAWorld.fillName(ft) end
                                    wanted[#wanted+1]=table.concat(names,' / ')
                                end
                            end
                        end
                        issues[#issues+1]={id='animal:missingFeed:'..tostring(p),title=name..' · chybí krmivo/suroviny',detail=#wanted>0 and ('Chybí vlastní zásoba: '..table.concat(wanted,', ')) or 'Nenalezen vlastní zdroj vhodného krmiva podle receptury této mapy.',priority=98}
                    end
                end
            end
            local straw=p.spec_husbandryStraw
            if straw and straw.inputFillType then
                local level=safeLevel(p,straw.inputFillType);local cap=safeCapacity(p,straw.inputFillType)
                if cap>0 then
                    local ratio=level/cap;local hours=(straw.inputLitersPerHour or 0)>0 and level/straw.inputLitersPerHour or math.huge
                    if not hasGameConditions then rows[#rows+1]={id='livestock:straw:'..tostring(p),name=name..' · podestýlka/sláma',ratio=ratio,value=level,capacity=cap,message='Podestýlka · výroba hnoje',priority=96,source='FALLBACK'} end
                    if ratio<(settings.strawTarget or 0.65) or hours<=(settings.beddingForecastHours or 12) then
                        issues[#issues+1]={id='animal:straw:'..tostring(p),title=name..' · doplnit slámu',detail='Sláma '..math.floor(ratio*100)..' %'..(hours<math.huge and (' · zásoba asi na '..string.format('%.1f',hours)..' h') or '')..'. Manager připraví fyzické zásobování/podestýlku.',priority=ratio<(settings.strawEmergency or 0.15) and 99 or 88}
                    end
                end
                outputRow(rows,issues,p,name,straw.outputFillType,straw.outputLitersPerHour,settings,'hnůj',farmId)
            end
            local liquid=p.spec_husbandryLiquidManure
            if liquid then outputRow(rows,issues,p,name,liquid.fillType,liquid.litersPerHour,settings,'kejda / močůvka',farmId) end
            local milk=p.spec_husbandryMilk
            if milk then
                for _,ft in ipairs(fillTypeList(milk.fillTypes or {})) do outputRow(rows,issues,p,name,ft,milk.litersPerHour and milk.litersPerHour[ft],settings,'mléko',farmId) end
            end
            local water=p.spec_husbandryWater
            if water and FillType and FillType.WATER then
                local level=safeLevel(p,FillType.WATER);local cap=safeCapacity(p,FillType.WATER)
                if cap>0 then
                    local ratio=level/cap
                    if not hasGameConditions then rows[#rows+1]={id='livestock:water:'..tostring(p),name=name..' · voda',ratio=ratio,value=level,capacity=cap,message='Napájení',priority=98,source='FALLBACK'} end
                    if ratio<(settings.waterTarget or 0.60) then issues[#issues+1]={id='animal:water:'..tostring(p),title=name..' · voda',detail='Napájení je na '..math.floor(ratio*100)..' %. Pokud není automatické, Manager připraví cisternu.',priority=ratio<0.15 and 100 or 90} end
                end
            end
        end
    end
    return rows,issues,plans
end

-- Convert real husbandry deficits into owner-visible work orders. The previous
-- implementation emitted a notification for missing straw/water, but created
-- no JOB unless the map exposed an AI unloading trigger. The new task explicitly
-- distinguishes a supported physical transport from a missing map adapter.
-- Never transfer feed virtually and never send a wagon to a building root.
function FMALivestockCoordinator.careProposals(controller)
    local out={}
    local settings=controller.settings or {}
    if not settings.livestock then return out end
    local farmId=controller.farmId
    local system=g_currentMission and g_currentMission.placeableSystem
    local placeables=FMAUtil.call(system,'getPlaceables') or (system and system.placeables) or {}
    local function make(place,fillType,label,level,capacity,target,priority)
        if not fillType or not capacity or capacity<=0 then return end
        local ratio=level/math.max(1,capacity)
        if ratio>=target then return end
        local stableKey=FMAWorld.vehicleKey(place)..':'..tostring(fillType)
        local source=bestSource(farmId,{fillType})
        local destination=husbandryDestination(place,farmId,fillType)
        local x,z=FMAUtil.position(place)
        local task={id='livestock:care:'..stableKey,operation='supply',kind='livestockNeed',
            label=FMAUtil.name(place)..' · '..label,husbandry=place,fillType=fillType,
            needed=math.max(0,capacity*target-level),priority=priority or 96,
            x=x,z=z,state='blocked',phase='POTŘEBA CHOVU · OVĚŘUJE DOPRAVU',
            reason=nil,attempts=0,blockedByIntegration=true}
        if not source then
            task.reason='Chybí AI nakládací stanice pro '..FMAWorld.fillName(fillType)..'; balíky mohou být fyzicky ve stodole, ale musí se nejprve vyskladnit a naložit'
        elseif not destination then
            task.reason='Fyzický výsypný trigger může existovat; pro '..FMAWorld.fillName(fillType)..' ale ještě není ověřen jako AIJobDeliver cíl, jízda na kořen budovy není bezpečná'
        else
            task.source=source.station;task.destination=destination;task.available=source.level
            task.free=math.max(0,capacity-level);task.state='pending';task.kind='supply'
            task.blockedByIntegration=nil;task.reason=nil;task.phase='ČEKÁ NA PŘIDĚLENÍ PŘEPRAVNÍ SOUPRAVY'
        end
        out[#out+1]=task
    end
    for _,p in pairs(placeables) do
        if FMAUtil.owner(p)==farmId and p.spec_husbandry then
            local straw=p.spec_husbandryStraw
            if straw and straw.inputFillType then
                local capacity=safeCapacity(p,straw.inputFillType)
                make(p,straw.inputFillType,'podestýlka/sláma',safeLevel(p,straw.inputFillType),capacity,
                    settings.strawTarget or 0.65,96)
            end
            local water=p.spec_husbandryWater
            if water and not water.automaticWaterSupply then
                local waterType=water.fillType or (FillType and FillType.WATER)
                if waterType then make(p,waterType,'napájení/voda',safeLevel(p,waterType),safeCapacity(p,waterType),settings.waterTarget or 0.60,98) end
            end
            local plan=controller.livestockPlans and controller.livestockPlans[p]
            if plan and plan.capacity>0 and plan.needed>100 and
                not (plan.mixturePlan and plan.mixturePlan.complete and controller.livestockMixPlaces and controller.livestockMixPlaces[p]) then
                if plan.directFillType then
                    make(p,plan.directFillType,'doplnit krmivo',plan.total,
                        plan.capacity,settings.foodTarget or 0.70,99)
                elseif not plan.mixturePlan then
                    local x,z=FMAUtil.position(p)
                    out[#out+1]={id='livestock:feedMissing:'..FMAWorld.vehicleKey(p),
                        kind='livestockNeed',operation='supply',label=plan.name..' · chybí krmivo',
                        state='blocked',blockedByIntegration=true,phase='CHYBÍ KRMNÁ DÁVKA',
                        reason='Ve vlastním skladu není vhodná krmná surovina ani úplná receptura. Nakup nebo vyrob krmivo; Manager ho nepřičte virtuálně.',
                        priority=99,x=x,z=z,needed=plan.needed}
                end
            end
        end
    end
    return out
end

function FMALivestockCoordinator.proposals(controller)
    local out={};controller.livestockMixPlaces={}
    for place,plan in pairs(controller.livestockPlans or {}) do
        if plan.capacity>0 and plan.needed>100 then
            if plan.mixturePlan and plan.mixturePlan.complete then
                local dest=husbandryDestination(place,controller.farmId,plan.mixturePlan.fillType)
                if dest then
                    controller.livestockMixPlaces[place]=true
                    out[#out+1]={id='ration:'..tostring(place),kind='livestockMix',operation='mixFeed',priority=99,label=plan.name..' · namíchat krmnou dávku',state='pending',attempts=0,
                        husbandry=place,destination=dest,mixturePlan=plan.mixturePlan,mixtureFillType=plan.mixturePlan.fillType,needed=plan.needed,x=select(1,FMAUtil.position(place)),z=select(2,FMAUtil.position(place))}
                else
                    controller:issue('rationDest:'..tostring(place),plan.name..' · krmná dávka','Mapa nepředává krmný žlab jako AI vykládací stanici pro '..FMAWorld.fillName(plan.mixturePlan.fillType)..'. Krmivo bude hlídané, ale fyzické vyložení směsi vyžaduje další mapový adaptér.',95)
                end
            end
        end
    end
    return out
end

local function findMixerFillUnit(record,ingredients)
    for _,obj in ipairs(FMAWorld.children(record.object)) do
        if obj.spec_mixerWagon then
            local units=FMAUtil.call(obj,'getFillUnits') or (obj.spec_fillUnit and obj.spec_fillUnit.fillUnits) or {}
            for i,unit in pairs(units) do
                local all=true
                for _,ing in ipairs(ingredients or {}) do
                    local supported=FMAUtil.call(obj,'getFillUnitSupportsFillType',i,ing.fillType)
                    if supported==nil then supported=unit.supportedFillTypes and unit.supportedFillTypes[ing.fillType] end
                    if supported~=true then all=false;break end
                end
                if all then return obj,i,FMAUtil.call(obj,'getFillUnitCapacity',i) or unit.capacity or 0 end
            end
        end
    end
    return nil
end

local function stationPoint(record,obj,index,fillType,station)
    local ok,x,z,dx,dz,trigger=pcall(station.getAITargetPositionAndDirection,station,fillType)
    if not ok or not x or not z or not trigger then return nil end
    local offsetZ=0
    local node=FMAUtil.call(obj,'getFillUnitRootNode',index)
    if node and record.object.rootNode and localToLocal then
        local okOffset,_,_,oz=pcall(localToLocal,node,record.object.rootNode,0,0,0)
        if okOffset and oz then offsetZ=oz end
    end
    return {station=station,trigger=trigger,x=x+(dx or 0)*(-offsetZ),z=z+(dz or 0)*(-offsetZ),dx=dx or 0,dz=dz or 1}
end

local function startGoto(controller,parent,record,point,phase,index)
    if FMATraffic and FMATraffic.canStart then
        local free,wait=FMATraffic.canStart(controller,record,point,{id='rationDrive:'..parent.id,kind='livestockMixDrive'},45000)
        if not free then return false,wait end
    end
    local angle=MathUtil and MathUtil.getYRotationFromDirection and MathUtil.getYRotationFromDirection(point.dx or 0,point.dz or 1) or 0
    local job,moveWhy,moveMethod=FMAAI.createTransferJob(controller,record,{x=point.x,z=point.z,angle=angle,tolerance=5})
    if not job then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,moveWhy or 'Krmná souprava neumí autonomní přejezd' end
    local t={id='rationDrive:'..parent.id..':'..tostring(index or 0),kind='livestockMixDrive',operation='mixFeed',label=parent.label,parentTaskId=parent.id,phase=phase,ingredientIndex=index,point=point,priority=100,state='running'}
    controller.reservations[record.key]=t.id;record.busy=true
    controller.active[job]={job=job,task=t,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal,trafficTarget=point,transferMethod=moveMethod}
    local okStart,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not okStart then controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(err) end
    return true
end

function FMALivestockCoordinator.dispatch(controller,parent,record)
    if not parent.mixturePlan or not parent.destination then return false,'Chybí dynamická receptura nebo krmný cíl' end
    local obj,index,capacity=findMixerFillUnit(record,parent.mixturePlan.ingredients)
    if not obj or capacity<=0 then return false,'Vybraná souprava nemá míchací jednotku podporující všechny suroviny této receptury' end
    local current=FMAUtil.call(obj,'getFillUnitFillLevel',index) or 0
    if current>capacity*0.08 then return false,'Krmný vůz není dostatečně prázdný pro novou přesnou dávku' end
    local total=math.min(parent.needed or capacity*0.85,capacity*0.88,parent.mixturePlan.availableMixLiters or capacity)
    if total<100 then return false,'Pro krmnou dávku není dost vlastních surovin' end
    local ingredients={}
    for _,ing in ipairs(parent.mixturePlan.ingredients) do
        local point=stationPoint(record,obj,index,ing.fillType,ing.source)
        if not point then return false,'Zdroj '..FMAWorld.fillName(ing.fillType)..' nemá použitelný AI nakládací bod' end
        ingredients[#ingredients+1]={fillType=ing.fillType,source=ing.source,point=point,targetDelta=total*(ing.weight or 0),weight=ing.weight or 0}
    end
    controller.livestockSessions=controller.livestockSessions or {}
    local session={parent=parent,vehicle=record,object=obj,fillUnitIndex=index,capacity=capacity,total=total,ingredients=ingredients,index=1,phase='driveIngredient',started=controller.now}
    controller.livestockSessions[parent.id]=session
    parent.state='assembling';parent.reason='Krmná četa nakládá recepturu z AnimalFoodSystem'
    local ok,why=startGoto(controller,parent,record,ingredients[1].point,'ingredient',1)
    if not ok then controller.livestockSessions[parent.id]=nil;return false,why end
    controller:notify(record.name..' jede pro 1. složku krmné dávky · '..FMAWorld.fillName(ingredients[1].fillType))
    return true
end

function FMALivestockCoordinator.onDriveStopped(controller,active)
    local parent=controller.tasks[active.task.parentTaskId];local s=parent and controller.livestockSessions and controller.livestockSessions[parent.id]
    if not parent or not s then return end
    if active.stopReason then parent.state='blocked';parent.reason=active.stopReason;controller.livestockSessions[parent.id]=nil;return end
    if active.task.phase=='ingredient' then
        local ing=s.ingredients[active.task.ingredientIndex]
        if not ing or not ing.point or type(ing.point.trigger.setIsLoading)~='function' then parent.state='blocked';parent.reason='Nakládací bod krmiva nepodporuje automatické plnění';controller.livestockSessions[parent.id]=nil;return end
        local allowed,why=FMARefillManager.canLoad(ing.point.trigger,s.object,s.fillUnitIndex,ing.fillType,controller.farmId)
        if not allowed then FMAJobs.fail(controller,parent,s.vehicle,why);controller.livestockSessions[parent.id]=nil;return end
        local before=FMAUtil.call(s.object,'getFillUnitFillLevel',s.fillUnitIndex) or 0
        local ok,err=pcall(ing.point.trigger.setIsLoading,ing.point.trigger,true,s.object,s.fillUnitIndex,ing.fillType)
        if not ok then parent.state='blocked';parent.reason='Nelze spustit nakládku krmiva: '..tostring(err);controller.livestockSessions[parent.id]=nil;return end
        s.phase='loading';s.loadingIngredient=ing;s.before=before;s.loadingStarted=controller.now;s.lastLevel=before
        controller.reservations[s.vehicle.key]=parent.id;s.vehicle.busy=true
        parent.reason='Nakládá '..FMAWorld.fillName(ing.fillType)..' · cíl '..math.floor(ing.targetDelta)..' l'
        return
    end
end

local function beginFeedDelivery(controller,s)
    local record=s.vehicle;local parent=s.parent
    if FMATraffic and FMATraffic.canStart then
        local dx,dz=FMAUtil.position(parent.destination)
        local free,wait=FMATraffic.canStart(controller,record,{x=dx or record.x,z=dz or record.z},{id='rationDeliver:'..parent.id,kind='livestockFeedDeliver'},60000)
        if not free then return false,wait end
    end
    if AIJobDeliver==nil then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,'Chybí AIJobDeliver' end
    local job=FMAAI.createRegisteredJob("DELIVER",AIJobDeliver);if not job then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,'Nelze vytvořit registrovaný AIJobDeliver' end;if not job:getIsAvailableForVehicle(record.object) then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,'Krmná souprava nepodporuje nativní doručení' end
    job:applyCurrentState(record.object,g_currentMission,controller.farmId,false)
    local x,z=FMAUtil.position(record.object);if x and z and job.positionAngleParameter then job.positionAngleParameter:setPosition(x,z) end
    job.unloadingStationParameter:setUnloadingStation(parent.destination)
    job.loopingParameter:setIsLooping(false);job:setValues()
    local valid,why=job:validate(controller.farmId);if not valid then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(why or 'AI odmítla krmný žlab') end
    local startable,state=job:getIsStartable(nil);if not startable then if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,'Krmnou jízdu nelze spustit: '..tostring(state) end
    local t={id='rationDeliver:'..parent.id,kind='livestockFeedDeliver',operation='mixFeed',label=parent.label,parentTaskId=parent.id,priority=100,state='running'}
    controller.reservations[record.key]=t.id;record.busy=true
    controller.active[job]={job=job,task=t,vehicle=record,start=controller.now,lastProgress=controller.now,x=record.x,z=record.z,fill=record.fillTotal}
    local okStart,err=pcall(FMAJobs.start,g_currentMission.aiSystem,job,controller.farmId)
    if not okStart then controller.active[job]=nil;controller.reservations[record.key]=nil;record.busy=false;if FMATraffic then FMATraffic.release(controller.traffic,record.key) end;return false,tostring(err) end
    parent.state='running';parent.reason='Hotová směs jede do krmného žlabu'
    controller:notify(record.name..' veze hotovou krmnou dávku do '..FMAUtil.name(parent.husbandry))
    return true
end

function FMALivestockCoordinator.update(controller)
    for id,s in pairs(controller.livestockSessions or {}) do
        if s.phase=='loading' then
            local level=FMAUtil.call(s.object,'getFillUnitFillLevel',s.fillUnitIndex) or 0
            local loaded=math.max(0,level-(s.before or 0));local ing=s.loadingIngredient
            local timeout=(controller.now-(s.loadingStarted or controller.now))>(controller.settings.feedLoadTimeoutSeconds or 180)*1000
            local stopped=ing.point.trigger.isLoading==false and level<=(s.lastLevel or level)+0.1
            if loaded+2>=ing.targetDelta or timeout or stopped then
                if ing.point.trigger.setIsLoading then pcall(ing.point.trigger.setIsLoading,ing.point.trigger,false,s.object,s.fillUnitIndex,ing.fillType) end
                if timeout or (stopped and loaded<ing.targetDelta*0.85) then
                    s.parent.state='blocked';s.parent.reason=timeout and 'Nakládka složky krmiva překročila časový limit' or 'Zdroj přestal vydávat složku krmiva'
                    controller:issue(s.parent.id,s.parent.label,s.parent.reason,99);controller.reservations[s.vehicle.key]=nil;s.vehicle.busy=false;controller.livestockSessions[id]=nil
                else
                    s.index=s.index+1;s.phase='driveIngredient';controller.reservations[s.vehicle.key]=nil;s.vehicle.busy=false
                    local nextIng=s.ingredients[s.index]
                    if nextIng then
                        local ok,why=startGoto(controller,s.parent,s.vehicle,nextIng.point,'ingredient',s.index)
                        if not ok then s.parent.state='blocked';s.parent.reason=why;controller.livestockSessions[id]=nil else controller:notify(s.vehicle.name..' jede pro další složku · '..FMAWorld.fillName(nextIng.fillType)) end
                    else
                        local ok,why=beginFeedDelivery(controller,s)
                        if not ok then s.parent.state='blocked';s.parent.reason=why;controller:issue(s.parent.id,s.parent.label,why,99);controller.livestockSessions[id]=nil else s.phase='delivering' end
                    end
                end
            else s.lastLevel=level end
        end
    end
end

function FMALivestockCoordinator.onDeliveryStopped(controller,active)
    local parent=controller.tasks[active.task.parentTaskId]
    if not parent then return end
    controller.livestockSessions[parent.id]=nil
    if active.stopReason then parent.state='blocked';parent.reason=active.stopReason;return end
    parent.state='done';parent.reason='Krmná dávka fyzicky namíchána a rozvezena';parent.retryAt=controller.now+30000
    controller:notify(parent.label..' · hotovo')
    if controller.settings.autoReturn and FMAReturnManager then
        local ok,why=FMAReturnManager.begin(controller,{task=parent,vehicle=active.vehicle})
        if ok then return end
        if why then FMAUtil.log('Návrat krmné soupravy: '..tostring(why)) end
    end
end

function FMALivestockCoordinator.cancelAll(controller)
    for id,s in pairs(controller.livestockSessions or {}) do
        local ing=s.loadingIngredient
        if s.phase=='loading' and ing and ing.point and ing.point.trigger and ing.point.trigger.setIsLoading then pcall(ing.point.trigger.setIsLoading,ing.point.trigger,false,s.object,s.fillUnitIndex,ing.fillType) end
        controller.reservations[s.vehicle.key]=nil;s.vehicle.busy=false
        if s.parent then s.parent.state='paused';s.parent.reason='Pozastaveno majitelem během krmné směny' end
        controller.livestockSessions[id]=nil
    end
end
