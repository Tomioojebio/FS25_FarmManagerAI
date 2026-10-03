#!/usr/bin/env python3
"""Build a direct-install mod ZIP; standard Python only. Run from any directory."""
from pathlib import Path
import hashlib
import json
import sys
import zipfile
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root.parent/'FS25_FarmManagerAI.zip'
if out.is_relative_to(root):
    raise SystemExit('Write the ZIP outside the mod source directory.')
tree=ET.parse(root/'modDesc.xml').getroot()
assert tree.tag=='modDesc' and tree.attrib['descVersion']=='105'
assert tree.find('multiplayer').attrib['supported']=='false'
source_files=[e.attrib['filename'] for e in tree.findall('./extraSourceFiles/sourceFile')]
assert len(source_files)==len(set(source_files))
assert set(source_files)=={p.relative_to(root).as_posix() for p in (root/"scripts").glob("*.lua")}
assert source_files[-1]=="scripts/main.lua"
for name in source_files: assert (root/name).is_file(),name
actions={e.attrib['name'] for e in tree.findall('./actions/action')}
for e in tree.findall('./inputBinding/actionBinding'): assert e.attrib['action'] in actions
# Compatibility gate for the GIANTS Lua runtime used by the user's FS25 1.15.0.0 build.
for lua in (root/'scripts').glob('*.lua'):
    source=lua.read_text(encoding='utf-8')
    assert 'goto ' not in source and '::' not in source, f'Unsupported Lua control syntax in {lua.name}'
    assert 'table.unpack' not in source, f'Lua 5.2+ table.unpack in gameplay script {lua.name}'
    assert 'math.tointeger' not in source, f'Lua 5.3+ math.tointeger in gameplay script {lua.name}'
    assert '//' not in source, f'Lua 5.3+ floor division token in gameplay script {lua.name}'
# Safety contract: Never inject our GUI into GIANTS' ESC/map, where invalid
# pages can corrupt the entire native menu. Keep a standalone Alt+M console.
bindings={e.attrib['action']:[b.attrib['input'] for b in e.findall('binding')] for e in tree.findall('./inputBinding/actionBinding')}
assert bindings.get('FMA_MENU')==['KEY_lalt KEY_m']
assert bindings.get('FMA_TOGGLE')==['KEY_lalt KEY_h']
main_source=(root/'scripts/main.lua').read_text(encoding='utf-8')
assert 'FMAMenuPage.install' not in main_source and 'g_inGameMenu:addPage' not in main_source
assert 'Gui.registerMenuInput=' not in main_source and 'guardedInput("liveMenuRebind"' not in main_source
assert 'function listener:keyEvent' in main_source and 'if not alt then return end' in main_source
# 0.20.9: a mouse HUD must be wired into the mod listener and offer an
# intentional mouse-only workflow, not merely draw inert click targets.
assert 'pcall(FMAHud.mouseEvent,controller,posX,posY,isDown,isUp,button)' in main_source
assert 'if controller.visible and guiBlocksInput() then listener:setPanelVisible(false) end' in main_source
assert 'FMAHud.changePage(controller' in main_source, 'Keyboard navigation must follow visual section order'
assert 'PlayerInputComponent.registerGlobalPlayerActionEvents=Utils.overwrittenFunction' not in main_source
assert 'PlayerInputComponent.registerGlobalPlayerActionEvents=' not in main_source
assert 'sym==Input.KEY_p' not in main_source
assert 'beginActionEventsModification,g_inputBinding,"PLAYER"' not in main_source
assert 'beginActionEventsModification,g_inputBinding,"VEHICLE"' not in main_source
assert 'filename="scripts/FMAMenuPage.lua"' not in (root/'modDesc.xml').read_text()
assert not (root/'scripts/FMAMenuPage.lua').exists() and not (root/'gui/FMAMenu.xml').exists()
hud_source=(root/'scripts/FMAHud.lua').read_text(encoding='utf-8')
assert 'if guiVisible or dialogVisible then return end' in hud_source
assert 'function FMAHud.mouseEvent(c,px,py,isDown,isUp,button)' in hud_source
assert 'function FMAHud.releaseMouse(c)' in hud_source
assert 'g_inputBinding.setShowMouseCursor' in hud_source
assert 'function FMAHud.cardGeometry()' in hud_source and 'function FMAHud.cardRect(d,index)' in hud_source
assert 'SPUSTIT VYBRANÉ' in hud_source and "tag='SPUSTIT'" in hud_source

# Movement/procurement gates learned from the user's Karpatsky venkov save.
assert (root/'scripts/FMATransfer.lua').is_file(), 'Courseplay transfer layer is required'
transfer_source=(root/'scripts/FMATransfer.lua').read_text(encoding='utf-8')
assert 'CpAIJob.setupTasks(self,isServer)' in transfer_source and 'findPathToGoal' in transfer_source
assert 'g_modManager.CP_MOD_NAME' in transfer_source and 'candidate[modName]' in transfer_source, 'Courseplay private globals must be resolved from its mod environment'
assert 'tableIndexEnvironment' in transfer_source and 'customEnvironment' in transfer_source, 'Courseplay environment lookup must survive GIANTS custom environments'
assert 'ignoreTrailerAtStartRange' in transfer_source, 'Long trailer trains need Courseplay obstacle-at-start recovery'
assert 'goalNodeInvalid==true' in transfer_source and 'transferGoalCandidates' in transfer_source, 'Invalid CP goal nodes must rotate through nearby map-validated candidates'
assert 'jobVehicle(self.job)' in transfer_source, 'Transfer task must recover its vehicle at runtime instead of indexing nil'
assert 'self.fmaDirectApproach=false' in transfer_source and 'if self.directApproach then' in transfer_source, 'Final hitch approach must bypass global pathfinding near implement collisions'
assert 'self.recoveryReverse and 2.2 or 2.8' in transfer_source and 'self:checkProximitySensors(not self.recoveryReverse)' in transfer_source, 'Physical coupling must cap speed and probe obstacles in either direction'
ai_source=(root/'scripts/FMAAI.lua').read_text(encoding='utf-8')
assert 'transfer.nativeSelected' in ai_source and 'GIANTS_GOTO' in ai_source, 'Normal travel must prefer native FS25 AI navigation'
assert 'COURSEPLAY_DIRECT_APPROACH' in ai_source and 'COURSEPLAY_FALLBACK' in ai_source and 'transfer.cpSelected' in ai_source, 'Courseplay bridge remains a local/precision fallback'
assert 'job.showNotification=function() end' in ai_source and 'fmaAuxiliaryTransfer=true' in ai_source, 'Auxiliary transfer jobs must not announce themselves as completed farm work'
travel_modules=['FMABaleStorage.lua','FMAFleetCoordinator.lua','FMABunkerCoordinator.lua','FMAServiceManager.lua','FMAAssembler.lua','FMAHeaderTransport.lua','FMARefillManager.lua','FMAAutoRoute.lua','FMALivestockCoordinator.lua','FMAFarmBrain.lua','FMAReturnManager.lua']
for name in travel_modules:
    source=(root/'scripts'/name).read_text(encoding='utf-8')
    assert 'createRegisteredJob("GOTO"' not in source and "createRegisteredJob('GOTO'" not in source, f'{name} bypasses unified transfer layer'
controller_source=(root/'scripts/FMAController.lua').read_text(encoding='utf-8')
assert 'transferRegistrationElapsed' in controller_source and 'FMATransfer.ensureRegistered(self)' in controller_source, 'Courseplay transfer registration must self-heal after load-order delays'
assert 'function FMAController:issueCounts()' in controller_source and 'classifyIssue' in controller_source, 'HUD must separate runtime errors from farm actions'
assert 'běžné přejezdy používají nativní AI FS25' in controller_source and 'warn("transfer"' in controller_source, 'Broken optional CP transfer bridge must not brick normal FS25 travel'
compat_source=(root/'scripts/FMACompatibility.lua').read_text(encoding='utf-8')
cp_source=(root/'scripts/FMACourseplay.lua').read_text(encoding='utf-8')
assert 'FMACourseplay.startFieldwork(controller,record,task)' in ai_source and 'startCpAtFirstWp' in cp_source, 'Courseplay fieldwork must use its public external-mod start interface'
assert 'stageFieldwork' in cp_source and 'PŘEJEZD K POLI · FS25 AI' in cp_source, 'Remote field machines must stage with native FS25 travel before direct Courseplay hand-off'
assert 'adoptExistingFieldwork' in cp_source and 'PRÁCE · COURSEPLAY (PŘEVZATO)' in cp_source, 'Manual H/Courseplay work must be adopted into the existing FarmManager crew'
assert 'syncManagedHarvestSettings' in cp_source and 'automaticCutterAttach' in (root/'scripts/FMAFieldQuality.lua').read_text(encoding='utf-8'), 'Header-trailer combines must enable Courseplay automatic cutter attach before work'
assert 'course.reuse' in (root/'scripts/FMAFieldQuality.lua').read_text(encoding='utf-8'), 'Existing Courseplay course for the same live field must be reused'
assert 'fieldworkStartedAt' in controller_source and 'verifyFieldOrderComplete' in controller_source and 'awaitingWorldVerification' in controller_source, 'Field orders may close only after real work start and live FS25 state verification'
assert 'task.preferredVehicleKey=chain.record.key' in controller_source and 'local cpOwns=FMAFieldQuality' in controller_source, 'Preloaded header chain must be handed to Courseplay instead of custom outbound transport when CP supports it'
hud_source=(root/'scripts/FMAHud.lua').read_text(encoding='utf-8')
assert 'function FMAHud.openCard' in hud_source and 'function FMAHud.draw' in hud_source, 'The mouse card console must implement navigation and rendering'
assert 'local x,y,w,h=0.148,0.125,0.704,0.748' in hud_source, 'Card HUD geometry must be fixed and bounded'
assert 'FMAHud.cardRect(d,index)' in hud_source and 'function FMAHud.mouseEvent' in hud_source, 'Card draw and click geometry must remain coupled'
missing_main=controller_source.index('task.phase="DOKOUPIT TECHNIKU"')
stage_support=controller_source.index('preparePendingHarvestCrew',missing_main)
assert missing_main < stage_support and 'task.blockedByEquipment=true' in controller_source
assert 'NOVÁ TECHNIKA ROZPOZNÁNA' in controller_source
world_source=(root/'scripts/FMAWorld.lua').read_text(encoding='utf-8')
registry_source=(root/'scripts/FMAWorldRegistry.lua').read_text(encoding='utf-8')
assembler_source=(root/'scripts/FMAAssembler.lua').read_text(encoding='utf-8')
header_source=(root/'scripts/FMAHeaderTransport.lua').read_text(encoding='utf-8')
native_source=(root/'scripts/FMAGameNative.lua').read_text(encoding='utf-8')
assert 'function FMAWorld.machineClass' in world_source and 'TELEHAND' in native_source and "return 'telehandler','store'" in native_source, 'Telehandlers must come from native FS25 store categories, not filename heuristics'
assert 'function FMAGameNative.operatorState' in native_source and "manual=entered and not aiActive" in native_source, 'Cab presence must not equal manual takeover while AI is active'
assert 'function FMAWorldRegistry.update' in registry_source and 'controller.digitalMapDirty=true' in registry_source and 'controller.elapsed=(controller.settings.scanSeconds or 12)*1000' in registry_source, 'Live world changes must force remap/replan'
assert "return false,'storeCategory:'" in native_source, 'Unknown autonomous field power units must be rejected instead of guessed'
assert 'directApproach=precise' in assembler_source and 'probeRadius=precise and nil' in assembler_source, 'Assembly must use staging plus local precision approach'
assert 'FMAWorld.children(carrier.object)' in header_source, 'Preloaded dynamic cutter must be discovered from the physical carrier tree'
fleet_source=(root/'scripts/FMAFleetCoordinator.lua').read_text(encoding='utf-8')
assert 'crewAssignments' in fleet_source and 'registerCrew' in fleet_source and 'manual takeover' in fleet_source.lower(), 'Harvest crews must persist independently of one AI job'
assert 'CREW CONTROL' in registry_source, 'Crew control modes must be exported in diagnostics'
assert "if harvester and not harvester.isForageHarvester then" in fleet_source, 'Grain combine must not be hard-blocked by unavailable haulage'
brain_source=(root/'scripts/FMAFarmBrain.lua').read_text(encoding='utf-8')
assert 'sellTriggerNode' in brain_source and 'workshopPose' in brain_source, 'Workshop navigation must use the real vehicle trigger instead of placeable root'

enterprise_source=(root/'scripts/FMAEnterprise.lua').read_text(encoding='utf-8')
assert 'FS25 and Courseplay remain the authoritative' in enterprise_source and 'operatorMode' in enterprise_source
assert 'a.task.state="running";a.task.phase="RUČNÍ ČLEN ČETY"' in controller_source, 'Manual takeover must keep the work order alive'
lifecycle_source=(root/'scripts/FMALifecycle.lua').read_text(encoding='utf-8')
assert "role.state='PLAYER'" in lifecycle_source and 'stále člen čety' in lifecycle_source, 'Manual unloader must remain reserved to its crew'
assert 'if guiVisible or dialogVisible then return end' in hud_source and 'FMAHud.cardGeometry()' in hud_source, 'Operator console must not render over FS25 ESC menu'


for lua in (root/'scripts').glob('*.lua'):
    if lua.name != 'FMAGameNative.lua':
        assert 'getIsEntered' not in lua.read_text(encoding='utf-8'), f'{lua.name} bypasses unified operatorState'

# Proactive regression gates for the user's current farm: the mod must not touch audio,
# must not hook the base save serializer, and must ship the desktop/fallback report exporter.
all_lua="\n".join(p.read_text(encoding="utf-8") for p in (root/"scripts").glob("*.lua"))
for forbidden in ("setMasterVolume", "setGameVolume", "setVehicleVolume", "setEnvironmentVolume", "setAudioVolume"):
    assert forbidden not in all_lua, f"Farm Manager must not change audio: {forbidden}"
for forbidden in ("VehicleSystem.save=", "FSCareerMissionInfo.saveToXMLFile=", "CareerMissionInfo.saveToXMLFile="):
    assert forbidden not in all_lua, f"Farm Manager must not hook base save serializer: {forbidden}"
controller_source=(root/"scripts/FMAController.lua").read_text(encoding="utf-8")
assert 'savegameDirectory.."/farmManagerAI_diagnostic.txt"' not in controller_source, "Diagnostics must never open a file inside savegameN"
ops=(root/"scripts/FMAOpsLog.lua").read_text(encoding="utf-8")
assert "FS25_FarmManagerAI_LOG.txt" in ops and "FS25_FarmManagerAI_DIAGNOSTIC.txt" in ops
assert "Desktop" in ops and "io.open" in ops
assert 'io.open(source' not in ops and '"rb"' not in ops and '"a"' not in ops, "Manager log must use bounded in-memory rewrite only"

icon=(root/'icon.dds').read_bytes(); panel=(root/'ui/white.dds').read_bytes()
assert icon[:4]==b'DDS ' and icon[84:88] in (b'DXT1',b'DXT3',b'DXT5'), 'icon.dds must be block-compressed'
assert panel[:4]==b'DDS ' and panel[84:88] in (b'DXT1',b'DXT3',b'DXT5'), 'ui/white.dds must be block-compressed'
manifest=root/'docs/MANIFEST.sha256'
manifest.parent.mkdir(parents=True,exist_ok=True)
files=sorted(p for p in root.rglob('*') if p.is_file() and p!=manifest and '__pycache__' not in p.parts)
manifest.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(root).as_posix()+'\n' for p in files))
files.append(manifest)
out.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
    for p in sorted(files):
        item=zipfile.ZipInfo(p.relative_to(root).as_posix(),(2026,9,29,18,0,0))
        item.compress_type=zipfile.ZIP_DEFLATED
        item.external_attr=0o100644 << 16
        archive.writestr(item,p.read_bytes())
with zipfile.ZipFile(out) as archive:
    assert archive.testzip() is None
    assert 'modDesc.xml' in archive.namelist()
    assert not any(n.startswith('/') or '..' in Path(n).parts for n in archive.namelist())
print(json.dumps({'file':str(out),'bytes':out.stat().st_size,'files':len(files),'lua_sources':len(source_files),
    'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'zip_integrity':'passed','xml_manifest':'passed','FS25_runtime_tested':False},indent=2))
# Runtime-log regressions for Carpathian field navigation / public consumables (0.20.9).
# This independent post-build gate is deliberately placed after archive validation.
assert 'function FMAFleetCoordinator.fieldWaitingCandidates' in (root/'scripts/FMAFleetCoordinator.lua').read_text(), 'Field-entry candidate generator missing'
assert 'fieldOutboundCandidates' in (root/'scripts/FMAHeaderTransport.lua').read_text(), 'Header-carrier alternate entry routes missing'
assert 'manualSupplySources' in (root/'scripts/FMARefillManager.lua').read_text(), 'Public lime source discovery missing'
assert 'WAIT_MATERIAL' in (root/'scripts/FMALiveTelemetry.lua').read_text(), 'Manual material waiting must appear in LIVE status'
assert 'SAFE_ESC noNativeTab=' in (root/'scripts/FMAController.lua').read_text(), 'ESC safety diagnostics must remain intact'
