-- Regression contracts for FS25 0.20.37.0. These do not simulate the game engine.
return function(test,eq)
    test('37: player-controlled vehicle wins even if AI flag lingers',function()
        local prior=g_currentMission
        local tractor={getIsEntered=function() return true end,getIsAIActive=function() return true end,
            getIsCpActive=function() return true end}
        g_currentMission={player={currentVehicle=tractor},controlledVehicle=tractor}
        local s=FMAGameNative.operatorState(tractor)
        eq(s.manual,true);eq(s.mode,'PLAYER')
        g_currentMission=prior
    end)
    test('37: unattended worker still recognized as AI',function()
        local prior=g_currentMission
        g_currentMission={player={currentVehicle=nil},controlledVehicle=nil}
        local tractor={getIsEntered=function() return false end,getIsAIActive=function()return true end}
        local s=FMAGameNative.operatorState(tractor)
        eq(s.manual,false);eq(s.mode,'FS_AI')
        g_currentMission=prior
    end)
    test('38: main terminal actually uses nine icon cards',function()
        local needed={['PŘEHLED']=true,['POLNÍ PRÁCE']=true,['SKLIZEŇ']=true,
            ['ZVÍŘATA']=true,['SILÁŽ']=true,['TECHNIKA']=true,
            ['PROBLÉMY']=true,['MAPA A STÁNÍ']=true,['NASTAVENÍ']=true}
        for _,item in ipairs(FMAHud.cards) do
            assert(needed[item.label],'unexpected tile: '..tostring(item.label))
            assert(item.icon and item.icon~='','missing tile icon')
            needed[item.label]=nil
        end
        eq(#FMAHud.cards,9)
        assert(next(needed)==nil)
    end)
    test('37: event listener no longer patches native input or uses Alt+P',function()
        local f=assert(io.open('scripts/main.lua','rb'))
        local source=f:read('*a');f:close()
        assert(not source:find('PlayerInputComponent.registerGlobalPlayerActionEvents=',1,true))
        assert(not source:find('sym==Input.KEY_p',1,true))
        assert(not source:find('registerGlobalActions,listener)',1,true) or source:find('inputReady=true',1,true))
        assert(source:find('if not alt then return end',1,true))
        assert(source:find('sym==Input.KEY_m',1,true))
    end)
end
