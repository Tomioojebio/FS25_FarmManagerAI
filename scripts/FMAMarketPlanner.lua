-- Universal market proposals for compatible bulk crops/products. Never moves
-- cargo or authorizes a sale: only user-approved jobs may sell on this farm.
FMAMarketPlanner = {}

local function stations(method)
    local system=g_currentMission and g_currentMission.storageSystem
    local rows=FMAUtil.call(system,method) or {}
    local out,seen={},{}
    for k,v in pairs(rows) do
        local obj=type(v)=='table' and v or (type(k)=='table' and k or nil)
        if obj and not seen[obj] then out[#out+1]=obj;seen[obj]=true end
    end
    return out
end
local function stock(station,ft,farmId)
    local level=tonumber(FMAUtil.call(station,'getFillLevel',ft,farmId))
    local cap=tonumber(FMAUtil.call(station,'getCapacity',ft,farmId))
    if (not level or not cap) and station.storage then
        level=level or tonumber(FMAUtil.call(station.storage,'getFillLevel',ft))
        cap=cap or tonumber(FMAUtil.call(station.storage,'getCapacity',ft))
    end
    if not level or not cap or cap<=0 or level<0 then return nil,nil end
    return level,cap
end
local function readableName(ft)
    return FMAWorld and FMAWorld.fillName and FMAWorld.fillName(ft) or tostring(ft)
end
function FMAMarketPlanner.currentPrices(ft,farmId)
    local prices={}
    for _,st in ipairs(stations('getUnloadingStations')) do
        if st.isSellingPoint==true and FMALogistics.supports(st,ft) then
            local price=tonumber(FMAUtil.call(st,'getEffectiveFillTypePrice',ft))
            local target=FMAWorldAtlas and FMAWorldAtlas.stationTarget and FMAWorldAtlas.stationTarget(st,ft)
            if price and price>0 then
                prices[#prices+1]={station=st,price=price,accessible=target~=nil,name=FMAUtil.name(st.owningPlaceable or st)}
            end
        end
    end
    table.sort(prices,function(a,b)
        if a.accessible~=b.accessible then return a.accessible end
        if a.price~=b.price then return a.price>b.price end
        return tostring(a.station)<tostring(b.station)
    end)
    return prices
end
function FMAMarketPlanner.scan(c)
    local farmId=c.farmId
    local settings=c.settings or {}
    local offers={};local market={};local history=c.marketHistory or {}
    c.marketHistory=history
    local seen={}
    local unloading=stations('getUnloadingStations')
    local pricesCache={}
    local function cachedPrices(ft)
        if not pricesCache[ft] then pricesCache[ft]=FMAMarketPlanner.currentPrices(ft,farmId) end
        return pricesCache[ft]
    end
    for _,src in ipairs(stations('getLoadingStations')) do
        if src.owningPlaceable and FMAUtil.owner(src.owningPlaceable)==farmId then
            local types=FMAUtil.call(src,'getAISupportedFillTypes') or {}
            for ft,yes in pairs(types) do
                if yes~=false and type(ft)=='number' and ft>0 then
                    local level,cap=stock(src,ft,farmId)
                    if level and level>100 and cap then
                        seen[tostring(src.owningPlaceable)..':'..ft]=true
                        local priceRows=cachedPrices(ft)
                        local best=priceRows[1]
                        local hist=history[ft] or {high=0,low=math.huge,samples=0}
                        if best and best.price>0 then
                            hist.high=math.max(hist.high or 0,best.price)
                            hist.low=math.min(hist.low or math.huge,best.price)
                            hist.samples=math.min(100000,(hist.samples or 0)+1)
                            hist.last=best.price
                            history[ft]=hist
                        end
                        local ratio=level/cap
                        local pressure=ratio>=math.max(0.5,math.min(0.99,settings.sellWhenStoreAbove or 0.90))
                        local quality=best and (hist.high==0 or best.price>=hist.high*(settings.priceSellThreshold or 0.95))
                        local row={fillType=ft,source=src,level=level,capacity=cap,ratio=ratio,best=best,
                            priceHigh=hist.high,priceLow=hist.low,priceSamples=hist.samples,pressure=pressure,goodPrice=quality==true}
                        market[#market+1]=row
                        -- Only genuine GIANTS bulk loading stations can supply an automatic
                        -- LOAD_AND_DELIVER job. Pallets need a separate validated loader.
                        if pressure and not (settings.retainOrganicFertilizer and FMALogistics.isOrganicFertilizer(ft)) then
                            -- Transfer within the owner's own property before proposing a sale.
                            -- A loading outlet and unloading inlet of the SAME silo are not a destination.
                            local otherStorage=nil
                            for _,dst in ipairs(unloading) do
                                if dst~=src and dst.owningPlaceable~=src.owningPlaceable
                                    and FMALogistics.stationOwner(dst)==farmId
                                    and FMALogistics.supports(dst,ft) then
                                    local free=tonumber(FMAUtil.call(dst,'getFreeCapacity',ft,farmId))
                                    local target=FMAWorldAtlas and FMAWorldAtlas.stationTarget and FMAWorldAtlas.stationTarget(dst,ft)
                                    if target and free and free>=6000 and
                                        (not otherStorage or free>otherStorage.free) then
                                        otherStorage={station=dst,free=free}
                                    end
                                end
                            end
                            local x,z=FMAUtil.position(src.owningPlaceable)
                            if otherStorage then
                                offers[#offers+1]={id='marketMove:'..tostring(src)..':'..tostring(ft),
                                    kind='supply',operation='supply',priority=92,
                                    label='PŘESKLADNIT · '..readableName(ft),state='pending',
                                    phase='VLASTNÍ SILO · PŘEDNOST',attempts=0,source=src,
                                    destination=otherStorage.station,fillType=ft,available=level,
                                    isSale=false,allowPublicDestination=false,x=x,z=z,
                                    reason='Sklad '..math.floor(ratio*100)..'% · jiné vlastní silo má volných '..math.floor(otherStorage.free)..' l'}
                            elseif best and best.accessible then
                            local id='marketSell:'..tostring(src)..':'..tostring(ft)
                            local nominal=math.max(0,level-cap*(settings.storageReservePercent or 0.15))
                            if nominal>100 then
                                offers[#offers+1]={id=id,kind='supply',operation='supply',
                                    priority=quality and 85 or 76,label='PRODEJ · '..readableName(ft),
                                    state='pending',phase='NÁVRH PRODEJE · SCHVÁLENÍ',
                                    reason='Sklad '..math.floor(ratio*100)..'% · cena '..math.floor(best.price*1000+0.5)..'/1000 l · k prodeji max '..math.floor(nominal)..' l',
                                    attempts=0,source=src,destination=best.station,fillType=ft,
                                    available=level,saleQuantity=nominal,allowPublicDestination=true,
                                    isSale=true,requiresSaleApproval=true,marketProposal=true,pricePerLiter=best.price,
                                    x=x,z=z,marketAlternatives=priceRows}
                            end
                            end
                        end
                    end
                end
            end
        end
    end
    -- Finished products without GIANTS automatic bulk loading are still monitored,
    -- but they are NOT falsely offered as tractor/silo jobs: their pallet/bale
    -- handling requires a validated compatible loader (or a player).
    local production=g_currentMission and g_currentMission.productionChainManager
    for _,point in pairs(FMAUtil.call(production,'getProductionPointsForFarmId',farmId) or {}) do
        local inventory=point.storage
        if inventory then
            for ft,level in pairs(FMAUtil.call(inventory,'getFillLevels') or {}) do
                if type(ft)=='number' and level>100 and point.outputFillTypeIds and point.outputFillTypeIds[ft] then
                    local ident=tostring(point.owningPlaceable or point)..':'..tostring(ft)
                    if not seen[ident] then
                        local cap=tonumber(FMAUtil.call(inventory,'getCapacity',ft))
                        if cap and cap>0 then
                            local prices=cachedPrices(ft)
                            if prices[1] and prices[1].price>0 then
                                local h=history[ft] or {high=0,low=math.huge,samples=0}
                                h.high=math.max(h.high or 0,prices[1].price)
                                h.low=math.min(h.low or math.huge,prices[1].price)
                                h.samples=math.min(100000,(h.samples or 0)+1)
                                h.last=prices[1].price;history[ft]=h
                            end
                            market[#market+1]={fillType=ft,source=point,level=level,capacity=cap,
                                ratio=level/cap,best=prices[1],pressure=level/cap>= (settings.sellWhenStoreAbove or 0.90),
                                priceHigh=history[ft] and history[ft].high or 0,manualHandling=true}
                        end
                    end
                end
            end
        end
    end
    table.sort(market,function(a,b) return a.ratio>b.ratio end)
    c.marketRows=market
    c.marketProposals=offers
    return offers,market
end

-- A stopped GIANTS transport job is NOT evidence of selling or unloading.
-- Wait for the next live-world scans to prove a real material transfer and,
-- for a sale, revenue. A price quotation alone is never counted as revenue.
function FMAMarketPlanner.onTransportStopped(c,active,outcome)
    local task=active and active.task
    if not task or task.kind~='supply' then return false end
    task.transportAIOutcome=outcome
    if outcome~='success' or active.stopReason then
        task.state='blocked';task.phase='DOPRAVA SELHALA'
        task.reason=active.stopReason or 'GIANTS AI nepotvrdila dokončení přepravy'
    else
        task.state='waiting';task.phase='OVĚŘOVÁNÍ SKUTEČNÉ VYKLÁDKY'
        task.reason='Čeká na potvrzený úbytek zdroje a příjem sila / peněz'
        task.transportVerifyUntil=(c.now or 0)+35000
    end
    c.diagnosticDirty=true
    return true
end
function FMAMarketPlanner.verifyTransport(c)
    for _,task in pairs(c.tasks or {}) do
        if task.kind=='supply' and task.phase=='OVĚŘOVÁNÍ SKUTEČNÉ VYKLÁDKY' and task.state=='waiting' then
            local now=c.now or 0
            local before=task.supplyStartLevel
            local after=tonumber(FMAUtil.call(task.source,'getFillLevel',task.fillType,c.farmId))
            local withdrawn=before and after and before-after or nil
            local delivered=false
            if task.isSale==true then
                local current=FMAWorld.money(c.farmId)
                delivered=current and task.supplyStartMoney and current>task.supplyStartMoney
            else
                local previous=task.supplyStartDestinationLevel
                local current=tonumber(FMAUtil.call(task.destination,'getFillLevel',task.fillType,c.farmId))
                delivered=current and previous and current-previous>100
            end
            if withdrawn and withdrawn>100 and delivered then
                task.state='done';task.phase=task.isSale and 'PRODEJ OVĚŘEN' or 'PŘESKLADNĚNÍ OVĚŘENO'
                task.reason='Potvrzen přesun '..math.floor(withdrawn)..' l v živé hře'
                task.retryAt=now+120000
                c.diagnosticDirty=true
            elseif now>=(task.transportVerifyUntil or now+35000) then
                task.state='blocked';task.phase='NEOVĚŘENO'
                task.reason='AI ohlásila konec, ale hra nepotvrdila úbytek zásob a příjem / peníze'
                c.diagnosticDirty=true
            end
        end
    end
end
