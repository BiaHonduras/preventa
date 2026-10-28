# Preventa — Control de Entregas

Módulo con acceso corporativo, catálogo compartido de rutas y motoristas y consulta de facturas sincronizadas desde Excel.

## Acceso

La cuenta operativa compartida solo ve este módulo. Los motoristas son registros del catálogo, no usuarios. Administrador, Coordinador y Jefatura pueden administrar rutas y motoristas dentro de sus sedes autorizadas. Las restricciones se validan en el servidor.

## Fuente de facturas

La fuente se lee desde una copia de Excel sincronizada en un equipo autorizado. Se admiten únicamente documentos Contado con número de ocho dígitos, guion y ocho dígitos. El código recibido antes de contabilizar se conserva cuando la factura cambia de estado. Los documentos que llegaron contabilizados sin código se muestran pendientes de vinculación; no se relacionan clientes solo por nombre.

La consulta incluye productos y cantidades y permite buscar por factura, cliente, sede y ruta de origen. Muestra la última sincronización y la fecha de guardado del archivo. El botón Actualizar vista consulta los datos ya recibidos, sin actualizar el Excel.

## Alcance actual

Accesos, catálogos y fuente de facturas se comparten en la plataforma. La programación y los registros de visitas aún se guardan en el navegador de cada cuenta. Su sincronización entre supervisor y motoristas sigue pendiente. No tratar esa parte como un registro de entregas compartido.

La ubicación requiere permiso del dispositivo. La fotografía documenta la visita sin probar por sí sola la presencia. La sugerencia de visitas usa distancia en línea recta y no considera tráfico ni carreteras.

## Pruebas

`node --test tests/*.test.mjs` con Node.js 22 o posterior.

No publicar archivos de Excel, facturas, datos de clientes ni credenciales en este repositorio público. El conector y su configuración privada no forman parte de los archivos publicados.
