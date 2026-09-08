const test = require('node:test');
const assert = require('node:assert/strict');
const { createEngine, normalizeTx } = require('../tx-engine.js');
const A = '0x' + '11'.repeat(20), B = '0x' + '22'.repeat(20), H = '0x' + 'ab'.repeat(32), BH = '0x' + 'cd'.repeat(32);
const tx = { chainId: 1, from: A, to: B, data: '0x1234', value: '0x0', rpcUrl: 'https://example.com', label: 'Stick', args: [] };
function fixture(overrides={}) {
  const db = new Map(); let sends = 0; let accounts = [A]; let walletChain = '0x1'; let rpcChain = '0x1'; let mined = true; let submitted = false; let next = null;
  const storage = { getItem: k => db.get(k) ?? null, setItem: (k,v) => db.set(k,v), removeItem: k => db.delete(k) };
  const transactions = new Map(); const receipts = new Map();
  const wallet = { request: async ({method, params}) => {
    if (method === 'eth_accounts') return accounts;
    if (method === 'eth_chainId') return walletChain;
    if (method === 'eth_sendTransaction') {
      sends++;
      const saved = [...db.values()].map(JSON.parse).find(value => Array.isArray(value.steps));
      assert.equal(saved.steps.find(s => s.state==='submitting')?.tx.to, params[0].to, 'journal saved before wallet submission');
      submitted = true;
      if (next) return next();
      const hash = sends===1 ? H : '0x'+String(sends).padStart(64,'0');
      transactions.set(hash,{...params[0],input:params[0].data,hash,blockHash:BH,blockNumber:'0xb',nonce:'0x0',chainId:'0x1'});
      receipts.set(hash,{transactionHash:hash,blockHash:BH,blockNumber:'0xb',status:'0x1',logs:[]});
      return hash;
    }
    throw Error(method);
  }};
  const rpc = async (plan,method,params) => {
    assert.equal(plan.rpcUrl, 'https://example.com/');
    if (overrides.rpc) { const value = await overrides.rpc(plan,method,params); if (value!==undefined) return value; }
    if(method==='eth_chainId') return rpcChain;
    if(method==='eth_call') return '0x';
    if(method==='eth_blockNumber') return '0xa';
    if(method==='eth_getTransactionCount') return '0x0';
    if(method==='eth_getCode') return '0x';
    if(method==='eth_getTransactionByHash') return mined ? transactions.get(params[0]) ?? null : null;
    if(method==='eth_getTransactionReceipt') return mined ? receipts.get(params[0]) ?? null : null;
    if(method==='eth_getBlockByNumber') return {hash:BH,number: params[0]==='finalized' ? '0xff' : params[0]};
    throw Error(method);
  };
  let lockHeld=false;
  const locks = {request: async (_name,_opts,cb) => {
    if(lockHeld) return cb(null);
    lockHeld=true;try{return await cb({name:'lock'});}finally{lockHeld=false;}
  }};
  const options = { storage, locks, rpc, wallet:()=>wallet, ensureChain:async ()=>{}, pollAttempts:1, randomId:()=>String(Math.random()), ...overrides };
  if(overrides.rpc) options.rpc=rpc;
  const engine=createEngine(options);
  return {engine, options, db, storage, wallet, transactions, receipts, get sends(){return sends;}, get submitted(){return submitted;}, setAccounts:x=>accounts=x, setChain:x=>walletChain=x, setRpcChain:x=>rpcChain=x, setMined:x=>mined=x, setNext:x=>next=x};
}
const review = async () => true;

test('freezes reviewed bytes and persists intent before wallet submission',async()=>{
 const f=fixture(); const input={...tx}; const session=await f.engine.prepare('Stick',[input]); input.data='0x9999';
 const result=await f.engine.run({review,sessionId:session.id});
 assert.equal(result.session.steps[0].tx.data,'0x1234'); assert.equal(result.session.steps[0].state,'confirmed'); assert.equal(f.sends,1);
});
test('cancelled review never submits and remains recoverable',async()=>{
 const f=fixture();await f.engine.prepare('Stick',[tx]);const result=await f.engine.run({review:async()=>false});
 assert.equal(result.cancelled,true);assert.equal(f.sends,0);assert.equal(f.engine.load().steps[0].state,'ready');
});
test('confirmed dependency is skipped after later wallet rejection and reload',async()=>{
 const f=fixture();await f.engine.prepare('Sequence',[tx,{...tx,data:'0x5678'}]);
 let prompts=0; const orig=f.wallet.request;
 f.wallet.request=async args=>{if(args.method==='eth_sendTransaction'&&++prompts===2)throw Object.assign(Error('rejected'),{code:4001});return orig(args);};
 await assert.rejects(f.engine.run({review}),/cancelled/);
 assert.deepEqual(f.engine.load().steps.map(s=>s.state),['confirmed','rejected']);
 f.wallet.request=orig;
 const resumed=createEngine(f.options);const done=await resumed.run({review});
 assert.deepEqual(done.session.steps.map(s=>s.state),['confirmed','confirmed']); assert.equal(f.sends,2);
});
test('unknown wallet failure survives reload and cannot automatically repeat',async()=>{
 const f=fixture();await f.engine.prepare('Stick',[tx]);f.setNext(()=>{throw Error('network lost after submitting');});
 await assert.rejects(f.engine.run({review}),/outcome is unknown/);assert.equal(f.sends,1);
 const reloaded=createEngine(f.options);
 await assert.rejects(reloaded.run({review}),/did not return a transaction hash/);assert.equal(f.sends,1);
 await assert.rejects(reloaded.clear(),/may still execute/);
 await assert.rejects(reloaded.prepare('Another',[{...tx,data:'0x5678'}]),/Finish or safely dismiss/);
});
test('receipt timeout retains exact hash and resumes without a second wallet request',async()=>{
 const f=fixture();await f.engine.prepare('Stick',[tx]);f.setMined(false);
 await assert.rejects(f.engine.run({review}),/still unresolved/);assert.equal(f.engine.load().steps[0].hash,H);
 f.setMined(true);const done=await f.engine.run({review});assert.equal(done.session.steps[0].state,'confirmed');assert.equal(f.sends,1);
});
test('wallet account or RPC chain mismatch fails before wallet submission',async()=>{
 for(const mode of ['account','walletChain','rpcChain']) {
  const f=fixture();await f.engine.prepare('Stick',[tx]);
  if(mode==='account')f.setAccounts([B]);if(mode==='walletChain')f.setChain('0xa');if(mode==='rpcChain')f.setRpcChain('0xa');
  await assert.rejects(f.engine.run({review}),/account|chain/i);assert.equal(f.sends,0);assert.equal(f.engine.load().steps[0].state,'ready');
 }
});
test('storage unavailable or corrupt fails closed',async()=>{
 const f=fixture(); f.storage.setItem=()=>{throw Error('quota');};await assert.rejects(f.engine.prepare('Stick',[tx]),/could not be saved/);assert.equal(f.sends,0);
 const g=fixture();g.db.set('sticky.transactions.v1','broken');assert.throws(()=>g.engine.load(),/recovery is required/);await assert.rejects(g.engine.prepare('Stick',[tx]));
});
test('cross-tab and same-tab attempts are rejected while a review holds the lock',async()=>{
 const f=fixture();await f.engine.prepare('Stick',[tx]);let release; const waiting=f.engine.run({review:()=>new Promise(r=>release=r)});
 await new Promise(r=>setImmediate(r));await assert.rejects(f.engine.run({review}),/already being reviewed/);
 const other=createEngine(f.options);await assert.rejects(other.run({review}),/Another Sticky tab/);
 release(false);await waiting;assert.equal(f.sends,0);
});
test('closing review flow between steps stops subsequent sends',async()=>{
 const f=fixture();await f.engine.prepare('Sequence',[tx,{...tx,data:'0x5678'}]);
 const result=await f.engine.run({review,shouldContinue:()=>f.sends===0});assert.equal(result.cancelled,true);assert.equal(f.sends,1);assert.deepEqual(result.session.steps.map(s=>s.state),['confirmed','ready']);
});
test('launch payment records cannot be replaced or cleared until receipt is acknowledged',async()=>{
 const f=fixture();await f.engine.prepare('Pay quote',[{...tx,sessionTag:'launch:123'}]);await f.engine.run({review});
 await assert.rejects(f.engine.clear(),/Resume the launch/);await assert.rejects(f.engine.prepare('New',[tx]),/Finish or safely dismiss/);
 await f.engine.acknowledge(f.engine.load().id);await f.engine.clear();assert.equal(f.engine.load(),null);
});
test('false-returning ERC20 approval is caught before opening wallet',async()=>{
 const f=fixture({rpc:async(_tx,method)=>method==='eth_call'?'0x'+'0'.repeat(64):undefined});
 await f.engine.prepare('Approve',[{...tx,data:'0x095ea7b3'+'0'.repeat(128)}]);await assert.rejects(f.engine.run({review}),/did not accept this approval/);assert.equal(f.sends,0);
});
test('normalization rejects malformed addresses, quantities, and remote cleartext RPC',()=>{
 for(const invalid of [{from:'0x12'},{to:'0x'+'0'.repeat(40)},{value:-1},{value:1.1},{data:'0x123'},{rpcUrl:'http://public.example.com'},{chainId:0}])assert.throws(()=>normalizeTx({...tx,...invalid}));
});

test('a cancelled unsubmitted ordinary plan does not block a different action',async()=>{
 const f=fixture();await f.engine.prepare('Stick',[tx]);await f.engine.run({review:async()=>false});
 const next=await f.engine.prepare('Another action',[{...tx,data:'0x5678'}]);assert.equal(next.steps[0].tx.data,'0x5678');assert.equal(f.sends,0);
});
test('clearing or replacing a completed plan rechecks its canonical receipt',async()=>{
 for(const operation of ['clear','replace']) {
  const f=fixture();await f.engine.prepare('Stick',[tx]);await f.engine.run({review});f.setMined(false);
  await assert.rejects(operation==='clear'?f.engine.clear():f.engine.prepare('Another',[{...tx,data:'0x5678'}]),/may still execute|Finish or safely dismiss/);
  assert.equal(f.engine.load().steps[0].state,'pending');assert.equal(f.sends,1);
 }
});

test('atomic cancellation binds the exact tagged session and persists a discard tombstone',async()=>{
 const f=fixture();const session=await f.engine.prepare('Prepare bridge',[{...tx,sessionTag:'sticky-bridge:123'}]);
 await assert.rejects(f.engine.discardUnsubmitted('other-id'),/saved transaction changed/);
 await f.engine.discardUnsubmitted(session.id);
 assert.equal(f.engine.load(),null);assert.equal(f.engine.wasDiscarded(session.id,'sticky-bridge:123'),true);assert.equal(f.engine.wasDiscarded(session.id,'sticky-bridge:456'),false);
 await assert.rejects(f.engine.run({review,sessionId:session.id}),/saved transaction changed/);assert.equal(f.sends,0);
});
test('a crash between cancellation tombstone and journal deletion never revives the old plan',async()=>{
 const f=fixture();const session=await f.engine.prepare('Prepare bridge',[{...tx,sessionTag:'sticky-bridge:123'}]);
 f.storage.removeItem=()=>{throw Error('crash');};await assert.rejects(f.engine.discardUnsubmitted(session.id),/crash/);
 assert.equal(f.engine.wasDiscarded(session.id,'sticky-bridge:123'),true);
 const reloaded=createEngine(f.options);assert.equal(reloaded.load(),null);await assert.rejects(reloaded.run({review,sessionId:session.id}),/saved transaction changed/);
 const next=await reloaded.prepare('New',[tx]);assert.notEqual(next.id,session.id);await reloaded.discardUnsubmitted(session.id);assert.equal(reloaded.load().id,next.id);
});
test('cancellation blocks unknown submissions, confirmed transfers, and unknown prior history',async()=>{
 const unknown=fixture();const u=await unknown.engine.prepare('Bridge',[{...tx,sessionTag:'bridge'}]);unknown.setNext(()=>{throw Error('lost');});await assert.rejects(unknown.engine.run({review}));await assert.rejects(unknown.engine.discardUnsubmitted(u.id),/may have been submitted/);assert.equal(unknown.engine.wasDiscarded(u.id),false);
 const completed=fixture();const c=await completed.engine.prepare('Bridge',[{...tx,sessionTag:'bridge'}]);await completed.engine.run({review});await assert.rejects(completed.engine.discardUnsubmitted(c.id),/may have been submitted/);
 const history=fixture();const h=await history.engine.prepare('Bridge',[{...tx,sessionTag:'bridge'}]);const raw=history.engine.load();raw.steps[0].attempts=[{state:'unknown'}];history.db.set('sticky.transactions.v1',JSON.stringify(raw));await assert.rejects(history.engine.discardUnsubmitted(h.id),/previous transaction attempt is unresolved/);
});
test('an explicit wallet rejection can be cancelled without losing an unsubmitted bridge intent',async()=>{
 const f=fixture();const session=await f.engine.prepare('Bridge',[{...tx,sessionTag:'bridge'}]);f.setNext(()=>{throw Object.assign(Error('reject'),{code:4001});});await assert.rejects(f.engine.run({review}),/cancelled/);
 await f.engine.discardUnsubmitted(session.id);assert.equal(f.engine.wasDiscarded(session.id,'bridge'),true);assert.equal(f.sends,1);
});
test('canonical approval may remain while its unsubmitted bridge transfer is cancelled',async()=>{
 const f=fixture();const approve={...tx,data:'0x095ea7b3'+'0'.repeat(24)+B.slice(2)+'0'.repeat(63)+'1',sessionTag:'bridge'};
 const session=await f.engine.prepare('Approve then bridge',[approve,{...tx,sessionTag:'bridge'}]);await f.engine.run({review,shouldContinue:()=>f.sends===0});assert.deepEqual(f.engine.load().steps.map(s=>s.state),['confirmed','ready']);
 await f.engine.discardUnsubmitted(session.id);assert.equal(f.engine.wasDiscarded(session.id,'bridge'),true);assert.equal(f.sends,1);
});
test('a missing approval receipt or value-carrying approval cannot authorize cancellation',async()=>{
 for(const mode of ['missing','value']) {
  const f=fixture();const approve={...tx,data:'0x095ea7b3'+'0'.repeat(24)+B.slice(2)+'0'.repeat(63)+'1',value:mode==='value'?'0x1':'0x0',sessionTag:'bridge'};
  const session=await f.engine.prepare('Approve then bridge',[approve,{...tx,sessionTag:'bridge'}]);await f.engine.run({review,shouldContinue:()=>f.sends===0});if(mode==='missing')f.setMined(false);
  await assert.rejects(f.engine.discardUnsubmitted(session.id),/may have been submitted/);assert.equal(f.engine.wasDiscarded(session.id),false);
 }
});
test('transaction lock prevents a cancel/resume race between tabs',async()=>{
 const f=fixture();const session=await f.engine.prepare('Bridge',[{...tx,sessionTag:'bridge'}]);let release;const run=f.engine.run({review:()=>new Promise(r=>release=r)});await new Promise(r=>setImmediate(r));
 const other=createEngine(f.options);await assert.rejects(other.discardUnsubmitted(session.id),/Another Sticky tab/);release(false);await run;await other.discardUnsubmitted(session.id);assert.equal(f.sends,0);
});
test('a failed cancellation tombstone write retains the active transaction plan',async()=>{
 const f=fixture();const session=await f.engine.prepare('Bridge',[{...tx,sessionTag:'bridge'}]);const set=f.storage.setItem;f.storage.setItem=(key,value)=>{if(key.includes('.discarded.'))throw Error('quota');return set(key,value);};await assert.rejects(f.engine.discardUnsubmitted(session.id),/quota/);assert.equal(f.engine.load().id,session.id);assert.equal(f.engine.wasDiscarded(session.id),false);
});
