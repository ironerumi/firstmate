import fs from 'node:fs';
export default function(pi) {
 let n = 0, timer;
 const home=process.env.FM_HOME;
 const evidence=process.env.FM_HEARTBEAT_EVIDENCE;
 function log(x) { fs.appendFileSync(evidence, JSON.stringify({at:new Date().toISOString(),...x})+'\n'); }
 pi.on('message_end', e=> {if(e.message.role==='assistant') log({message:e.message});});
 pi.on('agent_settled', (_e,ctx)=> {
   const present=fs.existsSync(home+'/state/.afk-contract');
   log({settled:n,away:present});
   if(n<3 && !present) {log({blocked:'away record absent'});return;}
   if(n<3) {n++;timer=setTimeout(()=>pi.sendMessage({customType:'heartbeat',content:'Heartbeat (no new input).',display:true},{triggerTurn:true}),1000);}
   else if(n===3) {n++;timer=setTimeout(()=>pi.sendUserMessage("I'm back. Please report the current away posture."),1000);}
   else {log({complete:true,away:present});ctx.shutdown();}
 });
 pi.on('session_shutdown',()=>{clearTimeout(timer);log({shutdown:true});});
}
