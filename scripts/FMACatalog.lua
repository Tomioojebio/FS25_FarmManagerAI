FMACatalog = {}
FMACatalog.operations = {
    harvest = {label="Sklizeň", priority=90, cap="harvest", categories={"HARVESTERS","CUTTERS"}},
    mow = {label="Sečení trávy", priority=80, cap="mow", categories={"MOWERS"}},
    plow = {label="Orba", priority=65, cap="plow", categories={"PLOWS","SUBSOILERS"}},
    cultivate = {label="Příprava půdy", priority=60, cap="cultivate", categories={"CULTIVATORS","DISCHARROWS","POWERHARROWS"}},
    sow = {label="Setí", priority=70, cap="sow", categories={"SOWINGMACHINES","PLANTERS"}},
    fertilize = {label="Hnojení", priority=55, cap="fertilize", categories={"FERTILIZERSPREADERS","SPRAYERS"}},
    weed = {label="Odplevelení", priority=58, cap="weed", categories={"WEEDERS"}},
    lime = {label="Vápnění", priority=64, cap="lime", categories={"FERTILIZERSPREADERS"}},
    roll = {label="Válení", priority=53, cap="roll", categories={"ROLLERS"}},
    stone = {label="Sběr kamenů", priority=62, cap="stone", categories={"STONEPICKERS"}},
    supply = {label="Zásobování", priority=95, cap="transport", categories={"TRAILERS","ANIMALS","SLURRYTANKS"}},
    ted = {label="Obracení", priority=74, cap="ted", categories={"TEDDERS"}},
    windrow = {label="Shrnování", priority=73, cap="windrow", categories={"WINDROWERS"}},
    bale = {label="Lisování", priority=72, cap="bale", categories={"BALERS"}},
    baleWrap = {label="Ovíjení balíků", priority=71, cap="baleWrap", categories={"BALEWRAPPERS"}},
    baleCollect = {label="Sběr balíků", priority=70, cap="baleCollect", categories={"BALELOADERS"}},
    foragePickup = {label="Sběr řádků", priority=72, cap="foragePickup", categories={"FORAGEWAGONS"}},
    mixFeed = {label="Míchání TMR", priority=98, cap="mixFeed", categories={"ANIMALS"}},
    compact = {label="Hutnění siláže", priority=86, cap="compact", categories={"SILOCOMPACTORS","LEVELERS"}}
}
FMACatalog.crops = {"WHEAT","BARLEY","OAT","CANOLA","SOYBEAN","SORGHUM","MAIZE","GRASS"}
FMACatalog.cropLabels = {WHEAT="Pšenice",BARLEY="Ječmen",OAT="Oves",CANOLA="Řepka",SOYBEAN="Sója",SORGHUM="Čirok",MAIZE="Kukuřice",GRASS="Tráva"}
-- Keep the historical names as a safe offline fallback. The actual list comes
-- from the currently loaded map, so a different map or modded fruit type is not
-- silently excluded from the sowing selector. This does not imply that a given
-- seeder is compatible with every listed fruit; equipment validation is separate.
function FMACatalog.availableCrops()
    local manager=g_fruitTypeManager
    local fruitTypes=manager and FMAUtil and FMAUtil.call(manager,'getFruitTypes') or nil
    if type(fruitTypes)~='table' then return FMACatalog.crops end
    local available,seen={},{}
    local function add(name,desc)
        if type(name)~='string' or name=='' or seen[name] then return end
        if type(desc)~='table' or desc.allowsSeeding~=true then return end
        seen[name]=true;available[#available+1]=name
        if not FMACatalog.cropLabels[name] then
            local title=desc.title
            FMACatalog.cropLabels[name]=(type(title)=='string' and title~='' and title) or name
        end
    end
    -- Familiar crops first, when the current map actually supports their sowing.
    for _,name in ipairs(FMACatalog.crops) do
        add(name,FMAUtil.fruit(name))
    end
    local extra={}
    for _,desc in pairs(fruitTypes) do
        if type(desc)=='table' and type(desc.name)=='string' and not seen[desc.name]
            and desc.allowsSeeding==true then extra[#extra+1]=desc end
    end
    table.sort(extra,function(a,b)return a.name<b.name end)
    for _,desc in ipairs(extra) do add(desc.name,desc) end
    -- Fail closed when the manager has no valid map crops; don't propose
    -- invented crops merely because a static default exists.
    return available
end
FMACatalog.statusLabels = {pending="Čeká",running="Pracuje",blocked="Zásah majitele",starting="Čeká na potvrzení AI",cooldown="Kontrola výsledku",done="Ověřeno",paused="Pozastaveno",stageComplete="AI etapa provedena (bez záruky plného pokrytí)",assembling="Připravuje soupravu",returning="Vrací techniku"}
FMACatalog.requirements = {
    harvest="Kombajn/řezačka + adaptér kompatibilní s aktuální plodinou",
    mow="Žací stroj / žací kombinace",
    plow="Pluh nebo podrývák",
    cultivate="Kultivátor / diskové nářadí / rotační brány",
    sow="Secí stroj podporující zvolenou plodinu",
    fertilize="Hnojicí technika s podporou příslušného hnojiva",
    weed="Plečka / odplevelovací nářadí",
    lime="Rozmetadlo, které runtime FS25 výslovně hlásí jako kompatibilní s vápnem",
    roll="Polní válec",
    stone="Sběrač kamenů",
    supply="Tahač + přepravní nářadí kompatibilní s nákladem",
    ted="Obraceč",
    windrow="Shrnovač",
    bale="Lis",
    baleWrap="Ovíječka",
    baleCollect="Sběrač / autoload balíků",
    foragePickup="Sběrací vůz nebo řezačka + sběrací adaptér",
    mixFeed="Míchací krmný vůz kompatibilní s recepturou mapy",
    compact="Vhodný těžký stroj / nahrnovač pro silážní jámu"
}
function FMACatalog.requirement(operation)
    return FMACatalog.requirements[operation] or ((FMACatalog.operations[operation] and FMACatalog.operations[operation].label) or tostring(operation))
end

function FMACatalog.recommend(operation, maxResults, categoryOverride)
    local op = FMACatalog.operations[operation]
    if op == nil then return {} end
    local categories = {}
    for _, c in ipairs(categoryOverride or op.categories) do categories[c] = true end
    local matches = {}
    for _, item in pairs(FMAUtil.call(g_storeManager,"getItems") or {}) do
        local match = false
        for _, c in pairs(item.categoryNames or {item.categoryName}) do
            if categories[string.upper(tostring(c))] then match = true end
        end
        if match and item.showInStore ~= false and (tonumber(item.price) or 0) > 0 then
            local name = item.name
            if type(name) == "table" then name = name.cz or name.en or next(name) end
            matches[#matches+1] = {name=tostring(name or item.xmlFilename), price=item.price,
                file=item.xmlFilename, mod=item.customEnvironment}
        end
    end
    table.sort(matches,function(a,b)
        if a.price == b.price then return a.name < b.name end
        return a.price < b.price
    end)
    while #matches > (maxResults or 3) do table.remove(matches) end
    return matches
end
