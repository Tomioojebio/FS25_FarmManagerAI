-- Passive, read-only farm audit. A PASS is an observation of currently loaded
-- game data; it is NEVER proof that a machine can drive or complete fieldwork.
FMATestSuite={VERSION='0.20.48.0'}
local T=FMATestSuite
local function count(t) local n=0;for _ in pairs(t or {}) do n=n+1 end;return n end
local function add(rows,kind,name,detail)
    rows[#rows+1]={kind=kind,name=name,detail=tostring(detail or '')}
end
function T.inspect(c)
    c=c or {}
    local rows={}
    local world=c.mapProfile or {}
    if c.supported==false then
        add(rows,'BLOCK','Supported map/game state','Mod currently considers this map or mission unsupported')
    elseif #(c.fields or {})>0 then
        add(rows,'SEEN','Owned fields',#c.fields..' fields')
    else
        add(rows,'NOTICE','Owned fields','No owned fields detected; no field operations will be offered')
    end
    if #(c.vehicles or {})>0 then add(rows,'SEEN','Powered vehicles',#c.vehicles..' vehicles')
    else add(rows,'NOTICE','Powered vehicles','No eligible powered vehicles discovered') end
    add(rows,'OBSERVED','Loose equipment',count(c.loose)..' known loose implements')
    add(rows,'OBSERVED','Farm structures',count(c.parkingFacilities)..' parking-relevant facilities; '
        ..count(c.parkingBays)..' verified parking spots')
    add(rows,'OBSERVED','Livestock',count(c.husbandries)..' husbandry objects; '
        ..count(c.animalConditions)..' conditions recorded')
    add(rows,'OBSERVED','Bunker silos',#(c.bunkers or {})..' bunker entries')
    if g_modIsLoaded and g_modIsLoaded.FS25_Courseplay then
        add(rows,'SEEN','Courseplay','Mod is loaded; successful engine start MUST be verified separately')
    elseif c.cpAvailable or (c.courseplay and c.courseplay.available) then
        add(rows,'OBSERVED','Courseplay','Runtime appears present; physical startup unverified')
    else add(rows,'NOTICE','Courseplay','Could not confirm plugin loaded in this snapshot') end
    for _,t in pairs(c.tasks or {}) do
        if t.ownerApproved then
            if t.state=='blocked' then
                add(rows,'BLOCK','Order '..tostring(t.id),tostring(t.phase)..' · '..tostring(t.reason or 'blocked'))
            elseif t.state=='running' and not t.fieldworkStartedAt and t.operation and t.operation~='haulage' then
                add(rows,'NOTICE','Order '..tostring(t.id),'Running flag present without independent fieldwork evidence')
            end
        end
    end
    for _,a in pairs(c.active or {}) do
        local age=(c.now or 0)-(a.lastProgress or a.start or (c.now or 0))
        if a.vehicle and age>30000 then
            add(rows,'NOTICE','Stalled AI '..tostring(a.vehicle.name or a.vehicle.key),
                'No confirmed progress for '..math.floor(age/1000)..'s; needs real movement verification')
        end
    end
    for name,err in pairs(c.subsystemFaults or {}) do add(rows,'BLOCK','Runtime '..name,err) end
    if c.recorderError then add(rows,'NOTICE','Flight recorder',c.recorderError) end
    if c.runtimePaused then add(rows,'BLOCK','Automation','Suspended due to runtime fault or owner action') end
    return rows
end
function T.report(c)
    local rows=T.inspect(c)
    local out={'NON-INVASIVE AUTOMATIC FARM AUDIT '..T.VERSION,
        'These are read-only consistency checks, NOT actual driving tests or proof of completed farming work.',
        'Rows do not start/stop AI or move vehicles.'}
    local totals={}
    for _,r in ipairs(rows) do
        totals[r.kind]=(totals[r.kind] or 0)+1
        out[#out+1]=r.kind..' | '..r.name..' | '..r.detail:gsub('[\r\n]',' ')
    end
    out[#out+1]='SUMMARY | seen='..tostring(totals.SEEN or 0)..' | blocking='..tostring(totals.BLOCK or 0)
        ..' | notices='..tostring(totals.NOTICE or 0)..' | other='..tostring(totals.OBSERVED or 0)
    return table.concat(out,'\n')..'\n',totals
end
function T.run(c)
    local _,totals=T.report(c)
    c.lastPassiveTestAt=c.now or 0
    c.lastPassiveTestSummary=totals
    if FMABlackBox and FMABlackBox.event then
        FMABlackBox.event(c,'selftest.passive','snapshot',
            'blocking='..tostring(totals.BLOCK or 0)..' warnings='..tostring(totals.NOTICE or 0))
    end
    return totals
end
