// Never treat an unavailable auth server as a confirmed sign-out.
export function temporaryFailure(error){
 if(!error)return false;
 if(error.name==='AuthSessionMissingError'||['session_not_found','refresh_token_not_found','refresh_token_already_used','user_not_found','bad_jwt','AUTH_REQUIRED'].includes(error.code))return false;
 const status=Number(error.status||0);
 return error.name==='AuthRetryableFetchError'||status===0||status===408||status===429||status>=500;
}
export async function verifiedUser(supabase){
 let result;
 try{result=await supabase.auth.getUser();}catch(error){return {temporary:temporaryFailure(error),error};}
 if(result.error&&[401,403].includes(Number(result.error.status))&&supabase.auth.refreshSession){
  let refreshed;try{refreshed=await supabase.auth.refreshSession();}catch(error){return {temporary:temporaryFailure(error),error};}
  if(refreshed.error)return {temporary:temporaryFailure(refreshed.error),error:refreshed.error};
  try{result=await supabase.auth.getUser();}catch(error){return {temporary:temporaryFailure(error),error};}
 }
 if(result.error)return {temporary:temporaryFailure(result.error),error:result.error};
 return {user:result.data?.user||null};
}
const sameSites=(a=[],b=[])=>JSON.stringify([...a].sort())===JSON.stringify([...b].sort());
export function createSessionMonitor({supabase,profile,onTemporary,onValid,onInvalid,onChanged,onPassword}){
 let running=false,active=true,epoch=0;
 function invalidate(reason){if(!active)return;active=false;epoch++;onInvalid(reason);}
 async function check(){
  if(running||!active)return;running=true;const token=epoch;
  try{
   const identity=await verifiedUser(supabase);if(!active||token!==epoch)return;
   if(identity.error){if(identity.temporary)onTemporary('auth_unavailable');else invalidate('session_invalid');return;}
   const user=identity.user;if(!user){invalidate('session_missing');return;}if(user.id!==profile.id){invalidate('account_changed');return;}
   if(user.app_metadata?.must_change_password){active=false;onPassword();return;}
   let result;try{result=await supabase.rpc('bia_profile');}catch{if(active&&token===epoch)onTemporary('profile_unavailable');return;}
   if(!active||token!==epoch)return;
   if(result.error){if(result.error.message==='CAMBIO_PASSWORD_REQUERIDO'){active=false;onPassword();}else if(result.error.message==='AUTH_REQUIRED'){invalidate('session_invalid');}else onTemporary('profile_unavailable');return;}
   const p=result.data;
   if(!p?.is_active||!p.applications?.includes('preventa')||!p.sedes?.length){invalidate('access_removed');return;}
   if(p.role_code!==profile.role_code||p.module_only!==profile.module_only||!sameSites(p.sedes,profile.sedes)){active=false;onChanged();return;}
   onValid();
  }finally{running=false;}
 }
 return {check,invalidate};
}
