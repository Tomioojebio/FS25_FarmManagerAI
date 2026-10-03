-- A bounded, evidence-based operational memory. No invented driving/physics, no
-- vehicle movement, no external I/O. Only a verified work order counts as success.
FMAExperience = {VERSION='0.20.15.0', LIMIT=120}

local function contains(haystack,patterns)
    for _,word in ipairs(patterns) do
        if string.find(haystack,word,1,true) then return true end
    end
    return false
end

function FMAExperience.classify(reason)
    local s=string.lower(tostring(reason or ''))
    -- Permanent/safety preconditions take precedence over tempting generic words.
    if contains(s,{'déle než 5 minut','překročilo 5 minut','timed out','timeout'}) then return 'EXHAUSTED',false end
    if contains(s,{'majitel','hráč','rucni','ruční','manual','player takeover','pozastaven'}) then return 'PLAYER',false end
    if contains(s,{'vlastníkem','vlastnictv','majitele stroje','změnil majitele','not owned','ownership'}) then return 'OWNERSHIP',false end
    if contains(s,{'neznámá operace','neznámý typ','jobtypeindex','invalid job type','registr typů','neplatný registrovaný'}) then return 'CONFIG',false end
    if contains(s,{'chybí vlastní','chybí vhodn','není kompatibilní','not compatible','nedostatečný výkon','potřebné nářadí','není připojený','nářadí chybí'}) then return 'EQUIPMENT',false end
    if contains(s,{'není ověřena finanční','rezerva','nedostatek peněz','money','rozpočet','stock empty'}) then return 'BUDGET',false end
    if contains(s,{'prázdná nádrž','žádné osivo','nemá dostatek','není dostupná náplň','chybí materiál','není skladem','není voda'}) then return 'SUPPLY',false end
    if contains(s,{'začala jiná ai','busy','obsazen','provoz','přednost','traffic','čeká na uvolnění'}) then return 'TRAFFIC',true end
    if contains(s,{'nepohnul','nepohybuje','bez pohybu','stall','zasekl','uvíz','překážk','cannot reach','no path','pathfinder','cesta','trasa','nájezd','zablokovaná brána','drive-to','blocked road','road blocked','stuck','brání objekt','objekt brání','objekt překáží','překáží objekt','object blocking','blocked by object','object in the way','object obstruct','kola se točí','otáčí kola','bez posunu'}) then return 'ROUTE',true end
    if contains(s,{'ai odmítl','ai odmítlo','start odmítnut','spuštění ai','nepotvrdilo převzetí','start rejected','worker failed','ai nahlásila chybu'}) then return 'START',true end
    if contains(s,{'připnut','připojen','zapřaž','attachment','hitch'}) then return 'ATTACH',false end -- handled by physical assembler
    return 'UNKNOWN',false
end

local advice={
    PLAYER='Majitel řídí stroj. Automatika ho nepřevezme násilím.',
    OWNERSHIP='Ověř vlastnictví. Cizí techniku Manager nepoužije.',
    CONFIG='Chybí platná registrace AI/modu; automatický pokus by mohl poškodit uloženou pozici.',
    EQUIPMENT='Prověř správné nářadí/adaptér, výkon a fyzické připojení.',
    BUDGET='Chybí volné prostředky nebo nelze ověřit finanční rezervu.',
    SUPPLY='Zkus jiný kompatibilní fyzický zdroj; bez ověřené náplně se práce nespustí.',
    TRAFFIC='Chvíli vyčkat na uvolnění provozu; potom jiná volná souprava.',
    ROUTE='Prověř volný vjezd, alternativní fyzický nájezd nebo naučený Teach bod.',
    START='Pokus o AI start odmítnut; lze zkusit jiný dostupný stroj nebo opakovat po prodlevě.',
    ATTACH='Připojení musí potvrdit hra; zkusit jinou geometrii podle specializovaného sestavovače.',
    EXHAUSTED='Dlouhé fyzické čekání překročilo bezpečný limit; prověř bránu, přístup nebo Teach bod.',
    UNKNOWN='Neznámá příčina. Zastavit automatické opakování a uložit diagnostiku.'
}

function FMAExperience.advice(reason)
    local category=FMAExperience.classify(reason)
    return category,advice[category] or advice.UNKNOWN
end

function FMAExperience.key(operation, vehicleKey)
    return tostring(operation or '?')..'\31'..tostring(vehicleKey or '?')
end

function FMAExperience.note(c,task,record,success,reason)
    if not c or not task or not record or not record.key then return nil end
    c.experience=c.experience or {}
    local operation=task.operation or task.kind or '?'
    local index=FMAExperience.key(operation,record.key)
    local entry=c.experience[index] or {operation=operation,vehicleKey=record.key,successes=0,failures=0,reliabilityDebt=0,lastCategory='NONE'}
    if success then
        entry.successes=math.min(1000,(entry.successes or 0)+1)
        -- Verified success lets a machine recover from past transient failures.
        entry.failures=math.max(0,(entry.failures or 0)-1)
        entry.reliabilityDebt=math.max(0,(entry.reliabilityDebt or 0)-1)
        entry.lastCategory='VERIFIED'
    else
        local category=FMAExperience.classify(reason)
        entry.failures=math.min(1000,(entry.failures or 0)+1)
        -- Traffic, stock, finance and owner intervention are not machine defects.
        if category=='ROUTE' or category=='START' then
            entry.reliabilityDebt=math.min(20,(entry.reliabilityDebt or 0)+1)
        end
        entry.lastCategory=category
    end
    c.experience[index]=entry
    c.experienceSequence=(c.experienceSequence or 0)+1
    entry.lastUsed=c.experienceSequence
    c.diagnosticDirty=true
    return entry
end

function FMAExperience.penalty(experience,task,vehicle)
    if not experience or not task or not vehicle then return 0 end
    local row=experience[FMAExperience.key(task.operation or task.kind,vehicle.key)]
    if not row then return 0 end
    -- Soft preference only; never assert an implement is incompatible from history.
    -- Strong enough to prefer a similar idle vehicle after repeated failures.
    local debt=math.max(0,row.reliabilityDebt or 0)
    return math.min(240,debt*45)
end

function FMAExperience.verified(c,task,record,engineVerified)
    if not task or not record or task.kind~='field' or engineVerified~=true then return false end
    if task.state~='done' or task.awaitingWorldVerification==true or not task.fieldworkStartedAt then return false end
    -- Only an externally verified field result is a trusted positive sample.
    FMAExperience.note(c,task,record,true)
    if c.jobFailures then c.jobFailures[task.id]=nil end
    task.failedVehicleKeys=nil
    task.recoveryCount=0
    task.failures=0
    if FMADiagnostics then FMADiagnostics.event(c,'experience.verified',task.id,record.name or record.key) end
    return true
end

-- A successfully finished handover is separate evidence from successful field
-- work: returning a plough does NOT establish that ploughing was completed.
function FMAExperience.handover(c,task,vehicleKey,success,reason)
    if not c or not task or not vehicleKey then return end
    c.experience=c.experience or {}
    local op=task.operation or task.kind or '?'
    local key=FMAExperience.key(op,vehicleKey)
    local row=c.experience[key] or {operation=op,vehicleKey=vehicleKey,successes=0,failures=0,reliabilityDebt=0,lastCategory='NONE'}
    if success then row.handovers=math.min(1000,(row.handovers or 0)+1)
    else row.handoverFailures=math.min(1000,(row.handoverFailures or 0)+1) end
    row.lastHandoverReason=tostring(reason or ''):sub(1,240)
    c.experience[key]=row;c.diagnosticDirty=true
end

function FMAExperience.writeDiagnostics(c,f)
    f:write('\nEXPERIENCE / VERIFIED OPERATIONS\n')
    local rows={}
    for _,r in pairs(c.experience or {}) do rows[#rows+1]=r end
    table.sort(rows,function(a,b) return (a.failures or 0)>(b.failures or 0) end)
    f:write('records=',tostring(#rows),' (not autonomous machine learning; verified success/failure statistics)\n')
    for i=1,math.min(#rows,35) do
        local r=rows[i]
        f:write(tostring(r.operation),' | ',tostring(r.vehicleKey),' | verified=',tostring(r.successes or 0),' failures=',tostring(r.failures or 0),' handovers=',tostring(r.handovers or 0),' handoverFailures=',tostring(r.handoverFailures or 0),' reliabilityDebt=',tostring(r.reliabilityDebt or 0),' last=',tostring(r.lastCategory or ''),'\n')
    end
end
