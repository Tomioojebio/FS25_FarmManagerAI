FMAHud = {}
FMAHud.pages={'Přehled','Pole','Stroje','Zvířata','Provoz','Problémy','Trasy','Nastavení','Práce','Mapa','Navigace','Polní práce','Sklizeň a pícniny','Práce u zvířat','Siláž a sklady'}
-- Courseplay-inspired task-first terminal. Page IDs stay unchanged to protect
-- every existing dispatch action and savegame setting.
-- Main screen is nine image cards, NEVER a left-hand navigation strip.
-- Actual work categories share page 9 and are separated by a task-kind filter.
FMAHud.cards={
    {label='PŘEHLED',description='Jak běží farma',page=1,icon='overview',tint={0.30,0.71,0.94}},
    {label='POLNÍ PRÁCE',description='Setí, hnojení, orba',page=9,filter='field',icon='tractor',tint={0.54,0.81,0.46}},
    {label='SKLIZEŇ',description='Kombajny, pícniny',page=9,filter='harvest',icon='combine',tint={0.95,0.70,0.30}},
    {label='ZVÍŘATA',description='Krmivo a podestýlka',page=9,filter='livestock',icon='cow',tint={0.88,0.58,0.38}},
    {label='SILÁŽ',description='Jámy a hutnění',page=9,filter='bunker',icon='silo',tint={0.34,0.79,0.65}},
    {label='TECHNIKA',description='Traktory a nářadí',page=3,icon='tractor',tint={0.35,0.72,0.96}},
    {label='PROBLÉMY',description='Proč stroje stojí',page=6,icon='alert',tint={0.98,0.42,0.43}},
    {label='MAPA A STÁNÍ',description='Trasy a parkování',page=10,icon='overview',tint={0.54,0.70,0.96}},
    {label='NASTAVENÍ',description='Pravidla družstva',page=8,icon='overview',tint={0.65,0.73,0.80}},
}

local harvestKinds={harvest=true,mow=true,ted=true,windrow=true,bale=true,baleWrap=true,baleCollect=true,foragePickup=true}
function FMAHud.taskGroup(task)
    if not task then return 'other' end
    local k=tostring(task.kind or ''):lower()
    local op=task.operation
    if k:find('bunker',1,true) or op=='compact' then return 'bunker' end
    if k:find('livestock',1,true) or k:find('animal',1,true) or op=='mixFeed' then return 'livestock' end
    if harvestKinds[op] then return 'harvest' end
    if k=='field' or (task.fieldId~=nil and op~='supply') then return 'field' end
    if op=='supply' then return 'livestock' end
    return 'other'
end

function FMAHud.openCard(c,card)
    if not c or not card then return end
    c.fmaCardHome=false
    c.fmaCardFilter=card.filter
    c.fmaCardOffset=0
    c.fmaCardMapView=false
    FMAHud.changePage(c,card.page)
end

FMAHud.iconOverlays={}
function FMAHud.loadIcons(directory)
    FMAHud.deleteIcons()
    if not Overlay or not Overlay.new then return end
    for _,name in ipairs({'overview','tractor','combine','cow','silo','alert'}) do
        local ok,overlay=pcall(Overlay.new,directory..'ui/fma_'..name..'.dds',0,0,1,1)
        if ok and overlay then FMAHud.iconOverlays[name]=overlay end
    end
end
function FMAHud.drawIcon(name,x,y,w,h)
    local overlay=FMAHud.iconOverlays and FMAHud.iconOverlays[name]
    if overlay then
        overlay:setPosition(x,y);overlay:setDimension(w,h)
        overlay:setColor(1,1,1,1);overlay:render()
    end
end
function FMAHud.deleteIcons()
    for _,overlay in pairs(FMAHud.iconOverlays or {}) do pcall(overlay.delete,overlay) end
    FMAHud.iconOverlays={}
end

FMAHud.options={
    {key="navigationLearning",label="Učit ověřené trasy automaticky"},
    {key="surveyEnabled",label="Živé mapování a malování dvora"},
    {key="surveyRadius",label="Dosah učení dvora (m)",values={120,180,230,300,400}},
    {key="surveyViewRadius",label="Přiblížení živé mapy (m)",values={80,120,180,240,320,420}},
    {key="reverseRecovery",label="Bezpečné couvnutí po fyzikálním ověření"},
    {key="navigationTimeoutSeconds",label="Stání na trase · časový limit (s)",values={45,60,75,90,120}},
    {key="hudPosition",label="Umístění menu: vpravo / střed / vlevo",values={0,1,2}},
    {key="selectedJobsOnly",label="AUTO pouze pro ručně spuštěné zakázky"},
    {key="maxWorkers",label="Současní pracovníci",values={1,2,3,4,5,6,8,10,12,16,20}},
    {key="reserve",label="Finanční rezerva",values={0,1000,5000,10000,25000,50000,100000}},
    {key="cropCare",label="Péče o porost a půdu"},
    {key="preferCourseplay",label="Courseplay pro polní práce"},
    {key="precisionFieldwork",label="Automatické pracovní kurzy a souvratě"},
    {key="coverageOverlapPercent",label="Překrytí pracovních jízd (%)",values={3,5,7,8,10,12,15}},
    {key="minHeadlands",label="Minimální počet souvratí",values={1,2,3,4}},
    {key="qualityAudit",label="Kontrola stavu po práci / opakování"},
    {key="windrowCourseReuse",label="Lis/sběrač přebírá uložený kurz řádku"},
    {key="autoForageChain",label="Automatická návaznost pícninářské čety"},
    {key="strawRecovery",label="Po sklizni automaticky zpracovat slámu"},
    {key="forageMode",label="Režim píce",values={0,1,2,3}},
    {key="baleStorageAutomation",label="Balíky automaticky do kompatibilního skladu"},
    {key="autoAssemble",label="Automaticky vybrat tahač a zapřáhnout nářadí"},
    {key="autoReturn",label="Po práci vrátit techniku a odstavit nářadí"},
    {key="headerTransport",label="Široké adaptéry vozit na podvozku"},
    {key="headerTransportMinWidth",label="Podvozek od šířky adaptéru (m)",values={4.0,5.0,6.0,7.0,8.0,9.0}},
    {key="refillBeforeWork",label="Doplnit materiál pod hranicí",values={0.10,0.20,0.25,0.35,0.50}},
    {key="refillTarget",label="Cíl doplnění před prací",values={0.60,0.70,0.80,0.85,0.90,0.95}},
    {key="autoBuyConsumables",label="Povolit automatický nákup osiva/hnojiva/paliva"},
    {key="harvestTeams",label="Koordinované sklizňové skupiny"},
    {key="maxUnloaders",label="Max. odvozců ke stroji",values={1,2,3,4}},
    {key="unloaderCall",label="Nouzová hranice přivolání odvozce",values={0.65,0.70,0.75,0.80,0.85,0.90}},
    {key="harvestFieldWaitDistance",label="Odstup čekajícího odvozce od pole (m)",values={8,10,12,15,18,22}},
    {key="livestock",label="Automatika živočišné výroby"},
    {key="foodTarget",label="Cílová zásoba krmiva",values={0.50,0.60,0.70,0.80,0.90}},
    {key="feedForecastHours",label="Předstih krmné čety (h)",values={6,12,18,24,36,48}},
    {key="strawTarget",label="Cílová zásoba podestýlky",values={0.40,0.50,0.65,0.75,0.85}},
    {key="beddingForecastHours",label="Předstih podestýlky (h)",values={6,12,18,24,36,48}},
    {key="waterTarget",label="Cílová zásoba vody",values={0.40,0.50,0.60,0.75,0.85}},
    {key="retainOrganicFertilizer",label="Hnůj/kejdu držet přednostně pro pole"},
    {key="outputForecastHours",label="Předstih odvozu výstupů (h)",values={6,12,18,24,36,48}},
    {key="productions",label="Automatika výroby a skladů"},
    {key="bunkerAutomation",label="Silážní jámy"},
    {key="bunkerDeliveryAutomation",label="Automatický vjezd/výjezd a vykládka v jámě"},
    {key="bunkerFillTarget",label="Uzavřít příjem jámy při odhadu zaplnění",values={0.80,0.85,0.90,0.95}},
    {key="bunkerPushSeconds",label="Čas nahrnování po odvozu (s)",values={20,30,35,45,60}},
    {key="baleAutomation",label="Balíky"},
    {key="baleSortByFillType",label="Třídit balíky podle skutečného typu"},
    {key="trafficSafety",label="Koordinace provozu / kolizí"},
    {key="trafficMaxTransit",label="Max. současných přejezdů po farmě",values={4,6,8,10,12,16,20}},
    {key="trafficLaunchIntervalSeconds",label="Rozestup vypouštění strojů (s)",values={1.0,1.5,2.0,2.5,3.0,4.0,5.0}},
    {key="playerPriority",label="Hráč má vždy přednost"},
    {key="supply",label="Fyzické zásobování mezi AI stanicemi"},
    {key="autoSellOutputs",label="Povolit prodej po schválení zakázky"},
    {key="sellWhenStoreAbove",label="Nabídnout prodej při naplnění sila",values={0.70,0.80,0.85,0.90,0.95,0.98}},
    {key="priceSellThreshold",label="Dobrá cena vůči pozorovanému maximu",values={0.85,0.90,0.95,0.98,1.00}},
    {key="storageReservePercent",label="Ponechat rezervu zásob",values={0.05,0.10,0.15,0.20,0.30,0.40}},
    {key="outputMoveAt",label="Odvážet výstupy od naplnění",values={0.50,0.60,0.70,0.75,0.80,0.90}},
    {key="proactivePlanning",label="Farm Brain · plánovat práci dopředu"},
    {key="strategyMode",label="Strategie družstva",values={0,1,2,3}},
    {key="weatherPriority",label="Počasí/čas mění priority práce"},
    {key="recoveryEnabled",label="Automatická obnova zablokovaných strojů"},
    {key="recoveryProbeSeconds",label="Kontrola stojícího stroje po (s)",values={20,30,35,45,60}},
    {key="maxRecoveryCycles",label="Pokusy o náhradní stroj",values={1,2,3,4,5}},
    {key="preventiveServiceDamage",label="Preventivní servis od poškození",values={0.45,0.55,0.60,0.70,0.80}},
    {key="autoService",label="Automatický servis v ověřené dílně"},
    {key="serviceAtPreventiveIdle",label="Preventivní servis volné techniky"},
    {key="performanceBudget",label="Rozložit výpočty pro velkou flotilu"},
    {key="daylightOnly",label="Nové práce pouze 06–22"},
    {key="stallSeconds",label="Watchdog nečinnosti (s)",values={120,180,300,600,900}},
    {key="threshold",label="Obecná hranice upozornění",values={0.1,0.2,0.25,0.35,0.5}}
}

local function machineType(v)
    local cls=v and v.machineClass or nil
    if cls=='tractor' then return 'Traktor' end
    if cls=='telehandler' then return 'Teleskopický manipulátor' end
    if cls=='loader' then return 'Nakladač' end
    if cls=='truck' then return 'Nákladní vozidlo' end
    if cls=='roadVehicle' then return 'Silniční vozidlo' end
    if cls=='forageHarvester' or (v and v.isForageHarvester) then return 'Řezačka' end
    if cls=='harvester' or (v and (v.isGrainCombine or v.hasCombine)) then return 'Kombajn' end
    if cls=='selfPropelledField' then return 'Samojízdný pracovní stroj' end
    return 'Stroj dle FS25'
end

function FMAHud.mainCandidates(c,task)
    local rows={}
    local seen={}
    local def=task and FMACatalog.operations[task.operation] or nil
    for _,v in ipairs(c.vehicles or {}) do
        local plausible=false
        if task.operation=="harvest" then plausible=v.isGrainCombine==true
        elseif task.operation=="foragePickup" then plausible=(v.hasCombine==true) or (v.capabilities and v.capabilities.foragePickup==true) or v.isPowerUnit==true
        else plausible=(def and v.capabilities and v.capabilities[def.cap]==true) or v.isPowerUnit==true end
        if plausible and not c.excluded[v.key] and not seen[v.key] then seen[v.key]=true;rows[#rows+1]=v end
    end
    table.sort(rows,function(a,b)
        local ad=(def and a.capabilities and a.capabilities[def.cap]) and 0 or 1
        local bd=(def and b.capabilities and b.capabilities[def.cap]) and 0 or 1
        if ad~=bd then return ad<bd end
        return a.name<b.name
    end)
    return rows
end

function FMAHud.implementCandidates(c,task)
    local rows={}
    local seen={}
    for _,tool in ipairs(c.loose or {}) do
        if FMAAssembler and FMAAssembler.toolSupports(task,tool) then rows[#rows+1]=tool;seen[tool.key]=true end
    end
    -- A cutter physically riding on the combine's attached header trailer is not "loose".
    -- Still show it as the real available adapter so the owner never sees "no adapter"
    -- while the complete transport chain is visibly connected in the yard.
    if task and task.operation=="harvest" and FMAHeaderTransport and FMAHeaderTransport.preloadedChain then
        local chain=FMAHeaderTransport.preloadedChain(c,task)
        if chain and chain.cutter and not seen[chain.cutter.key] then rows[#rows+1]=chain.cutter;seen[chain.cutter.key]=true end
    end
    table.sort(rows,function(a,b)return a.name<b.name end)
    return rows
end

local function recommendationsText(operation,maxItems)
    local list=FMACatalog.recommend(operation,maxItems or 3)
    if #list==0 then return "V katalogu nebyla bezpečně rozpoznána položka." end
    local out={};for _,item in ipairs(list) do out[#out+1]=item.name.." "..FMAUtil.money(item.price) end
    return table.concat(out," | ")
end

local function machineCondition(v)
    local damage=math.floor((v.damage or 0)*100+0.5)
    local wear=math.floor((v.wear or 0)*100+0.5)
    local fuel=v.fuelRatio and (" · palivo "..math.floor(v.fuelRatio*100+0.5).." %") or ""
    local power=(v.powerHP or 0)>0 and (" · "..math.floor((v.powerHP or 0)+0.5).." hp") or ""
    local mass=(v.mass or 0)>0 and (" · "..string.format("%.1f",v.mass).." t") or ""
    local need=(v.requiredPowerKW or 0)>0 and (" · požadavek "..math.floor(v.requiredPowerKW*1.359621617+0.5).." hp") or ""
    return "poškození "..damage.." % · opotřebení "..wear.." %"..fuel..power..mass..need
end

local function purchaseSummary(need)
    if not need then return nil end
    local names={}
    for i,item in ipairs(need.candidates or {}) do
        if i>2 then break end
        names[#names+1]=item.name.." "..FMAUtil.money(item.price)
    end
    local op=need.operation
    local requirement=op and FMACatalog.requirement(op) or "vhodná technika"
    local text="Potřeba: "..requirement
    if #names>0 then text=text.." · obchod: "..table.concat(names," | ") end
    return text
end

local function findRecord(rows,key)
    if not key then return nil end
    for _,row in ipairs(rows or {}) do if row.key==key then return row end end
    return nil
end

local function assignmentPreview(c,task,mainCandidates,implementCandidates)
    if task and task.operation=="harvest" and FMAHeaderTransport and FMAHeaderTransport.preloadedChain then
        local chain=FMAHeaderTransport.preloadedChain(c,task)
        if chain then
            return "PŘIPRAVENO K PŘEVOZU · "..chain.record.name.." → "..chain.carrier.name.." + "..chain.cutter.name.." · adaptér je fyzicky na podvozku a připojí se u pole","pending"
        end
    end
    local selected=findRecord(c.vehicles,task.preferredVehicleKey)
    local def=FMACatalog.operations[task.operation]
    if selected and def and selected.capabilities and selected.capabilities[def.cap] then
        return "PŘIPRAVENO · "..selected.name.." už má kompatibilní pracovní konfiguraci","pending"
    end
    if FMAAssembler and task.kind=="field" then
        local plan,why=FMAAssembler.findPlan(c,task)
        if plan then return "PŘIPRAVENO K ZAPŘAŽENÍ · "..plan.power.name.." → "..plan.tool.name,"pending" end
        if #implementCandidates==0 and task.operation~="supply" and task.operation~="mixFeed" then
            if FMAAssembler.hasPotentialForTask and FMAAssembler.hasPotentialForTask(c,task) then
                return "VLASTNÍ TECHNIKA NALEZENA · čeká na sestavení/uvolnění","pending"
            end
            return "NEVYJEDE · opravdu chybí kompatibilní nářadí. "..FMACatalog.requirement(task.operation),"blocked"
        end
        if task.preferredVehicleKey or task.preferredImplementKey then return "BLOKACE VÝBĚRU · "..tostring(why or "zvolená kombinace není kompatibilní"),"blocked" end
    end
    return "AUTO výběr podle dostupnosti a kompatibility","pending"
end

-- Plain-language order screen: one click opens a job, START and STOP are
-- separate deliberate actions. Optional machine selection is nested in MORE.
function FMAHud.isOrderPage(page)
    return page==9 or page==12 or page==13 or page==14 or page==15
end

function FMAHud.matchesSection(page,task)
    if page==9 then return true end
    local kind=tostring(task.kind or '')
    local op=tostring(task.operation or '')
    if page==14 then return kind:find('livestock',1,true)~=nil
        or kind:find('animal',1,true)~=nil or op=='mixFeed' or op=='supply' end
    if page==15 then return kind:find('bunker',1,true)~=nil or kind:find('bale',1,true)~=nil
        or op=='compact' or op=='baleCollect' or op=='foragePickup' end
    if page==13 then return op=='harvest' or op=='mow' or op=='windrow'
        or op=='bale' or op=='baleCollect' or op=='foragePickup' or op=='ted' end
    if page==12 then return kind=='field' and not FMAHud.matchesSection(13,task) end
    return false
end

function FMAHud.storedBaleRows(c)
    local out={}
    for _,store in ipairs(c.baleStorages or {}) do
        if (store.count or 0)>0 then
            out[#out+1]={title='BALÍKY VE SKLADU · '..tostring(store.name),
                icon='silo',status='pending',
                detail=tostring(store.count)..' uložených · '..(store.physicallyRetrievable and
                    'GIANTS umí fyzicky vyskladnit; automatický sběr vyžaduje ověřený nakladač' or
                    'vyzvednutí vyžaduje skutečný skladový výdej')}
        end
    end
    return out
end

function FMAHud.orderIcon(task)
    if FMAHud.matchesSection(14,task) then return 'cow' end
    if FMAHud.matchesSection(15,task) then return 'silo' end
    if FMAHud.matchesSection(13,task) then return 'combine' end
    return 'tractor'
end

function FMAHud.simpleOrderRows(c)
    local rows={}
    if c.fmaTaskListMode~=false or not c.focusTaskId then
        local marked=0
        for _,t in pairs(c.tasks or {}) do if t.ownerMarked then marked=marked+1 end end
        -- Batch actions have fixed, independent hitboxes above the list. Never
        -- consume the first two visible job rows with toolbar controls.
        for _,task in ipairs(FMAPlanner.queue(c.tasks or {})) do
            if FMAHud.matchesSection(c.page,task) and (not c.fmaCardFilter or FMAHud.taskGroup(task)==c.fmaCardFilter) then
            local state=task.state or 'pending'
            local tag=state=='done' and 'HOTOVO' or task.ownerApproved and 'SPUŠTĚNO' or task.ownerMarked and 'VYBRÁNO' or state=='blocked' and 'BLOKACE' or state=='paused' and 'STOP' or 'ČEKÁ'
            rows[#rows+1]={id=task.id,object={slot='simpleOpen',task=task},
                title=tostring(task.label or task.id),icon=FMAHud.orderIcon(task),
                detail=tag..' · '..tostring(FMAJobBrief and FMAJobBrief.reason and FMAJobBrief.reason(c,task) or task.reason or task.phase or 'Otevři a vyber START / STOP'),status=state}
            end
        end
        if c.page==14 or c.page==15 then
            for _,row in ipairs(FMAHud.storedBaleRows(c)) do rows[#rows+1]=row end
        end
        return rows
    end
    local task=c.tasks and c.tasks[c.focusTaskId]
    if not task then c.fmaTaskListMode=true;return rows end
    rows[#rows+1]={object={slot='simpleStart',task=task},title='START · CELÁ ČETA',
        detail='Zadá práci automatickému družstvu',status='pending'}
    rows[#rows+1]={object={slot='simpleStop',task=task},title='STOP · CELÁ ČETA',
        detail='Zastavit jen tuto zakázku a její soupravu',status='blocked'}
    rows[#rows+1]={object={slot='mark',task=task},title=task.ownerMarked and 'ODEBRAT Z VÝBĚRU' or 'PŘIDAT DO VÝBĚRU',
        detail='Pro hromadné spuštění více zakázek',status='pending'}
    rows[#rows+1]={object={slot='simpleMore',task=task},title='CO CHYBÍ / DETAILY',
        detail=tostring(FMAJobBrief and FMAJobBrief.reason and FMAJobBrief.reason(c,task) or task.reason or task.phase or 'Žádná známá blokace')..' · další nastavení',status=task.state}
    rows[#rows+1]={object={slot='back',task=task},title='ZPĚT NA ZAKÁZKY',
        detail='Bez změny stavu zakázky',status='pending'}
    return rows
end

function FMAHud.rows(c)
    if FMAHud.isOrderPage(c.page) and c.fmaAdvancedTask~=true then return FMAHud.simpleOrderRows(c) end
    local rows={}
    if c.page==1 then
        local total,ready,bare,prepared,growing,mixed=0,0,0,0,0,0
        for _,field in ipairs(c.fields or {}) do
            total=total+1
            if field.ready then ready=ready+1 elseif field.bare then bare=bare+1 elseif field.alive then growing=growing+1 end
            if field.prepared then prepared=prepared+1 end
            if field.mixed then mixed=mixed+1 end
        end
        rows[#rows+1]={title="FARMA · aktuální stav",detail="Pole "..total.." · roste "..growing.." · ke sklizni "..ready.." · připravená půda "..prepared.." · technika "..#(c.vehicles or {}).." + "..#(c.loose or {}).." nářadí",status=total>0 and "pending" or "blocked"}
        local brain=c.shiftPlan;local w=brain and brain.weather;rows[#rows+1]={title="FARM BRAIN · "..(FMAFarmBrain and FMAFarmBrain.strategyLabel(c.settings) or "AUTO"),detail="Počasí "..tostring(w and w.status or "čeká na scan").." · fronta "..tostring(brain and #(brain.rows or {}) or 0).." · aktivní "..tostring(FMAUtil.count(c.active or {})).." · připravované čety "..tostring(FMAUtil.count(c.preparedNextCrew or {})),status=c.settings.enabled and "running" or "pending"}
        local needs={};for _,need in pairs(c.purchaseNeeds or {}) do needs[#needs+1]=need end
        table.sort(needs,function(a,b)return tostring(a.label)<tostring(b.label) end)
        for i,need in ipairs(needs) do
            if i<=4 then rows[#rows+1]={title="CHYBÍ / DOKOUPIT · "..tostring(need.label),detail=purchaseSummary(need) or need.detail,status="blocked"} end
        end
        for _,t in ipairs(FMAPlanner.queue(c.tasks)) do
            local preferred=t.preferredVehicleKey and (" · stroj "..(t.preferredVehicleName or t.preferredVehicleKey)) or " · AUTO"
            local phase=t.phase and (" · fáze "..t.phase) or ""
            local eta=(t.etaMinutes and t.etaMinutes>0) and (" · ETA ~"..math.floor(t.etaMinutes+0.5).." min") or ""
            rows[#rows+1]={id=t.id,object=t,title=(t.ownerRequested and "[PRIORITA] " or "")..t.label,detail=(FMACatalog.statusLabels[t.state] or t.state)..phase.." · "..(t.reason or (t.vehicleKey and "Souprava přidělena" or "Připraveno"))..preferred..eta,status=t.state}
        end
        for _,condition in ipairs(c.conditions or {}) do rows[#rows+1]={title=condition.name,detail="Stav "..math.floor((condition.ratio or 0)*100).." %",status=(condition.ratio or 0)<0.25 and "blocked" or "pending"} end
    elseif c.page==2 then
        for _,field in ipairs(c.fields) do
            local policy=c.policies[field.id]
            local state=field.stateLabel or (field.valid and "stav ověřen" or "stav NEOVĚŘEN")
            local nextText=field.nextOperation and FMACatalog.operations[field.nextOperation].label or field.reason or "Bez práce"
            local sampleText=""
            local needs={}
            if field.needsLime then needs[#needs+1]="VÁPNO" end
            if field.needsFertilize then needs[#needs+1]="HNOJIVO" end
            if field.needsWeed then needs[#needs+1]="PLEVEL" end
            if field.needsRoll then needs[#needs+1]="VÁLENÍ" end
            if field.needsPlow then needs[#needs+1]="ORBA" end
            if field.needsStone then needs[#needs+1]="KAMENY" end
            local needText=#needs>0 and table.concat(needs,", ") or "bez zásahu"
            rows[#rows+1]={id=field.id,object=field,title=field.name.." · "..(policy.enabled and "SPRÁVA ZAPNUTA" or "RUČNÍ SPRÁVA"),detail="Stav: "..state.." · potřeby: "..needText.." · další práce: "..nextText.." · plán dalšího setí: "..(FMACatalog.cropLabels[policy.crop] or "VYBER PLODINU"),status=field.valid and "pending" or "blocked"}
        end
    elseif c.page==3 then
        for _,v in ipairs(c.vehicles) do
            local caps={};for op,yes in pairs(v.capabilities or {}) do if yes and FMACatalog.operations[op] then caps[#caps+1]=FMACatalog.operations[op].label end end;table.sort(caps)
            local state=c.excluded[v.key] and "RUČNĚ" or v.busy and "OBSAZENO" or "VOLNÝ"
            local damage=math.floor((v.damage or 0)*100+0.5);local wear=math.floor((v.wear or 0)*100+0.5)
            local fuel=v.fuelRatio and (" · palivo "..math.floor(v.fuelRatio*100+0.5).." %") or ""
            local origin=v.originKind=="mod" and (" · "..tostring(v.originMod)) or ""
            rows[#rows+1]={id=v.key,object=v,kind="vehicle",title=machineType(v).." · "..v.name.." · "..state,
                detail=machineCondition(v)..origin.." · "..(#caps>0 and table.concat(caps," / ") or "bez připojeného pracovního nářadí"),
                status=(damage>=55 or wear>=80 or v.lowFuel) and "blocked" or v.busy and "running" or "pending"}
        end
        for _,tool in ipairs(c.loose or {}) do
            local caps={};for op,yes in pairs(tool.capabilities or {}) do if yes and FMACatalog.operations[op] then caps[#caps+1]=FMACatalog.operations[op].label end end;table.sort(caps)
            local damage=math.floor((tool.damage or 0)*100+0.5);local wear=math.floor((tool.wear or 0)*100+0.5)
            local origin=tool.originKind=="mod" and (" · "..tostring(tool.originMod)) or ""
            rows[#rows+1]={id=tool.key,object=tool,kind="tool",title="Nářadí · "..tool.name,
                detail="poškození "..damage.." % · opotřebení "..wear.." %"..origin.." · "..(#caps>0 and table.concat(caps," / ") or "pomocné / přepravní nářadí"),status=(damage>=55 or wear>=80) and "blocked" or "pending"}
        end
    elseif c.page==4 then
        local conditionCountByPlace={}
        for _,condition in ipairs(c.animalConditions or {}) do
            local base=tostring(condition.name or ""):match("^(.-) · ") or tostring(condition.name or "")
            conditionCountByPlace[base]=(conditionCountByPlace[base] or 0)+1
        end
        for _,h in ipairs((c.mapProfile and c.mapProfile.husbandries) or {}) do
            local name=tostring(h.name or FMAUtil.name(h.object))
            rows[#rows+1]={title="CHOV · "..name,detail="FS25 runtime hodnoty níže · načtených ukazatelů "..tostring(conditionCountByPlace[name] or 0),status="pending"}
        end
        for _,condition in ipairs(c.animalConditions or {}) do
            local pct=math.floor((condition.ratio or 0)*100)
            local source=condition.source=="FS25" and "FS25 PŘÍMO" or condition.source=="FS25_STORAGE" and "FS25 ZÁSOBNÍK" or "ZÁLOŽNÍ VÝPOČET"
            local detail=source.." · "..(condition.message or "Chov").." · "..pct.." %"
            if condition.value~=nil and condition.capacity~=nil then detail=detail.." · "..math.floor(condition.value).." / "..math.floor(condition.capacity).." l" end
            local blocked=condition.neutral~=true and (condition.ratio or 0)<(c.settings.foodEmergency or 0.15)
            rows[#rows+1]={title=condition.name,detail=detail,status=blocked and "blocked" or "pending"}
        end
    elseif c.page==5 then
        local transit=0
        for _,a in pairs(c.active or {}) do if FMATraffic and FMATraffic.isTransitTask and FMATraffic.isTransitTask(a.task) then transit=transit+1 end end
        for i,m in ipairs(c.marketRows or {}) do
            if i>12 then break end
            local price=m.best and math.floor(m.best.price*1000+0.5) or 0
            local historic=math.floor((m.priceHigh or 0)*1000+0.5)
            rows[#rows+1]={title="TRH / SILO · "..FMAWorld.fillName(m.fillType),
                detail=math.floor(m.ratio*100).." % · "..math.floor(m.level).." l · cena "..price.."/1000 l · rekord "..historic.."/1000 l"..(m.manualHandling and " · PALETY: chybí ověřený převoz" or ""),
                status=m.pressure and "blocked" or "pending"}
        end
        rows[#rows+1]={title="DISPEČER PROVOZU",detail="Aktivní přejezdy "..transit.." / "..tostring(c.settings.trafficMaxTransit or 10).." · rezervované zóny "..tostring(FMAUtil.count(c.traffic and c.traffic.zones or {})).." · zadržené starty "..tostring(c.traffic and c.traffic.blockedStarts or 0).." · přednosti "..tostring(c.traffic and c.traffic.yieldCount or 0),status=transit>0 and "running" or "pending"}
        local primary=math.floor((c.settings.bunkerPrimaryIndex or 0)+0.5);local nextB=math.floor((c.settings.bunkerNextIndex or 0)+0.5)
        rows[#rows+1]={title="SILÁŽNÍ LINKA",detail=(primary>0 and ("Příjem jáma "..primary) or "Příjem AUTO")..(nextB>0 and (" → potom jáma "..nextB) or "").." · při cíli příjmu se odvoz přesměruje a stará jáma dokončí hutnění",status=primary>0 and "running" or "pending"}
        local mp=c.mapProfile or {}
        if mp.active then
            rows[#rows+1]={title="Karpatský venkov · načtená infrastruktura",detail="Stáje "..tostring(#(mp.husbandries or {})).." · jámy "..tostring(#(mp.bunkers or {})).." · sklady "..tostring(#(mp.storages or {})).." · výroby "..tostring(#(mp.productions or {})).." · AI nakládky "..tostring(mp.aiLoadingStations or 0).." / vykládky "..tostring(mp.aiUnloadingStations or 0),status="pending"}
            for _,row in ipairs(mp.husbandries or {}) do rows[#rows+1]={title="Stáj · "..tostring(row.name or FMAUtil.name(row.object)),detail="Vlastní objekt mapy / ModHub · sledování krmiva, podestýlky a výstupů",status="pending"} end
            for _,row in ipairs(mp.storages or {}) do
                local parts={}
                for _,fill in ipairs(row.fillRows or {}) do if (fill.level or 0)>0 then parts[#parts+1]=FMAWorld.fillName(fill.fillType).." "..math.floor(fill.level)..(fill.capacity and fill.capacity>0 and ("/"..math.floor(fill.capacity).." l") or " l") end end
                table.sort(parts)
                local detail
                if #parts>0 then
                    detail=table.concat(parts," · ").." · zdroj "..tostring(row.inventorySource or "FS25")
                elseif row.inventoryKnown then
                    detail="0 l · FS25 runtime potvrzuje prázdný zásobník"
                else
                    detail="STAV NEZNÁMÝ · tento sklad neposkytl Manageru autoritativní runtime stav náplní"
                end
                rows[#rows+1]={title="Sklad · "..tostring(row.name or FMAUtil.name(row.object)),detail=detail,status=row.inventoryKnown and "pending" or "blocked"}
            end
            for _,row in ipairs(mp.productions or {}) do rows[#rows+1]={title="Výroba · "..tostring(row.name or FMAUtil.name(row.object)),detail="Detekovaný výrobní bod · vstupy a výstupy se plánují podle skutečného objektu",status="pending"} end
        end
        for id,g in pairs(c.workgroups or {}) do rows[#rows+1]={title="Sklizňová skupina · pole "..g.fieldId,detail="Hlavní stroj "..g.harvester.name.." · odvoz "..#g.unloaders.."/"..g.required.." · "..g.state,status=#g.unloaders<g.required and "blocked" or "running"} end
        for taskId,roles in pairs(c.preparedSupport or {}) do
            local parent=c.tasks and c.tasks[taskId]
            for slot,role in pairs(roles) do
                if parent and role.state~='ACTIVE' then
                    local name=role.record and role.record.name or 'AUTO'
                    rows[#rows+1]={title='Odvoz '..tostring(parent.fieldId)..' #'..tostring(slot)..' · '..name,detail=tostring(role.state)..' · '..tostring(role.reason or ''),status=(role.state=='WAITING_FIELD' and 'running' or role.state=='BLOCKED' and 'blocked' or 'pending')}
                end
            end
        end
        for i,b in ipairs(c.bunkers or {}) do
            local role=FMABunkerCoordinator and FMABunkerCoordinator.role(c,i) or "VOLNÁ"
            local ratio=FMABunkerCoordinator and FMABunkerCoordinator.fillRatio(c,b) or nil
            local ws=c.bunkerWorkState and c.bunkerWorkState[i] or {}
            local fillText=ratio and (math.floor(ratio*100+0.5).." % odhad") or (math.floor(b.fillLevel or 0).." l")
            local route=b.deliveryMode and (b.deliveryMode=="driveThrough" and "PRŮJEZDNÁ" or "COUVÁNÍ") or "přístup čeká na ověření CP"
            local ready=b.canClose and " · HOTOVO K ZAKRYTÍ" or (ws.intakeClosed and " · PŘÍJEM UZAVŘEN" or "")
            rows[#rows+1]={object={kind="bunker",index=i},title="Silážní jáma "..i.." · "..role,
                detail="Zaplnění "..fillText.." · "..math.floor(b.fillLevel or 0).." l · hutnění "..math.floor(b.compactedPercent or 0).." % · "..tostring(ws.phase or "IDLE").." · "..route..ready.." · kliknutím: hlavní/další/auto",
                status=b.canClose and "blocked" or (role=="PŘÍJEM" or (b.fillLevel or 0)>0) and "running" or "pending"}
        end
        for fieldId,stage in pairs(c.forageStages or {}) do rows[#rows+1]={title="Pícninářská četa · pole "..fieldId,detail="Fáze: "..stage.." · další operace se vytvoří po návratu předchozí čety",status="running"} end
        for fieldId,row in pairs(c.baleFields or {}) do
            rows[#rows+1]={title="Balíky · pole "..fieldId,detail=tostring(row.count or 0).." ks · "..tostring(row.typeSummary or "typ nezjištěn").." · sběr → kompatibilní sklad → návrat",status=(row.count or 0)>0 and "running" or "pending"}
        end
        for _,s in ipairs(c.baleStorages or {}) do
            local stored={};for ft,count in pairs(s.storedFillTypes or {}) do if count>0 then stored[#stored+1]=FMAWorld.fillName(ft).." "..count.."×" end end;table.sort(stored)
            rows[#rows+1]={title="Sklad balíků · "..s.name,detail="Volná kapacita "..tostring(s.free).." / "..tostring(s.capacity)..(#stored>0 and (" · uloženo: "..table.concat(stored," · ")) or ""),status=s.free>(c.settings.baleStorageReserve or 0) and "pending" or "blocked"}
        end
    elseif c.page==6 then
        rows[#rows+1]={object={slot='devPhysical'},title='VÝVOJ: TEST MOTORU A JÍZDY',
            detail='JEN KOPIE POZICE! AUTO vypnuté · volný traktor 25 m od budov i vozidel · 1,4 m vpřed a zpět, jinak bezpečně odmítne',status='pending'}
        rows[#rows+1]={object={slot='devStop'},title='VÝVOJ: ZASTAVIT TEST',
            detail='Okamžitě uvolnit zkušební traktor; normální ovládání E/Enter/ESC se nemění',status='blocked'}
        rows[#rows+1]={object={runPassiveTest=true},title='DIAGNOSTICKÝ TEST + JEDEN REPORT',
            detail='Bez pohybu techniky · kontrola farmy, chyb, souprav, Courseplay a export jednoho souboru přes Alt+D',status='pending'}
        local needs={};for _,v in pairs(c.purchaseNeeds or {}) do needs[#needs+1]=v end;table.sort(needs,function(a,b)return a.label<b.label end)
        for _,need in ipairs(needs) do rows[#rows+1]={object={purchase=need},title=(need.approved and "SCHVÁLENO K NÁKUPU · " or "NÁVRH NÁKUPU · ")..need.label,detail=need.detail.." · kliknutím: "..(need.approved and "zrušit schválení" or "schválit nákupní požadavek"),status=need.approved and "pending" or "blocked"} end
        local issues={};for _,v in pairs(c.issues) do issues[#issues+1]=v end
        local issueRank={error=1,action=2,warning=3,info=4}
        local issueLabel={error="CHYBA",action="ZÁSAH",warning="UPOZORNĚNÍ",info="INFO"}
        table.sort(issues,function(a,b)
            local ar=issueRank[a.kind or "warning"] or 3;local br=issueRank[b.kind or "warning"] or 3
            if ar~=br then return ar<br end
            if a.priority==b.priority then return a.id<b.id end
            return a.priority>b.priority
        end)
        for _,v in ipairs(issues) do
            local kind=v.kind or "warning"
            rows[#rows+1]={id=v.id,title="["..(issueLabel[kind] or "UPOZORNĚNÍ").."] "..v.title,detail=v.detail,status=(kind=="error" or kind=="action") and "blocked" or "pending"}
        end
        if FMAJobBrief then
            local counts=FMAJobBrief.summary(c)
            rows[#rows+1]={title='PROVOZNÍ KONTROLA · '..counts.blockers..' blokací',
                detail='Zakázky '..counts.jobs..' · spuštěné '..counts.started..' · ručně zastavené '..counts.stopped..' · každý stav ověřit v FS25',
                status=counts.blockers>0 and 'blocked' or 'pending'}
            for _,problem in ipairs(FMAJobBrief.problems(c,8)) do
                rows[#rows+1]={title='ZAKÁZKA · '..tostring(problem.label),
                    detail=problem.reason,status='blocked'}
            end
        end
    elseif c.page==7 then
        for _,v in ipairs(c.vehicles) do
            local route=c.routes[v.key]
            if route or #(v.compatibility and v.compatibility.autoloaders or {})>0 then rows[#rows+1]={id=v.key,object=v,title=v.name.." · "..(route and route.enabled and "TRASA ZAPNUTA" or "TRASA VYPNUTA"),detail=route and ("Nakládka "..(route.load and "OK" or "CHYBÍ").." / Vykládka "..(route.unload and "OK" or "CHYBÍ").." · "..(route.reason or route.phase or "idle")) or "V soupravě: Alt+L nakládka · Alt+U vykládka",status=route and route.enabled and "running" or "pending"} end
        end
    elseif c.page==8 then
        for _,page in ipairs({{2,'POLE'},{4,'ZVÍŘATA'},{5,'PROVOZ A SILA'},{7,'TRASY'},{11,'NAVIGACE'}}) do
            rows[#rows+1]={object={slot='navigatePage',page=page[1]},title=page[2],detail='Otevřít pokročilou sekci',status='pending'}
        end
        for i,option in ipairs(FMAHud.options) do local value=c.settings[option.key];if option.key=="forageMode" and FMAForageCoordinator then value=FMAForageCoordinator.modeLabel(c.settings) elseif option.key=="strategyMode" and FMAFarmBrain then value=FMAFarmBrain.strategyLabel(c.settings) elseif type(value)=="boolean" then value=value and "ANO" or "NE" elseif type(value)=="number" and value>0 and value<1 then value=math.floor(value*100).." %" end;rows[#rows+1]={id=i,object=option,title=option.label,detail=tostring(value).." · kliknutím změní hodnotu",status="pending"} end
    elseif c.page==9 then
        if c.fmaTaskListMode==true or (c.fmaTaskListMode==nil and not c.focusTaskId) then
            rows[#rows+1]={object={slot="launchMarked"},title="▶ SPUSTIT VYBRANÉ ZAKÁZKY",detail="Označ práce níže · kliknutím spustí pouze vybrané",status="pending"}
            rows[#rows+1]={object={slot="markAll"},title="OZNAČIT VŠECHNY / ZRUŠIT",detail="Změní výběr všech navržených zakázek, nikoli jejich stroje",status="pending"}
            rows[#rows+1]={object={slot="editMarked"},title="NASTAVIT POSLEDNÍ VYBRANOU",detail="Výběr hlavního traktoru, nářadí a sklizňové čety",status="pending"}
            for _,task in ipairs(FMAPlanner.queue(c.tasks or {})) do
                rows[#rows+1]={id=task.id,object={slot="mark",task=task},
                    title=(task.ownerApproved and "[V PROVOZU] " or task.ownerMarked and "[X] " or "[ ] ")..tostring(task.label or "Zakázka"),
                    detail=(task.phase or (FMACatalog.statusLabels[task.state] or task.state or "Čeká")).." · "..(task.reason or task.preferredVehicleName or "Stroj AUTO").." · kliknutím označí / zruší",
                    status=task.state}
            end
        else
        local task=c.focusTaskId and c.tasks[c.focusTaskId] or FMAPlanner.queue(c.tasks or {})[1]
        if task then
            c.focusTaskId=task.id
            local mainCandidates=FMAHud.mainCandidates(c,task)
            local implementCandidates=FMAHud.implementCandidates(c,task)
            rows[#rows+1]={object={slot="start",task=task},title="SPUSTIT / POKRAČOVAT",detail=task.label.." · Manager provede přípravu, přejezd, práci, kontrolu a návrat",status=task.state}
            rows[#rows+1]={object={slot="back",task=task},title="← ZPĚT NA VŠECHNY ZAKÁZKY",detail="Vrátit seznam prací bez změny techniky",status="pending"}
            rows[#rows+1]={object={slot="main",task=task},title="Hlavní stroj · "..(task.preferredVehicleName or "AUTO"),detail="kliknutím: AUTO → vhodné stroje → AUTO · Manager v AUTO hodnotí kompatibilitu, výkon, hmotnost, stav a vzdálenost",status=#mainCandidates>0 and "pending" or "blocked"}
            if task.isSale and task.marketAlternatives then
                rows[#rows+1]={object={slot="marketTarget",task=task},title="ODBĚRATEL · "..tostring(FMAUtil.name(task.destination and (task.destination.owningPlaceable or task.destination)) or 'AUTO'),
                    detail="kliknutím: změnit prodejní místo dle živé ceny; bez schválení žádný prodej",status="pending"}
            end
            local needsImplement=task.kind=="field" and task.operation~="supply" and task.operation~="mixFeed"
            rows[#rows+1]={object={slot="implement",task=task},title="Nářadí / adaptér · "..(task.preferredImplementName or "AUTO"),detail=(#implementCandidates>0 and ("kliknutím: AUTO → "..#implementCandidates.." kompatibilní kusů → AUTO") or "Vlastní kompatibilní odpojené nářadí nenalezeno"),status=(not needsImplement or #implementCandidates>0) and "pending" or "blocked"}
            local preview,previewStatus=assignmentPreview(c,task,mainCandidates,implementCandidates)
            rows[#rows+1]={title="STAV SOUPRAVY",detail=preview,status=previewStatus}
            if task.operation=="harvest" then
                rows[#rows+1]={title="SKLIZŇOVÁ ČETA · AUTO",detail="Manager přidělí kompatibilní kombajn + adaptér a podle kapacity pole až "..tostring(c.settings.maxUnloaders or 3).." odvozní soupravy; řezačka se pro obilní sklizeň nenabízí.",status="pending"}
                rows[#rows+1]={object={slot="carrier",task=task},title="Podvozek adaptéru · "..(task.preferredCarrierName or "AUTO"),detail="kliknutím změní podvozek pouze pokud široký adaptér vyžaduje přepravu",status="pending"}
            end
            local need=c.purchaseNeeds and c.purchaseNeeds[task.operation]
            if need then rows[#rows+1]={title="CHYBÍ / DOKOUPIT · "..tostring(need.label),detail=purchaseSummary(need) or need.detail,status="blocked"}
            elseif needsImplement and #implementCandidates==0 and not (FMAAssembler and FMAAssembler.hasPotentialForTask and FMAAssembler.hasPotentialForTask(c,task)) then
                rows[#rows+1]={title="CHYBÍ TECHNIKA · "..(FMACatalog.operations[task.operation] and FMACatalog.operations[task.operation].label or task.operation),detail="Potřeba: "..FMACatalog.requirement(task.operation).." · obchod: "..recommendationsText(task.operation,2),status="blocked"}
            end
            if task.operation=="sow" or task.operation=="fertilize" or task.operation=="lime" then
                rows[#rows+1]={title="MATERIÁL",detail=(c.settings.autoBuyConsumables and "AUTO nákup spotřebního materiálu povolen" or "AUTO nákup vypnut · Manager použije vlastní zásoby / nákup oznámí").." · před výjezdem fyzické doplnění",status="pending"}
            end
            if task.phase then rows[#rows+1]={title="PRŮBĚH",detail=task.phase..(task.reason and (" · "..task.reason) or ""),status=task.state} end
        end
        end -- task list / detailed job setup

    elseif c.page==11 then
        local s=FMANavigation and FMANavigation.summary(c) or {routes=0,hazards=0,learned=0,failures=0,escapes=0}
        rows[#rows+1]={title="ŽIVÁ NAVIGACE",detail="Ověřené trasy: "..s.routes.." · problematická místa: "..s.hazards.." · potvrzené jízdy: "..s.learned,status="pending"}
        rows[#rows+1]={title="VYPROŠTĚNÍ",detail="Ověřená couvnutí: "..s.escapes.." · pozorované chyby: "..s.failures.." · bez teleportu a tlačení do překážky",status="pending"}
        rows[#rows+1]={title="POSLEDNÍ NAVIGAČNÍ UDÁLOST",detail=s.last~="" and s.last or "Žádná potvrzená jízdní zkušenost",status="pending"}
        local live={}
        for _,a in pairs(c.active or {}) do
            if a.trafficTarget and a.vehicle then
                local idle=math.max(0,math.floor(((c.now or 0)-(a.lastProgress or a.start or (c.now or 0)))/1000))
                live[#live+1]={name=a.vehicle.name or a.vehicle.key or '?',idle=idle,method=a.transferMethod or 'AI',phase=a.task and a.task.phase or ''}
            end
        end
        table.sort(live,function(a,b)return a.idle>b.idle end)
        for i=1,math.min(#live,5) do
            local r=live[i]
            rows[#rows+1]={title="STROJ · "..r.name,detail="Bez posunu: "..r.idle.." s · "..r.method.." · "..r.phase,status=r.idle>=30 and "blocked" or "running"}
        end
        rows[#rows+1]={object={navAction='refresh'},title="OBNOVIT STAV MAPY",detail="Přenačíst skutečné pozice strojů, cestovní omezení a aktuální mapové objekty",status="pending"}
        rows[#rows+1]={object={navAction='position'},title="PŘESUNOUT MENU",detail="Přepnout pravá / střední / levá pozice při konfliktu s panelem Courseplay",status="pending"}
        local n=c.navigationMap or {}
        local hazards={};for k,h in pairs(n.hazards or {}) do hazards[#hazards+1]={key=k,row=h} end
        table.sort(hazards,function(a,b)return (a.row.failures or 0)>(b.row.failures or 0) end)
        for i=1,math.min(12,#hazards) do
            local h=hazards[i]
            rows[#rows+1]={title="PŘEKÁŽKA · "..h.key,detail=(h.row.reason or 'Neprůjezdnost').." · hlášení: "..tostring(h.row.failures),status="blocked"}
        end
    elseif c.page==10 then
        local map=c.digitalMap or (FMAFarmBrain and FMAFarmBrain.buildDigitalMap and FMAFarmBrain.buildDigitalMap(c)) or {zones={},chokePoints={}}
        local role=FMATeach and FMATeach.role(c) or "DVŮR"
        rows[#rows+1]={object={mapAction="role"},title="ROLE UČENÍ · "..role,detail="kliknutím přepne DVŮR / POLE / JÁMA / SKLAD / NÁŘADÍ / SERVIS / PLNIČKA / ČEKÁNÍ / BRÁNA / OTOČKA",status="pending"}
        rows[#rows+1]={object={mapAction="point"},title="ULOŽIT BOD PŘÍJEZDU",detail="Sedni do stroje na bezpečném čekacím/nájezdovém místě · kliknutím uloží ověřený bod",status="pending"}
        local parkingCount=FMAUtil.count(c.parkingBays or {})
        rows[#rows+1]={object={mapAction="parkVehicle"},title="NAUČIT STÁNÍ STROJE",detail="Zastav traktor/kombajn na správném místě · kliknutím uloží přesnou pozici i směr",status="pending"}
        rows[#rows+1]={object={mapAction="parkTool"},title="NAUČIT STÁNÍ NÁŘADÍ",detail="Zastav s připojeným nářadím · kliknutím uloží polohu nářadí i tažného stroje",status="pending"}
        rows[#rows+1]={object={mapAction="organize"},title=c.parkingOrganize and "ZASTAVIT USPOŘÁDÁNÍ TECHNIKY" or "USPOŘÁDAT VOLNÉ STROJE",detail="Naučená stání: "..parkingCount.." · přesouvá jen volné stroje, každý přejezd musí potvrdit AI",status=c.parkingOrganize and "running" or "pending"}
        rows[#rows+1]={object={mapAction="removePark"},title="SMAZAT POSLEDNÍ STÁNÍ",detail="Opraví chybně naučené parkování bez změny ostatních tras",status="pending"}
        rows[#rows+1]={title="PARKOVACÍ ZÓNY",detail="Rozpoznáno provozních míst: "..#(c.parkingFacilities or {}).." · garáže, přístřešky, hnůj, jámy, sila · kořeny budov nejsou vjezdy",status="pending"}
        rows[#rows+1]={object={mapAction="route"},title=(c.teachSession and "UKONČIT UČÍCÍ JÍZDU" or "ZAČÍT UČÍCÍ JÍZDU"),detail="Projeď problematický dvůr/bránu/příjezd; Manager si uloží řídkou ověřenou stopu",status=c.teachSession and "running" or "pending"}
        rows[#rows+1]={object={mapAction="clear"},title="SMAZAT POSLEDNÍ NAUČENÝ BOD/TRASU",detail="Použij jen když ses při učení spletl",status="pending"}
        rows[#rows+1]={title="DIGITÁLNÍ MAPA FARMY",detail="Zóny "..tostring(#(map.zones or {})).." · úzká/rušná místa "..tostring(#(map.chokePoints or {})).." · naučené body "..tostring(FMAUtil.count(c.learnedPoints or {})).." · trasy "..tostring(FMAUtil.count(c.learnedRoutes or {})),status="pending"}
        local survey=FMAFarmSurvey and FMAFarmSurvey.summary(c) or {mapped=0,confirmed=0}
        rows[#rows+1]={object={mapAction="anchor"},title="ZAMĚŘIT STŘED DVORA",detail="Vezmi traktor na dvůr · kliknutím ukotví mapu podle skutečné polohy",status=survey.center and "pending" or "blocked"}
        rows[#rows+1]={object={mapAction="zoom"},title="PŘIBLÍŽENÍ MAPY",detail="Změnit rozsah zobrazení · aktuálně "..tostring(c.settings.surveyViewRadius or 180).." m",status="pending"}
        rows[#rows+1]={object={mapAction="preview"},title="NAJÍT NAUČENOU CESTU K OBJEKTU",detail=(c.farmSurveyPreview and c.farmSurveyPreview.name or 'Další sklad / stání / jáma')..' · pouze náhled po skutečně projeté síti',status="pending"}
        rows[#rows+1]={object={mapAction="toggle"},title="ŽIVÉ ZAZNAMENÁVÁNÍ",detail=""..(c.settings.surveyEnabled~=false and "ZAPNUTO" or "VYPNUTO").." · reálné stopy vozidel, nikoli vymyšlené cesty",status="pending"}
    end
    return rows
end

-- A single cooperative job can have several nested runtime phases (tractor,
-- assembly, refill, unloader, delivery, return). Identify ALL descendants by
-- their actual parent chain, not only the direct parent or a harvest crew label.
-- The same invariant applies to every job category and every ModHub machine.
function FMAHud.belongsToOrder(c,root,candidate)
    if not root or not candidate then return false end
    local rootId=root.id
    local crewId=root.crewId
    local seen={}
    local current=candidate
    for _=1,12 do
        if not current or seen[current] then return false end
        seen[current]=true
        if current==root or (rootId~=nil and current.id==rootId) then return true end
        if crewId~=nil and (current.parentGroup==crewId or current.crewId==crewId) then return true end
        local parentId=current.parentTaskId
        if rootId~=nil and parentId==rootId then return true end
        current=current.parentTask or (parentId and c and c.tasks and c.tasks[parentId])
    end
    return false
end

-- Stop just ONE selected job; never disable the entire cooperative.
function FMAHud.stopTask(c,task)
    if not task then return false end
    task.ownerApproved=false;task.ownerMarked=nil;task.ownerRequested=false
    task.ownerStopRequested=true
    local function relates(t) return FMAHud.belongsToOrder(c,task,t) end
    local jobs={}
    for job,a in pairs(c.active or {}) do
        if relates(a.task) then
            a.stopReason='OWNER_STOP_SELECTED'
            jobs[#jobs+1]=job
        end
    end
    for _,job in ipairs(jobs) do FMAAI.stop(job) end
    for key,session in pairs(c.externalFieldwork or {}) do
        if session and session.taskId==task.id then
            local record=c.vehicleByKey and c.vehicleByKey[key]
            local vehicle=record and record.object
            local liveJob=vehicle and FMAUtil.call(vehicle,'getJob')
            if liveJob and FMAUtil.call(vehicle,'getIsAIActive')==true then
                pcall(FMAAI.stop,liveJob)
            end
            c.externalFieldwork[key]=nil
        end
    end
    for _,name in ipairs({'attachSessions','refillSessions','headerWaits','livestockSessions',
                'bunkerDeliverySessions','baleUnloadSessions','baleDeliveryWaits','forageBunkerWaits',
                'qualityCoursePending','cpBoundary','deferred'}) do
        local collection=c[name] or {}
        local ids={}
        for id,s in pairs(collection) do
            if relates(s.parent) or relates(s.task) or (s.active and type(s.active)=='table' and relates(s.active.task)) then ids[#ids+1]=id end
        end
        for _,id in ipairs(ids) do
            local s=collection[id]
            if s then FMALifecycle.cancelSession(c,collection,id,s,'Zastaveno majitelem') end
        end
    end
    task.state='paused';task.phase='STOP';task.reason='Zastaveno majitelem';task.retryAt=0
    if c.preparedSupport and c.preparedSupport[task.id] then
        for _,role in pairs(c.preparedSupport[task.id]) do
            if role.record and (role.state=='WAITING_FIELD' or role.state=='NEEDED' or role.state=='BLOCKED'
                or role.state=='READY' or role.state=='ACTIVE' or role.state=='STAGING') then
                c.reservations[role.record.key]=nil;role.record.busy=false
                if c.traffic then FMATraffic.release(c.traffic,role.record.key) end
                role.state='PAUSED';role.reason='Zakázka zastavena majitelem'
            end
        end
    end
    if c.diagnosticDirty~=nil then c.diagnosticDirty=true end
    c:notify('STOP · '..tostring(task.label or task.id))
    return true
end

function FMAHud.stopMatching(c,predicate)
    local jobs={}
    for job,a in pairs(c.active) do
        if predicate(a) then a.stopReason="Převzato majitelem";jobs[#jobs+1]=job end
    end
    for _,job in ipairs(jobs) do FMAAI.stop(job) end
end

-- A Courseplay-style pointer, without adding pages to the native ESC GUI.
-- Save and restore the exact camera rotation state, not just "true".
-- Close the pointer session in one place. In FS25 a camera's isRotatable
-- may originally be nil (the engine default); a normal Lua table cannot store
-- that nil as a saved value. Remember it with an explicit sentinel instead.
-- CpHud.isHudActive is often a FUNCTION, never test it as a truthy boolean:
-- the old check accidentally kept our cursor visible forever after Alt+M.
function FMAHud.releaseMouse(c)
    if not c then return end
    local guiVisible=g_gui and g_gui.getIsGuiVisible and g_gui:getIsGuiVisible()
    local dialogVisible=g_gui and g_gui.getIsDialogVisible and g_gui:getIsDialogVisible()
    local cpHudActive=CpHud and type(CpHud.isHudActive)=='boolean' and CpHud.isHudActive==true
    if c.fmaMouseOwned and not guiVisible and not dialogVisible and not cpHudActive and g_inputBinding and g_inputBinding.setShowMouseCursor then
        pcall(g_inputBinding.setShowMouseCursor,g_inputBinding,false)
    end
    for camera,rotatable in pairs(c.fmaSavedCameras or {}) do
        if type(camera)=="table" then
            if rotatable=="__FMA_CAMERA_DEFAULT_NIL__" then camera.isRotatable=nil
            else camera.isRotatable=rotatable end
        end
    end
    c.fmaSavedCameras=nil
    c.fmaMouseOwned=false
    c.fmaMouseMode=false
    c.fmaCursorCheckAt=nil
end

function FMAHud.setVisible(c,value)
    FMAHud._controller=c
    if not c then return end
    if value==true and c.visible and c.fmaMouseMode then return end
    if value~=true then
        c.visible=false
        FMAHud.releaseMouse(c)
        return
    end
    if g_gui and g_gui.getIsGuiVisible and g_gui:getIsGuiVisible() then return end
    if g_gui and g_gui.getIsDialogVisible and g_gui:getIsDialogVisible() then return end
    c.visible=true
    c.fmaCardHome=true
    c.fmaCardOffset=0
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        local wasShown=false
        if g_inputBinding.getShowMouseCursor then
            local ok,v=pcall(g_inputBinding.getShowMouseCursor,g_inputBinding)
            if ok then wasShown=v==true end
        end
        if not wasShown then
            local ok=pcall(g_inputBinding.setShowMouseCursor,g_inputBinding,true)
            if not ok then c.fmaMouseMode=false;return end
            c.fmaMouseOwned=true
        else
            c.fmaMouseOwned=false -- Courseplay/another GUI owns existing cursor
        end
        c.fmaMouseMode=true
        local vehicle=g_currentMission and (g_currentMission.controlledVehicle or g_currentMission.currentVehicle)
        if not vehicle and g_currentMission and g_currentMission.getControlledVehicle then
            local ok,v=pcall(g_currentMission.getControlledVehicle,g_currentMission)
            if ok then vehicle=v end
        end
        -- NEVER write camera.isRotatable. GIANTS or Courseplay owns the camera
        -- and writes to this property may survive a vehicle exit / input switch.

    end
end

-- Input contexts can hide the pointer while Alt+M stays visible. Only restore it
-- when our panel owns input and no native UI/dialog is open. Rate limit to 1 Hz.
function FMAHud.maintainMouse(c)
    if not c or not c.visible or not c.fmaMouseMode then return false end
    if (g_gui and g_gui.getIsGuiVisible and g_gui:getIsGuiVisible()) or
        (g_gui and g_gui.getIsDialogVisible and g_gui:getIsDialogVisible()) then return false end
    if not (g_inputBinding and g_inputBinding.getShowMouseCursor and
            g_inputBinding.setShowMouseCursor) then return false end
    local now=c.now or 0
    if now<(c.fmaCursorCheckAt or 0) then return false end
    c.fmaCursorCheckAt=now+1000
    local ok,shown=pcall(g_inputBinding.getShowMouseCursor,g_inputBinding)
    if not ok or shown~=false then return false end
    local restored=pcall(g_inputBinding.setShowMouseCursor,g_inputBinding,true)
    if restored then c.fmaMouseOwned=true end
    return restored
end

function FMAHud.changePage(c,page)
    if not c then return end
    c.page=page
    c.selection=1
    if FMAHud.isOrderPage(page) then c.fmaTaskListMode=true;c.fmaAdvancedTask=false;c.focusTaskId=nil end
end

function FMAHud.activateTask(c,task)
    if not task or not c.supported then return end
    -- A husbandry deficit without a safe AI loading/unloading path is an
    -- honest inspection task, not a driveable mission. Do not let START turn
    -- its explanatory BLOCKED state into a fake RUNNING task.
    if task.kind=='livestockNeed' then
        c:notify('Nelze spustit automaticky: '..tostring(task.reason or 'Chybí ověřený přístup pro zásobování chovu'))
        return
    end
    if task.kind=='bunkerWorkOrder' and task.blockedByIntegration then
        c:notify('Jáma vyžaduje zásah: '..tostring(task.reason or 'Courseplay nepotvrdil stav silážní jámy'))
        return
    end
    c.runtimePaused=false
    c.lastRuntimeError=nil
    if c.issues then c.issues["runtime"]=nil end
    if task.state=="running" then
        task.ownerApproved=true;task.ownerStopRequested=nil
        c:notify(task.label.." · práce skutečně probíhá")
        return
    end
    if task.state=="assembling" or task.state=="preparing" or task.state=="waiting" or task.state=="starting" then
        c:notify(task.label.." · ještě se připravuje · "..tostring(task.phase or task.reason or "čeká na dokončení přípravy"))
        return
    end
    if task.state=="returning" then
        c:notify(task.label.." · práce skončila, technika se vrací")
        return
    end
    if c.jobFailures then c.jobFailures[task.id]=nil end
    task.state="pending";task.attempts=0;task.failures=0;task.retryAt=0
    task.reason=nil;task.ownerRequested=true;task.ownerApproved=true;task.ownerMarked=nil;task.ownerStopRequested=nil
    if not c.settings.enabled then
        local ok,why=c:enableAutomation()
        if not ok then task.ownerApproved=false;task.ownerRequested=false;task.state="paused";task.reason="START odmítnut · "..tostring(why);c:notify("Příkaz nepřevzat · "..tostring(why));return end
    end
    c:notify("Majitel spustil zakázku: "..task.label)
    c:scan()
    c:dispatch()
end

function FMAHud.layout(inGui)
    -- 1920×1080: below top-right notifications, above bottom-right speedometer;
    -- three operator-selectable positions if another HUD needs the same area.
    local c=FMAHud._controller or g_FMAControllerForMenu
    local p=c and c.settings and c.settings.hudPosition or 0
    if p==1 then return 0.225,0.243,0.545,0.530 end
    if p==2 then return 0.026,0.243,0.545,0.530 end
    return 0.414,0.243,0.545,0.530
end

function FMAHud.panelGeometry(inGui)
    local x,y,w,h=FMAHud.layout(inGui)
    local navWidth=0.112
    local cX=x+navWidth+0.029
    local cW=w-navWidth-0.046
    return {x=x,y=y,w=w,h=h,navX=x+0.012,navW=navWidth,
        contentX=cX,contentW=cW,top=y+h,navTop=y+h-0.149,navStep=0.041,
        listTop=y+h-0.223,listStep=0.047,listSize=4,
        batchX=cX,batchY=y+h-0.194,batchW=cW,batchH=0.032,
        footerY=y+0.015}
end

function FMAHud.inRect(x,y,rx,ry,rw,rh)
    return x>=rx and x<=rx+rw and y>=ry and y<=ry+rh
end

function FMAHud.cyclePreferredVehicle(c,task)
    if not task or not task.operation then return end
    local candidates=FMAHud.mainCandidates(c,task)
    if #candidates==0 then c:notify("Pro tento úkol není žádný vlastněný hlavní stroj / tahač");return end
    local idx=0
    if task.preferredVehicleKey then for i,v in ipairs(candidates) do if v.key==task.preferredVehicleKey then idx=i;break end end end
    idx=idx+1
    if idx>#candidates then task.preferredVehicleKey=nil;task.preferredVehicleName=nil;task.ownerPinnedVehicle=false;c:notify("Výběr hlavního stroje: AUTO")
    else task.preferredVehicleKey=candidates[idx].key;task.preferredVehicleName=candidates[idx].name;task.ownerPinnedVehicle=true;c:notify("Hlavní stroj: "..candidates[idx].name.." ("..machineType(candidates[idx])..")") end
end

function FMAHud.cycleList(task,key,nameKey,candidates,notify,c)
    table.sort(candidates,function(a,b)return a.name<b.name end)
    if #candidates==0 then c:notify("Pro tento slot není žádná vhodná volba");return end
    local current=task[key];local idx=0
    if current then for i,v in ipairs(candidates) do if v.key==current then idx=i;break end end end
    idx=idx+1
    if idx>#candidates then task[key]=nil;task[nameKey]=nil;c:notify(notify..": AUTO")
    else task[key]=candidates[idx].key;task[nameKey]=candidates[idx].name;c:notify(notify..": "..candidates[idx].name) end
end

function FMAHud.cycleJobSlot(c,row)
    local slot=row.object and row.object.slot;local task=row.object and row.object.task
    if not slot then return end
    if slot=='simpleOpen' and task then
        c.focusTaskId=task.id;c.fmaTaskListMode=false;c.fmaAdvancedTask=false;c.selection=1;return
    end
    if slot=='simpleStart' and task then FMAHud.activateTask(c,task);return end
    if slot=='simpleStop' and task then FMAHud.stopTask(c,task);return end
    if slot=='simpleMore' and task then
        c.fmaAdvancedTask=true;c.fmaTaskListMode=false;c.page=9;c.selection=1;return
    end
    if slot=="marketTarget" and task and task.marketAlternatives then
        local options={}
        for _,item in ipairs(task.marketAlternatives) do if item.accessible then options[#options+1]=item end end
        local idx=0
        for i,item in ipairs(options) do if item.station==task.destination then idx=i;break end end
        if #options==0 then c:notify("Žádný prodej s AI vjezdem");return end
        local choice=options[idx%#options+1]
        task.destination=choice.station;task.marketTargetPinned=true;task.pricePerLiter=choice.price
        c:notify("Prodej: "..tostring(choice.name).." · "..math.floor(choice.price*1000+0.5).." / 1000 l")
        return
    end
    if slot=="mark" then
        task.ownerMarked=not task.ownerMarked
        c.focusTaskId=task.id
        c:notify((task.ownerMarked and 'Označeno: ' or 'Odznačeno: ')..task.label)
        return
    end
    if slot=="launchMarked" then
        local marked={}
        for _,t in pairs(c.tasks or {}) do if t.ownerMarked then marked[#marked+1]=t end end
        if #marked==0 then c:notify('Nejprve označ alespoň jednu zakázku');return end
        -- Approve only work with a real executable integration. Diagnostic
        -- deficits remain visible and BLOCKED; approving all must not pretend
        -- the non-existent AI trigger has magically become a drivable goal.
        local runnable,skipped=0,0
        for _,t in ipairs(marked) do
            t.ownerMarked=nil
            if t.kind=='livestockNeed' or (t.kind=='bunkerWorkOrder' and t.blockedByIntegration) then
                skipped=skipped+1
            else
                runnable=runnable+1
                t.ownerApproved=true;t.ownerRequested=true;t.ownerStopRequested=nil
                if t.state=='blocked' or t.state=='paused' or t.state=='cooldown' then
                    t.state='pending';t.reason=nil;t.retryAt=0;t.failures=0
                end
            end
        end
        if runnable==0 then
            c:notify('Nelze spustit: '..skipped..' zakázek nemá ověřenou bezpečnou AI pracovní cestu')
            return
        end
        if not c.settings.enabled then
            local ok,why=c:enableAutomation()
            if not ok then
                for _,t in ipairs(marked) do
                    t.ownerApproved=false;t.ownerMarked=true
                end
                c:notify('Nelze spustit: '..tostring(why));return
            end
        end
        c:notify('Spouštím '..runnable..' vybraných zakázek'..(skipped>0 and (' · '..skipped..' čeká na ověřený přístup') or '')..'; ostatní čekají')
        c:scan();c:dispatch();return
    end
    if slot=="markAll" then
        local all=true
        for _,t in pairs(c.tasks or {}) do if not t.ownerMarked then all=false;break end end
        for _,t in pairs(c.tasks or {}) do t.ownerMarked=not all end
        c:notify(all and 'Označení zrušeno' or 'Označeny všechny zakázky');return
    end
    if slot=="editMarked" then
        local target=c.focusTaskId and c.tasks and c.tasks[c.focusTaskId]
        if not target then c:notify('Označ nejprve zakázku');return end
        c.fmaTaskListMode=false;c.selection=1;return
    end
    if not task then return end
    if slot=="open" then
        c.focusTaskId=task.id;c.fmaTaskListMode=false;c.selection=1
        return
    end
    if slot=="back" then
        if c.fmaAdvancedTask==true then c.fmaAdvancedTask=false;c.fmaTaskListMode=false
        else c.fmaTaskListMode=true end
        c.selection=1;return
    end
    if slot=="start" then FMAHud.activateTask(c,task);return end
    if slot=="mainAuto" then task.preferredVehicleKey=nil;task.preferredVehicleName=nil;task.ownerPinnedVehicle=false;c:notify("Hlavní stroj: AUTO");return end
    if slot=="mainChoice" then
        local candidate=row.object.candidate
        if candidate then task.preferredVehicleKey=candidate.key;task.preferredVehicleName=candidate.name;task.ownerPinnedVehicle=true;c:notify("Hlavní stroj: "..candidate.name.." ("..machineType(candidate)..")") end
        return
    end
    if slot=="implementAuto" then task.preferredImplementKey=nil;task.preferredImplementName=nil;task.ownerPinnedImplement=false;c:notify("Nářadí: AUTO");return end
    if slot=="implementChoice" then
        local candidate=row.object.candidate
        if candidate then task.preferredImplementKey=candidate.key;task.preferredImplementName=candidate.name;task.ownerPinnedImplement=true;c:notify("Nářadí: "..candidate.name) end
        return
    end
    if slot=="main" then FMAHud.cyclePreferredVehicle(c,task);return end
    if slot=="implement" then
        local candidates=FMAHud.implementCandidates(c,task)
        FMAHud.cycleList(task,"preferredImplementKey","preferredImplementName",candidates,"Nářadí",c);return
    end
    if slot=="carrier" then
        local candidates={};for _,tool in ipairs(c.loose or {}) do if FMAHeaderTransport.isCarrier(tool) then candidates[#candidates+1]=tool end end
        FMAHud.cycleList(task,"preferredCarrierKey","preferredCarrierName",candidates,"Podvozek",c);return
    end
    if slot=="supportPower" then
        local candidates={};local fillType=FMAFleetCoordinator and FMAFleetCoordinator.transportFillType(task) or nil
        for _,v in ipairs(c.vehicles or {}) do
            if not v.hasCombine and v.hasAttacherJoints and not c.excluded[v.key] then
                local suitable=v.capabilities and v.capabilities.transport and (not FMAFleetCoordinator or FMAFleetCoordinator.supportsTransportFillType(v,fillType))
                if not suitable then
                    for _,tool in ipairs(c.loose or {}) do
                        if tool.capabilities and tool.capabilities.transport and (not FMAFleetCoordinator or FMAFleetCoordinator.supportsTransportFillType(tool,fillType)) and FMAAssembler.findJointPair(v.object,tool.object,c.farmId) then suitable=true;break end
                    end
                end
                if suitable then candidates[#candidates+1]=v end
            end
        end
        task.preferredSupportKeys=task.preferredSupportKeys or {};task.preferredSupportNames=task.preferredSupportNames or {}
        local index=row.object.index
        local wrapper={preferred=task.preferredSupportKeys[index]}
        table.sort(candidates,function(a,b)return a.name<b.name end)
        local pos=0;if wrapper.preferred then for i,v in ipairs(candidates) do if v.key==wrapper.preferred then pos=i;break end end end
        pos=pos+1
        if pos>#candidates then task.preferredSupportKeys[index]=nil;task.preferredSupportNames[index]=nil;c:notify("Traktor odvozu "..index..": AUTO")
        else task.preferredSupportKeys[index]=candidates[pos].key;task.preferredSupportNames[index]=candidates[pos].name;c:notify("Traktor odvozu "..index..": "..candidates[pos].name) end
        return
    end
    if slot=="supportTool" then
        local candidates={};local fillType=FMAFleetCoordinator and FMAFleetCoordinator.transportFillType(task) or nil
        local selectedPower=task.preferredSupportKeys and task.preferredSupportKeys[row.object.index]
        local power=nil;if selectedPower then for _,v in ipairs(c.vehicles or {}) do if v.key==selectedPower then power=v;break end end end
        for _,tool in ipairs(c.loose or {}) do
            if tool.capabilities and tool.capabilities.transport and (not FMAFleetCoordinator or FMAFleetCoordinator.supportsTransportFillType(tool,fillType))
                and (not power or FMAAssembler.findJointPair(power.object,tool.object,c.farmId)) then candidates[#candidates+1]=tool end
        end
        task.preferredSupportToolKeys=task.preferredSupportToolKeys or {};task.preferredSupportToolNames=task.preferredSupportToolNames or {}
        local index=row.object.index;local current=task.preferredSupportToolKeys[index];local pos=0
        table.sort(candidates,function(a,b)return a.name<b.name end)
        if current then for i,v in ipairs(candidates) do if v.key==current then pos=i;break end end end
        pos=pos+1
        if pos>#candidates then task.preferredSupportToolKeys[index]=nil;task.preferredSupportToolNames[index]=nil;c:notify("Vůz odvozu "..index..": AUTO")
        else task.preferredSupportToolKeys[index]=candidates[pos].key;task.preferredSupportToolNames[index]=candidates[pos].name;c:notify("Vůz odvozu "..index..": "..candidates[pos].name) end
        return
    end
end

-- Full-size central card terminal; the old click-through sidebar is gone.
function FMAHud.cardGeometry()
    local x,y,w,h=0.148,0.125,0.704,0.748
    return {x=x,y=y,w=w,h=h,top=y+h,
        left=x+0.027,right=x+w-0.027,
        gridBottom=y+0.195,gridTop=y+h-0.204,
        cols=3,cellW=0.203,cellH=0.125,gapX=0.019,gapY=0.013,
        backX=x+0.028,backY=y+0.047,backW=0.151,backH=0.047,
        actionX=x+w-0.228,actionY=y+0.047,actionW=0.200,actionH=0.047,
        prevX=x+w-0.197,prevY=y+h-0.198,nextX=x+w-0.110,nextY=y+h-0.198}
end
function FMAHud.cardRect(d,index)
    local col=(index-1)%3
    local row=math.floor((index-1)/3)
    return d.left+col*(d.cellW+d.gapX),d.gridTop-(row+1)*d.cellH-row*d.gapY,d.cellW,d.cellH
end
function FMAHud.mouseEvent(c,px,py,isDown,isUp,button)
    if not c or not c.visible or not c.fmaMouseMode then return false end
    if g_gui and g_gui.getIsGuiVisible and g_gui:getIsGuiVisible() then return false end
    if g_gui and g_gui.getIsDialogVisible and g_gui:getIsDialogVisible() then return false end
    if type(px)~='number' or type(py)~='number' then return false end
    local d=FMAHud.cardGeometry()
    if not FMAHud.inRect(px,py,d.x,d.y,d.w,d.h) then return false end
    local up=Input and Input.MOUSE_BUTTON_WHEEL_UP
    local down=Input and Input.MOUSE_BUTTON_WHEEL_DOWN
    if (button==up and up) or (button==down and down) then
        if not c.fmaCardHome then
            local rows=FMAHud.rows(c)
            local pages=math.max(1,math.ceil(#rows/6))
            local page=math.floor((c.fmaCardOffset or 0)/6)
            page=math.max(0,math.min(pages-1,page+(button==down and 1 or -1)))
            c.fmaCardOffset=page*6
        end
        return true
    end
    if not isDown then return false end
    if Input and Input.MOUSE_BUTTON_LEFT and button~=Input.MOUSE_BUTTON_LEFT then return false end
    -- No keyboard interception. Visible buttons and positions match the render.
    if FMAHud.inRect(px,py,d.x+d.w-0.062,d.top-0.070,0.038,0.045) then
        FMAHud.setVisible(c,false);return true
    end
    if FMAHud.inRect(px,py,d.x+d.w-0.220,d.top-0.070,0.142,0.045) then
        if c.toggle then c:toggle() end
        return true
    end
    if c.fmaCardHome~=false then
        if FMAHud.inRect(px,py,d.actionX,d.actionY,d.actionW,d.actionH) then
            c.fmaCardHome=false;c.fmaCardFilter=nil;c.fmaCardOffset=0
            FMAHud.changePage(c,9);return true
        end
        for index,card in ipairs(FMAHud.cards) do
            local xx,yy,ww,hh=FMAHud.cardRect(d,index)
            if FMAHud.inRect(px,py,xx,yy,ww,hh) then
                FMAHud.openCard(c,card);return true
            end
        end
        return true
    end
    if FMAHud.inRect(px,py,d.backX,d.backY,d.backW,d.backH) then
        if c.page==9 and c.fmaTaskListMode==false then
            c.fmaTaskListMode=true;c.fmaAdvancedTask=false;c.selection=1;c.fmaCardOffset=0
        else c.fmaCardHome=true;c.fmaCardOffset=0 end
        return true
    end
    local rows=FMAHud.rows(c)
    local offset=math.max(0,c.fmaCardOffset or 0)
    local last=math.max(0,math.floor((math.max(#rows,1)-1)/6))*6
    if c.page==10 and FMAHud.inRect(px,py,d.left+0.31,d.top-0.198,0.105,0.039) then
        c.fmaCardMapView=not c.fmaCardMapView
        return true
    end
    if FMAHud.inRect(px,py,d.prevX,d.prevY,0.073,0.039) then
        c.fmaCardOffset=math.max(0,offset-6);return true
    end
    if FMAHud.inRect(px,py,d.nextX,d.nextY,0.074,0.039) then
        c.fmaCardOffset=math.min(last,offset+6);return true
    end
    if c.page==10 and c.fmaCardMapView then return true end
    for index=1,6 do
        local row=rows[offset+index]
        if row then
            local xx,yy,ww,hh=FMAHud.cardRect(d,index)
            if FMAHud.inRect(px,py,xx,yy,ww,hh) then
                c.selection=offset+index
                -- Read-only opening is immediate. Destructive actions require
                -- their own explicit START/STOP card or bottom action button.
                local slot=row.object and row.object.slot
                if slot=='simpleOpen' or slot=='simpleStart' or slot=='simpleStop'
                    or slot=='simpleMore' or slot=='back' or slot=='navigatePage'
                    or slot=='devPhysical' or slot=='devStop' then
                    FMAHud.select(c)
                    c.fmaCardOffset=0
                end
                return true
            end
        end
    end
    if FMAHud.inRect(px,py,d.actionX,d.actionY,d.actionW,d.actionH) then
        if c.page==10 and c.fmaCardMapView then
            c.fmaCardMapView=false
        elseif c.page==9 and c.fmaTaskListMode~=false then
            FMAHud.cycleJobSlot(c,{object={slot='launchMarked'}})
        else
            FMAHud.select(c)
        end
        return true
    end
    return true
end

function FMAHud.select(c)
    local row=FMAHud.rows(c)[c.selection]
    if not row or not c.supported then return end
    if c.page==2 then
        local p=c.policies[row.id];p.enabled=not p.enabled
        if not p.enabled then FMAHud.stopMatching(c,function(a) return a.task.fieldId==row.id end) end
    elseif c.page==3 then
        if row.id==nil then c:notify("Souhrn inventury · vyber konkrétní stroj nebo nářadí");return end
        if row.kind=="tool" then c:notify("Nářadí je v inventáři; výběr pro konkrétní práci uděláš na kartě Zakázka");return end
        c.excluded[row.id]=not c.excluded[row.id]
        if c.excluded[row.id] then
            local route=c.routes[row.id]
            if route then route.enabled=false;route.phase="idle" end
            FMAHud.stopMatching(c,function(a) return a.vehicle.key==row.id end)
            local tool=FMAAutoRoute.tool(row.object.object)
            if tool then tool:ualStopLoad() end
            c.reservations[row.id]=nil
        end
    elseif c.page==5 and row.object and row.object.kind=="bunker" then
        if FMABunkerCoordinator and FMABunkerCoordinator.cycleSelection then
            FMABunkerCoordinator.cycleSelection(c,row.object.index)
            if c.save then c:save() end
            c:scan()
        end
        return
    elseif c.page==6 and row.object and row.object.slot=='devPhysical' then
        if not FMADevLab then c:notify('Vývojový modul není načten');return end
        local ok,reason=FMADevLab.beginPhysical(c)
        c:notify((ok and 'DEV TEST: ' or 'DEV TEST ODMÍTNUT: ')..tostring(reason));return
    elseif c.page==6 and row.object and row.object.slot=='devStop' then
        if FMADevLab then FMADevLab.stop(c) end
        c:notify('Vývojový test zastaven');return
    elseif c.page==6 and row.object and row.object.runPassiveTest then
        if FMATestSuite then FMATestSuite.run(c) end
        if c.diagnostics then c:diagnostics(false) end
        return
    elseif c.page==6 and row.object and row.object.purchase then
        local need=row.object.purchase
        need.approved=not need.approved
        need.status=need.approved and "APPROVED" or "WAIT_APPROVAL"
        c.approvedPurchases=c.approvedPurchases or {};if need.operation then c.approvedPurchases[need.operation]=need.approved or nil end
        c:notify((need.approved and "Schválen nákupní požadavek: " or "Zrušeno schválení: ")..tostring(need.label))
        c.diagnosticDirty=true
        return
    elseif c.page==7 then
        local route=c.routes[row.id]
        if not route or not route.load or not route.unload then c:notify("Nejprve ulož oba body trasy ze soupravy");return end
        if not FMAAutoRoute.tool(row.object.object) or not FMAAutoRoute.unloadAPI() then c:notify("Trasa vyžaduje podporované rozhraní Universal Autoload");return end
        route.enabled=not route.enabled;route.phase=route.phase or "idle";route.reason=nil
        if route.enabled then route.phase="idle";route.retryAt=0
        else
            FMAHud.stopMatching(c,function(a) return a.vehicle.key==row.id end)
            local tool=FMAAutoRoute.tool(row.object.object)
            if tool then tool:ualStopLoad() end
            c.reservations[row.id]=nil;route.phase="idle"
        end
    elseif c.page==11 and row.object and row.object.navAction then
        if row.object.navAction=='refresh' then c:refresh();c:notify('Navigace / mapa znovu prověřeny')
        elseif row.object.navAction=='position' then c.settings.hudPosition=((c.settings.hudPosition or 0)+1)%3;c:notify('Panel přemístěn') end
        return
    elseif c.page==10 and row.object and row.object.mapAction then
        local action=row.object.mapAction
        if action=="anchor" and FMAFarmSurvey then
            local vehicle=FMAFarmSurvey.playerVehicle(c)
            if vehicle then
                local x,z=FMAUtil.position(vehicle)
                local ok,why=FMAFarmSurvey.anchor(c,{x=x,z=z})
                c:notify(ok and "Střed dvora zaměřen podle tvého traktoru" or tostring(why))
            else c:notify("Pro zaměření středu sedni do vlastního traktoru na dvoře") end
        elseif action=="zoom" then
            local values={80,120,180,240,320,420};local index=1
            for i,v in ipairs(values) do if v==c.settings.surveyViewRadius then index=i;break end end
            c.settings.surveyViewRadius=values[index%#values+1];c:notify("Měřítko mapy: "..c.settings.surveyViewRadius.." m")
        elseif action=="preview" and FMAFarmSurvey then
            local _,message=FMAFarmSurvey.previewNext(c);c:notify(message)
        elseif action=="toggle" then c.settings.surveyEnabled=not c.settings.surveyEnabled;c:notify(c.settings.surveyEnabled and "Živé mapování zapnuto" or "Živé mapování vypnuto")
        elseif action=="parkVehicle" and FMAParkingManager then local ok,why=FMAParkingManager.teach(c,'vehicle');if not ok then c:notify(why) end
        elseif action=="parkTool" and FMAParkingManager then local ok,why=FMAParkingManager.teach(c,'tool');if not ok then c:notify(why) end
        elseif action=="organize" and FMAParkingManager then
            if c.parkingOrganize then c.parkingOrganize=false;c:notify('Uspořádání zastaveno · rozjeté AI dojíždí bezpečně')
            else local ok,why=FMAParkingManager.organize(c);if not ok then c:notify(why) end end
        elseif action=="removePark" and FMAParkingManager then local ok,why=FMAParkingManager.removeLast(c);if not ok then c:notify(why) end
        elseif action=="role" and FMATeach then FMATeach.cycleRole(c)
        elseif action=="point" and FMATeach then local ok,why=FMATeach.learnPoint(c);if not ok then c:notify(why) end
        elseif action=="route" and FMATeach then local ok,why=FMATeach.toggleRoute(c);if not ok then c:notify(why) end
        elseif action=="clear" and FMATeach then if not FMATeach.clearLast(c) then c:notify("Není co smazat") end end
        if FMAFarmBrain and FMAFarmBrain.buildDigitalMap then FMAFarmBrain.buildDigitalMap(c) end
        return
    elseif c.page==8 then
        if row.object and row.object.slot=='navigatePage' then FMAHud.changePage(c,row.object.page);return end
        local option=row.object
        if option.values then
            local current=1
            for i,value in ipairs(option.values) do if value==c.settings[option.key] then current=i;break end end
            c.settings[option.key]=option.values[current%#option.values+1]
        else c.settings[option.key]=not c.settings[option.key] end
    elseif FMAHud.isOrderPage(c.page) and row.object and row.object.slot then
        FMAHud.cycleJobSlot(c,row);return
    elseif c.page==1 and row.object then
        c.focusTaskId=row.object.id
        c.page=9
        c.fmaTaskListMode=false
        c.selection=1
        c:notify("Zakázka otevřena: "..row.object.label.." · vyber sestavu myší a potvrď kliknutím")
        return
    end
    c:scan()
end

function FMAHud.changeCrop(c)
    if c.page~=2 then return end
    local row=FMAHud.rows(c)[c.selection]
    if not row then return end
    local policy=c.policies[row.id]
    local crops=FMACatalog.availableCrops and FMACatalog.availableCrops() or FMACatalog.crops
    if #crops==0 then return end
    local current=0
    for i,name in ipairs(crops) do if name==policy.crop then current=i;break end end
    for offset=1,#crops do
        local nextName=crops[(current+offset-1)%#crops+1]
        if FMAUtil.fruit(nextName) then policy.crop=nextName;break end
    end
    c:scan()
end

local function cardStatus(status)
    if status=='blocked' then return 'BLOKOVÁNO',0.99,0.55,0.43 end
    if status=='running' then return 'PRACUJE',0.49,0.91,0.64 end
    if status=='assembling' or status=='starting' or status=='preparing' then return 'PŘIPRAVUJE',0.99,0.79,0.37 end
    if status=='returning' then return 'VRACÍ SE',0.47,0.80,1.0 end
    if status=='done' then return 'HOTOVO',0.60,0.91,0.71 end
    if status=='paused' then return 'ZASTAVENO',0.99,0.61,0.61 end
    return 'ČEKÁ',0.70,0.84,0.96
end
function FMAHud.draw(c,overlay)
    if not c or not overlay then return end
    local guiVisible=g_gui and g_gui.getIsGuiVisible and g_gui:getIsGuiVisible() or false
    local dialogVisible=g_gui and g_gui.getIsDialogVisible and g_gui:getIsDialogVisible() or false
    if guiVisible or dialogVisible then return end
    local function rect(x,y,w,h,r,g,b,a)
        overlay:setPosition(x,y);overlay:setDimension(w,h);overlay:setColor(r,g,b,a or 1);overlay:render()
    end
    local function txt(x,y,size,value,r,g,b,strong,maxW)
        local valueText=tostring(value or '')
        if maxW and getTextWidth then
            local count=0
            while count<55 and #valueText>3 do
                local ok,width=pcall(getTextWidth,size,valueText)
                if not ok or not width or width<=maxW then break end
                valueText=FMAUtil.limit(valueText,math.max(3,#valueText-3))
                count=count+1
            end
        end
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextBold(strong==true)
        setTextColor(r or 0.92,g or 0.95,b or 0.96,1)
        renderText(x,y,size,valueText)
    end
    if not c.visible then
        -- Compact status only; never commandeer the screen or player's cursor.
        local working=FMAUtil.count(c.active or {})
        rect(0.362,0.016,0.301,0.040,0.025,0.055,0.066,0.92)
        txt(0.373,0.029,0.0125,'DRUŽSTVO · '..(c.settings and c.settings.enabled and 'AUTO ZAP' or 'AUTO VYP')..' · '..working..' čet · Alt+M',0.86,0.96,0.98,true)
        setTextBold(false);setTextColor(1,1,1,1)
        return
    end
    FMAHud.maintainMouse(c)
    local d=FMAHud.cardGeometry()
    rect(d.x,d.y,d.w,d.h,0.018,0.042,0.056,0.98)
    rect(d.x+0.007,d.y+0.009,d.w-0.014,d.h-0.018,0.035,0.075,0.093,1)
    rect(d.x,d.top-0.009,d.w,0.009,0.24,0.77,0.78,1)
    txt(d.x+0.032,d.top-0.063,0.029,'FARM MANAGER',0.96,0.99,1,true)
    txt(d.x+0.033,d.top-0.094,0.014,'AUTONOMNÍ DISPEČINK DRUŽSTVA',0.61,0.83,0.90)
    rect(d.x+d.w-0.220,d.top-0.070,0.142,0.045,
        c.settings and c.settings.enabled and 0.11 or 0.26,
        c.settings and c.settings.enabled and 0.36 or 0.17,0.25,1)
    txt(d.x+d.w-0.206,d.top-0.056,0.016,c.settings and c.settings.enabled and 'AUTO ZAP' or 'AUTO VYP',0.94,0.99,0.94,true)
    rect(d.x+d.w-0.062,d.top-0.070,0.038,0.045,0.42,0.13,0.16,1)
    txt(d.x+d.w-0.050,d.top-0.057,0.018,'X',1,0.96,0.94,true)
    local working=FMAUtil.count(c.active or {})
    local issues=c.issueCounts and c:issueCounts() or {error=0,action=FMAUtil.count(c.issues or {})}
    txt(d.left,d.top-0.129,0.013,'AKTIVNÍ ČETY '..working..'     CHYBY '..(issues.error or 0)..'     K ŘEŠENÍ '..(issues.action or 0),0.73,0.89,0.95,true)
    rect(d.left,d.top-0.149,d.right-d.left,0.0015,0.20,0.36,0.43,1)
    if c.fmaCardHome~=false then
        for index,card in ipairs(FMAHud.cards) do
            local xx,yy,ww,hh=FMAHud.cardRect(d,index)
            rect(xx,yy,ww,hh,0.076,0.139,0.172,1)
            rect(xx,yy,ww,0.004,card.tint[1],card.tint[2],card.tint[3],1)
            FMAHud.drawIcon(card.icon,xx+0.014,yy+0.057,0.051,0.066)
            txt(xx+0.072,yy+0.093,0.015,card.label,0.95,0.99,1,true,ww-0.079)
            txt(xx+0.072,yy+0.063,0.0105,card.description,0.72,0.87,0.92,false,ww-0.079)
            local taskCount=0;local blocking=0
            if card.filter then
                for _,task in pairs(c.tasks or {}) do
                    if FMAHud.taskGroup(task)==card.filter then
                        taskCount=taskCount+1
                        if task.state=='blocked' then blocking=blocking+1 end
                    end
                end
            end
            if card.filter then
                txt(xx+0.014,yy+0.018,0.012,taskCount..' zakázek  ·  '..blocking..' blokací',0.67,0.96,0.85,false,ww-0.030)
            else
                txt(xx+0.014,yy+0.018,0.012,'OTEVŘÍT  >',0.62,0.94,0.92,true)
            end
        end
        txt(d.left,d.y+0.088,0.012,'Klikni na kartu. Samotné otevření nikdy nespustí zakázku.',0.74,0.88,0.92)
        rect(d.actionX,d.actionY,d.actionW,d.actionH,0.12,0.40,0.30,1)
        txt(d.actionX+0.009,d.actionY+0.016,0.012,'VŠECHNY ZAKÁZKY',0.94,0.99,0.94,true)
    else
        local category='PŘEHLED'
        if c.page==9 then
            category=({field='POLNÍ PRÁCE',harvest='SKLIZEŇ',livestock='ZVÍŘATA',bunker='SILÁŽ'})[c.fmaCardFilter] or 'ZAKÁZKY'
            if c.fmaTaskListMode==false then category='DETAIL ZAKÁZKY' end
        else
            for _,card in ipairs(FMAHud.cards) do if card.page==c.page and not card.filter then category=card.label;break end end
        end
        txt(d.left,d.top-0.185,0.021,category,0.95,0.99,1,true)
        local rows=FMAHud.rows(c)
        c.selection=math.max(1,math.min(c.selection or 1,math.max(#rows,1)))
        local offset=math.max(0,c.fmaCardOffset or 0)
        local totalPages=math.max(1,math.ceil(#rows/6))
        local nowPage=math.floor(offset/6)+1
        txt(d.right-0.270,d.top-0.174,0.012,nowPage..' / '..totalPages..' · '..#rows..' položek',0.73,0.91,0.95)
        if c.page==10 then
            rect(d.left+0.31,d.top-0.198,0.105,0.039,0.12,0.37,0.32,1)
            txt(d.left+0.321,d.top-0.185,0.011,'MAPA / AKCE',0.93,0.98,0.92,true)
        end
        rect(d.prevX,d.prevY,0.073,0.039,0.10,0.24,0.32,1)
        rect(d.nextX,d.nextY,0.074,0.039,0.10,0.24,0.32,1)
        txt(d.prevX+0.027,d.prevY+0.011,0.015,'<',0.96,0.98,1,true)
        txt(d.nextX+0.026,d.nextY+0.011,0.015,'>',0.96,0.98,1,true)
        if c.page==10 and c.fmaCardMapView and FMAFarmSurvey and FMAFarmSurvey.draw then
            FMAFarmSurvey.draw(c,overlay,{x=d.left,y=d.y+0.235,w=d.right-d.left,h=0.418},rect,txt)
            txt(d.left,d.y+0.224,0.012,'Živá mapa dvora · jen ověřené body a trasy',0.72,0.91,0.93)
        else
        for i=1,6 do
            local index=offset+i
            local row=rows[index]
            if row then
                local xx,yy,ww,hh=FMAHud.cardRect(d,i)
                local selected=c.selection==index
                local rr,gg,bb=selected and 0.13 or 0.075,selected and 0.25 or 0.142,selected and 0.29 or 0.18
                local tag,sr,sg,sb=cardStatus(row.status)
                local slot=row.object and row.object.slot
                if slot=='simpleStart' then tag='SPUSTIT';sr,sg,sb=0.59,1,0.66 end
                if slot=='simpleStop' then tag='ZASTAVIT';sr,sg,sb=1,0.60,0.61 end
                rect(xx,yy,ww,hh,rr,gg,bb,1)
                rect(xx,yy+hh-0.005,ww,0.005,sr*0.7,sg*0.7,sb*0.7,1)
                local rowIcon=row.icon
                if not rowIcon and row.object and row.object.task then
                    local group=FMAHud.taskGroup(row.object.task)
                    rowIcon=({harvest='combine',livestock='cow',bunker='silo',field='tractor'})[group]
                end
                if rowIcon then FMAHud.drawIcon(rowIcon,xx+ww-0.058,yy+0.073,0.043,0.048) end
                txt(xx+0.012,yy+0.091,0.0145,row.title,0.96,0.99,1,true,ww-(rowIcon and 0.073 or 0.026))
                txt(xx+0.012,yy+0.068,0.011,tag,sr,sg,sb,true,ww-0.024)
                local description=tostring(row.detail or '')
                txt(xx+0.012,yy+0.043,0.0105,FMAUtil.limit(description,60),0.70,0.85,0.91,false,ww-0.026)
                if slot=='simpleOpen' then txt(xx+0.012,yy+0.015,0.0115,'DETAIL  >',0.56,0.96,0.90,true)
                elseif slot=='simpleStart' or slot=='simpleStop' then txt(xx+0.012,yy+0.015,0.0115,'POTVRDIT KLIKEM',0.79,0.98,0.88,true)
                else txt(xx+0.012,yy+0.015,0.011,'VYBRAT',0.63,0.83,0.92) end
            end
        end
        end -- Grid versus farm map
        if #rows==0 and not (c.page==10 and c.fmaCardMapView) then
            txt(d.left,d.y+0.435,0.019,'V této sekci nejsou žádné zakázky.',0.73,0.87,0.92,true)
        end
        rect(d.backX,d.backY,d.backW,d.backH,0.13,0.24,0.32,1)
        txt(d.backX+0.020,d.backY+0.016,0.013,'< ZPĚT',0.94,0.99,1,true)
        rect(d.actionX,d.actionY,d.actionW,d.actionH,0.12,0.40,0.30,1)
        if c.page==10 and c.fmaCardMapView then
            txt(d.actionX+0.012,d.actionY+0.016,0.012,'ZPĚT NA AKCE',0.94,0.99,0.94,true)
        elseif c.page==9 and c.fmaTaskListMode~=false then
            txt(d.actionX+0.012,d.actionY+0.016,0.012,'SPUSTIT VYBRANÉ',0.94,0.99,0.94,true)
        else
            txt(d.actionX+0.014,d.actionY+0.016,0.013,'PROVÉST VÝBĚR',0.94,0.99,0.94,true)
        end
        local row=rows[c.selection]
        if row then
            txt(d.left+0.175,d.y+0.069,0.010,'VYBRÁNO: '..FMAUtil.limit(row.title,48),0.76,0.89,0.93,false,0.26)
        end
    end
    txt(d.left,d.y+0.020,0.011,'Alt+M zavřít  ·  Alt+H AUTO  ·  Alt+D report  ·  E a řízení ovládá hra',0.62,0.79,0.85)
    setTextBold(false);setTextColor(1,1,1,1)
end
