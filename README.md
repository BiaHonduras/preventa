# Preventa — Control de Entregas

Módulo de entregas con acceso corporativo y catálogo compartido de rutas y motoristas.

## Acceso

El inicio de sesión se realiza desde la Intranet. La cuenta operativa compartida ve únicamente este módulo. Los motoristas son registros del catálogo y se seleccionan al iniciar la jornada: no son cuentas de usuario.

La administración de rutas y motoristas se muestra a Administrador, Coordinador y Jefatura, con validación de permisos en el servidor y alcance por sede. Permite crear, editar y desactivar; conserva auditoría de cambios. Una edición concurrente requiere actualizar el registro antes de volver a guardar.

## Estado funcional

El acceso y los catálogos están conectados. La programación y las visitas todavía usan datos ficticios guardados en el navegador de cada cuenta; no están sincronizadas entre dispositivos. La conexión a facturas está pendiente. No usar aún para registrar entregas reales.

La captura de ubicación requiere autorización del dispositivo. La fotografía documenta la visita y no prueba por sí sola la presencia. El orden sugerido usa distancia en línea recta, sin tráfico ni cálculo vial.

## Pruebas

`node --test tests/*.test.mjs` con Node.js 22 o posterior. Sin instalación de dependencias.

No guardar credenciales ni datos operativos en este repositorio público.
