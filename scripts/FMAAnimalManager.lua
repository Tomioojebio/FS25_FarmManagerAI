-- Husbandry facade. Detailed ration/forecast logic lives in FMALivestockCoordinator.
FMAAnimalManager = {}

function FMAAnimalManager.scan(farmId,settings)
    if FMALivestockCoordinator then return FMALivestockCoordinator.scan(farmId,settings) end
    local rows,issues={},{}
    local placeables=g_currentMission.placeableSystem and g_currentMission.placeableSystem.placeables or {}
    for _,p in pairs(placeables) do
        if FMAUtil.owner(p)==farmId and p.spec_husbandry then
            local name=FMAUtil.name(p);local food=FMAUtil.call(p,'getTotalFood');local foodCap=FMAUtil.call(p,'getFoodCapacity')
            if food and foodCap and foodCap>0 then
                local ratio=food/foodCap;rows[#rows+1]={id='livestock:food:'..tostring(p),name=name..' · krmivo',ratio=ratio,value=food,capacity=foodCap,message='Krmný plán',priority=100}
                if ratio<(settings.foodEmergency or 0.15) then issues[#issues+1]={id='animal:critical:'..tostring(p),title=name..' · KRITICKÉ KRMIVO',detail='Krmivo je pod kritickou hranicí.',priority=100} end
            end
        end
    end
    return rows,issues,{}
end

function FMAAnimalManager.tasks(farmId,settings)
    return FMAWorld.supplyTasks(farmId,settings.foodTarget or 0.70)
end
