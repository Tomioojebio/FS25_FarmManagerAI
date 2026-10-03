-- Differential verification of physical hitch direction & AI takeover.
dofile('scripts/FMAAssembler.lua')
local count=0
local function test(name,func)
    local ok,err=pcall(func)
    if not ok then error(name..': '..tostring(err),0) end
    count=count+1
    print('PASS PHYSICAL39 '..name)
end
FMAUtil={call=function(obj,method,...) return obj and obj[method] and obj[method](obj,...) end, owner=function()return 1 end,
 position=function(o)return o.px,o.pz end, name=function(o)return o.name or '?' end}
function getWorldTranslation(node) return node.x,node.y or 0,node.z end
function worldToLocal(node,x,y,z)
    return x-node.x,y-node.y,z-node.z
end
function localDirectionToWorld(node,x,y,z) return 0,0,1 end
MathUtil={getYRotationFromDirection=function(dx,dz)return math.atan2 and math.atan2(dx,dz) or math.atan(dx,dz) end,
 getDirectionFromYRotation=function(a)return math.sin(a),math.cos(a) end}
local function makePlan(offset)
 local root={x=0,y=0,z=0};local joint={node={x=0,z=offset}};local inp={node={x=50,z=100}}
 local power={object={rootNode=root,px=0,pz=0,spec_attacherJoints=true}}
 local tool={object={spec_attachable={inputAttacherJoints={inp}},px=50,pz=100}}
 return {power=power,tool=tool,joint=joint,input=inp,inputIndex=1}
end
test('REAR hitch candidate backs up',function()
 local p=FMAAssembler.alignmentCandidates(makePlan(-2),{attachAlignmentOffset=1.8})
 assert(p[2].reverse==true and p[2].localHitchZ == -2)
 assert(p[4].hitchGap<=0.4)
end)
test('FRONT hitch approaches forwards',function()
 local p=FMAAssembler.alignmentCandidates(makePlan(2),{attachAlignmentOffset=1.8})
 assert(p[2].reverse==false and p[2].localHitchZ == 2)
end)
test('STAGING front/back inherits coupling heading',function()
 local p=makePlan(-2)
 local seq=FMAAssembler.stagingCandidates(p,{assemblyStagingDistance=10})
 assert(seq[1].label=='rearJoint')
 local poses=FMAAssembler.alignmentCandidates(p,{})
 assert(math.abs(seq[1].angle-poses[2].angle)<0.0001)
end)
test('NEVER try precision drive without verified hitch pose',function()
 local p=FMAAssembler.alignmentCandidates({power={object={px=0,pz=0},px=0,pz=0},tool={object={px=50,pz=100}}},{})
 assert(#p>=1 and p[1].mode=='staging' and p[1].reverse==nil)
end)
print('PHYSICAL39 COUNT '..count)
-- The shared Courseplay start callback must never be mistaken for the bunker job.
dofile('scripts/FMACourseplay.lua')
FMADiagnostics={trace=function(err)return tostring(err)end,event=function()end}
local currentJob={cpJobParameters={
 siloPosition={setPosition=function(self,x,z)self.x=x;self.z=z end},
 startPosition={setPosition=function(self,x,z)self.x=x;self.z=z end},
 stopWithCompactedSilo={setValue=function()end}
}}
local alienJob={}
local called=0
local vehicle={px=0,pz=0,
 getCanStartCpBunkerSiloWorker=function()return true end,
 getIsAIActive=function()return false end,
 getCpBunkerSiloWorkerJob=function()return currentJob end,
 getCpStartableJob=function()return alienJob end,
 getIsMotorStarted=function()return true end,
 startCpAtFirstWp=function()called=called+1;return true end}
local c={bunkers={{geometry={center={x=10,z=20}}}}}
local rec={object=vehicle,name='test tractor'}
test('CP refuses another job under shared start',function()
 local job,reason=FMACourseplay.startBunker(c,rec,10,20,{bunkerIndex=1})
 assert(job==nil and reason:find('jinou úlohu') and called==0)
end)
test('CP sends correct bunker job only',function()
 alienJob=currentJob
 local job,reason=FMACourseplay.startBunker(c,rec,10,20,{bunkerIndex=1})
 assert(job==currentJob and called==1 and currentJob.fmaManaged==true)
end)
print('PHYSICAL39 + CP COUNT '..count)
