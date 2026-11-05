JSON.stringify((()=>{
 setImmediate(()=>{try{
  const req=process.mainModule.require.bind(process.mainModule),http=req('http'),fs=req('fs'),path=req('path'),crypto=req('crypto');
  if(globalThis.__codexQQEmojiBridge?.ttl)clearTimeout(globalThis.__codexQQEmojiBridge.ttl);
  if(globalThis.__codexQQEmojiBridge?.server)globalThis.__codexQQEmojiBridge.server.close();
  const native=req(path.join(process.resourcesPath,'app','wrapper.node'));
  const connection=JSON.parse(fs.readFileSync(path.join(process.resourcesPath,'app','stickerbox-connection.json'),'utf8'));
  const token=connection.token,expiresAt=0,port=Number(new URL(connection.baseUrl).port);
  const configPath=path.join(req('os').tmpdir(),'codex-qq-emoji-bridge.json');
  const searchService=()=>{try{return globalThis.authData?.uin&&native.NodeIQQNTWrapperSession.getNTWrapperSession('nt_1')?.getMsgService();}catch(_){return null;}};
  let tail=Promise.resolve();
  const reply=(res,status,obj)=>{if(!res.destroyed){res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'});res.end(JSON.stringify(obj));}};
  const server=http.createServer(async(request,response)=>{
   if(request.headers.authorization!=='Bearer '+token)return reply(response,401,{ok:false,error:'Unauthorized'});
   const u=new URL(request.url,'http://127.0.0.1');
   if(request.method!=='GET')return reply(response,405,{ok:false,error:'GET only'});
   if(u.pathname==='/health')return reply(response,200,{ok:true,version:3,expiresAt,loggedIn:!!searchService()?.getHotPicSearchResult});
   if(u.pathname!=='/search')return reply(response,404,{ok:false,error:'Unknown endpoint'});
   const query=(u.searchParams.get('q')||'').trim(),limit=Number(u.searchParams.get('limit')||20);
   if(!query||query.length>100||!Number.isInteger(limit)||limit<1||limit>50)return reply(response,400,{ok:false,error:'q must contain 1–100 characters; limit must be 1–50'});
   const previous=tail;let release;tail=new Promise(resolve=>{release=resolve;});
   await previous;
   if(response.destroyed){release();return;}
   let timer;
   try{
    const service=searchService();
    if(!service?.getHotPicSearchResult)throw new Error('请先在 QQ 调试副本登录，再重新搜索');
    const args={srcUin:String(globalThis.authData.uin),userText:query,pageSize:limit,pageIndex:0,sceneType:1,aioType:1,groupCode:'0',guildID:'0',channelID:'0',isSupportCompose:true,isSupportMall:true};
    const value=await Promise.race([service.getHotPicSearchResult(args),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('QQ search timed out')),20000);})]);
    const r=value?.rsp;
    if(value?.result!==0||r?.resultCode!==0)return reply(response,502,{ok:false,error:value?.errMsg||r?.errorMsg||'QQ search failed',code:value?.result,resultCode:r?.resultCode});
    const mapItem=x=>({id:x.resourceID,md5:x.imageMD5,width:x.imageWidth,height:x.imageHeight,url:x.imageUrl,thumbnailUrl:x.thumbnailUrl,size:String(x.imageSize),emojiType:x.emojiType,composition:x.textComposeInfo||null});
    const items=(r.infoArray||[]).map(mapItem);
    const templates=(r.composeEmojis||[]).filter(x=>x.textComposeInfo?.bBox).map(mapItem);
    reply(response,200,{ok:true,query,count:items.length,page:0,hasNext:!!r.pageHasNext,items,templates});
   }catch(e){reply(response,502,{ok:false,error:String(e.message||e)});}finally{clearTimeout(timer);release();}
  });
  server.listen(port,'127.0.0.1',()=>{fs.writeFileSync(configPath,JSON.stringify({version:3,baseUrl:'http://127.0.0.1:'+server.address().port,token,expiresAt,pid:process.pid}),{mode:0o600});});
  server.unref();
  globalThis.__codexQQEmojiBridge={server};
 }catch(e){try{process.mainModule.require('fs').writeFileSync(process.mainModule.require('path').join(process.mainModule.require('os').tmpdir(),'codex-qq-emoji-bridge-error.txt'),String(e));}catch(_){}}});
 return {scheduled:true};
})())
