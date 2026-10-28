import test from 'node:test';
import assert from 'node:assert/strict';
import {createCatalogs} from '../catalogs.mjs';
function fixture(manage){const rows={preventa_routes:[{id:'r1',code:'RUTA-1',name:'Ruta 1',site:'SPS',locality:'Zona <norte>',active:true,version:1}],preventa_drivers:[{id:'d1',name:'Motorista 1',site:'SPS',active:true,version:1}]};return createCatalogs({supabase:{from:table=>({select:()=>({order:async()=>({data:rows[table]})})})},profile:{sedes:['SPS']},permissions:{manage},onChange:()=>{},notify:()=>{}})}
test('Cuenta sin gestión no obtiene pantalla ni editor del catálogo',async()=>{const catalog=fixture(false);await catalog.refresh();assert.equal(catalog.html(),'');assert.throws(()=>catalog.editor('route','r1'),/permiso/)});
test('Pantalla de gestión distingue rutas de motoristas y escapa texto',async()=>{const catalog=fixture(true);await catalog.refresh();const html=catalog.html();assert.match(html,/Crear ruta/);assert.match(html,/Agregar motorista/);assert.match(html,/Zona &lt;norte&gt;/);assert.match(html,/sin crear cuentas de usuario/)});
test('Editor conserva versión y únicamente ofrece sedes autorizadas',async()=>{const catalog=fixture(true);await catalog.refresh();const html=catalog.editor('route','r1');assert.match(html,/data-version="1"/);assert.match(html,/<option selected>SPS<\/option>/);assert.doesNotMatch(html,/<option[^>]*>TGU/);assert.match(catalog.editor('driver','d1'),/no crea un usuario, correo ni contraseña/)});

