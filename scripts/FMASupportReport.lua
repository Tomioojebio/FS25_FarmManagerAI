-- Self-contained, plain UTF-8 support report. No reading existing files,
-- external commands, binary archive creation or savegame modifications.
-- GIANTS may deny io.open(..., 'r') on arbitrary game logs; every section
-- here is built from live in-memory state and our bounded flight recorder.
FMASupportReport={VERSION='0.20.48.0',FILE='FS25_FarmManagerAI_REPORT.txt',MAX_SECTION=2200000}
local R=FMASupportReport
local function clean(str)
    str=tostring(str or '')
    if #str>R.MAX_SECTION then
        return str:sub(#str-R.MAX_SECTION+1)..'\n[REPORT: older content truncated; latest part retained]\n'
    end
    return str
end
local function field(value)
    return tostring(value==nil and '-' or value):gsub('[\r\n|]',' ')
end
function R.compose(c,diagnosticText)
    local list={}
    local when='unknown'
    if os and type(os.date)=='function' then
        local ok,stamp=pcall(os.date,'%Y-%m-%d %H:%M:%S')
        if ok and stamp then when=stamp end
    end
    local meta={
        'FarmManagerAI SINGLE FILE SUPPORT REPORT '..R.VERSION,
        'Soubor vytvořen na vyžádání hráče (Alt+D).',
        'READ ONLY: nezapisuje do uložené pozice a nic neřídí.',
        'Date '..field(when),
        'Session ms '..field(c and c.now),
        'Map '..field(g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.mapTitle),
        'AUTO '..field(c and c.settings and c.settings.enabled),
        'Farm '..field(c and c.farmId),
        'WARNING: Genuine GIANTS FarmingSimulator2025/log.txt cannot be read through the FS25 Lua sandbox.',
        'Recorded FS25/Courseplay responses below are intercepted manager events, NOT the complete engine log.',
        'For native game-engine errors outside manager callbacks, the original game log may still be needed.',
    }
    list[#list+1]={name='00_MANIFEST.txt',content=table.concat(meta,'\n')..'\n'}
    list[#list+1]={name='01_DIAGNOSTIC.txt',content=clean(diagnosticText or '[Diagnostic unavailable]')}
    local live='[Live telemetry unavailable]'
    if FMALiveTelemetry and type(FMALiveTelemetry.snapshot)=='function' then
        local ok,result=pcall(FMALiveTelemetry.snapshot,c)
        if ok then live=result else live='[Live telemetry error] '..field(result) end
    end
    if FMATestSuite and FMATestSuite.report then
        local success,report=pcall(FMATestSuite.report,c)
        list[#list+1]={name='01A_PASSIVE_TEST.txt',content=clean(success and report or ('Test error: '..field(report)))}
    end
    if FMADevLab and FMADevLab.report then
        local ok,result=pcall(FMADevLab.report,c)
        list[#list+1]={name='01B_DEV_AUTOTEST.txt',content=clean(ok and result or ('DevLab snapshot failed: '..field(result)))}
    end
    list[#list+1]={name='02_LIVE.txt',content=clean(live)}
    local ops=FMAOpsLog and FMAOpsLog.lines
    list[#list+1]={name='03_MANAGER_LOG.txt',content=clean(ops and table.concat(ops,'\n') or '[Operational log unavailable]')}
    local trace,traceError={},nil
    if FMABlackBox and type(FMABlackBox.exportHistory)=='function' then
        local ok,result,err=pcall(FMABlackBox.exportHistory,c)
        if ok then trace,traceError=result or {},err else traceError=field(result) end
    else traceError='Flight recorder module missing' end
    if #trace==0 then
        list[#list+1]={name='04_TRACE_UNAVAILABLE.txt',content=field(traceError or 'No recorded events yet')..'\n'}
    else
        for _,segment in ipairs(trace) do
            list[#list+1]={name='TRACE_'..string.format('%02d',segment.slot)..'.txt',content=clean(segment.content)}
        end
    end
    list[#list+1]={name='99_LIMITATIONS.txt',content=table.concat({
        'Report sections: manager snapshot, live view, manager operational log, in-memory flight recorder.',
        'Scope: most recent '..tostring(FMABlackBox and FMABlackBox.SLOTS or 12)..' flight recorder segments in the CURRENT play session.',
        'After restarting FS25, older traces are not recovered by this report: reading previous disk files is not permitted.',
        'FS25 game log and Courseplay private logging are not fully accessible from this mod.',
        'The report contains map, farm, mod and machine identifiers. Check before sharing publicly.'},'\n')..'\n'}
    local output={}
    for index,item in ipairs(list) do
        local body=clean(item.content)
        output[#output+1]='\n'..string.rep('=',20)..' FILE '..index..'/'..#list..': '..item.name..' ('..#body..' bytes) '..string.rep('=',20)..'\n'
        output[#output+1]=body
        output[#output+1]='\n-- END '..item.name..' --\n'
    end
    return table.concat(output),list
end
function R.export(c,diagnosticText)
    local ok,result=pcall(R.compose,c,diagnosticText)
    if not ok then return {ok=false,reason='Could not assemble support report: '..field(result)} end
    if not (FMAOpsLog and FMAOpsLog.writePortable) then return {ok=false,reason='Desktop writer unavailable'} end
    local path,wrote=FMAOpsLog.writePortable(R.FILE,result)
    return {ok=wrote==true,path=path,bytes=#result,
        reason=wrote and nil or field(FMAOpsLog.lastExportError or 'Desktop/profil write denied')}
end
