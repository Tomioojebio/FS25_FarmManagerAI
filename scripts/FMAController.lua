FMAController = {}
FMAController.__index=FMAController

local function subsystemFault(controller,name,err)
    controller.subsystemFaults=controller.subsystemFaults or {}
    local text=tostring(err or "unknown error")
    controller.subsystemFaults[name]=text
    FMADiagnostics.error(controller,name,text)
end

local function safeSubsystem(controller,name,fn,...)
    controller.subsystemHealth=controller.subsystemHealth or {}
    local h=controller.subsystemHealth[name] or {failures=0,disabledUntil=0};controller.subsystemHealth[name]=h
    local now=controller.now or 0
    if h.disabledUntil>now and name~="job.finish" then return false,nil,nil,nil end
    local args={...}
    local ok,a,b,c=xpcall(function()
        assert(type(fn)=="function","funkce není dostupná")
        return fn(unpack(args))
    end,FMADiagnostics.trace)
    if not ok then
        h.failures=h.failures+1;h.lastError=tostring(a)
        h.disabledUntil=now+math.min(300000,10000*2^math.min(h.failures-1,5))
        subsystemFault(controller,name,a)
        if name=="dispatch" or name=="watchdog" or name=="lifecycle" or ((name=="world.fields" or name=="world.vehicles") and h.failures>=3) then
            controller.settings.enabled=false
            controller.runtimePaused=true
            controller.lastRuntimeError="Chyba jádra "..name..": "..tostring(a)
        end
        return false,nil,nil,nil
    end
    h.failures=0;h.disabledUntil=0;h.lastError=nil
    if controller.subsystemFaults then controller.subsystemFaults[name]=nil end
    return true,a,b,c
end

local function publishSubsystemFaults(controller)
    for name,err in pairs(controller.subsystemFaults or {}) do
        controller:issue("subsystem:"..tostring(name),"Modul dočasně vyřazen · "..tostring(name),tostring(err),99)
    end
end

function FMAController.new()
    return setmetatable({initialized=false,visible=false,supported=false,elapsed=0,now=0,
        tasks={},active={},reservations={},issues={},history={},fields={},fieldsById={},vehicles={},conditions={},
        policies={},excluded={},routes={},settings=FMAState.new().settings,bindings={},page=9,selection=1,fmaTaskListMode=true,
        ownDriveSessions={},traffic=FMATraffic.new(),workgroups={},crewAssignments={},bunkers={},animalConditions={},playerTakeovers={},implementReservations={},
        homePositions={},toolHomes={},parkingBays={},parkingLeases={},parkingFacilities={},haulageCycles={},refillSessions={},headerWaits={},focusTaskId=nil,supportAttachmentByVehicle={},
        forageStages={},windrowCourses={},qualityCoursePending={},qualityRecent={},baleStorages={},baleUnloadSessions={},baleDeliveryWaits={},forageBunkerWaits={},
        livestockPlans={},livestockSessions={},livestockMixPlaces={},bunkerDeliverySessions={},bunkerWorkState={},subsystemFaults={},
        learnedPoints={},learnedRoutes={},navigationMap={routes={},hazards={}},farmSurvey={edges={},manual=false},experience={},handoverLeases={},handoverJournal={},pendingHandovers={},pendingDetaches={},shiftPlan={},digitalMap={},brainDryRun={},teachSession=nil,preparedNextCrew={},serviceQueue={},
        sanitizedJobHistory=0,mapProfile={active=false},modHubProfile={},jobFailures={},stoppedJobs={},journal={},errorCounts={},approvedPurchases={},worldRegistry=(FMAWorldRegistry and FMAWorldRegistry.new and FMAWorldRegistry.new() or nil)},FMAController)
end

function FMAController:notify(text)
    text=tostring(text or "")
    self.lastMessage=text
    self.history[#self.history+1]={time=self.now,text=text}
    if #self.history>80 then table.remove(self.history,1) end
    local duplicate=self.lastNotificationText==text and ((self.now or 0)-(self.lastNotificationAt or -100000))<8000
    self.lastNotificationText=text;self.lastNotificationAt=self.now or 0
    -- Repeated status polling is not a new event. Keep history for inspection,
    -- but avoid flooding the operational log with identical lines every frame.
    if not duplicate then FMAUtil.log(text) end
    if not duplicate and g_currentMission and g_currentMission.addIngameNotification and FSBaseMission then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,"Farm Manager: "..text)
    end
end

local function classifyIssue(id,priority,explicitKind)
    if explicitKind=="error" or explicitKind=="action" or explicitKind=="warning" or explicitKind=="info" then return explicitKind end
    local key=tostring(id or "")
    -- Only technical/runtime faults belong in the red ERROR bucket. Normal farm
    -- work (feed, fuel, service, missing material/equipment) must never look like
    -- dozens of software errors to the player.
    if key=="runtime" or key=="platform" or key=="transferJob" or key=="courseplayRequired"
        or key:sub(1,10)=="subsystem:" or key:sub(1,10)=="preflight:"
        or key:sub(1,8)=="failure:" or key:sub(1,5)=="save:" then return "error" end
    if key:sub(1,14)=="preflightWarn:" or key=="mapProfile" or key=="precisionFarming"
        or key:sub(1,9)=="autoload:" then return "warning" end
    if key:sub(1,10)=="equipment:" or key:sub(1,5)=="fuel:" or key:sub(1,8)=="service:"
        or key:sub(1,16)=="serviceCritical:" or key:sub(1,11)=="production:"
        or key:sub(1,5)=="prod:" or key:sub(1,7)=="animal:" or key:sub(1,6)=="field:"
        or key:sub(1,6)=="route:" or key:sub(1,9)=="recovery:" or key:sub(1,5)=="crew:"
        or key:sub(1,5)=="team:" or key:sub(1,7)=="bunker:" or key:sub(1,6)=="bales:"
        or key:sub(1,12)=="baleStorage:" or key=="money" or key=="noFields" then return "action" end
    if (priority or 50)>=90 then return "action" end
    if (priority or 50)>=50 then return "warning" end
    return "info"
end

function FMAController:issue(id,title,detail,priority,kind)
    local p=priority or 50
    self.issues[id]={id=id,title=title,detail=detail or "",priority=p,kind=classifyIssue(id,p,kind)}
end

function FMAController:issueCounts()
    local counts={error=0,action=0,warning=0,info=0,total=0}
    for _,issue in pairs(self.issues or {}) do
        local kind=issue.kind or classifyIssue(issue.id,issue.priority,nil)
        if counts[kind]==nil then kind="warning" end
        counts[kind]=counts[kind]+1;counts.total=counts.total+1
    end
    return counts
end

function FMAController:initialize()
    self.farmId=FMAWorld.farmId()
    if not self.farmId or self.farmId==0 then return end
    self.supported=g_server~=nil and not (g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer)
    self.initialized=true
    FMAJobs.controller=self
    if FMATransfer and FMATransfer.ensureRegistered and FMACourseplay and FMACourseplay.available and FMACourseplay.available() then
        local ok,why=FMATransfer.ensureRegistered(self)
        if not ok then self:issue("transferJob","Courseplay přejezd není připraven",tostring(why),92) end
    end
    if not self.supported then
        self:issue("platform","Testovací vydání je pouze pro singleplayer","Síťové řízení není v této verzi zapnuto",100)
        self:notify("Režim prohlížení; automatizace pouze v singleplayeru")
        return
    end
    local state=FMAState.load()
    self.settings=state.settings;self.policies=state.fields;self.excluded=state.excluded;self.routes=state.routes;self.forageStages=state.forageStages or {}
    self.homePositions=state.homePositions or self.homePositions or {}
    self.toolHomes=state.toolHomes or self.toolHomes or {}
    self.parkingBays=state.parkingBays or {}
    self.learnedPoints=state.learnedPoints or {}
    self.learnedRoutes=state.learnedRoutes or {}
    self.navigationMap=state.navigationMap or {routes={},hazards={}}
    self.farmSurvey=state.farmSurvey or {edges={},manual=false}
    -- Save-dependent geometry must never bleed into a different map, even when
    -- the map title is identical. Older saves without an atlas id remain compatible.
    local mapId=FMAWorldAtlas and FMAWorldAtlas.identity and FMAWorldAtlas.identity() or nil
    local differentMap=state.mapIdentity and mapId and mapId~='MAP_UNIDENTIFIED' and state.mapIdentity~=mapId
    if differentMap then
        self.policies={};self.excluded={};self.routes={};self.forageStages={}
        self.homePositions={};self.toolHomes={};self.parkingBays={};self.learnedPoints={};self.learnedRoutes={}
        self.navigationMap={routes={},hazards={}};self.farmSurvey={edges={},manual=false}
        self.mapMismatch='Jiná mapa: staré naučené trasy a soupravy byly odpojeny'
    end
    -- Never restore the previous map's learned machine ratings or half-complete
    -- trailer handover after resetting the geometry above.
    self.experience=differentMap and {} or (state.experience or {})
    self.handoverJournal=differentMap and {} or (state.handoverJournal or {})
    self.marketHistory=differentMap and {} or (state.marketHistory or {})
    if FMACarpathianProfile then
        self.mapProfile=FMACarpathianProfile.detect()
        if self.mapProfile.active then FMACarpathianProfile.installCatalog() end
    end
    if g_messageCenter and MessageType and MessageType.AI_JOB_STOPPED then
        g_messageCenter:subscribe(MessageType.AI_JOB_STOPPED,self.onJobStopped,self)
    end
    self:scan()
    -- Capture the original farm standing positions BEFORE starting any crew.
    -- Otherwise a bunker worker can accidentally learn the bunker itself as home.
    if FMAReturnManager and FMAReturnManager.captureHomes and self.inventorySafe then
        FMAReturnManager.captureHomes(self)
    end
    self.diagnosticDirty=true
    self.desktopSnapshotDue=(self.now or 0)+1500
    FMAJobs.repairLastJobs(self)
    if self.mapProfile and self.mapProfile.active then
        self:notify("Carpathian + ModHub 0.20.48 · Živý atlas celé mapy a družstvo")
    else
        self:notify("0.20.48 · Univerzální živý atlas mapy, speciální pravidla jen pro Karpatský venkov")
    end
end

function FMAController:scan()
    self.issues={}
    self.purchaseNeeds={}
    if self.mapMismatch then self:issue('mapChange',self.mapMismatch,
        'Nová mapa používá vlastní souřadnice. Nauč nová stání a průjezdy; automatika staré trasy nepoužije.',75,'warning') end
    local okFields,fields=safeSubsystem(self,"world.fields",FMAWorld and FMAWorld.fields,self.farmId)
    -- Preserve last GOOD inventory for inspection; never mistake a failed scan
    -- for "zero fields" and overwrite in-flight dispatch with an empty farm.
    if okFields and type(fields)=='table' then self.fields=fields end
    self.fieldsById={}
    local okVehicles,vehicles,loose=safeSubsystem(self,"world.vehicles",FMAWorld and FMAWorld.vehicles,self.farmId)
    if okVehicles and type(vehicles)=='table' and type(loose)=='table' then
        self.vehicles=vehicles;self.loose=loose
    else okVehicles=false end
    self.inventorySafe=(okFields and okVehicles)==true
    if not self.inventorySafe then
        self:issue('worldScan','Zjišťování stavu farmy čeká na FS25',
            'Poslední úspěšný inventář je zachován, nové zakázky se nespouštějí.',96,'error')
    end
    self.vehicleByKey={}
    for _,vehicle in ipairs(self.vehicles or {}) do self.vehicleByKey[vehicle.key]=vehicle end
    self.looseByKey={}
    for _,tool in ipairs(self.loose or {}) do self.looseByKey[tool.key]=tool end
    if FMAWorldRegistry and FMAWorldRegistry.update then safeSubsystem(self,"world.registry.scan",FMAWorldRegistry.update,self,true) end
    if FMACarpathianProfile then
        local okProfile,profile=safeSubsystem(self,"carpathian.scan",FMACarpathianProfile.scan,self)
        if okProfile and profile then self.mapProfile=profile end
        if self.mapProfile and self.mapProfile.active then
            if not FMACourseplay or not FMACourseplay.available() then
                self:issue("courseplayRequired","Karpatský venkov · Courseplay není aktivní","Přesné polní práce jsou z bezpečnostních důvodů zablokované, dokud není Courseplay dostupný.",100,"error")
            elseif self.settings.preferCourseplay and FMATransfer and FMATransfer.ensureRegistered then
                local transferOk,transferWhy=FMATransfer.ensureRegistered(self)
                if not transferOk then
                    self:issue("transferJob","Courseplay přesný nájezd není připravený",tostring(transferWhy).." · běžné přejezdy dál zajišťuje nativní AI FS25",45,"warning")
                end
            end
        else
            -- Generic FS25 maps are a supported normal mode, not an error.
            -- The live atlas provides their actual equipment, land and stations.
        end
    end
    if FMAWorldAtlas and FMAWorldAtlas.scan then
        local atlasOk,atlas=safeSubsystem(self,'world.atlas',FMAWorldAtlas.scan,self)
        if atlasOk and atlas then
            self.worldAtlas=atlas
            if atlas.bounded then self:issue('atlasBounds','Mapa je rozsáhlá','Limit scanneru dosažen, výpis je pouze částečný.',55,'warning') end
            if atlas.fieldOwnershipKnown and atlas.farmlands.owned>0 and atlas.fieldCount==0 then
                self:issue('atlasFields','Vlastní pozemky načteny, ale bez polí',
                    'Zkontroluj skutečná pole, ochranu mapy a živé vlastnictví v diagnostice; automatika si nevymyslí polní úkoly.',65,'warning')
            end
        end
    end
    if FMAParkingManager and FMAParkingManager.scan then safeSubsystem(self,'parking.facilities',FMAParkingManager.scan,self) end
    if FMAReturnManager and FMAReturnManager.captureHomes then safeSubsystem(self,"return.captureHomes",FMAReturnManager.captureHomes,self) end
    local okConditions,conditions=safeSubsystem(self,"world.conditions",FMAWorld and FMAWorld.conditionRows,self.farmId)
    self.conditions=okConditions and (conditions or {}) or {}
    self.animalConditions={}
    if self.settings.livestock and FMAAnimalManager and FMAAnimalManager.scan then
        local okAnimals,animalRows,animalIssues,livestockPlans=safeSubsystem(self,"animals.scan",FMAAnimalManager.scan,self.farmId,self.settings)
        if okAnimals then
            self.animalConditions=animalRows or {}
            self.livestockPlans=livestockPlans or {}
            for _,issue in ipairs(animalIssues or {}) do self:issue(issue.id,issue.title,issue.detail,issue.priority) end
        else
            self.livestockPlans={}
        end
    end
    local okCompatibility,compatibility=safeSubsystem(self,"compatibility.environment",FMACompatibility and FMACompatibility.environment)
    self.compatibility=okCompatibility and (compatibility or {}) or {}
    for _,name in ipairs(self.compatibility) do
        if name:lower():find("precisionfarming",1,true) then
            self.settings.cropCare=false
            self:issue("precisionFarming","Precision Farming · půdu posuzuje jeho systém","Automatické vápnění, hnojení, válení a plevel jsou vypnuty; standardní model půdy nestačí.",70)
        end
    end
    local okMoney,money=safeSubsystem(self,"world.money",FMAWorld and FMAWorld.money,self.farmId)
    self.money=okMoney and money or nil
    if self.settings.bunkerAutomation and FMABunkerCoordinator and FMABunkerCoordinator.scan then safeSubsystem(self,"bunker.scan",FMABunkerCoordinator.scan,self) end
    local proposals={}
    if self.settings.bunkerAutomation and FMABunkerCoordinator and FMABunkerCoordinator.proposals then
        local ok,bunkerTasks=safeSubsystem(self,'bunker.proposals',FMABunkerCoordinator.proposals,self)
        if ok then for _,t in ipairs(bunkerTasks or {}) do proposals[#proposals+1]=t end end
    end
    for _,f in ipairs(self.fields) do
        self.fieldsById[f.id]=f
        if not self.policies[f.id] then self.policies[f.id]={enabled=true,crop=f.fruit and FMAUtil.fruit(f.fruit) and f.fruit or ""} end
        local p=self.policies[f.id]
        local stage=self.forageStages[tostring(f.id)]
        local chainOwnsField=self.settings.autoForageChain and stage~=nil and stage~="collected" and stage~="baledStored"
        local op,reason
        if chainOwnsField then op=nil;reason="Pícninářská/slámová četa · fáze "..tostring(stage)
        else op,reason=FMAPlanner.nextOperation(f,p,self.settings) end
        if op=="cultivate" then
            for _,v in ipairs(self.vehicles) do
                if v.directPlanting and v.sowingFruit==p.crop and not self.excluded[v.key] then op="sow";break end
            end
        end
        f.nextOperation=op;f.reason=reason
        if op then
            local t=FMAPlanner.makeTask(f,op,p.crop);t.fruitIndex=f.fruitIndex
            t.strategyMode=self.settings.strategyMode or 0;t.preventiveServiceDamage=self.settings.preventiveServiceDamage or 0.60;t.criticalServiceDamage=self.settings.criticalServiceDamage or 0.85
            if FMAFieldQuality and FMAFieldQuality.isRecentRework(self,t.id) then
                t.qualityRework=true;t.priority=t.priority+6;t.label=t.label.." · dočištění"
                t.reason="Kontrolní dojezd: stav pole stále hlásí neopracovanou část"
            end
            proposals[#proposals+1]=t
        elseif not f.valid or (f.bare and p.crop=="") then
            self:issue("field:"..f.id,f.name,reason,60)
        end
        -- Procurement forecast for the complete next crop cycle, not just today's task.
        if p.enabled and p.crop~="" then
            local required=p.crop=="GRASS" and {"mow"} or {"cultivate","sow","harvest"}
            for _,operation in ipairs(required) do
                local found=false
                for _,v in ipairs(self.vehicles) do if v.capabilities[operation] then found=true;break end end
                if not found and FMAAssembler then found=FMAAssembler.hasPotential(self,operation) end
                if not found then self:equipmentIssue(operation,"Příprava dalšího cyklu · "..f.name) end
            end
        end
    end
    if self.settings.autoForageChain and FMAForageCoordinator and FMAForageCoordinator.proposals then
        local okForage,forageTasks=safeSubsystem(self,"forage.proposals",FMAForageCoordinator.proposals,self)
        if okForage then for _,t in ipairs(forageTasks or {}) do proposals[#proposals+1]=t end end
    end
    self.livestockMixPlaces={}
    if self.settings.livestock and FMALivestockCoordinator and FMALivestockCoordinator.proposals then
        local okLivestock,livestockTasks=safeSubsystem(self,"livestock.proposals",FMALivestockCoordinator.proposals,self)
        if okLivestock then for _,t in ipairs(livestockTasks or {}) do proposals[#proposals+1]=t end end
    end
    if self.settings.livestock and FMALivestockCoordinator and FMALivestockCoordinator.careProposals then
        local okCare,careOrders=safeSubsystem(self,'livestock.careProposals',FMALivestockCoordinator.careProposals,self)
        if okCare then for _,t in ipairs(careOrders or {}) do proposals[#proposals+1]=t end end
    end
    if self.settings.supply then
        local threshold=self.settings.livestock and self.settings.foodTarget or self.settings.threshold
        local okSupply,supplyTasks=safeSubsystem(self,"world.supplyTasks",FMAWorld and FMAWorld.supplyTasks,self.farmId,threshold)
        for _,t in ipairs(okSupply and (supplyTasks or {}) or {}) do
            local skip=false
            local place=t.destination and t.destination.owningPlaceable
            if place and self.livestockMixPlaces[place] then
                local lp=self.livestockPlans and self.livestockPlans[place]
                if lp then
                    if lp.mixturePlan and lp.mixturePlan.fillType==t.fillType then skip=true end
                    for _,group in ipairs(lp.groups or {}) do for _,ft in ipairs(group.fillTypes or {}) do if ft==t.fillType then skip=true end end end
                elseif place.spec_husbandryFood and place.spec_husbandryFood.supportedFillTypes then skip=place.spec_husbandryFood.supportedFillTypes[t.fillType]==true end
            end
            if not skip then proposals[#proposals+1]=t end
        end
        if (self.settings.livestock or self.settings.productions) and FMALogistics and FMALogistics.outputTasks then
            local okOutputs,outputTasks=safeSubsystem(self,"logistics.outputTasks",FMALogistics.outputTasks,self.farmId,self.settings)
            if okOutputs then for _,t in ipairs(outputTasks or {}) do proposals[#proposals+1]=t end end
        end
        if FMAMarketPlanner and FMAMarketPlanner.scan then
            local okMarket,marketOffers=safeSubsystem(self,"market.scan",FMAMarketPlanner.scan,self)
            if okMarket then for _,t in ipairs(marketOffers or {}) do proposals[#proposals+1]=t end end
        end
    end
    if FMAMarketPlanner and FMAMarketPlanner.verifyTransport then
        safeSubsystem(self,'market.verifyTransport',FMAMarketPlanner.verifyTransport,self)
    end
    self.tasks=FMAPlanner.merge(self.tasks,proposals,self.now)
    if FMASelfHealing and FMASelfHealing.scan then
        safeSubsystem(self,'selfHealing.scan',FMASelfHealing.scan,self)
    end
    if FMARecovery and FMARecovery.restoreJournal then safeSubsystem(self,'handover.restore',FMARecovery.restoreJournal,self) end
    -- A purchase/equipment block is provisional. As soon as a newly bought machine
    -- appears in the live scan, release the task automatically instead of requiring
    -- the player to recreate it or restart the save.
    if FMAProcurement and FMAProcurement.hasForTask then
        for _,task in pairs(self.tasks or {}) do
            if task.state=="blocked" and task.blockedByEquipment==true and FMAProcurement.hasForTask(self,task) then
                task.state="pending";task.phase="NOVÁ TECHNIKA ROZPOZNÁNA";task.reason=nil;task.retryAt=0;task.blockedByEquipment=nil
                self.jobFailures[task.id]=nil
                self:notify(task.label.." · nová vhodná technika rozpoznána")
            end
        end
    end
    -- A replacement power unit may finish a different job later. A handover
    -- waiting for that machine is reactivated by every live scan, without the
    -- owner needing to press refresh or reset its failed-machine history.
    if FMAAssembler and FMAAssembler.findPlan then
        for _,task in pairs(self.tasks or {}) do
            if task.state=='blocked' and task.blockedByHandover and task.forceHandoverImplement then
                local plan=FMAAssembler.findPlan(self,task)
                if plan then
                    task.state='pending';task.phase='VÝMĚNA · NOVÝ TRAKTOR UVOLNĚN'
                    task.reason='Volný kompatibilní tahač nalezen';task.retryAt=0
                    task.blockedByHandover=nil
                    if self.jobFailures and self.jobFailures[task.id] then
                        self.jobFailures[task.id].blocked=false
                        self.jobFailures[task.id].retryAt=0
                    end
                end
            end
        end
    end
    for _,v in ipairs(self.vehicles) do
        local okInspect,compat=safeSubsystem(self,"compatibility.vehicle:"..tostring(v.key),FMACompatibility and FMACompatibility.inspect,v.object)
        v.compatibility=okInspect and (compat or {}) or {autoloaders={},externalBusy=false}
        v.compatibility.autoloaders=v.compatibility.autoloaders or {}
        if v.compatibility.externalBusy then v.busy=true end
        if v.lowFuel then self:issue("fuel:"..v.key,v.name.." · nízké palivo","Manager před prací zkusí fyzicky natankovat z vlastní zásoby; pokud vlastní AI zdroj nafty chybí, požádá majitele o doplnění.",95) end
        if (v.damage or 0)>=0.55 then self:issue("service:"..v.key,v.name.." · servis", "Poškození "..math.floor((v.damage or 0)*100).." %. Naplánuj servis před náročnou směnou; Manager stroj při kritickém stavu nebude preferovat.",82) end
        if #v.compatibility.autoloaders>0 then
            self:issue("autoload:"..v.key,v.name.." · autoloader","Vlastní ovládání autoloaderu zůstává aktivní. Podporovanou trasu nastav na kartě Trasy.",30)
        end
    end
    if self.settings.productions and FMAProductionManager and FMAProductionManager.scan then
        local okProduction,productionIssues=safeSubsystem(self,"production.scan",FMAProductionManager.scan,self.farmId,self.settings)
        if okProduction then for _,issue in ipairs(productionIssues or {}) do self:issue(issue.id,issue.title,issue.detail,issue.priority) end end
    end
    if self.settings.baleStorageAutomation and FMABaleStorage and FMABaleStorage.scan then safeSubsystem(self,"baleStorage.scan",FMABaleStorage.scan,self) end
    if self.settings.baleAutomation and FMABaleCoordinator and FMABaleCoordinator.scan then safeSubsystem(self,"bales.scan",FMABaleCoordinator.scan,self) end
    if FMAProcurement and FMAProcurement.audit then safeSubsystem(self,"procurement.audit",FMAProcurement.audit,self) end
    if FMAFleetCoordinator and FMAFleetCoordinator.sample then safeSubsystem(self,"fleet.sample",FMAFleetCoordinator.sample,self) end
    if FMAFleetCoordinator and FMAFleetCoordinator.planHarvestTeams then safeSubsystem(self,"fleet.harvestTeams",FMAFleetCoordinator.planHarvestTeams,self) end
    for _,condition in ipairs(self.conditions) do
        if not condition.neutral and condition.ratio<self.settings.threshold then
            self:issue(condition.id,condition.name,condition.message,condition.priority)
        end
    end
    if self.money~=nil and self.money<self.settings.reserve then self:issue("money","Finanční rezerva","Nové práce čekají; peníze "..FMAUtil.money(self.money),100) end
    if #self.fields==0 then self:issue("noFields","Nenalezena vlastní pole","Ověř vlastnictví / načtení mapy. Alt+D vytvoří diagnostiku.",65) end
    for _,task in pairs(self.tasks) do
        if task.state=="blocked" then self:issue(task.id,task.label,task.reason,task.priority) end
    end
    for key,route in pairs(self.routes) do
        if route.phase=="blocked" then self:issue("route:"..key,"Trasa autoloaderu",route.reason,95) end
    end
    for id,e in pairs(self.jobFailures or {}) do self:issue("failure:"..id,e.label or id,e.reason,95) end
    publishSubsystemFaults(self)
    self:buildReadinessAudit()
    if self.settings.enabled then self.diagnosticDirty=true end
end

function FMAController:equipmentIssue(operation,context)
    local def=FMACatalog.operations[operation]
    if not def then return end
    local categoryOverride=nil
    local missingDetail=nil
    if operation=="harvest" then
        local hasGrainCombine=false
        for _,record in ipairs(self.vehicles or {}) do
            if record.isGrainCombine==true then hasGrainCombine=true;break end
        end
        if not hasGrainCombine then
            -- A cutter parked on the farm is not a combine. After a combine is sold,
            -- recommend the missing self-propelled machine instead of another cheap header.
            categoryOverride={"HARVESTERS"}
            missingDetail="Chybí vlastní sklízecí mlátička. Adaptér samotný sklizeň nezajistí."
        else
            categoryOverride={"CUTTERS"}
            missingDetail="Sklízecí mlátička je na farmě, ale chybí kompatibilní adaptér pro aktuální plodinu."
        end
    end
    local candidates=FMACatalog.recommend(operation,3,categoryOverride)
    local detail=context..". "..(missingDetail or "Vlastní vhodná souprava nebyla nalezena.").." Požadavek: "..FMACatalog.requirement(operation).."."
    if #candidates>0 then
        detail=detail.." Kandidáti z odpovídající kategorie obchodu:"
        for _,item in ipairs(candidates) do detail=detail.." | "..item.name.." "..FMAUtil.money(item.price) end
        detail=detail.." Finální kompatibilitu ověří Manager z runtime vlastností po nákupu."
    else detail=detail.." V katalogu se nepodařilo bezpečně určit vhodnou položku; zkontroluj uvedený požadavek v obchodě." end
    self.purchaseNeeds=self.purchaseNeeds or {}
    self.approvedPurchases=self.approvedPurchases or {}
    local approved=self.approvedPurchases[operation]==true
    detail=detail.." · Nákup techniky vyžaduje schválení majitele; Manager ji nikdy nekoupí sám."
    self.purchaseNeeds[operation]={operation=operation,label=def.label,context=context,candidates=candidates,detail=detail,approved=approved,status=approved and "APPROVED" or "WAIT_APPROVAL"}
    self:issue("equipment:"..operation,"NÁVRH NÁKUPU · "..def.label,detail,72)
end

function FMAController:taskStillCurrent(task)
    if not task or task.kind~="field" then return true,nil end
    local field=self.fieldsById and self.fieldsById[task.fieldId]
    if not field or not field.valid then return false,"Pole už nemá ověřený živý stav" end
    local op=task.operation
    if op=="harvest" and field.ready~=true then return false,"Pole už není připravené ke sklizni" end
    if op=="mow" and field.ready~=true then return false,"Porost už není připraven k sečení" end
    if (op=="lime" or op=="plow" or op=="cultivate" or op=="stone") and field.alive==true then
        return false,"Na poli je živý porost; půdní práce jsou odloženy"
    end
    if op=="lime" and field.needsLime~=true then return false,"Pole už nepotřebuje vápno" end
    if op=="plow" and field.needsPlow~=true then return false,"Pole už nepotřebuje orbu" end
    if op=="stone" and field.needsStone~=true then return false,"Pole už nepotřebuje sběr kamenů" end
    if op=="fertilize" and field.needsFertilize~=true then return false,"Pole už nepotřebuje hnojení" end
    if op=="weed" and field.needsWeed~=true then return false,"Pole už nepotřebuje odstranění plevele" end
    if op=="roll" and field.needsRoll~=true then return false,"Pole už nepotřebuje válcování" end
    return true,nil
end


function FMAController:verifyFieldOrderComplete(task)
    if not task or task.kind~="field" then return true,nil end
    if not task.fieldworkStartedAt then return false,"Polní práce se ve skutečnosti ještě nespustila" end
    local field=self.fieldsById and self.fieldsById[task.fieldId]
    if not field or field.valid~=true or field.mixed==true then
        return false,"Stav pole není ověřený nebo ještě zbývá část neopracované plochy"
    end
    -- Density maps expose fertilizing/plowing/harvest results, but not reliable
    -- windrow/tedder completion. A completed *Courseplay route* can advance a
    -- forage crew as an AI stage, NEVER as verified soil/coverage completion.
    if task.forageChain and task.confirmedAiWorkFinish==true and task.qualityCourseReady==true then
        local stage=self.forageStages and self.forageStages[tostring(task.fieldId)]
        if task.operation=='ted' and stage=='tedded' then
            return true,'Courseplay potvrdil dokončení etapy obracení; pokrytí řádků nelze změřit','AI_STAGE'
        elseif task.operation=='windrow' and (stage=='windrowed' or stage=='windrowedGrass' or stage=='windrowedHay') then
            return true,'Courseplay potvrdil dokončení etapy shrnování; fyzický objem řádků neověřen','AI_STAGE'
        end
    end
    -- A completed physical delivery confirms cargo transfer, NOT whole-field coverage.
    if task.operation=='foragePickup' and self.forageStages
        and self.forageStages[tostring(task.fieldId)]=='collected' then
        return true,'Píce skutečně dodána a vůz je prázdný; úplnost sběru řádků není ověřená','DELIVERY'
    end
    if task.fingerprint and field.fingerprint and task.fingerprint==field.fingerprint then
        return false,"FS25 stále hlásí shodný stav pole jako před zahájením práce"
    end
    -- An AI success message, a missing field, or an irrelevant crop-state change
    -- is not an agricultural completion. Demand operation-specific physical evidence.
    local op=task.operation
    local done=false
    if op=='harvest' then done=field.ready==false and field.bare==true
    elseif op=='mow' then done=field.ready==false
    elseif op=='lime' then done=field.needsLime==false
    elseif op=='plow' then done=field.needsPlow==false
    elseif op=='stone' then done=field.needsStone==false
    elseif op=='fertilize' then done=field.needsFertilize==false
    elseif op=='weed' then done=field.needsWeed==false
    elseif op=='roll' then done=field.needsRoll==false
    elseif op=='cultivate' then done=field.prepared==true
    elseif op=='sow' then
        done=field.alive==true and (not task.crop or task.crop=='' or field.fruit==task.crop)
    end
    if not done then
        return false,"FS25 stále hlásí potřebu operace nebo chybí důkaz jejího fyzického výsledku · "..tostring(op)
    end
    -- A changed density map is NOT proof a spreader actually applied material.
    -- Confirm its attached fill unit was consumed during this job.
    if FMAWorkEvidence then
        local record=self.vehicleByKey and self.vehicleByKey[task.vehicleKey]
        local physical,physicalWhy=FMAWorkEvidence.verify(task,record)
        if not physical then return false,physicalWhy end
    end
    return true,"Výsledek operace "..tostring(op).." ověřen skutečným stavem pole",'WORLD' 
end

function FMAController:buildReadinessAudit()
    local audit={}
    for _,task in ipairs(FMAPlanner.queue(self.tasks or {})) do
        if task.state=="pending" or task.state=="blocked" or task.ownerRequested then
            local row={taskId=task.id,label=task.label,operation=task.operation,state="UNKNOWN"}
            local current,currentWhy=self:taskStillCurrent(task)
            if not current then
                row.state="STALE";row.reason=currentWhy
            else
                -- A parked combine can be a complete real transport chain even while the cutter
                -- is riding on a header trailer. Generic capability scanning sees the bare combine
                -- and would wrongly reject it. Recognise this workflow before the ordinary selector.
                local preloaded=nil
                if task.operation=="harvest" and self.settings.headerTransport and FMAHeaderTransport and FMAHeaderTransport.preloadedChain then
                    preloaded=FMAHeaderTransport.preloadedChain(self,task)
                end
                if preloaded then
                    row.main="PRELOADED";row.vehicle=preloaded.record.name;row.tool=preloaded.cutter.name
                    row.reason="Kombajn + podvozek + adaptér jsou připravený přepravní řetězec"
                else
                    local vehicle,why,kind=FMAPlanner.chooseVehicle(task,self.vehicles or {},self.reservations or {},self.excluded or {})
                    if vehicle then
                        row.main="READY";row.vehicle=vehicle.name
                    elseif FMAAssembler and FMAAssembler.findPlan then
                        local plan,assemblyWhy=FMAAssembler.findPlan(self,task)
                        if plan then row.main="ASSEMBLE";row.vehicle=plan.power.name;row.tool=plan.tool.name
                        elseif FMAAssembler.hasPotentialForTask and FMAAssembler.hasPotentialForTask(self,task) then row.main="WAIT";row.reason=why or assemblyWhy
                        else row.main="MISSING";row.reason=why or assemblyWhy end
                    else row.main=kind=="busy" and "WAIT" or "MISSING";row.reason=why end
                end
                if task.operation=="harvest" and FMAFleetCoordinator and FMAFleetCoordinator.previewTransport then
                    if row.main=="MISSING" then
                        row.support="HOLD";row.supportReason="Odvoz se nepřipravuje, dokud nechybějící hlavní sklizňová technika není na farmě"
                    else
                        local support=FMAFleetCoordinator.previewTransport(self,task,1)
                        row.support=support and support.state or "UNKNOWN"
                        row.supportVehicle=support and support.vehicle and support.vehicle.name or nil
                        row.supportTool=support and support.tool and support.tool.name or nil
                        row.supportReason=support and support.reason or nil
                    end
                end
                if row.main=="READY" or row.main=="ASSEMBLE" or row.main=="WAIT" or row.main=="PRELOADED" then row.state="SERVICEABLE" else row.state="BLOCKED" end
            end
            audit[task.id]=row
        end
    end
    self.readinessAudit=audit
    return audit
end

function FMAController:dispatch()
    if self.inventorySafe==false then
        self.waitReason='ČEKÁM NA PLATNÉ ŽIVÉ ZJIŠTĚNÍ TECHNIKY A POLÍ'
        return
    end
    if self.vehicleReloadHold or (g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.isReloadRunning==true) then
        self.waitReason='Reset / reload techniky · dispečink čeká na živý registr vozidel'
        return
    end
    local allowed,reason=FMAPlanner.canDispatch(self.settings,self.now,FMAWorld.money(self.farmId),FMAUtil.count(self.reservations))
    self.waitReason=reason
    if not allowed then return end
    if self.settings.daylightOnly then
        local hour=math.floor((g_currentMission.environment.dayTime or 0)/3600000)%24
        if hour<6 or hour>=22 then self.waitReason="Noční klid 22–06";return end
    end
    -- Owner-selected dispatch: AUTO is the worker master switch, not permission
    -- to start every proposal on the farm. Approved field orders are independent.
    if self.settings.selectedJobsOnly~=true and FMAAutoRoute and FMAAutoRoute.dispatch(self) then return end
    for _,task in ipairs(FMAPlanner.queue(self.tasks)) do
        if (self.settings.selectedJobsOnly~=true or task.ownerApproved==true)
            and (not task.requiresSaleApproval or task.ownerApproved==true)
            and task.kind~="bunkerWorkOrder" and task.kind~="livestockNeed" and task.state=="pending" and (task.retryAt or 0)<=self.now and FMAJobs.mayStart(self,task.id) then
            local current,currentWhy=self:taskStillCurrent(task)
            if not current then
                task.state="cooldown";task.phase="PLÁN ZASTARAL";task.reason=currentWhy;task.retryAt=self.now+2000
                self.diagnosticDirty=true
                self.waitReason=currentWhy
                self:scan()
                return
            end
            local conflict=FMALifecycle.fieldBusy(self,task)
            for _,a in pairs(self.active) do
                if task.kind=="field" and a.task.fieldId==task.fieldId then conflict=true end
                if task.kind=="supply" and a.task.kind=="supply" and
                    (a.task.destination==task.destination or a.task.source==task.source) then conflict=true end
                if task.kind=="livestockMix" and (a.task.parentTaskId==task.id or a.task.id==task.id) then conflict=true end
            end
            if not conflict then
                -- Never dispatch support vehicles when the main harvesting machine does not
                -- exist. This was the reason the 6R kept being sent to fields after the combine
                -- had already been sold. Surface a purchase need, then automatically re-open
                -- the job when a replacement machine appears in a later live scan.
                if (task.operation=="harvest" or task.operation=="foragePickup") and FMAProcurement and FMAProcurement.hasForTask then
                    local preloadedServiceable=false
                    if task.operation=="harvest" and self.settings.headerTransport and FMAHeaderTransport and FMAHeaderTransport.preloadedChain then
                        preloadedServiceable=FMAHeaderTransport.preloadedChain(self,task)~=nil
                    end
                    if not preloadedServiceable and not FMAProcurement.hasForTask(self,task) then
                        task.state="blocked";task.phase="DOKOUPIT TECHNIKU";task.reason="Chybí vlastní hlavní stroj / kompatibilní sestavitelná souprava";task.blockedByEquipment=true
                        self:equipmentIssue(task.operation,task.label)
                        self.waitReason=task.reason
                        return
                    end
                end
                -- Prepare harvest logistics independently only after the main machine has
                -- been proven to exist. The faster transport can then stage while the combine
                -- or header is being prepared.
                if (task.operation=="harvest" or task.operation=="foragePickup") and FMAFleetCoordinator
                    and (not FMAFleetCoordinator.mainHarvesterReady or FMAFleetCoordinator.mainHarvesterReady(self,task)) then
                    local required=(FMAFarmBrain and FMAFarmBrain.supportCount and FMAFarmBrain.supportCount(self,task)) or 1
                    for slot=1,required do
                        local crewStarted=FMAFleetCoordinator.preparePendingHarvestCrew(self,task,slot)
                        if crewStarted then return end
                    end
                end
                task.phase="PŘEDSTARTOVNÍ KONTROLA / SOUPRAVA"
                -- A completed handover explicitly targets the returned implement.
                -- Never quietly start an unrelated ready rig before giving the
                -- replacement tractor a chance to hitch the actual tool.
                if task.forceHandoverImplement and FMAAssembler then
                    local started,why=FMAAssembler.dispatch(self,task)
                    if started then return end
                    task.state='blocked';task.phase='VÝMĚNA / ČEKÁ NA DRUHÝ TRAKTOR'
                    task.reason=why or 'Po návratu nářadí není volný kompatibilní traktor'
                    task.blockedByHandover=true
                    self:issue('handover:'..task.id,task.label,task.reason,92)
                    return
                end
                -- Handle a combine that is already parked as combine -> header trailer -> cutter.
                -- This must happen before the generic vehicle selector, because while the cutter is
                -- transported the combine intentionally does not expose a direct harvest capability.
                if task.operation=="harvest" and self.settings.headerTransport and FMAHeaderTransport and FMAHeaderTransport.preloadedChain then
                    local chain=FMAHeaderTransport.preloadedChain(self,task)
                    if chain then
                        local cpOwns=FMAFieldQuality and FMAFieldQuality.courseplayOwnsHeaderTransport
                            and FMAFieldQuality.courseplayOwnsHeaderTransport(chain.record.object,task)
                        if cpOwns then
                            -- Courseplay already has a dedicated attach-header task. Keep the
                            -- complete X9 -> carrier -> cutter chain intact and let its fieldwork
                            -- job perform GIANTS drive-to, header handling and fieldwork as one job.
                            task.preferredVehicleKey=chain.record.key;task.preferredVehicleName=chain.record.name
                            task.preferredImplementKey=chain.cutter.key;task.preferredImplementName=chain.cutter.name
                            task.headerTransportPlan=nil;task.headerTransportReady=nil
                            task.phase="COURSEPLAY · PŘEJEZD + ADAPTÉR + PRÁCE"
                        else
                            local started,chainWhy=FMAHeaderTransport.startPreloadedOutbound(self,task,chain)
                            if started then return end
                            task.state="blocked";task.reason=chainWhy or "Předpřipravený přepravní řetězec adaptéru nelze rozjet"
                            self:issue("headerPreloaded:"..task.id,task.label.." · přeprava adaptéru",task.reason,98)
                            return
                        end
                    end
                end
                local vehicle,why,kind=FMAPlanner.chooseVehicle(task,self.vehicles,self.reservations,self.excluded,self.experience)
                if vehicle then
                    task.phase="PŘEDSTARTOVNÍ KONTROLA STROJE"
                    local prestartOk,prestartWhy=FMALifecycle.prestartCheck(self,task,vehicle)
                    if not prestartOk then
                        task.state="pending";task.reason=prestartWhy;task.retryAt=self.now+1500;self.waitReason=prestartWhy
                        self.elapsed=self.settings.scanSeconds*1000
                        return
                    end
                    if task.kind=="livestockMix" and FMALivestockCoordinator then
                        local started,mixWhy=FMALivestockCoordinator.dispatch(self,task,vehicle)
                        if started then return end
                        task.state="blocked";task.reason=mixWhy or "Krmnou dávku nelze připravit"
                        self:issue(task.id,task.label,task.reason,99)
                        return
                    end
                    -- A harvester never leaves as an isolated machine. Before fieldwork we make sure
                    -- at least the first haulage unit exists (or physically assemble tractor + trailer).
                    if (task.operation=="harvest" or (task.operation=="foragePickup" and vehicle.hasCombine)) and FMAFleetCoordinator then
                        local preparing,supportWhy=FMAFleetCoordinator.preflightHarvest(self,task,vehicle)
                        if preparing then return end
                        if supportWhy then
                            task.state="blocked";task.reason=supportWhy
                            self:issue("harvestSupport:"..task.id,task.label.." · chybí odvoz",supportWhy,98)
                            return
                        end
                    end
                    -- Wide harvesting equipment is transported as a complete real-world chain before fieldwork starts.
                    if self.settings.headerTransport and task.operation=="harvest" and FMAHeaderTransport then
                        local cpOwnsHeader=FMAFieldQuality and FMAFieldQuality.courseplayOwnsHeaderTransport
                            and FMAFieldQuality.courseplayOwnsHeaderTransport(vehicle.object,task)
                        if cpOwnsHeader then
                            task.headerTransportPlan=nil;task.headerTransportReady=nil
                            task.phase="COURSEPLAY · ADAPTÉR NA PODVOZKU"
                        else
                            local needed,cutter,width=FMAHeaderTransport.needsTransport(self,task,vehicle)
                            if needed then
                                local started,workflowWhy=FMAHeaderTransport.startOutbound(self,task,vehicle,cutter,width)
                                if started then return end
                                task.state="blocked";task.reason=workflowWhy;self:issue(task.id,task.label,workflowWhy,98);return
                            end
                        end
                    end
                    -- Generate a deterministic Courseplay field course with safe headlands and overlap.
                    if task.kind=="field" and FMAFieldQuality then
                        local ready,waiting,qualityWhy=FMAFieldQuality.ensureCourse(self,task,vehicle)
                        if waiting then self.waitReason=qualityWhy;return end
                        if not ready and qualityWhy then task.state="blocked";task.reason=qualityWhy;self:issue(task.id,task.label,qualityWhy,85);return end
                    end
                    -- Seeds/fertilizer/lime/fuel must exist physically before the worker is allowed onto the field.
                    if FMARefillManager then
                        task.phase="PLNĚNÍ / PROVOZNÍ MATERIÁLY"
                        local filling,fillWhy=FMARefillManager.dispatch(self,task,vehicle)
                        if filling then return end
                        if fillWhy then task.state="blocked";task.reason=fillWhy;return end
                    end
                    -- Courseplay's public startAtFirstWp is intentionally a DIRECT start.
                    -- Use it only after the base-game AI has brought a remote machine to a
                    -- reachable edge of the field (the same hand-off pattern used by external
                    -- route managers). This prevents a combine at the shop from trying to
                    -- pathfind directly to a field row with its header trailer attached.
                    if task.kind=="field" and self.settings.preferCourseplay and task.baseAIFallback~=true
                        and FMAUtil.call(vehicle.object,'hasCpCourse')==true and FMACourseplay and FMACourseplay.stageFieldwork then
                        local staging,stageWhy=FMACourseplay.stageFieldwork(self,task,vehicle)
                        if staging then return end
                        if stageWhy then task.state="blocked";task.phase="BLOKACE PŘEJEZDU";task.reason=stageWhy;self:issue(task.id,task.label,stageWhy,96);return end
                    end
                    task.phase="PŘEJEZD NA PRACOVIŠTĚ / PRÁCE"
                    if self.settings.trafficSafety and FMATraffic and FMATraffic.canStart then
                        local target={x=task.x or vehicle.x,z=task.z or vehicle.z}
                        local free,trafficWhy=FMATraffic.canStart(self,vehicle,target,task,60000)
                        if not free then
                            task.state="pending";task.phase="ČEKÁ NA PROVOZ";task.reason=trafficWhy;task.retryAt=self.now+((self.settings.trafficRetrySeconds or 6)*1000)
                            self.waitReason=trafficWhy
                            return
                        end
                    end
                    local ok,job,errorText=pcall(FMAAI.start,self,task,vehicle)
                    if ok and job then
                        task.attempts=(task.attempts or 0)+1;task.vehicleKey=vehicle.key
                        self.reservations[vehicle.key]=task.id;vehicle.busy=true
                        local pendingCp=(errorText=="COURSEPLAY_PUBLIC_PENDING" or job.fmaCourseplayPublicStart==true)
                        self.active[job]={job=job,task=task,vehicle=vehicle,start=self.now,lastProgress=self.now,x=vehicle.x,z=vehicle.z,fill=vehicle.fillTotal,startPendingCp=pendingCp,startPendingNative=not pendingCp and task.kind=='field'}
                        if pendingCp then
                            task.state="starting";task.phase="COURSEPLAY · ČEKÁ NA SKUTEČNÉ PŘEVZETÍ"
                            task.reason="Start odeslán přes veřejné rozhraní Courseplay · čeká na potvrzení AI"
                        elseif task.kind=='field' then
                            task.state='starting';task.phase='FS25 AI · ČEKÁ NA PŘEVZETÍ'
                            task.reason='AI job byl odeslán · ověřuje se skutečné řízení'
                        else
                            task.state="running";task.phase="PRÁCE";task.reason=nil
                            self:notify(task.label.." · "..vehicle.name)
                        end
                        return
                    else
                        if self.pendingJob then
                            if self.pendingJob.isRunning then pcall(FMAAI.stop,self.pendingJob) end
                            self.pendingJob=nil
                        end
                        self.startingTask=nil;self.startingVehicle=nil
                        if FMATraffic then FMATraffic.release(self.traffic,vehicle.key) end
                        local why=ok and errorText or tostring(job)
                        task.failures=(task.failures or 0)+1
                        FMAJobs.fail(self,task,vehicle,why or 'AI odmítlo start bez popisu')
                        if not ok then FMAUtil.log("Start odmítnut: "..tostring(job)) end
                    end
                elseif kind=="configuration" then
                    -- A player-selected bare tractor/combine is still a valid choice: first try
                    -- to assemble it with the selected/AUTO detached implement, then refill it.
                    if self.settings.autoAssemble and FMAAssembler then
                        local assembled,assemblyReason=FMAAssembler.dispatch(self,task)
                        if assembled then return end
                        if assemblyReason and task.preferredVehicleKey then task.reason=assemblyReason end
                    end
                    if FMARefillManager then
                        local preparable=FMARefillManager.findPreparableVehicle(self,task)
                        if preparable then
                            local filling,fillWhy=FMARefillManager.dispatch(self,task,preparable)
                            if filling then return end
                            if fillWhy then task.state="blocked";task.reason=fillWhy;return end
                        end
                    end
                    self:issue(task.id,task.label,task.reason or why,task.priority)
                elseif kind=="equipment" and self.settings.autoAssemble and FMAAssembler then
                    local assembled,assemblyReason=FMAAssembler.dispatch(self,task)
                    if assembled then return end
                    self:issue(task.id,task.label,assemblyReason or why,task.priority)
                    if not (FMAAssembler.hasPotentialForTask and FMAAssembler.hasPotentialForTask(self,task)) then self:equipmentIssue(task.operation,task.label) end
                elseif kind~="busy" then
                    self:issue(task.id,task.label,why,task.priority)
                    if kind=="equipment" and not (FMAAssembler and FMAAssembler.hasPotentialForTask and FMAAssembler.hasPotentialForTask(self,task)) then self:equipmentIssue(task.operation,task.label) end
                end
            end
        end
    end
end

function FMAController:handleJobStopped(job,message)
    local a=self.active[job]
    if not a then return end
    self.active[job]=nil
    -- Another worker may have acquired this tractor after the departing job
    -- stopped. Never clear an unrelated, newer reservation.
    if a.task and (self.reservations[a.vehicle.key]==a.task.id
            or self.reservations[a.vehicle.key]==a.task) then
        self.reservations[a.vehicle.key]=nil
    end
    -- A job-stop callback can arrive AFTER another worker acquired the tractor.
    -- Never release the newer operator's busy bit or its traffic corridor.
    local successor=false
    if self.ownDriveSessions and self.ownDriveSessions[a.vehicle.key] then successor=true end
    for newerJob,newer in pairs(self.active or {}) do
        if newerJob~=job and newer and newer.vehicle and newer.vehicle.key==a.vehicle.key then
            successor=true;break
        end
    end
    if self.reservations[a.vehicle.key] then successor=true end
    local bunkerKind=a.task and (a.task.kind=="bunker" or a.task.kind=="bunkerApproach" or a.task.kind=="bunkerYield" or a.task.kind=="bunkerDelivery")
    if self.traffic and not bunkerKind and not successor then FMATraffic.release(self.traffic,a.vehicle.key) end
    if not successor then a.vehicle.busy=false end
    local parentOrder=a.task and (a.task.parentTask or (a.task.parentTaskId and self.tasks[a.task.parentTaskId]) or a.task)
    if a.stopReason=='OWNER_STOP_SELECTED' or (parentOrder and parentOrder.ownerStopRequested==true) then
        if a.assemblyPlan and a.assemblyPlan.tool then self.implementReservations[a.assemblyPlan.tool.key]=nil end
        if a.transportAssemblyPlan and a.transportAssemblyPlan.tool then self.implementReservations[a.transportAssemblyPlan.tool.key]=nil end
        if a.task then a.task.state='paused';a.task.reason='Zastaveno majitelem' end
        if parentOrder then parentOrder.state='paused';parentOrder.phase='STOP';parentOrder.reason='Zastaveno majitelem' end
        return
    end
    local outcome=FMAJobs.outcome(message)
    a.outcome=outcome
    -- AI can stop immediately when the owner presses H/takes the wheel, before the
    -- once-per-second takeover monitor gets a chance to tag the job. Detect the live
    -- control state here as well so the crew survives that race.
    local operatorState=FMAGameNative and FMAGameNative.operatorState(a.vehicle and a.vehicle.object) or {manual=false}
    if outcome~="success" and operatorState.manual then
        a.playerTakeover=true;a.stopReason="PLAYER_TAKEOVER"
        self.playerTakeovers=self.playerTakeovers or {}
        self.playerTakeovers[a.vehicle.key]={task=a.task,taskId=a.task and a.task.id,vehicle=a.vehicle,vehicleKey=a.vehicle.key,mode="PLAYER"}
    end
    FMADiagnostics.event(self,"job.stop",a.task.id,outcome.." | "..FMAJobs.message(message))
    if FMANavigation and FMANavigation.finish and a.task.kind~="navigationEscape" then FMANavigation.finish(self,a,outcome) end
    if not self.settings.enabled or self.shuttingDown then
        a.task.state="paused";a.task.reason="Automatika je pozastavena"
        local parent=a.task.parentTask or self.tasks[a.task.parentTaskId]
        if parent then parent.state="paused";parent.reason=a.task.reason end
        if self.traffic then FMATraffic.release(self.traffic,a.vehicle.key) end
        if a.assemblyPlan and a.assemblyPlan.tool then self.implementReservations[a.assemblyPlan.tool.key]=nil end
        local ws=a.task.bunkerIndex and self.bunkerWorkState[a.task.bunkerIndex]
        if ws then ws.activeDeliveryKey=nil;ws.active=false;ws.approaching=false end
        return
    end
    local fullLoad=outcome=="full" and ((a.task.kind=="field" and a.task.operation=="foragePickup") or a.task.kind=="bales" or (a.task.kind=="support" and a.task.forageBunker))
    if fullLoad then a.task.resumeAfterDelivery=true end
    if outcome~="success" and not fullLoad and not a.stopReason then a.stopReason=FMAJobs.message(message) end
    if a.task.kind=="bunker" and (a.task.yieldForDelivery or a.task.completeForCover or a.task.switchToCompaction) then a.stopReason=nil end
    if a.playerTakeover or a.stopReason=="PLAYER_TAKEOVER" then
        a.task.state="running";a.task.phase="RUČNÍ ČLEN ČETY";a.task.reason="Majitel převzal volant · zakázka i četa zůstávají aktivní";return
    end
    if a.trafficYield or a.stopReason=="TRAFFIC_YIELD" then
        if FMATraffic and FMATraffic.onYieldStopped then FMATraffic.onYieldStopped(self,a) end
        return
    end
    -- In a learned multi-leg transit, successful arrival at an intermediate
    -- waypoint starts the next GIANTS job before the parent workflow can run.
    if FMAPathRunner and FMAPathRunner.advance and FMAPathRunner.advance(self,a,outcome) then return end
    if a.bunkerRequested and outcome=="cancelled" then a.stopReason=nil end
    if a.task.kind=="navigationEscape" and FMANavigation and FMANavigation.escapeStopped then FMANavigation.escapeStopped(self,a);return end
    if a.stopReason=="NAV_REVERSE" and FMARecovery and FMARecovery.onStopped and FMARecovery.onStopped(self,a) then return end
    if a.stopReason=="RECOVERY_REROUTE" and FMARecovery and FMARecovery.onStopped and FMARecovery.onStopped(self,a) then return end
    -- supportStage has its own route rotation/retry logic. Recording it as a generic
    -- equipment/job failure would poison the temporary task and can strand the crew.
    if a.stopReason and a.task.kind~="supportStage" and a.task.kind~="service" and a.task.kind~="assemble" and a.task.kind~="unloaderAssemble" and a.task.kind~="return" and a.task.kind~="refill" and a.task.kind~="support" and a.task.kind~="supportDelivery" then FMAJobs.fail(self,a.task,a.vehicle,a.stopReason) end
    -- The handover is its own physical workflow. In particular, the normal
    -- field-job completion path must not immediately overwrite its state.
    if a.task.kind=='field' and a.task.state=='handover' then return end
    if a.task.kind=='field' and a.stopReason and a.task.state=='pending' and (a.task.phase=='OBNOVA / NÁHRADNÍ STROJ' or a.task.phase=='OBNOVA / DRUHÝ POKUS') then return end
    if a.task.kind=="assemble" and FMAAssembler then FMAAssembler.onStopped(self,a,message);return end
    if a.task.kind=="unloaderAssemble" and FMAFleetCoordinator then FMAFleetCoordinator.onTransportAssemblyStopped(self,a,message);return end
    if a.task.kind=="supportStage" and FMAFleetCoordinator then FMAFleetCoordinator.onSupportStageStopped(self,a,message);return end
    if a.task.kind=="fieldStage" and FMACourseplay and FMACourseplay.onFieldStageStopped then FMACourseplay.onFieldStageStopped(self,a);return end
    if a.task.kind=="futureStage" and FMAFarmBrain then FMAFarmBrain.onFutureStageStopped(self,a,message);return end
    if a.task.kind=="service" and FMAServiceManager then FMAServiceManager.onStopped(self,a,message);return end
    if a.task.kind=="refill" and FMARefillManager then FMARefillManager.onStopped(self,a,message);return end
    if a.task.kind=="headerTransport" and FMAHeaderTransport then FMAHeaderTransport.onStopped(self,a,message);return end
    if a.task.kind=="route" and FMAAutoRoute then FMAAutoRoute.onStopped(self,a,message);return end
    if a.task.kind=="return" and FMAReturnManager then FMAReturnManager.finish(self,a);return end
    if a.task.kind=="baleDelivery" and FMABaleStorage then FMABaleStorage.onStopped(self,a);return end
    if a.task.kind=="supportDelivery" and FMAHaulageCycle then
        FMAHaulageCycle.onDeliveryStopped(self,a);return
    end
    if a.task.kind=="supply" and FMAMarketPlanner then
        FMAMarketPlanner.onTransportStopped(self,a,outcome);return
    end
    if a.task.kind=="support" and FMAFleetCoordinator and FMAFleetCoordinator.onSupportStopped then
        if FMAFleetCoordinator.onSupportStopped(self,a) then return end
    end
    if a.task.kind=="livestockMixDrive" and FMALivestockCoordinator then FMALivestockCoordinator.onDriveStopped(self,a);return end
    if a.task.kind=="livestockFeedDeliver" and FMALivestockCoordinator then FMALivestockCoordinator.onDeliveryStopped(self,a);return end
    if (a.task.kind=="bunker" or a.task.kind=="bunkerApproach" or a.task.kind=="bunkerYield" or a.task.kind=="bunkerDelivery") and FMABunkerCoordinator then
        if FMABunkerCoordinator.onStopped(self,a) then return end
    end
    if a.task.kind=="forageDelivery" and FMAForageCoordinator then FMAForageCoordinator.onDeliveryStopped(self,a);return end
    local task=a.task
    local isError=outcome~="success" and not fullLoad
    if not a.stopReason and outcome=="success" and task.kind=="field" then
        -- A finished AI job is NOT proof that the agricultural operation is finished.
        -- It only means the execution engine stopped successfully. The real FS25 field
        -- state must change before the dispatcher may close the work order.
        if task.fieldworkStartedAt then
            if FMAFieldQuality then FMAFieldQuality.rememberWindrow(self,task,a.vehicle.object);FMAFieldQuality.markCompleted(self,task) end
            -- Mowing/harvest start a new forage/straw chain only AFTER physical
            -- field-state verification at home, not on AI success alone.
            if FMAForageCoordinator and task.operation~='mow' and task.operation~='harvest' then
                FMAForageCoordinator.afterOperation(self,task)
            end
            task.confirmedAiWorkFinish=true
            task.awaitingWorldVerification=true
            task.phase="OVĚŘENÍ SKUTEČNÉHO STAVU POLE"
            task.reason="AI krok skončil · Dispečink ověřuje skutečný výsledek v FS25"
        else
            task.state="blocked";task.phase="BLOKACE"
            task.reason="Pracovní job skončil bez potvrzeného startu polní práce; zakázka nesmí být označena HOTOVO"
        end
        self.elapsed=self.settings.scanSeconds*1000
        self.diagnosticDirty=true
    end
    if not a.stopReason and not isError and task.kind=="field" and task.operation=="foragePickup" and FMAForageCoordinator then
        local ok,why=FMAForageCoordinator.beginDelivery(self,a)
        if ok then return end
        if why then FMAJobs.fail(self,task,a.vehicle,why);return end
    end
    if not a.stopReason and not isError and task.kind=="bales" and FMABaleStorage then
        local ok,why=FMABaleStorage.beginDelivery(self,a)
        if ok then return end
        if why and why~="Sběrač nemá naložené balíky" then FMAJobs.fail(self,task,a.vehicle,why);return end
    end
    if not a.stopReason and not isError and task.kind=="field" and task.operation=="harvest" and task.headerTransportPlan and task.headerTransportReady and FMAHeaderTransport then
        local ok,why=FMAHeaderTransport.beginReturn(self,a)
        if ok then return end
        if why then FMAJobs.fail(self,task,a.vehicle,"Návrat adaptéru: "..tostring(why));return end
    end
    if not a.stopReason and not isError and self.settings.autoReturn and FMAReturnManager and task.kind~="route" then
        local ok,why=FMAReturnManager.begin(self,a)
        if ok then return end
        if why then FMAJobs.fail(self,task,a.vehicle,"Návrat: "..tostring(why));return end
    end
    if (task.kind=="support" or task.kind=="bales") and not a.stopReason then task.state="done";task.reason=nil;return end
    task.state="cooldown";task.retryAt=self.now+45000
    task.reason="AI zastavena; čeká na novou kontrolu pole / zásob"
    if a.stopReason then
        task.state="blocked";task.phase="BLOKACE";task.reason=a.stopReason
    elseif isError then
        task.state="blocked";task.reason="AI nahlásila chybu. Ověř cestu, nářadí a náplně; Alt+R zkusí znovu."
    elseif (task.attempts or 0)>=self.settings.maxAttempts then
        task.state="blocked";task.reason="Dosažen limit pokusů. Ověř pole, cestu a náplně; Alt+R obnoví plán."
    end
    if message and message.getMessage then FMAUtil.log(task.label..": "..tostring(message:getMessage())) end
    self.elapsed=self.settings.scanSeconds*1000
end

function FMAController:watchdog()
    local stopped={}
    for job,a in pairs(self.active) do
        local vehicle=a.vehicle.object
        if a.startPendingCp==true then
            -- Courseplay starts through AIJobStartRequestEvent. Give the engine/network event
            -- time to bind the job before treating a non-running job as a failure.
            if self.now-(a.start or self.now)>9000 then stopped[#stopped+1]=job end
        elseif not job.isRunning then stopped[#stopped+1]=job
        else
            local x,z=FMAUtil.position(vehicle)
            local moved=x and a.x and ((x-a.x)^2+(z-a.z)^2)>4
            local fill=0
            for _,tool in ipairs(FMAWorld.children(vehicle)) do
                for i in pairs(FMAUtil.call(tool,"getFillUnits") or {}) do fill=fill+(FMAUtil.call(tool,"getFillUnitFillLevel",i) or 0) end
            end
            if a.task and a.task.kind=="support" and FMAUtil.call(vehicle,"getIsCpCombineUnloaderActive")==true then
                a.lastProgress=self.now;a.x=x;a.z=z;a.fill=fill
            elseif moved or (not a.trafficTarget and math.abs(fill-(a.fill or fill))>1) then
                a.lastProgress=self.now;a.x=x;a.z=z;a.fill=fill
            elseif self.now-(a.lastProgress or self.now)>(a.trafficTarget and (self.settings.navigationTimeoutSeconds or 75) or (self.settings.stallSeconds or 300))*1000 then
                a.stopReason="Bez skutečného posunu stroje na přejezdu / v práci"
                stopped[#stopped+1]=job
            end
        end
    end
    for _,job in ipairs(stopped) do
        if job.isRunning then FMAAI.stop(job) end
        if self.active[job] then self:onJobStopped(job,nil) end
    end
end

function FMAController:reconcileRuntimeState()
    local vehicles,tools=FMALifecycle.liveReservations(self)
    for key in pairs(self.reservations) do if not vehicles[key] then self.reservations[key]=nil end end
    for key in pairs(self.implementReservations) do if not tools[key] then self.implementReservations[key]=nil end end
    -- Rehydrate the exact own driver task after save/load or a stale cleanup.
    -- A physical FMA driver must never become dispatchable while turning wheels.
    for key,s in pairs(self.ownDriveSessions or {}) do
        self.reservations[key]=s.id
        if s.toolKey then self.implementReservations[s.toolKey]=s.id end
    end
    for _,v in ipairs(self.vehicles or {}) do
        v.busy=vehicles[v.key]==true or (FMAGameNative and FMAGameNative.isManuallyControlled(v.object))==true
            or FMAUtil.call(v.object,"getIsAIActive")==true or (v.compatibility and v.compatibility.externalBusy)==true
    end
    if self.traffic then FMATraffic.clean(self.traffic,self.now or 0) end
end

function FMAController:preflightAutomation()
    local report={errors={},warnings={},checkedAt=self.now or 0}
    local function err(id,text) report.errors[#report.errors+1]=text;self:issue("preflight:"..id,"AUTO nelze spustit",text,100) end
    local function warn(id,text) report.warnings[#report.warnings+1]=text;self:issue("preflightWarn:"..id,"AUTO upozornění",text,55) end

    if not self.initialized then err("init","Manager ještě nedokončil inicializaci farmy") end
    if not self.supported then err("platform","Automatika je povolena jen v podporovaném singleplayer režimu") end
    if not g_currentMission or not g_currentMission.isRunning then err("mission","Mise ještě neběží") end
    if not g_currentMission or not g_currentMission.aiSystem or type(g_currentMission.aiSystem.startJob)~="function" then err("ai","FS25 AI systém není připraven pro spuštění pracovních jobů") end
    if type(self.fields)~="table" or type(self.vehicles)~="table" or type(self.loose)~="table" then err("inventory","Inventář farmy není kompletně načten") end
    if not FMACatalog or not FMAPlanner or not FMAAI or not FMATraffic then err("core","Chybí některý základní modul Manageru") end
    if self.mapProfile and self.mapProfile.active and self.settings.preferCourseplay then
        if not FMACourseplay or not FMACourseplay.available() then
            err("courseplay","Na Karpatském venkově je pro plnou automatiku požadován aktivní Courseplay")
        elseif not FMATransfer or not FMATransfer.ensureRegistered then
            warn("transfer","Chybí volitelný Courseplay bridge pro přesné lokální nájezdy; běžné přejezdy používají nativní AI FS25")
        else
            local transferOk,transferWhy=FMATransfer.ensureRegistered(self)
            if not transferOk then warn("transfer","Courseplay přesný nájezd není připravený: "..tostring(transferWhy).." · běžné přejezdy používají nativní AI FS25") end
            local cpCandidates,cpReady=0,0
            if FMATransfer.runtimeStatus then
                for _,record in ipairs(self.vehicles or {}) do
                    if record and record.object and (record.isPowerUnit or record.isGrainCombine or record.isForageHarvester) then
                        cpCandidates=cpCandidates+1
                        local status=FMATransfer.runtimeStatus(record.object)
                        if status and status.vehicleReady then cpReady=cpReady+1 end
                    end
                end
            end
            if cpCandidates>0 and cpReady==0 then
                warn("courseplayVehicles","Courseplay je načtený, ale žádný vlastní řiditelný stroj nemá připravené CP runtime rozhraní; polní CP práce budou čekat, běžné přejezdy používají FS25 AI")
            elseif cpCandidates>0 and cpReady<cpCandidates then
                warn("courseplayVehicles",tostring(cpCandidates-cpReady).." z "..tostring(cpCandidates).." řiditelných strojů nemá Courseplay runtime rozhraní; Manager je nebude používat pro CP přejezdy")
            end
        end
    end

    self:reconcileRuntimeState()
    self:buildReadinessAudit()
    if FMAFarmBrain and FMAFarmBrain.dryRun then
        local dry=FMAFarmBrain.dryRun(self)
        for _,w in ipairs(dry.warnings or {}) do warn('brain:'..tostring(#report.warnings+1),w) end
        for _,e in ipairs(dry.errors or {}) do err('brain:'..tostring(#report.errors+1),e) end
    end
    if next(self.subsystemFaults or {})~=nil then
        for name,fault in pairs(self.subsystemFaults) do
            local reportFault=(name=="world.fields" or name=="world.vehicles") and err or warn
            reportFault("subsystem:"..tostring(name),tostring(name)..": "..tostring(fault))
        end
    end

    local pending=0;local serviceable=0;local missing=0;local assembling=0
    for _,task in pairs(self.tasks or {}) do
        if task and task.state=="pending"
                and (not self.settings.selectedJobsOnly or task.ownerApproved==true) then
            pending=pending+1
            local def=FMACatalog and FMACatalog.operations and FMACatalog.operations[task.operation] or nil
            if not def then
                task.state="blocked";task.phase="BLOKACE";task.reason="Neznámá pracovní operace "..tostring(task.operation)
                warn("operation:"..tostring(task.id),task.label.." · "..task.reason)
            else
                local auditRow=self.readinessAudit and self.readinessAudit[task.id] or nil
                if auditRow and auditRow.main=='ASSEMBLE' then assembling=assembling+1 end
                if auditRow and auditRow.state=="SERVICEABLE" then
                    serviceable=serviceable+1
                else
                    local vehicle,why,kind=FMAPlanner.chooseVehicle(task,self.vehicles or {},self.reservations or {},self.excluded or {})
                    if vehicle or kind=="busy" or kind=="configuration" then
                        serviceable=serviceable+1
                    elseif kind=="equipment" then
                        if FMAAssembler and FMAAssembler.hasPotentialForTask and FMAAssembler.hasPotentialForTask(self,task) then
                            serviceable=serviceable+1
                        else
                            missing=missing+1
                            self:equipmentIssue(task.operation,task.label)
                        end
                    else
                        warn("task:"..tostring(task.id),task.label.." · "..tostring((auditRow and auditRow.reason) or why or "nelze předem ověřit"))
                    end
                end
                if task.operation=="harvest" and FMAFleetCoordinator and FMAFleetCoordinator.previewTransport then
                    local auditRow=self.readinessAudit and self.readinessAudit[task.id] or nil
                    -- Do not diagnose/prepare haulage while the combine itself is missing.
                    -- That would tell the owner to fix the wrong half of the harvest chain.
                    if not auditRow or auditRow.main~="MISSING" then
                        local support=FMAFleetCoordinator.previewTransport(self,task,1)
                        if support and support.state=="MISSING" then
                            warn("haulage:"..tostring(task.id),task.label.." · chybí vlastní kompatibilní odvozní souprava")
                        end
                    end
                end
            end
        end
    end
    if #self.vehicles==0 and pending>0 then err("vehicles","Existují pracovní úkoly, ale Manager nevidí žádný vlastní řiditelný stroj") end

    report.pending=pending;report.serviceable=serviceable;report.missingEquipment=missing;report.assembling=assembling
    report.ok=#report.errors==0
    self.preflightReport=report
    return report.ok,report
end

function FMAController:disableAutomation(reason)
    self.settings.enabled=false
    if FMAOwnDriver then FMAOwnDriver.stopAll(self,reason or "Vypnuto majitelem") end
    local jobs={}
    for job,a in pairs(self.active or {}) do if a then a.stopReason=reason or "Pozastaveno majitelem" end;jobs[#jobs+1]=job end
    for _,job in ipairs(jobs) do pcall(FMAAI.stop,job) end
    if FMAFieldQuality then pcall(FMAFieldQuality.cancelAll,self) end
    if FMAAutoRoute then pcall(FMAAutoRoute.stopAll,self) end
    if FMARefillManager then pcall(FMARefillManager.cancelAll,self) end
    if FMAHeaderTransport then pcall(FMAHeaderTransport.cancelAll,self) end
    if FMALivestockCoordinator then pcall(FMALivestockCoordinator.cancelAll,self) end
    if FMABaleStorage and FMABaleStorage.cancelAll then pcall(FMABaleStorage.cancelAll,self) end
    if FMAFleetCoordinator and FMAFleetCoordinator.cancelWaits then pcall(FMAFleetCoordinator.cancelWaits,self) end
    if FMAHaulageCycle then
        for key,session in pairs(self.haulageCycles or {}) do
            self.reservations[key]=nil
            if session.record then session.record.busy=false end
        end
        self.haulageCycles={}
    end
    if FMAFarmBrain and FMAFarmBrain.cancelPreparedNext then pcall(FMAFarmBrain.cancelPreparedNext,self) end
    if FMABunkerCoordinator and FMABunkerCoordinator.cancelAll then pcall(FMABunkerCoordinator.cancelAll,self) end
    -- A stopped helper may never fire a callback on a failed CP transfer.  Do not
    -- keep phantom reservations while AUTO is off: all future starts are gated.
    self.reservations={}
    self.implementReservations={}
    self.playerTakeovers={}
    for _,record in ipairs(self.vehicles or {}) do
        record.busy=false
    end
    if self.traffic then self.traffic=FMATraffic.new() end
    FMALifecycle.update(self)
    self.diagnosticDirty=true
    self.desktopSnapshotDue=(self.now or 0)+500
    self:notify("Automatizace VYPNUTA")
end

function FMAController:enableAutomation()
    if FMADevLab then pcall(FMADevLab.stop,self) end -- Physical lab cannot overlap normal AUTO.
    if not self.supported then return false,"Nepodporovaný režim" end
    if self.runtimePaused then self.runtimePaused=false;self.lastRuntimeError=nil end
    self:refresh()
    local ok,report=self:preflightAutomation()
    if not ok then
        self.settings.enabled=false
        local first=report and report.errors and report.errors[1] or "Předletová kontrola selhala"
        self:notify("AUTO NEZAPNUTO · "..tostring(first))
        return false,first
    end
    self.settings.enabled=true
    self.diagnosticDirty=true
    self.desktopSnapshotDue=(self.now or 0)+500
    local approved=0
    for _,task in pairs(self.tasks or {}) do if task.ownerApproved then approved=approved+1 end end
    if self.settings.selectedJobsOnly then
        self:notify('AUTO PŘIPRAVENO · '..approved..' schválených zakázek · ostatní čekají na výběr majitele')
    else
        self:notify('AUTO ZAPNUTO · '..tostring(report.pending or 0)..' zakázek · '..tostring(report.assembling or 0)..' vyžaduje sestavení soupravy')
    end
    return true,nil
end

function FMAController:toggle()
    if self.settings.enabled then self:disableAutomation("Pozastaveno majitelem") else return self:enableAutomation() end
end

function FMAController:refresh()
    self.runtimePaused=false
    self.lastRuntimeError=nil
    self.jobFailures={}
    self.subsystemHealth={}
    self.issues["runtime"]=nil
    if FMABunkerCoordinator and FMABunkerCoordinator.resetFailures then FMABunkerCoordinator.resetFailures(self) end
    if FMAAI and FMAAI.sanitizeVehicleJobHistory then safeSubsystem(self,"aiJobHistory",FMAAI.sanitizeVehicleJobHistory,self) end
    for _,task in pairs(self.tasks) do
        if task.state~="running" and task.state~="assembling" and task.state~="returning" and task.state~="preparing" and task.state~="waiting" then task.state="pending";task.retryAt=0;task.attempts=0;task.failures=0 end
    end
    self:scan()
end

function FMAController:update(dt)
    if not g_currentMission or not g_currentMission.isRunning then return end
    self.now=self.now+dt
    -- Critical wheel watchdog must not wait for the 1-second scheduler:
    -- at 20 km/h a tractor may travel over five metres between checks.
    if self.initialized and self.settings and self.settings.enabled and FMABunkerCoordinator then
        local safe,err=pcall(FMABunkerCoordinator.enforceSafety,self)
        if not safe then
            self.settings.enabled=false;self.runtimePaused=true
            self.lastRuntimeError='Bezpečnostní kontrola siláže: '..tostring(err)
            pcall(function()
                for job,a in pairs(self.active or {}) do
                    if a.task and a.task.kind=='bunker' then
                        a.stopReason='BEZPEČNOST: selhání kontroly prostoru';FMAAI.stop(job)
                    end
                end
            end)
            FMADiagnostics.error(self,'bunker.enforceSafety',self.lastRuntimeError)
        end
    end
    -- Live read-only status works while AUTO is off and without Alt+D.
    self.liveTelemetryElapsed=(self.liveTelemetryElapsed or 0)+dt
    if FMABlackBox and FMABlackBox.sample and self.initialized then
        -- Recorder failures may never stop the cooperative. All output is read-only.
        local ok,err=pcall(FMABlackBox.sample,self)
        if not ok then self.recorderError=tostring(err) end
    end
    if self.initialized and self.liveTelemetryElapsed>=5000 then
        self.liveTelemetryElapsed=0
        if FMALiveTelemetry and FMALiveTelemetry.write then
            local ok,err=pcall(FMALiveTelemetry.write,self)
            if not ok then self.liveTelemetryLastError=tostring(err) end
        end
    end
    if not self.initialized then if self.now>2500 then self:initialize() end;return end
    if not self.supported then return end
    if FMAOwnDriver then
        local driveOk,driveWhy=pcall(FMAOwnDriver.update,self,dt)
        if not driveOk then
            -- A wheel-control failure must NEVER leave an autonomous tractor
            -- uncontrollably driving: stop every session and freeze dispatch.
            self.settings.enabled=false
            self.runtimePaused=true
            self.lastRuntimeError='Vlastní fyzický řidič: '..tostring(driveWhy)
            pcall(FMAOwnDriver.stopAll,self,self.lastRuntimeError)
            FMADiagnostics.error(self,'ownDriver.update',self.lastRuntimeError)
        end
    end
    self.reportElapsed=(self.reportElapsed or 0)+dt
    if self.desktopSnapshotDue and self.now>=self.desktopSnapshotDue then
        self.desktopSnapshotDue=nil
        pcall(self.diagnostics,self,true)
        self.reportElapsed=0
    elseif self.settings.enabled and self.diagnosticDirty and self.reportElapsed>=30000 then
        pcall(self.diagnostics,self,true)
        self.reportElapsed=0
    end
    self.elapsed=self.elapsed+dt
    self.workerElapsed=(self.workerElapsed or 0)+dt
    local managedLoad=FMAUtil.count(self.active or {})+FMAUtil.count(self.reservations or {})
    local budgetFactor=1
    if self.settings.performanceBudget~=false then
        if managedLoad>=15 then budgetFactor=2.5 elseif managedLoad>=9 then budgetFactor=1.6 end
    end
    self.performanceBudgetState={managedLoad=managedLoad,factor=budgetFactor,scanSeconds=(self.settings.scanSeconds or 12)*budgetFactor}
    if self.elapsed>=(self.settings.scanSeconds*1000*budgetFactor) then self.elapsed=0;self:scan() end
    if self.workerElapsed>=1000 then
        self.workerElapsed=0
        if FMAWorldRegistry and FMAWorldRegistry.update then safeSubsystem(self,"world.registry.live",FMAWorldRegistry.update,self,false) end
        safeSubsystem(self,"lifecycle",FMALifecycle.update,self)
        self:drainStoppedJobs()
        if FMAPathRunner and FMAPathRunner.update then safeSubsystem(self,'route.pendingLegs',FMAPathRunner.update,self) end
        if FMAControlAuthority and FMAControlAuthority.audit then
            safeSubsystem(self,'control.authority',FMAControlAuthority.audit,self)
        end
        if FMACourseplay.update then safeSubsystem(self,"courseplay.update",FMACourseplay.update,self) end
        if FMACourseplay.syncManagedHarvestSettings then safeSubsystem(self,"courseplay.settings",FMACourseplay.syncManagedHarvestSettings,self) end
        if FMACourseplay.adoptExistingFieldwork then safeSubsystem(self,"courseplay.adopt",FMACourseplay.adoptExistingFieldwork,self) end
        if FMACourseplay.confirmPendingFieldwork then safeSubsystem(self,"courseplay.publicStart",FMACourseplay.confirmPendingFieldwork,self) end
        if FMAJobs.verifyAuxiliaryStarts then safeSubsystem(self,'jobs.startVerification',FMAJobs.verifyAuxiliaryStarts,self) end
        -- Courseplay loads in its own mod environment and its private pathfinder classes may
        -- become visible a little later than our loadMap callback. Retry the registration
        -- handshake until it succeeds instead of leaving transport disabled for the session.
        self.transferRegistrationElapsed=(self.transferRegistrationElapsed or 0)+1000
        if self.transferRegistrationElapsed>=5000 and FMATransfer and FMATransfer.ensureRegistered
            and FMACourseplay and FMACourseplay.available and FMACourseplay.available() then
            self.transferRegistrationElapsed=0
            local manager=g_currentMission and g_currentMission.aiJobTypeManager
            local index=manager and FMAUtil.call(manager,"getJobTypeIndexByName","FMA_TRANSFER_CP")
            if index==nil or self.lastTransferRegistrationError~=nil then
                local registered,why=FMATransfer.ensureRegistered(self)
                if registered then
                    self.issues["transferJob"]=nil
                    if not self.transferRegistrationReadyLogged then
                        self.transferRegistrationReadyLogged=true
                        FMADiagnostics.event(self,"transfer.registered","FMA_TRANSFER_CP",tostring(self.transferJobType or index or "?"))
                    end
                else
                    self:issue("transferJob","Courseplay přejezd čeká na inicializaci",tostring(why),92)
                end
            end
        end
        if FMAFieldQuality.update then safeSubsystem(self,"course.update",FMAFieldQuality.update,self) end
        if FMAAssembler.update then safeSubsystem(self,"assembly.update",FMAAssembler.update,self) end
        if FMAReturnManager and FMAReturnManager.update then safeSubsystem(self,'handover.update',FMAReturnManager.update,self) end
        if FMAParkingManager and FMAParkingManager.update then safeSubsystem(self,'parking.dispatch',FMAParkingManager.update,self) end
        if FMATeach and FMATeach.update then safeSubsystem(self,"teach.update",FMATeach.update,self) end
        if FMAFarmSurvey and FMAFarmSurvey.update then safeSubsystem(self,"farm.survey.live",FMAFarmSurvey.update,self) end
        if FMANavigation and FMANavigation.sample then for _,active in pairs(self.active or {}) do safeSubsystem(self,"navigation.sample",FMANavigation.sample,self,active) end end
        if FMAWorkEvidence then
            for _,active in pairs(self.active or {}) do
                if active.task and active.task.kind=='field' and active.task.fieldworkStartedAt then
                    safeSubsystem(self,'physical.workEvidence',FMAWorkEvidence.sample,self,active.task,active.vehicle)
                end
            end
            for key,session in pairs(self.externalFieldwork or {}) do
                local record=self.vehicleByKey and self.vehicleByKey[key]
                local task=self.tasks and self.tasks[session.taskId]
                if record and task and task.fieldworkStartedAt then
                    safeSubsystem(self,'physical.adoptedEvidence',FMAWorkEvidence.sample,self,task,record)
                end
            end
        end
        if FMARecovery and FMARecovery.update then safeSubsystem(self,"recovery.update",FMARecovery.update,self) end
        self.brainElapsed=(self.brainElapsed or 0)+1000
        local brainBudget=(self.performanceBudgetState and self.performanceBudgetState.factor or 1)
        if FMAFarmBrain and FMAFarmBrain.update and self.brainElapsed>=(self.settings.brainSeconds or 5)*1000*brainBudget then self.brainElapsed=0;safeSubsystem(self,"brain.update",FMAFarmBrain.update,self) end
        if self.settings.playerPriority and FMATraffic and FMATraffic.playerTakeover then safeSubsystem(self,"traffic.player",FMATraffic.playerTakeover,self) end
        if FMALifecycle.resumeReleasedOrders then safeSubsystem(self,'lifecycle.resumeOwner',FMALifecycle.resumeReleasedOrders,self) end
        if FMATraffic and FMATraffic.clean then safeSubsystem(self,"traffic.clean",FMATraffic.clean,self.traffic,self.now) end
        if self.settings.trafficSafety and FMATraffic and FMATraffic.update then safeSubsystem(self,"traffic.update",FMATraffic.update,self) end
        if FMAFleetCoordinator and FMAFleetCoordinator.sample then safeSubsystem(self,"fleet.sample",FMAFleetCoordinator.sample,self) end
        if FMAHaulageCycle and FMAHaulageCycle.monitor then safeSubsystem(self,"haulage.monitor",FMAHaulageCycle.monitor,self) end
        if FMAHaulageCycle and FMAHaulageCycle.update then safeSubsystem(self,"haulage.cycle",FMAHaulageCycle.update,self) end
        if FMAFleetCoordinator and FMAFleetCoordinator.updateSupport then safeSubsystem(self,"fleet.supportUpdate",FMAFleetCoordinator.updateSupport,self) end
        if FMAFleetCoordinator and FMAFleetCoordinator.planHarvestTeams then safeSubsystem(self,"fleet.harvestTeams",FMAFleetCoordinator.planHarvestTeams,self) end
        if FMAEnterprise and FMAEnterprise.update then safeSubsystem(self,"enterprise.update",FMAEnterprise.update,self) end
        safeSubsystem(self,"watchdog",self.watchdog,self)
        if FMAAutoRoute and FMAAutoRoute.update then safeSubsystem(self,"autoroute.update",FMAAutoRoute.update,self) end
        if FMARefillManager and FMARefillManager.update then safeSubsystem(self,"refill.update",FMARefillManager.update,self) end
        if FMAHeaderTransport and FMAHeaderTransport.update then safeSubsystem(self,"header.update",FMAHeaderTransport.update,self) end
        if FMABaleStorage and FMABaleStorage.update then safeSubsystem(self,"baleStorage.update",FMABaleStorage.update,self) end
        if FMALivestockCoordinator and FMALivestockCoordinator.update then safeSubsystem(self,"livestock.update",FMALivestockCoordinator.update,self) end
        if FMABunkerCoordinator and FMABunkerCoordinator.update then safeSubsystem(self,"bunker.update",FMABunkerCoordinator.update,self) end
        if self.settings.enabled and self.inventorySafe~=false then
        if self.settings.selectedJobsOnly~=true then
            if FMAFarmBrain and FMAFarmBrain.planProactiveCrews then safeSubsystem(self,"brain.crews",FMAFarmBrain.planProactiveCrews,self) end
            if FMAServiceManager and FMAServiceManager.dispatch then safeSubsystem(self,"service.dispatch",FMAServiceManager.dispatch,self) end
            if FMAFleetCoordinator and FMAFleetCoordinator.dispatchSupport then safeSubsystem(self,"fleet.support",FMAFleetCoordinator.dispatchSupport,self) end
            if self.settings.bunkerAutomation and FMABunkerCoordinator and FMABunkerCoordinator.dispatch then safeSubsystem(self,"bunker.dispatch",FMABunkerCoordinator.dispatch,self) end
            if self.settings.baleAutomation and FMABaleCoordinator and FMABaleCoordinator.dispatch then safeSubsystem(self,"bales.dispatch",FMABaleCoordinator.dispatch,self) end
        else
            -- A selected bunker work order is a real owner-approved job. Other
            -- unattended silo work remains disabled in selected-only mode.
            if self.settings.bunkerAutomation and FMABunkerCoordinator and FMABunkerCoordinator.dispatch then safeSubsystem(self,"bunker.dispatch",FMABunkerCoordinator.dispatch,self) end
            if FMAFleetCoordinator and FMAFleetCoordinator.dispatchSupport then safeSubsystem(self,"fleet.support",FMAFleetCoordinator.dispatchSupport,self) end
        end
        safeSubsystem(self,"dispatch",self.dispatch,self)
        end
    end
end

function FMAController:diagnostics(quiet)
    local info=g_currentMission and g_currentMission.missionInfo or {}
    -- Build the whole report in memory first and export it outside the savegame.
    -- The Manager never opens a diagnostic file inside savegameN, so a diagnostic
    -- snapshot cannot contend with Farming Simulator's own save transaction.
    local chunks={}
    local f={write=function(_,...) local values={...};for i=1,#values do chunks[#chunks+1]=tostring(values[i]) end end}
    f:write("FarmManagerAI 0.20.48 FARM BRAIN COOPERATIVE CORE\nMap: ",tostring(info.mapTitle),"\nFarm: ",tostring(self.farmId),"\n")
    f:write("BUILD 0.20.48.0 | session-ms=",tostring(self.now),"\n")
    local currentInputContext=FMAUtil.call(g_inputBinding,"getContextName")
    f:write("INPUT_STATE ready=",tostring(self.inputReady or false)," contextActive=",tostring(self.uiContextActive or false)," visible=",tostring(self.visible or false),
        " registeredContexts=",table.concat(self.globalInputContexts or {},",")," currentContext=",tostring(currentInputContext or "nil"),
        " rebinds=",tostring(self.globalRebindCount or 0)," events=",tostring(self.inputEventCount or 0),
        " lastEvent=",tostring(self.lastInputEvent or "none")," lastEventAt=",tostring(self.lastInputEventAt or 0),
        " lastError=",tostring(self.lastInputError or "none"),"\n")
    f:write("SAFE_ESC noNativeTab=",tostring(not (g_inGameMenu and g_inGameMenu.fmaManagerPage~=nil)),
        " error=",tostring(self.nativeMenuReason or "none"),
        " controllerRef=",tostring(_G.g_FMAControllerForMenu==self),"\n")
    if FMANavigation and FMANavigation.writeDiagnostics then FMANavigation.writeDiagnostics(self,f) end
    if FMAParkingManager and FMAParkingManager.writeDiagnostics then FMAParkingManager.writeDiagnostics(self,f) end
    local transferIndex=g_currentMission and g_currentMission.aiJobTypeManager and FMAUtil.call(g_currentMission.aiJobTypeManager,"getJobTypeIndexByName","FMA_TRANSFER_CP")
    local transferStatus=FMATransfer and FMATransfer.runtimeStatus and FMATransfer.runtimeStatus() or {}
    f:write("TRANSFER_CORE cpAvailable=",tostring(FMACourseplay and FMACourseplay.available and FMACourseplay.available() or false),
        " cpMod=",tostring(transferStatus.modName or "-")," cpEnv=",tostring(transferStatus.environment or false)," classes=",tostring(transferStatus.classes or false),
        " registered=",tostring(transferIndex~=nil)," typeIndex=",tostring(transferIndex or "-"),
        " initError=",tostring(self.lastTransferRegistrationError or transferStatus.error or "none"),
        " fallback=",tostring(self.lastTransferFallbackReason or "none"),"\n")
    f:write('CONTROL_AUTHORITY conflicts=',tostring(self.controlAuthorityConflicts or 0),'\n')
    f:write('OWN_DRIVER active=',tostring(FMAUtil.count(self.ownDriveSessions or {})),'\n')
    for key,s in pairs(self.ownDriveSessions or {}) do
        f:write('OWN_DRIVER_VEHICLE ',tostring(key),' kind=',tostring(s.kind),
            ' target=',tostring(s.goal and s.goal.x),',',tostring(s.goal and s.goal.z),
            ' reverse=',tostring(s.reverse),' travelled=',tostring(s.travelled),
            ' passes=',tostring(s.passes),'\n')
    end
    local pr=self.preflightReport or {}
    f:write("LIVE_TELEMETRY file=FS25_FarmManagerAI_LIVE.txt lastOk=",tostring(FMALiveTelemetry and FMALiveTelemetry.lastOk)," lastError=",tostring(self.liveTelemetryLastError or "-"),"\n")
    f:write("AUTO_PREFLIGHT ok=",tostring(pr.ok)," pending=",tostring(pr.pending or 0)," errors=",tostring(#(pr.errors or {}))," warnings=",tostring(#(pr.warnings or {})),"\n")
    local issueCounts=self:issueCounts()
    f:write("ISSUE_SUMMARY errors=",tostring(issueCounts.error)," actions=",tostring(issueCounts.action)," warnings=",tostring(issueCounts.warning)," info=",tostring(issueCounts.info)," total=",tostring(issueCounts.total),"\n")
    if FMAJobBrief and FMAJobBrief.summary then
        local b=FMAJobBrief.summary(self)
        f:write('ORDER_BOARD jobs=',tostring(b.jobs),' approved=',tostring(b.started),' stopped=',tostring(b.stopped),' blocked=',tostring(b.blockers),'\n')
        for _,task in pairs(self.tasks or {}) do
            f:write('ORDER_BRIEF ',tostring(task.id),' status=',tostring(task.state),' reason=',tostring(FMAJobBrief.reason(self,task)),'\n')
        end
    end
    for _,e in ipairs(pr.errors or {}) do f:write("PREFLIGHT_ERROR ",tostring(e),"\n") end
    for _,e in ipairs(pr.warnings or {}) do f:write("PREFLIGHT_WARNING ",tostring(e),"\n") end
    for name,h in pairs(self.subsystemHealth or {}) do
        if h.failures>0 then f:write("SUBSYSTEM_RETRY ",name," failures=",tostring(h.failures)," retryAt=",tostring(h.disabledUntil),"\n") end
    end
    local mp=self.mapProfile or {}
    f:write("CARPATHIAN active=",tostring(mp.active)," loaded=",tostring(mp.loaded)," mapId=",tostring(mp.mapId)," version=",tostring(mp.version)," mapXML=",tostring(mp.mapXMLFilename),"\n")
    f:write("CARPATHIAN SNAPSHOT ownedPlaceables=",tostring(mp.ownedPlaceables or 0)," husbandries=",tostring(#(mp.husbandries or {}))," bunkers=",tostring(#(mp.bunkers or {}))," storages=",tostring(#(mp.storages or {}))," productions=",tostring(#(mp.productions or {}))," aiLoad=",tostring(mp.aiLoadingStations or 0)," aiUnload=",tostring(mp.aiUnloadingStations or 0),"\n")
    f:write("CARPATHIAN PLACEABLES\n")
    for _,kind in ipairs({"husbandries","bunkers","storages","productions"}) do
        for _,row in ipairs(mp[kind] or {}) do local x,z=FMAUtil.position(row.object);f:write(kind," | ",row.name or FMAUtil.name(row.object)," | x=",tostring(x)," z=",tostring(z),"\n") end
    end
    local function writeStations(label,rows)
        f:write(label,"\n")
        for _,row in ipairs(rows or {}) do
            local names={};for _,ft in ipairs(row.fillTypes or {}) do names[#names+1]=FMAWorld.fillName(ft) end
            f:write(row.name," | owner=",tostring(row.owner)," | x=",tostring(row.x)," z=",tostring(row.z)," | AI=",tostring(row.ai)," | fills=",table.concat(names,","),"\n")
        end
    end
    writeStations("CARPATHIAN LOADING STATIONS",mp.loadingStations)
    writeStations("CARPATHIAN UNLOADING STATIONS",mp.unloadingStations)
    f:write("CARPATHIAN STORAGE INVENTORY\n")
    for _,row in ipairs(mp.storages or {}) do
        f:write(row.name or FMAUtil.name(row.object)," known=",tostring(row.inventoryKnown)," source=",tostring(row.inventorySource or "none"),"\n")
        for _,fill in ipairs(row.fillRows or {}) do f:write("  ",FMAWorld.fillName(fill.fillType)," level=",tostring(fill.level)," capacity=",tostring(fill.capacity)," source=",tostring(fill.source),"\n") end
    end
    f:write("CARPATHIAN SPRAY/FERTILIZER TYPES\n")
    for _,row in ipairs(mp.sprayFillTypes or {}) do f:write(row.name," fertilizer=",tostring(row.fertilizer)," lime=",tostring(row.lime),"\n") end
    f:write("RUNTIME_PAUSED ",tostring(self.runtimePaused),"\nLAST_RUNTIME_ERROR ",tostring(self.lastRuntimeError or "none"),"\n")
    f:write("SUBSYSTEM FAULTS\n")
    for name,err in pairs(self.subsystemFaults or {}) do f:write(name," | ",tostring(err),"\n") end
    f:write("Livestock & silage build: dynamic AnimalFoodSystem rations, physical mixer loading, straw/water/output forecasting, organic nutrient retention, bunker access arbitration and manual-cover handoff; runtime/map integration requires in-game test.\n")
    f:write("FIELDS ",#self.fields," VEHICLES ",#self.vehicles," LOOSE_IMPLEMENT_ROOTS ",#(self.loose or {})," SANITIZED_JOB_HISTORY ",tostring(self.sanitizedJobHistory or 0),"\n")
    f:write("CP FIELDWORK ELIGIBILITY - directly from FS25/Courseplay\n")
    for _,record in ipairs(self.vehicles or {}) do
        if record.isGrainCombine or record.isForageHarvester then
            local v=record.object
            local can=FMAUtil.call(v,'getCanStartCpFieldWork')
            local cp=FMAUtil.call(v,'getCpSettings')
            local autoCutter=cp and cp.automaticCutterAttach and FMAUtil.call(cp.automaticCutterAttach,'getValue')
            f:write(record.name,' key=',record.key,' cpFieldWork=',tostring(can),' workingCutter=',tostring(record.hasCutter==true and not record.headerTransportPending),
                ' carrierWorkflow=',tostring(record.headerOnCarrier==true),' automaticCutterAttach=',tostring(autoCutter),
                ' cpCourse=',tostring(FMAUtil.call(v,'hasCpCourse')),' isAIActive=',tostring(FMAUtil.call(v,'getIsAIActive')),'\n')
        end
    end
    for _,field in ipairs(self.fields) do
        f:write(field.id," valid=",tostring(field.valid)," state=",tostring(field.stateLabel)," samples=",tostring(field.sampleCount),
            " ready=",tostring(field.ready)," bare=",tostring(field.bare)," alive=",tostring(field.alive)," prepared=",tostring(field.prepared),
            " coverageReady=",tostring(field.readyCoverage)," coverageBare=",tostring(field.bareCoverage)," coverageAlive=",tostring(field.aliveCoverage)," coveragePrepared=",tostring(field.preparedCoverage),
            " primaryGround=",tostring(field.groundTypeName)," primaryGrowth=",tostring(field.primaryGrowthState)," primaryPrepared=",tostring(field.primaryPrepared),
            " spray=",tostring(field.minSpray),"/",tostring(field.maxSprayObserved)," lime=",tostring(field.minLime),
            " plow=",tostring(field.minPlow)," fp=",tostring(field.fingerprint)," next=",tostring(field.reason),"\n")
    end
    for _,v in ipairs(self.vehicles) do
        local caps={};for name,value in pairs(v.capabilities) do if value then caps[#caps+1]=name end end;table.sort(caps)
        f:write(v.name," type=",tostring(v.isForageHarvester and "forageHarvester" or v.isGrainCombine and "grainCombine" or v.isPowerUnit and "powerUnit" or "selfPropelled")," class=",tostring(v.machineClass or "unknown"),
            " classSource=",tostring(v.machineClassSource or "unknown")," storeCategory=",tostring(v.storeCategory or "-")," storeSource=",tostring(v.storeSource or "-"),
            " key=",tostring(v.key)," caps=",table.concat(caps,",")," busy=",tostring(v.busy),
            " damage=",tostring(v.damage)," wear=",tostring(v.wear)," fuel=",tostring(v.fuelRatio),
            " powerKW=",tostring(v.powerKW)," powerHP=",tostring(v.powerHP)," mass=",tostring(v.mass)," requiredPowerKW=",tostring(v.requiredPowerKW),
            " ballast=",tostring(v.hasBallast==true)," frontBlade=",tostring(v.hasFrontBlade==true)," headerOnCarrier=",tostring(v.headerOnCarrier==true),
            " autoload=",tostring(#v.compatibility.autoloaders),"\n")
    end
    -- Permanent attachment-tree dump. This exposes live tractor->trailer->trailer
    -- and combine->header-carrier chains instead of forcing diagnosis from flat inventory.
    f:write("ATTACHMENT TREES\n")
    local function writeAttachmentTree(object,prefix,seen)
        if not object or seen[object] then return end
        seen[object]=true
        local normal={}
        for _,entry in pairs(FMAUtil.call(object,"getAttachedImplements") or {}) do if entry.object then normal[entry.object]=true end end
        for _,child in ipairs(FMAWorld.directChildren(object)) do
            local flags={}
            if child.spec_trailer then flags[#flags+1]="trailer" end
            if child.spec_dischargeable then flags[#flags+1]="dischargeable" end
            if child.spec_cutter then flags[#flags+1]="cutter" end
            if child.spec_dynamicMountAttacher or child.spec_tensionBelts then flags[#flags+1]="carrier" end
            if not normal[child] then flags[#flags+1]="dynamicMount" end
            f:write(prefix,normal[child] and "-> " or "=> ",FMAUtil.name(child)," key=",FMAWorld.vehicleKey(child)," [",table.concat(flags,","),"]\n")
            writeAttachmentTree(child,prefix.."  ",seen)
        end
    end
    for _,v in ipairs(self.vehicles or {}) do
        f:write("ROOT ",v.name," key=",v.key,"\n")
        writeAttachmentTree(v.object,"  ",{})
    end
    f:write("LOOSE IMPLEMENTS\n")
    for _,tool in ipairs(self.loose or {}) do
        local caps={};for name,value in pairs(tool.capabilities or {}) do if value then caps[#caps+1]=name end end;table.sort(caps)
        f:write(tool.name," key=",tool.key," storeCategory=",tostring(tool.storeCategory or "-")," storeSource=",tostring(tool.storeSource or "-")," caps=",table.concat(caps,",")," reserved=",tostring(self.implementReservations[tool.key]~=nil),
            " transported=",tostring(tool.transported or false)," mountedOn=",tostring(tool.mountedCarrier and FMAUtil.name(tool.mountedCarrier) or "-"),
            " mass=",tostring(tool.mass)," requiredPowerKW=",tostring(tool.requiredPowerKW)," width=",tostring(tool.workWidth),"\n")
    end
    f:write("LOADED MODS\n")
    local mods={};for name,loaded in pairs(g_modIsLoaded or {}) do if loaded then mods[#mods+1]=name end end;table.sort(mods)
    for _,name in ipairs(mods) do f:write(name,"\n") end
    f:write("WORKFLOW SESSIONS\n")
    for id,s in pairs(self.refillSessions or {}) do f:write("refill ",id," ",FMAWorld.fillName(s.requirement.fillType),"\n") end
    for id,w in pairs(self.headerWaits or {}) do f:write("headerWait ",id," carrier=",tostring(w.plan.carrier and w.plan.carrier.name),"\n") end
    f:write("FIELD QUALITY / FORAGE\n")
    for id,stage in pairs(self.forageStages or {}) do f:write("forage field ",id," stage=",stage,"\n") end
    for id,_ in pairs(self.windrowCourses or {}) do f:write("windrowCourse field ",id," remembered=true\n") end
    for fieldId,row in pairs(self.baleFields or {}) do
        local types={};for ft,count in pairs(row.fillTypes or {}) do types[#types+1]=FMAWorld.fillName(ft)..":"..tostring(count) end;table.sort(types)
        f:write("baleField ",tostring(fieldId)," count=",tostring(row.count)," types=",table.concat(types,","),"\n")
    end
    for _,s in ipairs(self.baleStorages or {}) do
        local types={};for ft,count in pairs(s.storedFillTypes or {}) do types[#types+1]=FMAWorld.fillName(ft)..":"..tostring(count) end;table.sort(types)
        f:write("baleStorage ",s.name," free=",tostring(s.free)," capacity=",tostring(s.capacity)," storedTypes=",table.concat(types,","),"\n")
    end
    f:write("LIVESTOCK / SILAGE\n")
    for _,condition in ipairs(self.animalConditions or {}) do
        f:write("condition ",tostring(condition.name)," ratio=",tostring(condition.ratio)," value=",tostring(condition.value)," capacity=",tostring(condition.capacity)," source=",tostring(condition.source or "unknown")," message=",tostring(condition.message),"\n")
    end
    for place,plan in pairs(self.livestockPlans or {}) do
        f:write("husbandry ",FMAUtil.name(place)," foodRatio=",tostring(plan.ratio)," needed=",tostring(plan.needed)," hours=",tostring(plan.hoursRemaining)," mixture=",tostring(plan.mixturePlan and FMAWorld.fillName(plan.mixturePlan.fillType) or "direct"),"\n")
        if plan.mixturePlan then for _,ing in ipairs(plan.mixturePlan.ingredients or {}) do f:write("  ingredient ",tostring(ing.weight)," ",ing.fillType and FMAWorld.fillName(ing.fillType) or "MISSING"," available=",tostring(ing.available),"\n") end end
    end
    for i,b in ipairs(self.bunkers or {}) do
        local ws=self.bunkerWorkState and self.bunkerWorkState[i] or {}
        f:write("bunker ",i," role=",tostring(FMABunkerCoordinator and FMABunkerCoordinator.role(self,i) or "?"),
            " fill=",tostring(b.fillLevel)," capacityEstimate=",tostring(b.capacityEstimate)," fillRatio=",tostring(b.fillRatio or (FMABunkerCoordinator and FMABunkerCoordinator.fillRatio(self,b))),
            " compact=",tostring(b.compactedPercent)," canClose=",tostring(b.canClose)," deliveryMode=",tostring(b.deliveryMode or "AUTO"),
            " phase=",tostring(ws.phase or "IDLE")," intakeClosed=",tostring(ws.intakeClosed or false)," activeDelivery=",tostring(ws.activeDeliveryKey or "none"),
            " failures=",tostring(ws.failures or 0)," blocked=",tostring(ws.blocked or false)," retryAt=",tostring(ws.retryAt or 0)," lastError=",tostring(ws.lastError or ""),"\n")
    end
    f:write("READINESS AUDIT\n")
    for id,row in pairs(self.readinessAudit or {}) do
        f:write(tostring(id)," state=",tostring(row.state)," main=",tostring(row.main or "-")," vehicle=",tostring(row.vehicle or "-")," tool=",tostring(row.tool or "-"),
            " support=",tostring(row.support or "-")," supportVehicle=",tostring(row.supportVehicle or "-")," supportTool=",tostring(row.supportTool or "-"),
            " reason=",tostring(row.reason or row.supportReason or ""),"\n")
    end
    f:write("WORKGROUPS\n")
    for id,g in pairs(self.workgroups or {}) do f:write(id," requiredUnloaders=",tostring(g.required)," assigned=",tostring(#g.unloaders)," state=",tostring(g.state),"\n") end
    f:write("PREPARED HARVEST CREWS\n")
    for taskId,roles in pairs(self.preparedSupport or {}) do
        for slot,role in pairs(roles) do f:write(taskId," slot=",tostring(slot)," state=",tostring(role.state)," vehicle=",tostring(role.record and role.record.name or "-")," tool=",tostring(role.tool and role.tool.name or "-")," reason=",tostring(role.reason or ""),"\n") end
    end
    f:write("TRAFFIC CORE zones=",tostring(FMAUtil.count(self.traffic and self.traffic.zones or {}))," blockedStarts=",tostring(self.traffic and self.traffic.blockedStarts or 0)," yields=",tostring(self.traffic and self.traffic.yieldCount or 0)," peakTransit=",tostring(self.traffic and self.traffic.peakTransit or 0)," maxTransit=",tostring(self.settings.trafficMaxTransit)," launchInterval=",tostring(self.settings.trafficLaunchIntervalSeconds),"\n")
    for zone,data in pairs(self.traffic and self.traffic.zones or {}) do f:write("traffic ",zone," vehicle=",tostring(data.vehicleKey)," role=",tostring(data.role)," expires=",tostring(data.expires),"\n") end
    f:write("TASKS\n")
    for _,task in ipairs(FMAPlanner.queue(self.tasks)) do
        f:write(task.id," ",task.state," ",tostring(task.reason),
            " main=",tostring(task.preferredVehicleName or "AUTO"),
            " implement=",tostring(task.preferredImplementName or "AUTO"),
            " carrier=",tostring(task.preferredCarrierName or "AUTO")," phase=",tostring(task.phase or "-"),"\n")
        for i=1,(self.settings.maxUnloaders or 3) do
            local pn=task.preferredSupportNames and task.preferredSupportNames[i] or "AUTO"
            local tn=task.preferredSupportToolNames and task.preferredSupportToolNames[i] or "AUTO"
            if pn~="AUTO" or tn~="AUTO" then f:write("  haulage ",i," power=",pn," trailer=",tn,"\n") end
        end
    end
    f:write("OWNER TASKS AND SHOP CANDIDATES\n")
    for _,issue in pairs(self.issues) do f:write("[",tostring(issue.kind or "warning"),"] ",issue.title," | ",issue.detail,"\n") end
    f:write("HISTORY\n")
    for _,entry in ipairs(self.history) do f:write(tostring(math.floor(entry.time/1000))," ",entry.text,"\n") end
    if FMAEnterprise and FMAEnterprise.writeDiagnostics then FMAEnterprise.writeDiagnostics(self,f) end
    if FMAWorldRegistry and FMAWorldRegistry.writeDiagnostics then FMAWorldRegistry.writeDiagnostics(self,f) end
    if FMAFarmBrain and FMAFarmBrain.writeDiagnostics then FMAFarmBrain.writeDiagnostics(self,f) end
    if FMAWorldAtlas and FMAWorldAtlas.writeDiagnostics then FMAWorldAtlas.writeDiagnostics(self,f) end
    if FMAServiceManager and FMAServiceManager.writeDiagnostics then FMAServiceManager.writeDiagnostics(self,f) end
    if FMARecovery and FMARecovery.writeDiagnostics then FMARecovery.writeDiagnostics(self,f) end
    if FMAExperience and FMAExperience.writeDiagnostics then FMAExperience.writeDiagnostics(self,f) end
    if FMATeach and FMATeach.writeDiagnostics then FMATeach.writeDiagnostics(self,f) end
    if FMAFarmSurvey and FMAFarmSurvey.writeDiagnostics then FMAFarmSurvey.writeDiagnostics(self,f) end
    if self.performanceBudgetState then f:write('\nPERFORMANCE BUDGET\nmanagedLoad=',tostring(self.performanceBudgetState.managedLoad),' factor=',tostring(self.performanceBudgetState.factor),' scanSeconds=',tostring(self.performanceBudgetState.scanSeconds),'\n') end
    FMADiagnostics.write(self,f)
    local text=table.concat(chunks)
    self.lastDiagnosticText=text
    local export=nil
    if FMAOpsLog and FMAOpsLog.exportSnapshot then
        local ok,result=pcall(FMAOpsLog.exportSnapshot,text)
        if ok then export=result else FMAUtil.log("Export diagnostiky/logu selhal: "..tostring(result)) end
    end
    -- The regular small snapshots are still maintained for live troubleshooting.
    -- Alt+D additionally creates ONE complete in-memory support file: no reading
    -- arbitrary FS25 files and no touching savegame data.
    local support=nil
    if not quiet and FMASupportReport and FMASupportReport.export then
        local good,result=pcall(FMASupportReport.export,self,text)
        if good then support=result else support={ok=false,reason=tostring(result)} end
    end
    self.diagnosticDirty=false
    if not quiet then
        if support and support.ok then
            self:notify("Alt+D · Jeden soubor pro opravy: "..FMASupportReport.FILE.." · "..tostring(FMAOpsLog.locationLabel()))
        else
            self:notify("Report se nepodařilo uložit · "..tostring(support and support.reason or "Modul reportu nedostupný"))
        end
    end
    local result=export or {diagnosticOk=false,logOk=false}
    result.supportReport=support
    return result
end

-- Process stop notifications on the next manager tick. FS25 may emit a stop
-- synchronously during startJob; immediate follow-up starts are reentrant.
function FMAController:onJobStopped(job,message)
    self.stoppedJobs=self.stoppedJobs or {}
    local entry=self.stoppedJobs[job]
    if not entry or (entry.message==nil and message~=nil) then self.stoppedJobs[job]={message=message} end
end

function FMAController:drainStoppedJobs()
    local stopped=self.stoppedJobs or {};self.stoppedJobs={}
    for job,entry in pairs(stopped) do
        if self.active[job] then
            local active=self.active[job]
            local ok=safeSubsystem(self,"job.finish",self.handleJobStopped,self,job,entry.message)
            if not ok then
                self.active[job]=nil
                local key=active.vehicle.key
                local lease=self.reservations[key]
                if active.task and (lease==active.task.id or lease==active.task) then
                    self.reservations[key]=nil
                end
                local successor=(self.ownDriveSessions and self.ownDriveSessions[key])~=nil or self.reservations[key]~=nil
                for laterJob,later in pairs(self.active or {}) do
                    if laterJob~=job and later and later.vehicle and later.vehicle.key==key then successor=true;break end
                end
                if not successor then
                    active.vehicle.busy=false
                    if self.traffic then FMATraffic.release(self.traffic,key) end
                end
                local parent=active.task.parentTask or self.tasks[active.task.parentTaskId] or active.task
                FMAJobs.fail(self,parent,active.vehicle,"Předání práce selhalo; podrobnosti v diagnostice")
            end
        end
    end
end
