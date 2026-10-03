-- Operational log/export helper.
-- GIANTS FS25 script sandbox permits write mode but rejects append/read access on arbitrary files.
-- Keep the manager log in memory and rewrite the whole desktop file with "w" so we never touch
-- the live FarmingSimulator2025/log.txt or hold a savegame file open.
FMAOpsLog = {
    VERSION="0.20.48.0",
    desktopDir=nil,
    fallbackDir=nil,
    lastExportError=nil,
    lines={},
    maxLines=1200,
    lastPath=nil
}

local function normalize(path)
    if not path or path=="" then return nil end
    path=tostring(path):gsub("\\","/")
    path=path:gsub("/+","/")
    if path:sub(-1)=="/" then path=path:sub(1,-2) end
    return path
end

local function uniqueAppend(list,seen,path)
    path=normalize(path)
    if not path or seen[path] then return end
    seen[path]=true;list[#list+1]=path
end

function FMAOpsLog.profileDir()
    if FMAOpsLog.fallbackDir then return FMAOpsLog.fallbackDir end
    if type(getUserProfileAppPath)=="function" then
        local ok,path=pcall(getUserProfileAppPath)
        if ok and path then FMAOpsLog.fallbackDir=normalize(path);return FMAOpsLog.fallbackDir end
    end
    return nil
end

function FMAOpsLog.desktopCandidates()
    local out,seen={},{}
    if os and type(os.getenv)=="function" then
        local ok,user=pcall(os.getenv,"USERPROFILE")
        if ok and user and user~="" then
            uniqueAppend(out,seen,user.."/Desktop")
            uniqueAppend(out,seen,user.."/OneDrive/Desktop")
        end
        local ok2,one=pcall(os.getenv,"OneDrive")
        if ok2 and one and one~="" then uniqueAppend(out,seen,one.."/Desktop") end
    end
    local profile=FMAOpsLog.profileDir()
    if profile then
        local prefix=profile:match("^(.-)/Documents/")
        if prefix then
            uniqueAppend(out,seen,prefix.."/Desktop")
            uniqueAppend(out,seen,prefix.."/OneDrive/Desktop")
        end
    end
    return out
end

local function writeExact(path,data)
    -- Deliberately use only "w". FS25 warns/rejects append/read modes in its sandbox.
    local file=io and io.open and io.open(path,"w") or nil
    if not file then return false,"open failed" end
    local ok,err=pcall(file.write,file,data or "")
    pcall(file.flush,file);pcall(file.close,file)
    return ok,err
end

function FMAOpsLog.writePortable(filename,data)
    local dirs={}
    if FMAOpsLog.desktopDir then dirs[#dirs+1]=FMAOpsLog.desktopDir end
    for _,dir in ipairs(FMAOpsLog.desktopCandidates()) do dirs[#dirs+1]=dir end
    local profile=FMAOpsLog.profileDir();if profile then dirs[#dirs+1]=profile end
    local tried={}
    for _,dir in ipairs(dirs) do
        dir=normalize(dir)
        if dir and not tried[dir] then
            tried[dir]=true
            local path=dir.."/"..filename
            local ok,err=writeExact(path,data)
            if ok then
                if dir~=profile then FMAOpsLog.desktopDir=dir end
                FMAOpsLog.lastExportError=nil
                FMAOpsLog.lastPath=path
                return path,true
            end
            FMAOpsLog.lastExportError=tostring(err or "write failed")
        end
    end
    return nil,false
end

local function joinedLines()
    return table.concat(FMAOpsLog.lines or {},"\n").."\n"
end

function FMAOpsLog.flushManager()
    return FMAOpsLog.writePortable("FS25_FarmManagerAI_LOG.txt",joinedLines())
end

function FMAOpsLog.resetSession()
    FMAOpsLog.lines={"FarmManagerAI operational log 0.20.47"}
    return FMAOpsLog.flushManager()
end

function FMAOpsLog.appendManager(message)
    local line=tostring(message or "")
    local lines=FMAOpsLog.lines or {};FMAOpsLog.lines=lines
    lines[#lines+1]=line
    while #lines>(FMAOpsLog.maxLines or 1200) do table.remove(lines,1) end
    -- Rewrite, never append. This is intentionally a short bounded file.
    return FMAOpsLog.flushManager()
end

function FMAOpsLog.writeDiagnostic(text)
    return FMAOpsLog.writePortable("FS25_FarmManagerAI_DIAGNOSTIC.txt",tostring(text or ""))
end

function FMAOpsLog.exportSnapshot(diagnosticText)
    local diagPath,diagOk=FMAOpsLog.writeDiagnostic(diagnosticText or "")
    local logPath,logOk=FMAOpsLog.flushManager()
    return {diagnosticPath=diagPath,diagnosticOk=diagOk,logPath=logPath,logOk=logOk,desktopDir=FMAOpsLog.desktopDir,fallbackDir=FMAOpsLog.profileDir()}
end

function FMAOpsLog.locationLabel()
    if FMAOpsLog.desktopDir then return "Plocha: "..tostring(FMAOpsLog.desktopDir) end
    local profile=FMAOpsLog.profileDir()
    if profile then return "profil hry: "..tostring(profile) end
    return "umístění nedostupné"
end
