import test from 'node:test';
import assert from 'node:assert/strict';
import {permissionsFor} from '../access.mjs';
const base={is_active:true,applications:['preventa'],sedes:['SPS'],role_code:'verificador'};
test('Cuenta compartida solo opera; no programa ni administra',()=>{const p=permissionsFor({...base,module_only:'preventa'});assert.equal(p.access,true);assert.equal(p.shared,true);assert.equal(p.operate,true);assert.equal(p.manage,false);assert.equal(p.plan,false);assert.equal(p.overview,false)});
test('Roles autorizados gestionan rutas y motoristas',()=>{for(const role_code of ['administrador','coordinador','jefatura_zn','jefatura_zc'])assert.equal(permissionsFor({...base,role_code}).manage,true)});
test('Consultas y verificadores no administran rutas',()=>{for(const role_code of ['consultas','verificador'])assert.equal(permissionsFor({...base,role_code}).manage,false);assert.equal(permissionsFor({...base,role_code:'consultas'}).operate,false)});
test('Una cuenta compartida no gana administración aunque cambie el rol visual',()=>{assert.equal(permissionsFor({...base,module_only:'preventa',role_code:'administrador'}).manage,false)});
test('Sin cuenta activa, sede o aplicación no hay acceso',()=>{for(const change of [{is_active:false},{sedes:[]},{applications:[]}])assert.equal(permissionsFor({...base,...change}).access,false)});
