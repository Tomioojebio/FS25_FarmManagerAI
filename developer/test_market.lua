return function(test,eq)
    local function scenario(fill,otherFree)
        local FT=52
        local place={ownerFarmId=1,name='Hlavní obilní silo',posX=0,posZ=0}
        local src={owningPlaceable=place,name='Výdej ze sila',
            getAISupportedFillTypes=function()return {[FT]=true} end,
            getFillLevel=function()return fill end,
            getCapacity=function()return 10000 end}
        local ownPlace={ownerFarmId=1,name='Rezervní obilní silo',posX=60,posZ=0}
        local dst={owningPlaceable=ownPlace,name='Příjem vlastní silo',
            getAISupportedFillTypes=function()return {[FT]=true} end,
            getFreeCapacity=function()return otherFree end}
        local salePlace={ownerFarmId=0,name='Výkup obilí',posX=250,posZ=0}
        local buyer={owningPlaceable=salePlace,isSellingPoint=true,
            getAISupportedFillTypes=function()return {[FT]=true} end,
            getEffectiveFillTypePrice=function()return 1.55 end}
        local backupPlace={ownerFarmId=0,name='Další výkup',posX=330,posZ=0}
        local buyer2={owningPlaceable=backupPlace,isSellingPoint=true,
            getAISupportedFillTypes=function()return {[FT]=true} end,
            getEffectiveFillTypePrice=function()return 1.24 end}
        local storage={getLoadingStations=function()return {src} end,
            getUnloadingStations=function()return {src,dst,buyer,buyer2} end}
        local oldMission=g_currentMission
        local oldAtlas=FMAWorldAtlas.stationTarget
        g_currentMission={storageSystem=storage}
        FMAWorldAtlas.stationTarget=function(s,ft)
            if ft~=FT then return nil end
            local p=s.owningPlaceable
            return p and {x=p.posX,z=p.posZ} or nil
        end
        local c={farmId=1,settings={sellWhenStoreAbove=0.90,priceSellThreshold=0.95,storageReservePercent=0.15,retainOrganicFertilizer=false},marketHistory={}}
        return c,src,dst,buyer,buyer2,function()
            g_currentMission=oldMission;FMAWorldAtlas.stationTarget=oldAtlas
        end
    end
    test('market prefers available OWN silo over higher priced sale',function()
        local c,src,dst,buyer,buyer2,restore=scenario(9300,18000)
        local proposals,stock=FMAMarketPlanner.scan(c)
        eq(#proposals,1)
        eq(proposals[1].isSale,false)
        eq(proposals[1].destination,dst)
        eq(#stock,1)
        restore()
    end)
    test('near full silo proposes a sale only as unapproved job',function()
        local c,src,dst,buyer,buyer2,restore=scenario(9300,0)
        local proposals,stock=FMAMarketPlanner.scan(c)
        eq(#proposals,1)
        eq(proposals[1].isSale,true)
        eq(proposals[1].requiresSaleApproval,true)
        eq(proposals[1].ownerApproved,nil)
        eq(proposals[1].destination,buyer)
        eq(proposals[1].saleQuantity,7800)
        eq(stock[1].priceHigh,1.55)
        restore()
    end)
    test('no sale proposal is made below space-warning threshold',function()
        local c,src,dst,buyer,buyer2,restore=scenario(5000,0)
        local offers=FMAMarketPlanner.scan(c)
        eq(#offers,0)
        restore()
    end)
    test('buyer selection remains sticky after market rescan',function()
        local c,src,dst,buyer,buyer2,restore=scenario(9300,0)
        local offers=FMAMarketPlanner.scan(c)
        local t=offers[1]
        t.ownerApproved=true;t.marketTargetPinned=true;t.destination=buyer2
        local newer=FMAMarketPlanner.scan(c)
        local after=FMAPlanner.merge({[t.id]=t},newer,10000)[t.id]
        eq(after.destination,buyer2)
        eq(after.ownerApproved,true)
        restore()
    end)
    test('stock and price sampling history are retained in controller state',function()
        local c,src,dst,buyer,buyer2,restore=scenario(9300,0)
        FMAMarketPlanner.scan(c);FMAMarketPlanner.scan(c)
        eq(c.marketHistory[52].samples,2)
        eq(c.marketHistory[52].high,1.55)
        restore()
    end)
    test('sale is not verified merely because GIANTS completed the job',function()
        local c,src,dst,buyer,buyer2,restore=scenario(9300,0)
        local offers=FMAMarketPlanner.scan(c)
        local task=offers[1]
        task.supplyStartLevel=9300;task.supplyStartMoney=10000
        c.now=1000;c.tasks={[task.id]=task}
        local oldMoney=FMAWorld.money;FMAWorld.money=function()return 10000 end
        FMAMarketPlanner.onTransportStopped(c,{task=task},'success')
        eq(task.state,'waiting')
        FMAMarketPlanner.verifyTransport(c)
        eq(task.state,'waiting')
        c.now=37000;FMAMarketPlanner.verifyTransport(c)
        eq(task.state,'blocked')
        FMAWorld.money=oldMoney;restore()
    end)
    test('sale verified only after REAL cargo and farm money delta',function()
        local c,src,dst,buyer,buyer2,restore=scenario(9300,0)
        local options=FMAMarketPlanner.scan(c);local task=options[1]
        local level=9300
        src.getFillLevel=function()return level end
        task.supplyStartLevel=9300;task.supplyStartMoney=10000
        local oldMoney=FMAWorld.money
        FMAWorld.money=function()return 10000 end
        c.now=1000;c.tasks={[task.id]=task}
        FMAMarketPlanner.onTransportStopped(c,{task=task},'success')
        level=3000;FMAMarketPlanner.verifyTransport(c)
        eq(task.state,'waiting')
        FMAWorld.money=function()return 18000 end
        FMAMarketPlanner.verifyTransport(c)
        eq(task.state,'done')
        eq(task.phase,'PRODEJ OVĚŘEN')
        FMAWorld.money=oldMoney;restore()
    end)
    test('transfer between owned silos needs confirmed material on both ends',function()
        local c,src,dst,buyer,buyer2,restore=scenario(9300,16000)
        local options=FMAMarketPlanner.scan(c);local task=options[1]
        local level=9300;local inbound=0
        src.getFillLevel=function()return level end
        dst.getFillLevel=function()return inbound end
        task.supplyStartLevel=9300;task.supplyStartDestinationLevel=0
        c.now=1000;c.tasks={[task.id]=task}
        FMAMarketPlanner.onTransportStopped(c,{task=task},'success')
        level=3000;FMAMarketPlanner.verifyTransport(c)
        eq(task.state,'waiting')
        inbound=6000;FMAMarketPlanner.verifyTransport(c)
        eq(task.state,'done')
        eq(task.phase,'PŘESKLADNĚNÍ OVĚŘENO')
        restore()
    end)
    test('sale without a real AI approach is not an executable proposal',function()
        local c,src,dst,buyer,buyer2,restore=scenario(9300,0)
        FMAWorldAtlas.stationTarget=function(s)
            if s==buyer or s==buyer2 then return nil end
            return {x=1,z=1}
        end
        local offers=FMAMarketPlanner.scan(c)
        eq(#offers,0)
        restore()
    end)
end
