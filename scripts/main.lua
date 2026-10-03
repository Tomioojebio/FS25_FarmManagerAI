local modDirectory=g_currentModDirectory
local listener={}
local controller
local overlay
local UI_CONTEXT="FMA_MANAGER_UI"
local inputTransition=false
local postLoadRefresh=false
local lastBaseInputContext=nil
local globalRebindElapsed=0
local lastHotkeyAt={}
local INPUT_HOOK_FLAG="__fmaGlobalPlayerInputHook0170"

local function stopAutomationAfterError(context,err)
    FMAUtil.log("ERROR ["..tostring(context).."] "..tostring(err))
    if not controller then return end
    controller.settings.enabled=false
    controller.runtimePaused=true
    controller.lastRuntimeError=tostring(context)..": "..tostring(err)
    controller.lastMessage="Chyba "..tostring(context).."; automatika pozastavena, panel zůstává aktivní."
    controller:issue("runtime","Chyba modulu "..tostring(context),tostring(err),100)
    -- Emergency stop must also release directly driven vehicles, not only GIANTS AI jobs.
    if FMAOwnDriver then pcall(FMAOwnDriver.stopAll,controller,"Kritická chyba manageru") end
    local jobs={};for job in pairs(controller.active or {}) do jobs[#jobs+1]=job end
    for _,job in ipairs(jobs) do pcall(FMAAI.stop,job) end
    if FMAAutoRoute then pcall(FMAAutoRoute.stopAll,controller) end
end

local function guarded(context,fn,...)
    local args={...}
    local ok,err=xpcall(function() return fn(unpack(args)) end,FMADiagnostics.trace)
    if not ok then FMADiagnostics.error(controller,context,err);stopAutomationAfterError(context,err) end
    return ok,err
end

local function guardedInput(context,fn,...)
    local args={...}
    local ok,err=xpcall(function() return fn(unpack(args)) end,FMADiagnostics.trace)
    if not ok and controller then
        controller.lastInputError=context..": "..tostring(err)
        FMADiagnostics.error(controller,"input:"..context,err)
        controller.lastMessage="Chyba ovládání: podrobnosti jsou v diagnostice."
    end
    return ok,err
end

local function guiBlocksInput()
    return g_gui and g_gui.getIsGuiVisible and g_gui:getIsGuiVisible()
end

local function removeEvents(list)
    if not g_inputBinding then return end
    for _,id in ipairs(list or {}) do if id then pcall(g_inputBinding.removeActionEvent,g_inputBinding,id) end end
end

local function hotkeyNow()
    -- Input debounce must follow the engine input clock even if controller update is
    -- temporarily paused by a GUI/context rebuild.
    return g_time or (controller and controller.now) or 0
end

local function triggerHotkey(name,callback,source,allowGui)
    local now=hotkeyNow()
    local key=tostring(name)
    if now-(lastHotkeyAt[key] or -1000000)<150 then return false end
    if not allowGui and guiBlocksInput() then return false end
    lastHotkeyAt[key]=now
    if controller then
        controller.inputEventCount=(controller.inputEventCount or 0)+1
        controller.lastInputEvent=key.."@"..tostring(source or "action")
        controller.lastInputEventAt=now
        controller.diagnosticDirty=true
    end
    guardedInput(key,callback)
    return true
end

local function moveSelection(delta)
    if not controller then return end
    local n=#FMAHud.rows(controller)
    if n>0 then controller.selection=math.max(1,math.min(n,controller.selection+delta)) end
end

local function prevPage()
    local nav=FMAHud.navigation or {}
    local at=1
    for i,item in ipairs(nav) do if item.id==controller.page then at=i;break end end
    if #nav>0 then FMAHud.changePage(controller,nav[(at-2)%#nav+1].id) end
end

local function nextPage()
    local nav=FMAHud.navigation or {}
    local at=1
    for i,item in ipairs(nav) do if item.id==controller.page then at=i;break end end
    if #nav>0 then FMAHud.changePage(controller,nav[at%#nav+1].id) end
end

function listener:setPanelVisible(value)
    if not controller then return end
    FMAHud.setVisible(controller,value)
    listener:syncInputContext()
end

-- Input safety: NEVER modify PlayerInputComponent, action-event registries,
-- player/vehicle contexts, ENTER, E or the game's native controls.
-- The mod listener sees keyEvent and uses only deliberate Alt shortcuts.
function listener:registerGlobalActions()
    if not controller then return end
    controller.inputReady=true
    controller.globalInputContext=FMAUtil.call(g_inputBinding,'getContextName')
    controller.globalInputContexts={'RAW_ALT_SHORTCUTS'}
end
local function installGlobalInputHook() end -- compatibility no-op

-- Never override Gui.registerMenuInput: GIANTS owns all ESC/map GUI actions.
-- The Farm Manager console is a standalone, non-modal gameplay overlay.

-- The legacy fullscreen input context was removed: it could interfere with
-- Courseplay, camera movement and the game menu.

function listener:closeInputContext()
    if not controller or not controller.uiContextActive then return end
    local current=FMAUtil.call(g_inputBinding,"getContextName")
    if guiBlocksInput() and not controller.shuttingDown then return end
    if g_inputBinding and g_inputBinding.revertContext and (current==nil or current==UI_CONTEXT) then
        pcall(g_inputBinding.revertContext,g_inputBinding,true)
    end
    removeEvents(controller.uiBindings);controller.uiBindings={};controller.uiContextActive=false
end

function listener:syncInputContext()
    -- The command terminal is a non-blocking overlay. It must never own the entire
    -- input context, otherwise walking/driving/map controls stop working.
    if controller and controller.uiContextActive then listener:closeInputContext() end
end

function listener:loadMap()
    inputTransition=false;postLoadRefresh=false;lastBaseInputContext=nil;globalRebindElapsed=0;lastHotkeyAt={}
    -- SAFE ESC: No native tab injection and no MENU_MAP_OVERVIEW input interception.
    if FMAOpsLog and FMAOpsLog.resetSession then pcall(FMAOpsLog.resetSession) end
    controller=FMAController.new()
    controller.globalBindings={};controller.uiBindings={};controller.menuBindings={};controller.bindings={};controller.lastMenuInputContext=nil
    -- Register the custom CP transfer job already in loadMap, at the same lifecycle
    -- stage Courseplay registers its own jobs. This makes a transfer job type known to
    -- the serializer before vehicles/lastJob history can ever need it. initialize()
    -- repeats the check later in case mod load order delayed Courseplay.
    if FMATransfer and FMATransfer.ensureRegistered and FMACourseplay and FMACourseplay.available and FMACourseplay.available() then
        local ok,why=FMATransfer.ensureRegistered(controller)
        if not ok then controller.lastTransferRegistrationError=tostring(why) end
    end
    overlay=Overlay.new(modDirectory.."ui/white.dds",0,0,1,1)
    FMAHud.loadIcons(modDirectory)
    guardedInput("registerGlobalActions",listener.registerGlobalActions,listener)
    guardedInput("inputContext",listener.syncInputContext,listener)
end

function listener:keyEvent(unicode,sym,modifier,isDown)
    if not isDown or not controller or not Input or guiBlocksInput() then return end
    local alt=false
    if bitAND and Input.MOD_LALT then alt=bitAND(modifier or 0,Input.MOD_LALT)~=0 end
    if not alt and Input.isKeyPressed and Input.KEY_lalt then alt=Input.isKeyPressed(Input.KEY_lalt)==true end
    -- The owner uses ENTER for the vehicle engine. Never interpret plain ENTER
    -- (or keypad ENTER) as a Farm Manager action, even while its overlay is shown.
    -- No menu confirmation hotkey: mouse click only, never the game's Alt+P.
    -- This keeps the native TOGGLE_MOTOR_STATE binding entirely engine-owned.
    -- E / ENTER / driving inputs are NEVER handled by Farm Manager.
    -- The non-modal overlay may close automatically after the player changes vehicle.
    if not alt then return end
    if sym==Input.KEY_m then
        triggerHotkey("FMA_MENU",function() listener:setPanelVisible(not controller.visible) end,"raw",false)
    elseif sym==Input.KEY_h then
        triggerHotkey("FMA_TOGGLE",function() controller:toggle() end,"raw",false)
    elseif sym==Input.KEY_d then
        triggerHotkey("FMA_DIAGNOSTIC",function() if controller.initialized then controller:diagnostics() end end,"raw",false)
    elseif sym==Input.KEY_r then
        triggerHotkey("FMA_REFRESH",function() if controller.supported then controller:refresh();controller.runtimePaused=false end end,"raw",false)
    end
end

function listener:mouseEvent(posX,posY,isDown,isUp,button)
    if not controller or not controller.visible then return false end
    local ok,result=pcall(FMAHud.mouseEvent,controller,posX,posY,isDown,isUp,button)
    if not ok then
        FMAUtil.log("FMA UI CLICK ERROR "..tostring(result))
        listener:setPanelVisible(false)
        return false
    end
    return result==true
end

function listener:update(dt)
    if controller then
        controller.diagnosticElapsed=(controller.diagnosticElapsed or 0)+dt
        globalRebindElapsed=(globalRebindElapsed or 0)+dt

        if controller.initialized and not postLoadRefresh and not controller.visible then
            postLoadRefresh=true
        end
        -- Never re-register global action bindings on an interval: native E,
        -- steering and helper context ownership always remain GIANTS-owned.
        guardedInput("inputContext",listener.syncInputContext,listener)
        -- Another GIANTS screen always wins. Release our pointer on ESC/shop/dialog.
        if controller.visible and guiBlocksInput() then listener:setPanelVisible(false) end
        if controller.runtimePaused then
            guarded("pausedCleanup",FMALifecycle.update,controller)
            guarded("pausedStops",controller.drainStoppedJobs,controller)
        end
        if not controller.runtimePaused then guarded("update",controller.update,controller,dt) end
        -- The temporary development observer must NEVER disable farm automation on an exception.
        if FMADevLab and FMADevLab.update then
            local ok,err=pcall(FMADevLab.update,controller,dt)
            if not ok then controller.devLabError=tostring(err); FMAUtil.log("DEV LAB ERROR "..tostring(err)) end
        end
    end
end

function listener:draw()
    if controller then
        local ok,err=pcall(FMAHud.draw,controller,overlay)
        if not ok then FMAUtil.log("HUD ERROR "..tostring(err));listener:setPanelVisible(false) end
    end
end

function listener:deleteMap()
    if controller then
        controller.shuttingDown=true
        FMAHud.setVisible(controller,false)
        if FMADevLab then pcall(FMADevLab.stop,controller) end
        controller:disableAutomation("Konec hry")
        FMALifecycle.update(controller)
        controller:drainStoppedJobs()
        FMAJobs.controller=nil
        if g_messageCenter then g_messageCenter:unsubscribeAll(controller) end
        listener:closeInputContext()
        removeEvents(controller.globalBindings);removeEvents(controller.uiBindings);removeEvents(controller.menuBindings);removeEvents(controller.bindings)
        pcall(FMAAutoRoute.stopAll,controller)
        -- Preserve the single file automatically when the map is closed.
        if FMASupportReport and FMASupportReport.export then
            pcall(FMASupportReport.export,controller,controller.lastDiagnosticText or '')
        end
        if FMAOpsLog then
            if controller.lastDiagnosticText and FMAOpsLog.writeDiagnostic then pcall(FMAOpsLog.writeDiagnostic,controller.lastDiagnosticText) end
            if FMAOpsLog.flushManager then pcall(FMAOpsLog.flushManager) end
        end
    end
    if overlay then overlay:delete();overlay=nil end
    if FMAHud and FMAHud.deleteIcons then FMAHud.deleteIcons() end
    controller=nil
    _G.g_FMAInputBridge=nil
end

-- Persist only our own small XML through the mod listener.  Never prepend or mutate
-- the base VehicleSystem/FSCareer save pipeline.
function listener:saveToXMLFile(xmlFile,key,usedModNames)
    if controller and controller.initialized and not controller.shuttingDown then guarded("saveState",FMAState.save,controller) end
end
addModEventListener(listener)
