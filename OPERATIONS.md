# Operación de Preventa

Preparación permite seleccionar una cantidad variable de clientes por ruta o facturas de pedidos para entregar. Las facturas de un mismo punto se agrupan en una visita. Cada cliente añade seis minutos de atención; el total incluye carretera desde SPS, traslados, regreso a SPS y el margen adicional indicado por supervisión.

Los recorridos usan una matriz dirigida de tiempos OSRM/FOSSGIS, con varias semillas de vecino cercano y mejoras de orden. No se garantiza el mínimo global. El modelo es vehículo liviano, sin tráfico en vivo ni restricciones de camión. El servicio recibe exclusivamente coordenadas, con autorización de la empresa; no recibe nombres, códigos, facturas ni fotografías. Sus solicitudes se registran. Se limita globalmente la frecuencia y se guardan los cálculos. Si falta conexión de carretera se muestra un error, sin sustituirla por distancia aérea.

El perfil operativo se valida en servidor. Preventista visita y registra pedidos; Motorista entrega pedidos con factura vigente y al menos 48 horas desde la fecha/hora real del pedido. Se valida al preparar, comenzar y llegar. GP solo proporciona fecha documental: supervisión debe registrar o vincular explícitamente el pedido con su hora real y el cliente correcto. No se enlazan nombres por parecido.

Las jornadas, preparaciones, pedidos, eventos y visitas se guardan en Supabase con acceso por sede, actividad y jornada propia. Administrador, Coordinador y Jefaturas pueden preparar y consultar el resumen. Los registros del ensayo anterior en este navegador se conservan; no se usan como la nueva operación compartida.

El flujo es seleccionar persona/ruta, Iniciar Jornada, elegir preparación o visitas, confirmar recorrido y atender clientes. La llegada requiere geolocalización y foto JPEG mediante getUserMedia; no hay selector de archivos. Se necesita HTTPS, permisos de cámara/ubicación y conexión. La fotografía se guarda en un contenedor privado con ticket de visita y enlaces temporales. No se presenta como garantía antifraude de presencia.

Las pausas requieren motivo, con minutos estimados opcionales. Puede atenderse otro cliente tras pausar el actual. Finalizar Jornada requiere resolver la visita activa y explicar la gestión de pendientes. Se confirma el cierre al regresar a SPS. El recorrido original usado queda inmutable como base de comparación.

Mapa de supervisión: verde visitados (incluye resultado fallido porque hubo visita), amarillo en atención, rojo pendientes/pausados. Se actualiza cada 15 segundos con la vista abierta. El tiempo real fuera de atención incluye traslados, esperas y otras gestiones; las pausas de distintos clientes pueden solaparse y no se suman como desplazamiento puro.

Pruebas: node --test tests/*.mjs operations.test.mjs. Verificación de roles, transiciones y límites de 48 horas realizada en transacciones revertidas. La captura real debe comprobarse en los teléfonos que se usarán en campo.
