FMAProductionManager = {}

function FMAProductionManager.scan(farmId,settings)
    local issues={}
    local manager=g_currentMission.productionChainManager
    for _,point in pairs(FMAUtil.call(manager,'getProductionPointsForFarmId',farmId) or {}) do
        local storage=point.storage
        local name=FMAUtil.call(point,'getName') or (point.owningPlaceable and FMAUtil.name(point.owningPlaceable)) or 'Výroba'
        if storage then
            for ft,level in pairs(FMAUtil.call(storage,'getFillLevels') or {}) do
                local cap=FMAUtil.call(storage,'getCapacity',ft)
                if cap and cap>0 then
                    if point.inputFillTypeIds and point.inputFillTypeIds[ft] and level/cap<(settings.productionInputEmergency or 0.10) then
                        issues[#issues+1]={id='prod:input:'..tostring(point)..':'..ft,title=name..' · dochází '..FMAWorld.fillName(ft),detail='Výroba může brzy stát. Manager hledá vlastní zásobu; pokud není, požádá majitele.',priority=88}
                    elseif point.outputFillTypeIds and point.outputFillTypeIds[ft] and level/cap>(settings.outputMoveAt or 0.75) then
                        issues[#issues+1]={id='prod:output:'..tostring(point)..':'..ft,title=name..' · plní se '..FMAWorld.fillName(ft),detail='Naplánován odvoz do vlastního skladu/výroby; prodej jen pokud je povolen.',priority=76}
                    end
                end
            end
        end
    end
    return issues
end
