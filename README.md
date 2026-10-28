# Preventa — Control de Entregas

Demostración de una aplicación web para programar y registrar entregas. Incluye únicamente datos ficticios y almacenamiento local en el navegador.

## Funciones de demostración

- Resumen diario por ruta y motorista.
- Programación de visitas y asignación semanal de clientes.
- Nombres editables para dos motoristas y tres rutas.
- Inicio y cierre de jornada.
- Ubicación bajo permiso del dispositivo, fotografía y tiempo de atención por visita.
- Resultado exitoso o fallido con motivo.
- Registro provisional de clientes y disposición de pedidos pendientes.
- Orden sugerido por distancia en línea recta, sin tráfico ni cálculo vial.

## Límites

No tiene autenticación, sincronización entre dispositivos ni conexión a sistemas externos. No usar con información real. La ubicación y las fotografías de prueba permanecen en el navegador. Una fotografía no prueba por sí sola la presencia en un establecimiento.

## Ejecución

Servir los archivos con un servidor HTTP y abrir index.html. La geolocalización requiere HTTPS o localhost y autorización del usuario.

Pruebas: `node --test tests/domain.test.mjs` con Node.js 22 o posterior. No requiere instalar dependencias.

GitHub Pages: seleccionar la rama main y la carpeta raíz en Settings → Pages para publicar la demostración.
