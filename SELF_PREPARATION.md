# Preparación por actividad y selección entre rutas

Motorista y Preventista acceden a Preparación, Mi Jornada y Consultar Facturas. Mapa y Clientes quedan visibles únicamente para Administrador, Coordinador y Jefaturas, igual que Resumen y Gestión. El inicio de sesión obtiene la actividad autorizada mediante preventa_ops_context; no se deduce de un texto escrito por el usuario.

Preparación admite la selección acumulada de varias rutas. Ruta de inicio identifica el recorrido operativo; Seleccionar de la ruta filtra la lista sin borrar lo marcado. La selección completa se muestra aparte con su ruta y permite quitar registros. Agregar primeros de esta ruta añade disponibles sin duplicar los ya seleccionados. Se conserva el desplazamiento al marcar casillas.

Preventista ve clientes del calendario de la ruta consultada (o ciclo completo, si lo marca). Motorista ve las facturas presentes en la sincronización para la ruta de origen elegida. Las facturas sin pedido y punto de entrega vinculados aparecen pendientes y no se seleccionan para calcular; no se asocian por similitud de nombre. Se mantiene la antigüedad mínima de 48 horas y la agrupación de varias facturas del mismo punto en una visita.

La actividad queda bloqueada para los accesos operativos; supervisión puede preparar ambas. Cada preparación operativa exige seleccionar una ficha de su propia actividad. Los permisos del servidor validan actividad, sede y rutas permitidas. La tabla privada preventa_worker_routes habilita explícitamente 501, 561 y 564 para las cinco fichas actuales de SPS; una ruta futura no se incorpora automáticamente a esa lista. La ruta propia asignada sigue siendo la ruta de inicio del Preventista. Nuevas habilitaciones se deben asignar expresamente; no se escriben desde las cuentas operativas.

El inicio y la aplicación de un recorrido vuelven a comprobar la ruta habilitada. La aplicación verifica también las rutas de todos los puntos. No cambian las restricciones de fotografía, geolocalización ni las políticas de los otros módulos.

Validación: 33 pruebas JavaScript y pruebas SQL en transacción revertida para preparación entre rutas, aislamiento de actividad, rechazo de clientes/rutas no habilitados, ruta inicial asignada, selección por factura y 48 horas. Pruebas de interfaz con ambos perfiles y datos ficticios confirmaron que selecciones 501/561 se mantienen al cambiar la lista y regresar.
