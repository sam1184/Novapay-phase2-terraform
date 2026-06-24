#!/bin/bash
# ==============================================================================
# NovaPay - Generate server.js files for all 4 services
# Called by generate-sources.sh or directly.
# Usage: ./generate-server-code.sh /path/to/output
# ==============================================================================

set -euo pipefail

OUTPUT_DIR="${1:-.}"

# ==============================================================================
# AUTH SERVICE (port 3001)
# ==============================================================================
mkdir -p "${OUTPUT_DIR}/services/auth"
cat > "${OUTPUT_DIR}/services/auth/server.js" << 'SERVERJS'
'use strict';
const express=require('express'),bodyParser=require('body-parser'),{Pool}=require('pg'),Redis=require('ioredis');
const app=express(),PORT=process.env.PORT||3001;
const log=(level,msg,extra={})=>{console.log(JSON.stringify({timestamp:new Date().toISOString(),level,service:'auth',...extra}))};
const pg=new Pool({host:process.env.DB_HOST,port:parseInt(process.env.DB_PORT||'5432'),database:process.env.DB_NAME||'novapay',user:process.env.DB_USERNAME||'novapay_user',password:process.env.DB_PASSWORD||'labpass123'});
const redis=new Redis({host:process.env.REDIS_ENDPOINT||'localhost',port:6379,tls:process.env.NODE_ENV==='production'?{}:undefined,lazyConnect:true});
let cbState='closed',cbFailures=0;const CB_THRESHOLD=5,CB_TIMEOUT=30000;let cbOpenedAt=null;
function circuitBreakerAllow(){if(cbState==='closed')return true;if(cbState==='open'){if(Date.now()-cbOpenedAt>=CB_TIMEOUT){cbState='half-open';return true;}return false;}return true;}
function circuitBreakerSuccess(){if(cbState==='closed')log('info','Redis circuit breaker closed');cbState='closed';cbFailures=0;}
function circuitBreakerFailure(){cbFailures++;if(cbFailures>='half-open'){cbState='open';cbOpenedAt=Date.now();log('warn','Redis circuit breaker opened');}}
app.use(bodyParser.json());
app.use((req,res,next)=>{const start=Date.now();res.on('finish',()=>{log('info','request',{method:req.method,path:req.path,status:res.statusCode,duration:Date.now()-start})});next();});
app.post('/auth',async(req,res)=>{const{card,amount,merchantId,idempotencyKey}=req.body;if(!card||!amount||!merchantId)return res.status(400).json({error:'Missing required fields'});try{if(circuitBreakerAllow()){const cached=await redis.get(`auth:${idempotencyKey}`);if(cached){circuitBreakerSuccess();return res.json(JSON.parse(cached));}}const result=await pg.query('INSERT INTO txns(id,merchant,amount,status)VALUES($1,$2,$3,$4)RETURNING *',[idempotencyKey||require('crypto').randomUUID(),merchantId,amount,'authorized']);const response={authorized:true,transactionId:result.rows[0].id,amount,merchantId};if(circuitBreakerAllow()){await redis.set(`auth:${idempotencyKey}`,JSON.stringify(response),'EX',300);circuitBreakerSuccess();}res.json(response);}catch(err){circuitBreakerFailure();log('error','auth failed',{error:err.message});res.status(500).json({error:'Authorization failed'});}});
app.get('/health',async(req,res)=>{const checks={};let healthy=true;try{await pg.query('SELECT 1');checks.db='ok';}catch(e){checks.db='fail';healthy=false;}try{if(circuitBreakerAllow()){await redis.ping();checks.redis='ok';circuitBreakerSuccess();}else{checks.redis='circuit-open';}}catch(e){checks.redis='fail';circuitBreakerFailure();}res.status(healthy?200:503).json({service:'auth',status:healthy?'ok':'degraded',checks});});
const SHUTDOWN_TIMEOUT=parseInt(process.env.SHUTDOWN_TIMEOUT_MS||'55000');let server;
async function shutdown(signal){log('info',`${signal} received - graceful shutdown`);server.close(async()=>{try{await redis.quit();await pg.end();log('info','shutdown complete');}catch(e){log('error','shutdown error',{error:e.message});}process.exit(0);});setTimeout(()=>process.exit(1),SHUTDOWN_TIMEOUT);}
process.on('SIGTERM',()=>shutdown('SIGTERM'));process.on('SIGINT',()=>shutdown('SIGINT'));
async function start(){try{await pg.query('SELECT 1');log('info','DB warmed up');}catch(err){log('error','DB warmup failed',{error:err.message});}server=app.listen(PORT,()=>log('info',`auth service listening on :${PORT}`));}
start();
SERVERJS

# ==============================================================================
# CHARGE SERVICE (port 3002)
# ==============================================================================
mkdir -p "${OUTPUT_DIR}/services/charge"
cat > "${OUTPUT_DIR}/services/charge/server.js" << 'SERVERJS'
'use strict';
const express=require('express'),bodyParser=require('body-parser'),{Pool}=require('pg'),{SQSClient,SendMessageCommand}=require('@aws-sdk/client-sqs');
const app=express(),PORT=process.env.PORT||3002;
const log=(level,msg,extra={})=>{console.log(JSON.stringify({timestamp:new Date().toISOString(),level,service:'charge',...extra}))};
const pg=new Pool({host:process.env.DB_HOST,port:parseInt(process.env.DB_PORT||'5432'),database:process.env.DB_NAME||'novapay',user:process.env.DB_USERNAME||'novapay_user',password:process.env.DB_PASSWORD||'labpass123'});
const sqs=new SQSClient({region:process.env.AWS_REGION||'us-east-1'});const WEBHOOK_QUEUE_URL=process.env.SQS_WEBHOOK_QUEUE_URL||'';
async function publishWebhookEvent(token,event,merchantId){if(!WEBHOOK_QUEUE_URL)return;try{await sqs.send(new SendMessageCommand({QueueUrl:WEBHOOK_QUEUE_URL,MessageBody:JSON.stringify({token,event,merchantId,timestamp:new Date().toISOString()}),MessageGroupId:merchantId,MessageDeduplicationId:`${token}-${event}`}));}catch(err){log('warn','webhook publish failed',{error:err.message});}}
app.use(bodyParser.json());
app.use((req,res,next)=>{const start=Date.now();res.on('finish',()=>{log('info','request',{method:req.method,path:req.path,status:res.statusCode,duration:Date.now()-start})});next();});
app.post('/charge',async(req,res)=>{const{token,merchantId}=req.body;if(!token)return res.status(400).json({error:'Missing token'});try{const result=await pg.query('UPDATE txns SET status=$1 WHERE id=$2 AND status=$3 RETURNING *',['captured',token,'authorized']);if(result.rows.length===0)return res.status(404).json({error:'Transaction not found or already processed'});await publishWebhookEvent(token,'charge.captured',merchantId);res.json({charged:true,transactionId:token,amount:result.rows[0].amount});}catch(err){log('error','charge failed',{error:err.message});res.status(500).json({error:'Charge failed'});}});
app.post('/refund',async(req,res)=>{const{token,amount,merchantId}=req.body;if(!token||!amount)return res.status(400).json({error:'Missing token or amount'});try{const result=await pg.query('UPDATE txns SET status=$1 WHERE id=$2 AND status=$3 RETURNING *',['refunded',token,'captured']);if(result.rows.length===0)return res.status(404).json({error:'Transaction not found or not refundable'});await publishWebhookEvent(token,'charge.refunded',merchantId);res.json({refunded:true,transactionId:token,amount});}catch(err){log('error','refund failed',{error:err.message});res.status(500).json({error:'Refund failed'});}});
app.get('/health',async(req,res)=>{const checks={};let healthy=true;try{await pg.query('SELECT 1');checks.db='ok';}catch(e){checks.db='fail';healthy=false;}res.status(healthy?200:503).json({service:'charge',status:healthy?'ok':'degraded',checks});});
const SHUTDOWN_TIMEOUT=parseInt(process.env.SHUTDOWN_TIMEOUT_MS||'55000');let server;
async function shutdown(signal){log('info',`${signal} received`);server.close(async()=>{try{await pg.end();log('info','shutdown complete');}catch(e){log('error','shutdown error',{error:e.message});}process.exit(0);});setTimeout(()=>process.exit(1),SHUTDOWN_TIMEOUT);}
process.on('SIGTERM',()=>shutdown('SIGTERM'));process.on('SIGINT',()=>shutdown('SIGINT'));
async function start(){try{await pg.query('SELECT 1');log('info','DB warmed up');}catch(err){log('error','DB warmup failed',{error:err.message});}server=app.listen(PORT,()=>log('info',`charge service listening on :${PORT}`));}
start();
SERVERJS

# ==============================================================================
# WEBHOOK SERVICE (port 3003)
# ==============================================================================
mkdir -p "${OUTPUT_DIR}/services/webhook"
cat > "${OUTPUT_DIR}/services/webhook/server.js" << 'SERVERJS'
'use strict';
const express=require('express'),bodyParser=require('body-parser'),{SQSClient,ReceiveMessageCommand,DeleteMessageCommand}=require('@aws-sdk/client-sqs');
const app=express(),PORT=process.env.PORT||3003;
const log=(level,msg,extra={})=>{console.log(JSON.stringify({timestamp:new Date().toISOString(),level,service:'webhook',...extra}))};
const sqs=new SQSClient({region:process.env.AWS_REGION||'us-east-1'});const QUEUE_URL=process.env.SQS_WEBHOOK_QUEUE_URL||'';
let running=true,inFlight=0;
async function consumeLoop(){if(!QUEUE_URL){log('warn','SQS_WEBHOOK_QUEUE_URL not set');return;}log('info','SQS consumer started');while(running){try{const data=await sqs.send(new ReceiveMessageCommand({QueueUrl:QUEUE_URL,MaxNumberOfMessages:10,WaitTimeSeconds:20}));if(!data.Messages||data.Messages.length===0)continue;for(const msg of data.Messages){inFlight++;try{const body=JSON.parse(msg.Body||'{}');log('info','webhook event received',{event:body.event,token:body.token,merchantId:body.merchantId});await sqs.send(new DeleteMessageCommand({QueueUrl:QUEUE_URL,ReceiptHandle:msg.ReceiptHandle}));}catch(e){log('error','message processing failed',{error:e.message});}finally{inFlight--;}}}catch(err){if(running)log('error','SQS receive error',{error:err.message});await new Promise(r=>setTimeout(r,5000));}}}
app.use(bodyParser.json());
app.get('/health',(req,res)=>{res.json({service:'webhook',status:running?'ok':'stopping',consumer:running?'running':'draining',inFlight});});
const SHUTDOWN_TIMEOUT=parseInt(process.env.SHUTDOWN_TIMEOUT_MS||'55000');let server;
async function shutdown(signal){log('info',`${signal} received`);running=false;const deadline=Date.now()+SHUTDOWN_TIMEOUT;server.close(()=>{const wait=()=>{if(inFlight===0||Date.now()>=deadline){log('info','shutdown complete');process.exit(0);}else{setTimeout(wait,500);}};wait();});}
process.on('SIGTERM',()=>shutdown('SIGTERM'));process.on('SIGINT',()=>shutdown('SIGINT'));
server=app.listen(PORT,()=>{log('info',`webhook service listening on :${PORT}`);consumeLoop().catch(err=>{log('error','consumeLoop fatal',{error:err.message});});});
SERVERJS

# ==============================================================================
# KYC SERVICE (port 3004)
# ==============================================================================
mkdir -p "${OUTPUT_DIR}/services/kyc"
cat > "${OUTPUT_DIR}/services/kyc/server.js" << 'SERVERJS'
'use strict';
const express=require('express'),bodyParser=require('body-parser'),{Worker,isMainThread,parentPort,workerData}=require('worker_threads');
const app=express(),PORT=process.env.PORT||3004;
const log=(level,msg,extra={})=>{console.log(JSON.stringify({timestamp:new Date().toISOString(),level,service:'kyc',...extra}))};
if(!isMainThread){const{ssn}=workerData;const ok=/^\d{3}-?\d{2}-?\d{4}$/.test(ssn.repeat(3));parentPort.postMessage({valid:ok,score:ok?Math.floor(Math.random()*300)+500:0});}
function validateInWorker(ssn){return new Promise((resolve,reject)=>{const worker=new Worker(__filename,{workerData:{ssn}});worker.on('message',resolve);worker.on('error',reject);worker.on('exit',(code)=>{if(code!==0)reject(new Error(`Worker exited with code ${code}`));});});}
app.use(bodyParser.json());
app.use((req,res,next)=>{const start=Date.now();res.on('finish',()=>{log('info','request',{method:req.method,path:req.path,status:res.statusCode,duration:Date.now()-start})});next();});
app.post('/kyc',async(req,res)=>{const ssn=(req.body&&req.body.ssn)||'';if(!ssn)return res.status(400).json({error:'Missing SSN'});try{const result=await validateInWorker(ssn);res.json({verified:result.valid,score:result.score,timestamp:new Date().toISOString()});}catch(err){log('error','kyc validation failed',{error:err.message});res.status(500).json({error:'KYC validation failed'});}});
app.get('/health',(req,res)=>{res.json({service:'kyc',status:'ok',pid:process.pid,uptime:process.uptime()});});
const SHUTDOWN_TIMEOUT=parseInt(process.env.SHUTDOWN_TIMEOUT_MS||'55000');let server;
process.on('SIGTERM',()=>{log('info','SIGTERM received');server.close(()=>process.exit(0));setTimeout(()=>process.exit(1),SHUTDOWN_TIMEOUT);});
process.on('SIGINT',()=>{server.close(()=>process.exit(0));setTimeout(()=>process.exit(1),SHUTDOWN_TIMEOUT);});
server=app.listen(PORT,()=>log('info',`kyc service listening on :${PORT}`));
SERVERJS

echo "  All server.js files generated"
