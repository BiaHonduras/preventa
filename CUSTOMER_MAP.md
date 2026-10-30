# Clientes y mapa de Preventa

La cartera se consulta desde `public.preventa_customer_schedule`, con permisos de lectura por sede y acceso a Preventa. La cuenta compartida puede leer su cartera; no puede editarla. Los archivos de clientes y las importaciones con datos reales no forman parte de este repositorio público.

Cada fila conserva código, nombre, base comercial, ruta/día/semana de preventa, coordenadas, censo y ruta/día/semana de entrega. El registro original, archivo de origen, número de fila y SHA-256 permiten verificar la importación.

El ciclo confirmado comienza el martes 3 de noviembre de 2026 como Semana 1. Las semanas se calculan de lunes a domingo y alternan cada dos semanas. No se desplazan visitas al primer día: un lunes de Semana 1 anterior al inicio se atiende el siguiente lunes de Semana 1, el 16 de noviembre. Los domingos no tienen visitas.

La sección Mapa de Clientes permite filtrar por ruta de entrega, ruta de preventa, base, fecha y ciclo completo con día y semana. Los colores representan rutas de entrega. La lista se pagina en grupos de 50 y la consulta obtiene todas las páginas de datos autorizados.

Los clientes importados se incorporan a Puntos de Entrega y al catálogo usado para planificar. Sus ubicaciones se identifican como procedentes del archivo; una posición confirmada durante una visita tiene prioridad y se conserva. Las facturas se vinculan por código, nunca por similitud de nombre.

Leaflet 1.9.4 se carga solamente al abrir el mapa, con comprobación de integridad. OpenStreetMap proporciona el fondo cartográfico con atribución visible, caché normal del navegador y sin descargas anticipadas. Los nombres y códigos de la cartera no se envían al proveedor cartográfico. Abrir ubicación conduce a Google Maps con las coordenadas del punto elegido por el usuario.

La cartera se carga en segundo plano para no bloquear el inicio de la plataforma. Las pruebas de calendario, paginación, filtros y conservación de ubicaciones están en `tests/customer-map.test.mjs`.
