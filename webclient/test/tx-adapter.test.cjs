const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require.resolve('../app.js'),'utf8');
const A='0x'+'11'.repeat(20),B='0x'+'22'.repeat(20);
function region(start,end){return source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));}
const authCode=region('function localTransactionMode(tx) {','// Give the reflected half');
function auth(overrides={}){
 const c={window:{STICKY_CONFIG:{}},location:{hostname:'sticky.example'},viewAs:null,walletAccount:null,$:id=>({value:id==='rpc'?'https://rpc.example':A}),URL,...overrides};vm.createContext(c);vm.runInContext(authCode,c);return c;
}
test('account preview and demo cannot send even with a connected wallet',()=>{
 assert.throws(()=>auth({viewAs:B,walletAccount:A}).txAccount(),/Exit account preview/);
 assert.throws(()=>auth({window:{__DEMO_RPC:()=>{},STICKY_CONFIG:{}},walletAccount:A}).txAccount(),/demo is read only/);
});
test('editable account field authorizes only explicit loopback local development',()=>{
 assert.throws(()=>auth().txAccount(),/Connect a wallet/);
 assert.throws(()=>auth({window:{STICKY_CONFIG:{localMode:true}}}).txAccount(),/Connect a wallet/);
 const c=auth({window:{STICKY_CONFIG:{localMode:true}},location:{hostname:'localhost'},$:id=>({value:id==='rpc'?'http://127.0.0.1:8545':A})});
 assert.equal(c.txAccount(),A);assert.equal(c.localTransactionMode({rpcUrl:'https://remote.example'}),false);
});
test('frozen caller sender cannot be silently replaced after wallet account changes',async()=>{
 let prepared=null;const c={txAccount:()=>B,ctx:{chainId:1},stickyDeploymentFor:()=>({rpcUrl:'https://rpc.example'}),getTxEngine:()=>({prepare:async(...args)=>{prepared=args;return{id:'x'};}}),runSavedTransactions:async()=>true};
 vm.createContext(c);vm.runInContext(region('async function confirmAndRun(title, txs, summary = [], hooks = {}) {','async function resumeSavedTransactions() {'),c);
 await assert.rejects(c.confirmAndRun('Stick',[{from:A,to:B,data:'0x'}]),/account changed/);assert.equal(prepared,null);
});
test('plan snapshots chain RPC and account before persisted review',async()=>{
 let prepared=null;const c={txAccount:()=>A,ctx:{chainId:1},stickyDeploymentFor:chain=>({rpcUrl:`https://rpc.example/${chain}`}),getTxEngine:()=>({prepare:async(...args)=>{prepared=args;return{id:'x'};}}),runSavedTransactions:async()=>true};
 vm.createContext(c);vm.runInContext(region('async function confirmAndRun(title, txs, summary = [], hooks = {}) {','async function resumeSavedTransactions() {'),c);
 await c.confirmAndRun('Stick',[{from:A,to:B,data:'0x',chainId:10}]);assert.equal(prepared[1][0].from,A);assert.equal(prepared[1][0].chainId,10);assert.equal(prepared[1][0].rpcUrl,'https://rpc.example/10');
});
test('guard blocks duplicate clicks, catches synchronous failures, and restores control',async()=>{
 const button={disabled:false,closest:()=>null};const notices=[];const c={document:{activeElement:button},confirmProgress:-1,$:()=>({open:false}),txStatus:m=>notices.push(m),inlineStatus:(_a,m)=>notices.push(m),txEngine:null};vm.createContext(c);vm.runInContext(region('function guard(fn) {','$("load").onclick'),c);
 let release,calls=0;const handler=c.guard(()=>{calls++;return new Promise(r=>release=r);});const first=handler({currentTarget:button});await handler({currentTarget:button});assert.equal(calls,1);assert.equal(button.disabled,true);release();await first;assert.equal(button.disabled,false);
 await c.guard(()=>{throw Error('bad input');})({currentTarget:button});assert.deepEqual(notices,['bad input']);assert.equal(button.disabled,false);
});
test('closing a review resolves cancellation and stops remaining execution steps',()=>{
 let answer;const elements={'confirm-dialog':{close(){}},'cd-confirm':{disabled:false},'cd-cancel':{textContent:''}};
 const c={confirmResolve:value=>answer=value,txRunCancelled:false,$:id=>elements[id]};vm.createContext(c);vm.runInContext(region('function settleConfirm(ok) {','async function runSavedTransactions('),c);
 c.settleConfirm(false);assert.equal(answer,false);assert.equal(c.txRunCancelled,true);assert.equal(c.confirmResolve,null);
});

test('coordinator persists its prepared marker after engine preparation and before execution',async()=>{
 const order=[];const c={txAccount:()=>A,ctx:{chainId:1},stickyDeploymentFor:()=>({rpcUrl:'https://rpc.example'}),getTxEngine:()=>({prepare:async()=>{order.push('engine-prepared');return{id:'saved'};}}),runSavedTransactions:async()=>{order.push('run');return true;}};
 vm.createContext(c);vm.runInContext(region('async function confirmAndRun(title, txs, summary = [], hooks = {}) {','async function resumeSavedTransactions() {'),c);
 await c.confirmAndRun('Bridge',[{from:A,to:B,data:'0x'}],[],{onPrepared:async(session)=>{assert.equal(session.id,'saved');order.push('coordinator-persisted');}});
 assert.deepEqual(order,['engine-prepared','coordinator-persisted','run']);
 order.length=0;
 await assert.rejects(c.confirmAndRun('Bridge',[{from:A,to:B,data:'0x'}],[],{onPrepared:async()=>{throw Error('save failed');}}),/save failed/);
 assert.deepEqual(order,['engine-prepared']);
});
