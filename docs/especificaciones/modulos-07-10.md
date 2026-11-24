# Producción y Control Administrativo

**Especificaciones del 23 de noviembre de 2026. Primera implementación institucional del 24 de noviembre.** Los 17 apartados describen el alcance acordado. Las pruebas de aceptación de cada fila conservan su carácter de requisito hasta que se documente su verificación.

## Disponible en la plataforma

Desde el menú principal, Producción abre las órdenes de trabajo, fichas, rótulos, movimientos, recuperación, costos, precios y garantías. Control Administrativo abre los permisos, las novedades, el panel gerencial, los proyectos, la documentación y la auditoría. Ambos utilizan la identidad de Equipo y guardan las operaciones en la base institucional.

1. El Creador asigna el perfil y las funciones en **Control Administrativo → Usuarios y permisos**. Para movimientos físicos, Equipo debe conceder también el permiso de registro de inventario. La verificación de referencias y el conteo de apertura requieren aprobación de Inventarios.
2. En **Inventario central**, vincular cada código comercial a su referencia física, unidad y conversión. Registrar la existencia contada por bodega. Las existencias importadas y los saldos físicos tienen procedencias distintas.
3. Crear la ficha con la ruta y la fórmula de materiales. Abrir la OT con el acta, fechas, responsables y bodega de insumos de cada referencia. La OT muestra reservas y faltantes. En su cierre se informa el consumo adicional real y se libera el material pendiente.
4. Producción verifica las etapas y registra el lote y las entregas. La persona que recibe comprueba la cantidad. Una diferencia conserva el conteo inicial y genera un caso compartido con Control. Al aceptar la cantidad exacta, el libro físico registra la entrada. Los cortes de carreta reservan y despachan contra la OP confirmada por Ventas.
5. Control muestra saldos de Caja, capital y abonos de Deudas, y conciliaciones por cuenta al corte, sujetos al mismo acceso de cada fuente. Los proyectos conservan sus propios presupuestos y supuestos. Los precios oficiales por SKU se consultan desde el selector de Ventas al añadir productos.

**Verificación independiente con datos de ensayo.** Se comprobaron el acceso por perfil, la revocación, la protección de expedientes, la OT única, el checklist, las diferencias de recepción, la idempotencia, el consumo y la reserva de materiales, las vigencias de precios, el despacho de carreta y la reapertura exclusiva. Las pruebas se ejecutan en una base aislada con el mismo libro de inventario que usa la aplicación.

Deudas y Producción comparten las partidas por factura, vencimiento y proveedor. Un abono puede distribuirse entre varias partidas. Cada aplicación exige el egreso efectivo de Caja o el movimiento físico de chatarra, monto disponible y aprobación de otra persona desde Control. El saldo a favor queda visible por separado como cuenta por cobrar al proveedor. Un reverso contabilizado de Caja deja de computar en el saldo.

La conciliación de garantías enlaza la entrada de material clasificado con la solución comercial y su movimiento original. La reposición conserva el costo interno y el comprobante de entrega. El reembolso debe corresponder al cliente, cantidad y precio pagado documentados. Usar las ubicaciones físicas **GARANTÍAS - CHATARRA**, **GARANTÍAS - RECUPERACIÓN** o **GARANTÍAS - CORTAS** según el dictamen. La documentación de la factura original y el enlace a la venta de adicionales requieren revisión humana. Los adicionales autorizados por Gerencia de Ventas conservan su lista y precio vigente. Informes permite consultar y exportar las versiones históricas por fecha, proceso y referencia.

**Pendientes para adopción integral.** Falta cotejar fórmulas y unidades con el archivo exacto `2. Muestras Junio 2026(4).xlsx` y homologar las referencias físicas y sus saldos de apertura. Las ventas que residen en el navegador y el histórico de Alegra sin detalle por línea impiden verificar automáticamente la OP, el precio unitario original de una garantía y la factura de adicionales. Falta integrar la nómina institucional y los cruces sustentados en servicios facturados a terceros. La cuenta de Creador ya está vinculada. La asignación de permisos al personal y las pruebas con evidencias reales corresponden a la puesta en marcha.

## Módulo 07 · Producción

| Apartado | Qué debe poder hacer el equipo | Evidencia para aceptar la entrega |
| --- | --- | --- |
| 07.1 Productos y fichas | Asociar la ficha versionada al código comercial, con presentación, unidad de análisis, materiales, cantidades teóricas, ruta propia y costo. Cada ruta interna empieza en recuperación. | Dos referencias con rutas distintas mantienen sus procesos. Tras un cambio de especificación autorizado por CREADOR, una OT anterior sigue mostrando la versión que utilizó. |
| 07.2 Materiales y recuperación | Registrar entregas parciales por partida, peso facturado, peso verificado o ausencia documentada de pesaje. Clasificar salidas en material limpio, insumo reutilizable, chatarra comercial y descarte. Vincular trabajos externos al valor de su factura. | Una diferencia de cualquier signo abre una novedad. Producción justifica el destino de cada componente antes de cerrar la conciliación. |
| 07.3 Proveedores y costos | Enlazar partidas legalizadas, recepciones y servicios al proveedor. Distribuir vencimientos y abonos, documentar compensaciones autorizadas y reconocer en Cartera el saldo a favor correspondiente. | Una factura con dos trabajos y una entrega parcial conserva los costos documentados, aunque solo se haya pagado un abono. Un pago mixto conserva el vínculo a Caja y al cruce aprobado. |
| 07.4 Programación | Al concluir la reunión con Ventas y Administrativa se emite una única OT definitiva. Incluir referencias fabricadas y compradas, fechas, responsables, prioridades, checklist por producto y necesidades de materiales. | Dos aperturas simultáneas dejan una sola OT abierta. Reprogramar deja motivo y valores anteriores y recalcula insumos y reservas. El cierre parcial exige conciliar lo ejecutado y justificar cada pendiente. |
| 07.5 Control operativo | Identificar cada rótulo por serie y referencia, registrar regular, cortas, daño y sobrantes. Conservar entrega y recepción por actores de sus áreas. Contar físicamente por clase maestra y sububicación. | Dos rótulos pueden alimentar un lote. Un rótulo pertenece a una sola referencia. El primer conteo y las diferencias permanecen en el historial. Reabrir un rótulo cerrado requiere CREADOR. |
| 07.6 Costos y rendimientos | Comparar cantidades teóricas y reales de todos los materiales por OT. Simular descuento, precio neto, utilidad, margen sobre venta y rentabilidad sobre costo. Analizar gastos generales por mes y conservar versiones históricas. | Validar fórmulas, unidades y vacíos frente al Excel de muestras de junio de 2026. Producción prepara el cierre mensual, Gerencia o CREADOR lo aprueba. Los informes históricos conservan el corte para exportar desde Informes. |
| 07.7 Inventarios y lotes | Habilitar el lote por checklist verificado. Admitir entregas parciales, conservar primer conteo y registrar aceptación física exacta por Bodega. Para producto comprado terminado, enlazar OT, compra, verificación y aceptación. Reservar y cortar metros por carreta contra OP confirmada. | Una diferencia en el primer conteo alerta a Gerencia y CREADOR. Reintentar una recepción aceptada produce una sola entrada. Dos OP no pueden reservar los mismos metros. El último corte concilia metros iniciales, cortes y saldo físico con decisión expresa sobre sobrantes. |
| 07.8 Garantías y devoluciones | Producción certifica origen, mide o pesa y dicta procedencia y destino. Gerencia o Gerencia de Ventas autoriza la solución. Vincular el reconocimiento a la factura y al precio pagado, y los adicionales al precio vigente autorizado. | La devolución queda separada del stock vendible. Cable 7 Hilos dañado va a chatarra. Reposición, adicionales y clasificación física deben quedar conciliados para cerrar el caso. |
| 07.9 Listas de precios | Mantener listas general, vendedores y adicionales. Cambiar referencias seleccionadas y programar vigencia. Registrar versión, responsable y autorización de CREADOR, Gerencia o Gerente de Ventas. | En la fecha programada se aplica el nuevo precio a operaciones nuevas. La factura anterior conserva el precio original y las referencias no seleccionadas conservan su precio. |

Las series de rótulo previstas son Alambre Eco, Alambre Plus, Alambre Desnudo, Cable 7 Hilos, Cobre para Pinos y Aluminio. El código comercial, la OT, la OP, el lote, el rótulo y la carreta identifican entidades distintas.

## Módulo 10 · Control Administrativo

La entrada exige una identidad activa con perfil **CREADOR, PRESIDENTE, SOCIO ACCIONISTA o GERENTE**. El servidor verifica además el permiso específico en cada operación. Gerente de Ventas resuelve las autorizaciones comerciales que le competen desde Ventas o Producción.

| Apartado | Qué debe poder hacer el equipo | Evidencia para aceptar la entrega |
| --- | --- | --- |
| 10.1 Usuarios y perfiles | Usar la identidad de Equipo para gestionar altas, activación, suspensión y reactivación. Consultar área, perfil, contacto y permisos. | Al desactivar una cuenta cesa el acceso y sus documentos conservan al responsable original. |
| 10.2 Permisos y accesos | Conceder y retirar facultades por persona, módulo y acción. Conservar valor anterior, nuevo, motivo, ejecutor y fecha. | Probar los cuatro perfiles con distintos permisos y una cuenta ajena al módulo con un permiso general. La revocación debe surtir efecto en el servidor. |
| 10.3 Autorizaciones | Mostrar el caso del módulo de origen por su identificador. Registrar pendiente, en revisión, aprobada, rechazada o resuelta, con responsable, motivo y soporte. | Tras una decisión, ambos módulos consultan el mismo caso. Un reintento aplica una sola vez el cambio permitido. La reapertura de cierres queda reservada a CREADOR. |
| 10.4 Novedades | Filtrar por módulo, estado, importancia, fecha, responsable y área. Asignar seguimiento con evidencias y preservar el hecho inicial. | Una entrega discrepante aparece con ambos conteos. El seguimiento administrativo conserva la responsabilidad de aceptación física de las áreas. |
| 10.5 Panel gerencial | Consultar indicadores autorizados de finanzas, ventas, operación, personal agregado y gestión con fecha de corte, fuente y acceso al detalle permitido. | Conciliar los totales al mismo corte con sus fuentes. Presentar por separado proyección, causación, pago y conciliación. |
| 10.6 Proyecciones y proyectos | Registrar objetivo, responsable, fechas, presupuesto, estado, supuestos versionados, vínculos a documentos y seguimiento previsto frente a ejecutado. | Revisar dos versiones de un escenario y rastrear el cambio de supuesto. El libro financiero refleja únicamente operaciones reales. |
| 10.7 Documentación confidencial | Clasificar expedientes por tipo, asunto, fecha, vigencia, responsable y nivel de acceso. Versionar archivos y controlar individualmente consulta, descarga, actualización y administración. | Probar búsqueda, vista previa, enlace directo, informe y exportación con sesión autorizada y revocada. La consulta y descarga autorizadas dejan traza según corresponda. |
| 10.8 Auditoría y seguridad | Consultar accesos, revocaciones, decisiones, reaperturas y eventos sensibles con actor, sello de tiempo, motivo, soporte y versión. | Reconstruir una autorización y una reapertura desde las dos vistas con el mismo documento fuente. Intentos de autoelevación y duplicación deben ser rechazados. |

## Orden de entrega y dependencias

1. **Identidades y maestros.** Vincular perfiles y permisos institucionales con Equipo. Cotejar códigos, unidades, existencias y ubicaciones con el maestro real. Probar sesión desactivada y autorización por acción.
2. **Primer recorrido de planta.** Ventas solicita, Producción abre la OT, verifica el checklist por producto y declara la entrega. Bodega cuenta y acepta. Inventarios registra la entrada una sola vez. Ensayar una recepción parcial y una con diferencia.
3. **Excepciones y gobierno.** Abrir el caso en el módulo de origen, revisarlo desde Control Administrativo y verificar la decisión en origen. Ensayar una reapertura exclusiva de CREADOR y acceso directo a un documento reservado.
4. **Rendimientos y cierre.** Probar recuperación, terceros, carretas, garantías, costos, listas vigentes e informes. Comparar el motor con el libro de junio antes de migrar fórmulas. Conciliar Caja, Inventarios, Ventas, Cartera y Nómina al mismo corte en los casos que los involucren.

## Fuentes de control

Los originales se conservan en la carpeta de trabajo `docs/especificaciones/originales/`. Las huellas SHA-256 permiten cotejar las copias utilizadas para pruebas y migración.

| Documento | Páginas | SHA-256 |
| --- | ---: | --- |
| TREFIL_OS_Modulo_07_Produccion_Especificacion_Funcional.pdf | 6 | `65fc0ed08d96c8ffb3c33b327f2b0fe6fb066c1b8a267b6cf5cb5ef0de57d3aa` |
| TREFIL_OS_Modulo_10_Control_Administrativo_Especificacion_Funcional.pdf | 5 | `e6306ba3d1062c9455ef3692fd8078f481208adb4cb8b2931a53e854efbf3ecc` |
