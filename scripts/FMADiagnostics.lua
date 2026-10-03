-- Bounded diagnostic journal. No intentional faults and no global print/error hooks.
FMADiagnostics = {VERSION="0.20.48.0"}

function FMADiagnostics.event(c,kind,id,detail)
    if not c then return end
    c.journal=c.journal or {}
    c.journal[#c.journal+1]={time=c.now or 0,kind=kind,id=tostring(id or ""),detail=tostring(detail or "")}
    if #c.journal>300 then table.remove(c.journal,1) end
    if FMABlackBox and FMABlackBox.event then pcall(FMABlackBox.event,c,kind,id,detail) end
end

function FMADiagnostics.error(c,name,err)
    if not c then return end
    c.errorCounts=c.errorCounts or {}
    local text=tostring(err);local key=tostring(name)..":"..text:sub(1,200)
    if not c.errorCounts[key] and FMAUtil.count(c.errorCounts)>=100 then
        key="overflow";name="Další chyby (agregováno)"
    end
    c.diagnosticDirty=true
    c.desktopSnapshotDue=math.min(c.desktopSnapshotDue or math.huge,(c.now or 0)+1000)
    local row=c.errorCounts[key] or {name=name,count=0,first=c.now or 0}
    row.count=row.count+1;row.last=c.now or 0;row.text=text
    c.errorCounts[key]=row
    if row.count==1 or row.count%50==0 then FMAUtil.log("ERROR ["..name.."] x"..row.count.." "..text) end
    if row.count==1 then FMADiagnostics.event(c,"error",name,text) end
end

function FMADiagnostics.trace(err)
    return debug and debug.traceback and debug.traceback(tostring(err),2) or tostring(err)
end

function FMADiagnostics.write(c,f)
    f:write("\nFLIGHT RECORDER: ",FMABlackBox and FMABlackBox.summary(c) or "missing","\n")
    f:write("\nJOB FAILURES\n")
    for id,e in pairs(c.jobFailures or {}) do f:write(id," count=",tostring(e.count)," blocked=",tostring(e.blocked)," retryAt=",tostring(e.retryAt)," | ",e.reason,"\n") end
    f:write("\nERROR COUNTS AND TRACES\n")
    for _,e in pairs(c.errorCounts or {}) do f:write(tostring(e.name)," count=",tostring(e.count)," first=",tostring(e.first)," last=",tostring(e.last),"\n",e.text,"\n") end
    f:write("\nACTIVE JOBS / RESERVATIONS\n")
    for job,a in pairs(c.active or {}) do
        f:write(tostring(a.task.id)," phase=",tostring(a.task.phase)," vehicle=",tostring(a.vehicle.key)," type=",tostring(job.jobTypeIndex),
            " running=",tostring(job.isRunning)," transfer=",tostring(a.transferMethod or "-"),
            " target=",tostring(a.trafficTarget and a.trafficTarget.x or a.task.x or "-"),",",tostring(a.trafficTarget and a.trafficTarget.z or a.task.z or "-"),"\n")
    end
    for key,id in pairs(c.reservations or {}) do f:write("reserve ",key," ",tostring(id),"\n") end
    f:write("\nDECISION BLACKBOX\n")
    for _,task in pairs(c.tasks or {}) do
        if task.selectionAudit and #task.selectionAudit>0 then
            f:write(tostring(task.id)," op=",tostring(task.operation)," state=",tostring(task.state)," preferred=",tostring(task.preferredVehicleName or "AUTO"),"\n")
            for _,row in ipairs(task.selectionAudit) do
                f:write("  ",tostring(row.name or row.key)," ok=",tostring(row.ok)," score=",tostring(row.score or "-")," reason=",tostring(row.reason or "selected/compatible"),"\n")
            end
        end
        for slot,rows in pairs(task.supportSelectionAudit or {}) do
            if rows and #rows>0 then
                f:write(tostring(task.id)," supportSlot=",tostring(slot),"\n")
                for _,row in ipairs(rows) do
                    f:write("  ",tostring(row.name or row.key)," ok=",tostring(row.ok)," score=",tostring(row.score or "-")," reason=",tostring(row.reason or "selected/compatible"),"\n")
                end
            end
        end
    end
    f:write("\nEVENT JOURNAL (bounded to 300)\n")
    for _,e in ipairs(c.journal or {}) do f:write(tostring(math.floor(e.time/1000))," ",e.kind," ",e.id," | ",e.detail,"\n") end
end
