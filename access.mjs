import {verifiedUser} from './session.mjs?v=20261030-session';
export const CATALOG_ROLES=new Set(['administrador','coordinador','jefatura_zn','jefatura_zc']);
export function permissionsFor(profile,operatorKind=null){
 const shared=profile?.module_only==='preventa';
 const access=!!profile?.is_active&&Array.isArray(profile.applications)&&profile.applications.includes('preventa')&&profile.sedes?.length>0;
 const manage=access&&!shared&&CATALOG_ROLES.has(profile.role_code);
 return {access,shared,manage,plan:manage||(access&&['preventista','motorista'].includes(operatorKind)),operate:access&&profile.role_code!=='consultas',overview:manage};
}
export async function authenticate(){
 const {supabase}=await import('/control-tiempos/supabase-config.js');
 const identity=await verifiedUser(supabase);
 if(identity.error&&identity.temporary)throw Error('No se pudo conectar para validar tu sesión. Revisa tu conexión y pulsa Reintentar.');
 if(identity.error||!identity.user){location.replace('/intranet/intranet.html');throw Error('Inicia sesión en la Intranet.');}
 if(identity.user.app_metadata?.must_change_password){location.replace('/control-tiempos/cambiar-password.html');throw Error('Actualiza tu contraseña para continuar.');}
 const result=await supabase.rpc('bia_profile');
 if(result.error)throw Error('No se pudo validar tu acceso. Regresa a la Intranet e inténtalo de nuevo.');
 const profile=result.data;
 const ops=await supabase.rpc('preventa_ops_context');if(ops.error)throw Error('No se pudo verificar la actividad operativa. Reintenta.');
 const permissions=permissionsFor(profile,ops.data?.kind);
 if(!permissions.access)throw Error('Tu cuenta no tiene acceso activo a Preventa. Solicita la revisión de permisos al administrador.');
 return {supabase,profile,permissions,opsContext:ops.data};
}

